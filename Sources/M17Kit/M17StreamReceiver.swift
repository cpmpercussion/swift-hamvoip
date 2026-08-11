// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

/// One tick of receiver output.
public struct M17StreamPlayout: Sendable, Equatable {

    /// What produced this tick's samples.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// Real decoded audio.
        case audio
        /// The codec frame for this slot never arrived; the previous frame is
        /// repeated, fading, for a short run.
        case concealment
        /// Nothing is playing — priming, starved, or the over has ended.
        case silence
    }

    public let kind: Kind
    /// 8 kHz mono signed 16-bit PCM, always one codec frame long.
    public let pcm: [Int16]

    public init(kind: Kind, pcm: [Int16]) {
        self.kind = kind
        self.pcm = pcm
    }
}

/// Turns received M17 stream datagrams into a steady stream of PCM.
///
/// Pure state, driven entirely by the caller: **no clock, no timer, no task.**
/// Datagrams go in with ``receive(_:arrivedAt:)``; PCM comes out of ``pop()``,
/// called once per 20 ms tick. That is what lets a recorded sequence be
/// replayed deterministically (AU-5). Mirrors `IAX2VoiceReceiver`.
///
/// The chain is: reject what must not be played → expand FN past its 15-bit
/// wrap → split the 16-byte payload into its two 20 ms codec frames → push
/// both into `JitterBuffer`, which reorders, drops duplicates and late frames
/// and decides per tick between a frame, a concealment and silence → decode
/// with the supplied codec.
///
/// ## Three reasons a datagram is refused
///
/// - **A failed CRC.** The M17-4 CRC is what makes this possible; before it,
///   a corrupt datagram was indistinguishable from a good one.
/// - **Encryption.** FR-2.5 is absolute: an encrypted stream is never played,
///   and there is no key parameter anywhere to change that.
/// - **A stream that is not this one.** A datagram whose SID differs from the
///   over in progress is a different transmission.
public struct M17StreamReceiver: Sendable {

    /// Why a datagram was not queued.
    public enum Rejection: Sendable, Equatable, CustomStringConvertible {
        /// The whole-datagram CRC did not check (M17-4).
        case crcFailed(carried: UInt16, computed: UInt16)
        /// The TYPE field says encrypted, so it is never played (FR-2.5).
        case encrypted
        /// The payload is not a whole number of codec frames.
        case malformedPayload(payloadBytes: Int, codecFrameBytes: Int)
        /// Belongs to a different stream than the one in progress.
        case wrongStream(expected: UInt16, actual: UInt16)

        public var description: String {
            switch self {
            case .crcFailed(let carried, let computed):
                return String(format: "CRC failed: carried 0x%04X, computed 0x%04X", carried, computed)
            case .encrypted:
                return "encrypted stream — never played (FR-2.5)"
            case .malformedPayload(let payload, let frame):
                return "payload of \(payload) bytes is not whole \(frame)-byte codec frames"
            case .wrongStream(let expected, let actual):
                return String(format: "stream 0x%04X, but 0x%04X is in progress", actual, expected)
            }
        }
    }

    /// What ``receive(_:arrivedAt:)`` did with a datagram.
    public enum Reception: Sendable, Equatable {
        /// Queued for playout.
        case accepted
        /// Queued, and it started a new over — the previous one, if any, was
        /// abandoned and the buffer reset.
        case acceptedNewStream(streamID: UInt16, source: M17Address)
        /// Queued, and it carried the last-frame flag.
        case acceptedFinalFrame
        /// Not queued.
        case rejected(Rejection)
    }

    // MARK: Configuration

    /// The codec the payload is decoded with. Codec2 3200 in practice; any
    /// ``VoiceCodec`` whose frame arithmetic fits the payload in principle.
    public let codec: any VoiceCodec

    // MARK: State

    private var buffer: JitterBuffer
    private var expander = M17FrameNumberExpander()

    /// The over in progress, `nil` before the first datagram.
    public private(set) var streamID: UInt16?
    /// The station transmitting the over in progress.
    public private(set) var source: M17Address?
    /// Whether the last frame of the current over has been queued.
    public private(set) var hasSeenFinalFrame = false

    private var lastDecoded: [Int16]?
    private var concealmentRun = 0

    /// How many consecutive concealments before falling back to silence.
    ///
    /// Same reasoning as the IAX2 path: repeating a 20 ms frame is convincing
    /// for a couple of ticks and an obvious buzz much beyond that.
    public static let maxConcealmentRun = 3

    // MARK: Init

    public init(codec: any VoiceCodec, buffer: JitterBuffer = JitterBuffer()) {
        self.codec = codec
        self.buffer = buffer
    }

