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
    /// The directory server refused the login, or never answered.
    case directory(EchoLinkDirectoryError)
    /// A directory login was asked for without both the things it needs.
    case directoryLoginIncomplete
    /// The node never answered the SDES that opens a session.
    case nodeDidNotAnswer
    /// `send(pcm:)` was handed something other than one codec frame.
    case wrongSampleCount(expected: Int, actual: Int)
    /// The station list would not parse, or never finished arriving.
    case stationList(EchoLinkStationListError)
    /// A second `fetchStationList` while one is already running.
    case stationListInFlight

    public var description: String {
        switch self {
        case .alreadyConnected: return "already connected"
        case .notConnected: return "not connected"
        case .directModeUnavailable:
            return "direct (non-proxied) EchoLink is not implemented — "
                + "no capture of a direct session exists to build it against"
        case .proxy(let error): return "proxy: \(error)"
        case .directory(let error): return "directory: \(error)"
        case .directoryLoginIncomplete:
            return "a directory login needs both an account password and a "
                + "directory server address"
        case .nodeDidNotAnswer:
            return "the node did not answer — no reply to the SDES that opens a session"
        case .wrongSampleCount(let expected, let actual):
            return "expected one codec frame of \(expected) samples, got \(actual)"
        case .stationList(let error): return "station list: \(error)"
        case .stationListInFlight: return "a station list download is already running"
        }
    }
}

/// Session events, in the shape `M17ClientEvent` already established.
public enum EchoLinkClientEvent: Sendable, Equatable {
    case connecting
    /// The directory server accepted our account login.
    case directoryLoggedIn
    /// The node answered the SDES, identifying itself.
    case nodeAnswered(name: String)
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

        /// How far the playout grid may fall behind before it re-anchors
        /// instead of sprinting to catch up.
        public var maximumPlayoutLag: Duration
        /// The operator's callsign, for the proxy login and the directory.
        public var callsign: String

        /// Shown to the far end in the SDES `NAME` item, alongside the
        /// callsign.
        public var operatorName: String

        /// How this client identifies itself in the SDES `TOOL` item.
        ///
        /// Observed values are `EchoHam2.31` and `thebridge V 0.81`. Whether
        /// any peer keys on this is unknown, so we send our own name rather
        /// than impersonating a client we are not.
        public var tool: String

        /// The short location string shown beside the callsign in the
        /// directory listing — the observed client sent a three-letter code.
        public var location: String

        /// The version this client reports in the directory's `ONLINE` line.
        public var directoryVersion: String

        /// The operator's own EchoLink account password (FR-3.4).
        ///
        /// `nil` skips the directory login. See the note on `connect(to:)` for
        /// what that costs.
        public var accountPassword: EchoLinkAccountPassword?

        /// The directory server's address, for the `OPEN` that tunnels the
        /// account login to it.
        ///
        /// Deliberately has **no default**. The proxy's `OPEN` carries a raw
        /// IPv4 address and nothing here resolves DNS, so a default would mean
        /// hardcoding one operator's choice of a third party's server into the
        /// library. It is configuration.
        public var directoryServer: EchoLinkPeerAddress?

        /// How long to wait for the node to answer the opening SDES.
        ///
        /// The captures show a reply about 1.5 s in, after one retransmit, so
        /// the default is generous rather than tight.
        public var nodeAnswerTimeout: Duration

        /// How often to resend the opening SDES while waiting.
        ///
        /// The observed client resent at ~0.8 s.
        public var nodeAnswerRetryInterval: Duration
        /// The inbound jitter buffer (AU-3).
        public var jitterBuffer: JitterBuffer
        /// The received-audio leveller (RC-6/AU-4).
        public var leveller: AudioLeveller

