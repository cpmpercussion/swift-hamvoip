// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Specification reference
//
// The reflector control protocol is *not* in the Part I "Air Interface" PDF
// (https://spec.m17project.org/files/M17_spec.pdf, v2.0.4, January 2026) —
// that document stops at the application layer and has no IP section at all.
// It lives in the M17 Protocol Specification's "M17 Internet Protocol (IP)
// Networking" chapter, which was published at
//
//   https://m17-protocol-specification.readthedocs.io/en/latest/ip_encapsulation.html
//
// That host has since gone offline; the text this file was written from is the
// last archived rendering,
//
//   https://web.archive.org/web/20251008220102/https://m17-protocol-specification.readthedocs.io/en/latest/ip_encapsulation.html
//   (Sphinx revision fa272742)
//
// which is byte-identical, in every field of every table used here, to the
// 2022-12-28 archived rendering — the layouts have been stable for years.
// See `docs/reference/PROVENANCE.md` for why an archived copy of the published
// specification is inside the clean-room boundary.
//
// Section names used in the comments below are that chapter's own headings:
// "Standard IP Framing" (Table 27) and "Control Packets" (Tables 28-33).
// TYPE-field bit assignments come from Part I §3.2.1, Table 3.2.
//
// "M17 over IP is big endian, consistent with other IP protocols."
// ("Standard IP Framing") — every multi-byte field here is big endian.

// MARK: - Errors

/// Everything that can go wrong turning bytes into an M17 reflector packet,
/// or a callsign/module into one.
///
/// Parsing is deliberately *total and strict*: a datagram either matches one
/// of the layouts in the specification exactly, or it is rejected. There is no
/// best-effort path, because a misparsed control packet would drive the
/// connection state machine on garbage.
public enum M17PacketError: Error, Equatable, CustomStringConvertible {
    /// Fewer than four bytes arrived, so there isn't even a magic to look at.
    case tooShort(byteCount: Int)

    /// The first four bytes are not one of the seven magics this protocol
    /// defines.
    case unknownMagic([UInt8])

    /// The magic is recognised but the datagram is not one of the lengths that
    /// magic permits. `expected` lists every legal length (only `DISC` has
    /// more than one).
    case wrongLength(magic: String, expected: [Int], actual: Int)

    /// The module byte is not a single ASCII `A`-`Z`, as "Control Packets"
    /// requires ("Module to connect to - single ASCII byte A-Z").
    case invalidModule(String)

    /// A 6-byte address field could not be formed — wrong byte count, a value
    /// with bits set above bit 47, or a callsign that will not base-40 encode.
    case invalidAddress(String)

    public var description: String {
        switch self {
        case .tooShort(let byteCount):
            return "M17 packet is \(byteCount) bytes; the 4-byte magic alone needs 4"
        case .unknownMagic(let bytes):
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return "unknown M17 packet magic \(hex) ('\(ascii)')"
        case .wrongLength(let magic, let expected, let actual):
            let lengths = expected.map(String.init).joined(separator: " or ")
            return "'\(magic)' packet must be \(lengths) bytes, got \(actual)"
        case .invalidModule(let detail):
            return "invalid M17 module: \(detail)"
        case .invalidAddress(let detail):
            return "invalid M17 address: \(detail)"
        }
    }
}

// MARK: - Magic

/// The four-byte ASCII tag that opens every M17 IP datagram.
///
/// Six control magics from "Control Packets", plus the stream magic from
/// "Standard IP Framing" (Table 27: "Magic bytes 0x4d313720 (\"M17 \")" —
/// note the trailing space, which is part of the magic).
public enum M17PacketMagic: String, CaseIterable, Sendable {
    case connect = "CONN"
    case acknowledge = "ACKN"
    case negativeAcknowledge = "NACK"
    case ping = "PING"
    case pong = "PONG"
    case disconnect = "DISC"
    case stream = "M17 "

    /// Length of the magic field: 32 bits (Table 27).
    public static let byteCount = 4

    /// The magic as its four ASCII bytes.
    public var bytes: [UInt8] { Array(rawValue.utf8) }

