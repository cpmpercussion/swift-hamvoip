// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import RadioCore

// MARK: - Test helpers

/// Generates a mono sine wave as Int16 PCM, with phase carried across calls
/// so successive frames splice together without discontinuities.
private struct SineGenerator {
    let frequency: Double
    let sampleRate: Double
    let amplitude: Float
    private var phase: Double = 0

    init(frequency: Double, sampleRate: Double, amplitude: Float) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.amplitude = amplitude
    }

    mutating func next(_ count: Int) -> [Int16] {
        let w = 2 * Double.pi * frequency / sampleRate
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let value = Double(amplitude) * sin(phase)
            let clamped = max(Double(Int16.min), min(Double(Int16.max), value))
            out[i] = Int16(clamped)
            phase += w
        }
        return out
    }
}

/// Linear peak amplitude (relative to `Int16.max`) that makes a sine wave's
/// RMS land at the requested dBFS level, using the same reference
/// (`Int16.max`) as `measureRMSdBFS` below. For a sine, RMS = peak/sqrt(2).
private func sineAmplitude(forRMSdBFS dBFS: Float) -> Float {
    let linearRMS = pow(10, dBFS / 20)
    return linearRMS * Float(2).squareRoot() * Float(Int16.max)
}

/// Independent RMS-in-dBFS measurement, deliberately not sharing code with
/// `AudioLeveller`'s internals, so a bug in the leveller's own measurement
/// can't hide a bug in its behaviour.
private func measureRMSdBFS(_ pcm: [Int16]) -> Float {
    guard !pcm.isEmpty else { return -.infinity }
    var sumSquares = 0.0
    for sample in pcm {
        let s = Double(sample)
        sumSquares += s * s
    }
    let rms = (sumSquares / Double(pcm.count)).squareRoot()
    guard rms > 0 else { return -.infinity }
    return Float(20 * log10(rms / Double(Int16.max)))
}

/// Feeds `generator` through `leveller` frame by frame until the applied
/// gain is within `toleranceDB` of `targetGainDB`, returning the frame
/// count at convergence (or `maxFrames` if it never converges).
private func framesToConverge(
    leveller: inout AudioLeveller,
    generator: inout SineGenerator,
    targetGainDB: Float,
    toleranceDB: Float = 1.0,
    frameSize: Int = 160,
    maxFrames: Int = 1000
) -> Int {
    for n in 1...maxFrames {
        var frame = generator.next(frameSize)
        leveller.process(&frame)
        if abs(leveller.currentGainDB - targetGainDB) <= toleranceDB {
            return n
        }
    }
    return maxFrames
}

// MARK: - Tests

final class AudioLevellerTests: XCTestCase {
    private let sampleRate: Double = 8000
    private let frameSize = 160 // 20 ms at 8 kHz

    func testQuietSineConvergesNearTargetWithinTwoSeconds() {
        var leveller = AudioLeveller()
        var generator = SineGenerator(frequency: 440, sampleRate: sampleRate, amplitude: sineAmplitude(forRMSdBFS: -30))

        var lastFrame: [Int16] = []
        for _ in 0..<100 { // 100 * 20 ms = 2 s
            var frame = generator.next(frameSize)
            leveller.process(&frame)
            lastFrame = frame
        }

        let outputDBFS = measureRMSdBFS(lastFrame)
        XCTAssertEqual(outputDBFS, -18, accuracy: 2.0, "expected convergence near -18 dBFS target")
    }

    func testFrameBelowNoiseFloorIsNotBoosted() {
        var leveller = AudioLeveller()
        var generator = SineGenerator(frequency: 300, sampleRate: sampleRate, amplitude: sineAmplitude(forRMSdBFS: -60))

        for _ in 0..<200 { // 4 s of "silence" below the -55 dBFS floor
            var frame = generator.next(frameSize)
            leveller.process(&frame)
        }

        // Gain must never have moved off unity: a -60 dBFS frame is below
        // the noise floor, so the leveller should hold gain, not chase a
        // target that would otherwise ask for +42 dB of boost.
        XCTAssertEqual(leveller.currentGain, 1.0, accuracy: 0.001)
    }

