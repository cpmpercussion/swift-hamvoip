// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Media format bitmask (RFC 5456 §8.7, notes §8)

/// The 32-bit codec/format bitmask used by the CAPABILITY IE (`0x08`, OR-able
/// set), the FORMAT IE (`0x09`, exactly one bit), and — via the `C`-bit
/// power-of-two subclass encoding (§8.1.1) — by the subclass byte of Voice,
/// Video, and Image frames.
///
/// Verified twice against RFC 5456 §8.7. Bits 14 and 15 are gaps the RFC
/// does not assign; nothing above bit 21 is defined ("Refer to the IANA
/// Registry for any additional IAX Media Format values", §8.7).
public struct MediaFormat: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// G.723.1 — 4-, 20-, and 24-byte frames of 240 samples.
    public static let g723_1 = MediaFormat(rawValue: 1 << 0)
    /// GSM Full Rate — 33-byte chunks of 160 samples, or 65-byte chunks of 320.
    public static let gsmFullRate = MediaFormat(rawValue: 1 << 1)
    /// G.711 µ-law. `0x00000004`, i.e. `1 << 2` — the codec this project uses.
    /// 1 byte per sample, 8 kHz default sampling rate (§8.6.32) => 160 bytes
    /// per 20 ms frame.
    public static let g711MuLaw = MediaFormat(rawValue: 1 << 2)
    /// G.711 a-law — 1 byte per sample.
    public static let g711ALaw = MediaFormat(rawValue: 1 << 3)
    /// G.726.
    public static let g726 = MediaFormat(rawValue: 1 << 4)
    /// IMA ADPCM — 1 byte per 2 samples.
    public static let imaADPCM = MediaFormat(rawValue: 1 << 5)
    /// 16-bit linear little-endian — 2 bytes per sample.
    public static let linear16LittleEndian = MediaFormat(rawValue: 1 << 6)
    /// LPC10 — variable-size frame of 172 samples.
    public static let lpc10 = MediaFormat(rawValue: 1 << 7)
    /// G.729 — 20-byte chunks of 172 samples.
    public static let g729 = MediaFormat(rawValue: 1 << 8)
    /// Speex — variable.
    public static let speex = MediaFormat(rawValue: 1 << 9)
    /// iLBC — 50 bytes per 240 samples.
    public static let ilbc = MediaFormat(rawValue: 1 << 10)
    /// G.726 AAL2.
    public static let g726AAL2 = MediaFormat(rawValue: 1 << 11)
    /// G.722 — 16 kHz ADPCM.
    public static let g722 = MediaFormat(rawValue: 1 << 12)
    /// AMR — variable.
    public static let amr = MediaFormat(rawValue: 1 << 13)
    // Bits 14 (0x4000) and 15 (0x8000) are not assigned by RFC 5456.
    /// JPEG (image).
    public static let jpeg = MediaFormat(rawValue: 1 << 16)
    /// PNG (image).
    public static let png = MediaFormat(rawValue: 1 << 17)
    /// H.261 (video).
    public static let h261 = MediaFormat(rawValue: 1 << 18)
    /// H.263 (video).
    public static let h263 = MediaFormat(rawValue: 1 << 19)
    /// H.263+ (video).
    public static let h263p = MediaFormat(rawValue: 1 << 20)
    /// H.264 (video).
    public static let h264 = MediaFormat(rawValue: 1 << 21)
}

// MARK: - Small bitmask/structure IE payloads (RFC 5456 §8.6 sub-tables)

/// AUTHMETHODS IE (`0x0e`) 2-octet bitmask (§8.6.13).
public struct IEAuthMethods: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// `0x0001`, "Reserved (was Plaintext)" (§8.6.13). Cleartext auth "has
    /// been eliminated" (§10) — this flag is modeled only so a peer that
    /// still advertises it can be recognised and rejected, never acted on.
    public static let reservedWasPlaintext = IEAuthMethods(rawValue: 0x0001)
    /// `0x0002` MD5 — the only method this project implements (IAX-4).
    public static let md5 = IEAuthMethods(rawValue: 0x0002)
    /// `0x0004` RSA — recognised, not implemented (out of scope for v1).
    public static let rsa = IEAuthMethods(rawValue: 0x0004)
}

/// DPSTATUS IE (`0x14`) 2-octet bitmask (§8.6.19). "Exactly one of the low 3
/// bits MUST be set, and zero, 1, or 2 of the high 2 bits MAY be set."
public struct IEDialplanStatus: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let exists = IEDialplanStatus(rawValue: 0x0001)
    public static let canExist = IEDialplanStatus(rawValue: 0x0002)
    public static let nonExistent = IEDialplanStatus(rawValue: 0x0004)
    public static let retainDialtone = IEDialplanStatus(rawValue: 0x4000)
    public static let moreDigitsMayMatch = IEDialplanStatus(rawValue: 0x8000)
}

/// ENCRYPTION IE (`0x2b`) method bitmask (§8.6.34). Not applied directly to
/// the `encryption` IE case's raw bytes because the RFC's own diagram and
/// prose disagree on the IE's width (trap 15 in the notes) — this is offered
/// as a decoding convenience for whichever width a peer actually sends.
public struct IEEncryptionMethods: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let aes128 = IEEncryptionMethods(rawValue: 0x0001)
}

