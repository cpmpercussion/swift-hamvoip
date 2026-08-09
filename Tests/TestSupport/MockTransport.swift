// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

/// The `DatagramTransport` every test uses in place of a socket (AU-5).
///
/// Two directions, both under the test's control:
///
/// - **Outbound** — `send(_:)` records the datagram in `sent` instead of
///   writing it anywhere. Assert on `sent` to check what the protocol layer
///   put on the wire.
/// - **Inbound** — `inject(_:)` pushes a datagram into `incoming`, which is
///   how a fixture-driven session feeds the code under test. The stream buffers
///   without limit, so datagrams injected before anyone starts iterating are
///   still delivered, in order.
///
/// `finish()` (and `close()`, which calls it) ends `incoming`, so a consumer
/// loop terminates instead of hanging a test.
///
/// Lives in `TestSupport` rather than a test target because IAX-3, IAX-5,
/// IAX-8 and M17-3 all need it.
///
/// Thread safety: every accessor is lock-guarded, and `AsyncStream.Continuation`
/// is itself safe to call from any task, so tests may `send`, `inject` and read
/// `sent` concurrently.
public final class MockTransport: DatagramTransport {
    public let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state = State()

    public init() {
        var escapedContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            escapedContinuation = continuation
        }
        self.incoming = stream
        self.continuation = escapedContinuation
    }

    // MARK: - Outbound (what the code under test wrote)

    /// Every datagram passed to `send(_:)`, in call order.
    public var sent: [Data] {
        state.withLock { $0.sent }
    }

    /// Convenience for the common `sent.count` assertion.
    public var sentCount: Int {
        state.withLock { $0.sent.count }
    }

    /// Drop the recorded datagrams — useful to ignore a connection handshake
    /// before asserting on what follows.
    public func clearSent() {
        state.withLock { $0.sent.removeAll() }
    }

    /// Records `datagram` in `sent`.
    ///
    /// - Throws: `DatagramTransportError.closed` after `close()`/`finish()`,
    ///   matching a real transport's behaviour.
    public func send(_ datagram: Data) async throws {
        let isClosed: Bool = state.withLock { current in
            guard !current.isClosed else { return true }
            current.sent.append(datagram)
            return false
        }
        if isClosed { throw DatagramTransportError.closed }
    }

    // MARK: - Inbound (what the peer "sent" us)

    /// Deliver one datagram to `incoming`. No-op once the stream has finished.
    public func inject(_ datagram: Data) {
        guard !isClosed else { return }
        continuation.yield(datagram)
    }

    /// Deliver several datagrams to `incoming`, in order.
    public func inject(_ datagrams: [Data]) {
        for datagram in datagrams { inject(datagram) }
    }

    // MARK: - Shutdown

    /// Whether `finish()` or `close()` has run.
    public var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    /// End `incoming` without pretending the transport was closed by the code
    /// under test. Idempotent.
    public func finish() {
        let alreadyClosed: Bool = state.withLock { current in
            defer { current.isClosed = true }
            return current.isClosed
        }
        guard !alreadyClosed else { return }
        continuation.finish()
    }

    public func close() async {
        finish()
    }

    // MARK: - Locked state

    private struct Storage {
        var sent: [Data] = []
        var isClosed = false
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Storage()

        func withLock<T>(_ body: (inout Storage) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&storage)
        }
    }
}
