// SPDX-License-Identifier: Apache-2.0

#if canImport(Network)

import Foundation
import Network

/// A `StreamTransport` backed by `NWConnection` in TCP mode.
///
/// PD-1: networking goes through `Network.framework`, never BSD sockets.
///
/// With `NWDatagramTransport` this is one of only two places in the package
/// that knows a socket exists. Per AU-5, no test here contacts a real host or
/// depends on DNS: `NWStreamTransportTests` exercises only cancellation and
/// lifecycle plumbing, against endpoints guaranteed never to connect.
/// Everything else that can be tested lives above the `StreamTransport` seam.
///
/// Thread safety: all mutable state lives in the internal `Core` actor. This
/// class holds only immutable, `Sendable` references, so it is safe to share.
public final class NWStreamTransport: StreamTransport {
    public let incoming: AsyncStream<Data>
    private let core: Core

    /// Connect to `host` on `port` over TCP.
    ///
    /// The connection starts immediately; `send(_:)` waits for it to become
    /// ready, so callers never have to observe connection state themselves.
    ///
    /// - Parameters:
    ///   - host: Hostname or literal IPv4/IPv6 address.
    ///   - port: TCP port. Must be non-zero.
    /// - Throws: `StreamTransportError.invalidEndpoint` for an unusable port.
    public init(host: String, port: UInt16) throws {
        // Port 0 is checked separately: `NWEndpoint.Port(rawValue:)` accepts
        // it, so the `guard let` below is not the rejection it looks like.
        // A connection to port 0 never becomes ready, so without this a caller
        // that passes 0 gets a silent hang instead of an error.
        // (`NWDatagramTransport` has the same shape and the same gap — see the
        // note on this in the EL-3 PR.)
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw StreamTransportError.invalidEndpoint("port \(port)")
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

    public func send(_ bytes: Data) async throws {
        try await core.send(bytes)
    }

    public func close() async {
        await core.close()
    }

    deinit {
        // As `NWDatagramTransport.deinit`: a transport dropped without an
        // explicit `close()` must still finish `incoming`, or a consumer loop
        // hangs forever on a connection nobody owns. Capture `core`, not
        // `self`, which is mid-deinitialisation.
        let core = self.core
        Task { await core.close() }
    }
}

/// Parameters for a signalling connection: interactive service class, and
/// Nagle off so the small proxy frames go out rather than sitting in a buffer
/// waiting for company.
///
/// Built by handing `NWParameters` the TCP options directly. An earlier version
/// reached for them through `defaultProtocolStack.internetProtocol` and cast —
/// that is the IP layer, so the cast always failed and `noDelay` was never set.
/// It failed silently, which is what an `if let` around a configuration step
/// buys you; hence the test, and hence no cast here.
enum SignallingParameters {
    /// The TCP options the signalling connection runs with.
    ///
    /// Separate from `make()` so a test can inspect them. Reading them back off
    /// the parameters is not a reliable substitute — see below.
    static func makeTCPOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return tcp
    }

    static func make() -> NWParameters {
        // Supplying the options to the initialiser is the documented way to
        // configure the transport layer, and it is the whole mechanism: an
        // earlier attempt also assigned `noDelay` on
        // `parameters.defaultProtocolStack.transportProtocol` as belt and
        // braces, which turned out to be neither.
        //
        // On the macOS 14 CI runner, setting `noDelay` through that property
        // and then reading it straight back gives `false`; on macOS 15 it
        // reads `true`. The behaviour consistent with that is
        // `defaultProtocolStack` vending a fresh copy per access on 14, so the
        // assignment mutated a temporary and the "belt" did nothing. Removed
        // rather than left in, because a line that looks like it configures
        // something and does not is exactly the defect this whole block exists
        // to fix.
        //
        // The consequence for testing: `noDelay` **cannot be verified by
        // readback** on every OS version, so `NWStreamTransportTests` asserts
        // the options object we build and the layer it is attached to, and
        // does not assert the round trip.
        let parameters = NWParameters(tls: nil, tcp: makeTCPOptions())
        parameters.serviceClass = .responsiveData
        return parameters
    }
}

/// Owns the `NWConnection` and every piece of mutable state. Actor isolation
/// serialises the three sources of concurrency here: caller `send`s, the
/// connection's state-update callbacks, and the receive loop.
private actor Core {
    /// How much to accept per `receive`. Only an efficiency knob: the protocol
    /// layer reassembles, so any value is correct and the chunking a caller
    /// sees is not a contract.
    private static let maximumReceiveLength = 64 * 1024

    private let connection: NWConnection
    private let continuation: AsyncStream<Data>.Continuation
    private let queue: DispatchQueue

    private var isStarted = false
    private var isReady = false
    private var isClosed = false
    private var isReceiving = false
    private var failure: StreamTransportError?
    private var readyWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, continuation: AsyncStream<Data>.Continuation) {
        let parameters = SignallingParameters.make()
        self.connection = NWConnection(host: host, port: port, using: parameters)
        self.continuation = continuation
        self.queue = DispatchQueue(label: "org.hamvoip.radiocore.nwstream")
    }

    deinit {
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
            fail(.closed)
        case .waiting:
            break
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func fail(_ error: StreamTransportError) {
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

    func send(_ bytes: Data) async throws {
        start()
        try await waitUntilReady()
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    waiter.resume(throwing: StreamTransportError.sendFailed(String(describing: error)))
                } else {
                    waiter.resume()
                }
            })
        }
    }

    /// Suspends until the connection is ready, or throws if it never will be.
    ///
    /// Cancellation-safe by the same argument as `NWDatagramTransport`: the
    /// cancellation check and the waiter registration happen in one
    /// synchronous, non-suspending, actor-isolated span, so a waiter can never
    /// be registered after its cancellation handler has already run.
    private func waitUntilReady() async throws {
        if let failure { throw failure }
        if isClosed { throw StreamTransportError.closed }
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

    private func finishWaiters(with error: StreamTransportError) {
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
        // `minimumIncompleteLength: 1` is what makes this a stream read rather
        // than a message read: hand up whatever has arrived instead of waiting
        // for a full buffer. The chunk that results is meaningless as a
        // protocol unit, which is exactly what `StreamTransport` documents.
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumReceiveLength
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task { await self.received(content, isComplete: isComplete, error: error) }
        }
    }

    private func received(_ content: Data?, isComplete: Bool, error: NWError?) {
        guard !isClosed else { return }
        if let content, !content.isEmpty {
            continuation.yield(content)
        }
        if let error {
            fail(.connectionFailed(String(describing: error)))
            return
        }
        // TCP has an end that UDP does not: the peer can half-close, and
        // `isComplete` is how that arrives. Treat it as a clean shutdown —
        // yielding the final bytes first, which is why this check follows the
        // yield above rather than preceding it.
        if isComplete {
            fail(.closed)
            return
        }
        receiveNext()
    }
}

#endif