/// MSGCOUNT IE (`0x18`) payload (§8.6.23): high octet = old messages, low
/// octet = new messages. "all-1s = at least one" per the notes; read here as
/// a per-byte sentinel (`0xFF` in that byte), since the RFC does not state
/// whether the sentinel is per-byte or spans the whole 16-bit word.
public struct MessageCount: Sendable, Equatable {
    public let old: UInt8
    public let new: UInt8

    public init(old: UInt8, new: UInt8) {
        self.old = old
        self.new = new
    }

    /// `true` if the old-message count byte is the "at least one" sentinel.
    public var oldIsAtLeastOneUnknownCount: Bool { old == 0xFF }
    /// `true` if the new-message count byte is the "at least one" sentinel.
    public var newIsAtLeastOneUnknownCount: Bool { new == 0xFF }
}

/// RR LOSS IE (`0x2f`) payload (§8.6.37): 1 octet loss percent, then a
/// 3-octet (24-bit) big-endian loss count.
public struct RRLoss: Sendable, Equatable {
    public let percent: UInt8
    public let count: UInt32 // only the low 24 bits are meaningful

    public init(percent: UInt8, count: UInt32) {
        self.percent = percent
        self.count = count & 0x00FF_FFFF
    }
}

/// CALLINGTNS IE (`0x28`) payload (§8.6.31). **RFC ambiguous** (notes §7):
/// the prose describes a 2-octet field of network-identification plan (low 4
/// bits) + type of network (next 3 bits) in the first octet, then "the
/// network identification as UTF-8" in the second octet — which cannot hold
/// a multi-character UTF-8 identification in a fixed 2-octet IE. We preserve
/// both raw bytes rather than guess a longer layout; building a fresh one
/// for a NEW message uses `0x00, 0x00` (Unknown / User Specified) per the
/// notes' documented choice.
public struct CallingTNS: Sendable, Equatable {
    /// Low 4 bits: network identification plan. Next 3 bits: type of network.
    public let planAndTypeByte: UInt8
    /// "The network identification as UTF-8" (§8.6.31) — one octet only.
    public let networkIDByte: UInt8

    public init(planAndTypeByte: UInt8, networkIDByte: UInt8) {
        self.planAndTypeByte = planAndTypeByte
        self.networkIDByte = networkIDByte
    }

    /// `0x00, 0x00` — Unknown plan / User Specified network, the value the
    /// notes document sending on an outbound NEW.
    public static let unknown = CallingTNS(planAndTypeByte: 0x00, networkIDByte: 0x00)
}

/// DATETIME IE (`0x1f`) payload (§8.6.28): a packed 32-bit big-endian word,
/// most-significant field first: `year(7) | month(4) | day(5) | hour(5) |
/// minute(6) | second(5)`. Year is offset from 2000; month is 1-based;
/// timezone MUST be UTC. Strictly informational (never affects call timing —
/// that's the per-call millisecond time-stamp in the frame header, a
/// different quantity entirely, see notes §11 / trap 8).
public struct PackedDateTime: Sendable, Equatable {
    public let yearOffsetFrom2000: UInt8 // 7 bits
    public let month: UInt8 // 4 bits, 1-based
    public let day: UInt8 // 5 bits
    public let hour: UInt8 // 5 bits
    public let minute: UInt8 // 6 bits
    public let second: UInt8 // 5 bits

    public init(yearOffsetFrom2000: UInt8, month: UInt8, day: UInt8, hour: UInt8, minute: UInt8, second: UInt8) {
        self.yearOffsetFrom2000 = yearOffsetFrom2000 & 0x7F
        self.month = month & 0x0F
        self.day = day & 0x1F
        self.hour = hour & 0x1F
        self.minute = minute & 0x3F
        self.second = second & 0x1F
    }

    public init(rawValue: UInt32) {
        second = UInt8(rawValue & 0x1F)
        minute = UInt8((rawValue >> 5) & 0x3F)
        hour = UInt8((rawValue >> 11) & 0x1F)
        day = UInt8((rawValue >> 16) & 0x1F)
        month = UInt8((rawValue >> 21) & 0x0F)
        yearOffsetFrom2000 = UInt8((rawValue >> 25) & 0x7F)
    }

    public var rawValue: UInt32 {
        UInt32(second & 0x1F)
            | (UInt32(minute & 0x3F) << 5)
            | (UInt32(hour & 0x1F) << 11)
            | (UInt32(day & 0x1F) << 16)
            | (UInt32(month & 0x0F) << 21)
            | (UInt32(yearOffsetFrom2000 & 0x7F) << 25)
    }
}

