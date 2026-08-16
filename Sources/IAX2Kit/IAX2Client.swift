// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Destination

/// Everything needed to place one IAX2 call: where the node is, and who we say
/// we are (FR-1.2, "IAX Direct").
///
/// This is deliberately the *only* IAX2-shaped type the application layer has
/// to know about. `NetworkClient` is generic over `Destination`, so a SwiftUI
/// view model builds one of these, hands it to ``IAX2Client/connect(to:)`` and
/// never sees a frame, an information element or a call number.
///
/// ## How the fields reach the wire (RFC 5456 §6.2.2, §8.6)
///
/// | Field | Information element | Notes |
/// |---|---|---|
/// | ``node`` | CALLED NUMBER `0x01` (§8.6.1) | Required on NEW |
/// | ``username`` | USERNAME `0x06` (§8.6.6) | Omitted when empty |
/// | ``callsign`` | CALLING NAME `0x04` (§8.6.4) | Omitted when empty |
/// | ``callingNumber`` | CALLING NUMBER `0x03` (§8.6.3) | Omitted when empty, which is the default |
/// | ``secret`` | — | **Never sent.** Hashed with the CHALLENGE; only the MD5 digest goes out (§8.6.15) |
///
/// ``host`` and ``port`` never appear in a frame at all — they address the UDP
/// association, which is why they live here rather than in `IAX2CallRequest`.
public struct IAX2Destination: Sendable, Equatable {
    /// Hostname or literal address of the node.
    public let host: String

    /// UDP port. ``IAX2Kit/defaultPort`` (4569) unless the node says otherwise.
    public let port: UInt16

    /// The operator's callsign, sent as CALLING NAME (§8.6.4).
    public let callsign: String

    /// The identity the far end attributes the call to, sent as CALLING NUMBER
    /// (§8.6.3). Omitted when empty, which is the default and what IAX Direct
    /// (FR-1.2) and registered node mode have always sent.
    ///
    /// Web Transceiver needs it. There the USERNAME is a fixed context name
    /// (`allstar-public`) shared by every guest, so it cannot identify anyone —
    /// the node has to learn *who* is calling from somewhere else before it can
    /// ask allstarlink.org whether to admit them. See IAX-12.
    public let callingNumber: String

    /// The account name the node authenticates us as, sent as USERNAME
    /// (§8.6.6).
    public let username: String

    /// The shared secret answering an MD5 CHALLENGE (§8.6.15). Never
    /// transmitted; see the table above.
    public let secret: String

    /// The number being called, e.g. an AllStar node number `"55553"`, sent as
    /// CALLED NUMBER (§8.6.1).
    public let node: String

    public init(
        host: String,
        port: UInt16 = IAX2Kit.defaultPort,
        callsign: String,
        username: String,
        secret: String,
        node: String,
        callingNumber: String = ""
    ) {
        self.callingNumber = callingNumber
        self.host = host
        self.port = port
        self.callsign = callsign
        self.username = username
        self.secret = secret
        self.node = node
    }

    /// The NEW message this destination describes (§6.2.2).
    ///
    /// Empty strings become absent IEs rather than zero-length ones: a node
    /// with no username configured should see no USERNAME IE at all, not an
    /// empty one it has to interpret.
    ///
    /// CAPABILITY and FORMAT are both G.711 µ-law (`1 << 2`, §8.7). That is the
    /// only codec IAX2Kit encodes or decodes (FR-1.1), so offering more would
    /// be an invitation to negotiate something we cannot play.
    public var callRequest: IAX2CallRequest {
        IAX2CallRequest(
            calledNumber: node,
            username: username.isEmpty ? nil : username,
            secret: secret.isEmpty ? nil : secret,
            callingNumber: callingNumber.isEmpty ? nil : callingNumber,
            callingName: callsign.isEmpty ? nil : callsign,
            capability: .g711MuLaw,
            format: .g711MuLaw)
    }
}

// MARK: - Errors

/// Failures surfaced by ``IAX2Client``.
public enum IAX2ClientError: Error, Equatable, CustomStringConvertible {
    /// An operation that needs a live call was attempted without one.
    case notConnected

    /// ``IAX2Client/connect(to:)`` was called while a call already exists.
    case alreadyConnected

    /// ``IAX2Client/disconnect()`` has run. A client is finished after that —
    /// its streams have been finished, and a finished `AsyncStream` cannot be
    /// reopened. Build a new client for a new session.
    case clientShutDown

    /// The peer answered the NEW with REJECT (§6.2.4). The CAUSE (`0x16`) and
    /// CAUSECODE (`0x2a`) IEs are carried through verbatim, because they are
    /// the only thing that distinguishes "wrong password" from "node full"
    /// from "no such node" — all of which reach the user as a REJECT.
    case rejected(cause: String?, causeCode: UInt8?)

    /// The peer never created its side of the call leg within the connect
    /// deadline. Imposed by `IAX2Call` on the injected clock — RFC 5456
    /// specifies no call-setup timeout, and the transport cannot supply one
    /// (an unreachable host makes `NWConnection` retry internally rather than
    /// fail).
    case connectTimedOut(Duration)

    /// The call ended during setup for some other reason: an INVAL, a HANGUP, a
    /// protocol violation, or the reliable channel exhausting its retries.
    case connectFailed(IAX2CallTermination)

