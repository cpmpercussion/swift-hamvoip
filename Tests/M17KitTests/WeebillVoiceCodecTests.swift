// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import M17Kit

/// Tests for the pure-Swift Codec 2 3200 binding (M17-7).
///
/// Unlike ``Codec2VoiceCodecTests`` these are **unconditional**: Weebill is a
/// source dependency, so there is no checkout on which they do not run, CI
/// included. That is most of the point of the task.
///
/// ## What is asserted, and what deliberately is not
///
/// Not bit-exactness against codec2. Codec 2 is a parametric vocoder whose
/// analysis stage is not specified to the bit, so two conforming encoders can
/// choose different quantiser indices for the same audio and both be right.
/// Worse, Weebill synthesises unvoiced phases stochastically, so it is not
/// waveform-identical even to itself across seeds. Asserting sample equality
/// anywhere here would be asserting that one implementation is the other.
///
/// What is asserted instead is that the *signal survives*: a voiced input
/// comes back at the pitch and level it went in at, and — where the XCFramework
/// is present — that it does so across the implementation boundary in both
/// directions, which is the only property M17 interoperability actually needs.
/// The perceptual judgement behind that choice was made by ear, off-air, by the
/// maintainer; these tests are the regression net under it, not the evidence
/// for it. The measured evidence is in `experiment-data/weebill-m17-7/`.
final class WeebillVoiceCodecTests: XCTestCase {

    // MARK: - Geometry and contract

    func testGeometryIs160SamplesAnd8Bytes() throws {
        let codec = try WeebillVoiceCodec()
        XCTAssertEqual(codec.samplesPerFrame, 160)
        XCTAssertEqual(codec.bytesPerFrame, 8)
    }

    /// The 16-byte M17 stream payload is exactly two frames — the arithmetic
    /// `M17StreamPayload` depends on, checked against this codec rather than
    /// against a constant.
    func testTwoFramesFillAnM17StreamPayload() throws {
        let codec = try WeebillVoiceCodec()
        XCTAssertEqual(codec.bytesPerFrame * 2, 16)
        XCTAssertEqual(codec.samplesPerFrame * 2, 320)  // 40 ms at 8 kHz
    }

    func testEncodeRejectsAnythingButOneFrameOfPCM() throws {
        let codec = try WeebillVoiceCodec()
        for count in [0, 159, 161, 320] {
            XCTAssertThrowsError(try codec.encode([Int16](repeating: 0, count: count))) { error in
                XCTAssertEqual(
                    error as? WeebillCodecError,
                    .wrongSampleCount(expected: 160, actual: count))
            }
        }
    }

    func testDecodeRejectsAnythingButOneEncodedFrame() throws {
        let codec = try WeebillVoiceCodec()
        for count in [0, 7, 9, 16] {
            XCTAssertThrowsError(try codec.decode([UInt8](repeating: 0, count: count))) { error in
                XCTAssertEqual(
                    error as? WeebillCodecError,
                    .wrongFrameSize(expected: 8, actual: count))
            }
        }
    }

    // MARK: - Determinism

    /// Two codecs constructed the same way must decode the same bytes to the
    /// same samples.
    ///
    /// This is what the pinned `phaseSeed` default buys, and it is load-bearing
    /// rather than cosmetic: the unvoiced-phase PRNG makes Weebill's output
    /// seed-dependent, so without a pin every test downstream of a decode —
    /// and every A/B listening comparison — would be measuring a different
    /// signal each run.
    func testDecodeIsDeterministicAcrossInstances() throws {
        let frames = Self.encodedSpeechLikeFrames(count: 25)
        let first = try WeebillVoiceCodec()
        let second = try WeebillVoiceCodec()
        for frame in frames {
            XCTAssertEqual(try first.decode(frame), try second.decode(frame))
        }
    }

    /// `reset()` must put the decoder back where a fresh one starts, or a
    /// second over on the same link would begin with the tail of the first.
    func testResetReturnsTheCodecToItsInitialState() throws {
        let frames = Self.encodedSpeechLikeFrames(count: 25)
        let reused = try WeebillVoiceCodec()
        let fresh = try WeebillVoiceCodec()

        for frame in frames { _ = try reused.decode(frame) }
        reused.reset()

        for frame in frames {
            XCTAssertEqual(try reused.decode(frame), try fresh.decode(frame))
        }
    }

