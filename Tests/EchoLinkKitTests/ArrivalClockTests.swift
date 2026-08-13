// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import RadioCore

/// The stream clock across a sender's pause.
///
/// These are the tests a fixture cannot give you, because a fixture has no
/// arrival times — and the absence of arrival times is precisely what hid the
/// bug they cover. The timings here are taken from a live 65-second
/// `*ECHOTEST*` session: 339 packets, eleven silences of half a second or more,
/// and **one** sequence discontinuity between them.
final class ArrivalClockTests: XCTestCase {
    /// The trap, stated as a test: a sender that pauses without skipping
    /// sequence numbers.
    func testAPauseAdvancesTheStreamClockByRealTimeNotByOnePacket() {
        var expander = EchoLinkSequenceExpander()

        // Two packets, 80 ms apart, sequence 10 and 11.
        let first = expander.expand(10, arrivedAt: .milliseconds(0))
        let second = expander.expand(11, arrivedAt: .milliseconds(80))
        XCTAssertEqual(second.streamTime, first.streamTime + 80)

        // Four seconds of silence. The sender resumes with sequence 12 —
        // contiguous, because EchoLink senders do not skip across a pause.
        let afterPause = expander.expand(12, arrivedAt: .milliseconds(4080))

        XCTAssertTrue(afterPause.isNewTalkspurt,
                      "a wall-clock pause is a talkspurt boundary even when the "
                          + "sequence says otherwise")
        XCTAssertGreaterThanOrEqual(
            afterPause.streamTime, second.streamTime + 4000,
            "the stream clock must keep up with real time, or the jitter "
                + "buffer's grid runs away from it and it stops buffering")
    }

    func testOrdinaryBurstinessIsNotMistakenForAPause() {
        // A proxied path delivers a clump of two or three packets every
        // ~200 ms, constantly. Re-latching on that rhythm fights the jitter
        // buffer rather than helping it, and each spurious re-latch costs a
        // re-prime — audible as a short drop in otherwise clean audio.
        var expander = EchoLinkSequenceExpander()
        _ = expander.expand(0, arrivedAt: .milliseconds(0))
        let together = expander.expand(1, arrivedAt: .milliseconds(0))
        let after = expander.expand(2, arrivedAt: .milliseconds(200))

        XCTAssertFalse(together.isNewTalkspurt, "two packets in one clump")
        XCTAssertFalse(after.isNewTalkspurt, "a 200 ms gap is the rhythm, not a pause")
        XCTAssertEqual(after.streamTime, together.streamTime + 80,
                       "and audio time still advances one packet per packet")
    }

    func testTheThresholdSitsInTheMeasuredValleyBetweenBunchingAndSilence() {
        // Measured across two live sessions, the gaps are sharply bimodal with
        // nothing in between:
        //
        //     bunching   max 218 ms and 375 ms
        //     silences   min 806 ms and 582 ms
        //
        // The threshold has to separate them. An earlier 240 ms sat inside the
        // bunching range and re-latched on ordinary delivery.
        var expander = EchoLinkSequenceExpander()
        _ = expander.expand(0, arrivedAt: .milliseconds(0))

        // The largest gap ever observed that was still just bunching.
        let bunching = expander.expand(1, arrivedAt: .milliseconds(375))
        XCTAssertFalse(bunching.isNewTalkspurt,
                       "375 ms was measured as normal delivery, not a pause")

        var other = EchoLinkSequenceExpander()
        _ = other.expand(0, arrivedAt: .milliseconds(0))
        // The smallest gap ever observed that really was a silence.
        let silence = other.expand(1, arrivedAt: .milliseconds(582))
        XCTAssertTrue(silence.isNewTalkspurt,
                      "582 ms was measured as a real sender pause")
    }

    func testWithoutArrivalTimesTheClockIsSequenceOnly() {
        // The old behaviour, kept working for callers that have no clock —
        // and pinned so its limitation is visible rather than surprising.
        var expander = EchoLinkSequenceExpander()
        let first = expander.expand(10)
        let second = expander.expand(11)
        XCTAssertEqual(second.streamTime, first.streamTime + 80)
    }

    /// The live session's shape: contiguous sequence, real pauses.
    func testTheCapturedSessionShapeKeepsTheClockAlignedWithRealTime() {
        // Eleven silences, sequence never skipping — the exact pattern that
        // made the buffer stop buffering.
        var expander = EchoLinkSequenceExpander()
        var arrival = Duration.milliseconds(0)
        var sequence: UInt16 = 0
        var lastStreamTime: UInt32 = 0

        for spurt in 0 ..< 12 {
            if spurt > 0 {
                arrival += .milliseconds(3000)  // a silence
            }
            for _ in 0 ..< 20 {                 // then twenty packets of speech
                let expansion = expander.expand(sequence, arrivedAt: arrival)
                lastStreamTime = expansion.streamTime
                sequence &+= 1
                arrival += .milliseconds(80)
            }
        }

        // 12 spurts x 20 packets x 80 ms of audio, plus 11 x 3 s of silence.
        // Each step is its own typed constant: folding the arithmetic into one
        // `UInt32(...)` initialiser is enough to defeat the type-checker on
        // some toolchains, which is a CI failure rather than a local one.
        let audioMilliseconds: UInt32 = 12 * 20 * 80
        let silenceMilliseconds: UInt32 = 11 * 3000
        let realElapsed: UInt32 = audioMilliseconds + silenceMilliseconds

        XCTAssertGreaterThan(
            lastStreamTime, realElapsed - 2000,
            "the stream clock must track real time; a sequence-only clock "
                + "reaches only the audio duration and leaves the buffer "
                + "every silence behind")
    }
}