/// APPARENT ADDR IE (`0x12`) payload (§8.6.17). A verbatim image of a POSIX
/// `sockaddr_in` (16 octets of *data*, per trap 14 in the notes — the "18
/// octets" in the RFC's prose counts the 2-octet IE header too) or
/// `sockaddr_in6` (28 octets of data).
///
/// **The address-family field's byte order is genuinely ambiguous** (notes
/// §7, trap 13). The RFC's own IPv4 example shows family bytes `0x02, 0x00`
/// next to port bytes `0x11, 0xd9` (= 4569) in the *same* structure: reading
/// the port as big-endian is required to get 4569, but reading the family
/// the same way gives 512, not the POSIX `AF_INET` value of 2. The
/// consistent explanation is that this is a raw memory image of a BSD/Linux
/// `sockaddr_in`, where `sin_family` is a host-order (commonly
/// little-endian) field but `sin_port`/`sin_addr` are always network-order —
/// but the RFC never says this, so we do not bake that theory in as fact.
/// Both byte-order readings of the family field are exposed; callers that
/// need a definite answer must decide for themselves, and this type never
/// fails to parse or re-serialize over it.
public struct ApparentAddress: Sendable, Equatable {
    /// POSIX `AF_INET`.
    public static let addressFamilyINET: UInt16 = 2
    /// POSIX `AF_INET6` (Linux numbering; this is the value implied by the
    /// RFC's `0x0A00` IPv6 example under the little-endian reading).
    public static let addressFamilyINET6: UInt16 = 10

    /// The 2 family-field bytes, exactly as they appeared on the wire.
    /// Stored as a fixed pair rather than `[UInt8]` so that a family field
    /// of the wrong length is unrepresentable: a public initialiser should
    /// not be able to construct a value whose public accessors
    /// (`familyAsBigEndian`/`familyAsLittleEndian`) can trap.
    public let familyByte0: UInt8
    public let familyByte1: UInt8
    /// `sin_port` — unambiguously network byte order (big-endian): it is the
    /// only reading that makes the RFC's own `0x11d9` example equal 4569.
    public let port: UInt16
    /// `sin_addr` (4 bytes) or `sin6_addr` (16 bytes).
    public let addressBytes: [UInt8]
    /// `sin6_flowinfo`, 32-bit — only present for the 28-byte IPv6 layout.
    public let ipv6FlowInfo: UInt32?
    /// `sin6_scope_id`, 32-bit — only present for the 28-byte IPv6 layout.
    public let ipv6ScopeID: UInt32?
    /// The 8 trailing padding bytes of the 16-byte IPv4 layout, preserved
    /// verbatim (the RFC implies zero, but we do not enforce that on parse).
    public let ipv4TrailingPadding: [UInt8]?

    public init(
        familyByte0: UInt8,
        familyByte1: UInt8,
        port: UInt16,
        addressBytes: [UInt8],
        ipv6FlowInfo: UInt32? = nil,
        ipv6ScopeID: UInt32? = nil,
        ipv4TrailingPadding: [UInt8]? = nil
    ) {
        self.familyByte0 = familyByte0
        self.familyByte1 = familyByte1
        self.port = port
        self.addressBytes = addressBytes
        self.ipv6FlowInfo = ipv6FlowInfo
        self.ipv6ScopeID = ipv6ScopeID
        self.ipv4TrailingPadding = ipv4TrailingPadding
    }

    /// The 2 family-field bytes, exactly as they appeared on the wire, as
    /// an array — for callers that want to treat it like the other
    /// variable-length byte fields on this type (e.g. re-serializing).
    public var familyBytes: [UInt8] { [familyByte0, familyByte1] }

    /// `familyBytes` read as a big-endian `UInt16`.
    public var familyAsBigEndian: UInt16 {
        (UInt16(familyByte0) << 8) | UInt16(familyByte1)
    }

    /// `familyBytes` read as a little-endian `UInt16` — the reading
    /// consistent with the RFC's own worked example (see the type doc).
    public var familyAsLittleEndian: UInt16 {
        (UInt16(familyByte1) << 8) | UInt16(familyByte0)
    }

    public var isIPv6Layout: Bool { addressBytes.count == 16 }

    /// Builds a fresh IPv4 APPARENT ADDR to send (TXREQ, REGACK). Uses the
    /// little-endian family encoding from the RFC's own §8.6.17 example
    /// (`0x02, 0x00` for `AF_INET`) since that is the reading consistent
    /// with a verbatim `sockaddr_in` image — a choice for frames *we*
    /// originate, not a claim about what a peer will send us.
    public static func ipv4(address: (UInt8, UInt8, UInt8, UInt8), port: UInt16) -> ApparentAddress {
        ApparentAddress(
            familyByte0: 0x02,
            familyByte1: 0x00,
            port: port,
            addressBytes: [address.0, address.1, address.2, address.3],
            ipv4TrailingPadding: Array(repeating: 0, count: 8)
        )
    }
}

// MARK: - Errors

