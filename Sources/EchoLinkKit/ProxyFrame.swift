// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Message type

/// The type byte at offset 0 of a proxy frame.
///
/// A `RawRepresentable` struct rather than an `enum` on purpose: an enum makes
/// "not one of the six I know" a parse failure, and the six below are what four
/// clients happened to send in three captures, not the permitted set. An
/// unknown type parses fine and keeps its raw value; deciding it is unusable is
/// the session layer's business, not the codec's.
public struct EchoLinkProxyMessageType: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Open a channel to `peer`. Zero-length payload.
    public static let open = Self(rawValue: 0x01)

    /// Tunnelled TCP payload — the directory session on port 5200, in both
    /// directions.
    ///
    /// ⚠️ In our captures these frames carry the operator's account password
    /// one way and the entire station directory the other. Nothing derived
    /// from one may be written to a fixture without being checked byte by
    /// byte; see `Tests/FIXTURES.md`.
    public static let data = Self(rawValue: 0x02)

    /// Close the channel. Zero-length payload.
    public static let close = Self(rawValue: 0x03)

    /// Status, 4 bytes. `00 00 00 00` is the only value observed, and it means
    /// success.
    public static let status = Self(rawValue: 0x04)

    /// Tunnelled UDP payload from the audio channel — port 5198 in direct
    /// mode. Carries RTP audio, and also `oNDATA` station-info text, which is
    /// *not* RTP and must be told apart before parsing (see EL-7).
    public static let udpData = Self(rawValue: 0x05)

    /// Tunnelled UDP payload from the control channel — port 5199 in direct
    /// mode. RTCP-shaped, packet type 201.
    public static let udpControl = Self(rawValue: 0x06)

    /// Whether this is one of the six types observed in the captures. Useful
    /// for logging an oddity; never for rejecting one.
    public var isObserved: Bool {
        (0x01 ... 0x06).contains(rawValue)
    }
}

extension EchoLinkProxyMessageType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .open: return "OPEN"
        case .data: return "TCP_DATA"
        case .close: return "CLOSE"
        case .status: return "STATUS"
        case .udpData: return "UDP_DATA"
        case .udpControl: return "UDP_CONTROL"
        default: return String(format: "unknown(0x%02x)", rawValue)
        }
    }
}

// MARK: - Peer address

/// The four raw octets at offset 1 of a proxy frame: the IPv4 address of the
/// far end of the channel this frame belongs to.
///
/// Deliberately a dumb four-byte container and not any of the platform address
/// types. It is an identifier for demultiplexing frames by channel, and it is
/// `0.0.0.0` on every directory and control frame, which is not an address at
/// all. Nothing here resolves, validates or connects to it.
public struct EchoLinkPeerAddress: Hashable, Sendable {
    public let octets: (UInt8, UInt8, UInt8, UInt8)

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        octets = (a, b, c, d)
    }

    /// The address carried on frames that belong to no peer channel.
    public static let unspecified = Self(0, 0, 0, 0)

    public var isUnspecified: Bool { self == .unspecified }

    /// The four octets in wire order.
    public var bytes: [UInt8] { [octets.0, octets.1, octets.2, octets.3] }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.octets == rhs.octets
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(octets.0)
        hasher.combine(octets.1)
        hasher.combine(octets.2)
        hasher.combine(octets.3)
    }

    /// Parse dotted-quad text. Returns `nil` for anything that is not four
    /// decimal octets — this is for configuration, not for the wire.
    public init?(_ dottedQuad: String) {
        let parts = dottedQuad.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var parsed: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            parsed.append(value)
        }
        self.init(parsed[0], parsed[1], parsed[2], parsed[3])
    }
}

extension EchoLinkPeerAddress: CustomStringConvertible {
    public var description: String {
        "\(octets.0).\(octets.1).\(octets.2).\(octets.3)"
    }
}

// MARK: - Frame

