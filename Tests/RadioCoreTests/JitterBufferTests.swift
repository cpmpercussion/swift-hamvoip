// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import RadioCore

// MARK: - Scripting helpers

/// One step of a jitter-buffer script. Everything the buffer knows about time
/// is supplied here, so each case is fully deterministic.
private enum Step: Equatable {
    /// Push a frame whose payload is derived from its timestamp.
    case push(UInt32)
    /// Push a frame with an explicit payload (to tell duplicates apart).
    case pushPayload(UInt32, [UInt8])
    /// Pop once and expect exactly this output.
    case expect(JitterOutput)
}

/// Deterministic payload for a timestamp, so `.frame` assertions identify
/// *which* frame came out.
private func payload(_ timestamp: UInt32) -> [UInt8] {
    [UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff)]
}

private func frame(_ timestamp: UInt32) -> JitterOutput {
    .frame(payload(timestamp))
}

private struct Case {
    let name: String
    let steps: [Step]
    var frameDuration: Duration = .milliseconds(20)
    var targetDepth: Duration = .milliseconds(60)
}

private func runScript(_ testCase: Case, file: StaticString = #filePath, line: UInt = #line) {
    var buffer = JitterBuffer(
        frameDuration: testCase.frameDuration,
        targetDepth: testCase.targetDepth
    )
    var popIndex = 0
    for (stepIndex, step) in testCase.steps.enumerated() {
        switch step {
        case .push(let timestamp):
            buffer.push(TimedFrame(timestamp: timestamp, payload: payload(timestamp)))
        case .pushPayload(let timestamp, let bytes):
            buffer.push(TimedFrame(timestamp: timestamp, payload: bytes))
        case .expect(let expected):
            let actual = buffer.pop()
            XCTAssertEqual(
                actual,
                expected,
                "\(testCase.name): pop #\(popIndex) (step \(stepIndex)) expected \(expected), got \(actual)",
                file: file,
                line: line
            )
            popIndex += 1
        }
    }
}

// MARK: - RC-3: fixed-depth behaviour