    /// Legal total datagram lengths for this magic, in bytes.
    ///
    /// `DISC` has two: 10 bytes when it carries the sender's address, and 4
    /// when it is the bare acknowledgement ("Acknowledged with 4-byte packet
    /// \"DISC\" (without the callsign field)").
    public var permittedLengths: [Int] {
        switch self {
        case .connect: return [M17PacketMagic.byteCount + M17Address.byteCount + 1]  // 11
        case .acknowledge, .negativeAcknowledge: return [M17PacketMagic.byteCount]   // 4
        case .ping, .pong: return [M17PacketMagic.byteCount + M17Address.byteCount]  // 10
        case .disconnect:
            return [M17PacketMagic.byteCount + M17Address.byteCount, M17PacketMagic.byteCount]  // 10, 4
        case .stream: return [M17StreamPacket.byteCount]                             // 56
        }
    }

    /// Matches the leading four bytes of a datagram, or `nil` if they are not
    /// a magic this protocol knows.
    public init?(leading bytes: [UInt8]) {
        guard bytes.count >= M17PacketMagic.byteCount else { return nil }
        let prefix = Array(bytes.prefix(M17PacketMagic.byteCount))
        guard let match = M17PacketMagic.allCases.first(where: { $0.bytes == prefix }) else { return nil }
        self = match
    }
}

// MARK: - Module

/// A reflector module: "single ASCII byte A-Z" ("Control Packets", Table 28).
///
/// Wrapped in a type rather than passed around as a `Character` so that a
/// packet, once constructed, can always be serialized — validation happens at
/// the boundary, never at write time.
public struct M17Module: Hashable, Sendable, CustomStringConvertible {
    /// The module letter, always uppercase ASCII `A`-`Z`.
    public let letter: Character

    /// - Throws: `M17PacketError.invalidModule` unless `letter` is ASCII
    ///   `A`-`Z`. Case-sensitive on purpose: the specification says the wire
    ///   byte is `A`-`Z`, and silently upcasing here would let a caller's bug
    ///   through untouched.
    public init(_ letter: Character) throws {
        guard let ascii = letter.asciiValue, (0x41...0x5A).contains(ascii) else {
            throw M17PacketError.invalidModule("'\(letter)' is not an ASCII letter A-Z")
        }
        self.letter = letter
    }

    /// - Throws: `M17PacketError.invalidModule` unless `byte` is `0x41...0x5A`.
    public init(wireByte byte: UInt8) throws {
        guard (0x41...0x5A).contains(byte) else {
            throw M17PacketError.invalidModule(String(format: "wire byte 0x%02X is outside 'A'-'Z'", byte))
        }
        self.letter = Character(UnicodeScalar(byte))
    }

    /// The single wire byte for this module.
    public var wireByte: UInt8 { letter.asciiValue! }

    public var description: String { String(letter) }
}

// MARK: - Address

/// The 6-byte base-40 address field carried by `CONN`, `PING`, `PONG` and the
/// long form of `DISC` — and by the DST/SRC fields of a stream packet.
///
/// "Control Packets" describes it as: "6-byte 'From' callsign including module
/// in last character (e.g. \"A1BCD D\") encoded as per Address Encoding". The
/// encoding itself is Part I Appendix A and lives in ``Base40Callsign``; this
/// type is only the wire field plus the module-suffix convention.
///
/// Kept as a raw 48-bit value rather than a `String` because the reserved,
/// extended and broadcast ranges (Part I Table A.2) are perfectly legal on the
/// wire and simply do not decode to text — ``callsign`` returns `nil` for
/// those instead of the parse failing.
public struct M17Address: Hashable, Sendable, CustomStringConvertible {
    /// Length of the address field: 48 bits (Part I Table 3.1, and bytes 4-9
    /// of the control packets).
    public static let byteCount = Base40Callsign.byteCount

    /// The 48-bit base-40 address. Bits above bit 47 are always zero.
    public let value: UInt64

    /// - Throws: `M17PacketError.invalidAddress` if `value` does not fit in
    ///   48 bits.
    public init(value: UInt64) throws {
        guard value <= 0x0000_FFFF_FFFF_FFFF else {
            throw M17PacketError.invalidAddress(
                String(format: "0x%llX exceeds the 48-bit address field", value))
        }
        self.value = value
    }