/// One EchoLink proxy frame: a 9-byte header and its payload.
///
/// The header, from the captures (`Tests/EchoLinkKitTests/Fixtures/`):
///
///     offset 0   1 byte   message type
///     offset 1   4 bytes  peer IPv4, raw octets; 0.0.0.0 when not a peer channel
///     offset 5   4 bytes  payload length, LITTLE-ENDIAN
///     offset 9   n bytes  payload
///
/// ⚠️ **The length is little-endian.** RFC 5456 and the M17 specification are
/// both big-endian, so this is the one length field in this package that runs
/// the other way, and it is the single most likely thing here to be
/// "corrected" by someone who has just been reading `IAX2Frame`. It is not a
/// mistake and it is not a guess: reading it big-endian desynchronises the
/// stream within a few frames, and the whole of both captures decodes under
/// this reading with zero bytes left over. That is the check (EL-1, EL-4).
public struct EchoLinkProxyFrame: Equatable, Sendable {
    public var type: EchoLinkProxyMessageType
    public var peer: EchoLinkPeerAddress
    public var payload: Data

    /// The fixed header size, in bytes.
    public static let headerSize = 9

    /// An upper bound on a payload, so a desynchronised or hostile stream
    /// cannot make us reserve gigabytes on the strength of four bytes.
    ///
    /// Not a protocol constant — nothing observed comes close, the largest
    /// frame in the captures being a 4096-byte chunk of the directory
    /// download. It is a bound on damage, set far enough above practice that
    /// it should never be the thing a real session hits.
    public static let maximumPayloadSize = 1 << 20

    public init(
        type: EchoLinkProxyMessageType,
        peer: EchoLinkPeerAddress = .unspecified,
        payload: Data = Data()
    ) {
        self.type = type
        self.peer = peer
        self.payload = payload
    }

    /// The frame as it goes on the wire.
    public var encoded: Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(type.rawValue)
        out.append(contentsOf: peer.bytes)
        let length = UInt32(payload.count)
        // Little-endian, explicitly and one byte at a time, so this does not
        // depend on the host's byte order and so the intent survives review.
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(payload)
        return out
    }

    /// Parse exactly one frame from the front of `bytes`.
    ///
    /// - Returns: the frame, and how many bytes it consumed.
    /// - Throws: `EchoLinkProxyFrameError`.
    public static func parse(_ bytes: Data) throws -> (frame: EchoLinkProxyFrame, consumed: Int) {
        guard bytes.count >= headerSize else {
            throw EchoLinkProxyFrameError.truncatedHeader(available: bytes.count)
        }

        let base = bytes.startIndex
        func byte(_ offset: Int) -> UInt8 { bytes[base + offset] }

        let type = EchoLinkProxyMessageType(rawValue: byte(0))
        let peer = EchoLinkPeerAddress(byte(1), byte(2), byte(3), byte(4))
        let length = UInt32(byte(5))
            | UInt32(byte(6)) << 8
            | UInt32(byte(7)) << 16
            | UInt32(byte(8)) << 24

        guard length <= UInt32(maximumPayloadSize) else {
            throw EchoLinkProxyFrameError.implausibleLength(Int(length))
        }

        let payloadLength = Int(length)
        let total = headerSize + payloadLength
        guard bytes.count >= total else {
            throw EchoLinkProxyFrameError.truncatedPayload(
                expected: payloadLength,
                available: bytes.count - headerSize
            )
        }

        let payloadStart = base + headerSize
        let frame = EchoLinkProxyFrame(
            type: type,
            peer: peer,
            payload: Data(bytes[payloadStart ..< payloadStart + payloadLength])
        )
        return (frame, total)
    }
}

extension EchoLinkProxyFrame: CustomStringConvertible {
    public var description: String {
        let peerText = peer.isUnspecified ? "" : " peer \(peer)"
        return "\(type)\(peerText) \(payload.count)B"
    }
}

// MARK: - Errors

