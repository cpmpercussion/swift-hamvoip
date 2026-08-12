// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Errors

/// Why an RTP-shaped payload could not be read.
public enum EchoLinkRTPError: Error, Equatable, CustomStringConvertible {
    /// Fewer than 12 bytes: the header itself is incomplete.
    case truncatedHeader(available: Int)

    /// The payload is not a whole number of 33-byte GSM frames.
    case partialCodecFrame(payloadBytes: Int)

    /// There is a header but no payload at all.
    case emptyPayload

    public var description: String {
        switch self {
        case .truncatedHeader(let available):
            return "truncated RTP header: \(available) of \(EchoLinkRTPHeader.size) bytes"
        case .partialCodecFrame(let bytes):
            return "\(bytes)-byte payload is not a whole number of "
                + "\(EchoLinkRTPPacket.gsmFrameSize)-byte GSM frames"
        case .emptyPayload:
            return "RTP packet carries a header and no payload"
        }
    }
}

// MARK: - Header

/// The 12-byte header on EchoLink's audio packets.
///
/// RTP-shaped, and **not RFC 3550-conformant as written**. Two departures, both
/// observed across every peer in every capture:
///
/// - **The version bits are 3**, where RFC 3550 §5.1 specifies 2. A parser
///   written faithfully from the RFC rejects every real EchoLink packet. Accept
///   3 — and do not reject 2 either, because nothing establishes that a peer
///   may not send it and refusing would be inventing a rule.
/// - **The timestamp is always zero** and never advances. This is a protocol
///   property, not one client's quirk: it held across four independent peers in
///   both directions. It is also the single fact that shapes EL-7, because
///   `JitterBuffer` keys on timestamps and there is nothing here to key on.
///   See `EchoLinkSequenceExpander`.
///
/// Two fields that a single-peer capture got wrong, and a four-peer capture
/// corrected — recorded here because the wrong version is the intuitive one:
///
/// - **SSRC is not always zero.** It is zero in everything this client emits,
///   which is what made it look like a constant, but one observed peer sent
///   1787057786. Never key on it and never assume it.
/// - **Sequence numbers do not start at zero.** Ours do; inbound sequences in
///   the wider capture ran 2126..23460. Treat the sequence as an opaque,
///   wrapping counter with an arbitrary origin.
public struct EchoLinkRTPHeader: Equatable, Sendable {
    /// The fixed header size, in bytes. Contributing sources would extend it,
    /// but no capture has ever shown a non-zero CSRC count.
    public static let size = 12

    /// What EchoLink puts in the version bits. See the type documentation.
    public static let observedVersion: UInt8 = 3

    /// Payload type 3 is GSM 06.10 — one of RFC 3551's static assignments, and
    /// the one place this protocol and the RFCs do agree.
    public static let gsmPayloadType: UInt8 = 3

    public var version: UInt8
    public var hasPadding: Bool
    public var hasExtension: Bool
    public var contributingSourceCount: UInt8
    public var marker: Bool
    public var payloadType: UInt8
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var synchronisationSource: UInt32

    public init(
        version: UInt8 = EchoLinkRTPHeader.observedVersion,
        hasPadding: Bool = false,
        hasExtension: Bool = false,
        contributingSourceCount: UInt8 = 0,
        marker: Bool = false,
        payloadType: UInt8 = EchoLinkRTPHeader.gsmPayloadType,
        sequenceNumber: UInt16,
        timestamp: UInt32 = 0,
        synchronisationSource: UInt32 = 0
    ) {
        self.version = version
        self.hasPadding = hasPadding
        self.hasExtension = hasExtension
        self.contributingSourceCount = contributingSourceCount
        self.marker = marker
        self.payloadType = payloadType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.synchronisationSource = synchronisationSource
    }

    /// Whether this looks like the audio EchoLink actually sends. Useful for a
    /// log line; never for rejecting a packet.
    public var isObservedShape: Bool {
        version == Self.observedVersion
            && payloadType == Self.gsmPayloadType
            && timestamp == 0
    }

    /// Parse the 12 bytes at the front of `bytes`.
    ///
    /// Every multi-byte field here is **big-endian** — network byte order, as
    /// RTP has always been. Note the contrast with the proxy header wrapping
    /// this one, whose length field is little-endian: the two byte orders sit
    /// nine bytes apart in the same datagram.
    public static func parse(_ bytes: Data) throws -> EchoLinkRTPHeader {
        guard bytes.count >= size else {
            throw EchoLinkRTPError.truncatedHeader(available: bytes.count)
        }
        let base = bytes.startIndex
        func byte(_ offset: Int) -> UInt8 { bytes[base + offset] }

        return EchoLinkRTPHeader(
            version: byte(0) >> 6,
            hasPadding: byte(0) & 0x20 != 0,
            hasExtension: byte(0) & 0x10 != 0,
            contributingSourceCount: byte(0) & 0x0F,
            marker: byte(1) & 0x80 != 0,
            payloadType: byte(1) & 0x7F,
            sequenceNumber: UInt16(byte(2)) << 8 | UInt16(byte(3)),
            timestamp: UInt32(byte(4)) << 24 | UInt32(byte(5)) << 16
                | UInt32(byte(6)) << 8 | UInt32(byte(7)),
            synchronisationSource: UInt32(byte(8)) << 24 | UInt32(byte(9)) << 16
                | UInt32(byte(10)) << 8 | UInt32(byte(11))
        )
    }