    /// - Throws: `M17PacketError.invalidAddress` unless exactly six bytes are
    ///   supplied. Interpreted big endian ("network byte order", Part I §A.2).
    public init(bytes: some Collection<UInt8>) throws {
        guard bytes.count == M17Address.byteCount else {
            throw M17PacketError.invalidAddress(
                "address field must be exactly \(M17Address.byteCount) bytes, got \(bytes.count)")
        }
        var accumulated: UInt64 = 0
        for byte in bytes { accumulated = (accumulated << 8) | UInt64(byte) }
        self.value = accumulated
    }

    /// Encodes a callsign, optionally with the module-in-last-character
    /// convention from "Control Packets".
    ///
    /// With `module` supplied, the encoded *text* is `callsign`, a space, then
    /// the module letter — exactly the shape of the specification's example,
    /// `"A1BCD D"` for callsign `A1BCD` on module `D`. Because the first
    /// character of a callsign is the least significant base-40 digit
    /// (Part I §A.2), that is arithmetically
    /// `encode(callsign) + module × 40^(callsign.count + 1)`, with the space
    /// contributing nothing (its alphabet value is 0).
    ///
    /// - Throws: `M17PacketError.invalidAddress` if the callsign will not
    ///   encode, or if `callsign` plus the space plus the module would exceed
    ///   the nine characters a 48-bit address holds.
    public init(callsign: String, module: M17Module? = nil) throws {
        let normalized = callsign.uppercased()
        var encoded: UInt64
        do {
            encoded = try Base40Callsign.encode(normalized)
        } catch {
            throw M17PacketError.invalidAddress("\(error)")
        }
        if let module {
            let modulePosition = normalized.count + 1
            guard modulePosition < Base40Callsign.maxLength else {
                throw M17PacketError.invalidAddress(
                    "'\(normalized) \(module)' is longer than the \(Base40Callsign.maxLength) "
                        + "characters a 48-bit address holds")
            }
            var multiplier: UInt64 = 1
            for _ in 0..<modulePosition { multiplier *= 40 }
            // Module letters are A-Z, i.e. alphabet values 1...26.
            let moduleValue = UInt64(module.wireByte - 0x41) + 1
            encoded += moduleValue * multiplier
        }
        try self.init(value: encoded)
    }

    /// The six wire bytes, most significant first (Part I §A.2: "the final
    /// 6-byte address is the big endian encoded representation").
    public var bytes: [UInt8] {
        (0..<M17Address.byteCount).map { offset in
            UInt8((value >> (8 * (M17Address.byteCount - 1 - offset))) & 0xFF)
        }
    }

    /// The decoded text, or `nil` when the address is in a range that carries
    /// no text — reserved zero, the extended/application range, or BROADCAST
    /// (Part I Table A.2).
    public var callsign: String? {
        try? Base40Callsign.decode(value)
    }

    public var description: String {
        callsign ?? String(format: "0x%012llX", value)
    }
}

// MARK: - Control packets

/// One of the six reflector control packets from "Control Packets".
///
/// Confirmed layouts (all offsets in bytes, all fields big endian):
///
/// | Packet | Size | 0-3    | 4-9                 | 10           |
/// |--------|------|--------|---------------------|--------------|
/// | `CONN` | 11   | "CONN" | 'From' address      | module `A`-`Z` |
/// | `ACKN` | 4    | "ACKN" | —                   | —            |
/// | `NACK` | 4    | "NACK" | —                   | —            |
/// | `PING` | 10   | "PING" | 'From' address      | —            |
/// | `PONG` | 10   | "PONG" | 'From' address      | —            |
/// | `DISC` | 10   | "DISC" | 'From' address      | —            |
/// | `DISC` | 4    | "DISC" | — (bare acknowledgement) | —       |
///
/// Note in particular that `ACKN` and `NACK` carry **no** address field — they
/// are four bytes and nothing else — while `PING` and `PONG` both do.
public enum M17ControlPacket: Hashable, Sendable {
    /// Client → reflector. "A client sends this to a reflector to initiate a
    /// connection. The reflector replies with ACKN on successful linking, or
    /// NACK on failure."
    case connect(from: M17Address, module: M17Module)

