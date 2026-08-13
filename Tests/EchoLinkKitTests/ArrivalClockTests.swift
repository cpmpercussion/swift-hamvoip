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
        // A proxied path delivers in bursts constantly — median gap zero, then
        // a couple of hundred milliseconds. Re-latching on that would fight the
        // jitter buffer rather than help it.
        var expander = EchoLinkSequenceExpander()
        _ = expander.expand(0, arrivedAt: .milliseconds(0))
        let together = expander.expand(1, arrivedAt: .milliseconds(0))
        let after = expander.expand(2, arrivedAt: .milliseconds(200))

        XCTAssertFalse(together.isNewTalkspurt, "two packets in one burst")
        XCTAssertFalse(after.isNewTalkspurt, "a 200 ms gap is bunching, not a pause")
        XCTAssertEqual(after.streamTime, together.streamTime + 80,
                       "and audio time still advances one packet per packet")
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
        let realElapsedMs = UInt32(12 * 20 * 80 + 11 * 3000)
        XCTAssertGreaterThan(
            lastStreamTime, realElapsedMs - 2000,
            "the stream clock tracked real time; a sequence-only clock would "
                + "have reached about \\(12 * 20 * 80) ms and left the buffer "
                + "33 seconds behind")
    }
}
