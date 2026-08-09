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

    /// µ-law has both a positive and a negative zero code, so the decode map
    /// is *not* injective: 0xFF and 0x7F both decode to 0, giving 255 distinct
    /// outputs from 256 inputs. An implementation that produces 256 distinct
    /// values has departed from G.711 somewhere.
    func testDecodeIsInjectiveExceptForTheTwoZeroCodes() {
        var seen = Set<Int16>()
        for raw in 0...255 {
            seen.insert(G711MuLawCodec.decodeSample(UInt8(raw)))
        }
        XCTAssertEqual(seen.count, 255)
        XCTAssertEqual(G711MuLawCodec.decodeSample(0xFF), 0, "positive zero")
        XCTAssertEqual(G711MuLawCodec.decodeSample(0x7F), 0, "negative zero")
    }

    /// Every byte except negative zero re-encodes to itself. 0x7F is the sole
    /// exception, and collapses onto the positive zero code.
    func testDecodeThenEncodeIsExactForEveryByteExceptNegativeZero() {
        for raw in 0...255 {
            let byte = UInt8(raw)
            let decoded = G711MuLawCodec.decodeSample(byte)
            let reencoded = G711MuLawCodec.encodeSample(decoded)
            let expected: UInt8 = (byte == 0x7F) ? 0xFF : byte
            XCTAssertEqual(reencoded, expected, "byte \(String(format: "0x%02X", byte)) did not round trip")
        }
    }

    // MARK: - Conformance to the classic 14-bit formulation

    /// Pins this implementation against the textbook G.711 construction
    /// (right-shift to 14 bits, clip 8159, bias 33, segment-end search).
    ///
    /// The two agree bit-for-bit on every non-negative sample. They diverge on
    /// 381 negative samples for one reason only: shifting a negative value
    /// right floors it, which rounds the *magnitude* away from zero, whereas
    /// this implementation takes the magnitude first and truncates toward
    /// zero. Ours is symmetric in sign; the textbook version's asymmetry is an
    /// artefact of C's arithmetic shift, not something G.711 asks for. Both
    /// are within one quantisation step, so both interoperate.
    ///
    /// This test locks in that story: exact agreement on non-negatives, and
    /// exact agreement on negatives once the reference is given the same
    /// magnitude-first treatment.
    func testMatchesClassic14BitFormulation() {
        let segmentEnds = [0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF]

        func reference(_ pcm: Int16, magnitudeFirst: Bool) -> UInt8 {
            let mask: Int
            var value: Int
            if magnitudeFirst {
                mask = pcm < 0 ? 0x7F : 0xFF
                value = abs(Int(pcm)) >> 2
            } else {
                value = Int(pcm) >> 2
                if value < 0 { mask = 0x7F; value = -value } else { mask = 0xFF }
            }
            value = min(value, 8159)
            value += 33
            let segment = segmentEnds.firstIndex { value <= $0 } ?? 8
            if segment >= 8 { return UInt8(0x7F ^ mask) }
            return UInt8(((segment << 4) | ((value >> (segment + 1)) & 0x0F)) ^ mask)
        }

        var negativeDivergences = 0
        for raw in Int(Int16.min)...Int(Int16.max) {
            let sample = Int16(raw)
            let ours = G711MuLawCodec.encodeSample(sample)

            XCTAssertEqual(ours, reference(sample, magnitudeFirst: true),
                           "diverged from the magnitude-first reference at \(sample)")

            if ours != reference(sample, magnitudeFirst: false) {
                XCTAssertLessThan(sample, 0, "diverged from the textbook reference at \(sample), which is not negative")
                negativeDivergences += 1
            }
        }
        XCTAssertEqual(negativeDivergences, 381, "the shift-direction divergence set changed size")
    }
}