final class JitterBufferPlayoutTests: XCTestCase {
    func testScriptedSequences() {
        let cases: [Case] = [
            Case(
                name: "in-order stream plays out in order then starves",
                steps: [
                    .push(1000), .push(1020), .push(1040), .push(1060), .push(1080),
                    .expect(frame(1000)),
                    .expect(frame(1020)),
                    .expect(frame(1040)),
                    .expect(frame(1060)),
                    .expect(frame(1080)),
                    .expect(.silence),
                ]
            ),
            Case(
                name: "arbitrary starting timestamp is fine",
                steps: [
                    .push(0xDEAD_0000), .push(0xDEAD_0014), .push(0xDEAD_0028),
                    .expect(frame(0xDEAD_0000)),
                    .expect(frame(0xDEAD_0014)),
                    .expect(frame(0xDEAD_0028)),
                ]
            ),
            Case(
                name: "frames reordered within the window are sorted by timestamp",
                steps: [
                    .push(1000), .push(1040), .push(1020),
                    .expect(frame(1000)),
                    .expect(frame(1020)),
                    .expect(frame(1040)),
                ]
            ),
            Case(
                name: "out-of-order frame still ahead of the playout point is recovered",
                steps: [
                    .push(1000), .push(1020), .push(1060),
                    .expect(frame(1000)),
                    .push(1040), // arrives late in wall-clock, but its slot is unplayed
                    .expect(frame(1020)),
                    .expect(frame(1040)),
                    .expect(frame(1060)),
                ]
            ),
            Case(
                name: "duplicate timestamps keep the first copy",
                steps: [
                    .pushPayload(1000, [0x01]),
                    .pushPayload(1020, [0xAA]),
                    .pushPayload(1020, [0xBB]),
                    .pushPayload(1020, [0xCC]),
                    .pushPayload(1040, [0x03]),
                    .expect(.frame([0x01])),
                    .expect(.frame([0xAA])),
                    .expect(.frame([0x03])),
                    .expect(.silence),
                ]
            ),
            Case(
                name: "late frame whose slot was already popped is dropped",
                steps: [
                    .push(1000), .push(1020), .push(1040),
                    .expect(frame(1000)),
                    .pushPayload(1000, [0xFF]), // late duplicate of a played slot
                    .expect(frame(1020)),
                    .expect(frame(1040)),
                    .expect(.silence), // the late frame never resurfaces
                ]
            ),
            Case(
                name: "single loss yields exactly one concealment",
                steps: [
                    .push(1000), .push(1020), .push(1060), // 1040 lost
                    .expect(frame(1000)),
                    .expect(frame(1020)),
                    .expect(.concealment),
                    .expect(frame(1060)),
                ]
            ),
            Case(
                name: "burst loss yields one concealment per lost slot",
                steps: [
                    .push(1000), .push(1020), .push(1100), // 1040, 1060, 1080 lost
                    .expect(frame(1000)),
                    .expect(frame(1020)),
                    .expect(.concealment),
                    .expect(.concealment),
                    .expect(.concealment),
                    .expect(frame(1100)),
                ]
            ),
            Case(
                name: "starvation yields silence, not concealment",
                steps: [
                    .push(1000), .push(1020), .push(1040),
                    .expect(frame(1000)),
                    .expect(frame(1020)),
                    .expect(frame(1040)),
                    .expect(.silence),
                    .expect(.silence),
                    .expect(.silence),
                ]
            ),
            Case(
                name: "priming: pops before the target depth is reached are silence",
                steps: [
                    .push(1000),
                    .expect(.silence),
                    .push(1020),
                    .expect(.silence),
                    .push(1040), // 3 x 20 ms == 60 ms target
                    .expect(frame(1000)),
                    .expect(frame(1020)),
                    .expect(frame(1040)),
                ]
            ),
            Case(
                name: "priming honours a deeper target depth",
                steps: [
                    .push(1000), .push(1020), .push(1040), .push(1060),
                    .expect(.silence), // 80 ms queued, 100 ms wanted
                    .push(1080),
                    .expect(frame(1000)),
                ],
                targetDepth: .milliseconds(100)
            ),
            Case(
                name: "re-priming after starvation re-anchors instead of concealing the gap",
                steps: [
                    .push(1000), .push(1020), .push(1040),
                    .expect(frame(1000)),
                    .expect(frame(1020)),
                    .expect(frame(1040)),
                    .expect(.silence),
                    .push(5000), .push(5020), .push(5040),
                    .expect(frame(5000)),
                    .expect(frame(5020)),
                    .expect(frame(5040)),
                ]
            ),
            Case(
                name: "frames arriving during playout keep the stream running",
                steps: [
                    .push(1000), .push(1020), .push(1040),
                    .expect(frame(1000)),
                    .push(1060),
                    .expect(frame(1020)),
                    .push(1080),
                    .expect(frame(1040)),
                    .expect(frame(1060)),
                    .expect(frame(1080)),
                    .expect(.silence),
                ]
            ),
            Case(
                name: "40 ms frames use the same grid",
                steps: [
                    .push(2000), .push(2040), .push(2120), // 2080 lost
                    .expect(frame(2000)),
                    .expect(frame(2040)),
                    .expect(.concealment),
                    .expect(frame(2120)),
                ],
                frameDuration: .milliseconds(40),
                targetDepth: .milliseconds(120)
            ),
        ]

        for testCase in cases {
            runScript(testCase)
        }
    }

    func testDepthAndPrimingState() {
        var buffer = JitterBuffer()
        XCTAssertEqual(buffer.depth, .zero)
        XCTAssertFalse(buffer.isPrimed)

        buffer.push(TimedFrame(timestamp: 100, payload: payload(100)))
        buffer.push(TimedFrame(timestamp: 120, payload: payload(120)))
        XCTAssertEqual(buffer.depth, .milliseconds(40))
        XCTAssertEqual(buffer.pop(), .silence)
        XCTAssertFalse(buffer.isPrimed)

        buffer.push(TimedFrame(timestamp: 140, payload: payload(140)))
        XCTAssertEqual(buffer.depth, .milliseconds(60))
        XCTAssertEqual(buffer.pop(), frame(100))
        XCTAssertTrue(buffer.isPrimed)
        XCTAssertEqual(buffer.depth, .milliseconds(40))
        XCTAssertEqual(buffer.nextExpectedTimestamp, 120)
    }
}

