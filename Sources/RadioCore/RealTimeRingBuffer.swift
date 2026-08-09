// SPDX-License-Identifier: Apache-2.0

import Darwin

// MARK: - Atomics

/// Atomic 64-bit counter operations with a full memory barrier.
///
/// ### Why `OSAtomic` and not `Synchronization.Atomic`
///
/// This package deploys to macOS 13 / iOS 16 (see `Package.swift`, which RC-9
/// may not edit). Swift's `Synchronization.Atomic` is `macOS 15 / iOS 18` only,
/// and `swift-atomics` is a third-party dependency this project does not take.
/// That leaves the `OSAtomic` family, which is documented as deprecated but is
/// still exported by `libSystem` on every platform this package targets, still
/// compiles warning-free against the current SDK, and — unlike a lock — is
/// wait-free and therefore safe to call from the audio render thread.
///
/// `OSAtomicAdd64Barrier(0, p)` is the canonical idiom for "atomic load with a
/// barrier": it is a read-modify-write that adds nothing, so it returns the
/// current value without changing it. Using an RMW rather than a plain load
/// costs a cache-line acquisition, which at 50 frames/second is not a cost
/// worth reasoning about, and it removes any question of the Swift optimiser
/// reordering or caching the load.
@inline(__always)
private func atomicLoad(_ pointer: UnsafeMutablePointer<Int64>) -> Int64 {
    OSAtomicAdd64Barrier(0, pointer)
}

/// Atomically adds `amount` and returns the new value, with a full barrier.
@inline(__always)
@discardableResult
private func atomicAdd(_ amount: Int64, _ pointer: UnsafeMutablePointer<Int64>) -> Int64 {
    OSAtomicAdd64Barrier(amount, pointer)
}

// MARK: - RealTimeRingBuffer

/// A lock-free, allocation-free, single-producer/single-consumer ring of
/// fixed-size `Int16` frames (RC-9).
///
/// ### What problem this solves
///
/// `AVAudioEngine` delivers microphone buffers on a real-time audio thread. A
/// real-time thread has a hard deadline; if it blocks on a lock held by a
/// normal-priority thread it misses that deadline and the audio device glitches.
/// `malloc` takes such a lock. So does `free`. So does anything that grows a
/// Swift `Array`, and so does arbitrary caller code invoked from the callback.
/// None of that is a data race — it is a priority-inversion hazard, and it
/// shows up as intermittent dropouts under load rather than as a crash, which
/// is why it has to be designed out rather than debugged later.
///
/// This type is the handoff. The tap thread writes whole frames into storage
/// that was allocated once, at `startCapture` time, and publishes them by
/// bumping an atomic counter. A normal-priority consumer task reads them back
/// and does everything unbounded (calling the caller's `onFrame`, network I/O)
/// off the render thread.
///
/// ### Concurrency contract — exactly one producer, exactly one consumer
///
/// * ``write(_:)-3vlhq`` may be called from **one** thread only (the tap).
/// * ``read(into:)`` may be called from **one** thread only (the drain task).
/// * Each counter has exactly one writer: the producer owns `writeCounter` and
///   `droppedCounter`, the consumer owns `readCounter`. Neither side ever
///   stores to the other's counter, so no compare-and-swap retry loop exists
///   and both sides are wait-free.
/// * The counters are monotonic frame counts, not wrapped indices, so
///   "how full is it" is the plain subtraction `written - read` with no
///   empty/full ambiguity. `Int64` at 50 frames/second overflows in about six
///   billion years.
/// * A full barrier separates the frame's payload from the counter bump on
///   both sides, so a consumer that observes `written == n` is guaranteed to
///   see the complete payload of frame `n - 1`.
///
/// Observers (``availableFrames``, ``droppedFrameCount``) may be read from any
/// thread; they are a snapshot and may be stale the instant they return.
///
/// ### Overrun policy — drop the newest frame, and count it
///
/// If the consumer stalls long enough for the ring to fill, ``write(_:)-3vlhq``
/// **discards the incoming frame and increments ``droppedFrameCount``**. It
/// does not block, does not overwrite, and does not wait.
///
/// Dropping the *newest* rather than the oldest is a deliberate choice, for two
/// reasons. First, discarding the oldest would require the producer to advance
/// `readCounter` — the consumer's variable — which breaks the single-writer
/// invariant above and would force a CAS retry loop onto the render thread.
/// Second, the already-buffered audio is a contiguous span of speech; punching
/// a hole in its middle is worse for a listener than truncating its end.
///
/// The counter is public all the way up to ``AudioPipeline/droppedCaptureFrameCount``
/// on purpose. Silently losing received audio is the single worst failure mode
/// for this project: it is indistinguishable, from the user's chair, from a bad
/// network, and it is what gets chased for weeks. If frames are being dropped,
/// the number says so.
final class RealTimeRingBuffer: @unchecked Sendable {
    /// Samples per frame. Every ``write(_:)-3vlhq`` and ``read(into:)`` moves
    /// exactly this many samples.
    let frameSize: Int

