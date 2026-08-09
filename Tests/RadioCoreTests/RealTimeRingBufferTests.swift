// SPDX-License-Identifier: Apache-2.0

import Darwin
import XCTest
@testable import RadioCore

// MARK: - Allocation counting harness

/// Counts heap allocations made **on the calling thread** while a block runs.
///
/// RC-9's central claim is "the microphone tap does not allocate". That claim
/// is worth very little if it is only ever checked by reading the code, because
/// the allocations that matter are the ones nobody meant to write: a Swift
/// `Array` that quietly grows, a closure that gets boxed on the heap because
/// the API it is passed to forgot `NS_NOESCAPE`. Both of those happened in the
/// code RC-9 replaces, and neither is visible at the call site.
///
/// So it is checked mechanically. `libmalloc` exports a global hook,
/// `malloc_logger`, which it calls on every allocation and free — it is the
/// mechanism behind `MallocStackLogging`. Installing our own hook and filtering
/// by thread gives an exact count of allocations performed by the code under
/// test, with no sampling and no tolerance.
///
/// Constraints this harness respects, because the hook runs *inside* the
/// allocator and must not itself allocate or re-enter it:
///
/// * the hook is a bare `@convention(c)` function with no captured context;
/// * all of its state lives in one raw allocation made ahead of time;
/// * every Swift global it touches is forced through its lazy initialiser
///   before the hook is installed (`prime()`), so no `swift_once` initialiser
///   can run from inside `malloc`;
/// * it is disarmed and the previous hook restored immediately afterwards.
///
/// Returns `nil` — rather than lying — if `malloc_logger` is not exported by
/// the runtime the tests happen to be running on. Callers should `XCTSkip`.
///
/// ### One trap, recorded so nobody rediscovers it
///
/// Every measured loop in this file is a `while` loop, deliberately. `swift
/// test` builds unoptimised, and in an unoptimised build `for _ in 0..<n`
/// performs **one heap allocation per iteration** on its own — the range's
/// iterator goes through unspecialised generic code — before the loop body does
/// anything at all. Measured here: an empty `for` loop of 1000 iterations
/// allocates exactly 1000 times; the identical `while` loop allocates zero.
/// Counting the loop as if it were the code under test would have made every
/// assertion below fail for a reason with nothing to do with audio.
enum AllocationCounter {
    private typealias LoggerFunction =
        @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `[0]` running count, `[1]` armed flag, `[2]` mach port of the watched
    /// thread. A raw allocation, not a Swift global, so the hook can touch it
    /// without going through anything that might allocate.
    private static let slots: UnsafeMutablePointer<UInt> = {
        let pointer = UnsafeMutablePointer<UInt>.allocate(capacity: 3)
        pointer.initialize(repeating: 0, count: 3)
        return pointer
    }()

    /// The hook cannot capture, so it reaches `slots` through this.
    private static var slotsAddress: UInt = 0

    private static let logger: LoggerFunction = { _, _, _, _, result, _ in
        // Only allocations (a non-zero returned address); frees report zero.
        guard result != 0 else { return }
        guard let slots = UnsafeMutablePointer<UInt>(bitPattern: slotsAddress) else { return }
        guard slots[1] != 0 else { return }
        guard UInt(pthread_mach_thread_np(pthread_self())) == slots[2] else { return }
        slots[0] &+= 1
    }

