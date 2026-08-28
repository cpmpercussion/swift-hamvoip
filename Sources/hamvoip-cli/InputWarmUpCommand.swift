// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import AVFoundation
import Foundation
import RadioCore

// MARK: - Command

/// `hamvoip-cli experiment input-warm-up` — how long an input device takes to
/// start producing *audio* after it is opened, and whether opening it once
/// beforehand removes that delay (Currawong's `BU-22`).
///
/// The fault: the first over after the input device spins up is silent. Frames
/// arrive from the tap the whole time — they are simply all zero — so nothing
/// above the device can tell it from an operator saying nothing. Measured on
/// melchior 2026-08-28 against a cold Bluetooth headset: frames from 178 ms,
/// **audio only from 1574 ms**, and then audio in the very first frame of the
/// next open.
///
/// Local, not on air: nothing is transmitted and no node is dialled. It opens
/// the microphone (`docs/CLI.md` §1 covers the macOS permission) and reports
/// counts and timings only — no audio is written anywhere.
struct InputWarmUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input-warm-up",
        abstract: "Measure how long an input device delivers silence after it is opened (BU-22).",
        discussion: """
            WHAT IT MEASURES. Two captures with a gap between them, which is the shape of \
            Currawong's fix for BU-22: a warm-up when the session connects, then the \
            operator's first over. For each, the time to the first frame and the time to \
            the first frame that is not all zeros — and the gap between those two numbers \
            is the fault.

            IT NEEDS A COLD DEVICE, and that is the hard part. A permanently powered input \
            — a USB webcam, most built-in microphones — shows nothing at all: it delivered \
            room noise in its first buffer, 283 ms in, on the same machine that showed \
            1574 ms of zeros on a Bluetooth headset minutes later. Make the headset the \
            default input, then leave the machine alone for twenty minutes or so before \
            running this. Anything that opens the microphone in the meantime — including a \
            previous run of this command — warms the device and spends the measurement.

            THE QUESTION IT IS STILL OPEN ON. Currawong holds its warm-up for about a \
            second past the route settling, and whether that is enough depends on something \
            not yet measured: whether it is the *opening* that wakes the device, or holding \
            it open until audio appears. Run with --warm-up shorter than the silence you \
            measured (0.5, say, against 1574 ms) and read the second capture:

              audio in the first frame     the opening is what wakes it; a short warm-up is enough
              a delay again, as before     the hold has to outlast the silence, and Currawong's
                                           warmUpHoldTicks is too small

            MEASURED 2026-08-28, melchior, cold AirPods: a 0.8 s warm-up that never saw \
            audio itself — 35 frames, every one of them zero — was still enough to leave \
            the next open carrying audio 98 ms in, against roughly 1400 ms cold. So it is \
            the opening that wakes the device.

            SECOND DEVICE 2026-08-29, a TIDRADIO Q2L: no fault at all — audio in the \
            first frame from every state tried, including a power cycle. The fault is not \
            "Bluetooth", it is inputs that power their microphone down; a PTT speaker-mic \
            keeps its ready. A device with no fault cannot confirm a hold chosen to fix \
            one. Note that idling may not produce a cold device: 20 minutes left the Q2L \
            awake. See docs/CLI.md §13.
            """)

    @Option(name: .long, help: "Seconds to hold the warm-up capture open.")
    var warmUp: Double = 1.6

    @Option(name: .long, help: "Seconds between the warm-up closing and the second capture.")
    var gap: Double = 1.5

    @Option(name: .long, help: "Seconds to hold the second capture open.")
    var over: Double = 4

    @Flag(name: .long, help: "Skip the warm-up, to measure the fault on its own.")
    var noWarmUp: Bool = false

    func run() async throws {
        guard warmUp > 0, gap >= 0, over > 0 else {
            throw ValidationError("durations must be positive.")
        }

        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        // The engine must outlive the read: an AVAudioNode does not keep its
        // engine alive, and `AVAudioEngine().inputNode.outputFormat(forBus: 0)`
        // as one expression is a use-after-free that segfaults inside
        // AVAudioIONodeImpl::GetOutputFormat.
        print("Input node: \(format.sampleRate) Hz, \(format.channelCount) ch, "
              + "interleaved=\(format.isInterleaved)")
        withExtendedLifetime(engine) {}

        let pipeline = AudioPipeline()
        defer { pipeline.stop() }
        let tally = SilenceTally()

        if !noWarmUp {
            tally.restart()
            try pipeline.startCapture { tally.note($0) }
            try await Task.sleep(nanoseconds: UInt64(warmUp * 1_000_000_000))
            print(tally.report(label: "warm-up (\(warmUp)s)"))
            pipeline.stop()
            try await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
        }

        tally.restart()
        try pipeline.startCapture { tally.note($0) }
        try await Task.sleep(nanoseconds: UInt64(over * 1_000_000_000))
        let second = tally.snapshot()
        print(tally.report(
            label: noWarmUp ? "capture (\(over)s, no warm-up)" : "over, \(gap)s after the warm-up"))
        pipeline.stop()

        print("")
        print(Self.verdict(for: second, warmedUp: !noWarmUp))
    }

    static func verdict(for capture: SilenceTally.Snapshot, warmedUp: Bool) -> String {
        guard capture.frames > 0 else {
            return "NO FRAMES AT ALL. The device delivered nothing — which is its own "
                + "finding, and a known hazard when a Bluetooth input is reopened soon "
                + "after being closed. Not the silence this measures."
        }
        guard let audioAt = capture.firstAudioMilliseconds else {
            return "ALL ZEROS for the whole capture. The device never produced audio: "
                + "either it is muted, or the wake-up is longer than this run."
        }
        let frameAt = capture.firstFrameMilliseconds ?? 0
        let silence = audioAt - frameAt
        if silence < 100 {
            return warmedUp
                ? "WARM: audio \(Int(silence)) ms after the first frame. The warm-up removed "
                    + "the delay — which is what BU-22's fix claims."
                : "NO FAULT HERE: audio \(Int(silence)) ms after the first frame with no "
                    + "warm-up at all. This device was already awake; see the note about "
                    + "needing a cold one."
        }
        return warmedUp
            ? "STILL COLD: \(Int(silence)) ms of zeros *after* a warm-up. The warm-up did "
                + "not take — so it is not merely the opening that wakes this device, and a "
                + "hold shorter than the silence is not enough."
            : "THE FAULT: \(Int(silence)) ms of zeros, with frames arriving throughout. "
                + "This is what a silent first over is made of."
    }
}

