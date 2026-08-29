// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import XCTest

@testable import RadioCore

/// RC-16 — `AudioPipeline` must hold no lock across a call into AVFAudio.
///
/// The fault these come from killed Currawong on air on 2026-08-29, and killed
/// it in the worst way available: the process stayed up, kept its window, and
/// never responded again, with a dead audio pipeline and nothing to tell the
/// operator the radio had stopped. `installTap` raised an Objective-C
/// `NSException`; **a Swift `defer` does not run when an ObjC exception unwinds
/// through it**; the pipeline's `NSLock` was released by exactly such a
/// `defer`. Three threads then waited on a lock nobody held — the PTT release
/// in `stop()`, received audio in `enqueuePlayback`, and the RC-14 rebuild on
/// the engine queue — and two samples six minutes apart were identical.
///
/// **What can and cannot be tested here.** Not the raise: an `NSException` no
/// `catch` can intercept would take the test runner down, which is the
/// complaint rather than a test of it. What *is* testable is the property that
/// makes a raise survivable, and it is a property of ordinary runs too — that
/// while the pipeline is inside `installTap`, the rest of it still answers. A
/// fake host calls back into the pipeline from another thread from inside its
/// own install; every one of these tests fails by timing out against the code
/// as it was.
///
/// The timeouts are what make a regression a failure rather than a hung suite.
final class AudioPipelineLockTests: XCTestCase {
    /// How long a call that must not block is given before it is called blocked.
    /// Generous: the calls under test take microseconds when they are correct,
    /// and the only thing a larger number costs is the time a genuine
    /// regression takes to fail.
    private static let responseTimeout: TimeInterval = 2

    // MARK: A host that calls back from inside the install

    /// A tap host that runs a closure from inside ``installTap``, i.e. at the
    /// exact point the real one can raise.
    private final class ReentrantTapHost: CaptureTapHost {
        private let rate: Double
        /// Run from inside `installTap`, on the installing thread.
        var duringInstall: (() -> Void)?
        private(set) var installs = 0
        private(set) var removals = 0

        init(rate: Double = 48_000) {
            self.rate = rate
        }

        private func makeFormat() -> AVAudioFormat {
            // Force-unwrapped deliberately: mono Float32 at a plausible device
            // rate is not a format CoreAudio declines, and a `nil` here would
            // mean the test harness itself is broken.
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        }

        var currentInputFormat: AVAudioFormat { makeFormat() }
        var hardwareInputFormat: AVAudioFormat { makeFormat() }

        func installTap(bufferSize: AVAudioFrameCount, body: @escaping (AVAudioPCMBuffer) -> Void) {
            installs += 1
            duringInstall?()
        }

        func removeTap() { removals += 1 }
        func reloadInputFormat() {}
    }

