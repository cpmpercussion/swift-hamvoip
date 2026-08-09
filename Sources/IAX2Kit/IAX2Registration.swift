// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Registration request

/// What goes in a REGREQ (RFC 5456 §6.1.2, §9.3).
///
/// Deliberately tiny: registration names an *account*, not a call. The host and
/// port live on the transport, exactly as they do for a call — see
/// `IAX2Destination`.
///
/// | Field | Information element | Notes |
/// |---|---|---|
/// | ``username`` | USERNAME `0x06` (§8.6.6) | Required on REGREQ and REGREL |
/// | ``refresh`` | REFRESH `0x13` (§8.6.18) | Omitted when `nil`; the peer then assumes 60 s (§6.1.1) |
/// | ``secret`` | — | **Never sent.** Hashed with the CHALLENGE; only the MD5 digest goes out (§8.6.15) |
public struct IAX2RegistrationRequest: Sendable, Equatable {
    /// USERNAME (`0x06`) — the account being registered (§8.6.6). "The
    /// 'username' information element is used to specify the identity of the
    /// user… It MUST be sent with IAX REGREQ, REGAUTH, and REGACK messages."
    public var username: String

    /// The shared secret answering a REGAUTH CHALLENGE (§8.6.14, §8.6.15).
    /// Never transmitted. `nil` for a registrar that does not challenge —
    /// permitted, since "the IAX protocol does permit servers to forego the
    /// challenge process" (§10), though a REGAUTH then fails with
    /// ``IAX2RegistrationError/missingSecret``.
    public var secret: String?

    /// REFRESH (`0x13`) — how many seconds of validity we are asking for
    /// (§8.6.18). `nil` omits the IE, at which point "a default registration
    /// expiration of 60 seconds MUST be assumed by both peers" (§6.1.1).
    ///
    /// Defaults to 60 s, the RFC's own default, sent explicitly: an omitted IE
    /// and an IE carrying 60 mean the same thing to a conforming peer, and
    /// sending it is the reading that does not depend on the peer implementing
    /// the default correctly.
    public var refresh: UInt16?

    public init(username: String, secret: String? = nil, refresh: UInt16? = 60) {
        self.username = username
        self.secret = secret
        self.refresh = refresh
    }

    /// The IE block of a REGREQ (§6.1.2). `md5Result` is present only on the
    /// REGREQ re-sent in answer to a REGAUTH: "This information element MUST
    /// NOT be sent except in response to a CHALLENGE." (§8.6.15)
    func registrationElements(md5Result: String? = nil) -> [InformationElement] {
        var elements: [InformationElement] = [.username(username)]
        if let md5Result { elements.append(.md5Result(md5Result)) }
        if let refresh { elements.append(.refresh(refresh)) }
        return elements
    }

    /// The IE block of a REGREL (§6.1.6, §9.4).
    ///
    /// No REFRESH: RFC 5456 Table 1 lists REFRESH against "REGREQ, REGACK,
    /// DPREP" and the §9.4 flow shows REGREL carrying USERNAME alone (plus the
    /// MD5 RESULT on the re-sent copy). A release has no validity period to
    /// negotiate.
    func releaseElements(md5Result: String? = nil) -> [InformationElement] {
        var elements: [InformationElement] = [.username(username)]
        if let md5Result { elements.append(.md5Result(md5Result)) }
        return elements
    }
}

// MARK: - What a REGACK told us

/// The contents of a successful REGACK (RFC 5456 §6.1.4, §9.3).
///
/// > "The registrant MUST be sent a REGACK message… The REGACK message MUST
/// > indicate the 'apparent address' and SHOULD indicate the 'refresh'
/// > \[expire] time." (§6.1.1, §6.1.4)
public struct IAX2RegistrationInfo: Sendable, Equatable {
    /// USERNAME (`0x06`) as the registrar echoed it (§8.6.6), or `nil` if it
    /// omitted the IE the RFC says it MUST send.
    public let username: String?

    /// REFRESH (`0x13`) exactly as received, in seconds — `nil` when the
    /// registrar omitted it (§8.6.18).
    public let refreshSeconds: UInt16?

    /// The validity period actually in force: ``refreshSeconds`` when the
    /// REGACK carried one, otherwise the configured default, which is 60 s
    /// because "If no 'refresh' is sent, a default registration expiration of
    /// 60 seconds MUST be assumed by both peers." (§6.1.1, §6.1.4, §8.6.18)
    ///
    /// The period "begins when the registrar sends a REGACK message" (§6.1.1);
    /// we can only observe its arrival, so this is measured from then — which
    /// errs on the side of renewing early.
    public let validity: Duration

    /// APPARENT ADDR (`0x12`) — "how the node sees us" (§8.6.17), which is what
    /// makes registration useful behind NAT.
    ///
    /// **Its address-family byte order is genuinely ambiguous** and
    /// `ApparentAddress` deliberately exposes both readings
    /// (`familyAsBigEndian` and `familyAsLittleEndian`); the RFC's own IPv4
    /// example is self-contradictory, showing family `0x0200` beside port
    /// `0x11d9`. That ambiguity is surfaced, not resolved — see the
    /// `ApparentAddress` documentation and notes trap 13.
    public let apparentAddress: ApparentAddress?

    /// DATETIME (`0x1f`) — the registrar's UTC wall clock (§8.6.28), which
    /// §6.1.4 says a REGACK SHOULD carry. Strictly informational, and a
    /// completely different quantity from a frame's per-call millisecond
    /// time-stamp (notes trap 8).
    public let dateTime: PackedDateTime?

    /// MSGCOUNT (`0x18`) — waiting-message counts, optional on REGACK
    /// (§8.6.23).
    public let messageCount: MessageCount?

    public init(
        username: String?,
        refreshSeconds: UInt16?,
        validity: Duration,
        apparentAddress: ApparentAddress?,
        dateTime: PackedDateTime? = nil,
        messageCount: MessageCount? = nil
    ) {
        self.username = username
        self.refreshSeconds = refreshSeconds
        self.validity = validity
        self.apparentAddress = apparentAddress
        self.dateTime = dateTime
        self.messageCount = messageCount
    }
}

// MARK: - State

