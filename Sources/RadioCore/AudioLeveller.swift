// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A slow automatic-gain-control (AGC) stage for received audio (AU-4).
///
/// Different ham VoIP networks (IAX2/AllStar, M17 reflectors, EchoLink) hand
/// back audio at wildly different levels — the operator should not have to
/// ride the volume knob every time they switch modes. `AudioLeveller` nudges
/// the RMS level of each incoming frame toward a target, smoothly, with a
/// fast-ish attack (turn loud audio down quickly) and a slow release (don't
/// pump quiet speech up during natural pauses).
///
/// Pure DSP: it operates on buffers of `Int16` PCM samples at a known sample
/// rate. No I/O, no clocks — the caller owns the audio pipeline.
public struct AudioLeveller: Sendable {
    /// Sample rate of the PCM this instance processes, in Hz.
    public let sampleRate: Double
    /// Target RMS level, in dBFS (negative; 0 dBFS = full-scale sine RMS
    /// would be about -3 dBFS, but we measure plain sample RMS here so 0
    /// dBFS corresponds to a full-scale square wave — what matters is that
    /// target/floor/ceiling are all measured the same way).
    public let targetRMSdBFS: Float
    /// Frames whose RMS is below this level are treated as "no signal": the
    /// current gain is held, never increased, so background hiss/silence
    /// between transmissions doesn't get boosted toward the target.
    public let noiseFloorRMSdBFS: Float
    /// Hard ceiling on applied gain, in dB. Prevents a very quiet floor from
    /// being amplified into a howl.
    public let maxGainDB: Float
    /// Hard floor on applied gain, in dB (negative = attenuation). Prevents
    /// a hot input from merely being "less amplified" — it must actually be
    /// turned down.
    public let minGainDB: Float

    /// One-pole smoothing coefficient for rising gain error correction
    /// (attack — level going up faster than target, or gain needs to
    /// decrease quickly) and falling correction (release). See `init` for
    /// the derivation.
    private let attackCoeff: Float
    private let releaseCoeff: Float

    /// Currently-applied linear gain (1.0 = unity). This is the gain in
    /// effect at the *end* of the most recently processed buffer; within a
    /// buffer, gain is interpolated sample-by-sample toward the frame's
    /// target gain so there is no step/zipper discontinuity.
    private var gainLinear: Float

    /// Current gain, linear (1.0 = unity, i.e. 0 dB).
    public var currentGain: Float { gainLinear }

    /// Current gain, in dB, derived from `currentGain`.
    public var currentGainDB: Float { 20 * log10(max(gainLinear, 1e-9)) }

    /// - Parameters:
    ///   - sampleRate: PCM sample rate in Hz. Default 8000 (narrowband ham
    ///     voice: G.711, Codec2, GSM 06.10 all run at 8 kHz).
    ///   - targetRMSdBFS: Desired output RMS level, in dBFS. Default -18.
    ///   - attackSeconds: Time constant for gain *decreasing* (loud input,
    ///     or any drop toward the ceiling/floor). Default 0.05 s (50 ms) —
    ///     fast enough to tame a sudden loud burst before it's obviously
    ///     jarring, slow enough to not distort the waveform envelope.
    ///   - releaseSeconds: Time constant for gain *increasing* (quiet
    ///     input being brought up toward target). Default 0.5 s (500 ms) —
    ///     deliberately slow so gain doesn't pump during ordinary syllable
    ///     gaps, only easing up during genuinely quiet passages.
    ///   - maxGainDB: Ceiling on applied gain. Default +18 dB.
    ///   - minGainDB: Floor on applied gain (attenuation limit for hot
    ///     sources). Default -12 dB.
    ///   - noiseFloorRMSdBFS: Frames at or below this RMS are passed through
    ///     with the current gain held (never boosted). Default -55 dBFS.
    public init(
        sampleRate: Double = 8000,
        targetRMSdBFS: Float = -18,
        attackSeconds: Double = 0.050,
        releaseSeconds: Double = 0.500,
        maxGainDB: Float = 18,
        minGainDB: Float = -12,
        noiseFloorRMSdBFS: Float = -55
    ) {
        self.sampleRate = sampleRate
        self.targetRMSdBFS = targetRMSdBFS
        self.maxGainDB = maxGainDB
        self.minGainDB = minGainDB
        self.noiseFloorRMSdBFS = noiseFloorRMSdBFS

        // One-pole ("exponential moving average") smoothing coefficient for
        // a time constant tau seconds, updated once per sample at rate fs:
        //
        //     coeff = 1 - exp(-1 / (tau * fs))
        //
        // With gain_next = gain + coeff * (target - gain), coeff derived
        // this way makes the response reach ~63% of the way to a step
        // change in target after tau seconds, matching the conventional
        // definition of an attack/release time constant in analogue and
        // digital compressors/AGCs.
        self.attackCoeff = Float(1 - exp(-1.0 / (attackSeconds * sampleRate)))
        self.releaseCoeff = Float(1 - exp(-1.0 / (releaseSeconds * sampleRate)))

        self.gainLinear = 1.0
    }

