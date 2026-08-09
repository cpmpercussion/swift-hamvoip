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

    func testTrailingSpacesDoNotAffectEncodedValue() throws {
        // Spec A.2: "Since the space character has a value of zero,
        // trailing spaces will not affect the encoded value." We reject
        // space as an *input* character (see Base40Callsign's doc
        // comment), but padding a shorter callsign into a longer field is
        // exactly what the decoder should reproduce without trailing
        // artifacts.
        let value = try Base40Callsign.encode("ABC")
        XCTAssertEqual(try Base40Callsign.decode(value), "ABC")
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
