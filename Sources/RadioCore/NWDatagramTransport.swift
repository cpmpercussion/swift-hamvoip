// SPDX-License-Identifier: Apache-2.0

#if canImport(Network)

import Foundation
import Network

/// A `DatagramTransport` backed by `NWConnection` in UDP mode.
///
/// PD-1: networking goes through `Network.framework`, never BSD sockets — that
/// is what gives us IPv6/NAT64 synthesis and sane behaviour across a
/// Wi-Fi/cellular handoff.
///
/// This type is the *only* place in the package that knows a socket exists.
/// Per AU-5, no test here ever contacts a real host or depends on DNS
/// resolution succeeding: `NWDatagramTransportTests` exercises only
/// cancellation and lifecycle plumbing, against endpoints guaranteed never to
/// connect. End-to-end behaviour against a real node is exercised by the CLI
/// harness (CLI-1). Everything else that can be tested lives above the
/// `DatagramTransport` seam.
///
/// Thread safety: all mutable state lives in the internal `Core` actor. This
/// class holds only immutable, `Sendable` references, so it is safe to share.
public final class NWDatagramTransport: DatagramTransport {
    public let incoming: AsyncStream<Data>
    private let core: Core

    /// Connect to `host` on `port` over UDP.
    ///
    /// The connection starts immediately; `send(_:)` waits for it to become
    /// ready, so callers never have to observe connection state themselves.
    ///
    /// - Parameters:
    ///   - host: Hostname or literal IPv4/IPv6 address.
    ///   - port: UDP port. Must be non-zero.
    /// - Throws: `DatagramTransportError.invalidEndpoint` for an unusable port.
    public init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw DatagramTransportError.invalidEndpoint("port \(port)")
        }

        var escapedContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            escapedContinuation = continuation
        }
        self.incoming = stream
        self.core = Core(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            continuation: escapedContinuation
        )

        let core = self.core
        Task { await core.start() }
    }

    public func send(_ datagram: Data) async throws {
        try await core.send(datagram)
    }

    public func close() async {
        await core.close()
    }

    deinit {
        // A transport dropped without an explicit `close()` must still keep
        // `DatagramTransport`'s contract: `incoming` "finishes when the
        // transport closes or the connection fails." Capture `core` (not
        // `self`, which is mid-deinitialisation) so this cleanup task is the
        // only thing keeping the actor alive; once `close()` runs it cancels
        // the connection and finishes `incoming`, so a caller that forgets to
        // close never leaks a live UDP socket or a stuck receive loop.
        let core = self.core
        Task { await core.close() }
    }
}

/// Owns the `NWConnection` and every piece of mutable state. Actor isolation
/// serialises the three sources of concurrency here: caller `send`s, the
/// connection's state-update callbacks, and the receive loop.
private actor Core {
    private let connection: NWConnection
    private let continuation: AsyncStream<Data>.Continuation
    private let queue: DispatchQueue

    private var isStarted = false
    private var isReady = false
    private var isClosed = false
    private var isReceiving = false
    private var failure: DatagramTransportError?
    private var readyWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, continuation: AsyncStream<Data>.Continuation) {
        let parameters = NWParameters.udp
        // Voice: keep the connection pinned to a single path and let the OS
        // treat it as interactive traffic.
        parameters.serviceClass = .responsiveData
        self.connection = NWConnection(host: host, port: port, using: parameters)
        self.continuation = continuation
        self.queue = DispatchQueue(label: "org.hamvoip.radiocore.nwdatagram")
    }

    deinit {
        // Backstop for `close()`: if `Core` is ever deallocated without it
        // (there should be no path left that does this, now that
        // `NWDatagramTransport.deinit` calls `close()`), still release the
        // socket and finish `incoming` rather than leaking silently.
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.finish()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted, !isClosed else { return }
        isStarted = true

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handle(state: state) }
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        isReady = false
        connection.stateUpdateHandler = nil
        connection.cancel()
        finishWaiters(with: failure ?? .closed)
        continuation.finish()
    }

    private func handle(state: NWConnection.State) {
        guard !isClosed else { return }
        switch state {
        case .ready:
            isReady = true
            resumeWaiters()
            startReceiving()
        case .failed(let error):
            fail(.connectionFailed(String(describing: error)))
        case .cancelled:
            // Cancellation we did not initiate (or a late callback after
            // `close()` cleared the handler): treat as a clean shutdown.
            fail(.closed)
        case .waiting:
            // Path unsatisfied or the peer is unreachable for now.
            // Network.framework retries on its own; nothing to do.
            break
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func fail(_ error: DatagramTransportError) {
        guard !isClosed else { return }
        failure = error
        isClosed = true
        isReady = false
        connection.stateUpdateHandler = nil
        connection.cancel()
        finishWaiters(with: error)
        continuation.finish()
    }

    // MARK: - Send

    func send(_ datagram: Data) async throws {
        start()
        try await waitUntilReady()
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            connection.send(content: datagram, completion: .contentProcessed { error in
                if let error {
                    waiter.resume(throwing: DatagramTransportError.sendFailed(String(describing: error)))
                } else {
                    waiter.resume()
                }
            })
        }
    }

    /// Suspends until the connection is ready, or throws if it never will be.
    ///
    /// Cancellation-safe: a caller that races this against a deadline (the
    /// documented way to impose a connect timeout above this layer, per
    /// RC-1) must get `CancellationError` back promptly, not leak a parked
    /// continuation. `withTaskCancellationHandler` and the waiter dictionary
    /// are both driven from actor-isolated code, so registering the waiter
    /// and removing it on cancellation are serialised against each other the
    /// same way `ManualTestClock.sleep(until:)` serialises under its lock:
    /// the cancellation check and the registration happen in the same
    /// synchronous, non-suspending span, so a waiter can never be registered
    /// after its cancellation handler has already run.
    private func waitUntilReady() async throws {
        if let failure { throw failure }
        if isClosed { throw DatagramTransportError.closed }
        if isReady { return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    waiter.resume(throwing: CancellationError())
                    return
                }
                readyWaiters[id] = waiter
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = readyWaiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
    }

    private func resumeWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }

    private func finishWaiters(with error: DatagramTransportError) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: error) }
    }

    // MARK: - Receive

    private func startReceiving() {
        guard !isReceiving else { return }
        isReceiving = true
        receiveNext()
    }

    private func receiveNext() {
        guard !isClosed else { return }
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            Task { await self.received(content, error: error) }
        }
    }

    private func received(_ content: Data?, error: NWError?) {
        guard !isClosed else { return }
        if let content, !content.isEmpty {
            continuation.yield(content)
        }
        if let error {
            fail(.connectionFailed(String(describing: error)))
            return
        }
        receiveNext()
    }
}

#endif
