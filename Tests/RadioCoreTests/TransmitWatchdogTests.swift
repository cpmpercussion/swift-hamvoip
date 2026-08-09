// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import RadioCore

/// A manually-driven `Clock` for deterministic watchdog tests: `advance(by:)`
/// moves time forward and resumes any sleepers whose deadline has been
/// reached. Nothing here touches the wall clock, so these tests never wait
/// in real time and never race against it.
///
/// Because the watchdog's internal timer task is spawned independently of
/// the calling test task, the test needs a way to know the timer task has
/// actually reached its `sleep` call (and therefore captured its deadline
/// relative to the *current* `now`) before advancing time — otherwise the
/// deadline could be computed against an already-advanced clock. That's
/// what `waitUntilSleeping(count:)` is for: it polls a counter that the
/// clock bumps synchronously the moment `sleep(until:)` is entered,
/// yielding cooperatively rather than sleeping in real time.
private final class ManualTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        fileprivate var offset: Swift.Duration

        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        static func == (lhs: Instant, rhs: Instant) -> Bool { lhs.offset == rhs.offset }

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }
    }

    typealias Duration = Swift.Duration

    private struct Waiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var offset: Swift.Duration = .zero
    private var waiters: [UUID: Waiter] = [:]
    private var sleepCallCount = 0

    /// Synchronous scoped locking, isolated in one place so `NSLock`'s
    /// async-context restriction (a warning today, an error under strict
    /// Swift 6 concurrency checking) has a single call site.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var now: Instant {
        Instant(offset: withLock { offset })
    }

    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        // Count every call to `sleep`, even one that's cancelled before it
        // ever registers a waiter — otherwise a test that cancels a timer
        // before its task is scheduled would make `waitUntilSleeping` spin
        // forever waiting for a call that already happened but wasn't
        // counted.
        withLock { sleepCallCount += 1 }

        if Task.isCancelled { throw CancellationError() }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyDue: Bool = withLock {
                    if offset >= deadline.offset { return true }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return false
                }
                if alreadyDue { continuation.resume() }
            }
        } onCancel: {
            let waiter = withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Advances virtual time and resumes every sleeper whose deadline has
    /// now been reached (or passed).
    func advance(by duration: Swift.Duration) {
        let ready: [Waiter] = withLock {
            offset += duration
            let due = waiters.filter { $0.value.deadline.offset <= offset }
            for key in due.keys { waiters.removeValue(forKey: key) }
            return Array(due.values)
        }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    /// Polls (via cooperative yielding, never real time) until `sleep` has
    /// been entered at least `count` times in total. Returns `false` if it
    /// never happens within a generous, purely-scheduling-bound number of
    /// attempts — which would indicate a real bug, not slowness.
    func waitUntilSleeping(count: Int, maxAttempts: Int = 100_000) async -> Bool {
        for _ in 0..<maxAttempts {
            let current = withLock { sleepCallCount }
            if current >= count { return true }
            await Task.yield()
        }
        return false
    }
}

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
}