    /// Resets applied gain to unity (0 dB). Does not change configuration.
    public mutating func reset() {
        gainLinear = 1.0
    }

    /// Processes `pcm` in place: measures its RMS level, decides a target
    /// gain, and applies gain to every sample, ramping smoothly from the
    /// gain in effect at the start of the buffer to the new target gain by
    /// its end (linear interpolation of the *linear* gain factor per
    /// sample) so there is no audible step between buffers.
    public mutating func process(_ pcm: inout [Int16]) {
        guard !pcm.isEmpty else { return }

        let rmsDBFS = Self.rmsDBFS(pcm)

        // Decide the gain we'd like to be applying by the end of this
        // buffer. Below the noise floor: hold current gain (never boost
        // silence/background hiss toward the target).
        var targetGainDB: Float
        if rmsDBFS <= noiseFloorRMSdBFS {
            targetGainDB = currentGainDB
        } else {
            targetGainDB = targetRMSdBFS - rmsDBFS
        }
        targetGainDB = min(max(targetGainDB, minGainDB), maxGainDB)
        let targetGainLinear = Self.dbToLinear(targetGainDB)

        // Attack when gain needs to fall (loud input arrived), release when
        // gain needs to rise (bringing quiet input up toward target).
        let coeff = targetGainLinear < gainLinear ? attackCoeff : releaseCoeff

        // Apply gain sample-by-sample, updating the one-pole filter once per
        // sample so the gain trajectory (and hence the coefficient's time
        // constant) is expressed per-sample regardless of buffer size, and
        // so there is no discontinuity at buffer boundaries.
        let startGain = gainLinear
        var g = startGain
        for i in 0..<pcm.count {
            g += coeff * (targetGainLinear - g)
            let sample = Float(pcm[i])
            let boosted = sample * g
            pcm[i] = Self.clampToInt16(boosted)
        }
        gainLinear = g
    }

    /// Converts a dB value to a linear amplitude ratio.
    private static func dbToLinear(_ db: Float) -> Float {
        pow(10, db / 20)
    }

    /// RMS level of a PCM buffer, in dBFS relative to `Int16.max`.
    /// Silence (all-zero buffer) reports `-.infinity`.
    static func rmsDBFS(_ pcm: [Int16]) -> Float {
        guard !pcm.isEmpty else { return -.infinity }
        var sumSquares: Double = 0
        for sample in pcm {
            let s = Double(sample)
            sumSquares += s * s
        }
        let meanSquare = sumSquares / Double(pcm.count)
        guard meanSquare > 0 else { return -.infinity }
        let rms = sqrt(meanSquare)
        let full = Double(Int16.max)
        return Float(20 * log10(rms / full))
    }

    /// Clamps a `Float` sample value into the `Int16` range, saturating
    /// (never wrapping). The multiply-by-gain result can wildly exceed
    /// `Int16` bounds, so the arithmetic is done in `Float` and only
    /// converted to `Int16` after clamping — converting an out-of-range
    /// `Float` directly to `Int16` is undefined/traps, and truncating bit
    /// patterns instead of clamping would flip the sign (the "wrap into
    /// noise" failure mode this type exists to avoid).
    private static func clampToInt16(_ value: Float) -> Int16 {
        if value >= Float(Int16.max) { return Int16.max }
        if value <= Float(Int16.min) { return Int16.min }
        return Int16(value)
    }
}
