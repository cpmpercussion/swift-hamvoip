// SPDX-License-Identifier: Apache-2.0

import TestSupport
import XCTest
@testable import RadioCore

/// Records `onExpiry` calls and lets tests await a specific count without
/// resorting to real-time sleeps.
private actor ExpiryRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }

    func waitUntilCount(_ target: Int, maxAttempts: Int = 100_000) async -> Bool {
        for _ in 0..<maxAttempts {
            if count >= target { return true }
            await Task.yield()
        }
        return count >= target
    }
}

final class TransmitWatchdogTests: XCTestCase {
    func testDefaultTimeoutIsOneHundredEightySeconds() {
        XCTAssertEqual(TransmitWatchdog.defaultTimeout, .seconds(180))
    }

    func testExpiryFiresExactlyOnceAfterTimeoutElapses() async {
        let clock = ManualTestClock()
        let watchdog = TransmitWatchdog(clock: clock)
        let recorder = ExpiryRecorder()

        await watchdog.start(timeout: .seconds(10)) { await recorder.record() }

        let sawFirstSleep = await clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(sawFirstSleep, "timer task never reached its sleep call")

        var isRunning = await watchdog.isRunning
        XCTAssertTrue(isRunning)
        var count = await recorder.count
        XCTAssertEqual(count, 0)

        clock.advance(by: .seconds(10))
        let fired = await recorder.waitUntilCount(1)
        XCTAssertTrue(fired, "onExpiry never fired after the deadline elapsed")

        count = await recorder.count
        XCTAssertEqual(count, 1, "onExpiry should fire exactly once")
        isRunning = await watchdog.isRunning
        XCTAssertFalse(isRunning, "watchdog should be idle after firing")

        // Advancing further must not cause a second firing.
        clock.advance(by: .seconds(1000))
        // Give any (incorrect) re-fire a fair chance to happen before asserting.
        for _ in 0..<50 { await Task.yield() }
        count = await recorder.count
        XCTAssertEqual(count, 1, "onExpiry must not fire more than once")
    }

    func testCancelBeforeDeadlinePreventsExpiryEntirely() async {
        let clock = ManualTestClock()
        let watchdog = TransmitWatchdog(clock: clock)
        let recorder = ExpiryRecorder()

        await watchdog.start(timeout: .seconds(5)) { await recorder.record() }
        await watchdog.cancel()

        let isRunning = await watchdog.isRunning
        XCTAssertFalse(isRunning)

        // Even if the deadline is later "reached" on the clock, expiry must
        // never fire because cancel() beat it.
        clock.advance(by: .seconds(1000))
        for _ in 0..<50 { await Task.yield() }

        let count = await recorder.count
        XCTAssertEqual(count, 0, "cancel() before the deadline must prevent onExpiry entirely")
    }