    private static let loggerSlot: UnsafeMutablePointer<LoggerFunction?>? = {
        // RTLD_DEFAULT
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
            return nil
        }
        return symbol.assumingMemoryBound(to: LoggerFunction?.self)
    }()

    /// Forces every lazy global this type owns through its initialiser, so that
    /// none of them can run — and allocate — from inside the hook.
    private static func prime() {
        slotsAddress = UInt(bitPattern: slots)
        _ = logger
        _ = loggerSlot
    }

    /// Whether mechanical counting is possible in this process.
    static var isAvailable: Bool {
        prime()
        return loggerSlot != nil
    }

    /// - Returns: the number of heap allocations `body` performed on the
    ///   calling thread, or `nil` if the runtime does not expose the hook.
    static func measure(_ body: () -> Void) -> Int? {
        prime()
        guard let slot = loggerSlot else { return nil }

        let previous = slot.pointee
        slots[0] = 0
        slots[2] = UInt(pthread_mach_thread_np(pthread_self()))
        slot.pointee = logger
        slots[1] = 1

        body()

        slots[1] = 0
        slot.pointee = previous
        return Int(slots[0])
    }

    /// Sanity check on the harness itself: assert that a known-allocating block
    /// is actually seen. A counter that always returns zero would make every
    /// no-allocation test vacuously pass, which is the one failure this harness
    /// must not have.
    static func selfCheck() -> (allocating: Int, quiet: Int)? {
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 256)
        defer { scratch.deallocate() }
        scratch.initialize(repeating: 0, count: 256)

        var sink: [[Int16]] = []
        sink.reserveCapacity(64)
        for _ in 0..<64 { sink.append([Int16](repeating: 1, count: 64)) }
        sink.removeAll(keepingCapacity: true)

        guard let allocating = measure({
            var index = 0
            while index < 64 {
                sink.append([Int16](repeating: Int16(index), count: 64))
                index += 1
            }
        }) else { return nil }

        guard let quiet = measure({
            var index = 0
            while index < 64 {
                scratch.update(repeating: 3, count: 256)
                index += 1
            }
        }) else { return nil }

        _ = sink.count
        return (allocating, quiet)
    }
}

/// Deterministic PRNG for the randomised-but-seeded tests. Nothing in this file
/// may use `Int.random` or `SystemRandomNumberGenerator`.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
}

// MARK: - RealTimeRingBuffer

/// The handoff between the real-time audio thread and everything else. If this
/// type is wrong, audio is silently lost or silently duplicated, so it is
/// tested harder than anything else in RC-9: ordering, wraparound,
/// fill-to-capacity, the overrun policy and its counter, empty drains, a
/// seeded randomised interleaving checked against a reference model, and a
/// genuinely concurrent producer/consumer run.
///
/// No audio hardware, no permissions, no `AVAudioEngine` — this is pointers and
/// atomics.
final class RealTimeRingBufferTests: XCTestCase {
    private let frameSize = 8

    /// A frame whose every sample is derived from `index`, so a lost,
    /// duplicated, or reordered frame is detectable by value.
    private func frame(_ index: Int, size: Int? = nil) -> [Int16] {
        let count = size ?? frameSize
        return (0..<count).map { Int16(truncatingIfNeeded: index &* 31 &+ $0) }
    }

    // MARK: Ordering