// MARK: - RC-4: adaptive depth

final class JitterBufferAdaptationTests: XCTestCase {
    private let frameMillis: UInt32 = 20

    /// Push `count` frames whose timestamps sit on a perfect 20 ms grid but
    /// whose arrivals are displaced by `jitter(i)` milliseconds.
    private func pushStream(
        into buffer: inout JitterBuffer,
        count: Int,
        startTimestamp: UInt32,
        startArrivalMillis: Int,
        jitter: (Int) -> Int
    ) {
        for i in 0..<count {
            let timestamp = startTimestamp + UInt32(i) * frameMillis
            let arrival = startArrivalMillis + i * Int(frameMillis) + jitter(i)
            buffer.push(
                TimedFrame(timestamp: timestamp, payload: payload(timestamp)),
                arrivedAt: .milliseconds(arrival)
            )
        }
    }

    /// Drain everything queued, then pop far enough into silence to cross a
    /// talk-spurt boundary. Returns every output produced.
    @discardableResult
    private func drainThroughTalkSpurtBoundary(
        _ buffer: inout JitterBuffer,
        extraSilencePops: Int = 12
    ) -> [JitterOutput] {
        var outputs: [JitterOutput] = []
        while buffer.queuedFrameCount > 0 {
            outputs.append(buffer.pop())
        }
        for _ in 0..<extraSilencePops {
            outputs.append(buffer.pop())
        }
        return outputs
    }

    func testTargetDepthGrowsUnderJitteryArrivals() {
        var buffer = JitterBuffer()
        XCTAssertEqual(buffer.currentTargetDepth, .milliseconds(60))

        // Alternating +0 / +30 ms displacement: every successive gap is off the
        // sender's 20 ms by 30 ms in one direction or the other, so |D| = 30.
        pushStream(into: &buffer, count: 60, startTimestamp: 1000, startArrivalMillis: 0) {
            $0.isMultiple(of: 2) ? 0 : 30
        }
        drainThroughTalkSpurtBoundary(&buffer)

        XCTAssertGreaterThan(buffer.currentTargetDepth, .milliseconds(60))
        XCTAssertLessThanOrEqual(buffer.currentTargetDepth, .milliseconds(200))
        // deviation ≈ 30 ms, k = 4 → ≈ 120 ms.
        XCTAssertEqual(buffer.arrivalDeviation, .milliseconds(30), accuracy: .milliseconds(1))
        XCTAssertEqual(buffer.currentTargetDepth, .milliseconds(120), accuracy: .milliseconds(4))
    }

    func testTargetDepthSaturatesAtMaxDepth() {
        var buffer = JitterBuffer()
        // Violent jitter: |D| alternates 120 / 80 ms → k·deviation well past 200.
        pushStream(into: &buffer, count: 60, startTimestamp: 1000, startArrivalMillis: 0) {
            $0.isMultiple(of: 2) ? 0 : 100
        }
        drainThroughTalkSpurtBoundary(&buffer)
        XCTAssertEqual(buffer.currentTargetDepth, .milliseconds(200))
    }

    func testTargetDepthShrinksBackUnderSteadyArrivals() {
        var buffer = JitterBuffer()

        pushStream(into: &buffer, count: 60, startTimestamp: 1000, startArrivalMillis: 0) {
            $0.isMultiple(of: 2) ? 0 : 100
        }
        drainThroughTalkSpurtBoundary(&buffer)
        XCTAssertEqual(buffer.currentTargetDepth, .milliseconds(200))

        // Second spurt, perfectly paced: deviation decays back to ~0 and the
        // target returns to the floor.
        pushStream(into: &buffer, count: 200, startTimestamp: 100_000, startArrivalMillis: 100_000) { _ in 0 }
        drainThroughTalkSpurtBoundary(&buffer)

        XCTAssertLessThan(buffer.arrivalDeviation, .milliseconds(1))
        XCTAssertEqual(buffer.currentTargetDepth, .milliseconds(60))
    }

