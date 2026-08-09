// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Byte order
//
// All multi-octet fields in this file are read and written **big-endian**.
//
// RFC ambiguous: RFC 5456 never uses the phrase "network byte order" or
// "big-endian" anywhere (the only occurrence of "endian" in the whole document
// is the codec name "16-bit linear little-endian", §8.7). Big-endian is an
// *inference* from the standard RFC bit-diagram convention used in Figures 5,
// 6, 7 and 8, where bit 0 is the most significant bit of the first octet
// transmitted. It is the only reading consistent with those diagrams. See
// `docs/reference/RFC5456-NOTES.md` §1 ("Byte order") and trap 24.
//
// The one place the RFC contradicts that inference — the APPARENT ADDR
// sockaddr image in §8.6.17, whose address-family field is byte-swapped
// relative to its port field — lives inside an information element and is
// therefore IAX-2's problem, not this file's.

// MARK: - Frame type

/// Frame Type, octet 10 of a Full Frame header (RFC 5456 §8.2).
///
/// Values the RFC does not define are preserved verbatim as `.unknown` so that
/// an unrecognised frame survives a parse/encode round trip unchanged
/// ("Refer to the IANA Registry for additional IAX Frame Type values", §8.2).
///
/// Equality and hashing are defined on `rawValue`, so `.unknown(0x01)` and
/// `.dtmf` compare equal — always build values through `init(rawValue:)`.
public enum IAX2FrameType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// `0x01` — a single DTMF digit; the subclass *is* the digit (§8.2.1).
    case dtmf
    /// `0x02` — audio; the subclass is a media format from §8.7 (§8.2.2).
    case voice
    /// `0x03` — video; the subclass is a media format from §8.7 (§8.2.3).
    case video
    /// `0x04` — control; the subclass is an `IAX2Control` value (§8.2.4, §8.3).
    case control
    /// `0x05` — Null. "Frames with the Null value MUST NOT be transmitted." (§8.2.5)
    case null
    /// `0x06` — IAX control; the subclass is an `IAX2Message` value (§8.2.6, §8.4).
    case iax
    /// `0x07` — UTF-8 text; the subclass is always 0 (§8.2.7).
    case text
    /// `0x08` — a single image; the subclass is a media format from §8.7 (§8.2.8).
    case image
    /// `0x09` — HTML; the subclass is an HTML command from §8.5 (§8.2.9).
    case html
    /// `0x0A` — comfort noise; the subclass is the level in -dBov (§8.2.10).
    case comfortNoise
    /// Any value not defined by RFC 5456 §8.2, preserved for round-tripping.
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .dtmf
        case 0x02: self = .voice
        case 0x03: self = .video
        case 0x04: self = .control
        case 0x05: self = .null
        case 0x06: self = .iax
        case 0x07: self = .text
        case 0x08: self = .image
        case 0x09: self = .html
        case 0x0A: self = .comfortNoise
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .dtmf: return 0x01
        case .voice: return 0x02
        case .video: return 0x03
        case .control: return 0x04
        case .null: return 0x05
        case .iax: return 0x06
        case .text: return 0x07
        case .image: return 0x08
        case .html: return 0x09
        case .comfortNoise: return 0x0A
        case .unknown(let raw): return raw
        }
    }

    /// Every frame type RFC 5456 §8.2 names, in table order.
    public static let defined: [IAX2FrameType] = [
        .dtmf, .voice, .video, .control, .null, .iax, .text, .image, .html, .comfortNoise,
    ]

    public static func == (lhs: IAX2FrameType, rhs: IAX2FrameType) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }

    public var description: String {
        switch self {
        case .dtmf: return "DTMF"
        case .voice: return "Voice"
        case .video: return "Video"
        case .control: return "Control"
        case .null: return "Null"
        case .iax: return "IAX"
        case .text: return "Text"
        case .image: return "Image"
        case .html: return "HTML"
        case .comfortNoise: return "ComfortNoise"
        case .unknown(let raw): return "Unknown(0x\(String(raw, radix: 16)))"
        }
    }
}

