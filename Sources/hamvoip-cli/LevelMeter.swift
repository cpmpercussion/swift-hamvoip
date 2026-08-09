// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Turns 20 ms frames of 8 kHz PCM into something a human can watch.
///
/// Pure arithmetic and string building — no audio device, no terminal, no
/// clock beyond the frame count. That is deliberate: "is there audio, and is
/// it at a sane level?" is one of the two questions the CLI harness exists to
/// answer (M2's checklist), and it would be embarrassing to get the answer
/// wrong because the dBFS conversion was never tested.
///
/// ### Why RMS and not peak
///
/// Peak level tells you almost nothing about speech: a single sample near full
/// scale reads 0 dBFS on a frame that is otherwise silence. RMS over a 20 ms
/// frame is short enough to follow syllables and long enough not to flicker.
/// A separate slow-decay peak hold rides on top, because the useful question
/// when setting levels is "did anything clip in the last second", which an
/// instantaneous meter cannot answer.
struct LevelMeter {
    /// Anything at or below this reads as silence; it is also the bottom of
    /// the bar. −60 dBFS is roughly the noise floor of an ordinary laptop
    /// microphone in a quiet room.
    static let floorDB: Double = -60

    /// Full scale. `Int16.min` is −32768 and `Int16.max` is +32767, so
    /// dividing by 32768 keeps the result inside [0, 1] for every possible
    /// sample, including `Int16.min`, whose magnitude has no positive
    /// counterpart.
    private static let fullScale: Double = 32768

    /// Per-frame decay applied to the held peak. 0.92 per 20 ms frame is about
    /// −0.7 dB per frame: a peak stays legible for roughly a second.
    private static let peakDecay: Double = 0.92

    private(set) var currentDB: Double = LevelMeter.floorDB
    private(set) var peakDB: Double = LevelMeter.floorDB
    private(set) var frameCount: Int = 0

    /// Whether audio has been seen recently enough to call this channel
    /// active. Used for the RX indicator: a node that is idle sends comfort
    /// silence, and a meter pinned at the floor is what "nobody is talking"
    /// looks like.
    var isActive: Bool { currentDB > LevelMeter.floorDB + 6 }

    // MARK: Pure conversions

    /// Root-mean-square of a frame, as a fraction of full scale in [0, 1].
    /// An empty frame is silence, not a division by zero.
    static func rms(_ pcm: [Int16]) -> Double {
        guard !pcm.isEmpty else { return 0 }
        var sum = 0.0
        for sample in pcm {
            let normalised = Double(sample) / fullScale
            sum += normalised * normalised
        }
        return (sum / Double(pcm.count)).squareRoot()
    }

    /// dBFS for a [0, 1] amplitude, clamped at ``floorDB`` so digital silence
    /// is a number rather than −∞.
    static func decibels(amplitude: Double) -> Double {
        guard amplitude > 0 else { return floorDB }
        let db = 20 * log10(amplitude)
        return db.isFinite ? max(db, floorDB) : floorDB
    }

    /// dBFS of one frame.
    static func decibels(of pcm: [Int16]) -> Double {
        decibels(amplitude: rms(pcm))
    }

    /// A `width`-cell bar for a level in dBFS, filled in proportion to the
    /// distance from ``floorDB`` up to 0.
    ///
    /// Levels above 0 dBFS cannot occur (the input is Int16), and levels below
    /// the floor give an empty bar rather than a negative one.
    static func bar(decibels db: Double, width: Int) -> String {
        guard width > 0 else { return "" }
        let span = -floorDB
        let fraction = max(0, min(1, (db - floorDB) / span))
        let filled = Int((fraction * Double(width)).rounded())
        return String(repeating: "#", count: filled)
            + String(repeating: ".", count: width - filled)
    }

    /// dBFS formatted for a fixed-width status line: always a sign, always one
    /// decimal, and the floor shown as `-inf` so a silent channel is
    /// unmistakable.
    static func format(decibels db: Double) -> String {
        if db <= floorDB { return " -inf" }
        return String(format: "%5.1f", db)
    }

    // MARK: Stateful metering

    /// Folds one frame in, updating the instantaneous level and the held peak.
    mutating func push(_ pcm: [Int16]) {
        frameCount += 1
        currentDB = Self.decibels(of: pcm)
        let decayed = Self.floorDB + (peakDB - Self.floorDB) * Self.peakDecay
        peakDB = max(currentDB, decayed)
    }

    /// One frame's worth of decay with no new audio — what a channel that has
    /// stopped delivering frames should look like, rather than freezing at
    /// whatever it last read.
    mutating func idle() {
        currentDB = Self.floorDB + (currentDB - Self.floorDB) * Self.peakDecay
        peakDB = Self.floorDB + (peakDB - Self.floorDB) * Self.peakDecay
    }

    /// `##### .....  -18.3 dBFS` — the bar, the number, and a `PEAK` marker
    /// when the held peak is within 3 dB of full scale.
    func rendered(width: Int = 16) -> String {
        let clipping = peakDB > -3 ? " CLIP" : ""
        return "\(Self.bar(decibels: currentDB, width: width)) \(Self.format(decibels: currentDB)) dBFS\(clipping)"
    }
}