    func testTargetDepthAlwaysStaysWithinBounds() {
        var buffer = JitterBuffer()
        // A deterministic pseudo-random arrival pattern spanning steady,
        // jittery, bursty and gap-ridden stretches.
        var seed: UInt64 = 0x5EED_1234
        func nextJitter(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }

        var timestamp: UInt32 = 4000
        var arrival = 0
        for spurt in 0..<8 {
            let bound = [1, 5, 60, 200, 15, 400, 2, 90][spurt]
            for _ in 0..<40 {
                buffer.push(
                    TimedFrame(timestamp: timestamp, payload: payload(timestamp)),
                    arrivedAt: .milliseconds(arrival + nextJitter(bound))
                )
                timestamp += frameMillis
                arrival += Int(frameMillis)

                XCTAssertGreaterThanOrEqual(buffer.currentTargetDepth, .milliseconds(60))
                XCTAssertLessThanOrEqual(buffer.currentTargetDepth, .milliseconds(200))
            }
            while buffer.queuedFrameCount > 0 {
                _ = buffer.pop()
                XCTAssertGreaterThanOrEqual(buffer.currentTargetDepth, .milliseconds(60))
                XCTAssertLessThanOrEqual(buffer.currentTargetDepth, .milliseconds(200))
            }
            for _ in 0..<20 {
                _ = buffer.pop()
                XCTAssertGreaterThanOrEqual(buffer.currentTargetDepth, .milliseconds(60))
                XCTAssertLessThanOrEqual(buffer.currentTargetDepth, .milliseconds(200))
            }
            // Gap between talk spurts.
            timestamp += 2000
            arrival += 2000
        }
    }

    func testTargetDepthNeverChangesMidTalkSpurt() {
        var buffer = JitterBuffer()
        let initialTarget = buffer.currentTargetDepth
        XCTAssertEqual(initialTarget, .milliseconds(60))

        // Jittery spurt: the estimator moves immediately, the applied target
        // must not — not while pushing, and not while playing out.
        pushStream(into: &buffer, count: 40, startTimestamp: 1000, startArrivalMillis: 0) {
            $0.isMultiple(of: 2) ? 0 : 100
        }
        XCTAssertGreaterThan(buffer.arrivalDeviation, .milliseconds(20))
        XCTAssertEqual(buffer.currentTargetDepth, initialTarget)

        while buffer.queuedFrameCount > 0 {
            let output = buffer.pop()
            XCTAssertNotEqual(output, .silence)
            XCTAssertEqual(
                buffer.currentTargetDepth,
                initialTarget,
                "target depth changed mid-spurt"
            )
        }

        // Now the spurt ends. 200 ms of continuous silence is 10 pops at 20 ms;
        // nothing may change before the tenth.
        for pop in 1...9 {
            XCTAssertEqual(buffer.pop(), .silence)
            XCTAssertEqual(
                buffer.currentTargetDepth,
                initialTarget,
                "target depth changed after only \(pop * 20) ms of silence"
            )
        }
        XCTAssertEqual(buffer.pop(), .silence)
        XCTAssertEqual(buffer.currentTargetDepth, .milliseconds(200))
    }

    func testConcealmentInterruptsTheSilenceRun() {
        var buffer = JitterBuffer()
        let initialTarget = buffer.currentTargetDepth

        pushStream(into: &buffer, count: 30, startTimestamp: 1000, startArrivalMillis: 0) {
            $0.isMultiple(of: 2) ? 0 : 100
        }
        // Drain, then a partial silence run, then a frame far in the future —
        // the silence run resets, so the depth stays put.
        while buffer.queuedFrameCount > 0 { _ = buffer.pop() }
        for _ in 0..<5 { XCTAssertEqual(buffer.pop(), .silence) }
        XCTAssertEqual(buffer.currentTargetDepth, initialTarget)

        pushStream(into: &buffer, count: 3, startTimestamp: 9000, startArrivalMillis: 9000) { _ in 0 }
        XCTAssertEqual(buffer.pop(), frame(9000))
        XCTAssertEqual(buffer.currentTargetDepth, initialTarget)

        for _ in 0..<2 { _ = buffer.pop() }
        for _ in 0..<9 { XCTAssertEqual(buffer.pop(), .silence) }
        XCTAssertEqual(buffer.currentTargetDepth, initialTarget)
        XCTAssertEqual(buffer.pop(), .silence)
        XCTAssertGreaterThan(buffer.currentTargetDepth, initialTarget)
    }