    /// Number of frames the ring can hold before it starts dropping.
    let capacity: Int

    /// `frameSize * capacity` samples, allocated once in `init` and never
    /// resized.
    private let storage: UnsafeMutablePointer<Int16>

    /// One 64-byte-aligned block holding three `Int64` counters, one per cache
    /// line, so the producer bumping `writeCounter` does not invalidate the
    /// line the consumer is reading `readCounter` from (false sharing).
    private let countersBlock: UnsafeMutableRawPointer
    private let writeCounter: UnsafeMutablePointer<Int64>   // producer-owned
    private let readCounter: UnsafeMutablePointer<Int64>    // consumer-owned
    private let droppedCounter: UnsafeMutablePointer<Int64> // producer-owned

    private static let cacheLine = 64

    init(frameSize: Int, capacity: Int) {
        precondition(frameSize > 0, "frameSize must be positive")
        precondition(capacity > 0, "capacity must be at least one frame")
        self.frameSize = frameSize
        self.capacity = capacity

        self.storage = UnsafeMutablePointer<Int16>.allocate(capacity: frameSize * capacity)
        self.storage.initialize(repeating: 0, count: frameSize * capacity)

        let block = UnsafeMutableRawPointer.allocate(
            byteCount: 3 * Self.cacheLine,
            alignment: Self.cacheLine
        )
        self.countersBlock = block
        self.writeCounter = block.bindMemory(to: Int64.self, capacity: 1)
        self.readCounter = block.advanced(by: Self.cacheLine).bindMemory(to: Int64.self, capacity: 1)
        self.droppedCounter = block.advanced(by: 2 * Self.cacheLine).bindMemory(to: Int64.self, capacity: 1)
        self.writeCounter.initialize(to: 0)
        self.readCounter.initialize(to: 0)
        self.droppedCounter.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: frameSize * capacity)
        storage.deallocate()
        countersBlock.deallocate()
    }

    // MARK: Observers

    /// Frames written and accepted since construction.
    var writtenFrameCount: Int { Int(atomicLoad(writeCounter)) }

    /// Frames handed to the consumer since construction.
    var readFrameCount: Int { Int(atomicLoad(readCounter)) }

    /// Frames the producer discarded because the ring was full — see the
    /// overrun policy in the type documentation. Monotonic.
    var droppedFrameCount: Int { Int(atomicLoad(droppedCounter)) }

    /// Frames currently waiting for the consumer.
    var availableFrames: Int {
        let written = atomicLoad(writeCounter)
        let read = atomicLoad(readCounter)
        return Int(written - read)
    }

    /// `true` when the next ``write(_:)-3vlhq`` would be dropped.
    var isFull: Bool { availableFrames >= capacity }

    // MARK: Producer side (real-time safe)

    /// Writes exactly one frame. **Real-time safe**: no allocation, no locks,
    /// no unbounded work — a `memcpy` of `frameSize` samples and two atomic
    /// counter operations.
    ///
    /// - Parameter samples: exactly ``frameSize`` samples.
    /// - Returns: `true` if the frame was accepted, `false` if the ring was
    ///   full and the frame was dropped (see ``droppedFrameCount``).
    @discardableResult
    func write(_ samples: UnsafeBufferPointer<Int16>) -> Bool {
        precondition(samples.count == frameSize, "a ring frame must be exactly frameSize samples")
        guard let source = samples.baseAddress else { return false }

        let written = atomicLoad(writeCounter)
        let read = atomicLoad(readCounter)
        guard written - read < Int64(capacity) else {
            atomicAdd(1, droppedCounter)
            return false
        }

        let slot = Int(written % Int64(capacity))
        storage.advanced(by: slot * frameSize).update(from: source, count: frameSize)
        // Full barrier: the payload above is visible to any thread that
        // observes the counter bump below.
        atomicAdd(1, writeCounter)
        return true
    }

    /// `Array`-flavoured producer entry point. Still allocation-free —
    /// `withUnsafeBufferPointer` borrows the array's existing storage — but it
    /// exists for tests and for callers that already hold an array, not for the
    /// render thread, which should hand over a pointer it already owns.
    @discardableResult
    func write(_ samples: [Int16]) -> Bool {
        samples.withUnsafeBufferPointer { write($0) }
    }

    // MARK: Consumer side

    /// Reads one frame into caller-provided storage. Allocation-free.
    ///
    /// - Parameter destination: exactly ``frameSize`` samples of writable
    ///   storage.
    /// - Returns: `true` if a frame was copied out, `false` if the ring was
    ///   empty (in which case `destination` is untouched).
    @discardableResult
    func read(into destination: UnsafeMutableBufferPointer<Int16>) -> Bool {
        precondition(destination.count == frameSize, "a ring frame must be exactly frameSize samples")
        guard let target = destination.baseAddress else { return false }

        let written = atomicLoad(writeCounter)
        let read = atomicLoad(readCounter)
        guard read < written else { return false }

        let slot = Int(read % Int64(capacity))
        target.update(from: storage.advanced(by: slot * frameSize), count: frameSize)
        // Full barrier: the copy above completes before the slot is released
        // back to the producer.
        atomicAdd(1, readCounter)
        return true
    }

    /// Convenience consumer read that returns a fresh array, or `nil` when the
    /// ring is empty. **Allocates** — for the normal-priority drain task and
    /// for tests, never for the render thread.
    func readFrame() -> [Int16]? {
        var frame = [Int16](repeating: 0, count: frameSize)
        let gotFrame = frame.withUnsafeMutableBufferPointer { read(into: $0) }
        return gotFrame ? frame : nil
    }
}

