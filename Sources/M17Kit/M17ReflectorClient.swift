// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - State

/// Where a reflector link is in its lifecycle.
///
/// The whole state machine, from "Control Packets":
///
/// ```text
///                    connect(module:)                ACKN
///   .disconnected ──────────────────▶ .connecting ──────────▶ .linked
///          ▲                               │                     │
///          │      NACK / connect timeout   │                     │ DISC in,
///          └───────────────────────────────┘                     │ disconnect(),
///          ▲                                                     │ keepalive timeout,
///          └─────────────────────────────────────────────────────┘ transport closed
/// ```
///
/// While `.linked`, inbound `PING` is answered with `PONG`; that exchange is
/// the only thing holding the link open, so a `PING` drought is treated as
/// link failure.
public enum M17ReflectorLinkState: Sendable, Equatable, CustomStringConvertible {
    case disconnected
    case connecting
    case linked

    public var description: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .linked: return "linked"
        }
    }
}

/// Why a link ended.
public enum M17DisconnectReason: Sendable, Equatable, CustomStringConvertible {
    /// ``M17ReflectorClient/disconnect()`` was called.
    case localRequest
    /// The reflector answered `CONN` with `NACK`.
    case rejectedByReflector
    /// The reflector sent `DISC`.
    case remoteRequest
    /// No `ACKN` (or `NACK`) arrived in time.
    case connectTimeout
    /// The reflector's `PING` keepalive stopped arriving.
    case keepaliveTimeout
    /// The underlying transport closed or failed.
    case transportClosed

    public var description: String {
        switch self {
        case .localRequest: return "disconnected locally"
        case .rejectedByReflector: return "refused by the reflector (NACK)"
        case .remoteRequest: return "disconnected by the reflector (DISC)"
        case .connectTimeout: return "timed out waiting for ACKN"
        case .keepaliveTimeout: return "reflector stopped sending PING keepalives"
        case .transportClosed: return "transport closed"
        }
    }
}

/// Everything ``M17ReflectorClient`` publishes to its owner.
public enum M17ReflectorEvent: Sendable, Equatable {
    /// `CONN` has gone out; waiting for `ACKN`/`NACK`.
    case connecting
    /// `ACKN` received — the link is up.
    case linked
    /// An `M17 ` stream datagram arrived on an established link. M17-4 owns
    /// what happens next; note that `packet.playability` may say the stream is
    /// encrypted and therefore not playable (FR-2.5).
    case stream(M17StreamPacket)
    /// The link ended.
    case disconnected(M17DisconnectReason)
}

// MARK: - Errors

/// Failures surfaced by ``M17ReflectorClient``.
public enum M17ReflectorClientError: Error, Equatable, CustomStringConvertible {
    /// The operation is not legal in the client's current state — e.g.
    /// `connect()` while already linked, or `disconnect()` while
    /// disconnected. Thrown rather than ignored, so a caller bug shows up at
    /// the call site instead of as a link that silently never comes up.
    case invalidTransition(from: M17ReflectorLinkState, operation: String)

    /// The reflector answered `CONN` with `NACK`.
    case connectionRefused(module: Character)

    /// No `ACKN` or `NACK` arrived within the connect timeout.
    case connectTimedOut(Duration)

    /// The reflector's `PING` keepalive stopped for longer than the link
    /// timeout, so the link was torn down.
    case keepaliveTimedOut(Duration)

    /// The transport closed while a connection attempt was outstanding.
    case transportClosed

    /// ``M17ReflectorClient/disconnect()`` or ``M17ReflectorClient/shutdown()``
    /// ran while a connection attempt was still outstanding.
    case connectCancelled

    public var description: String {
        switch self {
        case .invalidTransition(let from, let operation):
            return "cannot \(operation) while \(from)"
        case .connectionRefused(let module):
            return "reflector refused the connection (NACK) for module '\(module)'"
        case .connectTimedOut(let timeout):
            return "no ACKN from the reflector within \(timeout)"
        case .keepaliveTimedOut(let timeout):
            return "reflector stopped sending PING keepalives for \(timeout); link dropped"
        case .transportClosed:
            return "transport closed while connecting"
        case .connectCancelled:
            return "connection attempt cancelled"
        }
    }
}

// MARK: - Client