    /// Runs `work` on another thread and returns whether it finished within
    /// ``responseTimeout``. `false` is the deadlock.
    private func completes(within timeout: TimeInterval = responseTimeout, _ work: @escaping () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    // MARK: The lock is not held across the install

    /// **The test that matters.** It encodes "no AVFAudio call under the state
    /// lock" as behaviour rather than as a comment, which is what stops this
    /// coming back a third time.
    func testTheStateLockIsFreeWhileTheTapIsBeingInstalled() {
        let pipeline = AudioPipeline()
        let host = ReentrantTapHost()
        pipeline.replaceTapHostForTesting(host)

        var counterAnswered = false
        host.duringInstall = { [unowned pipeline] in
            counterAnswered = self.completes {
                // Any lock-taking reader will do; this one is the counter a
                // caller checks after a transmission, and it was one of the
                // calls that could never return again.
                _ = pipeline.droppedCaptureFrameCount
            }
        }

        // The install may or may not get as far as a running engine on a
        // headless machine, and that is not what is under test.
        try? pipeline.startCapture { _ in }
        pipeline.stop()

        XCTAssertEqual(host.installs, 1, "the install must actually have been reached")
        XCTAssertTrue(
            counterAnswered,
            "the state lock was held across installTap — which is the deadlock: a raise from "
                + "inside that call would orphan it for the life of the process"
        )
    }

    func testStopIsNotBlockedByAnInstallInProgress() {
        let pipeline = AudioPipeline()
        let host = ReentrantTapHost()
        pipeline.replaceTapHostForTesting(host)

        var stopped = false
        host.duringInstall = { [unowned pipeline] in
            // The PTT *release* arriving while the press is still installing:
            // the exact pair of threads in the report.
            stopped = self.completes { pipeline.stop() }
        }

        try? pipeline.startCapture { _ in }
        pipeline.stop()

        XCTAssertTrue(stopped, "stop() waited on the lock the install was holding")
    }

    func testPlaybackDoesNotBlockOnAnInstallInProgress() {
        let pipeline = AudioPipeline()
        let host = ReentrantTapHost()
        pipeline.replaceTapHostForTesting(host)

        var playbackReturned = false
        host.duringInstall = { [unowned pipeline] in
            // Received audio goes on arriving while the operator keys up. It
            // may lose this frame — the engine is genuinely busy, and one
            // dropped 20 ms frame is the cheap outcome — but it must come back.
            playbackReturned = self.completes { pipeline.enqueuePlayback([Int16](repeating: 0, count: 160)) }
        }

        try? pipeline.startCapture { _ in }
        pipeline.stop()

        XCTAssertTrue(playbackReturned, "the receive path blocked behind the transmit path")
    }

    // MARK: The install claim

    func testASecondInstallDuringOneInFlightIsRefusedRatherThanRaced() {
        let pipeline = AudioPipeline()
        let host = ReentrantTapHost()
        pipeline.replaceTapHostForTesting(host)

        var reentrant: Error?
        host.duringInstall = { [unowned pipeline] in
            _ = self.completes {
                do {
                    try pipeline.startCapture { _ in }
                } catch {
                    reentrant = error
                }
            }
        }

        try? pipeline.startCapture { _ in }
        pipeline.stop()

        XCTAssertEqual(
            reentrant as? AudioPipelineError, .captureInstallInProgress,
            "two installs over one bus is a hard error in AVAudioEngine, so the second is told "
                + "so — and told, rather than made to wait behind the first"
        )
        XCTAssertEqual(host.installs, 1)
    }

    /// The state a raise leaves behind: a claim nothing released, because
    /// nothing runs on that path. Everything must still answer, and the failure
    /// a caller sees must be a `throw` rather than a wait.
    func testAnOrphanedClaimFailsInstallsInsteadOfBlockingThem() {
        let pipeline = AudioPipeline()
        pipeline.replaceTapHostForTesting(ReentrantTapHost())
        pipeline.orphanCaptureInstallClaimForTesting()

        var caught: Error?
        let answered = completes {
            do {
                try pipeline.startCapture { _ in }
            } catch {
                caught = error
            }
        }

        XCTAssertTrue(answered, "an unwound install must not make later ones wait for it")
        XCTAssertEqual(caught as? AudioPipelineError, .captureInstallInProgress)
        XCTAssertTrue(completes { _ = pipeline.droppedCaptureFrameCount })
        XCTAssertTrue(completes { pipeline.enqueuePlayback([Int16](repeating: 0, count: 160)) })
    }

    /// The other side of `stop()` not waiting for an install: the install must
    /// not commit over it. Before RC-16 the two could not interleave at all,
    /// because an install was one locked region; now they can, and a commit
    /// that ignored the stop would leave a live tap and a drain task feeding a
    /// caller who had already said stop.
    func testAnInstallThatIsStoppedMidwayCommitsNothing() {
        let pipeline = AudioPipeline()
        let host = ReentrantTapHost()
        pipeline.replaceTapHostForTesting(host)

        host.duringInstall = { [unowned pipeline] in
            _ = self.completes { pipeline.stop() }
        }

        var caught: Error?
        do {
            try pipeline.startCapture { _ in }
        } catch {
            caught = error
        }

        XCTAssertEqual(
            caught as? AudioPipelineError, .captureInstallSuperseded,
            "the caller asked for capture and did not get it, so it is told so"
        )
        XCTAssertGreaterThanOrEqual(
            host.removals, 1, "the tap installed for the abandoned session came back off the bus")
        XCTAssertEqual(pipeline.captureChainRebuildCount, 0)
    }

    /// `stop()` is the documented way back from an unwound install, and the one
    /// the app already takes: releasing PTT stops the pipeline.
    func testStopClearsAnOrphanedClaimSoCaptureCanStartAgain() {
        let pipeline = AudioPipeline()
        let host = ReentrantTapHost()
        pipeline.replaceTapHostForTesting(host)
        pipeline.orphanCaptureInstallClaimForTesting()

        pipeline.stop()

        // Whether the engine starts on this machine is not the point; whether
        // the install was *attempted* is.
        try? pipeline.startCapture { _ in }
        pipeline.stop()

        XCTAssertEqual(host.installs, 1, "the claim survived stop(), so capture was dead for good")
    }
}