    /// Reflector → client, "acknowledge connection". Four bytes, no payload.
    case acknowledge

    /// Reflector → client, "deny connection". Four bytes, no payload.
    case negativeAcknowledge

    /// Reflector → client, "keepalive for the connection from the reflector to
    /// the client".
    case ping(from: M17Address)

    /// Client → reflector, "keepalive response from the client to the
    /// reflector". "Upon receiv[i]ng a PING from a reflector, the client
    /// replies with a PONG".
    case pong(from: M17Address)

    /// Either direction. `from` is `nil` for the four-byte bare form, which
    /// the specification defines as the acknowledgement of a `DISC`.
    case disconnect(from: M17Address?)

    /// This packet's magic.
    public var magic: M17PacketMagic {
        switch self {
        case .connect: return .connect
        case .acknowledge: return .acknowledge
        case .negativeAcknowledge: return .negativeAcknowledge
        case .ping: return .ping
        case .pong: return .pong
        case .disconnect: return .disconnect
        }
    }

    /// The address this packet carries, if its layout has one.
    public var address: M17Address? {
        switch self {
        case .connect(let from, _): return from
        case .ping(let from), .pong(let from): return from
        case .disconnect(let from): return from
        case .acknowledge, .negativeAcknowledge: return nil
        }
    }

    /// The datagram for this packet. Total by construction, since both the
    /// module and the address are validated when the packet is built.
    public var data: Data {
        var out = Data(magic.bytes)
        switch self {
        case .connect(let from, let module):
            out.append(contentsOf: from.bytes)
            out.append(module.wireByte)
        case .ping(let from), .pong(let from):
            out.append(contentsOf: from.bytes)
        case .disconnect(let from):
            if let from { out.append(contentsOf: from.bytes) }
        case .acknowledge, .negativeAcknowledge:
            break
        }
        return out
    }

    /// Parses a control datagram.
    ///
    /// - Throws: `M17PacketError` for a short datagram, an unrecognised magic,
    ///   a length the magic does not permit, or a bad module byte. A `"M17 "`
    ///   stream datagram is *not* a control packet and is rejected here with
    ///   `.wrongLength`/`.unknownMagic` semantics — use
    ///   ``M17ReflectorPacket/parse(_:)`` to demultiplex both kinds.
    public static func parse(_ data: Data) throws -> M17ControlPacket {
        let bytes = [UInt8](data)
        guard bytes.count >= M17PacketMagic.byteCount else {
            throw M17PacketError.tooShort(byteCount: bytes.count)
        }
        guard let magic = M17PacketMagic(leading: bytes) else {
            throw M17PacketError.unknownMagic(Array(bytes.prefix(M17PacketMagic.byteCount)))
        }
        guard magic != .stream else {
            throw M17PacketError.unknownMagic(Array(bytes.prefix(M17PacketMagic.byteCount)))
        }
        guard magic.permittedLengths.contains(bytes.count) else {
            throw M17PacketError.wrongLength(
                magic: magic.rawValue, expected: magic.permittedLengths, actual: bytes.count)
        }

        let addressRange = M17PacketMagic.byteCount..<(M17PacketMagic.byteCount + M17Address.byteCount)
        switch magic {
        case .connect:
            let address = try M17Address(bytes: bytes[addressRange])
            let module = try M17Module(wireByte: bytes[addressRange.upperBound])
            return .connect(from: address, module: module)
        case .acknowledge:
            return .acknowledge
        case .negativeAcknowledge:
            return .negativeAcknowledge
        case .ping:
            return .ping(from: try M17Address(bytes: bytes[addressRange]))
        case .pong:
            return .pong(from: try M17Address(bytes: bytes[addressRange]))
        case .disconnect:
            guard bytes.count > M17PacketMagic.byteCount else { return .disconnect(from: nil) }
            return .disconnect(from: try M17Address(bytes: bytes[addressRange]))
        case .stream:
            preconditionFailure("stream magic is rejected above")
        }
    }
}

// MARK: - Stream TYPE field