/// Why a proxy frame could not be read.
///
/// The two truncation cases are deliberately distinct, because they mean
/// opposite things to a caller reading from a stream: a truncated *header*
/// means "wait for more bytes and try again", which is the normal state of
/// affairs mid-chunk, while a truncated *payload* means the same only if the
/// declared length is believable. Collapsing them into one error loses the
/// distinction between "not yet" and "never".
public enum EchoLinkProxyFrameError: Error, Equatable, CustomStringConvertible {
    /// Fewer than 9 bytes available, so the header itself is incomplete.
    case truncatedHeader(available: Int)

    /// The header parsed and declared a payload longer than what is available.
    case truncatedPayload(expected: Int, available: Int)

    /// The declared length exceeds `EchoLinkProxyFrame.maximumPayloadSize`.
    ///
    /// On a stream this means the framing has desynchronised — there is no way
    /// to resynchronise a length-prefixed stream, so the connection is done.
    case implausibleLength(Int)

    public var description: String {
        switch self {
        case .truncatedHeader(let available):
            return "truncated proxy header: \(available) of \(EchoLinkProxyFrame.headerSize) bytes"
        case .truncatedPayload(let expected, let available):
            return "truncated proxy payload: \(available) of \(expected) bytes"
        case .implausibleLength(let length):
            return "proxy frame declares \(length) bytes, above the "
                + "\(EchoLinkProxyFrame.maximumPayloadSize)-byte ceiling — the stream has desynchronised"
        }
    }
}

// MARK: - Stream decoder

/// Turns the chunks a `StreamTransport` yields back into whole proxy frames.
///
/// This exists because `StreamTransport.incoming` yields whatever the network
/// hands over and its chunk boundaries carry no protocol meaning: one chunk may
/// be half a frame, or three frames, or the tail of one and the head of the
/// next. Every one of those cases goes through the same buffer here, so no
/// caller has to think about it.
///
/// A value type, not an actor: it holds a byte buffer and no I/O, and the actor
/// that owns the connection owns it. Keeping it a `struct` also means the
/// decoder can be tested without any concurrency at all.
///
///     var decoder = EchoLinkProxyFrameDecoder()
///     for await chunk in transport.incoming {
///         decoder.append(chunk)
///         while let frame = try decoder.nextFrame() { handle(frame) }
///     }
public struct EchoLinkProxyFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Bytes received but not yet consumed by a whole frame.
    public var bufferedByteCount: Int { buffer.count }

    /// Add a chunk from the transport. Any chunking is fine, including empty.
    public mutating func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    /// Take `count` bytes off the front of the buffer without framing them.
    ///
    /// For the login exchange, which is *not* framed — it precedes the framing
    /// entirely, as an 8-byte ASCII nonce from the proxy. That is why a capture
    /// including the TCP handshake fails to decode from byte 0 while one that
    /// began mid-session appears to work, which is the opposite of the
    /// intuition and cost EL-1 a guard.
    ///
    /// - Returns: the bytes, or `nil` if fewer than `count` have arrived.
    public mutating func takePrefix(_ count: Int) -> Data? {
        guard count >= 0 else { return nil }
        guard buffer.count >= count else { return nil }
        let taken = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return taken
    }

    /// The next whole frame, or `nil` if one has not fully arrived.
    ///
    /// - Throws: `EchoLinkProxyFrameError.implausibleLength` if the framing has
    ///   desynchronised. The two truncation errors are *not* thrown: from a
    ///   stream's point of view "not enough bytes yet" is the ordinary case,
    ///   and it is reported as `nil`.
    public mutating func nextFrame() throws -> EchoLinkProxyFrame? {
        do {
            let (frame, consumed) = try EchoLinkProxyFrame.parse(buffer)
            buffer.removeFirst(consumed)
            return frame
        } catch EchoLinkProxyFrameError.truncatedHeader, EchoLinkProxyFrameError.truncatedPayload {
            return nil
        }
    }

    /// Every whole frame available now, leaving any partial one buffered.
    public mutating func drain() throws -> [EchoLinkProxyFrame] {
        var frames: [EchoLinkProxyFrame] = []
        while let frame = try nextFrame() {
            frames.append(frame)
        }
        return frames
    }
}