// MARK: - IAX subclasses (frame type 0x06)

/// IAX frame subclasses — the subclass of a frame of type `.iax` (RFC 5456 §8.4).
///
/// The full §8.4 table. Values `0x1F` and `0x23`–`0x25` are "Reserved for
/// future use" and deliberately have no case; `init(rawValue:)` returns `nil`
/// for them, as it does for any other unassigned value. Unknown subclasses
/// still round-trip because `IAX2FullFrame` stores the wire octet
/// (`IAX2Subclass`), not this enum.
///
/// RFC ambiguous: §6.5.6 describes a "TXMEDIA" message and Figure 4 uses it,
/// but the §8.4 table assigns it no value, so it cannot appear here. We do not
/// implement path optimisation, so nothing depends on it.
public enum IAX2Message: UInt8, Hashable, Sendable, CaseIterable {
    /// Initiate a new call.
    case new = 0x01
    /// Ping request.
    case ping = 0x02
    /// Ping or poke reply.
    case pong = 0x03
    /// Explicit acknowledgment.
    case ack = 0x04
    /// Initiate call tear-down. Not to be confused with `IAX2Control.hangup`
    /// (frame type `0x04`, subclass `0x01`) — see notes trap 18.
    case hangup = 0x05
    /// Reject a call.
    case reject = 0x06
    /// Accept a call.
    case accept = 0x07
    /// Authentication request.
    case authreq = 0x08
    /// Authentication reply.
    case authrep = 0x09
    /// Invalid message.
    case inval = 0x0A
    /// Lag request.
    case lagrq = 0x0B
    /// Lag reply.
    case lagrp = 0x0C
    /// Registration request.
    case regreq = 0x0D
    /// Registration authentication.
    case regauth = 0x0E
    /// Registration acknowledgement.
    case regack = 0x0F
    /// Registration reject.
    case regrej = 0x10
    /// Registration release.
    case regrel = 0x11
    /// Video/Voice retransmit request.
    case vnak = 0x12
    /// Dialplan request.
    case dpreq = 0x13
    /// Dialplan reply.
    case dprep = 0x14
    /// Dial.
    case dial = 0x15
    /// Transfer request.
    case txreq = 0x16
    /// Transfer connect.
    case txcnt = 0x17
    /// Transfer accept.
    case txacc = 0x18
    /// Transfer ready.
    case txready = 0x19
    /// Transfer release.
    case txrel = 0x1A
    /// Transfer reject.
    case txrej = 0x1B
    /// Halt audio/video [media] transmission.
    case quelch = 0x1C
    /// Resume audio/video [media] transmission.
    case unquelch = 0x1D
    /// Poke request.
    case poke = 0x1E
    // 0x1F — Reserved for future use (§8.4).
    /// Message waiting indication.
    case mwi = 0x20
    /// Unsupported message.
    case unsupport = 0x21
    /// Remote transfer request.
    case transfer = 0x22
    // 0x23–0x25 — Reserved for future use (§8.4).

    /// The five messages that do **not** advance OSeqno (§7). Kept here so
    /// IAX-3 does not have to re-derive the list.
    public static let sequenceNumberExempt: Set<IAX2Message> = [.ack, .inval, .txcnt, .txacc, .vnak]
}

// MARK: - Control subclasses (frame type 0x04)

