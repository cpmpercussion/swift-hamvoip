// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import M17Kit

/// Tests for `Base40Callsign`, the M17 48-bit address codec (FR-2.3).
///
/// Spec reference throughout: "M17 Protocol Specification, Part I - Air
/// Interface", SP5WWP et al., v2.0.4, Appendix A "Address Encoding"
/// (A.1 alphabet table, A.2 encoding rules/worked example, A.3 address
/// ranges).
final class Base40CallsignTests: XCTestCase {

    // The 39 encodable M17 alphabet characters, in spec Table A.1 order
    // (value 1...39). Used here only to *generate* test input strings;
    // deliberately independent of Base40Callsign's private alphabet table
    // so the test doesn't just echo the implementation.
    private static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-/.")

    func testAlphabetHasThirtyNineCharacters() {
        XCTAssertEqual(Self.alphabet.count, 39)
    }

    // MARK: - Hand-computed arithmetic (catches a reversed digit order)

    /// Spec A.2 states a callsign is encoded backwards: the *first*
    /// character of the callsign lands in the *least* significant base-40
    /// digit. For a single character there is only one digit, so:
    ///   encode("A") == value('A') == 1
    ///   encode("Z") == value('Z') == 26
    ///   encode("0") == value('0') == 27   (digits start at value 27)
    func testHandComputedSingleCharacter() throws {
        XCTAssertEqual(try Base40Callsign.encode("A"), 1)
        XCTAssertEqual(try Base40Callsign.encode("Z"), 26)
        XCTAssertEqual(try Base40Callsign.encode("0"), 27)
        XCTAssertEqual(try Base40Callsign.encode("."), 39)
    }

    /// Two characters "B1": value('B') = 2, value('1') = 28.
    /// First character (B) is least significant, second ('1') is next:
    ///   address = value('1') * 40 + value('B') = 28 * 40 + 2 = 1122
    func testHandComputedTwoCharacters() throws {
        XCTAssertEqual(try Base40Callsign.encode("B1"), 28 * 40 + 2)
        XCTAssertEqual(try Base40Callsign.encode("B1"), 1122)
    }

    /// The worked example from spec A.2 itself, for "AB1CD":
    ///   value('A')=1, value('B')=2, value('1')=28, value('C')=3, value('D')=4
    ///   address = ((((4)*40 + 3)*40 + 28)*40 + 2)*40 + 1
    ///           = (((163)*40 + 28)*40 + 2)*40 + 1
    ///           = ((6548)*40 + 2)*40 + 1
    ///           = (261922)*40 + 1
    ///           = 10476881  (0x9FDD51)
    /// The spec gives this exact result (A.2), which is a strong
    /// cross-check that our digit order matches the specification.
    func testSpecWorkedExampleAB1CD() throws {
        let address = try Base40Callsign.encode("AB1CD")
        XCTAssertEqual(address, 10_476_881)
        XCTAssertEqual(address, 0x9F_DD51)
        XCTAssertEqual(try Base40Callsign.decode(address), "AB1CD")
    }

    // MARK: - Realistic round trips

    func testRoundTripAustralianCallsign() throws {
        try assertRoundTrips("VK1XYZ")
    }

    func testRoundTripSlashSuffix() throws {
        try assertRoundTrips("VK1AB/M")
    }

    func testRoundTripSingleCharacter() throws {
        try assertRoundTrips("W")
    }

    func testRoundTripMaxLengthNineCharacters() throws {
        // 9 characters, exactly Base40Callsign.maxLength, using letters,
        // digits, and a hyphen.
        let callsign = "VK1XYZ-12"
        XCTAssertEqual(callsign.count, 9)
        try assertRoundTrips(callsign)
    }

    func testCaseInsensitiveEncoding() throws {
        XCTAssertEqual(try Base40Callsign.encode("vk1xyz"), try Base40Callsign.encode("VK1XYZ"))
        XCTAssertEqual(try Base40Callsign.decode(try Base40Callsign.encode("vk1xyz")), "VK1XYZ")
    }