// MARK: - Tally

/// Counts frames and the first one that is not all zeros.
///
/// `onFrame` is called from the pipeline's drain task, and the report is read
/// from the command's own task, so this takes a lock. It never touches the
/// audio thread — see `AudioPipeline`.
final class SilenceTally: @unchecked Sendable {
    struct Snapshot {
        let frames: Int
        let framesWithAudio: Int
        let firstFrameMilliseconds: Double?
        let firstAudioMilliseconds: Double?
    }

    private let lock = NSLock()
    private var began = Date()
    private var frames = 0
    private var framesWithAudio = 0
    private var firstFrame: Double?
    private var firstAudio: Double?

    func restart() {
        lock.lock()
        began = Date()
        frames = 0
        framesWithAudio = 0
        firstFrame = nil
        firstAudio = nil
        lock.unlock()
    }

    func note(_ pcm: [Int16]) {
        // Exact zeros, not a threshold. A device that has not woken up delivers
        // *nothing at all*, and a threshold here would blur that into "quiet",
        // which is precisely the distinction BU-22 turns on: silence is not the
        // same thing as a dead device.
        let carriesAudio = pcm.contains { $0 != 0 }
        lock.lock()
        let elapsed = Date().timeIntervalSince(began) * 1000
        frames += 1
        if firstFrame == nil { firstFrame = elapsed }
        if carriesAudio {
            framesWithAudio += 1
            if firstAudio == nil { firstAudio = elapsed }
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            frames: frames, framesWithAudio: framesWithAudio,
            firstFrameMilliseconds: firstFrame, firstAudioMilliseconds: firstAudio)
    }

    func report(label: String) -> String {
        let snap = snapshot()
        let frame = snap.firstFrameMilliseconds.map { String(format: "%.0f ms", $0) } ?? "never"
        let audio = snap.firstAudioMilliseconds.map { String(format: "%.0f ms", $0) } ?? "NEVER"
        return "\(label): \(snap.frames) frames, \(snap.framesWithAudio) with audio, "
            + "first frame \(frame), first audio \(audio)"
    }
}