    func testWriteThenReadReturnsTheSameSamples() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 4)
        XCTAssertTrue(ring.write(frame(1)))
        XCTAssertEqual(ring.readFrame(), frame(1))
    }

    func testFramesComeBackInWriteOrder() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 16)
        for index in 0..<16 {
            XCTAssertTrue(ring.write(frame(index)))
        }
        for index in 0..<16 {
            XCTAssertEqual(ring.readFrame(), frame(index), "frame \(index) came back out of order")
        }
        XCTAssertNil(ring.readFrame())
    }

    func testWrapsAroundManyTimesWithoutCorruption() {
        // Capacity 3 with 1000 write/read cycles: the write index laps the
        // read index 333 times, so every slot is reused repeatedly.
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 3)
        for index in 0..<1_000 {
            XCTAssertTrue(ring.write(frame(index)), "write \(index) was refused on an empty ring")
            XCTAssertEqual(ring.readFrame(), frame(index), "wraparound corrupted frame \(index)")
        }
        XCTAssertEqual(ring.droppedFrameCount, 0)
        XCTAssertEqual(ring.writtenFrameCount, 1_000)
        XCTAssertEqual(ring.readFrameCount, 1_000)
    }

    func testInterleavedWritesAndReadsAcrossTheWrapPoint() {
        // Keep the ring partially full so reads and writes straddle the
        // modulo boundary rather than always starting from slot 0.
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 5)
        var nextWrite = 0
        var nextRead = 0
        for _ in 0..<400 {
            for _ in 0..<3 where !ring.isFull {
                XCTAssertTrue(ring.write(frame(nextWrite)))
                nextWrite += 1
            }
            for _ in 0..<2 {
                if let read = ring.readFrame() {
                    XCTAssertEqual(read, frame(nextRead))
                    nextRead += 1
                }
            }
        }
        while let read = ring.readFrame() {
            XCTAssertEqual(read, frame(nextRead))
            nextRead += 1
        }
        XCTAssertEqual(nextRead, nextWrite)
        XCTAssertEqual(ring.droppedFrameCount, 0)
    }

    // MARK: Capacity

    func testFillsToCapacityExactly() {
        let capacity = 8
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: capacity)
        XCTAssertFalse(ring.isFull)
        for index in 0..<capacity {
            XCTAssertTrue(ring.write(frame(index)), "ring refused frame \(index) before capacity")
            XCTAssertEqual(ring.availableFrames, index + 1)
        }
        XCTAssertTrue(ring.isFull)
        XCTAssertEqual(ring.availableFrames, capacity)
        XCTAssertEqual(ring.droppedFrameCount, 0)
    }

    // MARK: Overrun policy — drop newest, count it

    func testOverrunDropsTheNewestFrameAndCountsIt() {
        let capacity = 4
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: capacity)
        for index in 0..<capacity {
            XCTAssertTrue(ring.write(frame(index)))
        }

        // The policy is drop-newest: this frame never enters the ring.
        XCTAssertFalse(ring.write(frame(999)), "a full ring must refuse the incoming frame")
        XCTAssertEqual(ring.droppedFrameCount, 1)
        XCTAssertEqual(ring.availableFrames, capacity, "a dropped frame must not consume a slot")
        XCTAssertEqual(ring.writtenFrameCount, capacity, "a dropped frame must not count as written")

        // The frames already buffered are intact, in order, and the dropped
        // one is nowhere to be seen.
        for index in 0..<capacity {
            XCTAssertEqual(ring.readFrame(), frame(index), "overrun disturbed buffered frame \(index)")
        }
        XCTAssertNil(ring.readFrame())
    }

    func testDroppedCounterAccumulatesAcrossManyOverruns() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 2)
        XCTAssertTrue(ring.write(frame(0)))
        XCTAssertTrue(ring.write(frame(1)))
        for _ in 0..<50 {
            XCTAssertFalse(ring.write(frame(99)))
        }
        XCTAssertEqual(ring.droppedFrameCount, 50)
        XCTAssertEqual(ring.availableFrames, 2)
    }

    func testASingleReadReleasesExactlyOneSlotAfterOverrun() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 2)
        XCTAssertTrue(ring.write(frame(0)))
        XCTAssertTrue(ring.write(frame(1)))
        XCTAssertFalse(ring.write(frame(2)))

        XCTAssertEqual(ring.readFrame(), frame(0))
        XCTAssertTrue(ring.write(frame(3)), "the slot freed by a read must be reusable")
        XCTAssertFalse(ring.write(frame(4)))
        XCTAssertEqual(ring.droppedFrameCount, 2)

        XCTAssertEqual(ring.readFrame(), frame(1))
        XCTAssertEqual(ring.readFrame(), frame(3))
        XCTAssertNil(ring.readFrame())
    }

    // MARK: Empty

    func testReadOnAnEmptyRingReportsFailureAndLeavesTheDestinationAlone() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 4)
        var destination = [Int16](repeating: -1, count: frameSize)
        let gotFrame = destination.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        XCTAssertFalse(gotFrame)
        XCTAssertEqual(destination, [Int16](repeating: -1, count: frameSize))
        XCTAssertNil(ring.readFrame())
        XCTAssertEqual(ring.availableFrames, 0)
    }

    func testDrainingToEmptyThenRefillingWorks() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 4)
        for round in 0..<20 {
            for index in 0..<4 {
                XCTAssertTrue(ring.write(frame(round * 4 + index)))
            }
            for index in 0..<4 {
                XCTAssertEqual(ring.readFrame(), frame(round * 4 + index))
            }
            XCTAssertNil(ring.readFrame())
        }
    }

    // MARK: Randomised (seeded) interleaving against a reference model

    /// Drives the ring with a seeded pseudo-random mix of writes and reads and
    /// checks it against a trivially correct `Array`-based model with the same
    /// capacity and the same drop-newest rule. Deterministic: the same seed
    /// produces the same 20 000 operations on every run and on every machine.
    func testSeededRandomInterleavingMatchesAReferenceModel() {
        let capacity = 6
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: capacity)
        var model: [[Int16]] = []
        var modelDropped = 0
        var random = SeededRandom(seed: 0x5EED_0000_0C90_0001)

        var nextValue = 0
        for step in 0..<20_000 {
            if random.next(upperBound: 100) < 55 {
                let payload = frame(nextValue)
                nextValue += 1
                let accepted = ring.write(payload)
                if model.count < capacity {
                    XCTAssertTrue(accepted, "ring refused a write the model accepted at step \(step)")
                    model.append(payload)
                } else {
                    XCTAssertFalse(accepted, "ring accepted a write the model dropped at step \(step)")
                    modelDropped += 1
                }
            } else {
                let read = ring.readFrame()
                if model.isEmpty {
                    XCTAssertNil(read, "ring produced a frame the model did not have at step \(step)")
                } else {
                    XCTAssertEqual(read, model.removeFirst(), "divergence at step \(step)")
                }
            }
            XCTAssertEqual(ring.availableFrames, model.count, "occupancy diverged at step \(step)")
            XCTAssertEqual(ring.droppedFrameCount, modelDropped, "drop count diverged at step \(step)")
        }

        while let read = ring.readFrame() {
            XCTAssertEqual(read, model.removeFirst())
        }
        XCTAssertTrue(model.isEmpty)
    }

    // MARK: Genuine concurrency

    /// The single-threaded tests above exercise the bookkeeping; this one
    /// exercises the atomics. One producer thread and one consumer thread run
    /// flat out against a small ring, and every frame must arrive exactly once,
    /// in order, with its payload intact.
    ///
    /// The outcome is deterministic even though the timing is not: the producer
    /// retries instead of dropping, so the ring must deliver all 20 000 frames
    /// in sequence no matter how the two threads interleave. A torn payload, a
    /// missed wake-up, or a reordered counter update all show up as a mismatch,
    /// not as a flake.
    func testConcurrentProducerAndConsumerPreserveEveryFrameInOrder() {
        let total = 20_000
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 16)
        let finished = DispatchSemaphore(value: 0)
        let mismatch = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        mismatch.initialize(repeating: -1, count: 2)
        defer { mismatch.deallocate() }

        DispatchQueue.global(qos: .userInitiated).async { [frameSize] in
            var payload = [Int16](repeating: 0, count: frameSize)
            for index in 0..<total {
                for offset in 0..<frameSize {
                    payload[offset] = Int16(truncatingIfNeeded: index &* 31 &+ offset)
                }
                // Wait for a free slot rather than letting the write be
                // dropped, so the expected outcome is exact. Safe without any
                // extra synchronisation: this is the only producer, so
                // occupancy can only fall between the check and the write.
                while ring.isFull { sched_yield() }
                let accepted = payload.withUnsafeBufferPointer { ring.write($0) }
                if !accepted, mismatch[0] < 0 {
                    mismatch[0] = index
                    mismatch[1] = -2 // "write refused after isFull said otherwise"
                }
            }
            finished.signal()
        }

        DispatchQueue.global(qos: .userInitiated).async { [frameSize] in
            var payload = [Int16](repeating: 0, count: frameSize)
            var index = 0
            while index < total {
                if payload.withUnsafeMutableBufferPointer({ ring.read(into: $0) }) {
                    for offset in 0..<frameSize
                    where payload[offset] != Int16(truncatingIfNeeded: index &* 31 &+ offset) {
                        if mismatch[0] < 0 {
                            mismatch[0] = index
                            mismatch[1] = offset
                        }
                    }
                    index += 1
                } else {
                    sched_yield()
                }
            }
            finished.signal()
        }

        for _ in 0..<2 {
            XCTAssertEqual(
                finished.wait(timeout: .now() + 30), .success,
                "the lock-free handoff stalled — a producer or consumer never completed"
            )
        }
        XCTAssertLessThan(mismatch[0], 0, "frame \(mismatch[0]) sample \(mismatch[1]) was corrupted or out of order")
        XCTAssertEqual(ring.droppedFrameCount, 0, "the retrying producer must never have dropped a frame")
        XCTAssertEqual(ring.writtenFrameCount, total)
        XCTAssertEqual(ring.readFrameCount, total)
    }

    // MARK: Frame size independence

    func testWorksAtTheProductionFrameSize() {
        let ring = RealTimeRingBuffer(
            frameSize: AudioPipeline.captureFrameSize,
            capacity: AudioPipeline.captureRingCapacityFrames
        )
        XCTAssertEqual(ring.frameSize, 160)
        XCTAssertEqual(ring.capacity, 100)
        for index in 0..<100 {
            XCTAssertTrue(ring.write(frame(index, size: 160)))
        }
        XCTAssertFalse(ring.write(frame(100, size: 160)))
        for index in 0..<100 {
            XCTAssertEqual(ring.readFrame(), frame(index, size: 160))
        }
    }
}

