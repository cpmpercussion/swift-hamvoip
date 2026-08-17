// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Errors

/// Why a proxy session failed.
public enum EchoLinkProxyError: Error, Equatable, CustomStringConvertible {
    /// The operation is not legal in the client's current state.
    case invalidTransition(from: EchoLinkProxyState, operation: String)

    /// The unframed login prefix was not eight ASCII hex characters.
    ///
    /// Almost always means the stream is not what we think it is — a capture
    /// beginning mid-session, or a host that is not a proxy.
    case malformedNonce(Data)

    /// The proxy answered `OPEN` with a `0x04` status other than `00 00 00 00`.
    ///
    /// Only zero has ever been observed, so the meaning of any other value is
    /// unknown; it is surfaced verbatim rather than guessed at.
    case openRejected(status: UInt32)

    /// The proxy sent a frame where a `0x04` status was expected.
    case unexpectedFrame(EchoLinkProxyMessageType)

    /// No answer arrived before the deadline.
    case timedOut(operation: String)

    /// The stream closed — by the peer, or locally — before the operation
    /// finished. A login the proxy rejected arrives this way: there is no
    /// "login failed" message, the proxy simply drops the connection.
    case streamClosed

    /// The frame decoder gave up: the framing has desynchronised.
    case framing(EchoLinkProxyFrameError)

    public var description: String {
        switch self {
        case .invalidTransition(let state, let operation):
            return "cannot \(operation) while \(state)"
        case .malformedNonce(let bytes):
            return "expected an 8-character ASCII hex nonce, got \(bytes.count) bytes"
        case .openRejected(let status):
            return String(format: "proxy refused OPEN with status 0x%08x", status)
        case .unexpectedFrame(let type):
            return "expected a STATUS frame, got \(type)"
        case .timedOut(let operation):
            return "\(operation) timed out"
        case .streamClosed:
            return "the proxy stream closed"
        case .framing(let error):
            return "proxy framing: \(error)"
        }
    }
}

/// Where a proxy session has got to.
public enum EchoLinkProxyState: Equatable, Sendable, CustomStringConvertible {
    /// Nothing started.
    case idle
    /// Waiting for the proxy's unframed nonce.
    case awaitingNonce
    /// The digest has been sent. See the note on `login()`: this is as far as
    /// authentication can be confirmed without opening a channel.
    case loggedIn
    /// An `OPEN` is outstanding, waiting for its `STATUS`.
    case opening
    /// A channel is open to a peer.
    case open
    /// Finished, cleanly or otherwise.
    case closed

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .awaitingNonce: return "awaiting nonce"
        case .loggedIn: return "logged in"
        case .opening: return "opening"
        case .open: return "open"
        case .closed: return "closed"
        }
    }
}

// MARK: - Client