/// The 16-bit LSF `TYPE` field (Part I §3.2.1, Table 3.2).
///
/// Bit assignments, reading Table 3.2 with byte 1 as the least significant
/// byte of the big-endian 16-bit field:
///
/// | Bits  | Field |
/// |-------|-------|
/// | 0     | Packet/Stream indicator (Table 3.3: 1 = stream mode) |
/// | 1-2   | Data type (Table 3.4: 00 reserved, 01 data, 10 voice, 11 voice+data) |
/// | 3-4   | Encryption type (Table 3.5: 00 none, 01 scrambler, 10 AES, 11 other) |
/// | 5-6   | Encryption subtype (Table 3.6: key length) |
/// | 7-10  | Channel Access Number (§3.2.3, 0...15) |
/// | 11    | Signed stream (§3.2.5) |
/// | 12-15 | Reserved |
///
/// **FR-2.5.** The encryption bits are *read* — they have to be, or an
/// encrypted stream would be decoded as noise and played out — but nothing on
/// this type offers to decrypt anything, and no key material appears anywhere
/// in `M17Kit`. An encrypted stream is reported as ``Playability/encrypted``
/// and is simply not playable. Encryption is not permitted in the amateur
/// service in most jurisdictions, and the specification says as much itself
/// (§3.2.2: "The use of it may be restricted within some radio services and
/// countries, and should only be used if legally permissible").
public struct M17StreamType: Hashable, Sendable {
    /// The raw 16-bit field, as it appears on the wire (big endian).
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Table 3.4.
    public enum DataType: UInt16, Sendable, CaseIterable {
        case reserved = 0b00
        case data = 0b01
        case voice = 0b10
        case voiceAndData = 0b11
    }

    /// Why a received stream can or cannot be played out.
    public enum Playability: Hashable, Sendable, CustomStringConvertible {
        /// Unencrypted stream-mode audio.
        case playable
        /// Encryption type is non-zero. Not decryptable by this library, by
        /// design (FR-2.5).
        case encrypted
        /// Stream mode, but the payload is not voice.
        case notVoice
        /// The Packet/Stream indicator says packet mode, so there is no
        /// continuous stream to play.
        case notStreamMode

        public var description: String {
            switch self {
            case .playable: return "playable"
            case .encrypted: return "encrypted stream — not playable (encryption is not supported)"
            case .notVoice: return "stream carries no voice payload"
            case .notStreamMode: return "packet mode, not a voice stream"
            }
        }
    }

    /// Bit 0. Table 3.3: 1 = stream mode, 0 = packet mode.
    public var isStreamMode: Bool { rawValue & 0b1 == 1 }

    /// Bits 1-2, Table 3.4.
    public var dataType: DataType {
        DataType(rawValue: (rawValue >> 1) & 0b11)!
    }

    /// Bits 3-4, Table 3.5. Exposed as a plain flag rather than an enum of
    /// cipher names: knowing *that* a stream is encrypted is what the receiver
    /// needs; knowing *which* cipher is only useful to something that intends
    /// to decrypt (FR-2.5).
    public var isEncrypted: Bool { (rawValue >> 3) & 0b11 != 0 }

    /// Bits 7-10, §3.2.3. "A four bit code that may be used to filter received
    /// audio, text, and GNSS data."
    public var channelAccessNumber: UInt8 { UInt8((rawValue >> 7) & 0b1111) }

    /// Bit 11, §3.2.5 — the stream carries an ECDSA signature in its last four
    /// frames.
    public var isSignedStream: Bool { (rawValue >> 11) & 0b1 == 1 }

    /// Whether, and why, this stream can be played out.
    public var playability: Playability {
        guard isStreamMode else { return .notStreamMode }
        guard !isEncrypted else { return .encrypted }
        switch dataType {
        case .voice, .voiceAndData: return .playable
        case .data, .reserved: return .notVoice
        }
    }

    /// Convenience for `playability == .playable`.
    public var isPlayable: Bool { playability == .playable }
}

// MARK: - Stream packet