// MARK: - RealTimeFrameAssembler

/// Re-chunks an arbitrary-length run of `Int16` samples into exactly
/// `frameSize`-sample frames and pushes them into a ``RealTimeRingBuffer``,
/// carrying the remainder across calls — the real-time-safe replacement for
/// ``AudioFrameChunker`` on the tap thread.
///
/// It holds the same invariant as ``AudioFrameChunker``: concatenating every
/// frame it emits, followed by the samples still held in ``pendingCount``,
/// reconstructs the exact concatenation of every input pushed, in order. It
/// differs only in *how*: one preallocated `frameSize`-sample scratch buffer
/// and a fill count, instead of a growing `Array` and `removeFirst`. Both of
/// those `Array` operations call into the allocator, which is exactly what a
/// render thread must not do.
///
/// (`AudioFrameChunker` is deliberately kept: `RealTimeFrameAssemblerTests`
/// runs the two implementations against the same input and requires identical
/// output, so the already-trusted pure implementation acts as the oracle for
/// the pointer-based one.)
///
/// Not thread-safe: like the producer half of the ring, it belongs to exactly
/// one thread.
final class RealTimeFrameAssembler {
    let frameSize: Int

    /// Preallocated carry buffer: at most `frameSize - 1` samples ever live
    /// here, but sizing it to a full frame lets the "top up and emit" path be
    /// a single `memcpy`.
    private let pending: UnsafeMutablePointer<Int16>
    private var filled: Int = 0

    init(frameSize: Int) {
        precondition(frameSize > 0, "frameSize must be positive")
        self.frameSize = frameSize
        self.pending = UnsafeMutablePointer<Int16>.allocate(capacity: frameSize)
        self.pending.initialize(repeating: 0, count: frameSize)
    }

    deinit {
        pending.deinitialize(count: frameSize)
        pending.deallocate()
    }

    /// Samples carried over from previous pushes that do not yet fill a frame.
    /// Always in `0..<frameSize`.
    var pendingCount: Int { filled }

    /// Discards any carried remainder.
    func reset() { filled = 0 }

    /// Appends `samples` and writes every complete frame that results into
    /// `ring`. **Real-time safe**: `memcpy`s within preallocated storage plus
    /// the ring's atomic counter operations.
    ///
    /// - Returns: how many frames the ring **accepted**. Frames the ring
    ///   dropped because it was full are not counted here; they are counted by
    ///   ``RealTimeRingBuffer/droppedFrameCount``.
    @discardableResult
    func push(_ samples: UnsafeBufferPointer<Int16>, into ring: RealTimeRingBuffer) -> Int {
        precondition(ring.frameSize == frameSize, "assembler and ring must agree on frame size")
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }

        let count = samples.count
        var offset = 0
        var accepted = 0

        while offset < count {
            // Fast path: nothing carried and a whole frame available — hand it
            // straight to the ring without touching the carry buffer at all.
            if filled == 0, count - offset >= frameSize {
                if ring.write(UnsafeBufferPointer(start: base + offset, count: frameSize)) {
                    accepted += 1
                }
                offset += frameSize
                continue
            }

            let take = min(frameSize - filled, count - offset)
            pending.advanced(by: filled).update(from: base + offset, count: take)
            filled += take
            offset += take

            if filled == frameSize {
                if ring.write(UnsafeBufferPointer(start: pending, count: frameSize)) {
                    accepted += 1
                }
                filled = 0
            }
        }
        return accepted
    }

    /// `Array`-flavoured entry point for tests. Allocation-free.
    @discardableResult
    func push(_ samples: [Int16], into ring: RealTimeRingBuffer) -> Int {
        samples.withUnsafeBufferPointer { push($0, into: ring) }
    }
}