/// Failures from parsing or serializing an information element or a list of
/// them. Note that an **unknown IE id never produces one of these** — it is
/// always captured by `InformationElement.unknown` instead (see notes §7,
/// §8.6 and the IAX-2 task's hard requirement).
public enum InformationElementError: Swift.Error, Equatable, CustomStringConvertible {
    /// Fewer than 2 bytes remained where an IE id + length header was
    /// expected.
    case truncatedHeader(offset: Int)
    /// The declared data length runs past the end of the supplied buffer.
    case truncatedData(id: UInt8, offset: Int, declaredLength: Int, available: Int)
    /// A known IE's data was not the width its documented format requires.
    case wrongWidth(id: UInt8, name: String, expectedWidth: String, actualWidth: Int)
    /// A known IE documented as a UTF-8 string contained invalid UTF-8.
    case invalidUTF8(id: UInt8, name: String)
    /// Building would require a data length that cannot fit the 1-octet
    /// length field (max 255, per §8.6).
    case dataTooLong(id: UInt8, length: Int)

    public var description: String {
        switch self {
        case .truncatedHeader(let offset):
            return "IE list truncated at offset \(offset): need 2 bytes for id + length header"
        case .truncatedData(let id, let offset, let declaredLength, let available):
            return "IE 0x\(String(id, radix: 16)) at offset \(offset) declares \(declaredLength) data bytes but only \(available) remain"
        case .wrongWidth(let id, let name, let expectedWidth, let actualWidth):
            return "IE 0x\(String(id, radix: 16)) (\(name)) expected \(expectedWidth), got \(actualWidth)"
        case .invalidUTF8(let id, let name):
            return "IE 0x\(String(id, radix: 16)) (\(name)) is not valid UTF-8"
        case .dataTooLong(let id, let length):
            return "IE 0x\(String(id, radix: 16)) data is \(length) bytes, exceeding the 255-byte maximum"
        }
    }
}

// MARK: - InformationElement

/// One RFC 5456 §8.6 information element. IEs appear only in full-frame
/// payloads, never in mini or meta frames (§6, §8.1.2). This type is a pure
/// `[UInt8]` codec: it knows nothing about frame headers, call numbers, or
/// sequencing — that is `IAX2Frame`'s job.
///
/// Wire format (§8.6): 1-octet id, 1-octet data length, then `length` octets
/// of data. Maximum data length per IE is 255 octets.
///
/// Every id from the RFC 5456 Table 1 that has a defined data format gets a
/// typed case here. Reserved ids (`0x1d`, `0x1e`, `0x20`-`0x25`, `0x2c`), any
/// id the table lists without a resolvable format, and any id RFC 5456 does
/// not define at all, fall through to `.unknown` — parsed and re-serialized
/// byte-for-byte, never a parse failure.
public enum InformationElement: Sendable, Equatable {
    /// `0x01` CALLED NUMBER — UTF-8 string (§8.6.1).
    case calledNumber(String)
    /// `0x02` CALLING NUMBER — UTF-8 string (§8.6.2).
    case callingNumber(String)
    /// `0x03` CALLING ANI — UTF-8 string (§8.6.3).
    case callingANI(String)
    /// `0x04` CALLING NAME — UTF-8 string (§8.6.4).
    case callingName(String)
    /// `0x05` CALLED CONTEXT — UTF-8 string (§8.6.5).
    case calledContext(String)
    /// `0x06` USERNAME — UTF-8 string (§8.6.6).
    case username(String)

    /// `0x07` PASSWORD. **Dead id.** It appears in RFC 5456 Table 1 ("Password
    /// for authentication") but §8.6 has no defining subsection for it —
    /// the subsections run straight from §8.6.6 USERNAME to §8.6.7
    /// CAPABILITY. Combined with AUTHMETHODS `0x0001` being "Reserved (was
    /// Plaintext)" (§8.6.13) and §10's "Previous protocol versions supported
    /// cleartext passwords; this feature has been eliminated", the RFC's own
    /// position is that plaintext auth no longer exists.
    ///
    /// Modeled here **only** so that a nonconforming peer sending this id
    /// still round-trips instead of breaking the call — never send it.
    /// Deliberately no string-typed convenience accessor: reading or
    /// building a cleartext password from this case requires reaching past
    /// the type into `rawBytes` by hand, which is friction placed here on
    /// purpose. Use `IAX2Auth`'s MD5 challenge/response flow instead.
    case password(rawBytes: [UInt8])