    func testCancelAfterExpiryIsHarmless() async {
        let clock = ManualTestClock()
        let watchdog = TransmitWatchdog(clock: clock)
        let recorder = ExpiryRecorder()

        await watchdog.start(timeout: .seconds(1)) { await recorder.record() }
        let sawFirstSleep = await clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(sawFirstSleep)

        clock.advance(by: .seconds(1))
        let fired = await recorder.waitUntilCount(1)
        XCTAssertTrue(fired)

        // Should not crash, throw, or change anything.
        await watchdog.cancel()

        let isRunning = await watchdog.isRunning
        XCTAssertFalse(isRunning)
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testRestartingResetsTheDeadlineRatherThanStackingTimers() async {
        let clock = ManualTestClock()
        let watchdog = TransmitWatchdog(clock: clock)
        let recorder = ExpiryRecorder()

        // First arm: deadline at t = 10.
        await watchdog.start(timeout: .seconds(10)) { await recorder.record() }
        var sawSleep = await clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(sawSleep)

        // Let some, but not all, of the original window elapse.
        clock.advance(by: .seconds(4))
        for _ in 0..<50 { await Task.yield() }
        var count = await recorder.count
        XCTAssertEqual(count, 0)

        // Restart at t = 4 with a fresh 10 s timeout: new deadline at t = 14.
        await watchdog.start(timeout: .seconds(10)) { await recorder.record() }
        sawSleep = await clock.waitUntilSleeping(count: 2)
        XCTAssertTrue(sawSleep, "restart never reached its own sleep call")

        let isRunning = await watchdog.isRunning
        XCTAssertTrue(isRunning)

        // Advance to t = 10: past the ORIGINAL deadline, but not the new one.
        clock.advance(by: .seconds(6))
        for _ in 0..<50 { await Task.yield() }
        count = await recorder.count
        XCTAssertEqual(count, 0, "restart must have cancelled the original deadline")

        // Advance to t = 14: past the new deadline. Exactly one firing.
        clock.advance(by: .seconds(4))
        let fired = await recorder.waitUntilCount(1)
        XCTAssertTrue(fired)
        count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testIsRunningTransitionsAcrossStartCancelAndExpiry() async {
        let clock = ManualTestClock()
        let watchdog = TransmitWatchdog(clock: clock)
        let recorder = ExpiryRecorder()

        var isRunning = await watchdog.isRunning
        XCTAssertFalse(isRunning, "idle before the first start")

        await watchdog.start(timeout: .seconds(5)) { await recorder.record() }
        isRunning = await watchdog.isRunning
        XCTAssertTrue(isRunning, "running immediately after start")

        await watchdog.cancel()
        isRunning = await watchdog.isRunning
        XCTAssertFalse(isRunning, "idle immediately after cancel")

        await watchdog.start(timeout: .seconds(3)) { await recorder.record() }
        let sawSleep = await clock.waitUntilSleeping(count: 2)
        XCTAssertTrue(sawSleep)
        isRunning = await watchdog.isRunning
        XCTAssertTrue(isRunning, "running again after restart")

        clock.advance(by: .seconds(3))
        let fired = await recorder.waitUntilCount(1)
        XCTAssertTrue(fired)
        isRunning = await watchdog.isRunning
        XCTAssertFalse(isRunning, "idle again once expiry has fired")
    }

    // MARK: - Token-based cancel (`cancel(ifCurrent:)`)

    /// The ordinary case: a token cancel disarms the very deadline `start()`
    /// handed it back, exactly like the unconditional `cancel()`.
    func testTokenCancelDisarmsTheDeadlineItArmed() async {
        let clock = ManualTestClock()
        let watchdog = TransmitWatchdog(clock: clock)
        let recorder = ExpiryRecorder()

        let armed = await watchdog.start(timeout: .seconds(5)) { await recorder.record() }
        await watchdog.cancel(ifCurrent: armed)

        let isRunning = await watchdog.isRunning
        XCTAssertFalse(isRunning, "a token cancel for the live generation must disarm it")

        clock.advance(by: .seconds(1000))
        for _ in 0..<50 { await Task.yield() }
        let count = await recorder.count
        XCTAssertEqual(count, 0, "the cancelled deadline must never fire")
    }

    /// The race `IAX2Client.startTransmit()` needs this for: a caller holding
    /// a stale token — because a second `start()` has already re-armed the
    /// watchdog since — must not be able to tear down that newer deadline.
    /// `cancel(ifCurrent:)` is a no-op here, and in particular must not bump
    /// the internal generation counter, or a *third*, still-pending token
    /// cancel for the current generation would then also wrongly no-op.
    func testTokenCancelIsANoOpAfterANewerStart() async {
        let clock = ManualTestClock()
        let watchdog = TransmitWatchdog(clock: clock)
        let recorder = ExpiryRecorder()

        let stale = await watchdog.start(timeout: .seconds(5)) { await recorder.record() }
        let current = await watchdog.start(timeout: .seconds(5)) { await recorder.record() }
        XCTAssertNotEqual(stale, current, "the second start must mint a fresh generation")

        // The stale token must not touch the watchdog the second start armed.
        await watchdog.cancel(ifCurrent: stale)
        var isRunning = await watchdog.isRunning
        XCTAssertTrue(isRunning, "a stale token cancel must not disarm the current deadline")

        // Nor must it have consumed the current generation: a cancel for the
        // token the winner actually holds still works afterwards.
        await watchdog.cancel(ifCurrent: current)
        isRunning = await watchdog.isRunning
        XCTAssertFalse(isRunning, "the current token must still be able to disarm its own deadline")
    }

    /// The unconditional `cancel()` is untouched by any of this: it always
    /// wins, token or no token, because it is what a caller reaches for when
    /// it *does* know — from its own state — that whatever is armed needs to
    /// come down regardless of which generation armed it.
    func testUnconditionalCancelStillWinsOverAnyGeneration() async {
        let clock = ManualTestClock()
        let watchdog = TransmitWatchdog(clock: clock)
        let recorder = ExpiryRecorder()

        _ = await watchdog.start(timeout: .seconds(5)) { await recorder.record() }
        _ = await watchdog.start(timeout: .seconds(5)) { await recorder.record() }
        await watchdog.cancel()

        let isRunning = await watchdog.isRunning
        XCTAssertFalse(isRunning, "unconditional cancel disarms the live deadline regardless of generation")

        clock.advance(by: .seconds(1000))
        for _ in 0..<50 { await Task.yield() }
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }
}
