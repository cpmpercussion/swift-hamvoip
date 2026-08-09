// SPDX-License-Identifier: Apache-2.0

/// Hard transmit safety cut-off (SF-1, DESIGN-REQUIREMENTS.md §7).
///
/// A stuck open microphone keyed into a reflector or repeater is the
/// dominant on-air failure mode for software clients, so this actor favours
/// predictability over cleverness: `onExpiry` fires exactly once per
/// `start`, never fires after a `cancel()` that beat the deadline, and never
/// stacks two live timers.
///
/// The clock is injected so callers (and tests) never have to wait in real
/// time for a 180-second default to elapse.
public actor TransmitWatchdog {
    /// SF-1 default timeout: 180 seconds.
    public static let defaultTimeout: Duration = .seconds(180)

    private let clock: any Clock<Duration>
    private var pendingTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// - Parameter clock: `ContinuousClock()` in production; a test clock
    ///   under test so expiry can be driven deterministically.
    public init<C: Clock>(clock: C) where C.Duration == Duration {
        self.clock = clock
    }

    /// Whether a deadline is currently armed.
    public var isRunning: Bool {
        pendingTask != nil
    }

    /// Arms (or re-arms) the watchdog.
    ///
    /// Calling this while a deadline is already armed cancels the previous
    /// deadline and starts a fresh one measured from now — timers never
    /// stack, and the previous `onExpiry` is guaranteed not to run.
    /// Otherwise `onExpiry` runs exactly once, `timeout` from now, unless
    /// `cancel()` (or another `start()`) happens first.
    public func start(
        timeout: Duration = TransmitWatchdog.defaultTimeout,
        onExpiry: @escaping @Sendable () async -> Void
    ) {
        pendingTask?.cancel()
        generation &+= 1
        let thisGeneration = generation
        let clock = self.clock

        pendingTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                // Cancelled by `cancel()` or a subsequent `start()` — the
                // deadline this task was tracking no longer applies.
                return
            }
            guard let self else { return }
            guard await self.fire(generation: thisGeneration) else { return }
            await onExpiry()
        }
    }

    /// Disarms the watchdog.
    ///
    /// Harmless if the watchdog is not running or has already expired. If
    /// called before the deadline elapses, `onExpiry` is guaranteed never to
    /// run for the timer that was cancelled.
    public func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        generation &+= 1
    }

    /// Claims the right to fire `onExpiry` for `generation`, provided it
    /// hasn't been superseded by an intervening `cancel()` or `start()`.
    /// Marks the watchdog idle either way one such claim succeeds, so a
    /// racing `cancel()` observed by the actor before this call always wins.
    private func fire(generation: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        pendingTask = nil
        return true
    }
}