        public init(
            callsign: String,
            operatorName: String = "",
            tool: String = "swift-hamvoip",
            location: String = "",
            directoryVersion: String = "0.1",
            accountPassword: EchoLinkAccountPassword? = nil,
            directoryServer: EchoLinkPeerAddress? = nil,
            transmitTimeout: Duration = .seconds(180),
            frameInterval: Duration = .milliseconds(20),
            maximumPlayoutLag: Duration = .milliseconds(200),
            nodeAnswerTimeout: Duration = .seconds(15),
            nodeAnswerRetryInterval: Duration = .milliseconds(800),
            jitterBuffer: JitterBuffer = EchoLinkClient.defaultJitterBuffer,
            leveller: AudioLeveller = AudioLeveller()
        ) {
            self.callsign = callsign
            self.operatorName = operatorName
            self.tool = tool
            self.location = location
            self.directoryVersion = directoryVersion
            self.accountPassword = accountPassword
            self.directoryServer = directoryServer
            self.transmitTimeout = transmitTimeout
            self.frameInterval = frameInterval
            self.maximumPlayoutLag = maximumPlayoutLag
            self.nodeAnswerTimeout = nodeAnswerTimeout
            self.nodeAnswerRetryInterval = nodeAnswerRetryInterval
            self.jitterBuffer = jitterBuffer
            self.leveller = leveller
        }
    }

    /// A jitter buffer sized for **proxied** EchoLink, from measurement.
    ///
    /// `JitterBuffer()`'s own 60 ms default target is less than one 80 ms
    /// EchoLink packet, so it drains to empty between packets. But sizing for
    /// one packet is not enough either, and the reason is worth stating because
    /// it is a property of the transport rather than of the protocol:
    ///
    /// **The proxy tunnels UDP inside TCP, and TCP bunches it.** Measured on a
    /// live 65-second `*ECHOTEST*` session (`m3-working.pcap`, 339 audio
    /// packets, **zero loss in either direction**):
    ///
    ///     inter-arrival gap    p50 0 ms   p90 184 ms   p99 248 ms   max 375 ms
    ///     worst shortfall against a steady 20 ms grid    265 ms
    ///
    /// A median gap of zero with a p90 of 184 ms is the signature of arrivals
    /// in bursts: several packets land together, then nothing for a sixth of a
    /// second. Nothing is lost — it is all late, together. So the buffer has to
    /// absorb the burst, and 265 ms is the depth that session actually
    /// demanded.
    ///
    /// Hence 280 ms initial target: above the worst observed shortfall, with
    /// the ceiling high enough for the largest outlier. The buffer adapts
    /// within that range, so a kinder path settles lower on its own.
    ///
    /// The **floor is 240 ms**, not two packets. Adaptation may drive the
    /// target down to the floor, and a floor below the arrival rhythm starves
    /// on every clump: measured bunching reaches 218 ms on one session and
    /// 375 ms on another, so anything under about 240 ms is below the p99 of
    /// normal delivery on a tunnelled path.
    ///
    /// These are tuning values, not protocol facts, and they buy latency to
    /// pay for continuity. A direct (non-proxied) path would not need them —
    /// which is an argument for direct mode, not against this default.
    public static let defaultJitterBuffer = JitterBuffer(
        frameDuration: .milliseconds(20),
        targetDepth: .milliseconds(280),
        minDepth: .milliseconds(240),
        maxDepth: .milliseconds(500))

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

    // An existential `any Clock` cannot be used generically, so the two things
    // this type needs from the clock are captured as closures at init — the
    // same shape `M17Client` uses, and for the same reason.
    private let elapsedSinceOrigin: @Sendable () -> Duration
    private let sleepFor: @Sendable (Duration) async throws -> Void
    private let sleepUntilOffset: @Sendable (Duration) async throws -> Void
    private let makeDirectorySession:
        @Sendable (String, String, String, @escaping EchoLinkDirectorySession.Send)
            -> EchoLinkDirectorySession
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
    /// Live only while a directory login is in flight, so a stray `0x02`
    /// outside that window is ignored rather than fed to a finished session.
    private var directory: EchoLinkDirectorySession?

    /// Station-list download state (EL-11). The in-flight flag is its own
    /// state rather than `stationListReader != nil`, for the reason the whole
    /// module repeats: the frame pump writes the reader, so inferring "is a
    /// download running?" from something the completion path also touches is
    /// the actor-reentrancy hazard this tree has already paid for once.
    private var stationListInFlight = false
    private var stationListReader: EchoLinkStationListReader?
    private var stationListResult: Result<EchoLinkStationList, Error>?

    /// True while `openNodeSession` is waiting. As everywhere else in this
    /// module, the in-flight flag is its own state and not inferred from
    /// `phase`, which the frame pump also writes.
    private var awaitingNodeAnswer = false
    /// Set once the node has said anything at all.
    private var nodeAnswer: String?

    /// True from the moment a teardown is claimed until it finishes. Its own
    /// flag rather than a reading of `phase`, because `releaseSession` has to
    /// suspend part-way through and two callers must not both get in.
    private var isReleasing = false

    /// The last frame decoded from real audio, repeated (and faded) to cover a
    /// gap. `nil` until something has been heard.
    private var lastDecodedFrame: [Int16]?
    private var concealmentRun = 0

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
        let origin = clock.now
        self.elapsedSinceOrigin = { sendableClock.now.duration(to: origin) * -1 }
        self.sleepFor = { duration in try await sendableClock.sleep(for: duration) }
        self.sleepUntilOffset = { offset in
            try await sendableClock.sleep(until: origin.advanced(by: offset), tolerance: nil)
        }
        self.makeDirectorySession = { callsign, version, location, send in
            EchoLinkDirectorySession(
                callsign: callsign, version: version, location: location,
                clock: sendableClock, send: send)
        }
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

    /// Logs in to the proxy and the directory, opens the node session, and
    /// starts the audio path.
    ///
    /// ## The sequence, and why it is this one
    ///
    /// Straight from the captures, and two steps of it are not what the plan
    /// assumed:
    ///
    /// 1. **Proxy login** — nonce, then callsign and digest (EL-5).
    /// 2. **`OPEN` to the *directory server*** → `STATUS`. This is the only
    ///    `OPEN` a real client ever sends.
    /// 3. **Directory login** tunnelled as `0x02`, answered `OK` (EL-6).
    /// 4. The proxy **`CLOSE`s that channel**. The session continues.
    /// 5. **`RR + SDES` to the node** on the `0x06` channel, retransmitted
    ///    until it answers.
    ///
    /// **There is no `OPEN` for the node.** That is the correction that matters
    /// most here: across three captures and six distinct audio peers, `0x01
    /// OPEN` was sent *only* for the directory server. The `0x01`/`0x02`/`0x03`
    /// /`0x04` family is the tunnelled **TCP** connection; `0x05`/`0x06` are
    /// connectionless and carry the peer's address in each frame header, so an
    /// audio channel needs no setup at all. An earlier version of this method
    /// opened a channel to the node, which no real client does — see the EL-10
    /// notes.
    ///
    /// ## Skipping the directory login
    ///
    /// With no `accountPassword` (or no `directoryServer`) steps 2–4 are
    /// skipped. Whether a node answers a client that never logged in is **not
    /// established** — no capture shows the attempt — so this is offered as a
    /// deliberate experiment, not as a supported mode. If the node does not
    /// answer, `.nodeDidNotAnswer` is the likely result.
    public func connect(to destination: EchoLinkDestination) async throws {
        guard phase == .idle else { throw EchoLinkClientError.alreadyConnected }
        guard case .proxy(_, _, let password) = destination.route else {
            throw EchoLinkClientError.directModeUnavailable
        }
        // Half a configuration is a mistake, not an intention: a password with
        // nowhere to send it would silently skip the login it was given for.
        if (configuration.accountPassword == nil) != (configuration.directoryServer == nil) {
            throw EchoLinkClientError.directoryLoginIncomplete
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
        } catch let error as EchoLinkProxyError {
            await releaseSession()
            throw EchoLinkClientError.proxy(error)
        }

        // The frame pump must be running before the directory login, because
        // that login's reply arrives as a 0x02 frame through it.
        startFramePump(proxy: proxy)

        do {
            try await logInToDirectoryIfConfigured(proxy: proxy)
            try await openNodeSession(proxy: proxy, destination: destination)
        } catch {
            await releaseSession()
            throw error
        }

        phase = .connected
        setState(.receiving)
        startPlayoutLoop()
        emit(.connected(node: destination.node))
    }

    /// Steps 2–4: tunnel the account login to the directory server.
    private func logInToDirectoryIfConfigured(proxy: EchoLinkProxyClient) async throws {
        guard let accountPassword = configuration.accountPassword,
              let server = configuration.directoryServer
        else { return }

        do {
            try await proxy.open(peer: server)
        } catch let error as EchoLinkProxyError {
            throw EchoLinkClientError.proxy(error)
        }

        let session = makeDirectorySession(
            configuration.callsign,
            configuration.directoryVersion,
            configuration.location
        ) { [weak proxy] bytes in
            // Tunnelled: the same login message, inside a 0x02 frame. EL-6's
            // seam exists exactly so this is the only difference from direct
            // mode.
            //
            // The peer field names the directory server. An earlier version
            // left it 0.0.0.0, reading the fixture's *inbound* frames — which
            // are always 0.0.0.0 — as if they told us what to send. Outbound
            // 0x02 frames carry the address, as the working client does.
            guard let proxy else { throw EchoLinkProxyError.streamClosed }
            try await proxy.send(
                EchoLinkProxyFrame(type: .data, peer: server, payload: bytes))
        }
        directory = session

        do {
            try await session.login(password: accountPassword)
        } catch let error as EchoLinkDirectoryError {
            directory = nil
            throw EchoLinkClientError.directory(error)
        }
        directory = nil
        emit(.directoryLoggedIn)
    }

    // MARK: - Station list (EL-11)

    /// Download the directory's station list.
    ///
    /// **Deliberately not part of `connect`.** Nothing on the path to a QSO
    /// needs the list — an operator who knows the node they want connects
    /// without it — and `connect` is the path that Milestone M3 signed off. A
    /// 433 kB download in the middle of it would add three seconds and a new
    /// failure mode to a sequence that works.
    ///
    /// ## The sequence, from the capture
    ///
    ///     ==> OPEN   (directory server)          a *second* channel
    ///     ==> DATA   "f0" CR                     the request
    ///     <== STATUS success
    ///     <== DATA   "@@@" … "+++"               the list, across 129 frames
    ///
    /// The second `OPEN` is the part worth stating: the login channel is not
    /// reused. In the capture the proxy `CLOSE`s the login channel while the
    /// list is still arriving on the new one, which is also why
    /// `EchoLinkClient` must not treat a `CLOSE` as the session ending.
    ///
    /// ⚠️ **Never run against a live server.** Every rule this depends on was
    /// read off a capture; the request has never been sent by this code. The
    /// parse is conformance-tested against the real 6444-entry download, but
    /// the *fetch* is not, and cannot be until someone runs it — the same
    /// standing caveat the rest of Phase 6 carried until M3.
    ///
    /// - Parameter timeout: how long to wait for the terminator. The reference
    ///   download took 2.6 seconds; the default allows for a slow link rather
    ///   than for a stalled one.
    /// - Returns: the parsed list.
    /// - Throws: `EchoLinkClientError.stationList` if it will not parse or
    ///   never completes, `.notConnected` if there is no session.
    public func fetchStationList(
        timeout: Duration = .seconds(60)
    ) async throws -> EchoLinkStationList {
        guard let proxy, phase == .connected else { throw EchoLinkClientError.notConnected }
        guard let server = configuration.directoryServer else {
            throw EchoLinkClientError.directoryLoginIncomplete
        }
        guard !stationListInFlight else { throw EchoLinkClientError.stationListInFlight }

        stationListInFlight = true
        stationListReader = EchoLinkStationListReader()
        stationListResult = nil
        defer {
            stationListInFlight = false
            stationListReader = nil
            stationListResult = nil
        }

        do {
            try await proxy.open(peer: server)
            try await proxy.send(EchoLinkProxyFrame(
                type: .data, peer: server, payload: EchoLinkStationList.stationListRequest))
        } catch let error as EchoLinkProxyError {
            throw EchoLinkClientError.proxy(error)
        }

        // Poll rather than park a continuation. The frame pump writes
        // `stationListResult`, and this is the one place in the module where a
        // continuation buys nothing: the download takes seconds and arrives in
        // a hundred frames, so a short poll is neither a latency nor a wakeup
        // concern — and it cannot lose a completion to the reentrancy window
        // that `EchoLinkDirectorySession` needs its in-flight flag for.
        let deadline = elapsedSinceOrigin() + timeout
        while elapsedSinceOrigin() < deadline {
            if let result = stationListResult {
                return try result.get()
            }
            try? await sleepFor(.milliseconds(50))
        }

        // A stall, not a short list. `finish()` turns however far it got into
        // an error that says so.
        guard let reader = stationListReader else {
            throw EchoLinkClientError.stationList(.missingTerminator(afterRecords: 0))
        }
        do {
            return try reader.finish()
        } catch let error as EchoLinkStationListError {
            throw EchoLinkClientError.stationList(error)
        }
    }

    /// Feed a `0x02` payload to an in-flight station-list download.
    ///
    /// Returns `true` if it was consumed, so the caller knows not to treat it
    /// as a directory-login reply.
    private func feedStationList(_ payload: Data) -> Bool {
        guard stationListInFlight, stationListResult == nil else { return false }
        do {
            if let list = try stationListReader?.append(payload) {
                stationListResult = .success(list)
            }
        } catch let error as EchoLinkStationListError {
            stationListResult = .failure(EchoLinkClientError.stationList(error))
        } catch {
            stationListResult = .failure(error)
        }
        return true
    }

    /// Step 5: the SDES exchange that actually opens a node session.
    private func openNodeSession(
        proxy: EchoLinkProxyClient,
        destination: EchoLinkDestination
    ) async throws {
        let opening = EchoLinkRTCPCompound.sessionOpening(
            callsign: configuration.callsign,
            operatorName: configuration.operatorName,
            localTime: localTimeHHMM(),
            tool: configuration.tool
        )
        let frame = EchoLinkProxyFrame(
            type: .udpControl,
            peer: destination.peer,
            payload: opening.encoded
        )

        awaitingNodeAnswer = true
        defer { awaitingNodeAnswer = false }

        let deadline = elapsedSinceOrigin() + configuration.nodeAnswerTimeout
        while elapsedSinceOrigin() < deadline {
            do {
                try await proxy.send(frame)
            } catch let error as EchoLinkProxyError {
                throw EchoLinkClientError.proxy(error)
            }
            if nodeAnswer != nil { return }

            // Retransmit until answered, as the observed client does.
            try? await sleepFor(configuration.nodeAnswerRetryInterval)
            if nodeAnswer != nil { return }
        }
        throw EchoLinkClientError.nodeDidNotAnswer
    }

    /// `HH:MM` local time, which is what the observed clients put in the SDES
    /// `PHONE` item.
    private func localTimeHHMM() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
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
            throw EchoLinkClientError.wrongSampleCount(
                expected: codec.samplesPerFrame, actual: pcm.count)
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
                noteNodeAnswer(named: nil)
                // The arrival time matters: EchoLink's timestamp is always zero
                // and its sender does not skip sequence numbers across a pause,
                // so without a wall clock the stream clock drifts behind real
                // time and the jitter buffer stops buffering. See
                // `EchoLinkSequenceExpander.expand`.
                let reception = inbound.receive(packet, arrivedAt: elapsedSinceOrigin())
                if reception.isNewTalkspurt { emit(.talkspurtStarted) }
                for timed in reception.frames { buffer.push(timed) }
            case .stationInfo(let text):
                // The first thing ECHOTEST sent back was oNDATA text, before
                // its RTCP — so this counts as the node answering.
                noteNodeAnswer(named: nil)
                emit(.stationInfo(text))
            case .unrecognised:
                break
            }

        case .udpControl:
            guard let compound = try? EchoLinkRTCPCompound.parse(frame.payload) else { break }
            if compound.isGoodbye {
                Task { [weak self] in await self?.nodeSaidGoodbye() }
                break
            }
            noteNodeAnswer(named: compound.sourceName)

        case .data:
            // Two things arrive tunnelled on 0x02, and only one of them can be
            // in flight at a time: the directory login's reply, and the station
            // list. The list is checked first because a login is not running
            // while one is downloading.
            if feedStationList(frame.payload) { break }
            if let directory {
                Task { await directory.received(frame.payload) }
            }

        case .close:
            // ⚠️ A CLOSE is *not* the session ending. It closes the tunnelled
            // TCP channel — which in a normal session is the directory
            // connection being shut down on purpose, immediately after the
            // login succeeds, with audio still to come. An earlier version
            // treated any 0x03 as the link going down, which would have torn
            // down every session a few hundred milliseconds after connecting.
            //
            // Audio channels are connectionless and have no CLOSE at all, so
            // there is no case in which this means the node has gone.
            break

        default:
            break
        }
    }

    /// Record that the far end has said something, which is what "the node
    /// answered" means — see `openNodeSession`.
    private func noteNodeAnswer(named name: String?) {
        guard awaitingNodeAnswer, nodeAnswer == nil else { return }
        nodeAnswer = name ?? ""
        emit(.nodeAnswered(name: name ?? destination?.node ?? "the node"))
    }

    private func nodeSaidGoodbye() async {
        guard phase != .idle else { return }
        await releaseSession()
        emit(.disconnected(reason: "the node said goodbye"))
    }

    private func linkFinished() async {
        guard phase != .idle else { return }
        await releaseSession()
        emit(.disconnected(reason: "the link closed"))
    }

    // MARK: - Playout

    /// How many consecutive concealed frames before the repeat is faded out
    /// entirely. Matches `M17StreamReceiver`.
    private static let maximumConcealmentRun = 3

    private func startPlayoutLoop() {
        guard playoutTask == nil else { return }
        let interval = configuration.frameInterval
        let maximumLag = configuration.maximumPlayoutLag
        let elapsed = elapsedSinceOrigin
        let sleepUntil = sleepUntilOffset

        playoutTask = Task { [weak self] in
            // An ABSOLUTE grid, not `tick(); sleep(interval)`.
            //
            // The relative version drifts: each period costs the interval plus
            // the tick plus scheduler slop, so 20 ms frames go out every 22-25
            // ms into a device consuming them every 20 ms. The speaker starves
            // a few times a second, and the result is a continuous grinding
            // rather than an obvious fault — which is exactly how it presented
            // on the first live audio test.
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
                // If the grid has fallen far behind — the app was suspended,
                // say — re-anchor rather than sprinting to catch up.
                if next + maximumLag < now {
                    next = now + interval
                }
            }
        }
    }

    private func playoutTick() {
        guard phase == .connected else { return }

        // ⚠️ Every tick yields exactly one frame, including a concealed or
        // silent one. Emitting nothing leaves a hole in the output stream, the
        // device underruns, and the gap is audible — the second half of why the
        // first live audio was grindy. `IAX2VoiceStream` and `M17StreamReceiver`
        // both always produce PCM for the same reason.
        var pcm: [Int16]
        switch buffer.pop() {
        case .frame(let payload):
            guard let decoded = try? codec.decode(payload) else {
                // Undecodable bytes in the right slot: a gap, not audio, and
                // not something to seed concealment from.
                concealmentRun = 0
                pcm = silentFrame()
                break
            }
            lastDecodedFrame = decoded
            concealmentRun = 0
            pcm = decoded

        case .concealment:
            guard let previous = lastDecodedFrame,
                  concealmentRun < Self.maximumConcealmentRun else {
                concealmentRun += 1
                pcm = silentFrame()
                break
            }
            concealmentRun += 1
            // Fade the repeat, so a run tails off instead of buzzing.
            let attenuation = Double(Self.maximumConcealmentRun - concealmentRun + 1)
                / Double(Self.maximumConcealmentRun + 1)
            pcm = previous.map { Int16(clamping: Int(Double($0) * attenuation)) }

        case .silence:
            concealmentRun = 0
            pcm = silentFrame()
        }

        leveller.process(&pcm)  // RC-6/AU-4, in place
        audioContinuation.yield(pcm)
    }

    private func silentFrame() -> [Int16] {
        [Int16](repeating: 0, count: codec.samplesPerFrame)
    }

    // MARK: - Watchdog (SF-1)

    private func transmitWatchdogExpired(after timeout: Duration) async {
        guard case .transmitting = state else { return }
        await stopTransmit()
        emit(.transmitTimedOut(after: timeout))
    }

    // MARK: - Teardown

    private func releaseSession() async {
        // ⚠️ Plan rule 10, in teardown rather than in a request/response.
        //
        // Saying goodbye means awaiting a send, and an actor is reentrant
        // across that await — so `disconnect()` and the frame pump noticing the
        // stream end can both be inside this function at once, both see
        // `phase == .connected`, and both send a BYE. That is what
        // `testDisconnectSendsAGoodbye` caught, intermittently and only under
        // load.
        //
        // The fix is the pattern used everywhere else here: decide and claim
        // the teardown in one synchronous, actor-isolated region with no await
        // in it, and only then suspend.
        guard !isReleasing else { return }
        isReleasing = true
        let farewell: EchoLinkProxyFrame? = {
            guard phase == .connected, let destination else { return nil }
            return EchoLinkProxyFrame(
                type: .udpControl,
                peer: destination.peer,
                payload: EchoLinkRTCPCompound.sessionClosing().encoded
            )
        }()
        let proxyForFarewell = proxy
        phase = .idle
        // ---- end of the region that must not suspend ----

        if let farewell, let proxyForFarewell {
            // Best effort: if the link is already gone this does nothing, which
            // is why it is not allowed to throw.
            try? await proxyForFarewell.send(farewell)
        }

        frameTask?.cancel()
        frameTask = nil
        playoutTask?.cancel()
        playoutTask = nil

        awaitingNodeAnswer = false
        nodeAnswer = nil
        directory = nil

        await watchdog.cancel()
        await proxy?.close()
        proxy = nil
        await transport?.close()
        transport = nil

        destination = nil
        inbound.reset()
        transmitter.reset()
        buffer.reset()
        lastDecodedFrame = nil
        concealmentRun = 0
        setState(.idle)
        isReleasing = false
    }

    // MARK: - Plumbing

    private func setState(_ new: TransmitState) {
        stateBox.value = new
    }

    private func emit(_ event: EchoLinkClientEvent) {
        eventContinuation.yield(event)
    }
}