    /// Reference (independent-of-implementation) base-40 arithmetic that,
    /// unlike `Base40Callsign.encode`, *does* accept the space character
    /// at value 0 -- exactly the alphabet spec A.2 and
    /// `docs/reference/PROVENANCE.md` describe: index 0 is space, encoding
    /// runs from the least significant digit (the first character of
    /// `text`) outward. Used only to exercise the "trailing spaces don't
    /// affect the value" claim, which the public `encode` API cannot
    /// exercise directly (see below).
    private func referenceBase40ValueIncludingSpace(_ text: String) -> UInt64 {
        var address: UInt64 = 0
        for character in text.reversed() {
            let index = character == " " ? 0 : Self.alphabet.firstIndex(of: character)! + 1
            address = address * 40 + UInt64(index)
        }
        return address
    }

    /// Spec A.2: "Since the space character has a value of zero, trailing
    /// spaces will not affect the encoded value."
    ///
    /// The original version of this test only round-tripped `"ABC"` --
    /// a string containing no space at all -- so it exercised nothing
    /// about trailing spaces and would have passed against any
    /// implementation whatsoever, correct or not.
    ///
    /// On inspection, the property as literally stated is **not
    /// observable through this type's public `encode` API**: `encode`
    /// deliberately throws `.invalidCharacter` for space at *any*
    /// position (see the type's doc comment, FR-2.3) -- so you cannot ask
    /// it to encode `"ABC "` and compare, because the trailing space
    /// itself throws before "does it affect the value" is even
    /// answerable. What genuinely holds, and is what makes `decode` safe
    /// to write the way it is, is the underlying base-40 *arithmetic*:
    /// since encoding runs from the least significant digit (spec A.2),
    /// trailing spaces land in the most-significant digit positions,
    /// where a zero-valued digit contributes nothing regardless of how
    /// many of them there are. This test exercises that arithmetic
    /// directly (via `referenceBase40ValueIncludingSpace`, which -- unlike
    /// `encode` -- does accept space) and then confirms the flip side:
    /// `decode` never reconstructs trailing spaces, for any of the
    /// (identical) addresses padding would have produced.
    func testTrailingSpacesDoNotAffectTheEncodedValue() throws {
        let unpadded = referenceBase40ValueIncludingSpace("ABC")
        XCTAssertEqual(
            unpadded, try Base40Callsign.encode("ABC"),
            "sanity check: the reference arithmetic must agree with the real encoder on space-free input"
        )

        for paddingLength in 1...(Base40Callsign.maxLength - 3) {
            let padded = "ABC" + String(repeating: " ", count: paddingLength)
            XCTAssertEqual(
                referenceBase40ValueIncludingSpace(padded), unpadded,
                "\(paddingLength) trailing space(s) must not change the encoded value"
            )
        }

        // The flip side of the same property: decode never reconstructs
        // trailing spaces, because nothing in the address distinguishes
        // "ABC" from "ABC   ".
        XCTAssertEqual(try Base40Callsign.decode(unpadded), "ABC")
    }

    private func assertRoundTrips(_ callsign: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try Base40Callsign.encode(callsign)
        XCTAssertEqual(try Base40Callsign.decode(value), callsign.uppercased(), file: file, line: line)
        XCTAssertEqual(value & 0xFFFF_0000_0000_0000, 0, "top 16 bits must be zero", file: file, line: line)

        let bytes = try Base40Callsign.encodedBytes(callsign)
        XCTAssertEqual(bytes.count, 6, file: file, line: line)
        XCTAssertEqual(try Base40Callsign.decode(bytes: bytes), callsign.uppercased(), file: file, line: line)
    }

    // MARK: - Exhaustive-ish round trip