/// An `M17 ` stream datagram, parsed as far as its header.
///
/// Layout from "Standard IP Framing", Table 27:
///
/// | Offset | Size | Field |
/// |--------|------|-------|
/// | 0-3    | 4    | MAGIC `"M17 "` (`0x4D313720`) |
/// | 4-5    | 2    | StreamID (SID) |
/// | 6-35   | 30   | LICH — "the meaningful contents of a LICH frame (dst, src, streamtype, META field, CRC16)" |
/// | 36-37  | 2    | FN, frame number, last-frame flag at `FN & 0x8000` |
/// | 38-53  | 16   | Payload |
/// | 54-55  | 2    | CRC16 over the entire packet |
///
/// The LICH sub-fields are the Link Setup Frame contents of Part I Table 3.1:
/// DST 48 bits, SRC 48 bits, TYPE 16 bits, META 112 bits, CRC 16 bits — 240
/// bits, i.e. 30 bytes, which is exactly what Table 27 states.
///
/// **Total: 56 bytes.** That follows arithmetically from Table 27
/// (4 + 2 + 30 + 2 + 16 + 2) and from the LICH field being the *whole* 30-byte
/// LSF including its own CRC. It is worth flagging for M17-4: a 28-byte LICH
/// (LSF without its CRC) would give the 54-byte frame that is sometimes quoted
/// for M17-over-IP, and the two readings differ only in whether the LSF CRC is
/// present. This implementation follows the specification's stated 240 bits.
/// If a capture from a live reflector says otherwise, ``byteCount`` and the
/// offsets below are the single place to change.
///
/// Scope: M17-3 parses the header so the connection layer can *recognise* a
/// stream datagram and route it. Interpreting ``payload`` (Codec 2), verifying
/// ``crc``, and stream reassembly all belong to M17-4.
public struct M17StreamPacket: Hashable, Sendable {
    /// Total datagram size, in bytes. See the type-level note.
    public static let byteCount = 56

    /// Size of the LICH/LSF field: 240 bits (Table 27, Part I Table 3.1).
    public static let lichByteCount = 30

    /// Size of the payload field: 128 bits (Table 27).
    public static let payloadByteCount = 16

    /// Size of the META field: 112 bits (Part I Table 3.1).
    public static let metadataByteCount = 14

    /// Bit 15 of FN: "including the last frame indicator at (FN & 0x8000)".
    public static let lastFrameFlag: UInt16 = 0x8000

    /// "Random bits, changed for each PTT or stream, but consistent from frame
    /// to frame within a stream."
    public let streamID: UInt16

    /// LSF DST — destination address (Part I §3.1.1).
    public let destination: M17Address

    /// LSF SRC — "always the callsign of the station transmitting".
    public let source: M17Address

    /// LSF TYPE (Part I §3.2.1).
    public let type: M17StreamType

    /// LSF META, 14 bytes. Contents depend on TYPE; not interpreted here.
    public let metadata: Data

    /// LSF CRC, the last two bytes of the 30-byte LSF (Part I §3.1.4).
    /// Carried through verbatim; not verified here (M17-4 owns CRC).
    public let lsfCRC: UInt16

    /// Frame number, including the last-frame flag in bit 15.
    public let frameNumber: UInt16

    /// 16 bytes of stream payload, "exactly as would be transmitted in an RF
    /// stream frame". Opaque to M17-3.
    public let payload: Data

    /// CRC16 over the entire packet. Carried through verbatim; not verified
    /// here (M17-4 owns CRC).
    public let crc: UInt16

    /// Whether this is the final frame of the stream (`FN & 0x8000`).
    public var isLastFrame: Bool { frameNumber & M17StreamPacket.lastFrameFlag != 0 }

    /// The frame counter with the last-frame flag masked off. Part I §3.2.2
    /// notes the effective capacity is 15 bits for exactly this reason.
    public var sequenceNumber: UInt16 { frameNumber & ~M17StreamPacket.lastFrameFlag }

    /// Whether this stream's audio can be played out — `.encrypted` streams
    /// never can (FR-2.5). Shorthand for `type.playability`.
    public var playability: M17StreamType.Playability { type.playability }