/// Control frame subclasses — the subclass of a frame of type `.control`
/// (RFC 5456 §8.3).
///
/// Values `0x02`, `0x06`, `0x07` and `0x0A` are "Reserved for future use" and
/// have no case.
public enum IAX2Control: UInt8, Hashable, Sendable, CaseIterable {
    /// The call has been hungup at the remote end. Distinct from
    /// `IAX2Message.hangup` — see notes trap 18.
    case hangup = 0x01
    // 0x02 — Reserved for future use (§8.3).
    /// Remote end is ringing (ring-back).
    case ringing = 0x03
    /// Remote end has answered.
    case answer = 0x04
    /// Remote end is busy.
    case busy = 0x05
    // 0x06, 0x07 — Reserved for future use (§8.3).
    /// The call is congested.
    case congestion = 0x08
    /// Flash hook.
    case flashHook = 0x09
    // 0x0A — Reserved for future use (§8.3).
    /// Device-specific options are being transmitted.
    case option = 0x0B
    /// Key Radio. Present because of the amateur radio use case (§6.3.1).
    case keyRadio = 0x0C
    /// Unkey Radio.
    case unkeyRadio = 0x0D
    /// Call is in progress.
    case callProgress = 0x0E
    /// Call is proceeding.
    case callProceeding = 0x0F
    /// Call is placed on hold.
    case hold = 0x10
    /// Call is taken off hold.
    case unhold = 0x11
}

// MARK: - Subclass field and the C bit

/// Octet 11 of a Full Frame header: the `C` bit plus a 7-bit subclass field
/// (RFC 5456 §8.1.1).
///
/// ```
///  bit 0    bits 1..7
/// +-----+---------------+
/// |  C  |  subclass[7]  |
/// +-----+---------------+
/// ```
///
/// > "This bit determines how the remaining 7 bits of the Subclass field are
/// > coded. If the 'C' bit is set to 1, the Subclass value is interpreted as a
/// > power of 2. If it is not set, the Subclass value is interpreted as a
/// > simple 7-bit unsigned integer." (§8.1.1)
///
/// The wire octet is the stored property, so every subclass — defined,
/// reserved or nonsense — round-trips byte-for-byte. `value` applies the C-bit
/// rule on demand.
///
/// RFC ambiguous — overlap: a value that is both ≤ 127 *and* an exact power of
/// two (1, 2, 4, 8, 16, 32, 64) has two legal encodings. G.711 µ-law (4) may
/// arrive as `0x04` (C = 0, field 4) or as `0x82` (C = 1, field 2); RFC 5456
/// does not say which a sender MUST use. A decoder therefore MUST accept both,
/// which `value` does. For *encoding* we follow the convention recommended in
/// `docs/reference/RFC5456-NOTES.md` §6: media formats are §8.7 bitmask values
/// and go out with C = 1 (`init(mediaFormat:)`); IAX, Control and HTML
/// subclasses are ordinals ≤ 127 and go out with C = 0 (`init(value:)`).
public struct IAX2Subclass: Hashable, Sendable, CustomStringConvertible {
    /// Octet 11 exactly as it appears on the wire, C bit included.
    public let rawByte: UInt8

    public init(rawByte: UInt8) {
        self.rawByte = rawByte
    }

    /// The `C` bit: `true` when the 7-bit field is a base-2 exponent.
    public var isPowerEncoded: Bool { rawByte & 0x80 != 0 }

    /// The low 7 bits, before the C-bit rule is applied. Range 0…127.
    public var field: UInt8 { rawByte & 0x7F }

    /// The decoded subclass value: `field` when C = 0, `1 << field` when C = 1.
    ///
    /// `nil` when C = 1 and `field` ≥ 32, i.e. when the encoded value does not
    /// fit the 32-bit media-format bitmask domain of §8.7. RFC 5456 permits
    /// exponents up to 127, but assigns no meaning above `1 << 21` (H.264) and
    /// every field that consumes a subclass value — FORMAT and CAPABILITY IEs
    /// (§8.6.7, §8.6.8), §8.7 itself — is 32 bits wide.
    public var value: UInt32? {
        guard isPowerEncoded else { return UInt32(field) }
        guard field < 32 else { return nil }
        return UInt32(1) << UInt32(field)
    }

    /// Encodes `value` with the general §8.1.1 rule: values ≤ 127 go out as a
    /// plain 7-bit integer (C = 0); larger values must be an exact power of two
    /// and go out as an exponent (C = 1). Returns `nil` for a value above 127
    /// that is not a power of two — such a value is not representable in a
    /// subclass field at all.
    public init?(value: UInt32) {
        if value <= 0x7F {
            self.init(rawByte: UInt8(value))
            return
        }
        guard value.nonzeroBitCount == 1 else { return nil }
        self.init(rawByte: 0x80 | UInt8(value.trailingZeroBitCount))
    }