    public var description: String {
        switch self {
        case .notConnected:
            return "not connected to a node"
        case .alreadyConnected:
            return "already connected; disconnect before connecting again"
        case .clientShutDown:
            return "this client has been disconnected and cannot be reused"
        case .rejected(let cause, let code):
            switch (cause, code) {
            case (let cause?, let code?):
                return "the node rejected the call: \(cause) (cause code \(code))"
            case (let cause?, nil):
                return "the node rejected the call: \(cause)"
            case (nil, let code?):
                return "the node rejected the call (cause code \(code))"
            case (nil, nil):
                return "the node rejected the call, giving no reason"
            }
        case .connectTimedOut(let timeout):
            return "the node did not answer within \(timeout)"
        case .connectFailed(let reason):
            return "the call could not be set up: \(reason)"
        }
    }
}

// MARK: - Events

/// What a ``IAX2Client`` tells its owner, beyond ``IAX2Client/state``.
///
/// `state` is enough to drive a PTT button; this stream is what an application
/// needs to explain *why* something happened — a node that hung up, a watchdog
/// that fired, a DTMF digit that arrived.
public enum IAX2ClientEvent: Sendable, Equatable {
    /// The call is up and media may flow. `format` is the FORMAT IE from the
    /// ACCEPT (§6.2.3), i.e. the codec the node chose.
    case connected(format: MediaFormat?)

    /// Transmission started (``IAX2Client/startTransmit()``).
    case transmitting

    /// Transmission stopped, for any reason.
    case receiving

    /// **SF-1.** The transmit watchdog reached its deadline and stopped
    /// transmission on the operator's behalf. Worth putting in front of the
    /// user: it means a PTT was held (or stuck) for the whole timeout.
    case transmitWatchdogExpired(Duration)

    /// An inbound DTMF digit (§8.2.1, FR-1.5).
    case dtmf(IAX2DTMFDigit)

    /// Inbound media is being dropped. Emitted when the reason *changes*, not
    /// once per frame — a stream that cannot be decoded produces fifty of these
    /// a second, and the second one tells the operator nothing the first did
    /// not.
    case mediaRejected(IAX2VoiceReceiver.Rejection)

    /// The call ended. `reason` is `nil` when the transport closed underneath
    /// the call rather than the call itself terminating.
    case disconnected(IAX2CallTermination?)
}

// MARK: - Translation onto RadioCore's mode-agnostic events

extension IAX2ClientEvent {
    /// This event as `NetworkClient` sees it (RC-10).
    ///
    /// **Never `nil`** — alone among the three modes, every `IAX2ClientEvent`
    /// maps — so an application reading only ``IAX2Client/radioEvents`` misses
    /// nothing that happened, only some of the RFC 5456 vocabulary in which it
    /// happened. `IAX2Client.events` remains the place to go for that.
    ///
    /// The `Optional` is here to satisfy the shape the other two modes need; it
    /// is not a hedge about this one.
    public var radioEvent: RadioEvent? {
        switch self {
        // The negotiated codec is deliberately dropped: there is exactly one
        // (§8.7, FR-1.1), and a mode-agnostic event has nowhere honest to put a
        // `MediaFormat`. `IAX2Client.negotiatedFormat` still answers the
        // question for anyone who has a reason to ask it.
        case .connected:
            return .connected
        case .transmitting:
            return .transmitting
        case .receiving:
            return .receiving
        case .transmitWatchdogExpired(let timeout):
            return .transmitWatchdogExpired(timeout)
        case .dtmf(let digit):
            return .dtmfReceived(digit.character)
        case .mediaRejected(let rejection):
            return .incomingAudioDropped(rejection.radioAudioIssue)
        case .disconnected(let termination):
            // No termination means the transport went away underneath the call
            // — the call itself never reported an ending.
            return .disconnected(termination?.radioDisconnectReason ?? .transportFailure())
        }
    }
}

extension IAX2CallTermination {
    /// This termination as `NetworkClient` sees it (RC-10).
    public var radioDisconnectReason: RadioDisconnectReason {
        switch self {
        case .localHangup:
            // The cause on a local HANGUP is ours; telling the operator what we
            // told the node is not news.
            return .localRequest
        case .remoteHangup(let cause, let code):
            return .remoteRequest(detail: Self.radioDetail(cause, code))
        case .rejected(let cause, let code):
            return .rejected(detail: Self.radioDetail(cause, code))
        case .invalidated:
            return .protocolFailure(detail: "the node sent INVAL (RFC 5456 §6.9.2)")
        case .connectTimedOut(let timeout):
            return .connectTimedOut(timeout)
        case .channelFailed(.retriesExhausted):
            // The node stopped acknowledging. To an operator that is not a
            // "channel failure", it is the far end having gone quiet.
            return .linkTimedOut(nil)
        case .channelFailed(let error):
            return .transportFailure(detail: "\(error)")
        case .protocolError(let error):
            return .protocolFailure(detail: "\(error)")
        case .closed:
            return .localRequest
        }
    }

    /// The CAUSE (`0x16`) and CAUSECODE (`0x2a`) IEs as one line of prose, or
    /// `nil` when the node gave neither. `nil` rather than "no cause given",
    /// because a `RadioDisconnectReason` already renders that case itself.
    private static func radioDetail(_ cause: String?, _ code: UInt8?) -> String? {
        switch (cause, code) {
        case (let cause?, let code?): return "\(cause) (cause code \(code))"
        case (let cause?, nil): return cause
        case (nil, let code?): return "cause code \(code)"
        case (nil, nil): return nil
        }
    }
}