/// The EchoLink proxy protocol over a `StreamTransport` (TCP 8100).
///
/// ## What the login actually looks like
///
/// The plan's EL-5 text, following the OQ-9 write-up, describes the login as
/// "proxy sends nonce; client replies with callsign and digest; **proxy answers
/// `0x04` status and a `0x02` payload from the directory server**". The
/// captures do not support that last clause, and this is worth being precise
/// about because it changes the API.
///
/// In the capture the frames run:
///
///     [0] <== nonce (unframed)
///     [1] ==> callsign + LF + digest (unframed)
///     [2] ==> 0x01 OPEN   peer <directory server>
///     [3] <== 0x04 STATUS 00 00 00 00
///     [4] ==> 0x02 TCP_DATA  the directory login
///     [5] <== 0x02 TCP_DATA  "OK"
///
/// The `STATUS` at `[3]` answers the `OPEN` at `[2]`, not the login at `[1]`,
/// and the `"OK"` at `[5]` is the *directory server's* answer to `[4]`. Both
/// belong to later steps. **The login itself is never acknowledged.** A proxy
/// that rejects it closes the connection instead.
///
/// So `login()` completes when the digest is written, and a bad password
/// surfaces as `.streamClosed` — from `open(peer:)`, or from whatever runs
/// next. That is a real limitation of the protocol rather than of this client,
/// and pretending otherwise would mean inventing an acknowledgement to wait for
/// and hanging forever when it never came.
///
/// ## Actor reentrancy (plan rule 10)
///
/// `open(peer:)` is a continuation-parking API: it awaits `transport.send` and
/// *then* waits for a reply. An actor is reentrant across that await, so the
/// receive loop can process the `STATUS` before `open` has parked its
/// continuation. This is the exact shape that cost M17-3 a hang in 4% of runs.
///
/// The mitigation here is the dedicated in-flight flag, the first of the two
/// patterns the plan sanctions: `openInFlight` is set before the send and
/// cleared only when the outcome reaches the caller, and it is independent of
/// `state`, which the reply handler also writes. A result that arrives during
/// the window is stashed in `pendingOpenResult` and collected the moment the
/// continuation parks. `testOpenReturnsWhenStatusIsProcessedDuringSend`
/// delivers the reply from inside the awaited send, which is the only ordering
/// that finds this.
public actor EchoLinkProxyClient {
    /// The well-known port for the EchoLink proxy protocol.
    public static let defaultPort: UInt16 = 8100

    /// Deadline for a channel `OPEN` to be answered.
    public static let defaultOpenTimeout: Duration = .seconds(10)

    /// Deadline for the proxy's unframed nonce to arrive.
    public static let defaultNonceTimeout: Duration = .seconds(10)

    // MARK: Immutable configuration

    private let callsign: String
    private let password: EchoLinkProxyPassword
    private let transport: any StreamTransport
    private let clock: any Clock<Duration>
    private let openTimeout: Duration
    private let nonceTimeout: Duration

    /// Frames the session layer above this one should handle: everything the
    /// proxy sends that is not a reply this client is itself waiting on.
    public nonisolated let frames: AsyncStream<EchoLinkProxyFrame>
    private let frameContinuation: AsyncStream<EchoLinkProxyFrame>.Continuation

    // MARK: Mutable state

    private var state: EchoLinkProxyState = .idle
    private var decoder = EchoLinkProxyFrameDecoder()
    private var receiveTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineGeneration: UInt64 = 0

    /// The nonce, once it has arrived.
    private var nonce: String?
    private var pendingNonce: CheckedContinuation<String, Error>?
    private var pendingNonceResult: Result<String, Error>?
    /// See the type documentation: independent of `state`, on purpose.
    private var nonceInFlight = false

    private var pendingOpen: CheckedContinuation<Void, Error>?
    private var pendingOpenResult: Result<Void, Error>?
    /// True from the moment `open(peer:)` commits to sending until its outcome
    /// has been handed back. Deliberately **not** inferred from `state`: the
    /// STATUS handler moves `state` to `.open` before delivering the outcome,
    /// so a result arriving inside the reentrancy window around
    /// `transport.send` would find no parked continuation and a state that is
    /// no longer `.opening` — and be dropped, hanging `open()` forever.
    private var openInFlight = false

    // MARK: Init

    /// - Parameters:
    ///   - callsign: This station's callsign, sent alongside the digest.
    ///   - password: The proxy password. `.publicProxy` for a public proxy.
    ///   - transport: The stream seam. Tests pass `MockStreamTransport`.
    ///   - clock: `ContinuousClock()` in production; a manual clock under test.
    public init<C: Clock>(
        callsign: String,
        password: EchoLinkProxyPassword = .publicProxy,
        transport: any StreamTransport,
        clock: C,
        openTimeout: Duration = EchoLinkProxyClient.defaultOpenTimeout,
        nonceTimeout: Duration = EchoLinkProxyClient.defaultNonceTimeout
    ) where C.Duration == Duration {
        self.callsign = callsign
        self.password = password
        self.transport = transport
        self.clock = clock
        self.openTimeout = openTimeout
        self.nonceTimeout = nonceTimeout

        var escapedContinuation: AsyncStream<EchoLinkProxyFrame>.Continuation!
        let stream = AsyncStream<EchoLinkProxyFrame>(bufferingPolicy: .unbounded) { continuation in
            escapedContinuation = continuation
        }
        self.frames = stream
        self.frameContinuation = escapedContinuation
    }

    // MARK: Introspection

    public var sessionState: EchoLinkProxyState { state }

    /// The nonce the proxy issued, once seen. Public because it is evidence —
    /// a bug report about a digest is not diagnosable without it — and not a
    /// secret: the proxy sends it in clear.
    public var issuedNonce: String? { nonce }

    // MARK: Login

    /// Wait for the proxy's nonce, then send the callsign and digest.
    ///
    /// Completes when the digest has been written. It does **not** confirm the
    /// proxy accepted it — see the note on this type; there is nothing to wait
    /// for. A rejected login shows up as `.streamClosed` on the next operation.
    ///
    /// - Throws: `EchoLinkProxyError`.
    public func login() async throws {
        guard state != .closed else { throw EchoLinkProxyError.streamClosed }
        guard state == .idle else {
            throw EchoLinkProxyError.invalidTransition(from: state, operation: "login")
        }

        state = .awaitingNonce
        pendingNonceResult = nil
        nonceInFlight = true
        startReceiveLoop()
        armDeadline(after: nonceTimeout, operation: "nonce")

        let challenge: String
        do {
            challenge = try await awaitNonce()
        } catch {
            teardown()
            throw error
        }
        cancelDeadline()

        nonce = challenge
        let message = EchoLinkAuth.proxyLoginMessage(
            callsign: callsign,
            password: password,
            nonce: challenge
        )

        do {
            try await transport.send(message)
        } catch {
            teardown()
            throw EchoLinkProxyError.streamClosed
        }

        // Only advance if the receive loop has not torn us down meanwhile.
        if state == .awaitingNonce {
            state = .loggedIn
        }
    }

    // MARK: Channels

    /// Open a channel to `peer` and wait for the proxy's `STATUS`.
    ///
    /// This is the first point at which the proxy says anything about whether
    /// the session is working, so it is also where a rejected login surfaces —
    /// as `.streamClosed`.
    ///
    /// - Throws: `EchoLinkProxyError.openRejected` for a non-zero status.
    public func open(peer: EchoLinkPeerAddress) async throws {
        // A dead session gets `.streamClosed`, not `.invalidTransition`.
        // Both are true, but only one tells the caller anything: the reason
        // this cannot open is that the proxy hung up, which is also how a
        // rejected login arrives. `.invalidTransition` is reserved for calls
        // made in the wrong *order*, which is a programming error rather than
        // a network event, and the two want different handling.
        guard state != .closed else { throw EchoLinkProxyError.streamClosed }
        guard state == .loggedIn || state == .open else {
            throw EchoLinkProxyError.invalidTransition(from: state, operation: "open")
        }

        pendingOpenResult = nil
        state = .opening
        openInFlight = true
        armDeadline(after: openTimeout, operation: "open")

        do {
            try await send(EchoLinkProxyFrame(type: .open, peer: peer))
        } catch {
            openInFlight = false
            pendingOpenResult = nil
            cancelDeadline()
            teardown()
            throw EchoLinkProxyError.streamClosed
        }

        // Everything between the send above and the park inside
        // `awaitOpenOutcome()` is the reentrancy window. It is safe because the
        // outcome is stashed rather than dropped when no continuation is
        // parked — see `finishOpen`.
        do {
            try await awaitOpenOutcome()
        } catch {
            cancelDeadline()
            throw error
        }
        cancelDeadline()
    }

    /// Send a frame verbatim. The session layer uses this for tunnelled
    /// directory traffic (`0x02`) and audio (`0x05`/`0x06`).
    public func send(_ frame: EchoLinkProxyFrame) async throws {
        guard state != .closed else { throw EchoLinkProxyError.streamClosed }
        do {
            try await transport.send(frame.encoded)
        } catch {
            throw EchoLinkProxyError.streamClosed
        }
    }

    /// Close the channel and the session.
    public func close() async {
        guard state != .closed else { return }
        // Best effort: if the stream is already gone this throws and there is
        // nothing useful to do about it.
        try? await send(EchoLinkProxyFrame(type: .close))
        await transport.close()
        teardown()
    }

    // MARK: Receive loop

    private func startReceiveLoop() {
        guard receiveTask == nil else { return }
        let incoming = transport.incoming
        receiveTask = Task { [weak self] in
            for await chunk in incoming {
                guard let self else { return }
                await self.received(chunk)
            }
            await self?.streamFinished()
        }
    }

    private func received(_ chunk: Data) {
        guard state != .closed else { return }
        decoder.append(chunk)

        // The unframed login prefix comes first, and only once. Taking it here
        // rather than letting the decoder frame it is the whole point of
        // `takePrefix` — see EL-1, and `testDecodingTheNonceAsAFrameIsWhatGoesWrong`.
        if nonceInFlight, nonce == nil {
            guard let prefix = decoder.takePrefix(EchoLinkAuth.nonceLength) else { return }
            guard EchoLinkAuth.isPlausibleNonce(prefix),
                  let text = String(data: prefix, encoding: .ascii) else {
                finishNonce(.failure(EchoLinkProxyError.malformedNonce(prefix)))
                return
            }
            finishNonce(.success(text))
        }

        do {
            while let frame = try decoder.nextFrame() {
                handle(frame)
            }
        } catch let error as EchoLinkProxyFrameError {
            // A desynchronised length-prefixed stream cannot be resynchronised.
            fail(.framing(error))
        } catch {
            fail(.streamClosed)
        }
    }

    private func handle(_ frame: EchoLinkProxyFrame) {
        if frame.type == .status, openInFlight {
            let status = frame.payload.count >= 4
                ? UInt32(frame.payload[frame.payload.startIndex]) << 24
                    | UInt32(frame.payload[frame.payload.startIndex + 1]) << 16
                    | UInt32(frame.payload[frame.payload.startIndex + 2]) << 8
                    | UInt32(frame.payload[frame.payload.startIndex + 3])
                : 0
            // NB. `state` is moved here, *before* the outcome is delivered.
            // That is exactly why `openInFlight` cannot be inferred from it.
            if status == 0 {
                state = .open
                finishOpen(.success(()))
            } else {
                state = .loggedIn
                finishOpen(.failure(EchoLinkProxyError.openRejected(status: status)))
            }
            return
        }
        frameContinuation.yield(frame)
    }

    private func streamFinished() {
        fail(.streamClosed)
    }

    private func fail(_ error: EchoLinkProxyError) {
        guard state != .closed else { return }
        finishNonce(.failure(error))
        finishOpen(.failure(error))
        teardown()
    }

    private func teardown() {
        guard state != .closed else { return }
        state = .closed
        cancelDeadline()
        receiveTask?.cancel()
        receiveTask = nil
        finishNonce(.failure(EchoLinkProxyError.streamClosed))
        finishOpen(.failure(EchoLinkProxyError.streamClosed))
        frameContinuation.finish()
    }

    // MARK: Deadlines

    private func armDeadline(after timeout: Duration, operation: String) {
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
            await self?.deadlineElapsed(generation: generation, operation: operation)
        }
    }

    private func cancelDeadline() {
        deadlineGeneration &+= 1
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func deadlineElapsed(generation: UInt64, operation: String) {
        guard generation == deadlineGeneration, state != .closed else { return }
        let error = EchoLinkProxyError.timedOut(operation: operation)
        finishNonce(.failure(error))
        // An OPEN that timed out leaves no channel open, but the login is
        // still good — so, like `handle(_:)` moving `state` before it
        // delivers a STATUS outcome, this restores `state` to `.loggedIn`
        // before `finishOpen` runs, so a retried `open(peer:)` finds a state
        // that permits it rather than being wedged behind
        // `.invalidTransition(from: .opening, ...)` forever. `openInFlight`
        // still gates a late STATUS for this attempt: `finishOpen` below
        // clears it, so that frame arrives with `openInFlight` already
        // false and is forwarded as an ordinary frame instead of touching
        // `state` again.
        if state == .opening {
            state = .loggedIn
        }
        finishOpen(.failure(error))
    }

    // MARK: Continuations
    //
    // Both pairs below follow the M17ReflectorClient pattern exactly: the
    // deliver-side stashes when no continuation is parked, and the await-side
    // checks the stash before parking. The check and the park happen in one
    // synchronous, actor-isolated span with no await between them, so no
    // interleaving can slip in.

    private func finishNonce(_ result: Result<String, Error>) {
        guard nonceInFlight else { return }
        if let continuation = pendingNonce {
            pendingNonce = nil
            pendingNonceResult = nil
            nonceInFlight = false
            continuation.resume(with: result)
        } else {
            pendingNonceResult = result
        }
    }

    private func awaitNonce() async throws -> String {
        if let stored = pendingNonceResult {
            pendingNonceResult = nil
            nonceInFlight = false
            return try stored.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingNonce = continuation
        }
    }

    private func finishOpen(_ result: Result<Void, Error>) {
        guard openInFlight else { return }
        if let continuation = pendingOpen {
            pendingOpen = nil
            pendingOpenResult = nil
            openInFlight = false
            continuation.resume(with: result)
        } else {
            pendingOpenResult = result
        }
    }

    private func awaitOpenOutcome() async throws {
        if let stored = pendingOpenResult {
            pendingOpenResult = nil
            openInFlight = false
            return try stored.get()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingOpen = continuation
        }
    }
}