    /// Encodes a §8.7 media format bitmask, always with C = 1.
    ///
    /// G.711 µ-law is `0x0000_0004` = `1 << 2`, which is field 2, which is
    /// subclass octet `0x82` (§8.7, §8.1.1; notes §6 and trap 3). Returns `nil`
    /// unless exactly one bit is set — "Only one CODEC MUST be specified"
    /// (§8.6.8), and with C = 1 a subclass field can only ever name one.
    public init?(mediaFormat: UInt32) {
        guard mediaFormat.nonzeroBitCount == 1 else { return nil }
        self.init(rawByte: 0x80 | UInt8(mediaFormat.trailingZeroBitCount))
    }

    /// An IAX subclass (§8.4). All defined values are ≤ 127, so C = 0.
    public init(_ message: IAX2Message) {
        self.init(rawByte: message.rawValue)
    }

    /// A Control subclass (§8.3). All defined values are ≤ 127, so C = 0.
    public init(_ control: IAX2Control) {
        self.init(rawByte: control.rawValue)
    }

    /// A literal 7-bit subclass with C = 0. Traps if `value` exceeds 127.
    public static func literal(_ value: UInt8) -> IAX2Subclass {
        precondition(value <= 0x7F, "a C = 0 subclass field holds 7 bits (RFC 5456 §8.1.1)")
        return IAX2Subclass(rawByte: value)
    }

    /// A power-of-two subclass with C = 1, naming `1 << exponent`.
    /// Traps if `exponent` exceeds 127.
    public static func powerOfTwo(exponent: UInt8) -> IAX2Subclass {
        precondition(exponent <= 0x7F, "a C = 1 subclass field holds a 7-bit exponent (RFC 5456 §8.1.1)")
        return IAX2Subclass(rawByte: 0x80 | exponent)
    }

    public var description: String {
        if isPowerEncoded {
            return "C=1 1<<\(field) (0x\(String(format: "%02x", rawByte)))"
        }
        return "C=0 \(field) (0x\(String(format: "%02x", rawByte)))"
    }
}

// MARK: - Errors

/// Why a datagram could not be understood as a Full or Mini Frame.
public enum IAX2FrameError: Error, Equatable, CustomStringConvertible {
    /// The datagram is shorter than the header its own first octets claim:
    /// 12 octets for a Full Frame (§8.1.1), 4 for a Mini Frame (§8.1.2).
    case tooShort(expected: Int, actual: Int)

    /// The first 16 bits were all zero, which identifies a Meta Frame —
    /// trunk or video (§8.1.3.1, §8.1.3.2). We do not implement trunking, so
    /// these are rejected rather than mis-parsed as a Mini Frame. RFC 5456
    /// defines no message for refusing one; the caller should simply drop it.
    case metaFrame

    /// A frame that parses structurally but violates a normative rule.
    /// Produced by `validateForTransmission()`, never by `parse(_:)` — once
    /// length and the Meta Frame test are past, every remaining bit pattern is
    /// a legal, round-trippable frame.
    case malformed(reason: String)

    public var description: String {
        switch self {
        case .tooShort(let expected, let actual):
            return "IAX2 frame too short: need at least \(expected) octets, got \(actual)"
        case .metaFrame:
            return "IAX2 meta frame (RFC 5456 §8.1.3): trunking is not implemented"
        case .malformed(let reason):
            return "malformed IAX2 frame: \(reason)"
        }
    }
}

// MARK: - Full frame

/// A Full Frame: 12-octet header plus payload (RFC 5456 §8.1.1, Figure 5).
///
/// ```
///                      1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |F|     Source Call Number      |R|   Destination Call Number   |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                            time-stamp                         |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |    OSeqno     |    ISeqno     |   Frame Type  |C|  Subclass   |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                             Data                              |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// The `F` bit is implicit: a `IAX2FullFrame` always encodes with F = 1.
public struct IAX2FullFrame: Hashable, Sendable {
    /// The header length RFC 5456 §8.1.1 fixes: "The standard Full Frame
    /// header length is 12 octets."
    public static let headerLength = 12