// MARK: - RealTimeFrameAssembler

/// The tap-thread replacement for ``AudioFrameChunker``. It must hold exactly
/// the same invariant — no sample lost, duplicated, or reordered — while doing
/// it inside preallocated storage, so most of these tests check it *against*
/// `AudioFrameChunker` rather than against a hand-written expectation.
final class RealTimeFrameAssemblerTests: XCTestCase {
    private let frameSize = AudioPipeline.captureFrameSize // 160

    private func markers(_ range: Range<Int>) -> [Int16] {
        range.map { Int16(truncatingIfNeeded: $0) }
    }

    /// Pushes `chunkSizes` through the assembler and reconstructs the stream
    /// from the frames the ring received plus whatever remains pending.
    private func assertReconstructs(
        chunkSizes: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let totalPushed = chunkSizes.reduce(0, +)
        // Capacity generous enough that nothing is dropped: this test is about
        // the chunking invariant, not the overrun policy.
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: totalPushed / frameSize + 8)
        let assembler = RealTimeFrameAssembler(frameSize: frameSize)

        var cursor = 0
        var reconstructed: [Int16] = []
        for size in chunkSizes {
            let input = markers(cursor..<(cursor + size))
            cursor += size
            assembler.push(input, into: ring)
            while let emitted = ring.readFrame() {
                XCTAssertEqual(emitted.count, frameSize, file: file, line: line)
                reconstructed.append(contentsOf: emitted)
            }
        }