    /// The header as it goes on the wire.
    public var encoded: Data {
        var out = Data(capacity: Self.size)
        out.append(
            (version << 6)
                | (hasPadding ? 0x20 : 0)
                | (hasExtension ? 0x10 : 0)
                | (contributingSourceCount & 0x0F)
        )
        out.append((marker ? 0x80 : 0) | (payloadType & 0x7F))
        out.append(UInt8(truncatingIfNeeded: sequenceNumber >> 8))
        out.append(UInt8(truncatingIfNeeded: sequenceNumber))
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: timestamp >> UInt32(shift)))
        }
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: synchronisationSource >> UInt32(shift)))
        }
        return out
    }
}

// MARK: - Packet

/// One EchoLink audio packet: a 12-byte RTP header and its GSM frames.
///
/// Every packet observed, across four peers and 475 packets, was 144 bytes:
/// the header plus **four** 33-byte GSM 06.10 frames, which is 80 ms of audio
/// in four 20 ms units.
///
/// That four is treated as *observed practice, not a rule*. Four independent
/// senders agreeing is strong evidence about what implementations do and silent
/// about what the protocol permits, so parsing accepts any whole number of
/// codec frames and only the transmitter commits to four. Build to the
/// observation and you ship a client that works with the peers you happened to
/// test against.
public struct EchoLinkRTPPacket: Equatable, Sendable {
    /// One GSM 06.10 frame at 13 kbit/s: 33 bytes for 20 ms.
    public static let gsmFrameSize = 33

    /// What every observed sender packs into one packet.
    public static let observedFramesPerPacket = 4

    /// The audio duration of one codec frame.
    public static let frameDuration: Duration = .milliseconds(20)

    /// The size every observed packet had.
    public static let observedPacketSize =
        EchoLinkRTPHeader.size + gsmFrameSize * observedFramesPerPacket

    public var header: EchoLinkRTPHeader
    /// The codec frames, each `gsmFrameSize` bytes.
    public var codecFrames: [[UInt8]]

    public init(header: EchoLinkRTPHeader, codecFrames: [[UInt8]]) {
        self.header = header
        self.codecFrames = codecFrames
    }

    /// How much audio this packet carries.
    public var duration: Duration {
        Self.frameDuration * codecFrames.count
    }

    /// Parse a whole audio payload — the bytes inside a `0x05` proxy frame, or
    /// a UDP datagram from port 5198 in direct mode.
    public static func parse(_ bytes: Data) throws -> EchoLinkRTPPacket {
        let header = try EchoLinkRTPHeader.parse(bytes)
        let payload = bytes.dropFirst(EchoLinkRTPHeader.size)

        guard !payload.isEmpty else { throw EchoLinkRTPError.emptyPayload }
        guard payload.count % gsmFrameSize == 0 else {
            throw EchoLinkRTPError.partialCodecFrame(payloadBytes: payload.count)
        }

        var frames: [[UInt8]] = []
        frames.reserveCapacity(payload.count / gsmFrameSize)
        var index = payload.startIndex
        while index < payload.endIndex {
            let end = payload.index(index, offsetBy: gsmFrameSize)
            frames.append(Array(payload[index ..< end]))
            index = end
        }
        return EchoLinkRTPPacket(header: header, codecFrames: frames)
    }

    /// The packet as it goes on the wire.
    public var encoded: Data {
        var out = header.encoded
        for frame in codecFrames { out.append(contentsOf: frame) }
        return out
    }
}

// MARK: - The 0x05 channel carries more than audio

/// What arrived on the audio channel.
///
/// The `0x05` channel — UDP 5198 in direct mode — is **not audio-only**, and
/// this is the trap the fixtures exposed: station-info text arrives on the same
/// channel, beginning `oNDATA`. Fed to an RTP parser it decodes "successfully"
/// as version 1, payload type 78, with a nonsensical fraction of a GSM frame,
/// because `o` is `0x6F` and `N` is `0x4E`.
///
/// So classification comes before parsing. A client that skips this step plays
/// station announcements as noise.
public enum EchoLinkAudioChannelMessage: Equatable, Sendable {
    /// An RTP audio packet.
    case audio(EchoLinkRTPPacket)

    /// Station info, as text. The prefix is included verbatim rather than
    /// stripped: nothing here decodes its structure past the outer shape, and
    /// pretending otherwise would be designing against one capture.
    case stationInfo(String)

    /// Neither. Kept rather than discarded so a caller can log it — the point
    /// of the whole module is that we have not met every client.
    case unrecognised(Data)
}

extension EchoLinkAudioChannelMessage {
    /// The marker station-info text begins with.
    public static let stationInfoPrefix = "oNDATA"

    /// Classify a `0x05` payload.
    ///
    /// Deliberately does not throw. A payload that is neither is
    /// `.unrecognised`, not an error, for the same reason an unknown proxy
    /// message type parses: it is a client we have not met, not a fault.
    public static func classify(_ bytes: Data) -> EchoLinkAudioChannelMessage {
        if bytes.starts(with: Array(stationInfoPrefix.utf8)) {
            let text = String(decoding: bytes, as: UTF8.self)
            return .stationInfo(text)
        }
        if let packet = try? EchoLinkRTPPacket.parse(bytes) {
            return .audio(packet)
        }
        return .unrecognised(bytes)
    }
}
