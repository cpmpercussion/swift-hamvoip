// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Destination

/// Where to connect, and how to get there.
public struct EchoLinkDestination: Sendable, Equatable {
    /// How the session reaches the far end.
    ///
    /// **FR-3.3 makes the proxy the default on cellular**, because direct mode
    /// is unusable behind CGNAT — which is the app's main target. Direct mode
    /// stays reachable because it is the better path when it works: one less
    /// hop, one less party.
    public enum Route: Sendable, Equatable {
        /// Through an EchoLink proxy on TCP 8100. The default.
        case proxy(host: String, port: UInt16, password: EchoLinkProxyPassword)

        /// Straight to the peer. Requires inbound UDP 5198/5199 to arrive,
        /// which is exactly what a carrier-grade NAT prevents.
        case direct
    }

    /// The peer's address. On a proxied session this is what goes in the
    /// `OPEN` frame's peer field.
    public let peer: EchoLinkPeerAddress

    /// The node being called, for display and logging. `*ECHOTEST*` is the
    /// obvious first contact: it echoes audio back, so one operator alone can
    /// confirm a round trip.
    public let node: String

    public let route: Route

    public init(
        peer: EchoLinkPeerAddress,
        node: String,
        route: Route = .proxy(
            host: "",
            port: EchoLinkProxyClient.defaultPort,
            password: .publicProxy
        )
    ) {
        self.peer = peer
        self.node = node
        self.route = route
    }

    /// Whether this destination goes through a proxy.
    public var isProxied: Bool {
        if case .proxy = route { return true }
        return false
    }
}

// MARK: - Errors and events

public enum EchoLinkClientError: Error, Equatable, CustomStringConvertible {
    case alreadyConnected
    case notConnected
    /// Direct mode is not implemented. See the note on `EchoLinkClient`.
    case directModeUnavailable
    case proxy(EchoLinkProxyError)

    public var description: String {
        switch self {
        case .alreadyConnected: return "already connected"
        case .notConnected: return "not connected"
        case .directModeUnavailable:
            return "direct (non-proxied) EchoLink is not implemented — "
                + "no capture of a direct session exists to build it against"
        case .proxy(let error): return "proxy: \(error)"
        }
    }
}

/// Session events, in the shape `M17ClientEvent` already established.
public enum EchoLinkClientEvent: Sendable, Equatable {
    case connecting
    case connected(node: String)
    case disconnected(reason: String)
    case transmitting
    case receiving
    /// A new inbound talkspurt began — someone else started speaking.
    case talkspurtStarted
    /// Station info arrived on the audio channel (the `oNDATA` text).
    case stationInfo(String)
    /// The transmit watchdog cut transmission (SF-1).
    case transmitTimedOut(after: Duration)
}

// MARK: - Client

