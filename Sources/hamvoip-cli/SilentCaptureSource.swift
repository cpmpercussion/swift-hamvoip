// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

/// What `--no-audio` feeds the transmit path, so that the flag means what the
/// banner says it means.
///
/// ### The bug this exists to remove
///
/// `--no-audio` printed "PTT will send silence" and sent **nothing at all**.
/// The only frame source was `AudioPipeline.startCapture(onFrame:)`, inside the
/// branch the flag switches off, so pressing PTT changed the client's state and
/// then offered it no PCM: `Datagrams transmitted: 0`, and a receiver on the
/// same reflector heard no stream. Found on 2026-08-20, when an attempt to
/// settle the app's `BU-8` with two CLI instances keyed up twice and put
/// nothing on the air.
///
/// That is worse than a wrong message. `--no-audio` is the mode an *unattended*
/// on-air test runs in — nobody is there to talk into a microphone — so the one
/// job it has is to produce carrier without needing hardware.
///
/// ### What it produces
///
/// The same shape the microphone tap produces, and nothing cleverer:
/// ``AudioPipeline/captureFrameSize`` samples of zero, every 20 ms. Silence
/// rather than a tone, because this stands in for an operator not talking, and
/// a tone left running by accident on a shared module is somebody else's
/// problem to listen to. The codecs encode it happily — µ-law has an exact zero
/// and Codec2 3200 encodes a silent frame like any other — so what goes on air
/// is a real stream with real framing, including the last frame that ends it.
///
/// ### Cadence
///
/// Runs continuously once started, exactly as capture does, for the same
/// reason: the client drops frames while unkeyed, and starting a source on the
/// key-down would put the first frames of every over out late. The interval is
/// wall-clock rather than a frame counter — this is a stand-in for a device
/// that ticks in real time, and drift against the client's own timestamps is
/// the thing to avoid.
struct SilentCaptureSource {

    /// One frame of it: 160 samples of zero, matching the tap's frame size.
    static let frame = [Int16](repeating: 0, count: AudioPipeline.captureFrameSize)

    /// 20 ms, the duration of one frame at 8 kHz.
    static let interval = Duration.milliseconds(20)

    /// Starts producing frames, and keeps going until the task is cancelled.
    ///
    /// - Parameters:
    ///   - onFrame: called once per frame, off the audio hardware entirely.
    ///   - limit: stop after this many frames. `nil` runs until cancelled; a
    ///     count is what makes this testable without waiting on a clock.
    /// - Returns: the task doing the producing. Cancel it to stop.
    @discardableResult
    static func start(
        limit: Int? = nil,
        onFrame: @escaping @Sendable ([Int16]) -> Void
    ) -> Task<Void, Never> {
        Task {
            var produced = 0
            while !Task.isCancelled, limit.map({ produced < $0 }) ?? true {
                onFrame(frame)
                produced += 1
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return  // Cancelled mid-sleep.
                }
            }
        }
    }
}
