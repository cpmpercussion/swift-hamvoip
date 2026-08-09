// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Errors

/// Why a character could not be sent as DTMF.
public enum IAX2DTMFError: Error, Equatable, CustomStringConvertible {
    /// The character is not one of the sixteen RFC 5456 §8.2 names it.
    case invalidDigit(Character)

    public var description: String {
        switch self {
        case .invalidDigit(let character):
            return
                "'\(character)' is not a DTMF digit; RFC 5456 §8.2 gives the domain as "
                + "0-9, A-D, * and # (case-sensitive — the RFC names the upper-case letters)"
        }
    }
}

// MARK: - IAX2DTMFDigit

/// One validated DTMF digit, and the RFC 5456 §8.2.1 rule for putting it on the
/// wire.
///
/// ## The frame
///
/// A DTMF digit travels as a **Full Frame of frame type `0x01`**, one digit per
/// frame, with the digit itself in the subclass field and **no payload at all**:
///
/// > "The message carries a single digit of DTMF (Dual Tone Multi-Frequency).
/// > Useful background information about DTMF can be found in [RFC4733] and
/// > [RFC4734], but, note that IAX does not use the RTP protocol." (§6.10.1)
///
/// > "For DTMF frames, the subclass is the actual DTMF digit carried by the
/// > frame." (§8.2.1)
///
/// The §8.2 frame-type table gives the subclass domain as `0-9, A-D, *, #` and
/// the Data field as "Undefined" — hence `payload` is empty on transmit, and a
/// payload on receive is ignored rather than parsed.
///
/// Being a Full Frame carrying media, it is reliable: it increments OSeqno (§7)
/// and the peer MUST ACK it ("Upon receiving any media message, except the
/// abbreviated audio and video Mini Frames, an ACK message MUST be sent",
/// §6.10). `ReliableChannel` already does both, so `IAX2VoiceStream.send(dtmf:)`
/// is a single `IAX2Call.send(type:subclass:timestamp:payload:)`.
///
/// ## Begin/end semantics: there are none
///
/// RFC 5456 specifies **no** DTMF BEGIN or END frame, no duration field, no
/// volume field, and no "digit start"/"digit stop" control subclass. One frame
/// carries one complete digit, and that is the whole of it (notes §14). This is
/// deliberately unlike RFC 4733, which §6.10.1 cites only as background while
/// pointing out that "IAX does not use the RTP protocol". Nothing here sends a
/// second frame to end a digit, and nothing waits for one on receive.
///
/// ## The subclass encoding
///
/// *RFC ambiguous:* §8.2.1 says only "the actual DTMF digit" — it never states
/// that the digit is ASCII-encoded. All sixteen symbols have ASCII codes ≤ 0x7F
/// (`#` = 0x23, `*` = 0x2A, `0`–`9` = 0x30–0x39, `A`–`D` = 0x41–0x44), so they
/// fit the 7-bit subclass field with the C bit clear, which is the reading this
/// implementation takes (notes §14).
///
/// One happy accident is worth recording: **not one of the sixteen is an exact
/// power of two**, so the §8.1.1 C-bit overlap that makes µ-law representable
/// as either `0x04` or `0x82` cannot arise for a DTMF digit. A subclass octet
/// with C = 1 can therefore never name a valid digit, and
/// ``init(subclass:)`` rejects every such frame after applying the C-bit rule
/// — decoding both forms as the notes require (§6), and finding no digit in the
/// power-encoded one.
public struct IAX2DTMFDigit: Hashable, Sendable, CustomStringConvertible {
    /// The digit as written: `0`–`9`, `A`–`D`, `*` or `#`.
    public let character: Character

    /// The frame type every DTMF digit travels in: `0x01` (§8.2, §8.2.1).
    public static let frameType: IAX2FrameType = .dtmf

    /// The sixteen symbols of the §8.2 subclass domain, in table order.
    public static let validCharacters: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "A", "B", "C", "D",
        "*", "#",
    ]

    /// Validates a character against the §8.2 domain.
    ///
    /// Case-sensitive: the RFC names `A-D`, so `a` is not a DTMF digit here.
    /// Upper-casing a caller's input would be a convenience this layer has no
    /// mandate to invent — the layer that owns a keypad can do it.
    ///
    /// - Throws: ``IAX2DTMFError/invalidDigit(_:)`` for anything else.
    public init(_ character: Character) throws {
        guard Self.validCharacters.contains(character) else {
            throw IAX2DTMFError.invalidDigit(character)
        }
        self.character = character
    }

    /// Every valid digit, for exhaustive tests and keypad models.
    public static let all: [IAX2DTMFDigit] = validCharacters.map {
        // Force-try is safe: the input is `validCharacters` itself.
        try! IAX2DTMFDigit($0)  // swiftlint:disable:this force_try
    }

    /// The digit's ASCII code — the value that goes in the subclass field.
    public var asciiValue: UInt8 {
        // Every member of `validCharacters` is a single ASCII scalar, so this
        // is total.
        UInt8(character.unicodeScalars.first!.value)
    }

    /// The subclass octet: C = 0, the ASCII code in the low 7 bits (§8.1.1,
    /// §8.2.1). All sixteen codes are ≤ 0x44, so the field never overflows.
    public var subclass: IAX2Subclass {
        IAX2Subclass.literal(asciiValue)
    }

    public var description: String { String(character) }

    // MARK: Receiving

    /// Reads a digit out of a subclass octet, tolerating either C-bit form.
    ///
    /// `IAX2Subclass.value` applies the §8.1.1 rule — `field` when C = 0,
    /// `1 << field` when C = 1 — and the result is then checked against the
    /// §8.2 domain. Since no valid digit's ASCII code is a power of two, a
    /// C = 1 octet always fails that check, which is the correct outcome: it
    /// names no digit RFC 5456 defines.
    ///
    /// - Returns: `nil` if the subclass names no valid digit.
    public init?(subclass: IAX2Subclass) {
        guard let value = subclass.value, value <= 0x7F else { return nil }
        guard let scalar = Unicode.Scalar(UInt8(value)) as Unicode.Scalar? else { return nil }
        let character = Character(scalar)
        guard Self.validCharacters.contains(character) else { return nil }
        self.character = character
    }

    /// Reads a digit out of a received Full Frame.
    ///
    /// Inbound DTMF reaches this client as ``IAX2CallEvent/other(_:)`` — the
    /// FSM has no use for it and hands the frame over untouched, already ACKed
    /// by the reliable channel. Any payload is ignored: §8.2 gives the DTMF
    /// Data field as "Undefined".
    ///
    /// - Returns: `nil` when the frame is not type `0x01`, or when its subclass
    ///   names no valid digit.
    public init?(frame: IAX2FullFrame) {
        guard frame.type == .dtmf else { return nil }
        self.init(subclass: frame.subclass)
    }
}
