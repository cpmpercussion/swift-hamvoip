// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A manually-driven `Clock`, so timeout and backoff behaviour is exercised
/// without a single real-time wait.
///
/// Every component in this package that waits on time takes an injected clock
/// for exactly this reason (see `TransmitWatchdog`, `ReliableChannel`,
/// `M17ReflectorClient`). Tests advance virtual time with ``advance(by:)`` and
/// any sleeper whose deadline has passed resumes immediately.
///
/// ## Waiting for a timer to arm
///
/// The subtlety that makes or breaks determinism here: a timer task is spawned
/// independently of the test task, so the test must not advance time until the
/// timer has actually entered `sleep` and captured its deadline against the
/// *current* `now`. Advance too early and the deadline is computed against
/// already-advanced time, so the timer never fires and the test hangs or flakes.
///
/// Two synchronisation counters are provided because the two natural questions
/// are genuinely different, and each has a case where the other is useless:
///
/// - ``waitUntilSleeping(count:)`` waits on the **cumulative** number of times
///   `sleep` has been entered. Use it when timers are replaced over the life of
///   the test — a watchdog that restarts cancels its old timer, so the number
///   of *live* sleepers returns to one and never distinguishes "restarted" from
///   "never stopped".
/// - ``waitUntilSleepers(_:)`` waits on the number of **live** sleepers. Use it
///   when many timers come and go — a channel that has retired hundreds of
///   frames has hundreds of finished timer tasks behind it, so a cumulative
///   count never settles on a value the test can name.
public final class ManualTestClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol {
        fileprivate var offset: Swift.Duration

        public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        public static func == (lhs: Instant, rhs: Instant) -> Bool { lhs.offset == rhs.offset }

        public func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }
    }

    public typealias Duration = Swift.Duration

    private struct Waiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum Registration {
        case due
        case cancelled
        case registered
    }

    private let lock = NSLock()
    private var offset: Swift.Duration = .zero
    private var waiters: [UUID: Waiter] = [:]
    private var sleepEntryCount = 0

    public init() {}

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var now: Instant { Instant(offset: withLock { offset }) }

    public var minimumResolution: Swift.Duration { .zero }

    /// Timers currently asleep on a live deadline.
    public var sleeperCount: Int { withLock { waiters.count } }

    /// Total number of times `sleep` has been entered, including timers that
    /// have since fired or been cancelled.
    public var sleepCallCount: Int { withLock { sleepEntryCount } }

    public func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        // Counted before the cancellation check, so a timer cancelled before its
        // task was ever scheduled still registers as having been armed.
        // Otherwise `waitUntilSleeping` spins to its attempt limit.
        withLock { sleepEntryCount += 1 }

        if Task.isCancelled { throw CancellationError() }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                // The cancellation check happens under the same lock as
                // registration, so a waiter can never be registered after its
                // cancellation handler has already run — that would leave a
                // sleeper nothing will ever resume.
                let registration: Registration = withLock {
                    if Task.isCancelled { return .cancelled }
                    if offset >= deadline.offset { return .due }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return .registered
                }
                switch registration {
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .registered: break
                }
            }
        } onCancel: {
            let waiter = withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Advances virtual time and resumes every sleeper now due.
    public func advance(by duration: Swift.Duration) {
        let ready: [Waiter] = withLock {
            offset += duration
            let due = waiters.filter { $0.value.deadline.offset <= offset }
            for key in due.keys { waiters.removeValue(forKey: key) }
            return Array(due.values)
        }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Polls — by cooperative yielding, never real time — until `sleep` has been
    /// entered at least `count` times in total.
    ///
    /// Returns `false` if that never happens within a purely scheduling-bound
    /// number of attempts, which indicates a real bug rather than slowness.
    public func waitUntilSleeping(count: Int, maxAttempts: Int = 100_000) async -> Bool {
        for _ in 0..<maxAttempts {
            if sleepCallCount >= count { return true }
            await Task.yield()
        }
        return false
    }

    /// Polls — by cooperative yielding, never real time — until exactly `count`
    /// timers are asleep on a live deadline.
    ///
    /// Returns `false` if that never happens within a purely scheduling-bound
    /// number of attempts, which indicates a real bug rather than slowness.
    public func waitUntilSleepers(_ count: Int, maxAttempts: Int = 100_000) async -> Bool {
        for _ in 0..<maxAttempts {
            if sleeperCount == count { return true }
            await Task.yield()
        }
        return false
    }
}
