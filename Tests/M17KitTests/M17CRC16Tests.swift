// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import M17Kit

/// Tests for ``M17CRC16`` (M17-4).
///
/// The hard part of testing a CRC is that the obvious test — "assert it
/// returns the value it returns" — proves nothing. Three things here do
/// prove something, and none of them is the implementation checking itself:
///
/// 1. **A reference implementation written a different way.** ``M17CRC16``
///    runs the standard byte-wise register loop. ``bitwiseReference`` below
///    shifts the message in one *bit* at a time, which is the definition the
///    byte-wise loop is an optimisation of. They agree on every input tested,
///    including inputs chosen to exercise the carry path.
/// 2. **The check value.** `0x772B` for `"123456789"` is pinned, so a
///    mis-transcribed polynomial or a wrong initial value fails loudly rather
///    than producing self-consistent nonsense.
/// 3. **Live traffic.** The parameters were not guessed. Of the eight
///    combinations of reflected input, reflected output and final XOR against
///    the spec's polynomial and initial value, exactly one validates the
///    trailing two bytes of a captured stream datagram, and it does so in 52
///    of 52 frames of the OQ-7 capture; the other seven validate none. That
///    capture cannot be checked in (it is other operators' traffic — see
///    `docs/reference/PROVENANCE.md`), so what stands in for it here is the
///    check value plus ``M17ReflectorProtocolTests`` round-tripping a packet
///    through ``M17StreamPacket/isCRCValid``.
final class M17CRC16Tests: XCTestCase {

    // MARK: - An independent reference

    /// The same CRC, defined bit by bit rather than byte by byte.
    ///
    /// Deliberately *not* the same shape as ``M17CRC16/compute(_:)``: the
    /// message is expanded to a bit sequence and clocked through the register
    /// one bit at a time, MSB of each byte first. If the production loop
    /// mishandles a byte boundary or the carry, the two diverge.
    private func bitwiseReference(_ bytes: [UInt8]) -> UInt16 {
        var register = M17CRC16.initialValue
        for byte in bytes {
            for bit in (0..<8).reversed() {
                let incoming = (UInt16(byte) >> UInt16(bit)) & 1
                let outgoing = (register >> 15) & 1
                register = register << 1
                if incoming ^ outgoing == 1 {
                    register ^= M17CRC16.polynomial
                }
            }
        }
        return register
    }

    // MARK: - Parameters

    func testPolynomialAndInitialValueAreTheOnesTheSpecificationStates() {
        // M17 spec Part I: polynomial 0x5935, initial value 0xFFFF.
        XCTAssertEqual(M17CRC16.polynomial, 0x5935)
        XCTAssertEqual(M17CRC16.initialValue, 0xFFFF)
    }

    func testCheckValueOfTheConventionalVector() {
        XCTAssertEqual(M17CRC16.compute(Array("123456789".utf8)), 0x772B)
        XCTAssertEqual(M17CRC16.compute(Array("123456789".utf8)), M17CRC16.checkValue)
    }

    func testEmptyMessageIsTheInitialValueUntouched() {
        // No bytes clocked in means no shifts, so the register is still the
        // seed. There is no final XOR to disturb it.
        XCTAssertEqual(M17CRC16.compute([]), M17CRC16.initialValue)
    }

    // MARK: - Agreement with the reference

    func testAgreesWithTheBitwiseReferenceOnHandPickedInputs() {
        let cases: [[UInt8]] = [
            [],
            [0x00],
            [0xFF],
            [0x00, 0x00],
            [0xFF, 0xFF],
            Array("123456789".utf8),
            Array("M17 ".utf8),
            Array(repeating: 0xAA, count: 52),
            Array(repeating: 0x00, count: 52),
            Array(0..<52).map(UInt8.init),
        ]
        for input in cases {
            XCTAssertEqual(
                M17CRC16.compute(input), bitwiseReference(input),
                "byte-wise and bit-wise disagree on \(input.count) bytes")
        }
    }

    func testAgreesWithTheBitwiseReferenceOnAStreamOfPseudoRandomMessages() {
        // A fixed seed, so a failure is reproducible rather than a rumour.
        var state: UInt64 = 0x5935_FFFF_1234_5678
        func nextByte() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        for length in 0..<64 {
            let input = (0..<length).map { _ in nextByte() }
            XCTAssertEqual(
                M17CRC16.compute(input), bitwiseReference(input),
                "byte-wise and bit-wise disagree on a \(length)-byte message")
        }
    }

    // MARK: - Properties a CRC must have

    func testASingleBitFlipAnywhereChangesTheResult() {
        // The point of carrying a CRC at all. 52 bytes is the length a stream
        // datagram's CRC actually closes over.
        let base = (0..<52).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let expected = M17CRC16.compute(base)
        for byteIndex in base.indices {
            for bit in 0..<8 {
                var corrupted = base
                corrupted[byteIndex] ^= UInt8(1 << bit)
                XCTAssertNotEqual(
                    M17CRC16.compute(corrupted), expected,
                    "flipping bit \(bit) of byte \(byteIndex) went unnoticed")
            }
        }
    }

    func testLeadingZeroBytesAreNotTransparent() {
        // The reason the initial value is 0xFFFF rather than 0: with a zero
        // seed, prepending zero bytes would leave the CRC unchanged, so a
        // message and a zero-padded version of it would be indistinguishable.
        XCTAssertNotEqual(M17CRC16.compute([0x00, 0x01]), M17CRC16.compute([0x01]))
        XCTAssertNotEqual(M17CRC16.compute([0x00, 0x00, 0x01]), M17CRC16.compute([0x00, 0x01]))
    }

    func testAcceptsAnySequenceOfBytesNotJustAnArray() {
        // `compute` is generic over Sequence so callers do not have to
        // materialise an array; Data is the one that matters in practice.
        let bytes: [UInt8] = Array("123456789".utf8)
        XCTAssertEqual(M17CRC16.compute(Data(bytes)), M17CRC16.checkValue)
        XCTAssertEqual(M17CRC16.compute(bytes[...]), M17CRC16.checkValue)
    }
}