        XCTAssertEqual(ring.droppedFrameCount, 0, "test ring was undersized", file: file, line: line)
        XCTAssertEqual(
            reconstructed.count + assembler.pendingCount, totalPushed,
            "samples went missing or were duplicated", file: file, line: line
        )
        XCTAssertEqual(
            reconstructed, markers(0..<reconstructed.count),
            "reconstruction lost, duplicated, or reordered samples", file: file, line: line
        )
        XCTAssertEqual(assembler.pendingCount, totalPushed % frameSize, file: file, line: line)
    }

    func testManyDifferentChunkSizesReconstructExactly() {
        assertReconstructs(chunkSizes: [1, 159, 160, 161, 480, 1024, 2, 3, 5, 7, 11, 13, 17, 19, 23, 97, 101, 997, 1009])
    }

    func testSingleSampleChunksReconstructExactly() {
        assertReconstructs(chunkSizes: Array(repeating: 1, count: 500))
    }

    func testExactMultipleChunksLeaveNoRemainder() {
        assertReconstructs(chunkSizes: [frameSize * 4])
    }

    func testEmptyPushEmitsNothingAndKeepsTheRemainder() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 4)
        let assembler = RealTimeFrameAssembler(frameSize: frameSize)
        assembler.push(markers(0..<50), into: ring)
        XCTAssertEqual(assembler.push([], into: ring), 0)
        XCTAssertEqual(ring.availableFrames, 0)
        XCTAssertEqual(assembler.pendingCount, 50)
    }

    func testNoFrameEmittedUntilFrameSizeIsReached() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 4)
        let assembler = RealTimeFrameAssembler(frameSize: frameSize)
        XCTAssertEqual(assembler.push(markers(0..<(frameSize - 1)), into: ring), 0)
        XCTAssertNil(ring.readFrame())
        XCTAssertEqual(assembler.pendingCount, frameSize - 1)
        XCTAssertEqual(assembler.push(markers(0..<1), into: ring), 1)
        XCTAssertEqual(ring.availableFrames, 1)
        XCTAssertEqual(assembler.pendingCount, 0)
    }

    func testResetDiscardsTheRemainder() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 4)
        let assembler = RealTimeFrameAssembler(frameSize: frameSize)
        assembler.push(markers(0..<50), into: ring)
        assembler.reset()
        XCTAssertEqual(assembler.pendingCount, 0)
        assembler.push(markers(0..<frameSize), into: ring)
        XCTAssertEqual(ring.readFrame(), markers(0..<frameSize))
    }

    /// **The differential test.** `AudioFrameChunker` is the pure, allocating,
    /// already-trusted statement of the chunking invariant; the assembler is
    /// the pointer-arithmetic version that runs on the render thread. Given the
    /// same seeded sequence of oddly-sized pushes, they must emit byte-identical
    /// frames in the same order and carry the same remainder. Any off-by-one in
    /// the wrap/top-up logic shows up here immediately.
    func testAssemblerAgreesWithAudioFrameChunkerOnSeededRandomInput() {
        var random = SeededRandom(seed: 0xA55E_3B1E_0000_0009)
        var sizes: [Int] = []
        for _ in 0..<400 { sizes.append(random.next(upperBound: 2_000)) }

        let totalPushed = sizes.reduce(0, +)
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: totalPushed / frameSize + 8)
        let assembler = RealTimeFrameAssembler(frameSize: frameSize)
        var chunker = AudioFrameChunker(frameSize: frameSize)

        var cursor = 0
        for size in sizes {
            let input = markers(cursor..<(cursor + size))
            cursor += size

            let expected = chunker.push(input)
            assembler.push(input, into: ring)

            var actual: [[Int16]] = []
            while let emitted = ring.readFrame() { actual.append(emitted) }

            XCTAssertEqual(actual, expected, "assembler and chunker disagreed on a push of \(size) samples")
            XCTAssertEqual(assembler.pendingCount, chunker.pending.count, "remainders diverged")
        }
        XCTAssertEqual(ring.droppedFrameCount, 0)
    }

    func testFramesDroppedByAFullRingAreNotReportedAsAccepted() {
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: 3)
        let assembler = RealTimeFrameAssembler(frameSize: frameSize)
        // Ten frames' worth of samples into a three-frame ring.
        let accepted = assembler.push(markers(0..<(frameSize * 10)), into: ring)
        XCTAssertEqual(accepted, 3, "only the frames that fit may be reported as accepted")
        XCTAssertEqual(ring.droppedFrameCount, 7)
        XCTAssertEqual(ring.availableFrames, 3)
        // Drop-newest: the ring holds the *first* three frames.
        for index in 0..<3 {
            XCTAssertEqual(ring.readFrame(), markers((index * frameSize)..<((index + 1) * frameSize)))
        }
    }
}