    /// The largest value a 15-bit call-number field can hold (§8.1.1).
    public static let maximumCallNumber: UInt16 = 0x7FFF

    /// 15 bits: the call number *this* sender uses for the call (§8.1.1).
    public let sourceCallNumber: UInt16

    /// 15 bits: the peer's source call number, or 0 for "none yet" — a NEW has
    /// no destination call number (§6.2.2) and "A POKE MUST have 0 as its
    /// destination call number" (§6.7.1), so 0 is normal, not malformed.
    public let destinationCallNumber: UInt16

    /// The `R` bit. 0 on first transmission, 1 on every retransmitted copy
    /// (§8.1.1). It shares its octet with the destination call number but is
    /// **not** part of it (notes trap 1).
    public let isRetransmission: Bool

    /// 32-bit milliseconds since the first transmission of the call (§8.1.1,
    /// §6.2.2). Each peer keeps its own clock; the two are independent.
    public let timestamp: UInt32

    /// Outbound stream sequence number (§8.1.1). Owned by IAX-3.
    public let oSeqno: UInt8

    /// Inbound stream sequence number (§8.1.1). Owned by IAX-3.
    public let iSeqno: UInt8

    /// Frame Type, octet 10 (§8.2).
    public let type: IAX2FrameType

    /// The C bit and 7-bit subclass field, octet 11 (§8.1.1).
    public let subclass: IAX2Subclass

    /// Everything after the 12-octet header, opaque here. For a frame of type
    /// `.iax` these are information elements (§8.6) — IAX-2 parses those; for
    /// media frames it is the media payload.
    public let payload: [UInt8]

    /// - Precondition: both call numbers fit 15 bits (§8.1.1).
    public init(
        sourceCallNumber: UInt16,
        destinationCallNumber: UInt16,
        isRetransmission: Bool = false,
        timestamp: UInt32,
        oSeqno: UInt8,
        iSeqno: UInt8,
        type: IAX2FrameType,
        subclass: IAX2Subclass,
        payload: [UInt8] = []
    ) {
        precondition(
            sourceCallNumber <= Self.maximumCallNumber,
            "source call number is a 15-bit field (RFC 5456 §8.1.1)")
        precondition(
            destinationCallNumber <= Self.maximumCallNumber,
            "destination call number is a 15-bit field (RFC 5456 §8.1.1)")
        self.sourceCallNumber = sourceCallNumber
        self.destinationCallNumber = destinationCallNumber
        self.isRetransmission = isRetransmission
        self.timestamp = timestamp
        self.oSeqno = oSeqno
        self.iSeqno = iSeqno
        self.type = type
        self.subclass = subclass
        self.payload = payload
    }

    /// The same frame with the `R` bit set, for a retransmission. Everything
    /// else — OSeqno and the time-stamp included — is retransmitted unchanged;
    /// RFC 5456 gives no rule permitting either to be updated (§8.1.1, §7).
    public func retransmitted() -> IAX2FullFrame {
        IAX2FullFrame(
            sourceCallNumber: sourceCallNumber,
            destinationCallNumber: destinationCallNumber,
            isRetransmission: true,
            timestamp: timestamp,
            oSeqno: oSeqno,
            iSeqno: iSeqno,
            type: type,
            subclass: subclass,
            payload: payload)
    }

    /// The subclass read as an IAX message, when this is a frame of type
    /// `.iax` carrying a subclass RFC 5456 §8.4 defines. `nil` otherwise —
    /// including for reserved and unassigned subclasses, which the caller
    /// should answer with UNSUPPORT (§6.9.5) using `subclass.rawByte`.
    public var iaxMessage: IAX2Message? {
        guard type == .iax, !subclass.isPowerEncoded else { return nil }
        return IAX2Message(rawValue: subclass.field)
    }