/// Where a registration is in the RFC 5456 §6.1 exchange.
///
/// ```
/// unregistered → registering → [authenticating] → registered
///                     ↓ REGREJ / channel failure
///                  rejected ──(backoff)──▶ registering
/// registered → releasing → [authenticating] → unregistered
/// ```
public enum IAX2RegistrationState: String, Sendable, Equatable, CaseIterable,
    CustomStringConvertible
{
    /// No registration is in force and nothing is in flight.
    case unregistered
    /// A REGREQ has been sent; awaiting REGAUTH, REGACK or REGREJ (§6.1.2).
    case registering
    /// A REGAUTH was received and the credentialed REGREQ/REGREL re-sent
    /// (§6.1.3): "the registrant MUST resend the REGREQ or REGREL message with
    /// one of the requested credentials".
    case authenticating
    /// A REGACK confirmed the registration (§6.1.4). A refresh is scheduled.
    case registered
    /// A REGREL has been sent; awaiting REGAUTH or REGACK (§6.1.6).
    case releasing
    /// The last attempt failed — a REGREJ (§6.1.5), or the reliable channel
    /// giving up (§7). A retry may be scheduled; see
    /// ``IAX2Registrar/Configuration/retry``.
    case rejected
    /// ``IAX2Registrar/close()`` has run. Terminal.
    case closed

    public var description: String { rawValue }
}

// MARK: - Errors

/// Why a registration attempt failed.
public enum IAX2RegistrationError: Error, Equatable, CustomStringConvertible {
    /// REGREJ (§6.1.5). "Upon receipt of a REGREJ message, the registrant MUST
    /// consider registration process unsuccessful and no further interaction is
    /// required." The CAUSE (`0x16`) and CAUSECODE (`0x2a`) IEs are carried
    /// through verbatim — §6.1.5 says a REGREJ "MUST include the 'cause' and
    /// 'cause code' IEs", and they are the only thing separating "wrong
    /// password" from "unknown user".
    case rejected(cause: String?, causeCode: UInt8?)

    /// REGAUTH offered no method this client implements (§8.6.13). There is no
    /// plaintext path (§10) and RSA (`0x0004`) is out of scope for v1.
    case unsupportedAuthentication(offered: IAX2Auth.AuthMethods)

    /// REGAUTH arrived without the CHALLENGE IE §6.1.3 requires (§8.6.14).
    case missingChallenge

    /// REGAUTH arrived but no shared secret is configured, so no MD5 RESULT can
    /// be computed (§8.6.15).
    case missingSecret

    /// An IE block would not parse (§8.6).
    case malformedInformationElements(String)

    /// The reliable channel gave up: retries exhausted, or a transport write
    /// failed (§7).
    case channelFailed(ReliableChannelError)

    /// An operation was attempted in a state that does not admit it — a
    /// ``IAX2Registrar/unregister()`` with nothing registered, say.
    case illegalState(IAX2RegistrationState, attempted: String)

    /// The registrar has been closed and cannot be reused.
    case closed

    public var description: String {
        switch self {
        case .rejected(let cause, let code):
            switch (cause, code) {
            case (let cause?, let code?): return "the node refused the registration: \(cause) (cause code \(code))"
            case (let cause?, nil): return "the node refused the registration: \(cause)"
            case (nil, let code?): return "the node refused the registration (cause code \(code))"
            case (nil, nil): return "the node refused the registration, giving no reason"
            }
        case .unsupportedAuthentication(let offered):
            let hex = String(format: "0x%04x", offered.rawValue)
            return
                "REGAUTH offered AUTHMETHODS \(hex); this client implements MD5 (0x0002) only. "
                + "RSA (0x0004) is out of scope for v1 and plaintext (0x0001) was withdrawn by "
                + "RFC 5456 §10 — there is no plaintext path to fall back to."
        case .missingChallenge:
            return "REGAUTH carried no CHALLENGE information element (RFC 5456 §8.6.14)"
        case .missingSecret:
            return "REGAUTH received but no shared secret is configured for this registration"
        case .malformedInformationElements(let detail):
            return "malformed information element block: \(detail)"
        case .channelFailed(let error):
            return "reliable transport failed: \(error)"
        case .illegalState(let state, let attempted):
            return "\(attempted) is not valid while registration is '\(state)'"
        case .closed:
            return "this registrar has been closed and cannot be reused"
        }
    }
}

// MARK: - Events

/// Everything a registrar tells the layers above it. Delivered on
/// ``IAX2Registrar/events``, buffered without limit, finished by
/// ``IAX2Registrar/close()``.
///
/// Registration failures have to be *observable*: a node that quietly stops
/// accepting us is otherwise indistinguishable from a node nobody is calling.
public enum IAX2RegistrationEvent: Sendable, Equatable {
    /// Every state transition, in order.
    case stateChanged(from: IAX2RegistrationState, to: IAX2RegistrationState)

    /// REGAUTH arrived (§6.1.3). Reported before the MD5 RESULT is computed, so
    /// a failure to authenticate is still visible in the event history.
    case challenged(challenge: String, methods: IAX2Auth.AuthMethods)

    /// REGACK confirmed a registration (§6.1.4).
    case registered(IAX2RegistrationInfo)

    /// REGACK confirmed a REGREL (§6.1.6): we are no longer registered.
    case released

    /// The attempt failed. A retry may follow — see ``retryScheduled(after:attempt:)``.
    case failed(IAX2RegistrationError)

    /// A refresh has been scheduled to run before the registration expires
    /// (§7.2.2). `after` is measured from now on the injected clock.
    case refreshScheduled(after: Duration, validity: Duration)

    /// A failed attempt will be retried. `attempt` counts from 1 and is the
    /// number of the *upcoming* attempt's place in the backoff ladder.
    case retryScheduled(after: Duration, attempt: Int)

    /// The retry ladder is exhausted (or disabled): nothing further will be
    /// attempted until the caller asks again.
    case gaveUp(IAX2RegistrationError)

    /// A full frame addressed to this registration that §6.1 gives it no use
    /// for. Already ACKed by the reliable channel.
    case unhandled(IAX2FullFrame)
}

// MARK: - IAX2Registrar