// MARK: - Allocation behaviour

/// Mechanical evidence for RC-9's core claim. See ``AllocationCounter`` for how
/// the counting works and why it is trustworthy.
final class RealTimeAllocationTests: XCTestCase {
    /// If this fails, every other test in this class is meaningless.
    func testTheAllocationCounterActuallyDetectsAllocations() throws {
        guard let result = AllocationCounter.selfCheck() else {
            throw XCTSkip("malloc_logger is not exported in this runtime; allocation counting unavailable")
        }
        XCTAssertGreaterThanOrEqual(
            result.allocating, 64,
            "the counter missed 64 array allocations — it is not measuring anything"
        )
        XCTAssertEqual(result.quiet, 0, "a pure memcpy loop must not allocate")
    }

    func testRingBufferHotPathDoesNotAllocate() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger unavailable")

        let ring = RealTimeRingBuffer(
            frameSize: AudioPipeline.captureFrameSize,
            capacity: AudioPipeline.captureRingCapacityFrames
        )
        var source = [Int16](repeating: 0, count: AudioPipeline.captureFrameSize)
        for index in 0..<source.count { source[index] = Int16(truncatingIfNeeded: index) }
        var sink = [Int16](repeating: 0, count: AudioPipeline.captureFrameSize)

        // Warm up: first-touch lazy initialisation is a real allocation, but it
        // happens once per process, not once per audio callback.
        for _ in 0..<500 {
            _ = source.withUnsafeBufferPointer { ring.write($0) }
            _ = sink.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        }