    /// Exhaustively round-trips every 1- and 2-character callsign (39 +
    /// 39*39 = 1,560 cases), then a further 5,000 pseudo-randomly
    /// generated callsigns of length 3...9 drawn from a fixed-seed linear
    /// congruential generator (PCG-style constants; no system randomness,
    /// fully deterministic across runs). ~6,560 cases total.
    func testExhaustiveRoundTrip() throws {
        var count = 0

        // Exhaustive: every single character.
        for c in Self.alphabet {
            try assertRoundTrips(String(c))
            count += 1
        }

        // Exhaustive: every two-character combination.
        for c1 in Self.alphabet {
            for c2 in Self.alphabet {
                try assertRoundTrips("\(c1)\(c2)")
                count += 1
            }
        }

        // Deterministic pseudo-random: lengths 3...9.
        var rng = DeterministicRNG(seed: 0x5EED_1234_ABCD_EF01)
        for _ in 0..<5000 {
            let length = Int(rng.next() % 7) + 3 // 3...9
            var chars: [Character] = []
            chars.reserveCapacity(length)
            for _ in 0..<length {
                let index = Int(rng.next() % UInt64(Self.alphabet.count))
                chars.append(Self.alphabet[index])
            }
            try assertRoundTrips(String(chars))
            count += 1
        }

        XCTAssertEqual(count, 39 + 39 * 39 + 5000)
        XCTAssertGreaterThan(count, 6000)
    }

    // MARK: - Invalid input

    func testInvalidCharactersThrow() {
        for bad in ["*", "#", " ", "@", "_", "!"] {
            XCTAssertThrowsError(try Base40Callsign.encode(bad)) { error in
                guard case Base40CallsignError.invalidCharacter = error else {
                    return XCTFail("expected invalidCharacter for \"\(bad)\", got \(error)")
                }
            }
        }
    }

    func testEmptyCallsignThrows() {
        XCTAssertThrowsError(try Base40Callsign.encode("")) { error in
            XCTAssertEqual(error as? Base40CallsignError, .empty)
        }
    }

    func testInvalidCharacterEmbeddedInOtherwiseValidCallsignThrows() {
        XCTAssertThrowsError(try Base40Callsign.encode("VK1*XY")) { error in
            guard case Base40CallsignError.invalidCharacter(let ch) = error else {
                return XCTFail("expected invalidCharacter, got \(error)")
            }
            XCTAssertEqual(ch, "*")
        }
    }

    func testTooLongCallsignThrows() {
        let tooLong = "VK1ABCDEF" // 9 valid chars is fine; add a 10th.
        XCTAssertEqual(tooLong.count, 9)
        let overLength = tooLong + "G" // 10 characters
        XCTAssertThrowsError(try Base40Callsign.encode(overLength)) { error in
            XCTAssertEqual(error as? Base40CallsignError, .tooLong(count: 10, max: 9))
        }
    }

    // MARK: - Unicode case mapping must not smuggle characters past validation
    //
    // `String.uppercased()` performs full Unicode case mapping, which for
    // some characters *expands* one character into several: "ß" -> "SS",
    // "ﬁ" -> "FI". If `encode` uppercases before validating, a single
    // character outside the M17 alphabet turns into two-or-more characters
    // that pass validation, and the callsign that goes on the air is not
    // the one the operator typed. Each of these must instead throw
    // `.invalidCharacter` naming the *original* character.

    func testEszettDoesNotExpandIntoTwoSCharacters() {
        // "ß".uppercased() == "SS", which is 779 under this alphabet
        // (verified independently: value('S')=19, so "SS" encodes to
        // 19*40+19 = 779). Before the fix, encode("ß") silently returned
        // 779 -- identical to encode("SS") -- instead of throwing.
        let eszett = "\u{00DF}" // "ß"
        XCTAssertThrowsError(try Base40Callsign.encode(eszett)) { error in
            guard case Base40CallsignError.invalidCharacter(let ch) = error else {
                return XCTFail("expected invalidCharacter, got \(error)")
            }
            XCTAssertEqual(ch, Character(eszett), "the error must name the character as typed, not an uppercased/expanded form")
        }
    }