/// Registered-node mode: the RFC 5456 §6.1 registration exchange, its refresh
/// timer and its backoff ladder (FR-1.3).
///
/// ```
///   Registrant (us)                                Registrar (the node)
///      |  ===REGREQ============================>     |  USERNAME (+ REFRESH)     §6.1.2
///      |  <=========================REGAUTH====      |  USERNAME + AUTHMETHODS + CHALLENGE
///      |  ===REGREQ============================>     |  USERNAME + MD5 RESULT (+ REFRESH)
///      |  <==========================REGACK====      |  USERNAME + DATETIME + APPARENT ADDR (+ REFRESH)
///      |  ===ACK===============================>     |  REQUIRED (§6.1.4)
/// ```
///
/// Release (§6.1.6, §9.4) is the same shape with REGREL in place of REGREQ.
/// Failure at any point is a REGREJ carrying CAUSE and CAUSECODE (§6.1.5).
///
/// ## What this actor owns, and what it borrows
///
/// It composes the same four layers `IAX2Call` does and adds nothing to the
/// wire they do not already model: `IAX2Frame` serialises, `InformationElement`
/// codes the IE block, `ReliableChannel` owns OSeqno/ISeqno and the ACKs, and
/// **`IAX2Auth` computes the MD5 response — registration authenticates exactly
/// the way a call does** (§8.6.15 governs AUTHREP and REGREQ identically), so
/// none of that arithmetic is repeated here.
///
/// ## Integration seam (for `IAX2Client`)
///
/// This actor is self-contained and does not require any change to `IAX2Call`
/// or `IAX2Client` to be correct. Wiring it into `IAX2Client` is three lines:
///
/// 1. Build it with the client's **shared `IAX2CallNumberAllocator`** — a
///    registration occupies a source call number for the life of the
///    registration, exactly like a call leg, and the two must not collide
///    ("The source call number for an active call MUST NOT be in use by
///    another call on the same client", §8.1.1) — and with
///    `readsTransport: false`, because `DatagramTransport.incoming` is
///    single-consumer and the client owns that loop.
/// 2. In `IAX2Client.handleInbound(_:)`, offer the datagram to the registrar
///    first and return if it consumed it:
///    ```swift
///    if let registrar, await registrar.deliver(datagram: datagram) { return }
///    ```
///    ``deliver(datagram:)`` returns `false` for anything not addressed to the
///    registration's call-number pair, so a call datagram falls straight
///    through to the existing `call.deliver(datagram:)` path. It never sends an
///    INVAL for a frame it does not recognise — that decision belongs to the
///    multiplexer, which is the only party that knows whether *some* leg owns
///    the frame.
/// 3. Close it wherever the client releases its session
///    (`IAX2Client.releaseSession()`), and note that the read loop must run for
///    the whole registered lifetime, not merely while a call is up — which is
///    the one ordering change registered-node mode asks of the client, since
///    `connect(to:)` currently starts the loop as part of placing a call.
///
/// ## Concurrency (plan rule 10)
///
/// A REGAUTH can arrive **while the REGREQ that provoked it is still inside
/// `transport.send`** — an actor is reentrant across an await, and on a fast
/// local node the reply genuinely wins that race. Two defences, both used here:
///
/// - The state transition and the ``isExchangeInFlight`` flag are committed
///   **before** the send is awaited, so an inbound REGAUTH never finds a state
///   that would reject it, and a concurrent ``register()`` never starts a
///   second exchange.
/// - ``waitUntilRegistered()`` re-checks the terminal conditions and parks its
///   continuation in the **same actor-isolated synchronous region**, with no
///   await between the check and the park, so no interleaving can drop an
///   outcome.
///
/// `testRegistrationCompletesWhenRegauthArrivesDuringSend` delivers the reply
/// from inside `send` and is what holds both in place.
public actor IAX2Registrar {

    // MARK: Configuration

    /// Refresh, retry and retransmission policy.
    ///
    /// RFC 5456 supplies exactly one number here — the 60 s default validity
    /// (§6.1.1) — and one instruction without a number: "The registrations
    /// SHOULD be renewed at random intervals to prevent network congestion."
    /// (§7.2.2) Everything else is local policy, documented as such.
    public struct Configuration: Sendable, Equatable {
        /// The validity to assume when a REGACK carries no REFRESH IE: "a
        /// default registration expiration of 60 seconds MUST be assumed by
        /// both peers" (§6.1.1, §6.1.4, §8.6.18).
        public var defaultRefreshSeconds: UInt16

        /// What fraction of the validity period to wait before renewing.
        /// Local policy: §7.2.2 requires only that renewal happen "before the
        /// time period expires". 0.8 leaves a fifth of the period — 12 s of a
        /// 60 s registration — for the exchange itself, which is comfortably
        /// more than the reliable channel's 500 ms → 4 s retransmission ladder
        /// needs (§7.2.1).
        public var renewalFraction: Double

        /// How much of the period to subtract at random, to satisfy "renewed at
        /// random intervals to prevent network congestion" (§7.2.2). The delay
        /// is `validity × (renewalFraction − renewalJitterFraction × u)` for a
        /// `u` drawn uniformly from `[0, 1)`, so it is always **earlier** than
        /// ``renewalFraction`` and therefore always before expiry. Set to 0 for
        /// a fully deterministic schedule.
        public var renewalJitterFraction: Double

        /// What to do about a failed attempt.
        public var retry: RetryPolicy

        /// Retransmission policy for the exchange's `ReliableChannel` (§7,
        /// §7.2.1).
        public var channel: ReliableChannel.Configuration

        public init(
            defaultRefreshSeconds: UInt16 = 60,
            renewalFraction: Double = 0.8,
            renewalJitterFraction: Double = 0.1,
            retry: RetryPolicy = RetryPolicy(),
            channel: ReliableChannel.Configuration = ReliableChannel.Configuration()
        ) {
            self.defaultRefreshSeconds = defaultRefreshSeconds
            self.renewalFraction = renewalFraction
            self.renewalJitterFraction = renewalJitterFraction
            self.retry = retry
            self.channel = channel
        }
    }

    /// The backoff ladder for failed registrations.
    ///
    /// **Entirely local policy.** §6.1.5 says a REGREJ means "the registrant
    /// MUST consider registration process unsuccessful and no further
    /// interaction is required" — which settles what to do about *that*
    /// exchange (stop) and says nothing about starting a new one later. A node
    /// that is rebooting, or whose database is briefly unavailable, refuses
    /// registrations it will accept a minute later, so giving up permanently on
    /// one REGREJ is wrong too.
    ///
    /// The rule this encodes is: retry, but back off geometrically so a node
    /// that is rejecting us is never hammered. Default 5 s, doubling, capped at
    /// 5 minutes, indefinitely — an unattended repeater link is expected to
    /// keep trying.
    public struct RetryPolicy: Sendable, Equatable {
        /// The delay before the first retry.
        public var initialInterval: Duration
        /// The ceiling the doubling ladder is clamped to.
        public var maximumInterval: Duration
        /// How many retries to make before giving up. `nil` is unlimited; 0
        /// disables retrying altogether.
        public var maximumAttempts: Int?

        public init(
            initialInterval: Duration = .seconds(5),
            maximumInterval: Duration = .seconds(300),
            maximumAttempts: Int? = nil
        ) {
            self.initialInterval = initialInterval
            self.maximumInterval = maximumInterval
            self.maximumAttempts = maximumAttempts
        }

        /// Never retry: one attempt, then ``IAX2RegistrationEvent/gaveUp(_:)``.
        public static let none = RetryPolicy(maximumAttempts: 0)
    }

    /// Which message this exchange is built around.
    private enum Exchange: Sendable, Equatable {
        /// REGREQ (§6.1.2).
        case registration
        /// REGREL (§6.1.6).
        case release

        var message: IAX2Message { self == .registration ? .regreq : .regrel }
        var busyState: IAX2RegistrationState { self == .registration ? .registering : .releasing }
    }

    // MARK: Public surface

    /// Our 15-bit source call number for the registration (§8.1.1).
    ///
    /// Fixed for the life of the registrar, across refreshes and retries, so a
    /// multiplexing client can route inbound datagrams on it. Allocated from
    /// the same 1…32767 space as call legs, and from the same allocator when
    /// one is supplied, because §8.1.1's uniqueness rule spans the client.
    public nonisolated let sourceCallNumber: UInt16

    /// What we are registering.
    public nonisolated let request: IAX2RegistrationRequest

    /// Registration lifecycle, buffered without limit so nothing is missed by a
    /// consumer that starts iterating late. Finished by ``close()``.
    public nonisolated let events: AsyncStream<IAX2RegistrationEvent>

    /// Where the registration is in the §6.1 exchange.
    public private(set) var state: IAX2RegistrationState = .unregistered

    /// The most recent REGACK's contents — including the APPARENT ADDR the node
    /// reported (§8.6.17). Survives expiry of the registration it described, so
    /// a UI can still say what the node last thought our address was.
    public private(set) var registration: IAX2RegistrationInfo?

    /// The most recent failure, if any. Cleared by a successful REGACK.
    public private(set) var lastFailure: IAX2RegistrationError?

    /// The peer's source call number for this exchange, learned from its first
    /// reply. 0 until then — a REGREQ has no destination call number to carry,
    /// for the same reason a NEW does not (§6.2.2).
    public private(set) var destinationCallNumber: UInt16 = 0

    /// How many consecutive failures have occurred. Reset by a REGACK.
    public private(set) var consecutiveFailures = 0

    // MARK: Injected

    private let transport: any DatagramTransport
    private let clock: any Clock<Duration>
    private let configuration: Configuration
    private let allocator: IAX2CallNumberAllocator?
    private let readsTransport: Bool
    private let randomUnitInterval: @Sendable () -> Double
    private nonisolated let continuation: AsyncStream<IAX2RegistrationEvent>.Continuation

    /// Builds the exchange's reliable channel on the injected clock.
    ///
    /// A closure rather than a stored `any Clock<Duration>`, because
    /// `ReliableChannel.init` is generic over a concrete `Clock` and an
    /// existential cannot satisfy that. The generic initialiser is the only
    /// place the concrete clock type is known, so everything needing it is
    /// captured there — the same technique `IAX2Client` uses for `makeCall`.
    private let makeChannel: @Sendable () -> ReliableChannel

    /// Milliseconds elapsed since this actor was created, on the injected
    /// clock. Each exchange's time-stamp origin is a fixed offset from it.
    private let elapsedMillisecondsSinceInit: @Sendable () -> UInt32

    // MARK: Exchange state

    /// The reliable channel of the exchange currently in flight, if any.
    ///
    /// **One channel per exchange, not one per registrar.** A `ReliableChannel`
    /// that exhausts its retries is permanently dead (§7), so a retry needs a
    /// fresh one; and each REGREQ→REGACK exchange is a self-contained
    /// transaction in the §9.3 flow, which starts its sequence numbers at 0.
    ///
    /// *RFC ambiguous:* RFC 5456 does not say whether a refresh continues the
    /// previous exchange's OSeqno/ISeqno or restarts them. §8.1.1 defines the
    /// counters per call and "Upon initialization of a call, its value is 0";
    /// the §9.3 flow shows one exchange beginning at 0 and never revisits it.
    /// We restart per exchange, which is the reading consistent with both, and
    /// re-learn the peer's call number each time from its first reply.
    private var channel: ReliableChannel?
    private var channelEventTask: Task<Void, Never>?
    private var exchange: Exchange = .registration
    private var timestampOrigin: UInt32 = 0

    /// **The dedicated in-flight flag (plan rule 10).** Never inferred from
    /// ``state``, which the completion path mutates: an actor is reentrant
    /// across `transport.send`, so a REGAUTH — or a second `register()` — can
    /// interleave between committing the state and the send returning.
    private var isExchangeInFlight = false

    /// **True only while a frame of ours is inside `transport.send`.**
    ///
    /// The second rule-10 flag, and the one that keeps the *wire* deterministic
    /// rather than merely correct. A REGAUTH genuinely can arrive while the
    /// REGREQ that provoked it is still being written; answering it from inside
    /// that window would mean two `ReliableChannel.send` calls overlapping, and
    /// a channel assigns OSeqno *before* awaiting the write and advances it
    /// *after* — so both frames would leave carrying the same sequence number
    /// and the second would clobber the first's entry in the outstanding table.
    ///
    /// So the credentialed re-send is stashed in ``deferredCredentialedPayload``
    /// and flushed the moment the write completes. Nothing is lost and nothing
    /// overlaps.
    private var isWritingFrame = false

    /// A REGREQ/REGREL re-send that arrived while ``isWritingFrame`` was set.
    private var deferredCredentialedPayload: [UInt8]?

    private var readTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var registeredWaiters: [UUID: CheckedContinuation<IAX2RegistrationInfo, Error>] = [:]
    private var didReleaseCallNumber = false

    // MARK: Init

    /// - Parameters:
    ///   - sourceCallNumber: our 15-bit call number for the registration.
    ///     **Must be in 1…32767** (§8.1.1, notes §15); prefer
    ///     ``outbound(allocator:request:transport:clock:configuration:readsTransport:randomUnitInterval:)``.
    ///   - request: the account to register (§6.1.2).
    ///   - transport: the datagram seam (AU-5). Never closed by this actor —
    ///     one transport carries the registration *and* the calls, which is the
    ///     whole point of registered-node mode.
    ///   - clock: `ContinuousClock()` in production, a manual clock under test.
    ///     Drives the refresh timer, the backoff ladder, the retransmission
    ///     ladder and the frame time-stamps — every timer in this stack, so a
    ///     test runs a whole registration lifetime without one real-time wait
    ///     (AU-5).
    ///   - configuration: refresh, retry and retransmission policy.
    ///   - allocator: if given, ``sourceCallNumber`` is returned to it by
    ///     ``close()``.
    ///   - readsTransport: `true` (default) for a registrar that owns the
    ///     transport; `false` when a client multiplexes and will call
    ///     ``deliver(datagram:)`` itself. See the integration seam above.
    ///   - randomUnitInterval: the source of the renewal jitter §7.2.2 asks
    ///     for, in `[0, 1)`. Injected so a test's schedule is exact.
    public init<C: Clock>(
        sourceCallNumber: UInt16,
        request: IAX2RegistrationRequest,
        transport: any DatagramTransport,
        clock: C,
        configuration: Configuration = Configuration(),
        allocator: IAX2CallNumberAllocator? = nil,
        readsTransport: Bool = true,
        randomUnitInterval: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) where C.Duration == Duration {
        precondition(
            IAX2CallNumberAllocator.range.contains(sourceCallNumber),
            "an IAX2 source call number is a 15-bit field and MUST NOT be 0 "
                + "(RFC 5456 §8.1.1, §8.1.3; notes §15)")
        self.sourceCallNumber = sourceCallNumber
        self.request = request
        self.transport = transport
        self.clock = clock
        self.configuration = configuration
        self.allocator = allocator
        self.readsTransport = readsTransport
        self.randomUnitInterval = randomUnitInterval

        let channelConfiguration = configuration.channel
        self.makeChannel = {
            ReliableChannel(
                sourceCallNumber: sourceCallNumber,
                transport: transport,
                clock: clock,
                configuration: channelConfiguration)
        }

        let origin = clock.now
        self.elapsedMillisecondsSinceInit = {
            let elapsed = origin.duration(to: clock.now)
            let (seconds, attoseconds) = elapsed.components
            guard seconds > 0 || attoseconds > 0 else { return 0 }
            // 1 ms = 1e15 attoseconds (§8.1.1).
            let milliseconds = seconds &* 1000 &+ attoseconds / 1_000_000_000_000_000
            return UInt32(truncatingIfNeeded: milliseconds)
        }

        var escapedContinuation: AsyncStream<IAX2RegistrationEvent>.Continuation!
        let stream = AsyncStream<IAX2RegistrationEvent>(bufferingPolicy: .unbounded) {
            continuation in
            escapedContinuation = continuation
        }
        self.events = stream
        self.continuation = escapedContinuation
    }

    /// Allocates a source call number and builds a registrar around it. The
    /// recommended constructor: on this path a call number can never be out of
    /// range, and exhaustion is a thrown error rather than a trap.
    public static func outbound<C: Clock>(
        allocator: IAX2CallNumberAllocator,
        request: IAX2RegistrationRequest,
        transport: any DatagramTransport,
        clock: C,
        configuration: Configuration = Configuration(),
        readsTransport: Bool = true,
        randomUnitInterval: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) async throws -> IAX2Registrar where C.Duration == Duration {
        let number = try await allocator.allocate()
        return IAX2Registrar(
            sourceCallNumber: number,
            request: request,
            transport: transport,
            clock: clock,
            configuration: configuration,
            allocator: allocator,
            readsTransport: readsTransport,
            randomUnitInterval: randomUnitInterval)
    }

    // MARK: Introspection

    /// Whether a registration is currently in force.
    public var isRegistered: Bool { state == .registered }

    /// The APPARENT ADDR the node last reported (§8.6.17), if any. Both
    /// byte-order readings of its family field are available on the value —
    /// see ``IAX2RegistrationInfo/apparentAddress``.
    public var apparentAddress: ApparentAddress? { registration?.apparentAddress }

    /// Whether an exchange is on the wire right now. The dedicated rule-10
    /// flag, exposed for tests and diagnostics.
    public var hasExchangeInFlight: Bool { isExchangeInFlight }

    /// The next OSeqno the current exchange will use (§8.1.1), or `nil` between
    /// exchanges.
    public func outboundSequenceNumber() async -> UInt8? {
        await channel?.outboundSequenceNumber
    }

    /// How many callers are parked in ``waitUntilRegistered()``. Internal, and
    /// it exists for one reason: the rule-10 test has to know that a waiter is
    /// genuinely parked *before* it delivers the outcome, or it would be
    /// testing the ordering it is meant to rule out.
    var parkedWaiterCount: Int { registeredWaiters.count }

    // MARK: - Registering (§6.1.2)

    /// Sends a REGREQ and returns once it is on the wire.
    ///
    /// Returning does **not** mean the registration succeeded — the REGACK has
    /// not arrived yet. Await ``waitUntilRegistered()`` for that, or watch
    /// ``events``.
    ///
    /// Idempotent while an exchange is in flight, and a no-op while already
    /// registered: refreshing is the refresh timer's job, and a caller that
    /// re-registered on every UI event would defeat it.
    ///
    /// - Throws: ``IAX2RegistrationError/closed`` on a closed registrar, or
    ///   whatever the transport threw.
    public func register() async throws {
        guard state != .closed else { throw IAX2RegistrationError.closed }
        guard !isExchangeInFlight else { return }
        guard state != .registered else { return }
        cancelRetry()
        consecutiveFailures = 0
        try await beginExchange(.registration)
    }

    /// Suspends until a REGACK confirms the registration.
    ///
    /// - Returns: what the REGACK carried, including the APPARENT ADDR.
    /// - Throws: ``IAX2RegistrationError`` if the current attempt fails —
    ///   ``IAX2RegistrationError/rejected(cause:causeCode:)`` for a REGREJ. A
    ///   scheduled retry is **not** waited for: a wrong password should surface
    ///   now, not five minutes from now. Call this again to wait on the next
    ///   attempt.
    ///
    /// ## Rule 10, twice over
    ///
    /// The terminal-condition checks and the park below sit in one
    /// actor-isolated synchronous region — `withCheckedThrowingContinuation`'s
    /// body runs before the suspension — so a REGACK that arrives during
    /// ``register()``'s own `transport.send` cannot slip between them.
    ///
    /// **And the checks cover every state in which nothing would ever resume
    /// the continuation, not merely the happy one.** Checking only for
    /// `.registered` was a real hang: a REGREJ processed before the caller
    /// managed to park left a waiter nothing would ever wake, which reproduced
    /// in about half of whole-suite runs and never once when this class ran
    /// alone — the M17-3 fault, in a new place. The rule that fixes it is
    /// "park only when something is actually on the wire": if no exchange is in
    /// flight, there is no outcome coming, so report the last failure (or the
    /// state) instead of waiting for one.
    @discardableResult
    public func waitUntilRegistered() async throws -> IAX2RegistrationInfo {
        if state == .registered, let registration { return registration }
        if state == .closed { throw IAX2RegistrationError.closed }
        guard isExchangeInFlight else {
            throw lastFailure
                ?? IAX2RegistrationError.illegalState(state, attempted: "waitUntilRegistered")
        }
        let id = UUID()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<IAX2RegistrationInfo, Error>) in
            registeredWaiters[id] = continuation
        }
    }

    // MARK: - Releasing (§6.1.6)

    /// Sends a REGREL, releasing the registration, and returns once it is on
    /// the wire.
    ///
    /// > "Registrants SHOULD be capable of sending this message and registrars
    /// > MUST be able to process it." (§6.1.6)
    ///
    /// The REGREL exchange is authenticated exactly like the REGREQ one: a
    /// REGAUTH is answered by re-sending the REGREL with the MD5 RESULT (§6.1.6,
    /// §9.4). The refresh timer is cancelled first, so a release is never raced
    /// by a renewal.
    ///
    /// - Throws: ``IAX2RegistrationError/illegalState(_:attempted:)`` when
    ///   nothing is registered.
    public func unregister() async throws {
        guard state != .closed else { throw IAX2RegistrationError.closed }
        guard state == .registered else {
            throw IAX2RegistrationError.illegalState(state, attempted: "unregister")
        }
        cancelRefresh()
        cancelRetry()
        try await beginExchange(.release)
    }

    // MARK: - Receiving

    /// Offers one received datagram to the registration.
    ///
    /// **The multiplexing seam.** Returns `true` when the datagram belonged to
    /// this registration and was consumed, `false` when it did not — so a
    /// client that fans one UDP association out to a registration *and* a call
    /// can try each in turn (see the integration seam in the type
    /// documentation).
    ///
    /// Deliberately does not throw, and deliberately never answers an
    /// unrecognised frame with INVAL: a `false` return means "not mine", not
    /// "nobody's", and only the multiplexer can tell the difference (§6.9.2).
    /// A protocol failure inside a frame that *is* ours ends the exchange and
    /// schedules a retry rather than propagating into the caller's read loop.
    @discardableResult
    public func deliver(datagram: Data) async -> Bool {
        guard let frame = try? IAX2Frame.parse(datagram) else { return false }
        return await deliver(frame)
    }

    /// Offers one already-parsed frame. See ``deliver(datagram:)``.
    @discardableResult
    public func deliver(_ frame: IAX2Frame) async -> Bool {
        // A mini frame carries no destination call number (§8.1.2) and
        // registration has no media, so one can never belong here.
        guard case .full(let full) = frame else { return false }
        guard isForThisRegistration(full) else { return false }
        guard let channel, isExchangeInFlight else {
            // Nothing in flight: a late retransmission of a REGACK we have
            // already answered, or a stray frame on a number we still hold. It
            // is ours by call number, so it is consumed rather than offered to
            // a call leg that would answer it with INVAL.
            return true
        }

        if destinationCallNumber == 0, full.sourceCallNumber != 0 {
            // Before the channel sees the frame: the ACK it is about to send
            // has to carry the peer's number as its destination.
            destinationCallNumber = full.sourceCallNumber
            await channel.setDestinationCallNumber(full.sourceCallNumber)
        }

        switch await channel.receive(frame) {
        case .deliver(let delivered):
            await handle(delivered)
        case .media, .consumed, .duplicate, .outOfSequence, .ignored:
            break
        }
        return true
    }

    /// Is this full frame addressed to this registration?
    ///
    /// The same pair rule a call leg uses (§6.2.1, §4): the frame's
    /// *destination* call number is ours and its *source* is the peer's. Before
    /// the peer's first reply we do not know its number, so any source is
    /// accepted and the number learned from it.
    private func isForThisRegistration(_ frame: IAX2FullFrame) -> Bool {
        guard frame.destinationCallNumber == sourceCallNumber else { return false }
        guard destinationCallNumber != 0 else { return true }
        return frame.sourceCallNumber == destinationCallNumber
    }

    // MARK: - The §6.1 message handlers

    private func handle(_ frame: IAX2FullFrame) async {
        guard frame.type == .iax, let message = frame.iaxMessage else {
            continuation.yield(.unhandled(frame))
            return
        }
        switch message {
        case .regauth:
            await handleRegistrationAuthentication(frame)
        case .regack:
            await handleRegistrationAcknowledgement(frame)
        case .regrej:
            await handleRegistrationRejection(frame)
        case .ack:
            // Consumed by the channel; it never reaches here.
            break
        default:
            // PING, POKE, INVAL, anything else: not part of §6.1. Already ACKed
            // by the channel where the RFC requires it.
            continuation.yield(.unhandled(frame))
        }
    }

    /// REGAUTH (§6.1.3, §8.6.13–§8.6.15).
    ///
    /// > "Upon receipt of a REGAUTH message, the registrant MUST resend the
    /// > REGREQ or REGREL message with one of the requested credentials, if it
    /// > has the specified credentials." (§6.1.3)
    ///
    /// The MD5 RESULT is computed by `IAX2Auth.md5Response(challenge:secret:)`
    /// — the same function, over the same `MD5(challenge ‖ password)`
    /// construction, that answers an AUTHREQ on a call. §8.6.15 governs both
    /// messages in one sentence, and the OQ-5 text-encoding assumption is
    /// isolated there, in one place, for both.
    ///
    /// MD5 only. There is no plaintext path to fall back to (§8.6.13, §10) and
    /// an RSA-only registrar fails here, loudly.
    private func handleRegistrationAuthentication(_ frame: IAX2FullFrame) async {
        guard state == .registering || state == .releasing else {
            // A REGAUTH after we have already answered one, or after the
            // exchange resolved. Nothing sensible to re-send.
            continuation.yield(.unhandled(frame))
            return
        }

        let elements: [InformationElement]
        do {
            elements = try InformationElement.parseList(frame.payload)
        } catch {
            await failExchange(.malformedInformationElements(String(describing: error)))
            return
        }

        var challenge: String?
        var offered = IAX2Auth.AuthMethods([])
        for element in elements {
            switch element {
            case .challenge(let value):
                challenge = value
            case .authMethods(let value):
                // The IE parser and `IAX2Auth` model the same §8.6.13 bitmask
                // in two types; the raw value is the shared truth.
                offered = IAX2Auth.AuthMethods(rawValue: value.rawValue)
            default:
                break
            }
        }

        guard let challenge else {
            await failExchange(.missingChallenge)
            return
        }
        continuation.yield(.challenged(challenge: challenge, methods: offered))

        do {
            _ = try IAX2Auth.selectAuthMethod(offered: offered)
        } catch {
            await failExchange(.unsupportedAuthentication(offered: offered))
            return
        }
        guard let secret = request.secret else {
            await failExchange(.missingSecret)
            return
        }

        // §8.6.15: MD5( challenge ‖ password ), challenge first, no separator,
        // carried as text. The text encoding is OQ-5 and lives in `IAX2Auth`.
        let response = IAX2Auth.md5Response(challenge: challenge, secret: secret)
        let elementsToSend =
            exchange == .registration
            ? request.registrationElements(md5Result: response)
            : request.releaseElements(md5Result: response)

        let payload: [UInt8]
        do {
            payload = try InformationElement.serialize(elementsToSend)
        } catch {
            await failExchange(.malformedInformationElements(String(describing: error)))
            return
        }

        // Committed before anything is awaited — plan rule 10. A REGACK can
        // arrive from inside `transport.send`, and it must not find a state
        // that would make it look out of place.
        transition(to: .authenticating)

        guard !isWritingFrame else {
            // The REGREQ that provoked this REGAUTH is still inside
            // `transport.send`. Queue the answer; ``beginExchange`` flushes it
            // the instant the write completes. See ``isWritingFrame``.
            deferredCredentialedPayload = payload
            return
        }
        await sendCredentialed(payload)
    }

    /// Writes the credentialed REGREQ/REGREL, holding ``isWritingFrame`` for
    /// the duration so a second reply arriving mid-write is queued rather than
    /// overlapped.
    private func sendCredentialed(_ payload: [UInt8]) async {
        guard let channel else { return }
        isWritingFrame = true
        do {
            try await channel.send(
                exchange.message, timestamp: timestampMilliseconds, payload: payload)
            isWritingFrame = false
        } catch {
            isWritingFrame = false
            await failExchange(Self.channelFailure(error))
        }
        await flushDeferredCredentialedSend()
    }

    /// Sends whatever a reply queued while we were writing.
    private func flushDeferredCredentialedSend() async {
        guard let payload = deferredCredentialedPayload else { return }
        deferredCredentialedPayload = nil
        await sendCredentialed(payload)
    }

    /// REGACK (§6.1.4). "Receipt of a REGACK message requires an ACK in
    /// response." — already sent by the reliable channel, which ACKs every
    /// in-sequence full frame (§6.9.1, §8.1.1).
    private func handleRegistrationAcknowledgement(_ frame: IAX2FullFrame) async {
        let wasReleasing = exchange == .release
        let elements = (try? InformationElement.parseList(frame.payload)) ?? []

        var username: String?
        var refreshSeconds: UInt16?
        var apparent: ApparentAddress?
        var dateTime: PackedDateTime?
        var messageCount: MessageCount?
        for element in elements {
            switch element {
            case .username(let value): username = value
            case .refresh(let value): refreshSeconds = value
            case .apparentAddr(let value): apparent = value
            case .datetime(let value): dateTime = value
            case .msgCount(let value): messageCount = value
            default: break
            }
        }

        // The exchange is over either way: nothing further is expected on this
        // channel, and leaving its retransmission timers armed would produce
        // exactly the spurious traffic §7 exists to bound.
        await finishExchange()

        if wasReleasing {
            registration = nil
            transition(to: .unregistered)
            continuation.yield(.released)
            // Every terminal outcome of an exchange resumes every waiter —
            // there is no registration left to hand back, and a waiter parked
            // across a release would otherwise never be woken by anything.
            resumeWaiters(
                with: .failure(.illegalState(.unregistered, attempted: "waitUntilRegistered")))
            return
        }

        // "If no 'refresh' is sent, a default registration expiration of 60
        // seconds MUST be assumed by both peers." (§6.1.1, §6.1.4, §8.6.18)
        let seconds = refreshSeconds ?? configuration.defaultRefreshSeconds
        let info = IAX2RegistrationInfo(
            username: username,
            refreshSeconds: refreshSeconds,
            validity: .seconds(Int(seconds)),
            apparentAddress: apparent,
            dateTime: dateTime,
            messageCount: messageCount)

        registration = info
        lastFailure = nil
        consecutiveFailures = 0
        transition(to: .registered)
        continuation.yield(.registered(info))
        resumeWaiters(with: .success(info))
        scheduleRefresh(validity: info.validity)
    }

    /// REGREJ (§6.1.5).
    ///
    /// > "Upon receipt of a REGREJ message, the registrant MUST consider
    /// > registration process unsuccessful and no further interaction is
    /// > required." (§6.1.5)
    ///
    /// So the exchange stops here — the ACK the channel already sent is the
    /// last thing on the wire for it. Whether to try *again*, later, is the
    /// backoff ladder's decision; see ``RetryPolicy``.
    private func handleRegistrationRejection(_ frame: IAX2FullFrame) async {
        var cause: String?
        var causeCode: UInt8?
        // Both are "MUST" on REGREJ (§6.1.5) but a payload that will not parse
        // must still not lose the rejection itself.
        if let elements = try? InformationElement.parseList(frame.payload) {
            for element in elements {
                switch element {
                case .cause(let value): cause = value
                case .causeCode(let value): causeCode = value
                default: break
                }
            }
        }
        await failExchange(.rejected(cause: cause, causeCode: causeCode))
    }

    // MARK: - Exchange lifecycle

    /// Starts a REGREQ or REGREL exchange on a fresh reliable channel.
    ///
    /// The state and the in-flight flag are committed **before** the send is
    /// awaited (plan rule 10): an actor is reentrant across `transport.send`,
    /// so on a fast node the REGAUTH is genuinely delivered while this call is
    /// still suspended. Committing first means the reply finds the state it
    /// expects; the failure path below unwinds it if the send throws.
    private func beginExchange(_ kind: Exchange) async throws {
        // Everything that can fail without touching the wire happens first, so
        // a serialisation failure leaves no state to unwind.
        let payload: [UInt8]
        do {
            payload = try InformationElement.serialize(
                kind == .registration ? request.registrationElements() : request.releaseElements())
        } catch {
            throw IAX2RegistrationError.malformedInformationElements(String(describing: error))
        }

        // Claimed synchronously, before the first await of this function — two
        // concurrent `register()` calls must not both get past their in-flight
        // guard and start two exchanges (plan rule 10).
        isExchangeInFlight = true
        transition(to: kind.busyState)

        await teardownChannel()

        let channel = makeChannel()
        self.channel = channel
        exchange = kind
        destinationCallNumber = 0
        timestampOrigin = elapsedMillisecondsSinceInit()
        startLoops(channel: channel)

        isWritingFrame = true
        do {
            // Time-stamp 0: this frame *is* the first transmission of the
            // exchange (§8.1.1, §6.2.2).
            try await channel.send(kind.message, timestamp: 0, payload: payload)
            isWritingFrame = false
        } catch {
            isWritingFrame = false
            deferredCredentialedPayload = nil
            await failExchange(Self.channelFailure(error))
            throw error
        }
        // A REGAUTH may have arrived and been queued while that write was in
        // flight; this is where it goes out. See ``isWritingFrame``.
        await flushDeferredCredentialedSend()
    }

    /// The exchange resolved successfully. Retires its channel and its loops.
    private func finishExchange() async {
        isExchangeInFlight = false
        deferredCredentialedPayload = nil
        await teardownChannel()
    }

    /// The exchange failed. Records it, tells everyone, and hands the decision
    /// about trying again to the backoff ladder.
    private func failExchange(_ error: IAX2RegistrationError) async {
        guard isExchangeInFlight || state == .registering || state == .releasing else { return }
        isExchangeInFlight = false
        deferredCredentialedPayload = nil
        await teardownChannel()

        lastFailure = error
        consecutiveFailures += 1
        transition(to: .rejected)
        continuation.yield(.failed(error))
        resumeWaiters(with: .failure(error))
        scheduleRetry(after: error)
    }

    private func teardownChannel() async {
        channelEventTask?.cancel()
        channelEventTask = nil
        if let channel { await channel.close() }
        channel = nil
    }

    // MARK: - Loops

    private func startLoops(channel: ReliableChannel) {
        if readsTransport, readTask == nil {
            let transport = self.transport
            readTask = Task { [weak self] in
                for await datagram in transport.incoming {
                    guard let self else { return }
                    await self.deliver(datagram: datagram)
                }
            }
        }
        channelEventTask = Task { [weak self] in
            for await event in channel.events {
                guard case .failed(let error) = event else { continue }
                guard let self else { return }
                // §7: the leg is torn down "without any further interaction",
                // so there is nothing to send — only something to report, and
                // to retry later.
                await self.failExchange(.channelFailed(error))
            }
        }
    }

    // MARK: - The refresh timer (§6.1.1, §7.2.2)

    /// Arms the renewal.
    ///
    /// > "It is the client's responsibility to renew this registration before
    /// > the time period expires. The registrations SHOULD be renewed at random
    /// > intervals to prevent network congestion." (§7.2.2)
    ///
    /// The delay is a fraction of the validity period, minus a random slice —
    /// so it is always strictly before expiry, and two clients that came up
    /// together do not stay in lockstep. Both fractions are configurable and
    /// the randomness is injected, so a test's schedule is exact.
    private func scheduleRefresh(validity: Duration) {
        cancelRefresh()
        let jitter = configuration.renewalJitterFraction * randomUnitInterval()
        let fraction = max(0.0, min(1.0, configuration.renewalFraction - jitter))
        let delay = Self.scale(validity, by: fraction)
        continuation.yield(.refreshScheduled(after: delay, validity: validity))

        let clock = self.clock
        refreshTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return  // Cancelled: released, closed, or superseded.
            }
            await self?.refreshDue()
        }
    }

    private func refreshDue() async {
        guard state == .registered, !isExchangeInFlight else { return }
        do {
            try await beginExchange(.registration)
        } catch {
            // `beginExchange` has already reported and scheduled the retry.
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - The backoff ladder

    private func scheduleRetry(after error: IAX2RegistrationError) {
        cancelRetry()
        let policy = configuration.retry
        if let maximum = policy.maximumAttempts, consecutiveFailures > maximum {
            continuation.yield(.gaveUp(error))
            return
        }

        // Geometric: interval × 2^(failures − 1), clamped. The first failure
        // waits `initialInterval`; a node that keeps refusing is backed away
        // from rather than hammered.
        var delay = policy.initialInterval
        for _ in 1..<max(1, consecutiveFailures) {
            delay = delay * 2
            if delay > policy.maximumInterval { break }
        }
        delay = min(delay, policy.maximumInterval)

        continuation.yield(.retryScheduled(after: delay, attempt: consecutiveFailures + 1))

        let clock = self.clock
        retryTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return  // Cancelled: closed, or superseded by an explicit call.
            }
            await self?.retryDue()
        }
    }

    private func retryDue() async {
        guard state == .rejected, !isExchangeInFlight else { return }
        do {
            try await beginExchange(.registration)
        } catch {
            // `beginExchange` has already reported and scheduled the next one.
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: - Teardown

    /// Stops every timer, closes the exchange's channel, returns the source
    /// call number to the allocator and finishes ``events``.
    ///
    /// Terminal and idempotent. It does **not** send a REGREL — call
    /// ``unregister()`` first if the node should be told; a registration left
    /// to expire simply lapses after its validity period (§6.1.1).
    ///
    /// The transport is not closed: it carries the calls too, and it is the
    /// client's to close.
    public func close() async {
        guard state != .closed else { return }
        cancelRefresh()
        cancelRetry()
        readTask?.cancel()
        readTask = nil
        isExchangeInFlight = false
        deferredCredentialedPayload = nil
        await teardownChannel()

        transition(to: .closed)
        resumeWaiters(with: .failure(.closed))
        continuation.finish()

        if !didReleaseCallNumber, let allocator {
            didReleaseCallNumber = true
            await allocator.release(sourceCallNumber)
        }
    }

    // MARK: - Small helpers

    /// Milliseconds since the first transmission of the current exchange — the
    /// value that goes in a full frame's time-stamp field (§8.1.1).
    private var timestampMilliseconds: UInt32 {
        elapsedMillisecondsSinceInit() &- timestampOrigin
    }

    private func transition(to next: IAX2RegistrationState) {
        guard state != next else { return }
        let previous = state
        state = next
        continuation.yield(.stateChanged(from: previous, to: next))
    }

    private func resumeWaiters(with result: Result<IAX2RegistrationInfo, IAX2RegistrationError>) {
        let waiters = registeredWaiters
        registeredWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(with: result.mapError { $0 as Error })
        }
    }

    private static func channelFailure(_ error: Error) -> IAX2RegistrationError {
        .channelFailed((error as? ReliableChannelError) ?? .transportFailed(String(describing: error)))
    }

    /// Multiplies a `Duration` by a fraction, in whole milliseconds. Refresh
    /// periods are whole seconds on the wire (§8.6.18), so millisecond
    /// resolution is ample and keeps the arithmetic exact for a manual clock.
    private static func scale(_ duration: Duration, by fraction: Double) -> Duration {
        let (seconds, attoseconds) = duration.components
        let milliseconds = Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
        return .milliseconds(Int64((milliseconds * fraction).rounded()))
    }
}
