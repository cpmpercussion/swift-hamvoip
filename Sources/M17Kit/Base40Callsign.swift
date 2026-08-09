// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Base-40 encoding of a callsign (or other short text) into the 48-bit
/// address field used by M17 stream and packet frames.
///
/// Reference: "M17 Protocol Specification, Part I - Air Interface",
/// Wojciech Kaczmarski SP5WWP et al., version 2.0.4
/// (https://spec.m17project.org/files/M17_spec.pdf), Appendix A "Address
/// Encoding":
///   - A.1 "The M17 alphabet" — the 40-character table (Table A.1).
///   - A.2 "Callsign Encoding" — the base-40 arithmetic and byte order.
///   - A.3 "Encoded Addresses" — the reserved/standard/extended/broadcast
///     address ranges (Table A.2).
///
/// This type intentionally validates more strictly than the spec's own
/// illustrative C `Encode()` routine (Appendix A.4), which silently maps
/// *any* unrecognised input character to the value 0 ("space"). FR-2.3
/// calls for a codec that rejects malformed callsigns outright, so
/// `encode` throws on any character outside Table A.1's 39 encodable
/// symbols (space included) instead of coercing it.
public enum Base40Callsign {

    /// Maximum number of characters that fit in a 48-bit base-40 address.
    /// Spec A.1: "Encoded, up to nine characters can be used ... that will
    /// still fit in a 48-bit address field."  (40^9 - 1 < 2^48 <= 40^10 - 1.)
    public static let maxLength = 9

    /// `0x000000000000` — reserved (Table A.2: "Reserved ... For future
    /// use"). This is also the value produced by encoding a callsign made
    /// of nothing but space characters (spec A.2), since space is value 0.
    public static let reservedAddress: UInt64 = 0x0000_0000_0000

    /// Highest address in the "Standard" range: `40^9 - 1`, i.e. the
    /// largest value nine base-40 characters can produce (Table A.2:
    /// `0xEE6B27FFFFFF`, "\"A\" to \".........\"").
    public static let standardRangeMax: UInt64 = 0x0000_EE6B_27FF_FFFF

    /// First address in the "Extended" range (Table A.2): addresses above
    /// `standardRangeMax` that no sequence of up to nine alphabet
    /// characters can produce. Reserved "for application use"; not
    /// decodable as a callsign.
    public static let extendedRangeMin: UInt64 = 0x0000_EE6B_2800_0000

    /// `0xFFFFFFFFFFFF` — BROADCAST (Table A.2). "Valid only for a
    /// destination" address; means the stream/packet is intended for any
    /// capable M17 receiver.
    public static let broadcastAddress: UInt64 = 0x0000_FFFF_FFFF_FFFF

    /// Mask for the 48-bit address field (top 16 bits of a `UInt64` are
    /// always zero).
    private static let addressFieldMask: UInt64 = 0x0000_FFFF_FFFF_FFFF

    /// Number of bytes in the wire address field.
    public static let byteCount = 6