    func testFullScaleInputIsAttenuatedWithoutWraparound() {
        var leveller = AudioLeveller()

        // Prime the leveller toward the +18 dB ceiling with a quiet-but-
        // audible passage, then hit it with a full-scale burst. This is
        // the scenario where an incorrect clamp (e.g. truncating instead
        // of saturating) would wrap loud audio into noise.
        var quiet = SineGenerator(frequency: 300, sampleRate: sampleRate, amplitude: sineAmplitude(forRMSdBFS: -40))
        for _ in 0..<200 {
            var frame = quiet.next(frameSize)
            leveller.process(&frame)
        }
        XCTAssertGreaterThan(leveller.currentGain, 1.0, "expected gain to have risen above unity during the quiet passage")

        var loud = SineGenerator(frequency: 1000, sampleRate: sampleRate, amplitude: Float(Int16.max))
        for _ in 0..<50 {
            let inputFrame = loud.next(frameSize)
            var frame = inputFrame
            leveller.process(&frame)

            for i in 0..<frame.count {
                // Note: Int16.min's magnitude (32768) legitimately exceeds
                // Int16.max's (32767) — that's an asymmetric two's-complement
                // range, not a wraparound. Check against the actual bounds,
                // not against a magnitude comparison that would flag a
                // correctly-saturated Int16.min as an "overflow".
                XCTAssertGreaterThanOrEqual(Int32(frame[i]), Int32(Int16.min), "output sample below Int16 range")
                XCTAssertLessThanOrEqual(Int32(frame[i]), Int32(Int16.max), "output sample above Int16 range")
                if inputFrame[i] > 0 {
                    XCTAssertGreaterThanOrEqual(frame[i], 0, "sign flipped: positive input produced negative output (wraparound)")
                } else if inputFrame[i] < 0 {
                    XCTAssertLessThanOrEqual(frame[i], 0, "sign flipped: negative input produced positive output (wraparound)")
                }
            }
        }

        XCTAssertLessThan(leveller.currentGain, 1.0, "expected a full-scale input to end up attenuated")
    }

    func testGainNeverExceedsCeilingAfterLongQuietPassage() {
        var leveller = AudioLeveller()
        // -50 dBFS is above the -55 dBFS noise floor but well below target,
        // so the leveller will keep asking for more gain than the +18 dB
        // ceiling allows.
        var generator = SineGenerator(frequency: 300, sampleRate: sampleRate, amplitude: sineAmplitude(forRMSdBFS: -50))

        for _ in 0..<2000 { // 40 s, far beyond the 500 ms release time constant
            var frame = generator.next(frameSize)
            leveller.process(&frame)
            XCTAssertLessThanOrEqual(leveller.currentGainDB, 18.0001, "gain exceeded the +18 dB ceiling")
        }

        XCTAssertEqual(leveller.currentGainDB, 18, accuracy: 0.1, "expected gain to have settled at the ceiling")
    }

    func testAttackIsFasterThanRelease() {
        // Both levellers start primed at the target level, so gain is at
        // unity before the step.
        var levellerForAttack = AudioLeveller()
        var levellerForRelease = AudioLeveller()
        var primeA = SineGenerator(frequency: 440, sampleRate: sampleRate, amplitude: sineAmplitude(forRMSdBFS: -18))
        var primeB = SineGenerator(frequency: 440, sampleRate: sampleRate, amplitude: sineAmplitude(forRMSdBFS: -18))
        for _ in 0..<100 {
            var fa = primeA.next(frameSize)
            levellerForAttack.process(&fa)
            var fb = primeB.next(frameSize)
            levellerForRelease.process(&fb)
        }
        XCTAssertEqual(levellerForAttack.currentGain, 1.0, accuracy: 0.05)
        XCTAssertEqual(levellerForRelease.currentGain, 1.0, accuracy: 0.05)

        // Step up in level (-18 -> -6 dBFS): gain must fall, i.e. attack.
        var loud = SineGenerator(frequency: 440, sampleRate: sampleRate, amplitude: sineAmplitude(forRMSdBFS: -6))
        let attackTargetDB: Float = -18 - (-6) // -12 dB
        let attackFrames = framesToConverge(leveller: &levellerForAttack, generator: &loud, targetGainDB: attackTargetDB)

        // Step down in level (-18 -> -30 dBFS): gain must rise, i.e. release.
        var quiet = SineGenerator(frequency: 440, sampleRate: sampleRate, amplitude: sineAmplitude(forRMSdBFS: -30))
        let releaseTargetDB: Float = -18 - (-30) // +12 dB
        let releaseFrames = framesToConverge(leveller: &levellerForRelease, generator: &quiet, targetGainDB: releaseTargetDB)

        XCTAssertLessThan(attackFrames, releaseFrames, "attack (\(attackFrames) frames) should converge faster than release (\(releaseFrames) frames)")
    }

    func testResetReturnsGainToUnity() {
        var leveller = AudioLeveller()
        var generator = SineGenerator(frequency: 440, sampleRate: sampleRate, amplitude: sineAmplitude(forRMSdBFS: -40))
        for _ in 0..<50 {
            var frame = generator.next(frameSize)
            leveller.process(&frame)
        }
        XCTAssertNotEqual(leveller.currentGain, 1.0)

        leveller.reset()
        XCTAssertEqual(leveller.currentGain, 1.0)
    }
}