    /// `0x08` CAPABILITY — 4-octet codec bitmask, OR-able (§8.6.7, §8.7).
    case capability(MediaFormat)
    /// `0x09` FORMAT — 4-octet codec bitmask; the RFC requires exactly one
    /// bit set ("Only one CODEC MUST be specified", §8.6.8), but this parses
    /// whatever 4 bytes are present without enforcing that constraint.
    case format(MediaFormat)
    /// `0x0a` LANGUAGE — UTF-8 string, RFC 5646 / RFC 4647 tag (§8.6.9).
    case language(String)
    /// `0x0b` VERSION — 2 octets; RFC 5456 defines the value `0x0002`
    /// (§8.6.10). Parsed as a plain integer without enforcing that value, so
    /// a future protocol version is not rejected outright.
    case version(UInt16)
    /// `0x0c` ADSICPE — 2 octets, no further meaning stated (§8.6.11).
    case adsicpe(UInt16)
    /// `0x0d` DNID — UTF-8 string (§8.6.12).
    case dnid(String)
    /// `0x0e` AUTHMETHODS — 2-octet bitmask (§8.6.13).
    case authMethods(IEAuthMethods)
    /// `0x0f` CHALLENGE — UTF-8 challenge string (§8.6.14).
    case challenge(String)
    /// `0x10` MD5 RESULT — UTF-8-encoded digest text (§8.6.15). See
    /// `IAX2Auth` (OQ-5) for the encoding assumption used when building one.
    case md5Result(String)
    /// `0x11` RSA RESULT — UTF-8-encoded signature text (§8.6.16).
    case rsaResult(String)
    /// `0x12` APPARENT ADDR — POSIX `sockaddr` image (§8.6.17).
    case apparentAddr(ApparentAddress)
    /// `0x13` REFRESH — 2 octets, seconds (§8.6.18).
    case refresh(UInt16)
    /// `0x14` DPSTATUS — 2-octet bitmask (§8.6.19).
    case dpStatus(IEDialplanStatus)
    /// `0x15` CALLNO — 2 octets, a call number as in a frame header (§8.6.20).
    case callNo(UInt16)
    /// `0x16` CAUSE — UTF-8 string (§8.6.21).
    case cause(String)
    /// `0x17` IAX UNKNOWN — 1 octet, the unrecognised subclass that triggered
    /// an UNSUPPORT (§8.6.22). Not to be confused with `.unknown`, which is
    /// this parser's catch-all for IE *ids* it does not model.
    case iaxUnknown(UInt8)
    /// `0x18` MSGCOUNT — high octet old messages, low octet new (§8.6.23).
    case msgCount(MessageCount)
    /// `0x19` AUTOANSWER — zero-length; presence alone is the signal (§8.6.24).
    case autoAnswer
    /// `0x1a` MUSICONHOLD — optional UTF-8 class name; may be zero-length
    /// (§8.6.25).
    case musicOnHold(String)
    /// `0x1b` TRANSFERID — 4 octets (§8.6.26).
    case transferID(UInt32)
    /// `0x1c` RDNIS — UTF-8 string (§8.6.27).
    case rdnis(String)
    /// `0x1f` DATETIME — packed 32-bit UTC timestamp (§8.6.28).
    case datetime(PackedDateTime)
    /// `0x26` CALLINGPRES — 1 octet, presentation value (§8.6.29).
    case callingPres(UInt8)
    /// `0x27` CALLINGTON — 1 octet, Q.931 type-of-number (§8.6.30).
    case callingTON(UInt8)
    /// `0x28` CALLINGTNS — 2 octets, RFC-ambiguous layout (§8.6.31).
    case callingTNS(CallingTNS)
    /// `0x29` SAMPLINGRATE — 2 octets, Hz (§8.6.32).
    case samplingRate(UInt16)
    /// `0x2a` CAUSECODE — 1 octet, Q.931-derived (§8.6.33).
    case causeCode(UInt8)
    /// `0x2b` ENCRYPTION — method bitmask. Raw bytes, not a fixed integer
    /// width: trap 15 in the notes records that §8.6.34's prose (2-octet
    /// bitmask) and its own diagram (1-octet data length) disagree, and the
    /// RFC does not resolve it. We do not implement encryption, so this is
    /// preserved rather than guessed at. Decode with `IEEncryptionMethods`
    /// if the width happens to be 2.
    case encryption(rawBytes: [UInt8])
    /// `0x2d` CODEC PREFS — UTF-8 list of codecs in preference order (§8.6.35).
    case codecPrefs(String)
    /// `0x2e` RR JITTER — 4 octets, measured jitter (§8.6.36).
    case rrJitter(UInt32)
    /// `0x2f` RR LOSS — 1 octet percent + 3-octet count (§8.6.37).
    case rrLoss(RRLoss)
    /// `0x30` RR PKTS — 4 octets, frames received (§8.6.38).
    case rrPkts(UInt32)
    /// `0x31` RR DELAY — 2 octets, max playout delay in ms (§8.6.39).
    case rrDelay(UInt16)
    /// `0x32` RR DROPPED — 4 octets, frames dropped (§8.6.40).
    case rrDropped(UInt32)
    /// `0x33` RR OOO — 4 octets, frames received out of order (§8.6.41).
    case rrOOO(UInt32)
    /// `0x34` OSPTOKEN — 1-octet block index followed by the token block
    /// (§8.6.42).
    case ospToken(blockIndex: UInt8, token: [UInt8])

    /// Any IE id without a typed case above: RFC 5456's reserved ids
    /// (`0x1d`, `0x1e`, `0x20`-`0x25`, `0x2c`), and any id outside the
    /// Table 1 range entirely. Preserved as the raw `(id, data)` pair so a
    /// peer sending an IE we don't recognise never breaks the call, and
    /// re-serializes byte-identical to what was parsed.
    case unknown(id: UInt8, data: [UInt8])