/// The M17 reflector connection state machine (FR-2.1).
///
/// Speaks the control protocol from the M17 specification's "M17 Internet
/// Protocol (IP) Networking" chapter — see the reference block at the top of
/// `M17ReflectorProtocol.swift` for the exact document and layouts — over a
/// ``DatagramTransport``, conventionally UDP port
/// ``M17Kit/defaultReflectorPort`` (17000).
///
/// Design notes:
///
/// - **The clock is injected**, exactly as in `TransmitWatchdog`. Both
///   deadlines — waiting for `ACKN`, and waiting for the next `PING` — are
///   measured on that clock, so tests drive them instantly and deterministically
///   and never wait in real time.
/// - **Illegal transitions throw.** `connect()` is legal only while
///   ``linkState`` is `.disconnected`; `disconnect()` only while it isn't.
/// - **Unparsable datagrams are dropped, not guessed at.** Anything that isn't
///   one of the seven documented layouts is discarded without touching the
///   state machine.
/// - **No encryption API (FR-2.5).** Nothing here takes a key, and no code path
///   attempts to decrypt. If a received stream's TYPE field says it is
///   encrypted, it is delivered with `playability == .encrypted` so the layer
///   above can refuse to play it.
public actor M17ReflectorClient {

    /// How long to wait for `ACKN`/`NACK` after sending `CONN`.
    ///
    /// The specification does not state a value — it defines no timers at all
    /// — so this is a local policy choice, sized so a user gets a clear failure
    /// rather than a spinner.
    public static let defaultConnectTimeout: Duration = .seconds(5)

    /// How long the link may go without an inbound `PING` before it is
    /// declared dead.
    ///
    /// Also a local policy choice; the specification names `PING` as the
    /// keepalive but gives no interval. Generous enough to survive a couple of
    /// missed keepalives on a lossy path.
    public static let defaultLinkTimeout: Duration = .seconds(30)

    // MARK: Configuration

    private let transport: any DatagramTransport
    private let clock: any Clock<Duration>
    private let connectTimeout: Duration
    private let linkTimeout: Duration

    /// This client's own 'From' address, as sent in `CONN`, `PONG` and `DISC`.
    public nonisolated let address: M17Address

    // MARK: Published events

    /// Link lifecycle and inbound stream packets, in order.
    ///
    /// Single-consumer, like ``DatagramTransport/incoming``. Buffers without
    /// limit, so nothing is lost if iteration starts late.
    public nonisolated let events: AsyncStream<M17ReflectorEvent>
    private nonisolated let eventContinuation: AsyncStream<M17ReflectorEvent>.Continuation

    // MARK: Mutable state

    private var state: M17ReflectorLinkState = .disconnected
    private var pendingModule: M17Module?
    private var receiveTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    /// Bumped whenever a deadline is armed or invalidated, so a timer task
    /// that wakes up after its deadline stopped being relevant does nothing.
    private var deadlineGeneration: UInt64 = 0
    private var pendingConnect: CheckedContinuation<Void, Error>?
    /// Set when a connection resolves before `connect()` has parked its
    /// continuation — possible because `transport.send` is awaited first, and
    /// an actor is reentrant across that await.
    private var pendingConnectResult: Result<Void, Error>?
    /// True from the moment `connect()` commits to sending `CONN` until its
    /// outcome has been handed back to the caller.
    ///
    /// This exists because "is a connect in flight?" cannot be inferred from
    /// `state`. The inbound `ACKN` handler moves `state` to `.linked` *before*
    /// delivering the outcome, so a result arriving during the reentrancy
    /// window around `transport.send` would find no parked continuation and a
    /// state that is no longer `.connecting` — and be dropped, hanging
    /// `connect()` forever. Tracking the in-flight call explicitly makes the
    /// stash independent of whatever `state` happens to be.
    private var connectInFlight = false

    // MARK: Init

    /// - Parameters:
    ///   - callsign: This station's callsign, base-40 encoded into the 'From'
    ///     address field of `CONN`, `PONG` and `DISC`.
    ///   - sourceModule: Optional module letter appended to the encoded address
    ///     as `"<callsign> <module>"`, the convention the specification shows
    ///     for the 'From' field ("6-byte 'From' callsign including module in
    ///     last character (e.g. \"A1BCD D\")"). Left `nil` the address is the
    ///     bare callsign. Independent of the module passed to
    ///     ``connect(module:)``, which is the reflector module being linked.
    ///   - transport: The datagram seam. Tests pass `MockTransport`.
    ///   - clock: `ContinuousClock()` in production; a manual clock under test.
    ///   - connectTimeout: Deadline for `ACKN` after `CONN`.
    ///   - linkTimeout: Deadline for the next inbound `PING`.
    /// - Throws: `M17PacketError.invalidAddress` if the callsign will not
    ///   base-40 encode.
    public init<C: Clock>(
        callsign: String,
        sourceModule: M17Module? = nil,
        transport: any DatagramTransport,
        clock: C,
        connectTimeout: Duration = M17ReflectorClient.defaultConnectTimeout,
        linkTimeout: Duration = M17ReflectorClient.defaultLinkTimeout
    ) throws where C.Duration == Duration {
        self.address = try M17Address(callsign: callsign, module: sourceModule)
        self.transport = transport
        self.clock = clock
        self.connectTimeout = connectTimeout
        self.linkTimeout = linkTimeout

        var escapedContinuation: AsyncStream<M17ReflectorEvent>.Continuation!
        let stream = AsyncStream<M17ReflectorEvent>(bufferingPolicy: .unbounded) { continuation in
            escapedContinuation = continuation
        }
        self.events = stream
        self.eventContinuation = escapedContinuation
    }

    // MARK: Introspection

    /// The current link state.
    public var linkState: M17ReflectorLinkState { state }

    /// The reflector module currently linked (or being linked), if any.
    public var linkedModule: M17Module? { pendingModule }

    // MARK: Public API

    /// Sends `CONN` and waits for the reflector's answer.
    ///
    /// Returns once `ACKN` has arrived and the link is `.linked`.
    ///
    /// - Parameter module: The reflector module to link, ASCII `A`-`Z`
    ///   ("Control Packets", Table 28, byte 10).
    /// - Throws: `M17ReflectorClientError.invalidTransition` unless the client
    ///   is `.disconnected`; `.connectionRefused` on `NACK`; `.connectTimedOut`
    ///   if no answer arrives; `.transportClosed` if the link dies first;
    ///   `M17PacketError.invalidModule` for a module outside `A`-`Z`; or
    ///   whatever the transport's `send` threw.
    public func connect(module moduleLetter: Character) async throws {
        let module = try M17Module(moduleLetter)
        try await connect(module: module)
    }

    /// Sends `CONN` and waits for the reflector's answer.
    public func connect(module: M17Module) async throws {
        guard state == .disconnected else {
            throw M17ReflectorClientError.invalidTransition(from: state, operation: "connect")
        }

        pendingConnectResult = nil
        pendingModule = module
        state = .connecting
        connectInFlight = true
        startReceiveLoopIfNeeded()
        emit(.connecting)
        armDeadline(after: connectTimeout, isConnectDeadline: true)

        do {
            try await transport.send(M17ControlPacket.connect(from: address, module: module).data)
        } catch {
            pendingConnectResult = nil
            connectInFlight = false
            teardown(reason: .transportClosed)
            throw error
        }

        try await awaitConnectOutcome()
    }

    /// Sends one stream datagram to the reflector (M17-5).
    ///
    /// The link layer's only outbound media path. It does not build the
    /// packet, number it or CRC it — that is `M17StreamTransmitter`'s job, and
    /// keeping it there is what lets the sequencing be tested without a
    /// transport.
    ///
    /// - Throws: `M17ReflectorClientError.invalidTransition` unless the link is
    ///   up. Transmitting into a reflector that has not acknowledged the link
    ///   is not a recoverable condition to paper over — it means PTT and the
    ///   link state have diverged, and the fail-safe direction is to refuse.
    public func send(_ packet: M17StreamPacket) async throws {
        guard state == .linked else {
            throw M17ReflectorClientError.invalidTransition(from: state, operation: "send")
        }
        try await transport.send(packet.data)
    }

    /// Sends `DISC` and tears the link down.
    ///
    /// - Throws: `M17ReflectorClientError.invalidTransition` if there is no
    ///   link to drop, or whatever the transport's `send` threw. The link is
    ///   torn down locally either way.
    public func disconnect() async throws {
        guard state != .disconnected else {
            throw M17ReflectorClientError.invalidTransition(from: state, operation: "disconnect")
        }

        let datagram = M17ControlPacket.disconnect(from: address).data
        defer {
            finishConnect(.failure(M17ReflectorClientError.connectCancelled))
            teardown(reason: .localRequest)
        }
        try await transport.send(datagram)
    }

    /// Drops the link if there is one, stops the receive loop, finishes
    /// ``events`` and closes the transport. Idempotent.
    ///
    /// Not part of the state machine — this is the "we are done with this
    /// object" call, and it never throws.
    public func shutdown() async {
        if state != .disconnected {
            try? await transport.send(M17ControlPacket.disconnect(from: address).data)
            finishConnect(.failure(M17ReflectorClientError.connectCancelled))
            teardown(reason: .localRequest)
        }
        receiveTask?.cancel()
        receiveTask = nil
        eventContinuation.finish()
        await transport.close()
    }

    // MARK: Receive loop

    private func startReceiveLoopIfNeeded() {
        guard receiveTask == nil else { return }
        let incoming = transport.incoming
        receiveTask = Task { [weak self] in
            for await datagram in incoming {
                guard let self else { return }
                await self.handleInbound(datagram)
            }
            await self?.handleTransportFinished()
        }
    }

    private func handleInbound(_ datagram: Data) async {
        // Anything that isn't exactly one of the documented layouts is
        // discarded. A reflector link is a public UDP port; stray or malformed
        // datagrams must not be able to move the state machine.
        guard let packet = try? M17ReflectorPacket.parse(datagram) else { return }

        switch packet {
        case .stream(let stream):
            guard state == .linked else { return }
            emit(.stream(stream))

        case .control(let control):
            await handleControl(control)
        }
    }

    private func handleControl(_ packet: M17ControlPacket) async {
        switch packet {
        case .acknowledge:
            guard state == .connecting else { return }
            state = .linked
            armDeadline(after: linkTimeout, isConnectDeadline: false)
            emit(.linked)
            finishConnect(.success(()))

        case .negativeAcknowledge:
            guard state == .connecting else { return }
            let module = pendingModule?.letter ?? "?"
            finishConnect(.failure(M17ReflectorClientError.connectionRefused(module: module)))
            teardown(reason: .rejectedByReflector)

        case .ping:
            // "Upon receiv[i]ng a PING from a reflector, the client replies
            // with a PONG." This exchange is the only thing keeping the link
            // alive, so it also resets the link-failure deadline.
            guard state == .linked else { return }
            armDeadline(after: linkTimeout, isConnectDeadline: false)
            try? await transport.send(M17ControlPacket.pong(from: address).data)

        case .disconnect:
            guard state != .disconnected else { return }
            // "Acknowledged with 4-byte packet 'DISC' (without the callsign
            // field)."
            try? await transport.send(M17ControlPacket.disconnect(from: nil).data)
            finishConnect(.failure(M17ReflectorClientError.connectCancelled))
            teardown(reason: .remoteRequest)

        case .connect, .pong:
            // Client-to-reflector packets. A reflector has no reason to send
            // these to us; ignore rather than act on them.
            return
        }
    }

    private func handleTransportFinished() {
        receiveTask = nil
        guard state != .disconnected else { return }
        finishConnect(.failure(M17ReflectorClientError.transportClosed))
        teardown(reason: .transportClosed)
    }

    // MARK: Deadlines

    /// Arms the single outstanding deadline, cancelling any previous one.
    ///
    /// Generation-checked in the same way as `TransmitWatchdog`: a timer task
    /// that already woke up cannot fire once its generation has been
    /// superseded by a re-arm or a teardown.
    private func armDeadline(after timeout: Duration, isConnectDeadline: Bool) {
        deadlineTask?.cancel()
        deadlineGeneration &+= 1
        let generation = deadlineGeneration
        let clock = self.clock

        deadlineTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return  // Superseded or cancelled.
            }
            await self?.deadlineElapsed(generation: generation, isConnectDeadline: isConnectDeadline)
        }
    }

    private func deadlineElapsed(generation: UInt64, isConnectDeadline: Bool) {
        guard generation == deadlineGeneration else { return }
        deadlineTask = nil

        if isConnectDeadline {
            guard state == .connecting else { return }
            finishConnect(.failure(M17ReflectorClientError.connectTimedOut(connectTimeout)))
            teardown(reason: .connectTimeout)
        } else {
            guard state == .linked else { return }
            teardown(reason: .keepaliveTimeout)
        }
    }

    private func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        deadlineGeneration &+= 1
    }

    // MARK: Teardown

    private func teardown(reason: M17DisconnectReason) {
        cancelDeadline()
        pendingModule = nil
        guard state != .disconnected else { return }
        state = .disconnected
        emit(.disconnected(reason))
    }

    // MARK: Connect continuation

    /// Delivers the outcome of an in-flight `connect()`.
    ///
    /// If `connect()` has not parked its continuation yet the result is stashed
    /// and picked up the moment it does, which closes the reentrancy window
    /// around `transport.send`.
    private func finishConnect(_ result: Result<Void, Error>) {
        guard connectInFlight else { return }
        if let continuation = pendingConnect {
            pendingConnect = nil
            pendingConnectResult = nil
            connectInFlight = false
            continuation.resume(with: result)
        } else {
            // `connect()` has not parked its continuation yet. Stash the result
            // for `awaitConnectOutcome()` to pick up. The stash must NOT be
            // conditional on `state` — the ACKN handler has already moved it to
            // `.linked` by the time it calls this.
            pendingConnectResult = result
        }
    }

    private func awaitConnectOutcome() async throws {
        if let stored = pendingConnectResult {
            pendingConnectResult = nil
            connectInFlight = false
            return try stored.get()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingConnect = continuation
        }
    }

    // MARK: Events

    private func emit(_ event: M17ReflectorEvent) {
        eventContinuation.yield(event)
    }
}