    // MARK: - Signal integrity

    /// A voiced signal must come back at the pitch and level it went in at.
    ///
    /// The substantive round-trip assertion. A vocoder is free to change the
    /// waveform completely — that is what it is for — but it may not move the
    /// fundamental or lose the level, and a mis-transcribed quantiser table
    /// shows up in one or the other immediately.
    func testEncodeThenDecodePreservesPitchAndLevel() throws {
        let codec = try WeebillVoiceCodec()
        let f0 = 125.0
        let input = Self.voicedSignal(f0: f0, frames: 50)

        var output: [Int16] = []
        for frame in Self.split(input, into: 160) {
            output += try codec.decode(try codec.encode(frame))
        }

        // The first frames are the codec converging from its initial state;
        // the same allowance `Codec2VoiceCodecTests` makes for the framework.
        let settled = Array(output.dropFirst(160 * 5))
        let reference = Array(input.dropFirst(160 * 5))

        XCTAssertEqual(Self.fundamental(of: settled), f0, accuracy: 8.0)
        XCTAssertEqual(
            Self.rmsDB(settled), Self.rmsDB(reference), accuracy: 6.0,
            "decoded level drifted more than 6 dB from the input")
    }

    /// Silence in, silence out — no idle hiss on a quiet channel.
    func testSilenceDecodesQuiet() throws {
        let codec = try WeebillVoiceCodec()
        var output: [Int16] = []
        for _ in 0..<25 {
            output += try codec.decode(try codec.encode([Int16](repeating: 0, count: 160)))
        }
        XCTAssertLessThan(Self.rmsDB(Array(output.dropFirst(160 * 5))), -60.0)
    }