    /// The wire id byte for this element.
    public var id: UInt8 {
        switch self {
        case .calledNumber: return 0x01
        case .callingNumber: return 0x02
        case .callingANI: return 0x03
        case .callingName: return 0x04
        case .calledContext: return 0x05
        case .username: return 0x06
        case .password: return 0x07
        case .capability: return 0x08
        case .format: return 0x09
        case .language: return 0x0a
        case .version: return 0x0b
        case .adsicpe: return 0x0c
        case .dnid: return 0x0d
        case .authMethods: return 0x0e
        case .challenge: return 0x0f
        case .md5Result: return 0x10
        case .rsaResult: return 0x11
        case .apparentAddr: return 0x12
        case .refresh: return 0x13
        case .dpStatus: return 0x14
        case .callNo: return 0x15
        case .cause: return 0x16
        case .iaxUnknown: return 0x17
        case .msgCount: return 0x18
        case .autoAnswer: return 0x19
        case .musicOnHold: return 0x1a
        case .transferID: return 0x1b
        case .rdnis: return 0x1c
        case .datetime: return 0x1f
        case .callingPres: return 0x26
        case .callingTON: return 0x27
        case .callingTNS: return 0x28
        case .samplingRate: return 0x29
        case .causeCode: return 0x2a
        case .encryption: return 0x2b
        case .codecPrefs: return 0x2d
        case .rrJitter: return 0x2e
        case .rrLoss: return 0x2f
        case .rrPkts: return 0x30
        case .rrDelay: return 0x31
        case .rrDropped: return 0x32
        case .rrOOO: return 0x33
        case .ospToken: return 0x34
        case .unknown(let id, _): return id
        }
    }

    /// The raw data bytes this element carries (without the 2-byte id+length
    /// header). Always well-formed for the types above; ≤ 255 bytes unless
    /// the caller built an oversized `.unknown`, `.password`, or
    /// `.encryption` value by hand (`serialized()` rejects that at build
    /// time).
    public var data: [UInt8] {
        switch self {
        case .calledNumber(let s): return Array(s.utf8)
        case .callingNumber(let s): return Array(s.utf8)
        case .callingANI(let s): return Array(s.utf8)
        case .callingName(let s): return Array(s.utf8)
        case .calledContext(let s): return Array(s.utf8)
        case .username(let s): return Array(s.utf8)
        case .password(let raw): return raw
        case .capability(let f): return Self.uint32BE(f.rawValue)
        case .format(let f): return Self.uint32BE(f.rawValue)
        case .language(let s): return Array(s.utf8)
        case .version(let v): return Self.uint16BE(v)
        case .adsicpe(let v): return Self.uint16BE(v)
        case .dnid(let s): return Array(s.utf8)
        case .authMethods(let m): return Self.uint16BE(m.rawValue)
        case .challenge(let s): return Array(s.utf8)
        case .md5Result(let s): return Array(s.utf8)
        case .rsaResult(let s): return Array(s.utf8)
        case .apparentAddr(let a): return Self.encodeApparentAddress(a)
        case .refresh(let v): return Self.uint16BE(v)
        case .dpStatus(let m): return Self.uint16BE(m.rawValue)
        case .callNo(let v): return Self.uint16BE(v)
        case .cause(let s): return Array(s.utf8)
        case .iaxUnknown(let v): return [v]
        case .msgCount(let m): return [m.old, m.new]
        case .autoAnswer: return []
        case .musicOnHold(let s): return Array(s.utf8)
        case .transferID(let v): return Self.uint32BE(v)
        case .rdnis(let s): return Array(s.utf8)
        case .datetime(let d): return Self.uint32BE(d.rawValue)
        case .callingPres(let v): return [v]
        case .callingTON(let v): return [v]
        case .callingTNS(let t): return [t.planAndTypeByte, t.networkIDByte]
        case .samplingRate(let v): return Self.uint16BE(v)
        case .causeCode(let v): return [v]
        case .encryption(let raw): return raw
        case .codecPrefs(let s): return Array(s.utf8)
        case .rrJitter(let v): return Self.uint32BE(v)
        case .rrLoss(let l):
            let countBytes = Self.uint32BE(l.count)
            return [l.percent, countBytes[1], countBytes[2], countBytes[3]]
        case .rrPkts(let v): return Self.uint32BE(v)
        case .rrDelay(let v): return Self.uint16BE(v)
        case .rrDropped(let v): return Self.uint32BE(v)
        case .rrOOO(let v): return Self.uint32BE(v)
        case .ospToken(let blockIndex, let token): return [blockIndex] + token
        case .unknown(_, let data): return data
        }
    }

    /// Encodes this single IE as `id, length, data...`.
    ///
    /// - Throws: `InformationElementError.dataTooLong` if the data would not
    ///   fit the 1-octet length field (only reachable via a hand-built
    ///   `.unknown`, `.password`, `.encryption`, or over-long string case).
    public func serialized() throws -> [UInt8] {
        let bytes = data
        guard bytes.count <= 255 else {
            throw InformationElementError.dataTooLong(id: id, length: bytes.count)
        }
        return [id, UInt8(bytes.count)] + bytes
    }

    // MARK: List parse / serialize