    func testDeeperTargetDepthRequiresMorePrimingAfterAdaptation() {
        var buffer = JitterBuffer()
        pushStream(into: &buffer, count: 60, startTimestamp: 1000, startArrivalMillis: 0) {
            $0.isMultiple(of: 2) ? 0 : 100
        }
        drainThroughTalkSpurtBoundary(&buffer)
        XCTAssertEqual(buffer.currentTargetDepth, .milliseconds(200))

        // 200 ms target == 10 frames of 20 ms before playout starts.
        for i in 0..<9 {
            let timestamp = 50_000 + UInt32(i) * 20
            buffer.push(
                TimedFrame(timestamp: timestamp, payload: payload(timestamp)),
                arrivedAt: .milliseconds(50_000 + i * 20)
            )
        }
        XCTAssertEqual(buffer.depth, .milliseconds(180))
        XCTAssertEqual(buffer.pop(), .silence)

        buffer.push(
            TimedFrame(timestamp: 50_180, payload: payload(50_180)),
            arrivedAt: .milliseconds(50_180)
        )
        XCTAssertEqual(buffer.depth, .milliseconds(200))
        XCTAssertEqual(buffer.pop(), frame(50_000))
    }

    func testPushWithoutArrivalTimeLeavesTheEstimatorAlone() {
        var buffer = JitterBuffer()
        for i in 0..<40 {
            let timestamp = 1000 + UInt32(i) * 20
            buffer.push(TimedFrame(timestamp: timestamp, payload: payload(timestamp)))
        }
        drainThroughTalkSpurtBoundary(&buffer)
        XCTAssertEqual(buffer.arrivalDeviation, .zero)
        XCTAssertEqual(buffer.currentTargetDepth, .milliseconds(60))
    }
}

// MARK: - RC-3/RC-4: recovery from bad timestamps and stream restarts

