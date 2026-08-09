// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import RadioCore

/// Independently re-derives the expected quantisation-error bound for a
/// given PCM magnitude from the public ITU-T G.711 constants (bias 0x84,
/// 8 segments), so these tests check the codec's *behaviour* against the
/// spec rather than against its own internals.
private enum ExpectedG711 {
    static let bias = 132
    static let clip = 32635

    /// Segment (0...7) that `magnitude` (already clipped) falls into.
    static func exponent(forMagnitude magnitude: Int) -> Int {
        let biased = min(magnitude, clip) + bias
        var exponent = 7
        var probe = 0x4000
        while exponent > 0 && (biased & probe) == 0 {
            probe >>= 1
            exponent -= 1
        }
        return exponent
    }

    /// Maximum |decoded - original| for a sample of this magnitude: half
    /// the segment's quantisation step, plus whatever was lost to clipping
    /// above `clip`, plus a 1-unit rounding safety margin.
    static func maxError(forMagnitude magnitude: Int) -> Int {
        let clippingError = max(0, magnitude - clip)
        let halfStep = 1 << (exponent(forMagnitude: magnitude) + 2)
        return clippingError + halfStep + 1
    }
}

final class G711MuLawCodecTests: XCTestCase {
    let codec = G711MuLawCodec()

    // MARK: - Framing

    func testFrameSizes() {
        XCTAssertEqual(codec.samplesPerFrame, 160)
        XCTAssertEqual(codec.bytesPerFrame, 160)
    }

    func testFullFrameRoundTrips() throws {
        let pcm: [Int16] = (0..<160).map { i in
            Int16(Double(Int16.max) * 0.5 * sin(2 * .pi * Double(i) / 20))
        }
        let encoded = try codec.encode(pcm)
        XCTAssertEqual(encoded.count, 160)
        let decoded = try codec.decode(encoded)
        XCTAssertEqual(decoded.count, 160)
        for (original, roundTripped) in zip(pcm, decoded) {
            let bound = ExpectedG711.maxError(forMagnitude: abs(Int(original)))
            XCTAssertLessThanOrEqual(
                abs(Int(roundTripped) - Int(original)), bound,
                "sample \(original) round-tripped to \(roundTripped), exceeding bound \(bound)"
            )
        }
    }

    // MARK: - Wrong length

    func testEncodeWrongLengthThrows() {
        XCTAssertThrowsError(try codec.encode(Array(repeating: 0, count: 159))) { error in
            XCTAssertEqual(error as? G711Error, .wrongFrameLength(expected: 160, got: 159))
        }
        XCTAssertThrowsError(try codec.encode([])) { error in
            XCTAssertEqual(error as? G711Error, .wrongFrameLength(expected: 160, got: 0))
        }
    }

    func testDecodeWrongLengthThrows() {
        XCTAssertThrowsError(try codec.decode(Array(repeating: 0, count: 161))) { error in
            XCTAssertEqual(error as? G711Error, .wrongFrameLength(expected: 160, got: 161))
        }
    }

    // MARK: - Silence

    func testSilenceEncodesTo0xFF() {
        XCTAssertEqual(G711MuLawCodec.encodeSample(0), 0xFF)
    }

    // MARK: - Round trip within quantisation error, across all 8 segments

    func testRoundTripWithinQuantisationErrorAcrossSegments() {
        // Magnitudes chosen to land in each of the 8 segments (verified
        // below by asserting the expected exponent actually varies 0...7
        // across this table), plus the required edge cases: 0, ±1, ±32767.
        let magnitudes = [0, 1, 30, 200, 500, 1_000, 2_000, 4_000,
                           10_000, 20_000, 32_635, 32_767]

        var observedExponents = Set<Int>()
        for magnitude in magnitudes {
            for sign: Int16 in [1, -1] {
                let x = Int16(sign == -1 ? -magnitude : magnitude)

                let byte = G711MuLawCodec.encodeSample(x)
                let decoded = G711MuLawCodec.decodeSample(byte)
                let bound = ExpectedG711.maxError(forMagnitude: magnitude)
                observedExponents.insert(ExpectedG711.exponent(forMagnitude: magnitude))

                XCTAssertLessThanOrEqual(
                    abs(Int(decoded) - Int(x)), bound,
                    "x=\(x) decoded=\(decoded) exceeds per-segment bound \(bound)"
                )
            }
        }

        XCTAssertEqual(observedExponents, Set(0...7), "test table should exercise all 8 segments")
    }

    func testExtremeValuesRoundTrip() {
        for x: Int16 in [Int16.max, Int16.min, Int16.min + 1, -1, 0, 1] {
            let decoded = G711MuLawCodec.decodeSample(G711MuLawCodec.encodeSample(x))
            let bound = ExpectedG711.maxError(forMagnitude: x == Int16.min ? 32_768 : abs(Int(x)))
            XCTAssertLessThanOrEqual(abs(Int(decoded) - Int(x)), bound)
        }
    }

    // MARK: - Monotonicity

    func testEncodingIsMonotonicInMagnitudePerSign() {
        var previousPositive = -1
        for x in stride(from: Int16(0), through: Int16.max, by: 1) {
            let decoded = Int(G711MuLawCodec.decodeSample(G711MuLawCodec.encodeSample(x)))
            XCTAssertGreaterThanOrEqual(decoded, previousPositive, "not monotonic at x=\(x)")
            previousPositive = decoded
            if x == Int16.max { break }
        }

        var previousNegativeMagnitude = -1
        var x = Int32(0)
        while x >= Int32(Int16.min) {
            let decoded = Int(G711MuLawCodec.decodeSample(G711MuLawCodec.encodeSample(Int16(x))))
            XCTAssertGreaterThanOrEqual(
                abs(decoded), previousNegativeMagnitude, "not monotonic at x=\(x)"
            )
            previousNegativeMagnitude = abs(decoded)
            x -= 1
        }
    }

    // MARK: - Full byte-space properties

    func testAll256BytesDecodeToDistinctValues() {
        var seen = Set<Int16>()
        for raw in 0...255 {
            seen.insert(G711MuLawCodec.decodeSample(UInt8(raw)))
        }
        XCTAssertEqual(seen.count, 256)
    }

    func testDecodeThenEncodeIsExactForEveryByte() {
        for raw in 0...255 {
            let byte = UInt8(raw)
            let decoded = G711MuLawCodec.decodeSample(byte)
            let reencoded = G711MuLawCodec.encodeSample(decoded)
            XCTAssertEqual(reencoded, byte, "byte \(String(format: "0x%02X", byte)) did not round trip")
        }
    }
}