    // MARK: - Alphabet (spec Table A.1, "Callsign Alphabet")
    //
    // Value  Character  Note
    //   0      ' '      "Also, any invalid character" (decode only here —
    //                   see the type-level doc comment on why `encode`
    //                   does not accept it as input).
    //  1-26   'A'-'Z'   Uppercase letter.
    // 27-36   '0'-'9'   Decimal digit.
    //  37      '-'      Hyphen.
    //  38      '/'      Forward slash.
    //  39      '.'      Period.
    //
    // (The PDF's ASCII-code column for '/' and '.' reads 0x3F/0x3E, which
    // are actually '?' and '>' — an evident typo/OCR artefact in the
    // document, since the correct codes are 0x2F and 0x2E respectively.
    // The character *order* — the only thing that affects the arithmetic —
    // is unambiguous and is corroborated by both the encoder and decoder
    // example code in appendices A.4/A.5, which agree with the table.)
    private static let alphabet: [Character] = {
        var chars: [Character] = [" "]
        chars.append(contentsOf: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        chars.append(contentsOf: "0123456789")
        chars.append(contentsOf: ["-", "/", "."])
        return chars
    }()

    /// Encodable characters only (values 1...39) — space is deliberately
    /// excluded here; see the type-level doc comment.
    private static let valueByCharacter: [Character: UInt64] = {
        var map: [Character: UInt64] = [:]
        for (index, character) in alphabet.enumerated() where index > 0 {
            map[character] = UInt64(index)
        }
        return map
    }()

    /// Encodes `callsign` into a 48-bit base-40 address (top 16 bits of the
    /// returned `UInt64` are always zero).
    ///
    /// Per spec A.2: "A callsign is encoded backwards, from the last
    /// character to the first character. This means that the first
    /// character of the callsign is in the least significant bits of the
    /// address, while the last character is enco[d]ed into the most
    /// significant bits of the address." Concretely (worked example from
    /// A.2, reproduced in the tests): for callsign "AB1CD" the value is
    /// `((((D * 40 + C) * 40 + '1') * 40 + B) * 40 + A)`.
    ///
    /// Case-insensitive: the callsign is uppercased before encoding.
    public static func encode(_ callsign: String) throws -> UInt64 {
        guard !callsign.isEmpty else {
            throw Base40CallsignError.empty
        }
        let characters = Array(callsign.uppercased())
        guard characters.count <= maxLength else {
            throw Base40CallsignError.tooLong(count: characters.count, max: maxLength)
        }

        var address: UInt64 = 0
        // Walk from the last character to the first (spec A.2), so the
        // first character ends up least significant.
        for character in characters.reversed() {
            guard let value = valueByCharacter[character] else {
                throw Base40CallsignError.invalidCharacter(character)
            }
            address = address * 40 + value
        }
        return address
    }

    /// Decodes a 48-bit base-40 address back into an uppercase callsign
    /// string.
    ///
    /// Only addresses in the "Standard" range (`0x1 ... standardRangeMax`,
    /// Table A.2) decode to a callsign; `0`, the "Extended" range, and
    /// `broadcastAddress` all throw `.reservedValue`, since none of them
    /// represents text encoded per A.2 — this mirrors the spec's own
    /// decoder example (A.5), which explicitly declines to decode anything
    /// `>= 0xEE6B28000000`.
    public static func decode(_ value: UInt64) throws -> String {
        guard value & ~addressFieldMask == 0 else {
            throw Base40CallsignError.addressOutOfRange(value)
        }
        guard value != reservedAddress, value <= standardRangeMax else {
            throw Base40CallsignError.reservedValue(value)
        }

        var address = value
        var characters: [Character] = []
        while address > 0 {
            let index = Int(address % 40)
            characters.append(alphabet[index])
            address /= 40
        }
        return String(characters)
    }

    /// Encodes `callsign` directly to the 6-byte wire representation.
    ///
    /// Wire byte order per spec A.2: "After the base-40 value is
    /// calculated, the final 6-byte address is the big endian encoded
    /// representation of the base-40 value. This is also called network
    /// byte order." I.e. `bytes[0]` holds bits 40...47 (most significant)
    /// and `bytes[5]` holds bits 0...7 (least significant).
    public static func encodedBytes(_ callsign: String) throws -> [UInt8] {
        let address = try encode(callsign)
        return bigEndianBytes(address)
    }

    /// Decodes a 6-byte big-endian (network byte order) wire address, per
    /// spec A.2, back into an uppercase callsign string.
    public static func decode(bytes: [UInt8]) throws -> String {
        guard bytes.count == byteCount else {
            throw Base40CallsignError.wrongByteCount(bytes.count)
        }
        var address: UInt64 = 0
        for byte in bytes {
            address = (address << 8) | UInt64(byte)
        }
        return try decode(address)
    }

    private static func bigEndianBytes(_ address: UInt64) -> [UInt8] {
        (0..<byteCount).map { offset in
            let shift = 8 * (byteCount - 1 - offset)
            return UInt8((address >> shift) & 0xFF)
        }
    }
}

/// Errors produced by ``Base40Callsign`` encoding/decoding.
public enum Base40CallsignError: Error, Equatable, CustomStringConvertible {
    /// The input string was empty.
    case empty
    /// `character` is not one of the 39 encodable symbols in the M17
    /// alphabet (spec Table A.1: `A-Z`, `0-9`, `-`, `/`, `.`).
    case invalidCharacter(Character)
    /// The callsign has more than `Base40Callsign.maxLength` characters.
    case tooLong(count: Int, max: Int)
    /// The 48-bit value is not in the "Standard" address range (Table
    /// A.2) — it is the reserved-zero address, in the "Extended" range,
    /// or the BROADCAST address — so it does not decode to callsign text.
    case reservedValue(UInt64)
    /// The `UInt64` supplied to `decode(_:)` has bits set above bit 47,
    /// i.e. it is not a valid 48-bit address at all.
    case addressOutOfRange(UInt64)
    /// `decode(bytes:)` was given a byte array whose count isn't exactly
    /// `Base40Callsign.byteCount` (6).
    case wrongByteCount(Int)

    public var description: String {
        switch self {
        case .empty:
            return "callsign is empty"
        case .invalidCharacter(let character):
            return "'\(character)' is not a valid M17 callsign character (A-Z, 0-9, -, /, .)"
        case .tooLong(let count, let max):
            return "callsign has \(count) characters, but the M17 address field holds at most \(max)"
        case .reservedValue(let value):
            return String(format: "0x%012llX is a reserved M17 address, not a decodable callsign", value)
        case .addressOutOfRange(let value):
            return String(format: "0x%llX exceeds the 48-bit M17 address field", value)
        case .wrongByteCount(let count):
            return "M17 address field must be exactly \(Base40Callsign.byteCount) bytes, got \(count)"
        }
    }
}