    /// The subclass read as a control message, when this is a frame of type
    /// `.control` carrying a subclass RFC 5456 §8.3 defines.
    public var control: IAX2Control? {
        guard type == .control, !subclass.isPowerEncoded else { return nil }
        return IAX2Control(rawValue: subclass.field)
    }

    /// The subclass read as a §8.7 media format bitmask, for `.voice`,
    /// `.video` and `.image` frames. Accepts both encodings of a small power
    /// of two, per the overlap note on `IAX2Subclass`: a Voice frame with
    /// subclass octet `0x82` and one with `0x04` both yield `0x0000_0004`.
    public var mediaFormat: UInt32? {
        switch type {
        case .voice, .video, .image: return subclass.value
        default: return nil
        }
    }
}

// MARK: - Mini frame

/// A Mini Frame: 4-octet header plus media payload (RFC 5456 §8.1.2, Figure 6).
///
/// ```
///                      1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |F|     Source call number      |            time-stamp         |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                             Data                              |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// There is no destination call number, no sequence number, no frame type and
/// no subclass. Type is implicitly Voice (2) and the codec is whatever the most
/// recent *full* voice frame of the call named — not what the ACCEPT's FORMAT
/// IE said (§8.1.2; notes trap 20). Mini Frames are unreliable and are never
/// ACKed (§6.10), and they MUST NOT carry information elements (§6).
///
/// The `F` bit is implicit: a `IAX2MiniFrame` always encodes with F = 0.
public struct IAX2MiniFrame: Hashable, Sendable {
    /// "Mini Frames are so named because their header is a minimal 4 octets."
    /// (§8.1.2)
    public static let headerLength = 4

    /// 15 bits: the transmitting peer's call number (§8.1.2).
    ///
    /// Never 0. A Mini Frame with source call number 0 encodes to a first
    /// 16-bit word of all zeroes, which is by definition a Meta Frame
    /// (§8.1.3.1, §8.1.3.2) — so such a frame could not be parsed back as a
    /// Mini Frame. This is why source call numbers are allocated from 1…32767
    /// (notes §15, trap 17).
    public let sourceCallNumber: UInt16

    /// The low 16 bits of the sender's 32-bit call time-stamp (§8.1.2). It
    /// wraps every 65.536 s; IAX-6 owns re-expanding it against the call clock.
    public let timestamp: UInt16

    /// The media payload. Length is not constrained by the RFC.
    public let payload: [UInt8]

    /// - Precondition: `sourceCallNumber` is in 1…32767 (§8.1.2, §8.1.3, notes §15).
    public init(sourceCallNumber: UInt16, timestamp: UInt16, payload: [UInt8] = []) {
        precondition(
            sourceCallNumber >= 1 && sourceCallNumber <= IAX2FullFrame.maximumCallNumber,
            "a mini frame source call number is a 15-bit field and MUST NOT be 0, "
                + "or the frame is indistinguishable from a meta frame (RFC 5456 §8.1.2, §8.1.3)")
        self.sourceCallNumber = sourceCallNumber
        self.timestamp = timestamp
        self.payload = payload
    }
}

// MARK: - Frame

/// One IAX2 datagram: either a Full Frame or a Mini Frame (RFC 5456 §8.1).
///
/// Meta Frames (§8.1.3) are recognised but not represented — `parse(_:)`
/// rejects them with `IAX2FrameError.metaFrame`, because this client does not
/// implement trunking and must not mistake a trunk header for media.
public enum IAX2Frame: Hashable, Sendable {
    case full(IAX2FullFrame)
    case mini(IAX2MiniFrame)

    /// The shortest datagram that could be any kind of frame — a Mini Frame
    /// header (§8.1.2).
    public static let minimumLength = IAX2MiniFrame.headerLength

    // MARK: Parsing