final class JitterBufferRecoveryTests: XCTestCase {
    /// Longest unbroken run of `.concealment` in `outputs`.
    private func longestConcealmentRun(_ outputs: [JitterOutput]) -> Int {
        var longest = 0
        var run = 0
        for output in outputs {
            if output == .concealment {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest
    }

    /// A single frame carrying a timestamp 65536 ms in the future — exactly
    /// what a mis-expanded 16-bit IAX2 mini-frame timestamp looks like (IAX-6)
    /// — must not turn into a minute of concealment. `.concealment` tells the
    /// caller to repeat or fade the last frame, so an unbounded run is a
    /// stuck-audio bug, not a graceful degradation.
    func testMisExpandedTimestampDoesNotCauseAnUnboundedConcealmentRun() {
        var buffer = JitterBuffer()
        let base: UInt32 = 1000
        for i in 0..<10 {
            var timestamp = base + UInt32(i) * 20
            if i == 5 { timestamp &+= 65_536 } // the 16-bit mis-expansion
            buffer.push(TimedFrame(timestamp: timestamp, payload: payload(timestamp)))
        }

        // 400 pops is 8 s of playout: far more than the stream is worth, and
        // far less than the 65 s the unbounded run produced.
        var outputs: [JitterOutput] = []
        for _ in 0..<400 { outputs.append(buffer.pop()) }

        let run = longestConcealmentRun(outputs)
        XCTAssertLessThanOrEqual(
            run,
            10,
            "one bad timestamp produced \(run) consecutive concealments (\(run * 20) ms of repeated audio)"
        )

        // The nine good frames still play, in order, before the outlier is hit.
        let played = outputs.compactMap { output -> [UInt8]? in
            if case .frame(let bytes) = output { return bytes }
            return nil
        }
        let expectedPlayed = [1000, 1020, 1040, 1060, 1080, 1120, 1140, 1160, 1180]
            .map { payload(UInt32($0)) }
        XCTAssertEqual(played, expectedPlayed)

        // Having hit the discontinuity the buffer un-primes and waits for a new
        // spurt to anchor on, rather than grinding through the gap.
        XCTAssertFalse(buffer.isPrimed)
    }

    /// A gap that is genuinely packet loss (well inside the discontinuity
    /// bound) must still be concealed slot by slot — the bound must not turn
    /// ordinary burst loss into silence.
    func testBurstLossJustInsideTheBoundIsStillConcealed() {
        var buffer = JitterBuffer()
        for timestamp: UInt32 in [1000, 1020, 1040] {
            buffer.push(TimedFrame(timestamp: timestamp, payload: payload(timestamp)))
        }
        // 1060...1240 lost: a 200 ms gap, the largest run still concealed.
        buffer.push(TimedFrame(timestamp: 1260, payload: payload(1260)))

        var outputs: [JitterOutput] = []
        for _ in 0..<14 { outputs.append(buffer.pop()) }

        XCTAssertEqual(outputs.prefix(3), [frame(1000), frame(1020), frame(1040)])
        XCTAssertEqual(Array(outputs[3..<13]), Array(repeating: .concealment, count: 10))
        XCTAssertEqual(outputs[13], frame(1260))
    }

    /// Reusing a buffer for a second call: the new stream's clock is unrelated
    /// to the old one's and typically starts lower. Starvation un-primes the
    /// buffer, and the documented contract is that it re-anchors on the new
    /// head — which it cannot do if `enqueue` is still rejecting frames as
    /// "late" against the dead stream's playout grid.
    func testStreamRestartAtALowerTimestampIsNotRejectedAsLate() {
        var buffer = JitterBuffer()
        for timestamp: UInt32 in [600_000, 600_020, 600_040] {
            buffer.push(TimedFrame(timestamp: timestamp, payload: payload(timestamp)))
        }
        XCTAssertEqual(buffer.pop(), frame(600_000))
        XCTAssertEqual(buffer.pop(), frame(600_020))
        XCTAssertEqual(buffer.pop(), frame(600_040))
        XCTAssertEqual(buffer.pop(), .silence) // starved: un-primes
        XCTAssertFalse(buffer.isPrimed)

        // New call on the same buffer, 30 s of audio starting at timestamp 0.
        for i in 0..<1500 {
            let timestamp = UInt32(i) * 20
            buffer.push(TimedFrame(timestamp: timestamp, payload: payload(timestamp)))
        }
        XCTAssertEqual(buffer.queuedFrameCount, 1500, "the new call's frames were dropped as late")

        XCTAssertEqual(buffer.pop(), frame(0))
        XCTAssertEqual(buffer.pop(), frame(20))
        XCTAssertEqual(buffer.pop(), frame(40))
    }

    /// The smaller version of the same defect: a short stream, then a restart
    /// at timestamp 0. Not one frame may be swallowed.
    func testShortStreamRestartLosesNoFrames() {
        var buffer = JitterBuffer()
        for timestamp: UInt32 in [1000, 1020, 1040] {
            buffer.push(TimedFrame(timestamp: timestamp, payload: payload(timestamp)))
        }
        for _ in 0..<3 { _ = buffer.pop() }
        XCTAssertEqual(buffer.pop(), .silence)

        for i in 0..<60 {
            let timestamp = UInt32(i) * 20
            buffer.push(TimedFrame(timestamp: timestamp, payload: payload(timestamp)))
        }
        XCTAssertEqual(buffer.queuedFrameCount, 60)
        XCTAssertEqual(buffer.pop(), frame(0), "the restarted stream's first frame was dropped")
    }

    /// `reset()` is how a caller reuses one buffer across calls deliberately
    /// (IAX-8 composes a single buffer per client): queued audio from the dead
    /// call is dropped, and nothing about its clock survives to reject or
    /// mis-anchor the next one.
    func testResetClearsQueueGridAndEstimator() {
        var buffer = JitterBuffer()
        for i in 0..<40 {
            let timestamp = 600_000 + UInt32(i) * 20
            buffer.push(
                TimedFrame(timestamp: timestamp, payload: payload(timestamp)),
                arrivedAt: .milliseconds(600_000 + i * 20 + (i.isMultiple(of: 2) ? 0 : 100))
            )
        }
        XCTAssertEqual(buffer.pop(), frame(600_000))
        XCTAssertTrue(buffer.isPrimed)
        XCTAssertEqual(buffer.nextExpectedTimestamp, 600_020)
        XCTAssertGreaterThan(buffer.queuedFrameCount, 0)
        XCTAssertGreaterThan(buffer.arrivalDeviation, .zero)

        buffer.reset()

        XCTAssertEqual(buffer.queuedFrameCount, 0, "reset must drop the dead call's audio")
        XCTAssertEqual(buffer.depth, .zero)
        XCTAssertFalse(buffer.isPrimed)
        XCTAssertNil(buffer.nextExpectedTimestamp)
        XCTAssertEqual(buffer.arrivalDeviation, .zero)
        XCTAssertEqual(buffer.currentTargetDepth, .milliseconds(60), "reset restores the initial target depth")
        XCTAssertEqual(buffer.pop(), .silence)
    }

    /// After `reset()` the buffer behaves exactly like a fresh one, including
    /// for a stream whose timestamps sit below the old call's.
    func testBufferIsFullyReusableAfterReset() {
        var buffer = JitterBuffer()
        for timestamp: UInt32 in [600_000, 600_020, 600_040, 600_060] {
            buffer.push(TimedFrame(timestamp: timestamp, payload: payload(timestamp)))
        }
        XCTAssertEqual(buffer.pop(), frame(600_000))

        buffer.reset()

        // Second call: primes from scratch, then plays from timestamp 0.
        buffer.push(TimedFrame(timestamp: 0, payload: payload(0)))
        buffer.push(TimedFrame(timestamp: 20, payload: payload(20)))
        XCTAssertEqual(buffer.pop(), .silence, "only 40 ms queued: still priming")
        buffer.push(TimedFrame(timestamp: 40, payload: payload(40)))
        XCTAssertEqual(buffer.pop(), frame(0))
        XCTAssertEqual(buffer.pop(), frame(20))
        XCTAssertEqual(buffer.pop(), frame(40))
        XCTAssertEqual(buffer.pop(), .silence)
    }

    /// The arrival estimator must survive a restart too: a new call's arrival
    /// clock and timestamps both start over, and if the estimator keeps
    /// comparing against the old stream's newest timestamp it never takes
    /// another sample and RC-4 adaptation dies for the life of the buffer.
    func testEstimatorResumesAfterAStreamRestart() {
        var buffer = JitterBuffer()
        for i in 0..<40 {
            let timestamp = 600_000 + UInt32(i) * 20
            buffer.push(
                TimedFrame(timestamp: timestamp, payload: payload(timestamp)),
                arrivedAt: .milliseconds(600_000 + i * 20)
            )
        }
        while buffer.queuedFrameCount > 0 { _ = buffer.pop() }
        for _ in 0..<12 { _ = buffer.pop() }
        XCTAssertEqual(buffer.arrivalDeviation, .zero, "steady arrivals: deviation should be ~0")

        // New call: timestamps restart at 0, arrivals badly jittered.
        for i in 0..<40 {
            let timestamp = UInt32(i) * 20
            let jitter = i.isMultiple(of: 2) ? 0 : 30
            buffer.push(
                TimedFrame(timestamp: timestamp, payload: payload(timestamp)),
                arrivedAt: .milliseconds(i * 20 + jitter)
            )
        }
        XCTAssertGreaterThan(
            buffer.arrivalDeviation,
            .milliseconds(20),
            "the estimator never took another sample after the stream restarted"
        )
    }
}

// MARK: - Duration assertion helper

private func XCTAssertEqual(
    _ actual: Duration,
    _ expected: Duration,
    accuracy: Duration,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let difference = actual > expected ? actual - expected : expected - actual
    XCTAssertLessThanOrEqual(
        difference,
        accuracy,
        "\(actual) is not within \(accuracy) of \(expected)",
        file: file,
        line: line
    )
}