/// EchoLink as the app sees it (FR-3.1, FR-3.2, FR-3.3).
///
/// The same shape as `IAX2Client` and `M17Client`: a `NetworkClient` actor with
/// a `nonisolated var state` over a `TransmitStateBox`, the four required
/// methods, a `Configuration`, a `TransportFactory`, `receivedAudio` and
/// `events`, and an `init<C: Clock>` so tests are deterministic.
///
/// Nothing in `RadioCore` needed to change to add this mode, which is the
/// architectural claim the layering makes: if the app ever needs an
/// EchoLink-specific type, that is `NetworkClient` missing a capability and the
/// fix belongs in the library.
///
/// ## The codec is injected
///
/// `EchoLinkClient` is written against `RadioCore.VoiceCodec` and never names
/// GSM. This follows the precedent `M17Client` set for Codec2: the sequencing,
/// the packing and the watchdog are all testable with a stub codec, so they are
/// covered whether or not the real codec is present. Production passes
/// `GSMVoiceCodec` (EL-8).
///
/// ## Direct mode is declared, not implemented
///
/// `Route.direct` exists in the type because FR-3.3 requires direct mode to
/// remain reachable, and leaving it out of the model would make adding it a
/// breaking change. It currently throws `.directModeUnavailable`, and that is
/// deliberate: **no capture of a direct session exists.** Every protocol fact
/// this module has came from proxied traffic, where the proxy frames carry the
/// UDP payloads verbatim — strip the 9-byte header and what remains is
/// byte-for-byte what direct mode would put on the wire. So the *framing* is
/// known; what is unobserved is the port assignment and the socket setup, and
/// building that from the plausible reading rather than from evidence is
/// exactly what this module's clean-room position forbids. It is a small,
/// well-understood gap, not a hole — see the OQ-9 write-up.
public actor EchoLinkClient: NetworkClient {
    public typealias Destination = EchoLinkDestination

    // MARK: Configuration

    public struct Configuration: Sendable {
        /// Transmit watchdog timeout (SF-1). The safety requirement lives here
        /// in the library, not in the app.
        public var transmitTimeout: Duration
        /// One codec frame — the playout tick. 20 ms.
        public var frameInterval: Duration
        /// The operator's callsign, for the proxy login and the directory.
        public var callsign: String
        /// The inbound jitter buffer (AU-3).
        public var jitterBuffer: JitterBuffer
        /// The received-audio leveller (RC-6/AU-4).
        public var leveller: AudioLeveller

        public init(
            callsign: String,
            transmitTimeout: Duration = .seconds(180),
            frameInterval: Duration = .milliseconds(20),
            jitterBuffer: JitterBuffer = JitterBuffer(),
            leveller: AudioLeveller = AudioLeveller()
        ) {
            self.callsign = callsign
            self.transmitTimeout = transmitTimeout
            self.frameInterval = frameInterval
            self.jitterBuffer = jitterBuffer
            self.leveller = leveller
        }
    }

    /// How a stream transport is made. Tests inject `MockStreamTransport`;
    /// nothing here opens a socket itself (AU-5).
    public typealias TransportFactory =
        @Sendable (EchoLinkDestination) throws -> any StreamTransport

    // MARK: Public surface

    /// Levelled 8 kHz mono PCM, one 20 ms frame per tick. Finished by
    /// ``disconnect()``.
    public nonisolated let receivedAudio: AsyncStream<[Int16]>

    /// Session events.
    public nonisolated let events: AsyncStream<EchoLinkClientEvent>

    public nonisolated var state: TransmitState { stateBox.value }

    // MARK: Injected

    private let configuration: Configuration
    private let codec: any VoiceCodec
    private let makeTransport: TransportFactory
    private let makeProxyClient:
        @Sendable (String, EchoLinkProxyPassword, any StreamTransport) -> EchoLinkProxyClient

    // MARK: Session state

    private enum Phase: Sendable, Equatable {
        case idle, connecting, connected
    }

    private var phase: Phase = .idle
    private var destination: EchoLinkDestination?
    private var transport: (any StreamTransport)?
    private var proxy: EchoLinkProxyClient?

    private var inbound = EchoLinkStreamAudio()
    private var transmitter = EchoLinkStreamTransmitter()
    private var buffer: JitterBuffer
    private var leveller: AudioLeveller

    private let watchdog: TransmitWatchdog
    private var frameTask: Task<Void, Never>?
    private var playoutTask: Task<Void, Never>?

    private nonisolated let stateBox = TransmitStateBox()
    private nonisolated let audioContinuation: AsyncStream<[Int16]>.Continuation
    private nonisolated let eventContinuation: AsyncStream<EchoLinkClientEvent>.Continuation

    // MARK: Init

    /// - Parameters:
    ///   - codec: the voice codec. `GSMVoiceCodec` in production; tests pass a
    ///     stub, which is what keeps this type compiling and covered on a
    ///     checkout without the vendored codec (EL-8).
    ///   - clock: drives the watchdog and the playout tick.
    public init<C: Clock>(
        codec: any VoiceCodec,
        configuration: Configuration,
        clock: C,
        transportFactory: @escaping TransportFactory = EchoLinkClient.tcpTransportFactory,
        proxyClientFactory: (
            @Sendable (String, EchoLinkProxyPassword, any StreamTransport) -> EchoLinkProxyClient
        )? = nil
    ) where C.Duration == Duration {
        self.codec = codec
        self.configuration = configuration
        self.buffer = configuration.jitterBuffer
        self.leveller = configuration.leveller
        self.makeTransport = transportFactory
        self.watchdog = TransmitWatchdog(clock: clock)

        let sendableClock = clock
        self.makeProxyClient =
            proxyClientFactory
            ?? { callsign, password, transport in
                EchoLinkProxyClient(
                    callsign: callsign,
                    password: password,
                    transport: transport,
                    clock: sendableClock
                )
            }

        var escapedAudio: AsyncStream<[Int16]>.Continuation!
        self.receivedAudio = AsyncStream { escapedAudio = $0 }
        self.audioContinuation = escapedAudio

        var escapedEvents: AsyncStream<EchoLinkClientEvent>.Continuation!
        self.events = AsyncStream { escapedEvents = $0 }
        self.eventContinuation = escapedEvents
    }

    /// The real transport (PD-1). Never used by a unit test.
    public static let tcpTransportFactory: TransportFactory = { destination in
        guard case .proxy(let host, let port, _) = destination.route else {
            throw EchoLinkClientError.directModeUnavailable
        }
        return try NWStreamTransport(host: host, port: port)
    }

    // MARK: Introspection

    public var isConnected: Bool { phase == .connected }
    public var currentDestination: EchoLinkDestination? { destination }
    public var queuedInboundFrameCount: Int { buffer.queuedFrameCount }

    // MARK: - NetworkClient: connecting

    /// Logs in to the proxy, opens a channel to the peer, and starts the audio
    /// path.
    public func connect(to destination: EchoLinkDestination) async throws {
        guard phase == .idle else { throw EchoLinkClientError.alreadyConnected }
        guard case .proxy(_, _, let password) = destination.route else {
            throw EchoLinkClientError.directModeUnavailable
        }

        phase = .connecting
        self.destination = destination
        emit(.connecting)

        let transport: any StreamTransport
        do {
            transport = try makeTransport(destination)
        } catch {
            await releaseSession()
            throw error
        }
        self.transport = transport

        let proxy = makeProxyClient(configuration.callsign, password, transport)
        self.proxy = proxy

        do {
            try await proxy.login()
            try await proxy.open(peer: destination.peer)
        } catch let error as EchoLinkProxyError {
            await releaseSession()
            throw EchoLinkClientError.proxy(error)
        } catch {
            await releaseSession()
            throw error
        }

        phase = .connected
        setState(.receiving)
        startFramePump(proxy: proxy)
        startPlayoutLoop()
        emit(.connected(node: destination.node))
    }

    /// Drops the session, stops the audio path and finishes the public streams.
    public func disconnect() async {
        let wasActive = phase != .idle
        await releaseSession()
        if wasActive { emit(.disconnected(reason: "local request")) }
        audioContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: - NetworkClient: transmitting

    /// Keys up: arms the watchdog (SF-1) and starts a new over.
    ///
    /// The watchdog is armed **before** `state` becomes `.transmitting`, so
    /// there is no window in which audio goes out with no deadline attached.
    /// Idempotent while already transmitting, and deliberately does not re-arm:
    /// a caller re-keying per frame would push the deadline out forever, which
    /// defeats the requirement.
    public func startTransmit() async throws {
        guard phase == .connected else { throw EchoLinkClientError.notConnected }
        if case .transmitting = state { return }

        let timeout = configuration.transmitTimeout
        await watchdog.start(timeout: timeout) { [weak self] in
            await self?.transmitWatchdogExpired(after: timeout)
        }

        guard phase == .connected else {
            await watchdog.cancel()
            throw EchoLinkClientError.notConnected
        }

        transmitter.reset()
        setState(.transmitting(since: Date()))
        emit(.transmitting)
    }

    /// Unkeys. Idempotent, and safe when not connected — SF-2 and SF-3 both
    /// call this from paths that cannot know the current state.
    ///
    /// Flushes any part-filled packet, so the last 60 ms of an over is not
    /// clipped.
    public func stopTransmit() async {
        await watchdog.cancel()
        guard case .transmitting = state else { return }

        if phase == .connected, let packet = transmitter.flush() {
            try? await sendAudio(packet)
        }
        transmitter.reset()

        setState(phase == .connected ? .receiving : .idle)
        emit(.receiving)
    }

    /// Offers one 20 ms frame of captured audio.
    ///
    /// Four of these make one packet, so this returns `nil` on three calls in
    /// four even while transmitting — that is the 80 ms packing, not a failure.
    ///
    /// **Not transmitting is not an error.** A capture pipeline runs
    /// continuously and hands over every frame it makes; knowing PTT is
    /// released is this client's job, and dropping silently is the fail-safe
    /// direction — the failure mode is dead air, not an open microphone.
    @discardableResult
    public func send(pcm: [Int16]) async throws -> EchoLinkRTPPacket? {
        guard case .transmitting = state, phase == .connected else { return nil }
        guard pcm.count == codec.samplesPerFrame else {
            throw EchoLinkClientError.notConnected
        }

        let encoded = try codec.encode(pcm)
        guard let packet = transmitter.push(encoded) else { return nil }
        try await sendAudio(packet)
        return packet
    }

    private func sendAudio(_ packet: EchoLinkRTPPacket) async throws {
        guard let proxy, let destination else { return }
        try await proxy.send(
            EchoLinkProxyFrame(
                type: .udpData,
                peer: destination.peer,
                payload: packet.encoded
            )
        )
    }

    // MARK: - Inbound

    private func startFramePump(proxy: EchoLinkProxyClient) {
        guard frameTask == nil else { return }
        let incoming = proxy.frames
        frameTask = Task { [weak self] in
            for await frame in incoming {
                guard let self else { return }
                await self.handle(frame)
            }
            await self?.linkFinished()
        }
    }

    private func handle(_ frame: EchoLinkProxyFrame) {
        switch frame.type {
        case .udpData:
            switch EchoLinkAudioChannelMessage.classify(frame.payload) {
            case .audio(let packet):
                let reception = inbound.receive(packet)
                if reception.isNewTalkspurt { emit(.talkspurtStarted) }
                for timed in reception.frames { buffer.push(timed) }
            case .stationInfo(let text):
                emit(.stationInfo(text))
            case .unrecognised:
                break
            }
        case .close:
            Task { [weak self] in await self?.linkFinished() }
        default:
            // 0x06 control frames are observed but not decoded past their
            // outer shape, and nothing on the path to a QSO needs them.
            break
        }
    }

    private func linkFinished() async {
        guard phase != .idle else { return }
        await releaseSession()
        emit(.disconnected(reason: "the link closed"))
    }

    // MARK: - Playout

    private func startPlayoutLoop() {
        guard playoutTask == nil else { return }
        let interval = configuration.frameInterval
        playoutTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.playoutTick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func playoutTick() {
        guard phase == .connected else { return }
        switch buffer.pop() {
        case .frame(let payload):
            guard var pcm = try? codec.decode(payload) else { return }
            leveller.process(&pcm)  // RC-6/AU-4, in place
            audioContinuation.yield(pcm)
        case .concealment, .silence:
            break
        }
    }

    // MARK: - Watchdog (SF-1)

    private func transmitWatchdogExpired(after timeout: Duration) async {
        guard case .transmitting = state else { return }
        await stopTransmit()
        emit(.transmitTimedOut(after: timeout))
    }

    // MARK: - Teardown

    private func releaseSession() async {
        frameTask?.cancel()
        frameTask = nil
        playoutTask?.cancel()
        playoutTask = nil

        await watchdog.cancel()
        await proxy?.close()
        proxy = nil
        await transport?.close()
        transport = nil

        phase = .idle
        destination = nil
        inbound.reset()
        transmitter.reset()
        buffer.reset()
        setState(.idle)
    }

    // MARK: - Plumbing

    private func setState(_ new: TransmitState) {
        stateBox.value = new
    }

    private func emit(_ event: EchoLinkClientEvent) {
        eventContinuation.yield(event)
    }
}