    // MARK: Observation

    /// Samples in every ``M17StreamPlayout``.
    public var samplesPerFrame: Int { codec.samplesPerFrame }
    public var queuedFrameCount: Int { buffer.queuedFrameCount }
    public var isPrimed: Bool { buffer.isPrimed }
    public var currentTargetDepth: Duration { buffer.currentTargetDepth }

    // MARK: Control

    /// Back to a just-constructed state.
    public mutating func reset() {
        buffer.reset()
        expander.reset()
        streamID = nil
        source = nil
        hasSeenFinalFrame = false
        lastDecoded = nil
        concealmentRun = 0
    }

    // MARK: Receive

    /// Accepts one inbound stream datagram.
    ///
    /// - Parameter arrivedAt: a monotonic arrival offset from any origin;
    ///   only differences matter. Supplying it drives the jitter buffer's
    ///   adaptive depth (AU-3). Omitting it leaves the depth alone, which is
    ///   what a fixture replay wants.
    public mutating func receive(
        _ packet: M17StreamPacket,
        arrivedAt: Duration? = nil
    ) -> Reception {
        guard packet.isCRCValid else {
            return .rejected(.crcFailed(carried: packet.crc, computed: packet.computedCRC))
        }
        guard packet.playability != .encrypted else {
            return .rejected(.encrypted)
        }

        // A new SID is a new transmission. Anything still queued belongs to an
        // over that is over, so it goes rather than being played across the
        // join.
        var startedNewStream = false
        if streamID != packet.streamID {
            if streamID != nil || hasSeenFinalFrame {
                buffer.reset()
                expander.reset()
                lastDecoded = nil
                concealmentRun = 0
            }
            streamID = packet.streamID
            source = packet.source
            hasSeenFinalFrame = false
            startedNewStream = true
        }

        let frames: [[UInt8]]
        do {
            frames = try M17StreamPayload.split(
                packet.payload, bytesPerCodecFrame: codec.bytesPerFrame)
        } catch {
            return .rejected(
                .malformedPayload(
                    payloadBytes: packet.payload.count, codecFrameBytes: codec.bytesPerFrame))
        }

        // Both halves are queued as separate 20 ms slots, so one lost datagram
        // conceals as two ordinary gaps and the buffer keeps the same tick as
        // every other codec in the stack.
        let base = expander.expand(packet.frameNumber) * M17StreamPayload.millisecondsPerPacket
        for (index, frame) in frames.enumerated() {
            let timestamp = base &+ UInt32(index) &* M17StreamPayload.millisecondsPerCodecFrame
            let timed = TimedFrame(timestamp: timestamp, payload: frame)
            if let arrivedAt {
                buffer.push(timed, arrivedAt: arrivedAt)
            } else {
                buffer.push(timed)
            }
        }

        if packet.isLastFrame {
            hasSeenFinalFrame = true
            return .acceptedFinalFrame
        }
        if startedNewStream {
            return .acceptedNewStream(streamID: packet.streamID, source: packet.source)
        }
        return .accepted
    }

    // MARK: Play out

    /// One 20 ms tick of audio.
    ///
    /// Call once per codec frame period. Returns decoded audio when a frame is
    /// due and available, a short run of concealment when one is missing, and
    /// silence otherwise.
    public mutating func pop() -> M17StreamPlayout {
        let silence = [Int16](repeating: 0, count: codec.samplesPerFrame)

        switch buffer.pop() {
        case .frame(let payload):
            guard let pcm = try? codec.decode(payload) else {
                // Undecodable bytes at the right slot: treat as a gap rather
                // than as audio, and do not disturb the concealment source.
                return M17StreamPlayout(kind: .silence, pcm: silence)
            }
            lastDecoded = pcm
            concealmentRun = 0
            return M17StreamPlayout(kind: .audio, pcm: pcm)

        case .concealment:
            guard let previous = lastDecoded, concealmentRun < Self.maxConcealmentRun else {
                concealmentRun += 1
                return M17StreamPlayout(kind: .silence, pcm: silence)
            }
            concealmentRun += 1
            // Fade the repeat, so a run tails off instead of buzzing.
            let attenuation = Double(Self.maxConcealmentRun - concealmentRun + 1)
                / Double(Self.maxConcealmentRun + 1)
            let faded = previous.map { sample in
                Int16(clamping: Int(Double(sample) * attenuation))
            }
            return M17StreamPlayout(kind: .concealment, pcm: faded)

        case .silence:
            concealmentRun = 0
            return M17StreamPlayout(kind: .silence, pcm: silence)
        }
    }
}