extension IAX2VoiceReceiver.Rejection {
    /// This rejection as `NetworkClient` sees it (RC-10).
    public var radioAudioIssue: RadioAudioIssue {
        switch self {
        case .unsupportedFormat:
            return .unsupportedFormat(detail: description)
        // Not-audio, an unpinned codec, an empty or wrong-length payload and a
        // pre-origin time-stamp are all "arrived, could not be turned into
        // samples". The distinction between them is an RFC 5456 distinction and
        // stays on `IAX2Client.events`.
        case .notAudio, .codecNotPinned, .emptyPayload, .wrongPayloadLength,
            .timestampPrecedesCallOrigin:
            return .undecodable(detail: description)
        }
    }
}

// MARK: - IAX2Client

/// An AllStarLink / IAX2 connection, whole (FR-1.2).
///
/// This is the one type an application sees. It conforms to `NetworkClient`,
/// so the SwiftUI layer talks to `connect(to:)`, `startTransmit()`,
/// `stopTransmit()`, `disconnect()` and `state` and knows nothing about RFC
/// 5456.
///
/// ```
///        transport ──▶ IAX2Call ──▶ events ──▶ IAX2VoiceStream ──▶ pop()
///            ▲            │                          │               │
///            │            │                          │           AudioLeveller
///        send(pcm:) ──────┴──────────────────────────┘               │
///                                                            receivedAudio ──▶ app
/// ```
///
/// Everything below it is already tested in isolation; this actor's whole job
/// is composition, plus the three things that only exist once the pieces are
/// assembled: the **20 ms media tick**, the **transmit watchdog** and the
/// **read loop**.
///
/// ## The 20 ms tick, and why it lives here
///
/// `IAX2VoiceStream` (IAX-6/IAX-7) is deliberately clock-free: frames go in
/// when the caller hands them in, PCM comes out when the caller calls `pop()`.
/// That is what makes a recorded session replayable (AU-5). Somebody, though,
/// has to call `pop()` fifty times a second, and this is that somebody.
///
/// The tick runs on an **absolute grid** — tick *n* wakes at `origin + n ×
/// frameInterval` — rather than sleeping a relative 20 ms each time round, so
/// the time spent decoding never accumulates into playout drift. If the grid
/// falls more than ``Configuration/maximumPlayoutLag`` behind (a suspended app,
/// a stalled thread, or a test advancing a manual clock by half a minute), it
/// is **resynchronised to now** instead of being caught up tick by tick:
/// replaying thirty seconds of stale jitter-buffer state into a speaker at
/// 6000× real time is not a recovery, it is a second fault.
///
/// ## The audio seams
///
/// - **Out:** the caller pushes 160-sample frames into ``send(pcm:)``.
/// - **In:** decoded, levelled PCM comes out of ``receivedAudio``.
///
/// `AudioPipeline` (RC-7) — microphone, speaker, `AVAudioEngine`, sample-rate
/// conversion — is attached by the application layer, **not here**. That is
/// what keeps this whole file testable without an audio device, and what lets
/// the CLI harness (CLI-1) and the iOS app wire the same client to very
/// different audio stacks.
///
/// ## Lifecycle
///
/// `connect(to:)` builds a transport, a call and a voice stream; a failed
/// connect releases all three and leaves the client ready to try again.
/// ``disconnect()`` is terminal: it hangs up, releases the session **and
/// finishes ``receivedAudio`` and ``events``**, because a consumer that is
/// looping over a stream needs that loop to end. Build a new client for a new
/// session. A call that ends remotely (the node hangs up) releases the session
/// but leaves the streams open, so the application can hear about it and
/// reconnect.
///
/// ## What is deliberately not here
///
/// **Registration (FR-1.3, REGREQ/REGAUTH/REGACK, §6.1) is out of scope** —
/// it is follow-up task IAX-8b. The seam it needs is ``handleInbound(_:)``:
/// this client owns the transport read loop precisely so a registration
/// exchange can share one UDP association with the call, which would be
/// impossible if `IAX2Call` were reading the transport itself
/// (`DatagramTransport.incoming` is single-consumer).
public actor IAX2Client: NetworkClient {
    public typealias Destination = IAX2Destination

    // MARK: Configuration

    public struct Configuration: Sendable {
        /// **SF-1.** How long a single transmission may last before the
        /// watchdog stops it. Default `TransmitWatchdog.defaultTimeout`, 180 s.
        public var transmitTimeout: Duration

        /// The media frame grid: 20 ms, which is one G.711 frame of 160
        /// samples at 8 kHz (§8.6.32, §8.7). Drives both the playout tick and
        /// the time-stamps of outbound frames, because they are the same grid
        /// seen from two ends.
        public var frameInterval: Duration

        /// How far the playout grid may fall behind the clock before it is
        /// resynchronised rather than caught up. See the type documentation.
        public var maximumPlayoutLag: Duration

        /// How many decoded frames ``IAX2Client/receivedAudio`` buffers for a
        /// consumer that is not keeping up. 50 frames is one second. Beyond
        /// that the **oldest** audio is dropped: in a live conversation, stale
        /// audio is worth less than current audio, and an unbounded buffer
        /// would grow forever behind a stalled consumer.
        public var receivedAudioBufferedFrames: Int

        /// Connect deadline and retransmission policy for the call leg.
        public var call: IAX2Call.Configuration

        /// The inbound jitter buffer (RC-3, RC-4/AU-3).
        public var jitterBuffer: JitterBuffer

        /// The received-audio leveller (RC-6/AU-4).
        public var leveller: AudioLeveller

        public init(
            transmitTimeout: Duration = TransmitWatchdog.defaultTimeout,
            frameInterval: Duration = .milliseconds(20),
            maximumPlayoutLag: Duration = .milliseconds(200),
            receivedAudioBufferedFrames: Int = 50,
            call: IAX2Call.Configuration = IAX2Call.Configuration(),
            jitterBuffer: JitterBuffer = JitterBuffer(),
            leveller: AudioLeveller = AudioLeveller()
        ) {
            self.transmitTimeout = transmitTimeout
            self.frameInterval = frameInterval
            self.maximumPlayoutLag = maximumPlayoutLag
            self.receivedAudioBufferedFrames = receivedAudioBufferedFrames
            self.call = call
            self.jitterBuffer = jitterBuffer
            self.leveller = leveller
        }
    }

    /// Builds the transport for a destination. Injected so tests substitute
    /// `MockTransport` and never open a socket (AU-5).
    public typealias TransportFactory = @Sendable (IAX2Destination) throws -> any DatagramTransport

    // MARK: Public surface

    /// Decoded, levelled 8 kHz mono PCM, one 160-sample frame per 20 ms tick,
    /// starting when the call comes up and ending at ``disconnect()``.
    ///
    /// **Exactly 160 samples, every tick, unconditionally** — that is
    /// `IAX2VoiceStream`'s contract and this stream keeps it. Concealment and
    /// silence are already substituted for missing frames, so the consumer
    /// feeds its audio device and never has to decide what a gap sounds like.
    ///
    /// Single-consumer, like `DatagramTransport.incoming`.
    public nonisolated let receivedAudio: AsyncStream<[Int16]>

    /// Connection lifecycle, watchdog expiry and inbound DTMF, in order.
    /// Buffered without limit; finished by ``disconnect()``.
    public nonisolated let events: AsyncStream<IAX2ClientEvent>

    /// `NetworkClient`'s mode-agnostic view of ``events`` (RC-10).
    ///
    /// The same events in the same order, translated by
    /// ``IAX2ClientEvent/radioEvent``, which for this mode drops nothing. Both
    /// streams are fed from one place, so they cannot disagree about what
    /// happened; a consumer picks the vocabulary it wants and ignores the other
    /// stream entirely.
    public nonisolated let radioEvents: AsyncStream<RadioEvent>

    /// `NetworkClient`'s transmit state.
    ///
    /// `nonisolated` — and therefore backed by a lock rather than by actor
    /// isolation — for two reasons: the protocol requirement is synchronous, so
    /// an actor-isolated property cannot satisfy it; and a UI that has to
    /// `await` to find out whether it is transmitting is a UI that will show
    /// the wrong thing at the worst moment.
    public nonisolated var state: TransmitState { stateBox.value }

    // MARK: Injected

    private let configuration: Configuration
    private let makeTransport: TransportFactory

    /// Builds the call leg on the injected clock.
    ///
    /// A closure rather than a stored `any Clock<Duration>`, because
    /// `IAX2Call.outbound` is generic over a concrete `Clock` and an existential
    /// cannot satisfy that. The generic initialiser is the only place the
    /// concrete clock type is known, so everything that needs it is captured
    /// there: this, ``elapsedSinceOrigin``, ``sleepUntilOffset`` and the
    /// watchdog.
    private let makeCall:
        @Sendable (IAX2CallNumberAllocator, IAX2CallRequest, any DatagramTransport) async throws ->
            IAX2Call

    /// How long ago this client was created, on the injected clock. The playout
    /// grid is expressed as offsets from that origin, which is the only way to
    /// hold an absolute grid without knowing the clock's `Instant` type: an
    /// `any Clock<Duration>` exposes `sleep(for:)` and nothing else, so the
    /// generic initialiser captures what it needs while the concrete type is
    /// still in scope — the same technique `IAX2Call` uses for its call clock.
    private let elapsedSinceOrigin: @Sendable () -> Duration

    /// Sleeps until `origin + offset` on the injected clock. Same trick, other
    /// direction.
    private let sleepUntilOffset: @Sendable (Duration) async throws -> Void

    // MARK: Session state

    private enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case shutDown
    }

    private var phase: Phase = .idle
    private var destination: IAX2Destination?
    private var transport: (any DatagramTransport)?
    private var call: IAX2Call?
    private var voice: IAX2VoiceStream?
    private var leveller: AudioLeveller

    private let allocator = IAX2CallNumberAllocator()
    private let watchdog: TransmitWatchdog

    private var readTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var playoutTask: Task<Void, Never>?

    /// The call time-stamp of the first frame of the current transmission
    /// (§8.1.1), and how many frames have gone out since. Outbound time-stamps
    /// are `base + index × frameInterval` rather than a fresh reading of the
    /// call clock per frame: "time-stamps MAY be approximate, but, MUST be in
    /// order" (§7), and a media grid derived from the media itself is both in
    /// order and jitter-free, which a wall-clock reading taken once per capture
    /// callback is not.
    private var transmitTimestampBase: UInt32 = 0
    private var transmitFrameIndex: UInt32 = 0

    /// The last inbound-media rejection reported, so a stream that cannot be
    /// decoded produces one event rather than fifty a second.
    private var lastReportedRejection: IAX2VoiceReceiver.Rejection?

    private nonisolated let stateBox = TransmitStateBox()
    private nonisolated let audioContinuation: AsyncStream<[Int16]>.Continuation
    private nonisolated let eventContinuation: AsyncStream<IAX2ClientEvent>.Continuation
    private nonisolated let radioEventContinuation: AsyncStream<RadioEvent>.Continuation

    // MARK: Init

    /// - Parameters:
    ///   - clock: `ContinuousClock()` in production; a manual clock under test.
    ///     Drives the playout tick, the transmit watchdog, the call's connect
    ///     deadline and the reliable channel's retransmission ladder — every
    ///     timer in the stack, so a test can run a whole session without one
    ///     real-time wait (AU-5).
    ///   - configuration: watchdog timeout, frame grid, jitter buffer, leveller.
    ///   - transportFactory: how to reach a destination. Defaults to UDP via
    ///     `NWDatagramTransport` (PD-1: `Network.framework`, never BSD sockets).
    public init<C: Clock>(
        clock: C = ContinuousClock(),
        configuration: Configuration = Configuration(),
        transportFactory: @escaping TransportFactory = IAX2Client.udpTransportFactory
    ) where C.Duration == Duration {
        self.configuration = configuration
        self.makeTransport = transportFactory
        self.leveller = configuration.leveller
        self.watchdog = TransmitWatchdog(clock: clock)

        let callConfiguration = configuration.call
        self.makeCall = { allocator, request, transport in
            try await IAX2Call.outbound(
                allocator: allocator,
                request: request,
                transport: transport,
                clock: clock,
                configuration: callConfiguration,
                // This client owns the read loop: see the type documentation,
                // and `IAX2Call`'s note that a client fanning one transport out
                // to several legs must demultiplex itself.
                readsTransport: false)
        }

        let origin = clock.now
        self.elapsedSinceOrigin = { origin.duration(to: clock.now) }
        self.sleepUntilOffset = { offset in
            try await clock.sleep(until: origin.advanced(by: offset), tolerance: nil)
        }

        var escapedAudio: AsyncStream<[Int16]>.Continuation!
        let audio = AsyncStream<[Int16]>(
            bufferingPolicy: .bufferingNewest(configuration.receivedAudioBufferedFrames)
        ) { continuation in
            escapedAudio = continuation
        }
        self.receivedAudio = audio
        self.audioContinuation = escapedAudio

        var escapedEvents: AsyncStream<IAX2ClientEvent>.Continuation!
        let events = AsyncStream<IAX2ClientEvent>(bufferingPolicy: .unbounded) { continuation in
            escapedEvents = continuation
        }
        self.events = events
        self.eventContinuation = escapedEvents

        var escapedRadioEvents: AsyncStream<RadioEvent>.Continuation!
        let radioEvents = AsyncStream<RadioEvent>(bufferingPolicy: .unbounded) { continuation in
            escapedRadioEvents = continuation
        }
        self.radioEvents = radioEvents
        self.radioEventContinuation = escapedRadioEvents
    }

    /// The production transport: UDP to the destination's host and port.
    public static let udpTransportFactory: TransportFactory = { destination in
        try NWDatagramTransport(host: destination.host, port: destination.port)
    }

    // MARK: Introspection

    /// Whether a call leg is up.
    public var isConnected: Bool { phase == .connected }

    /// The destination of the current (or most recent) call.
    public var currentDestination: IAX2Destination? { destination }

    /// The codec the node chose in its ACCEPT (§6.2.3), once it has.
    public var negotiatedFormat: MediaFormat? {
        get async { await call?.negotiatedFormat }
    }

    /// Our 15-bit source call number for the current leg (§8.1.1), for
    /// diagnostics.
    public var sourceCallNumber: UInt16? { call?.sourceCallNumber }

    /// Frames waiting in the inbound jitter buffer — how much audio is queued
    /// but not yet played. Diagnostic: a UI meter, a log line, or a test
    /// waiting for a replayed fixture to have landed before it advances the
    /// clock.
    public var queuedInboundFrameCount: Int {
        get async { await voice?.queuedFrameCount ?? 0 }
    }

    // MARK: - NetworkClient: connecting

    /// Places the call and returns when it is up (§6.2.2 → §6.3.4).
    ///
    /// NEW → [AUTHREQ → AUTHREP] → ACCEPT → ANSWER, all of it driven by
    /// `IAX2Call`; this method's own work is to stand up the transport, the
    /// read loop, the event pump and the playout tick around it, and to turn a
    /// failed setup into an error a user interface can show.
    ///
    /// The connect deadline is `IAX2Call`'s, measured on the injected clock. It
    /// is **not** re-implemented here, and in particular it is not built by
    /// racing an in-flight `transport.send` against a timeout: the
    /// `NWConnection` send-completion continuation is not cancellation-aware
    /// (RC-1), so cancelling a send in flight would leak a continuation on the
    /// exact path a connect timeout exercises.
    ///
    /// - Throws: ``IAX2ClientError/rejected(cause:causeCode:)`` on REJECT,
    ///   ``IAX2ClientError/connectTimedOut(_:)`` on the deadline,
    ///   ``IAX2ClientError/connectFailed(_:)`` for any other teardown during
    ///   setup, ``IAX2ClientError/alreadyConnected`` or
    ///   ``IAX2ClientError/clientShutDown`` for a misuse, or whatever the
    ///   transport factory threw.
    public func connect(to destination: IAX2Destination) async throws {
        switch phase {
        case .shutDown: throw IAX2ClientError.clientShutDown
        case .connecting, .connected: throw IAX2ClientError.alreadyConnected
        case .idle: break
        }

        phase = .connecting
        self.destination = destination
        lastReportedRejection = nil
        leveller = configuration.leveller

        let transport: any DatagramTransport
        do {
            transport = try makeTransport(destination)
        } catch {
            phase = .idle
            throw error
        }
        self.transport = transport

        let call: IAX2Call
        do {
            call = try await makeCall(allocator, destination.callRequest, transport)
        } catch {
            await releaseSession()
            throw error
        }
        self.call = call

        let voice = IAX2VoiceStream(
            call: call, format: .g711MuLaw, buffer: configuration.jitterBuffer)
        self.voice = voice

        // The event pump starts before the NEW goes out. `call.events` buffers
        // without limit from the moment the call is constructed, so nothing is
        // missed either way, but starting first means the ACCEPT's FORMAT IE
        // pins the codec before any media can be handled — the event stream is
        // ordered, and `.accepted` precedes every `.media`.
        startEventPump(call: call, voice: voice)

        do {
            try await call.start()

            // **The read loop starts only now, and that ordering is load-bearing.**
            //
            // `IAX2Call.start()` moves the FSM to `newSent` *after* awaiting the
            // write of the NEW, and an actor is reentrant across an await — so a
            // datagram delivered during that window would reach an FSM still in
            // `idle`, where an ACCEPT is an illegal transition and the call is
            // torn down as a protocol error. Not reading the transport until the
            // NEW has been written closes the window outright, and closes it for
            // free: `DatagramTransport.incoming` buffers without limit, so a
            // reply that arrives during the send is still delivered, in order,
            // the moment the loop starts.
            //
            // This is exactly the class of fault plan rule 10 exists for, and
            // `testConnectReturnsWhenTheCallComesUpDuringSend` is the test that
            // holds the ordering in place.
            startReadLoop(transport: transport)

            try await call.waitUntilUp()
        } catch {
            await releaseSession()
            throw Self.connectError(error)
        }

        // Re-checked after the awaits: an actor is reentrant, so the call could
        // have been torn down (a HANGUP, a closed transport) between coming up
        // and this line.
        guard phase == .connecting else {
            let reason = await call.termination
            throw IAX2ClientError.connectFailed(reason ?? .closed)
        }
        phase = .connected
        setState(.receiving)
        startPlayout()
        emit(.connected(format: await call.negotiatedFormat))
    }

    /// Hangs up, tears everything down and **finishes ``receivedAudio`` and
    /// ``events``**.
    ///
    /// Terminal, and idempotent. A finished `AsyncStream` cannot be reopened,
    /// so a client is done once this returns; build a new one to reconnect.
    /// That is the price of the guarantee the application layer actually needs
    /// — that its `for await` loops end, rather than hanging forever on a
    /// client nobody will ever feed again.
    ///
    /// The HANGUP is best-effort: §6.2.5 destroys the leg the moment it is
    /// written, and a node that has already gone away is owed nothing.
    public func disconnect() async {
        guard phase != .shutDown else { return }
        if let call, await call.state.isLive {
            try? await call.hangup()
        }
        await releaseSession()
        phase = .shutDown
        setState(.idle)
        audioContinuation.finish()
        eventContinuation.finish()
        radioEventContinuation.finish()
    }

    // MARK: - NetworkClient: transmitting

    /// Keys up: arms the transmit watchdog and starts a fresh media grid.
    ///
    /// **SF-1.** The watchdog is armed *before* ``state`` becomes
    /// `.transmitting`, so there is no window in which audio can be sent
    /// without a deadline attached to it. On expiry it calls
    /// ``stopTransmit()`` itself and emits
    /// ``IAX2ClientEvent/transmitWatchdogExpired(_:)``. A stuck PTT cannot hold
    /// a repeater open.
    ///
    /// Idempotent while already transmitting — it does **not** re-arm the
    /// watchdog, because a caller that re-keys on every audio frame would
    /// otherwise push the deadline out forever and the watchdog would never
    /// fire at all.
    ///
    /// - Throws: ``IAX2ClientError/notConnected`` without a live call.
    public func startTransmit() async throws {
        guard phase == .connected, let call else { throw IAX2ClientError.notConnected }
        if case .transmitting = state { return }

        let base = await call.timestampMilliseconds
        let timeout = configuration.transmitTimeout
        await watchdog.start(timeout: timeout) { [weak self] in
            await self?.transmitWatchdogExpired(after: timeout)
        }

        // Re-checked after the awaits, for the same reentrancy reason as
        // `connect`: a teardown could have run while we were suspended, and
        // transmitting on a released session would be a lie in the UI.
        guard phase == .connected else {
            await watchdog.cancel()
            throw IAX2ClientError.notConnected
        }

        transmitTimestampBase = base
        transmitFrameIndex = 0
        setState(.transmitting(since: Date()))
        emit(.transmitting)
    }

    /// Unkeys: disarms the watchdog and returns to receive. Idempotent, and
    /// safe on a client that is not connected — SF-3 (audio interruption) and
    /// SF-2 (BLE accessory loss) both call this from paths that cannot know the
    /// current state.
    public func stopTransmit() async {
        await watchdog.cancel()
        guard case .transmitting = state else { return }
        setState(phase == .connected ? .receiving : .idle)
        emit(.receiving)
    }

    /// Sends one 20 ms frame of captured audio.
    ///
    /// The first frame of a stream — and every frame whose time-stamp crosses a
    /// `0x8000` boundary — goes out as a **full Voice frame** carrying the
    /// codec in its subclass; the rest go as Mini Frames (§8.1.2, §6.10). That
    /// decision belongs to `IAX2VoiceTransmitter` and is not re-made here.
    ///
    /// - Parameter pcm: exactly 160 samples of 8 kHz signed 16-bit mono.
    /// - Returns: what went on the wire, or `nil` if the client is not
    ///   transmitting. **Not transmitting is not an error**: a capture pipeline
    ///   runs continuously and hands over every frame it produces, and it is
    ///   this client's job — not the microphone's — to know that PTT is
    ///   released. Silently dropping is also the fail-safe direction: the
    ///   failure mode of a mistake here is dead air, not an open microphone.
    /// - Throws: whatever the codec or the call throws — a wrong frame length,
    ///   or a leg that died between the check and the write.
    @discardableResult
    public func transmit(pcm: [Int16]) async throws -> IAX2VoiceFrame? {
        guard case .transmitting = state, let voice else { return nil }
        let step = UInt32(Self.milliseconds(configuration.frameInterval))
        let timestamp = transmitTimestampBase &+ transmitFrameIndex &* step
        transmitFrameIndex &+= 1
        return try await voice.send(pcm: pcm, timestamp: timestamp)
    }

    /// `NetworkClient`'s transmit seam: ``transmit(pcm:)``, with the frame
    /// discarded.
    ///
    /// Two methods rather than one because a witness may not return a value the
    /// requirement does not — and the requirement should not, since
    /// `IAX2VoiceFrame` is exactly the RFC 5456 detail the seam exists to keep
    /// out of an application. Anything that wants to know what went on the wire
    /// (the CLI counts frames that reached it) calls ``transmit(pcm:)``.
    public func send(pcm: [Int16]) async throws {
        _ = try await transmit(pcm: pcm)
    }

    /// Sends one DTMF digit (§8.2.1, FR-1.5) — how an AllStar node is commanded
    /// once connected.
    ///
    /// Unlike ``send(pcm:)`` this does not require PTT: DTMF is signalling, and
    /// it travels as a reliable full frame rather than as audio.
    public func send(dtmf digit: Character) async throws {
        guard phase == .connected, let voice else { throw IAX2ClientError.notConnected }
        try await voice.send(dtmf: digit)
    }

    /// Sends a string of DTMF digits, one frame each, in order.
    public func send(dtmfSequence digits: String) async throws {
        guard phase == .connected, let voice else { throw IAX2ClientError.notConnected }
        _ = try await voice.send(dtmfSequence: digits)
    }

    // MARK: - The read loop (and the IAX-8b seam)

    private func startReadLoop(transport: any DatagramTransport) {
        guard readTask == nil else { return }
        let incoming = transport.incoming
        readTask = Task { [weak self] in
            for await datagram in incoming {
                guard let self else { return }
                await self.handleInbound(datagram)
            }
            await self?.transportFinished()
        }
    }

    /// One received datagram.
    ///
    /// **This is the IAX-8b seam.** Today every datagram goes to the call leg,
    /// whose own demultiplexer decides whether it is addressed to us and
    /// answers anything that is not with INVAL (§6.9.2). A registration
    /// exchange (FR-1.3: REGREQ → REGAUTH → REGREQ → REGACK, §6.1) shares the
    /// same UDP association and would be dispatched here, ahead of the call, by
    /// its own source/destination call-number pair — which is exactly why this
    /// client owns the read loop instead of letting `IAX2Call` run it:
    /// `DatagramTransport.incoming` is single-consumer, so whoever iterates it
    /// first excludes everyone else.
    private func handleInbound(_ datagram: Data) async {
        guard let call else { return }
        do {
            _ = try await call.deliver(datagram: datagram)
        } catch {
            // The peer broke a rule the FSM enforces — a Control frame before
            // the ACCEPT, say (§6.3.1). §6.6 forbids "other indications over
            // the errant IAX call leg", so the leg is destroyed silently.
            await call.close()
        }
    }

    private func transportFinished() async {
        readTask = nil
        guard phase == .connecting || phase == .connected else { return }
        await releaseSession()
        emit(.disconnected(nil))
    }

    // MARK: - The event pump

    /// Drains `call.events` into `IAX2VoiceStream` — the other half of the seam
    /// IAX-6/IAX-7 left, the first half being the playout tick.
    private func startEventPump(call: IAX2Call, voice: IAX2VoiceStream) {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            for await event in call.events {
                guard let self else { return }
                await self.handle(event, voice: voice)
            }
        }
    }

    private func handle(_ event: IAX2CallEvent, voice: IAX2VoiceStream) async {
        if let interpreted = await voice.handle(event) {
            switch interpreted {
            case .dtmf(let digit):
                emit(.dtmf(digit))
            case .audioRejected(let rejection):
                // §6.9.3 says a VNAK "is sent when a message is received out of
                // order, particularly when a Mini Frame is received before the
                // first full voice frame on a call", and IAX-6 left that seam
                // open for this client to wire up. It is deliberately left
                // unwired, for three reasons.
                //
                // A VNAK carries exactly one piece of meaning: its ISeqno, on
                // receipt of which "a peer MUST retransmit all frames with a
                // higher sequence number" (§6.9.3). A Mini Frame has no
                // sequence number at all (§8.1.2), so the VNAK we could send
                // here would name our current inbound counter and ask the node
                // to retransmit *signalling* frames it has already delivered —
                // a retransmission burst that cannot possibly produce the full
                // Voice frame we are actually missing, because that frame is
                // not outstanding at the peer. Mini Frames themselves are
                // unreliable and are never retransmitted.
                //
                // The condition is also self-correcting and, in practice,
                // nearly unreachable: the ACCEPT's FORMAT IE pins the codec
                // (§6.2.3), and §6.10 requires the node to send a full Voice
                // frame at every 0x8000 boundary regardless. At fifty frames a
                // second an un-pinned stream would emit fifty VNAKs a second,
                // each provoking retransmissions — so wiring it up would need a
                // throttling policy the RFC does not describe.
                //
                // So the frame is dropped, as IAX-6 already had it, and the
                // condition is *reported* instead: once per change of reason,
                // where an operator or a log can see it.
                if lastReportedRejection != rejection {
                    lastReportedRejection = rejection
                    emit(.mediaRejected(rejection))
                }
            case .audioQueued:
                lastReportedRejection = nil
            case .formatNegotiated:
                break
            }
        }

        if case .ended(let reason) = event {
            await callEnded(reason)
        }
    }

    private func callEnded(_ reason: IAX2CallTermination) async {
        guard phase == .connecting || phase == .connected else { return }
        await releaseSession()
        emit(.disconnected(reason))
    }

    // MARK: - The 20 ms playout tick

    /// Starts the media grid. See the type documentation for why it is absolute
    /// and why it resynchronises rather than catching up.
    private func startPlayout() {
        guard playoutTask == nil else { return }
        let interval = configuration.frameInterval
        let maximumLag = configuration.maximumPlayoutLag
        let elapsed = elapsedSinceOrigin
        let sleepUntil = sleepUntilOffset

        playoutTask = Task { [weak self] in
            var next = elapsed() + interval
            while !Task.isCancelled {
                do {
                    try await sleepUntil(next)
                } catch {
                    return  // Cancelled: the session is over.
                }
                guard let self else { return }
                await self.playoutTick()

                next += interval
                let now = elapsed()
                if next + maximumLag < now {
                    // Too far behind to be worth replaying. Re-anchor the grid.
                    next = now + interval
                }
            }
        }
    }

    private func playoutTick() async {
        guard phase == .connected, let voice else { return }
        var pcm = await voice.pop().pcm
        // AU-4: the same leveller instance across the whole session, because
        // its gain trajectory is the point — a per-frame leveller would be an
        // expensive way to do nothing.
        leveller.process(&pcm)
        audioContinuation.yield(pcm)
    }

    // MARK: - The transmit watchdog (SF-1)

    private func transmitWatchdogExpired(after timeout: Duration) async {
        guard case .transmitting = state else { return }
        await stopTransmit()
        emit(.transmitWatchdogExpired(timeout))
    }

    // MARK: - Teardown

    /// Stops every task, closes the call and the transport, and returns the
    /// client to `.idle`. Does **not** finish the public streams — that is
    /// ``disconnect()``'s doing, and only ``disconnect()``'s, so a call that
    /// ends remotely can still be reported to a listening application.
    private func releaseSession() async {
        playoutTask?.cancel()
        playoutTask = nil
        eventTask?.cancel()
        eventTask = nil
        readTask?.cancel()
        readTask = nil

        await watchdog.cancel()
        if let call { await call.close() }
        call = nil
        voice = nil
        if let transport { await transport.close() }
        transport = nil

        phase = .idle
        setState(.idle)
    }

    // MARK: - Small helpers

    private func setState(_ next: TransmitState) {
        stateBox.value = next
    }

    /// The one place events leave this client, so ``events`` and ``radioEvents``
    /// cannot drift apart or disagree on ordering.
    private func emit(_ event: IAX2ClientEvent) {
        eventContinuation.yield(event)
        if let radio = event.radioEvent { radioEventContinuation.yield(radio) }
    }

    /// Turns a call-setup failure into something an application can show.
    private static func connectError(_ error: Error) -> Error {
        guard let ended = error as? IAX2CallEnded else { return error }
        switch ended.reason {
        case .rejected(let cause, let causeCode):
            return IAX2ClientError.rejected(cause: cause, causeCode: causeCode)
        case .connectTimedOut(let timeout):
            return IAX2ClientError.connectTimedOut(timeout)
        default:
            return IAX2ClientError.connectFailed(ended.reason)
        }
    }

    /// Whole milliseconds in a `Duration`. Media grids are expressed in
    /// milliseconds on the wire (§8.1.1), so this is where the two meet.
    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}

// `TransmitStateBox` now lives in RadioCore, so M17Client can use it too
// (M17-5). It was always a RadioCore concern — it guards a `TransmitState`.