    func testFiLigatureDoesNotExpandIntoFAndI() {
        // "ﬁ".uppercased() == "FI" (366 = value('F')=6, value('I')=9 ->
        // 9*40+6 = 366). Before the fix this collided with encode("FI").
        let fiLigature = "\u{FB01}" // "ﬁ"
        XCTAssertThrowsError(try Base40Callsign.encode(fiLigature)) { error in
            guard case Base40CallsignError.invalidCharacter(let ch) = error else {
                return XCTFail("expected invalidCharacter, got \(error)")
            }
            XCTAssertEqual(ch, Character(fiLigature))
        }
    }

    func testFfiLigatureExpandsToThreeCharactersAndMustStillThrow() {
        // "ﬃ".uppercased() == "FFI" -- a single character expanding to
        // *three*, the most aggressive case. Also two extra characters
        // longer than the input, which the length check must not be
        // fooled by either (see testTooLongCountIsPreExpansion below).
        let ffiLigature = "\u{FB03}" // "ﬃ"
        XCTAssertThrowsError(try Base40Callsign.encode(ffiLigature)) { error in
            guard case Base40CallsignError.invalidCharacter(let ch) = error else {
                return XCTFail("expected invalidCharacter, got \(error)")
            }
            XCTAssertEqual(ch, Character(ffiLigature))
        }
    }

    func testApostropheNCharacterExpandsAndMustStillThrow() {
        // U+0149 LATIN SMALL LETTER N PRECEDED BY APOSTROPHE uppercases to
        // U+02BC (modifier letter apostrophe) + "N" -- an expansion where
        // neither resulting character is even a plain ASCII letter.
        let apostropheN = "\u{0149}" // "ŉ"
        XCTAssertThrowsError(try Base40Callsign.encode(apostropheN)) { error in
            guard case Base40CallsignError.invalidCharacter(let ch) = error else {
                return XCTFail("expected invalidCharacter, got \(error)")
            }
            XCTAssertEqual(ch, Character(apostropheN))
        }
    }

    func testNonExpandingNonASCIICharacterStillThrows() {
        // A plain sanity check that ordinary (non-expanding) non-ASCII
        // input is still rejected -- this already worked before the fix,
        // and must keep working after it.
        XCTAssertThrowsError(try Base40Callsign.encode("\u{03C9}")) { error in // "ω" (Greek small omega)
            guard case Base40CallsignError.invalidCharacter = error else {
                return XCTFail("expected invalidCharacter, got \(error)")
            }
        }
    }

    func testAsciiLowercaseLettersStillEncodeToTheirUppercaseValue() throws {
        // The fix must not regress the intended, tested a-z case folding:
        // only ASCII a-z gets the case-mapping treatment, and only ever
        // one-character-for-one-character.
        for lower in "abcdefghijklmnopqrstuvwxyz" {
            let upper = Character(String(lower).uppercased())
            XCTAssertEqual(
                try Base40Callsign.encode(String(lower)),
                try Base40Callsign.encode(String(upper)),
                "'\(lower)' should encode the same as '\(upper)'"
            )
        }
    }

    func testTooLongCountIsPreExpansion() {
        // A 10-character callsign containing an expanding character (each
        // of which would balloon under naive uppercasing) must still be
        // reported as having exactly 10 characters -- the count the
        // operator typed -- not some larger post-expansion count.
        let tenCharsWithLigature = "VK1ABCDEF\u{FB01}" // 9 valid + "ﬁ" = 10 chars
        XCTAssertEqual(tenCharsWithLigature.count, 10)
        XCTAssertThrowsError(try Base40Callsign.encode(tenCharsWithLigature)) { error in
            XCTAssertEqual(error as? Base40CallsignError, .tooLong(count: 10, max: 9))
        }
    }

    // MARK: - Reserved / special values