    /// No bitstream, however wrong, may make the synthesis stage produce a
    /// non-finite sample.
    ///
    /// Off the air this is not hypothetical: M17 carries codec bytes with no
    /// FEC of our own over UDP, so a corrupted frame reaching the decoder is a
    /// question of when. Weebill counts its own substitutions, and the count
    /// must stay at zero rather than merely be survivable.
    func testArbitraryBitstreamsNeverSynthesiseNonFiniteSamples() throws {
        let codec = try WeebillVoiceCodec()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let frame = (0..<8).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
            XCTAssertEqual(try codec.decode(frame).count, 160)
        }
        XCTAssertEqual(codec.nonFiniteSampleCount, 0)
    }

    // MARK: - Against the reference implementation

    #if CODEC2

    /// Weebill's bits, decoded by codec2 — the direction that matters for
    /// anyone listening to us.
    ///
    /// Compiled only where `Codec2.xcframework` has been built, so it does not
    /// run on CI. That is a limitation worth stating plainly: the interop
    /// evidence is a local and an on-air result, not a gate.
    func testCodec2DecodesWhatWeebillEncoded() throws {
        try assertCrossDecodeSurvives(
            encoder: try WeebillVoiceCodec(), decoder: try Codec2VoiceCodec())
    }

    /// codec2's bits, decoded by Weebill — the direction that matters for
    /// listening to a net, since every other station on it is running codec2.
    func testWeebillDecodesWhatCodec2Encoded() throws {
        try assertCrossDecodeSurvives(
            encoder: try Codec2VoiceCodec(), decoder: try WeebillVoiceCodec())
    }

    /// Both implementations must agree about the *shape* of the bitstream even
    /// when they disagree about its contents: same frame size, same rate.
    func testBothImplementationsReportTheSameGeometry() throws {
        let weebill = try WeebillVoiceCodec()
        let reference = try Codec2VoiceCodec()
        XCTAssertEqual(weebill.samplesPerFrame, reference.samplesPerFrame)
        XCTAssertEqual(weebill.bytesPerFrame, reference.bytesPerFrame)
    }

    /// Encode with one, decode with the other, and require the fundamental and
    /// the level to survive the crossing.
    private func assertCrossDecodeSurvives(
        encoder: any VoiceCodec,
        decoder: any VoiceCodec,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let f0 = 125.0
        let input = Self.voicedSignal(f0: f0, frames: 50)

        var output: [Int16] = []
        for frame in Self.split(input, into: 160) {
            output += try decoder.decode(try encoder.encode(frame))
        }

        let settled = Array(output.dropFirst(160 * 5))
        let reference = Array(input.dropFirst(160 * 5))

        XCTAssertEqual(
            Self.fundamental(of: settled), f0, accuracy: 8.0,
            "pitch did not survive the implementation boundary", file: file, line: line)
        XCTAssertEqual(
            Self.rmsDB(settled), Self.rmsDB(reference), accuracy: 6.0,
            "level did not survive the implementation boundary", file: file, line: line)
    }

    #endif

    // MARK: - Signal helpers

    /// A synthetic voiced sound: a fundamental and seven harmonics under a
    /// falling envelope, which is roughly what Codec 2's sinusoidal model
    /// expects to see and is inside its 50–400 Hz pitch range.
    ///
    /// Deliberately synthetic rather than a recording. A speech fixture would
    /// be a licensing and provenance question for the sake of a test whose
    /// assertions are about pitch and level, which a tone carries perfectly
    /// well.
    static func voicedSignal(f0: Double, frames: Int) -> [Int16] {
        let count = frames * 160
        var out = [Int16](repeating: 0, count: count)
        for n in 0..<count {
            let t = Double(n) / 8000.0
            var sample = 0.0
            for harmonic in 1...8 {
                let f = f0 * Double(harmonic)
                guard f < 3400 else { break }
                sample += (1.0 / Double(harmonic)) * sin(2 * .pi * f * t)
            }
            out[n] = Int16(max(-1.0, min(1.0, sample / 2.0)) * 8000)
        }
        return out
    }

    /// A run of frames encoded from the synthetic voiced signal, for the tests
    /// that only need plausible bitstreams rather than a known input.
    static func encodedSpeechLikeFrames(count: Int) -> [[UInt8]] {
        guard let codec = try? WeebillVoiceCodec() else { return [] }
        return split(voicedSignal(f0: 125, frames: count), into: 160)
            .compactMap { try? codec.encode($0) }
    }

    static func split(_ samples: [Int16], into size: Int) -> [[Int16]] {
        stride(from: 0, to: samples.count - size + 1, by: size)
            .map { Array(samples[$0..<($0 + size)]) }
    }

    static func rmsDB(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        let sum = samples.reduce(0.0) { $0 + pow(Double($1) / 32768.0, 2) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    /// The fundamental, by normalised autocorrelation over the 50–400 Hz range
    /// Codec 2 itself works in.
    ///
    /// Autocorrelation rather than a DFT peak because a vocoder is free to
    /// redistribute energy between harmonics — the strongest *bin* after a
    /// round trip need not be the fundamental, but the strongest *period*
    /// still is.
    ///
    /// **Octave errors are the trap here, and they are the measurement's
    /// rather than the codec's.** A periodic signal correlates just as well
    /// against two periods as against one, so "highest score wins" picks a
    /// sub-harmonic on exactly the clean synthetic input these tests use — it
    /// read 62 Hz for a 125 Hz signal the encoders had in fact both quantised
    /// to within 3% of 125. So the score is normalised by *both* windows'
    /// energy, and the shortest lag scoring within 10% of the best wins, which
    /// is the usual way of resolving the tie in favour of the fundamental.
    static func fundamental(of samples: [Int16]) -> Double {
        let signal = samples.map { Double($0) }
        let minLag = 20  // 400 Hz
        let maxLag = 160  // 50 Hz
        guard signal.count > maxLag * 2 else { return .nan }

        var scores: [Int: Double] = [:]
        for lag in minLag...maxLag {
            var numerator = 0.0
            var headEnergy = 0.0
            var tailEnergy = 0.0
            for n in 0..<(signal.count - lag) {
                numerator += signal[n] * signal[n + lag]
                headEnergy += signal[n] * signal[n]
                tailEnergy += signal[n + lag] * signal[n + lag]
            }
            let denominator = (headEnergy * tailEnergy).squareRoot()
            scores[lag] = denominator > 0 ? numerator / denominator : 0
        }

        let best = scores.values.max() ?? 0
        guard best > 0 else { return .nan }
        let shortestStrongLag = (minLag...maxLag).first { (scores[$0] ?? 0) >= best * 0.9 } ?? minLag
        return 8000.0 / Double(shortestStrongLag)
    }
}
