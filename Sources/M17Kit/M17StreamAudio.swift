// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Payload

/// The split of an ``M17StreamPacket``'s 16-byte payload into codec frames.
///
/// An M17 stream datagram carries 128 bits of voice, and Codec2 3200 produces
/// 64 bits per 20 ms frame (confirmed against the built framework by the M17-1
/// spike, and re-asserted by ``Codec2VoiceCodec`` at construction). So one
/// datagram is **two codec frames, 40 ms of audio**.
///
/// That factor of two is the only reason this type exists, and it is worth
/// naming rather than scattering `16 / 8` through the receive path: the two
/// halves are queued into the jitter buffer as separate 20 ms slots, so a
/// single lost datagram conceals as two ordinary gaps rather than one
/// double-length one, and every other codec in the stack keeps its 20 ms tick.
public enum M17StreamPayload {

    /// Codec frames per datagram.
    public static let framesPerPacket = 2

    /// Audio per datagram: 40 ms at 8 kHz.
    public static let samplesPerPacket = 320

    /// Audio per codec frame: 20 ms at 8 kHz. The tick the rest of the stack
    /// works in — `JitterBuffer`'s default `frameDuration`, and what
    /// `AudioPipeline` expects.
    public static let millisecondsPerCodecFrame: UInt32 = 20

    /// Audio per datagram, in the milliseconds `JitterBuffer` counts in.
    public static let millisecondsPerPacket: UInt32 =
        millisecondsPerCodecFrame * UInt32(framesPerPacket)

    /// Splits a payload into its codec frames.
    ///
    /// - Throws: ``M17StreamAudioError/payloadNotDivisible`` if the payload is
    ///   not ``framesPerPacket`` whole frames of `bytesPerCodecFrame`.
    public static func split(_ payload: Data, bytesPerCodecFrame: Int) throws -> [[UInt8]] {
        guard bytesPerCodecFrame > 0,
            payload.count == bytesPerCodecFrame * framesPerPacket
        else {
            throw M17StreamAudioError.payloadNotDivisible(
                payloadBytes: payload.count, codecFrameBytes: bytesPerCodecFrame)
        }
        let bytes = [UInt8](payload)
        return (0..<framesPerPacket).map { index in
            Array(bytes[(index * bytesPerCodecFrame)..<((index + 1) * bytesPerCodecFrame)])
        }
    }

    /// Joins codec frames back into a payload.
    public static func join(_ frames: [[UInt8]], bytesPerCodecFrame: Int) throws -> Data {
        guard frames.count == framesPerPacket,
            frames.allSatisfy({ $0.count == bytesPerCodecFrame })
        else {
            throw M17StreamAudioError.payloadNotDivisible(
                payloadBytes: frames.reduce(0) { $0 + $1.count },
                codecFrameBytes: bytesPerCodecFrame)
        }
        return Data(frames.flatMap { $0 })
    }
}

/// Failures in the stream audio path.
public enum M17StreamAudioError: Error, Equatable, CustomStringConvertible {
    /// The payload is not a whole number of codec frames.
    case payloadNotDivisible(payloadBytes: Int, codecFrameBytes: Int)
    /// `encode` was handed something other than one datagram's worth of PCM.
    case wrongSampleCount(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .payloadNotDivisible(let payload, let frame):
            return """
                a \(payload)-byte payload is not \(M17StreamPayload.framesPerPacket) \
                whole codec frames of \(frame) bytes
                """
        case .wrongSampleCount(let expected, let actual):
            return "an M17 stream datagram carries exactly \(expected) samples, got \(actual)"
        }
    }
}

// MARK: - Frame numbering

/// Expands M17's 15-bit frame number into a monotonic count.
///
/// FN is 15 bits plus the last-frame flag in bit 15 (Part I §3.2.2), so it
/// wraps every 32768 frames — 21.8 minutes at 40 ms a frame. Rare, but a
/// stream that wraps must not look to the jitter buffer like a stream that
/// jumped backwards by 21 minutes.
///
/// Same job as `IAX2MiniTimestampExpander`, and it works the same way for the
/// same reason: expansion is relative to the **newest expanded value**, and the
/// reference only advances when a frame is genuinely newer.
///
/// The obvious implementation — remember the last raw sequence, bump an epoch
/// whenever the number jumps backwards — is wrong at exactly the boundary it
/// exists to handle, and the failure is not subtle. A pre-wrap `0x7FFF`
/// arriving *after* the stream has already wrapped to `0` leaves the reference
/// at `0x7FFF`, so the next ordinary post-wrap frame reads as a second wrap.
/// The epoch then runs away permanently: every timestamp is 21.8 minutes
/// further out than the last, the jitter buffer sees a discontinuity rather
/// than a stream, and the audio does not recover. Found in review of M17-5.
public struct M17FrameNumberExpander: Sendable, Equatable {

    /// One past the largest sequence number, the 15-bit range.
    public static let modulus: UInt32 = 0x8000

    /// Half the range. A step further than this in either direction is a wrap
    /// rather than an ordinary reorder — the same "nearest interpretation"
    /// rule a sequence-number window uses.
    private static let wrapThreshold: Int = 0x4000

    /// The newest expanded value emitted so far. `nil` until the first frame.
    private var newestExpanded: UInt32?

    public init() {}

