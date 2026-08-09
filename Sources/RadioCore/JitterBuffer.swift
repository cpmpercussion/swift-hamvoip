// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One received audio frame, tagged with its stream timestamp.
///
/// `timestamp` is in milliseconds and monotonically increasing per stream. It
/// is *not* required to start at zero — the first frame of a stream may carry
/// any value, and everything downstream is relative to it. Timestamp wrap
/// (2^32 ms ≈ 49 days) is out of scope here; protocol layers that truncate
/// timestamps on the wire (IAX2 mini frames) re-expand them to a full 32-bit
/// stream clock before pushing.
public struct TimedFrame: Sendable, Equatable {
    /// Milliseconds, monotonic per stream.
    public let timestamp: UInt32
    /// Encoded codec payload for this frame.
    public let payload: [UInt8]

    public init(timestamp: UInt32, payload: [UInt8]) {
        self.timestamp = timestamp
        self.payload = payload
    }
}

/// What a single `pop()` produced.
public enum JitterOutput: Sendable, Equatable {
    /// The in-sequence payload for this tick.
    case frame([UInt8])
    /// A slot with no frame available: the caller repeats/fades the last frame.
    case concealment
    /// The buffer is starving or not yet primed: the caller plays silence.
    case silence
}

/// Adaptive jitter buffer (AU-3, AU-5).
///
/// Pull model: the caller pushes frames as they arrive off the network and
/// calls ``pop()`` exactly once per frame tick (every `frameDuration` of
/// audio). The buffer holds **no clock, no timer, no thread and no task** —
/// every notion of time enters as a parameter, which is what makes it fully
/// deterministic under test (AU-5).
///
/// ## Playout model
///
/// The buffer primes until `targetDepth` worth of audio is queued, then emits
/// one slot per `pop()`. The playout grid is anchored on the first frame that
/// is emitted after priming, and advances by `frameDuration` per `pop()`:
/// `nextExpectedTimestamp` is what decides frame-versus-concealment.
///
/// - a queued frame at or before the expected timestamp is emitted (`.frame`)
/// - a queued frame *after* the expected timestamp means the expected slot is
///   missing, so the slot is concealed (`.concealment`) and the grid advances
/// - nothing queued at all is starvation: `.silence`, and the buffer un-primes
///   so it re-primes (and re-anchors the grid) on the next talk spurt
///
/// Frames older than the expected timestamp are late and dropped. Frames that
/// duplicate a timestamp already queued are dropped, keeping the first copy.
/// Out-of-order frames still inside the buffer window are reordered by
/// timestamp on insertion.
///
/// ## Adaptive depth (RC-4)
///
/// ``push(_:arrivedAt:)`` feeds an inter-arrival variation estimator. For two
/// successive in-order arrivals the buffer forms the RTP-style relative
/// transit difference
///
///     D = (arrival₂ - arrival₁) - (timestamp₂ - timestamp₁)
///
/// — i.e. how much the network stretched or compressed the gap the sender
/// intended — and tracks its mean absolute value with an exponentially
/// weighted moving average:
///
///     deviation ← deviation + α · (|D| - deviation),  α = 1/8
///
/// Using the *timestamp* difference rather than a flat `frameDuration` means a
/// gap in the stream (a talk-spurt boundary, or a burst that was lost outright)
/// contributes ≈ 0 rather than a spurious spike. Out-of-order arrivals produce
/// no sample at all.
///
/// The candidate target depth is `clamp(k · deviation, minDepth, maxDepth)`
/// with `k = adaptationGain` (default 4). It is only *applied* at a talk-spurt
/// boundary — after at least `talkSpurtGap` (200 ms) of continuous `.silence`
/// output — never mid-stream, because changing depth while audio is playing
/// out means dropping or duplicating audible frames.
public struct JitterBuffer: Sendable {
    // MARK: Configuration