    /// Decodes one received datagram.
    ///
    /// The demultiplexing order is fixed by §8.1.3.1/§8.1.3.2 and must not be
    /// rearranged (notes trap 17):
    ///
    /// 1. first 16 bits all zero → Meta Frame → rejected;
    /// 2. else `F` bit set → Full Frame, 12-octet header;
    /// 3. else → Mini Frame, 4-octet header.
    ///
    /// Testing `F` before the Meta test would classify every Meta Frame as a
    /// Mini Frame and feed trunk headers to the audio decoder.
    public static func parse(_ data: Data) throws -> IAX2Frame {
        let octets = [UInt8](data)

        // Two octets are needed before the Meta Frame test can even be applied.
        guard octets.count >= 2 else {
            throw IAX2FrameError.tooShort(expected: minimumLength, actual: octets.count)
        }

        // 1. Meta Frame: "the first 16 bits will always be zero in any Meta
        //    Frame, whereas Full or Mini Frames will have either the 'F' bit
        //    set or some (nonzero) value for the source call number (or both)."
        //    (§8.1.3.1, §8.1.3.2)
        if octets[0] == 0 && octets[1] == 0 {
            throw IAX2FrameError.metaFrame
        }

        // 2. Full Frame: F = 1 (§8.1.1).
        if octets[0] & 0x80 != 0 {
            guard octets.count >= IAX2FullFrame.headerLength else {
                throw IAX2FrameError.tooShort(
                    expected: IAX2FullFrame.headerLength, actual: octets.count)
            }
            // Mask with 0x7FFF, not 0xFFFF: the top bit of each 16-bit word is
            // the F or R flag, not part of the call number (notes trap 1).
            let source = be16(octets, 0) & 0x7FFF
            let destination = be16(octets, 2) & 0x7FFF
            let retransmission = octets[2] & 0x80 != 0
            let timestamp = be32(octets, 4)
            return .full(
                IAX2FullFrame(
                    sourceCallNumber: source,
                    destinationCallNumber: destination,
                    isRetransmission: retransmission,
                    timestamp: timestamp,
                    oSeqno: octets[8],
                    iSeqno: octets[9],
                    type: IAX2FrameType(rawValue: octets[10]),
                    subclass: IAX2Subclass(rawByte: octets[11]),
                    payload: Array(octets[IAX2FullFrame.headerLength...])))
        }

        // 3. Mini Frame (§8.1.2). F = 0 and the source call number is nonzero,
        //    or step 1 would have caught it.
        guard octets.count >= IAX2MiniFrame.headerLength else {
            throw IAX2FrameError.tooShort(
                expected: IAX2MiniFrame.headerLength, actual: octets.count)
        }
        return .mini(
            IAX2MiniFrame(
                sourceCallNumber: be16(octets, 0) & 0x7FFF,
                timestamp: be16(octets, 2),
                payload: Array(octets[IAX2MiniFrame.headerLength...])))
    }

    // MARK: Encoding

    /// Serialises the frame for transmission. Always the inverse of
    /// `parse(_:)`: `try IAX2Frame.parse(frame.encoded()) == frame`.
    public func encoded() -> Data {
        switch self {
        case .full(let frame):
            var octets = [UInt8]()
            octets.reserveCapacity(IAX2FullFrame.headerLength + frame.payload.count)
            // Octets 0–1: F = 1, then the 15-bit source call number (§8.1.1).
            octets.append(0x80 | UInt8(truncatingIfNeeded: frame.sourceCallNumber >> 8))
            octets.append(UInt8(truncatingIfNeeded: frame.sourceCallNumber))
            // Octets 2–3: R, then the 15-bit destination call number (§8.1.1).
            let retransmitBit: UInt8 = frame.isRetransmission ? 0x80 : 0x00
            octets.append(retransmitBit | UInt8(truncatingIfNeeded: frame.destinationCallNumber >> 8))
            octets.append(UInt8(truncatingIfNeeded: frame.destinationCallNumber))
            // Octets 4–7: 32-bit time-stamp, big-endian (§8.1.1).
            appendBE32(&octets, frame.timestamp)
            // Octets 8–11: OSeqno, ISeqno, Frame Type, C + Subclass (§8.1.1).
            octets.append(frame.oSeqno)
            octets.append(frame.iSeqno)
            octets.append(frame.type.rawValue)
            octets.append(frame.subclass.rawByte)
            octets.append(contentsOf: frame.payload)
            return Data(octets)

        case .mini(let frame):
            var octets = [UInt8]()
            octets.reserveCapacity(IAX2MiniFrame.headerLength + frame.payload.count)
            // Octets 0–1: F = 0, then the 15-bit source call number (§8.1.2).
            octets.append(UInt8(truncatingIfNeeded: frame.sourceCallNumber >> 8) & 0x7F)
            octets.append(UInt8(truncatingIfNeeded: frame.sourceCallNumber))
            // Octets 2–3: 16-bit time-stamp, big-endian (§8.1.2).
            octets.append(UInt8(truncatingIfNeeded: frame.timestamp >> 8))
            octets.append(UInt8(truncatingIfNeeded: frame.timestamp))
            octets.append(contentsOf: frame.payload)
            return Data(octets)
        }
    }