    /// Parses a full frame payload's IE block (§8.6) into an ordered list of
    /// elements. Order is preserved because it is meaningful (VERSION MUST be
    /// first on NEW, §8.6.10).
    ///
    /// - Throws: `InformationElementError.truncatedHeader` or `.truncatedData`
    ///   for malformed TLV framing; `.wrongWidth` or `.invalidUTF8` for a
    ///   *known* IE id whose data does not match its documented format.
    ///   An id this parser does not model never throws — it becomes
    ///   `.unknown`.
    public static func parseList(_ bytes: [UInt8]) throws -> [InformationElement] {
        var result: [InformationElement] = []
        var offset = 0
        while offset < bytes.count {
            guard offset + 2 <= bytes.count else {
                throw InformationElementError.truncatedHeader(offset: offset)
            }
            let id = bytes[offset]
            let length = Int(bytes[offset + 1])
            let dataStart = offset + 2
            let dataEnd = dataStart + length
            guard dataEnd <= bytes.count else {
                throw InformationElementError.truncatedData(
                    id: id,
                    offset: offset,
                    declaredLength: length,
                    available: bytes.count - dataStart
                )
            }
            let elementData = Array(bytes[dataStart..<dataEnd])
            result.append(try decode(id: id, data: elementData))
            offset = dataEnd
        }
        return result
    }

    /// Serializes an ordered list of elements back into a full frame
    /// payload's IE block, in list order.
    public static func serialize(_ elements: [InformationElement]) throws -> [UInt8] {
        var out: [UInt8] = []
        for element in elements {
            out += try element.serialized()
        }
        return out
    }

    // MARK: Decoding a single (id, data) pair