    /// Duration of one frame of audio; also one `pop()` tick.
    public let frameDuration: Duration
    /// Lower bound on the adaptive target depth (AU-3).
    public let minDepth: Duration
    /// Upper bound on the adaptive target depth (AU-3).
    public let maxDepth: Duration
    /// `k` in `targetDepth = clamp(k · deviation, minDepth, maxDepth)`.
    public let adaptationGain: Double
    /// How much continuous `.silence` output counts as a talk-spurt boundary.
    public let talkSpurtGap: Duration

    /// Smoothing factor of the deviation EWMA.
    private static let smoothing = 0.125

    // MARK: Derived configuration (milliseconds, to keep the arithmetic exact)

    private let frameMillis: Double
    private let frameStep: UInt32
    private let minDepthMillis: Double
    private let maxDepthMillis: Double
    private let talkSpurtGapMillis: Double

    // MARK: State

    /// Queued frames, always sorted by ascending timestamp, no duplicates.
    private var queue: [TimedFrame] = []
    /// Timestamp of the slot the next `pop()` will emit. `nil` until priming.
    private var nextExpected: UInt32?
    private var primed = false
    private var currentTargetMillis: Double
    private var deviationMillis: Double = 0
    /// Arrival time and timestamp of the newest in-order arrival seen.
    private var lastArrivalMillis: Double?
    private var lastArrivalTimestamp: UInt32?
    /// Length of the current unbroken run of `.silence` output.
    private var silenceRunMillis: Double = 0

    // MARK: Init

    /// - Parameters:
    ///   - frameDuration: audio per frame and per `pop()` tick (20 ms for every
    ///     codec in scope).
    ///   - targetDepth: initial target depth, clamped into
    ///     `minDepth...maxDepth`. Adaptation replaces it at the first talk-spurt
    ///     boundary once arrival times are being supplied.
    ///   - minDepth: floor on the adaptive target depth.
    ///   - maxDepth: ceiling on the adaptive target depth.
    ///   - adaptationGain: `k`, the multiplier on the measured deviation.
    ///   - talkSpurtGap: continuous `.silence` required before a depth change
    ///     takes effect.
    public init(
        frameDuration: Duration = .milliseconds(20),
        targetDepth: Duration = .milliseconds(60),
        minDepth: Duration = .milliseconds(60),
        maxDepth: Duration = .milliseconds(200),
        adaptationGain: Double = 4.0,
        talkSpurtGap: Duration = .milliseconds(200)
    ) {
        precondition(frameDuration > .zero, "frameDuration must be positive")
        precondition(minDepth <= maxDepth, "minDepth must not exceed maxDepth")

        self.frameDuration = frameDuration
        self.minDepth = minDepth
        self.maxDepth = maxDepth
        self.adaptationGain = adaptationGain
        self.talkSpurtGap = talkSpurtGap

        let frameMillis = Self.milliseconds(frameDuration)
        precondition(frameMillis >= 1, "frameDuration must be at least 1 ms")
        self.frameMillis = frameMillis
        self.frameStep = UInt32(frameMillis.rounded())
        self.minDepthMillis = Self.milliseconds(minDepth)
        self.maxDepthMillis = Self.milliseconds(maxDepth)
        self.talkSpurtGapMillis = Self.milliseconds(talkSpurtGap)
        self.currentTargetMillis = min(
            max(Self.milliseconds(targetDepth), Self.milliseconds(minDepth)),
            Self.milliseconds(maxDepth)
        )
    }

    // MARK: Read-only state

    /// Target depth currently in force. Only changes at talk-spurt boundaries.
    public var currentTargetDepth: Duration {
        Self.duration(milliseconds: currentTargetMillis)
    }

    /// Audio currently queued (frame count × `frameDuration`).
    public var depth: Duration {
        Self.duration(milliseconds: Double(queue.count) * frameMillis)
    }

    /// Number of frames currently queued.
    public var queuedFrameCount: Int { queue.count }

    /// `true` once enough audio has been queued to start playing out.
    public var isPrimed: Bool { primed }

    /// Current mean absolute inter-arrival variation estimate.
    public var arrivalDeviation: Duration {
        Self.duration(milliseconds: deviationMillis)
    }