    // MARK: Accessors

    /// The transmitting peer's call number, whichever form the frame takes.
    public var sourceCallNumber: UInt16 {
        switch self {
        case .full(let frame): return frame.sourceCallNumber
        case .mini(let frame): return frame.sourceCallNumber
        }
    }

    /// The Full Frame, or `nil` for a Mini Frame.
    public var fullFrame: IAX2FullFrame? {
        if case .full(let frame) = self { return frame }
        return nil
    }

    /// The Mini Frame, or `nil` for a Full Frame.
    public var miniFrame: IAX2MiniFrame? {
        if case .mini(let frame) = self { return frame }
        return nil
    }

    /// The payload, whichever form the frame takes.
    public var payload: [UInt8] {
        switch self {
        case .full(let frame): return frame.payload
        case .mini(let frame): return frame.payload
        }
    }

    // MARK: Validation

    /// Checks the normative rules that constrain what we may *send*, as
    /// distinct from what we must tolerate on receive.
    ///
    /// `parse(_:)` deliberately does not apply these — RFC 5456 §8.1.1's
    /// header admits no structurally invalid bit pattern once length and the
    /// Meta Frame test are past, and being strict about a peer's frames would
    /// break `parse(encoded())` identity for the frames we must still be able
    /// to represent.
    ///
    /// - Throws: `IAX2FrameError.malformed` describing the violated rule.
    public func validateForTransmission() throws {
        switch self {
        case .full(let frame):
            // "Frames with the Null value MUST NOT be transmitted." (§8.2.5)
            if frame.type == .null {
                throw IAX2FrameError.malformed(
                    reason: "a Null frame (type 0x05) MUST NOT be transmitted (RFC 5456 §8.2.5)")
            }
        case .mini(let frame):
            // Belt and braces: `IAX2MiniFrame.init` already rejects 0.
            if frame.sourceCallNumber == 0 {
                throw IAX2FrameError.malformed(
                    reason: "a mini frame with source call number 0 is indistinguishable "
                        + "from a meta frame (RFC 5456 §8.1.3)")
            }
        }
    }
}

// MARK: - Big-endian helpers

/// Reads a big-endian 16-bit field at `offset`. See the byte-order note at the
/// top of this file: big-endian is inferred from the RFC's bit diagrams.
private func be16(_ octets: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(octets[offset]) << 8 | UInt16(octets[offset + 1])
}

/// Reads a big-endian 32-bit field at `offset`.
private func be32(_ octets: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(octets[offset]) << 24
        | UInt32(octets[offset + 1]) << 16
        | UInt32(octets[offset + 2]) << 8
        | UInt32(octets[offset + 3])
}

private func appendBE32(_ octets: inout [UInt8], _ value: UInt32) {
    octets.append(UInt8(truncatingIfNeeded: value >> 24))
    octets.append(UInt8(truncatingIfNeeded: value >> 16))
    octets.append(UInt8(truncatingIfNeeded: value >> 8))
    octets.append(UInt8(truncatingIfNeeded: value))
}