    /// The expanded, monotonic frame count for `frameNumber`.
    ///
    /// Late frames expand to where they were *sent* — below the reference —
    /// rather than being dragged forward, which is what lets the jitter buffer
    /// recognise them as the reordered arrivals they are.
    ///
    /// - Parameter frameNumber: the raw FN field, last-frame flag included;
    ///   the flag is masked off here.
    public mutating func expand(_ frameNumber: UInt16) -> UInt32 {
        let sequence = UInt32(frameNumber & ~M17StreamPacket.lastFrameFlag)

        guard let reference = newestExpanded else {
            newestExpanded = sequence
            return sequence
        }

        let referenceSequence = reference % Self.modulus
        let referenceEpoch = reference / Self.modulus
        let delta = Int(sequence) - Int(referenceSequence)

        let epoch: UInt32
        if delta < -Self.wrapThreshold {
            // A long way below the reference: the stream wrapped forwards.
            epoch = referenceEpoch &+ 1
        } else if delta > Self.wrapThreshold, referenceEpoch > 0 {
            // A long way above it: a straggler from before the wrap. It
            // belongs in the previous epoch, not this one.
            epoch = referenceEpoch - 1
        } else {
            epoch = referenceEpoch
        }

        let expanded = epoch &* Self.modulus &+ sequence
        // Only newer frames move the reference. A late arrival that dragged it
        // backwards would make the *next* in-order frame look like a wrap,
        // which is the bug this design exists to avoid.
        if expanded > reference { newestExpanded = expanded }
        return expanded
    }

    /// Back to a just-constructed state, for a new over.
    public mutating func reset() {
        newestExpanded = nil
    }
}

// MARK: - Outbound

/// Produces the stream datagrams of one over.
///
/// Pure state, no clock and no codec: hand it a payload, get a packet with the
/// right frame number and a valid CRC. Mirrors `IAX2VoiceTransmitter`.
///
/// The LSF fields — DST, SRC, TYPE, META — and the stream ID are fixed for the
/// life of the over, which is what the specification means by "consistent from
/// frame to frame within a stream". A new over means a new transmitter, or
/// ``reset(streamID:)``.
public struct M17StreamTransmitter: Sendable {

    /// Random per PTT, constant within the over.
    public private(set) var streamID: UInt16

    public let destination: M17Address
    public let source: M17Address
    public let type: M17StreamType
    public let metadata: Data

    /// The sequence number the next datagram will carry, before the
    /// last-frame flag is applied.
    public private(set) var nextSequenceNumber: UInt16 = 0

    /// Whether the last frame has been sent, after which this transmitter is
    /// finished and ``next(payload:isLast:)`` throws.
    public private(set) var isFinished = false

    /// - Parameters:
    ///   - streamID: the stream ID for this over. Callers that do not care
    ///     what it is should use ``randomStreamID()``.
    ///   - metadata: 14 bytes. Zeros unless the TYPE says otherwise.
    public init(
        streamID: UInt16,
        destination: M17Address,
        source: M17Address,
        type: M17StreamType = M17StreamType(rawValue: 0x0005),
        metadata: Data = Data(repeating: 0, count: M17StreamPacket.metadataByteCount)
    ) {
        self.streamID = streamID
        self.destination = destination
        self.source = source
        self.type = type
        self.metadata = metadata
    }

    /// A stream ID drawn at random, as "Random bits, changed for each PTT or
    /// stream" requires.
    public static func randomStreamID() -> UInt16 {
        UInt16.random(in: UInt16.min...UInt16.max)
    }

    /// The next datagram of this over.
    ///
    /// - Parameter isLast: sets the last-frame flag, `FN & 0x8000`. After a
    ///   last frame the transmitter is finished.
    public mutating func next(payload: Data, isLast: Bool = false) throws -> M17StreamPacket {
        guard !isFinished else { throw M17StreamTransmitError.streamAlreadyEnded }

        let frameNumber = isLast
            ? nextSequenceNumber | M17StreamPacket.lastFrameFlag
            : nextSequenceNumber
        let packet = try M17StreamPacket(
            streamID: streamID,
            destination: destination,
            source: source,
            type: type,
            metadata: metadata,
            frameNumber: frameNumber,
            payload: payload)

        // 15 bits, so the counter wraps rather than colliding with the flag.
        nextSequenceNumber = (nextSequenceNumber &+ 1) & ~M17StreamPacket.lastFrameFlag
        isFinished = isLast
        return packet
    }

    /// Encodes 40 ms of PCM and emits it as one datagram.
    ///
    /// - Parameter pcm: exactly ``M17StreamPayload/samplesPerPacket`` samples
    ///   of 8 kHz mono signed 16-bit audio.
    public mutating func next(
        pcm: [Int16],
        using codec: some VoiceCodec,
        isLast: Bool = false
    ) throws -> M17StreamPacket {
        guard pcm.count == M17StreamPayload.samplesPerPacket else {
            throw M17StreamAudioError.wrongSampleCount(
                expected: M17StreamPayload.samplesPerPacket, actual: pcm.count)
        }
        var frames: [[UInt8]] = []
        for index in 0..<M17StreamPayload.framesPerPacket {
            let start = index * codec.samplesPerFrame
            frames.append(try codec.encode(Array(pcm[start..<(start + codec.samplesPerFrame)])))
        }
        let payload = try M17StreamPayload.join(frames, bytesPerCodecFrame: codec.bytesPerFrame)
        return try next(payload: payload, isLast: isLast)
    }

    /// Starts a new over, with a new stream ID and the counter back at zero.
    public mutating func reset(streamID: UInt16) {
        self.streamID = streamID
        nextSequenceNumber = 0
        isFinished = false
    }
}

/// Failures producing a stream datagram.
public enum M17StreamTransmitError: Error, Equatable, CustomStringConvertible {
    /// The last frame has already been sent.
    case streamAlreadyEnded

    public var description: String {
        switch self {
        case .streamAlreadyEnded:
            return "the last frame of this stream has already been sent; reset for a new over"
        }
    }
}