    private static func decode(id: UInt8, data: [UInt8]) throws -> InformationElement {
        switch id {
        case 0x01: return .calledNumber(try decodeString(data, id: id, name: "CALLED_NUMBER"))
        case 0x02: return .callingNumber(try decodeString(data, id: id, name: "CALLING_NUMBER"))
        case 0x03: return .callingANI(try decodeString(data, id: id, name: "CALLING_ANI"))
        case 0x04: return .callingName(try decodeString(data, id: id, name: "CALLING_NAME"))
        case 0x05: return .calledContext(try decodeString(data, id: id, name: "CALLED_CONTEXT"))
        case 0x06: return .username(try decodeString(data, id: id, name: "USERNAME"))
        case 0x07: return .password(rawBytes: data)
        case 0x08: return .capability(MediaFormat(rawValue: try decodeUInt32(data, id: id, name: "CAPABILITY")))
        case 0x09: return .format(MediaFormat(rawValue: try decodeUInt32(data, id: id, name: "FORMAT")))
        case 0x0a: return .language(try decodeString(data, id: id, name: "LANGUAGE"))
        case 0x0b: return .version(try decodeUInt16(data, id: id, name: "VERSION"))
        case 0x0c: return .adsicpe(try decodeUInt16(data, id: id, name: "ADSICPE"))
        case 0x0d: return .dnid(try decodeString(data, id: id, name: "DNID"))
        case 0x0e: return .authMethods(IEAuthMethods(rawValue: try decodeUInt16(data, id: id, name: "AUTHMETHODS")))
        case 0x0f: return .challenge(try decodeString(data, id: id, name: "CHALLENGE"))
        case 0x10: return .md5Result(try decodeString(data, id: id, name: "MD5_RESULT"))
        case 0x11: return .rsaResult(try decodeString(data, id: id, name: "RSA_RESULT"))
        case 0x12: return .apparentAddr(try decodeApparentAddress(data, id: id))
        case 0x13: return .refresh(try decodeUInt16(data, id: id, name: "REFRESH"))
        case 0x14: return .dpStatus(IEDialplanStatus(rawValue: try decodeUInt16(data, id: id, name: "DPSTATUS")))
        case 0x15: return .callNo(try decodeUInt16(data, id: id, name: "CALLNO"))
        case 0x16: return .cause(try decodeString(data, id: id, name: "CAUSE"))
        case 0x17: return .iaxUnknown(try decodeUInt8(data, id: id, name: "IAX_UNKNOWN"))
        case 0x18:
            try requireWidth(data, exactly: 2, id: id, name: "MSGCOUNT")
            return .msgCount(MessageCount(old: data[0], new: data[1]))
        case 0x19:
            try requireWidth(data, exactly: 0, id: id, name: "AUTOANSWER")
            return .autoAnswer
        case 0x1a: return .musicOnHold(try decodeString(data, id: id, name: "MUSICONHOLD"))
        case 0x1b: return .transferID(try decodeUInt32(data, id: id, name: "TRANSFERID"))
        case 0x1c: return .rdnis(try decodeString(data, id: id, name: "RDNIS"))
        case 0x1f: return .datetime(PackedDateTime(rawValue: try decodeUInt32(data, id: id, name: "DATETIME")))
        case 0x26: return .callingPres(try decodeUInt8(data, id: id, name: "CALLINGPRES"))
        case 0x27: return .callingTON(try decodeUInt8(data, id: id, name: "CALLINGTON"))
        case 0x28:
            try requireWidth(data, exactly: 2, id: id, name: "CALLINGTNS")
            return .callingTNS(CallingTNS(planAndTypeByte: data[0], networkIDByte: data[1]))
        case 0x29: return .samplingRate(try decodeUInt16(data, id: id, name: "SAMPLINGRATE"))
        case 0x2a: return .causeCode(try decodeUInt8(data, id: id, name: "CAUSECODE"))
        case 0x2b: return .encryption(rawBytes: data)
        case 0x2d: return .codecPrefs(try decodeString(data, id: id, name: "CODEC_PREFS"))
        case 0x2e: return .rrJitter(try decodeUInt32(data, id: id, name: "RRJITTER"))
        case 0x2f:
            try requireWidth(data, exactly: 4, id: id, name: "RRLOSS")
            let count = (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
            return .rrLoss(RRLoss(percent: data[0], count: count))
        case 0x30: return .rrPkts(try decodeUInt32(data, id: id, name: "RRPKTS"))
        case 0x31: return .rrDelay(try decodeUInt16(data, id: id, name: "RRDELAY"))
        case 0x32: return .rrDropped(try decodeUInt32(data, id: id, name: "RRDROPPED"))
        case 0x33: return .rrOOO(try decodeUInt32(data, id: id, name: "RROOO"))
        case 0x34:
            guard let blockIndex = data.first else {
                throw InformationElementError.wrongWidth(id: id, name: "OSPTOKEN", expectedWidth: "at least 1 byte", actualWidth: 0)
            }
            return .ospToken(blockIndex: blockIndex, token: Array(data.dropFirst()))
        default:
            return .unknown(id: id, data: data)
        }
    }

    private static func decodeApparentAddress(_ data: [UInt8], id: UInt8) throws -> ApparentAddress {
        switch data.count {
        case 16: // IPv4 layout (§8.6.17)
            return ApparentAddress(
                familyByte0: data[0],
                familyByte1: data[1],
                port: (UInt16(data[2]) << 8) | UInt16(data[3]),
                addressBytes: Array(data[4..<8]),
                ipv4TrailingPadding: Array(data[8..<16])
            )
        case 28: // IPv6 layout (§8.6.17)
            let flowInfo = (UInt32(data[4]) << 24) | (UInt32(data[5]) << 16) | (UInt32(data[6]) << 8) | UInt32(data[7])
            let scopeID = (UInt32(data[24]) << 24) | (UInt32(data[25]) << 16) | (UInt32(data[26]) << 8) | UInt32(data[27])
            return ApparentAddress(
                familyByte0: data[0],
                familyByte1: data[1],
                port: (UInt16(data[2]) << 8) | UInt16(data[3]),
                addressBytes: Array(data[8..<24]),
                ipv6FlowInfo: flowInfo,
                ipv6ScopeID: scopeID
            )
        default:
            throw InformationElementError.wrongWidth(
                id: id,
                name: "APPARENT_ADDR",
                expectedWidth: "16 (IPv4) or 28 (IPv6) bytes",
                actualWidth: data.count
            )
        }
    }

    private static func encodeApparentAddress(_ addr: ApparentAddress) -> [UInt8] {
        var out: [UInt8] = addr.familyBytes
        out += uint16BE(addr.port)
        if addr.isIPv6Layout {
            out += uint32BE(addr.ipv6FlowInfo ?? 0)
            out += addr.addressBytes
            out += uint32BE(addr.ipv6ScopeID ?? 0)
        } else {
            out += addr.addressBytes
            out += addr.ipv4TrailingPadding ?? Array(repeating: 0, count: 8)
        }
        return out
    }

    // MARK: Byte-width primitives

    private static func requireWidth(_ data: [UInt8], exactly width: Int, id: UInt8, name: String) throws {
        guard data.count == width else {
            let unit = width == 1 ? "byte" : "bytes"
            throw InformationElementError.wrongWidth(id: id, name: name, expectedWidth: "\(width) \(unit)", actualWidth: data.count)
        }
    }

    private static func decodeUInt8(_ data: [UInt8], id: UInt8, name: String) throws -> UInt8 {
        try requireWidth(data, exactly: 1, id: id, name: name)
        return data[0]
    }

    private static func decodeUInt16(_ data: [UInt8], id: UInt8, name: String) throws -> UInt16 {
        try requireWidth(data, exactly: 2, id: id, name: name)
        return (UInt16(data[0]) << 8) | UInt16(data[1])
    }

    private static func decodeUInt32(_ data: [UInt8], id: UInt8, name: String) throws -> UInt32 {
        try requireWidth(data, exactly: 4, id: id, name: name)
        return (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
    }

    private static func decodeString(_ data: [UInt8], id: UInt8, name: String) throws -> String {
        guard let s = String(bytes: data, encoding: .utf8) else {
            throw InformationElementError.invalidUTF8(id: id, name: name)
        }
        return s
    }

    private static func uint16BE(_ v: UInt16) -> [UInt8] {
        [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    private static func uint32BE(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}

// MARK: - Convenience lookup

extension Array where Element == InformationElement {
    /// The first element with the given wire id, if any. A convenience for
    /// callers pulling a specific IE (e.g. FORMAT) out of a parsed list
    /// without hand-rolling a linear search.
    public func first(withID id: UInt8) -> InformationElement? {
        first { $0.id == id }
    }
}