    public init(
        streamID: UInt16,
        destination: M17Address,
        source: M17Address,
        type: M17StreamType,
        metadata: Data,
        lsfCRC: UInt16,
        frameNumber: UInt16,
        payload: Data,
        crc: UInt16
    ) throws {
        guard metadata.count == M17StreamPacket.metadataByteCount else {
            throw M17PacketError.wrongLength(
                magic: "META", expected: [M17StreamPacket.metadataByteCount], actual: metadata.count)
        }
        guard payload.count == M17StreamPacket.payloadByteCount else {
            throw M17PacketError.wrongLength(
                magic: "payload", expected: [M17StreamPacket.payloadByteCount], actual: payload.count)
        }
        self.streamID = streamID
        self.destination = destination
        self.source = source
        self.type = type
        self.metadata = metadata
        self.lsfCRC = lsfCRC
        self.frameNumber = frameNumber
        self.payload = payload
        self.crc = crc
    }

    /// Parses a stream datagram.
    ///
    /// - Throws: `M17PacketError` unless the datagram opens with `"M17 "` and
    ///   is exactly ``byteCount`` bytes long.
    public static func parse(_ data: Data) throws -> M17StreamPacket {
        let bytes = [UInt8](data)
        guard bytes.count >= M17PacketMagic.byteCount else {
            throw M17PacketError.tooShort(byteCount: bytes.count)
        }
        guard M17PacketMagic(leading: bytes) == .stream else {
            throw M17PacketError.unknownMagic(Array(bytes.prefix(M17PacketMagic.byteCount)))
        }
        guard bytes.count == M17StreamPacket.byteCount else {
            throw M17PacketError.wrongLength(
                magic: M17PacketMagic.stream.rawValue,
                expected: [M17StreamPacket.byteCount],
                actual: bytes.count)
        }

        func uint16(at offset: Int) -> UInt16 {
            (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        }

        return try M17StreamPacket(
            streamID: uint16(at: 4),
            destination: M17Address(bytes: bytes[6..<12]),
            source: M17Address(bytes: bytes[12..<18]),
            type: M17StreamType(rawValue: uint16(at: 18)),
            metadata: Data(bytes[20..<34]),
            lsfCRC: uint16(at: 34),
            frameNumber: uint16(at: 36),
            payload: Data(bytes[38..<54]),
            crc: uint16(at: 54))
    }

    /// The datagram for this packet.
    public var data: Data {
        var out = Data(M17PacketMagic.stream.bytes)
        out.append(contentsOf: M17StreamPacket.bigEndian(streamID))
        out.append(contentsOf: destination.bytes)
        out.append(contentsOf: source.bytes)
        out.append(contentsOf: M17StreamPacket.bigEndian(type.rawValue))
        out.append(metadata)
        out.append(contentsOf: M17StreamPacket.bigEndian(lsfCRC))
        out.append(contentsOf: M17StreamPacket.bigEndian(frameNumber))
        out.append(payload)
        out.append(contentsOf: M17StreamPacket.bigEndian(crc))
        return out
    }

    private static func bigEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
}

// MARK: - Demultiplexer

/// Any datagram a reflector link can carry: a control packet or a stream
/// packet.
///
/// This is the single entry point the connection actor uses, so there is one
/// place where an unrecognised datagram is rejected rather than guessed at.
public enum M17ReflectorPacket: Hashable, Sendable {
    case control(M17ControlPacket)
    case stream(M17StreamPacket)

    /// The magic of the wrapped packet.
    public var magic: M17PacketMagic {
        switch self {
        case .control(let packet): return packet.magic
        case .stream: return .stream
        }
    }

    /// The datagram for the wrapped packet.
    public var data: Data {
        switch self {
        case .control(let packet): return packet.data
        case .stream(let packet): return packet.data
        }
    }

    /// - Throws: `M17PacketError` for anything that is not exactly one of the
    ///   seven documented layouts.
    public static func parse(_ data: Data) throws -> M17ReflectorPacket {
        let bytes = [UInt8](data)
        guard bytes.count >= M17PacketMagic.byteCount else {
            throw M17PacketError.tooShort(byteCount: bytes.count)
        }
        guard let magic = M17PacketMagic(leading: bytes) else {
            throw M17PacketError.unknownMagic(Array(bytes.prefix(M17PacketMagic.byteCount)))
        }
        if magic == .stream {
            return .stream(try M17StreamPacket.parse(data))
        }
        return .control(try M17ControlPacket.parse(data))
    }
}