    func testReservedZeroAddressDoesNotDecode() {
        XCTAssertThrowsError(try Base40Callsign.decode(Base40Callsign.reservedAddress)) { error in
            XCTAssertEqual(error as? Base40CallsignError, .reservedValue(0))
        }
    }

    func testBroadcastAddressDoesNotDecodeAsCallsign() {
        // Table A.2: 0xFFFFFFFFFFFF is BROADCAST, "valid only for a
        // destination"; it is not text encoded per A.2, so we treat it as
        // non-decodable rather than fabricating a callsign string for it.
        XCTAssertEqual(Base40Callsign.broadcastAddress, 0xFFFF_FFFF_FFFF)
        XCTAssertThrowsError(try Base40Callsign.decode(Base40Callsign.broadcastAddress)) { error in
            XCTAssertEqual(error as? Base40CallsignError, .reservedValue(Base40Callsign.broadcastAddress))
        }
    }

    func testExtendedRangeDoesNotDecodeAsCallsign() {
        XCTAssertThrowsError(try Base40Callsign.decode(Base40Callsign.extendedRangeMin)) { error in
            XCTAssertEqual(error as? Base40CallsignError, .reservedValue(Base40Callsign.extendedRangeMin))
        }
        // One below the extended range is still standard and must decode.
        XCTAssertNoThrow(try Base40Callsign.decode(Base40Callsign.standardRangeMax))
    }

    func testAddressAboveFortyEightBitsThrows() {
        let outOfRange: UInt64 = 0x0001_0000_0000_0000 // bit 48 set
        XCTAssertThrowsError(try Base40Callsign.decode(outOfRange)) { error in
            XCTAssertEqual(error as? Base40CallsignError, .addressOutOfRange(outOfRange))
        }
    }

    // MARK: - Wire bytes

    func testEncodedBytesAreBigEndianNetworkByteOrder() throws {
        // AB1CD -> 0x9FDD51 (3 significant bytes), zero-extended to the
        // full 6-byte field in big-endian (network) byte order:
        // [0x00, 0x00, 0x00, 0x9F, 0xDD, 0x51].
        let value = try Base40Callsign.encode("AB1CD")
        let bytes = try Base40Callsign.encodedBytes("AB1CD")
        XCTAssertEqual(bytes.count, 6)
        var reconstructed: UInt64 = 0
        for byte in bytes {
            reconstructed = (reconstructed << 8) | UInt64(byte)
        }
        XCTAssertEqual(reconstructed, value)
        // Most significant byte first (network byte order).
        XCTAssertEqual(bytes[0], 0)
        XCTAssertEqual(bytes[1], 0)
        XCTAssertEqual(bytes[2], 0)
        XCTAssertEqual(bytes[3], 0x9F)
        XCTAssertEqual(bytes[4], 0xDD)
        XCTAssertEqual(bytes[5], 0x51)
    }

    func testDecodeBytesRoundTrip() throws {
        for callsign in ["VK1XYZ", "W", "VK1AB/M", "VK1XYZ-12"] {
            let bytes = try Base40Callsign.encodedBytes(callsign)
            XCTAssertEqual(try Base40Callsign.decode(bytes: bytes), callsign)
        }
    }

    func testWrongByteCountThrows() {
        for count in [0, 1, 5, 7, 12] {
            let bytes = [UInt8](repeating: 0, count: count)
            XCTAssertThrowsError(try Base40Callsign.decode(bytes: bytes)) { error in
                XCTAssertEqual(error as? Base40CallsignError, .wrongByteCount(count))
            }
        }
    }
}

/// A minimal, fully deterministic PRNG (PCG-XSH-RR-style constants) used
/// only to generate a large, reproducible set of test callsigns. Not
/// cryptographic; not `Math.random`-style — same seed always yields the
/// same sequence.
private struct DeterministicRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        // Mix the bits a bit further (xorshift) so low bits aren't weak.
        var x = state
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        return x
    }
}