    /// Timestamp the next `pop()` expects, once the buffer has primed.
    public var nextExpectedTimestamp: UInt32? { nextExpected }

    // MARK: Push

    /// Queue a frame and feed the inter-arrival estimator.
    ///
    /// - Parameter arrivedAt: monotonic offset from an arbitrary origin chosen
    ///   by the caller (e.g. `ContinuousClock.now - streamStart`). Only
    ///   differences between successive values matter, so the origin is free.
    public mutating func push(_ frame: TimedFrame, arrivedAt: Duration) {
        updateEstimator(timestamp: frame.timestamp, arrivedAtMillis: Self.milliseconds(arrivedAt))
        enqueue(frame)
    }

    /// Queue a frame without an arrival time.
    ///
    /// The estimator is left untouched, so the target depth stays wherever it
    /// is. Useful for replaying a recorded frame sequence where only ordering
    /// matters.
    public mutating func push(_ frame: TimedFrame) {
        enqueue(frame)
    }

    private mutating func enqueue(_ frame: TimedFrame) {
        // Late: its slot has already been played out.
        if let expected = nextExpected, frame.timestamp < expected { return }
        // Duplicate: keep the first copy, drop the rest.
        let index = insertionIndex(for: frame.timestamp)
        if index < queue.count, queue[index].timestamp == frame.timestamp { return }
        queue.insert(frame, at: index)
    }

    /// First index whose timestamp is >= `timestamp` (binary search).
    private func insertionIndex(for timestamp: UInt32) -> Int {
        var low = 0
        var high = queue.count
        while low < high {
            let mid = (low + high) / 2
            if queue[mid].timestamp < timestamp {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private mutating func updateEstimator(timestamp: UInt32, arrivedAtMillis: Double) {
        guard let previousArrival = lastArrivalMillis,
              let previousTimestamp = lastArrivalTimestamp
        else {
            lastArrivalMillis = arrivedAtMillis
            lastArrivalTimestamp = timestamp
            return
        }
        // Out-of-order arrival: no usable sample, and the reference stays on
        // the newest timestamp seen.
        guard timestamp > previousTimestamp else { return }

        let transit = (arrivedAtMillis - previousArrival) - Double(timestamp - previousTimestamp)
        deviationMillis += Self.smoothing * (abs(transit) - deviationMillis)
        lastArrivalMillis = arrivedAtMillis
        lastArrivalTimestamp = timestamp
    }

    // MARK: Pop

    /// Produce the output for one frame tick. Call exactly once per
    /// `frameDuration` of playout.
    public mutating func pop() -> JitterOutput {
        if !primed {
            guard let head = queue.first,
                  Double(queue.count) * frameMillis >= currentTargetMillis
            else {
                return emitSilence()
            }
            // Re-anchor the playout grid on the first frame of the new spurt,
            // so a resumption after starvation does not conceal the gap.
            primed = true
            nextExpected = head.timestamp
        }

        guard let expected = nextExpected else { return emitSilence() }

        guard let head = queue.first else {
            // Starved: fall back to priming for the next talk spurt.
            primed = false
            return emitSilence()
        }

        silenceRunMillis = 0

        if head.timestamp > expected {
            // The expected slot never showed up.
            nextExpected = expected &+ frameStep
            return .concealment
        }

        queue.removeFirst()
        nextExpected = head.timestamp &+ frameStep
        return .frame(head.payload)
    }

    private mutating func emitSilence() -> JitterOutput {
        silenceRunMillis += frameMillis
        if silenceRunMillis >= talkSpurtGapMillis {
            // Talk-spurt boundary: safe to retarget.
            currentTargetMillis = min(
                max(adaptationGain * deviationMillis, minDepthMillis),
                maxDepthMillis
            )
        }
        return .silence
    }

    // MARK: Duration <-> milliseconds

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private static func duration(milliseconds: Double) -> Duration {
        .microseconds(Int64((milliseconds * 1_000).rounded()))
    }
}