        let allocations = AllocationCounter.measure {
            var iteration = 0
            while iteration < 10_000 {
                _ = source.withUnsafeBufferPointer { ring.write($0) }
                _ = sink.withUnsafeMutableBufferPointer { ring.read(into: $0) }
                iteration += 1
            }
        }
        XCTAssertEqual(allocations, 0, "the ring buffer allocated on its hot path")
    }

    func testOverrunPathDoesNotAllocate() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger unavailable")

        // A permanently full ring, so every write takes the drop branch.
        let ring = RealTimeRingBuffer(frameSize: 160, capacity: 2)
        let source = [Int16](repeating: 5, count: 160)
        _ = source.withUnsafeBufferPointer { ring.write($0) }
        _ = source.withUnsafeBufferPointer { ring.write($0) }
        for _ in 0..<500 { _ = source.withUnsafeBufferPointer { ring.write($0) } }

        let allocations = AllocationCounter.measure {
            var iteration = 0
            while iteration < 10_000 {
                _ = source.withUnsafeBufferPointer { ring.write($0) }
                iteration += 1
            }
        }
        XCTAssertEqual(allocations, 0, "dropping a frame must be as allocation-free as accepting one")
        XCTAssertGreaterThan(ring.droppedFrameCount, 10_000)
    }

    func testFrameAssemblerDoesNotAllocate() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger unavailable")

        let ring = RealTimeRingBuffer(frameSize: 160, capacity: 64)
        let assembler = RealTimeFrameAssembler(frameSize: 160)
        // 137 is deliberately not a multiple of 160, so every push exercises
        // both the carry-buffer top-up path and the whole-frame fast path.
        var source = [Int16](repeating: 0, count: 137)
        for index in 0..<source.count { source[index] = Int16(truncatingIfNeeded: index) }
        var sink = [Int16](repeating: 0, count: 160)

        for _ in 0..<500 {
            _ = source.withUnsafeBufferPointer { assembler.push($0, into: ring) }
            while sink.withUnsafeMutableBufferPointer({ ring.read(into: $0) }) {}
        }

        let allocations = AllocationCounter.measure {
            var iteration = 0
            while iteration < 10_000 {
                _ = source.withUnsafeBufferPointer { assembler.push($0, into: ring) }
                while sink.withUnsafeMutableBufferPointer({ ring.read(into: $0) }) {}
                iteration += 1
            }
        }
        XCTAssertEqual(allocations, 0, "the frame assembler allocated on its hot path")
    }
}
