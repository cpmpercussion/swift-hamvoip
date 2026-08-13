// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Destination

/// Where an ``M17Client`` connects: a reflector, and a module on it.
public struct M17Destination: Sendable, Equatable {

    /// The reflector's default UDP port.
    public static let defaultPort: UInt16 = 17000

    /// Reflector host name or address.
    public let host: String

    /// Reflector UDP port.
    public let port: UInt16

    /// The module to link — a single ASCII uppercase letter, `A`…`Z`.
    public let module: Character

    /// Our own callsign, which travels in every packet's SRC field.
    public let callsign: String

    public init(
        host: String,
        port: UInt16 = M17Destination.defaultPort,
        module: Character,
        callsign: String
    ) {
        self.host = host
        self.port = port
        self.module = module
        self.callsign = callsign
    }
}

// MARK: - Errors

public enum M17ClientError: Error, Equatable, CustomStringConvertible {
    /// An operation needing a live link was attempted without one.
    case notConnected
    /// ``M17Client/connect(to:)`` was called while already connected.
    case alreadyConnected
    /// The destination's callsign or module is not encodable.
    case invalidDestination(String)

    public var description: String {
        switch self {
        case .notConnected: return "not linked to a reflector"
        case .alreadyConnected: return "already linked; disconnect first"
        case .invalidDestination(let why): return "invalid destination: \(why)"
        }
    }
}

// MARK: - Events

/// Why an inbound stream stopped.
public enum StreamEndReason: Sendable, Equatable, CustomStringConvertible {
    /// The transmitting station set the last-frame flag — a clean end of over.
    case lastFrame
    /// A different stream ID started before this one ended. The previous
    /// station either lost its last frame or was talked over; either way its
    /// audio is abandoned rather than played across the join.
    case preempted

    public var description: String {
        switch self {
        case .lastFrame: return "end of over"
        case .preempted: return "cut off by another station"
        }
    }
}

/// What an ``M17Client`` reports to whoever is watching.
public enum M17ClientEvent: Sendable, Equatable {
    /// A link attempt has begun.
    case connecting
    /// The reflector acknowledged; audio can flow.
    case linked(module: Character)
    /// A new station started transmitting.
    case streamStarted(source: M17Address, streamID: UInt16)
    /// A station stopped transmitting, and why.
    ///
    /// The reason matters to an operator: a stream that just stopped arriving
    /// is an ordinary end of over, while one displaced by another station is
    /// somebody being cut off — the kind of thing worth showing rather than
    /// silently replacing in the UI.
    case streamEnded(source: M17Address, reason: StreamEndReason)
    /// A datagram was refused, with why. Emitted once per run of the same
    /// reason rather than per datagram, so a corrupt stream cannot flood.
    case streamRejected(M17StreamReceiver.Rejection)
    /// PTT is down.
    case transmitting
    /// PTT is up.
    case receiving
    /// The transmit watchdog fired and unkeyed for us (SF-1).
    case transmitWatchdogExpired(Duration)
    /// The link is gone.
    case disconnected(M17DisconnectReason?)
}

// MARK: - Translation onto RadioCore's mode-agnostic events

extension M17ClientEvent {
    /// This event as `NetworkClient` sees it (RC-10).
    ///
    /// Never `nil` for this mode: every case maps. What is dropped is detail
    /// inside the cases — the module letter, which `M17Client.linkedModule`
    /// still answers for, and the stream ID, which identifies an over on the
    /// wire and means nothing above the protocol.
    public var radioEvent: RadioEvent? {
        switch self {
        case .connecting:
            return .connecting
        case .linked:
            return .connected
        case .streamStarted(let source, _):
            return .remoteTransmitStarted(station: source.callsign)
        case .streamEnded(let source, let reason):
            // `preempted` is the one an operator needs distinguished: it means
            // somebody was talked over, not that an over ended.
            return .remoteTransmitEnded(
                station: source.callsign, displaced: reason == .preempted)
        case .streamRejected(let rejection):
            return .incomingAudioDropped(rejection.radioAudioIssue)
        case .transmitting:
            return .transmitting
        case .receiving:
            return .receiving
        case .transmitWatchdogExpired(let timeout):
            return .transmitWatchdogExpired(timeout)
        case .disconnected(let reason):
            // No reason means the transport went away underneath the link.
            return .disconnected(reason?.radioDisconnectReason ?? .transportFailure())
        }
    }
}

extension M17DisconnectReason {
    /// This reason as `NetworkClient` sees it (RC-10).
    public var radioDisconnectReason: RadioDisconnectReason {
        switch self {
        case .localRequest:
            return .localRequest
        case .rejectedByReflector:
            // A NACK means the link never existed — usually the module letter
            // or the callsign, both of which the operator can fix.
            return .rejected(detail: "the reflector sent NACK")
        case .remoteRequest:
            return .remoteRequest(detail: "the reflector sent DISC")
        case .connectTimeout:
            return .connectTimedOut(nil)
        case .keepaliveTimeout:
            // The reflector stopped sending PING. It is gone; it just never
            // said so, which is what `linkTimedOut` means.
            return .linkTimedOut(nil)
        case .transportClosed:
            return .transportFailure()
        }
    }
}

extension M17StreamReceiver.Rejection {
    /// This rejection as `NetworkClient` sees it (RC-10).
    public var radioAudioIssue: RadioAudioIssue {
        switch self {
        case .encrypted:
            // Deliberately visible rather than silent (FR-2.5): the audio is
            // not missing, it is unlistenable, and there is no decrypt path.
            return .encrypted
        // A failed CRC, a payload that is not two codec frames and a packet
        // from a stream we are not playing are all "arrived, could not be
        // turned into samples". The distinctions are M17 distinctions and stay
        // on `M17Client.events`.
        case .crcFailed, .malformedPayload, .wrongStream:
            return .undecodable(detail: description)
        }
    }
}

// MARK: - M17Client

/// The M17 mode as the application sees it (M17-5).
///
/// Mirrors `IAX2Client`: it is the one type that composes a link, a codec, a
/// jitter buffer, the transmit watchdog and the received-audio leveller into
/// something conforming to `RadioCore.NetworkClient`, so the SwiftUI layer can
/// drive M17 without knowing what a LICH is.
///
/// ```
///  captured PCM ──► send(pcm:) ──► M17StreamTransmitter ──► M17ReflectorClient
///                    (pairs 20 ms frames into 40 ms datagrams)
///
///  M17ReflectorClient ──► M17StreamReceiver ──► leveller ──► receivedAudio
///                          (jitter buffer + Codec2)
/// ```
///
/// ## Two things worth knowing
///
/// **The 20/40 ms mismatch is handled here.** Everything else in the stack
/// works in 20 ms frames — `AudioPipeline` captures them, `JitterBuffer` ticks
/// in them — but an M17 datagram carries 40 ms. Rather than push that oddity
/// out to callers, ``send(pcm:)`` takes the same 20 ms frame the IAX2 path
/// takes and holds every other one back, emitting a datagram on the second.
/// The pending half is discarded on unkey, so a partial datagram never
/// straddles two overs.
///
/// **A new stream ID per PTT.** "Random bits, changed for each PTT or stream"
/// is a protocol requirement, and it is what lets a receiver tell one over
/// from the next; ``startTransmit()`` draws a fresh one and resets the frame
/// counter.
public actor M17Client: NetworkClient {
    public typealias Destination = M17Destination

    // MARK: Configuration

    public struct Configuration: Sendable {
        /// Transmit watchdog timeout (SF-1).
        public var transmitTimeout: Duration
        /// One codec frame — the playout tick. 20 ms.
        public var frameInterval: Duration
        /// How far the playout grid may fall behind before it re-anchors.
        public var maximumPlayoutLag: Duration
        /// How long to wait for the reflector's ACKN.
        public var connectTimeout: Duration
        /// How long without a reflector PING before the link is declared dead.
        public var linkTimeout: Duration
        /// The inbound jitter buffer (AU-3).
        public var jitterBuffer: JitterBuffer
        /// The received-audio leveller (RC-6/AU-4).
        public var leveller: AudioLeveller

        public init(
            transmitTimeout: Duration = .seconds(180),
            frameInterval: Duration = .milliseconds(20),
            maximumPlayoutLag: Duration = .milliseconds(200),
            connectTimeout: Duration = M17ReflectorClient.defaultConnectTimeout,
            linkTimeout: Duration = M17ReflectorClient.defaultLinkTimeout,
            jitterBuffer: JitterBuffer = JitterBuffer(),
            leveller: AudioLeveller = AudioLeveller()
        ) {
            self.transmitTimeout = transmitTimeout
            self.frameInterval = frameInterval
            self.maximumPlayoutLag = maximumPlayoutLag
            self.connectTimeout = connectTimeout
            self.linkTimeout = linkTimeout
            self.jitterBuffer = jitterBuffer
            self.leveller = leveller
        }
    }

    /// How a transport is made for a destination. Tests inject `MockTransport`;
    /// nothing here ever opens a socket itself (AU-5).
    public typealias TransportFactory =
        @Sendable (M17Destination) throws -> any DatagramTransport

    // MARK: Public surface

    /// Levelled 8 kHz mono PCM, one 20 ms frame per tick, for the whole
    /// session. Finished by ``disconnect()``.
    public nonisolated let receivedAudio: AsyncStream<[Int16]>

    /// Session events.
    public nonisolated let events: AsyncStream<M17ClientEvent>

    /// `NetworkClient`'s mode-agnostic view of ``events`` (RC-10).
    ///
    /// The same events in the same order, translated by
    /// ``M17ClientEvent/radioEvent``. Both streams are fed from one place, so
    /// they cannot disagree about what happened.
    public nonisolated let radioEvents: AsyncStream<RadioEvent>

    public nonisolated var state: TransmitState { stateBox.value }

    // MARK: Injected

    private let configuration: Configuration
    private let codec: any VoiceCodec
    private let makeTransport: TransportFactory
    private let makeReflectorClient:
        @Sendable (String, any DatagramTransport, Duration, Duration) throws -> M17ReflectorClient
    private let elapsedSinceOrigin: @Sendable () -> Duration
    private let sleepUntilOffset: @Sendable (Duration) async throws -> Void

    // MARK: Session state

    private enum Phase: Sendable, Equatable {
        case idle, connecting, connected
    }

    private var phase: Phase = .idle
    private var destination: M17Destination?
    private var transport: (any DatagramTransport)?
    private var link: M17ReflectorClient?
    private var transmitter: M17StreamTransmitter?
    private var receiver: M17StreamReceiver?
    private var leveller: AudioLeveller

    private let watchdog: TransmitWatchdog

    private var eventTask: Task<Void, Never>?
    private var playoutTask: Task<Void, Never>?

    /// The 20 ms frame held back waiting for its partner. See the class note.
    private var pendingHalfFrame: [Int16]?

    /// The last rejection reported, so a corrupt stream reports once rather
    /// than 25 times a second.
    private var lastReportedRejection: M17StreamReceiver.Rejection?

    private nonisolated let stateBox = TransmitStateBox()
    private nonisolated let audioContinuation: AsyncStream<[Int16]>.Continuation
    private nonisolated let eventContinuation: AsyncStream<M17ClientEvent>.Continuation
    private nonisolated let radioEventContinuation: AsyncStream<RadioEvent>.Continuation

    // MARK: Init

    /// - Parameters:
    ///   - codec: the voice codec. `Codec2VoiceCodec` in production; tests pass
    ///     a stub, which is why this is injected rather than constructed here —
    ///     it also keeps `M17Client` compiling on a checkout with no
    ///     `Codec2.xcframework`.
    ///   - clock: drives the playout grid. Tests pass a manual clock.
    public init<C: Clock>(
        codec: any VoiceCodec,
        configuration: Configuration = Configuration(),
        clock: C,
        transportFactory: @escaping TransportFactory = M17Client.udpTransportFactory,
        reflectorClientFactory: (
            @Sendable (String, any DatagramTransport, Duration, Duration) throws
                -> M17ReflectorClient
        )? = nil
    ) where C.Duration == Duration {
        self.codec = codec
        self.configuration = configuration
        self.leveller = configuration.leveller
        self.makeTransport = transportFactory
        self.watchdog = TransmitWatchdog(clock: clock)

        let sendableClock = clock
        self.makeReflectorClient =
            reflectorClientFactory
            ?? { callsign, transport, connectTimeout, linkTimeout in
                try M17ReflectorClient(
                    callsign: callsign,
                    transport: transport,
                    clock: sendableClock,
                    connectTimeout: connectTimeout,
                    linkTimeout: linkTimeout)
            }

        let origin = clock.now
        self.elapsedSinceOrigin = { clock.now.duration(to: origin) * -1 }
        self.sleepUntilOffset = { offset in
            try await clock.sleep(until: origin.advanced(by: offset), tolerance: nil)
        }

        var escapedAudio: AsyncStream<[Int16]>.Continuation!
        self.receivedAudio = AsyncStream { escapedAudio = $0 }
        self.audioContinuation = escapedAudio

        var escapedEvents: AsyncStream<M17ClientEvent>.Continuation!
        self.events = AsyncStream { escapedEvents = $0 }
        self.eventContinuation = escapedEvents

        var escapedRadioEvents: AsyncStream<RadioEvent>.Continuation!
        self.radioEvents = AsyncStream { escapedRadioEvents = $0 }
        self.radioEventContinuation = escapedRadioEvents
    }

    /// The real transport (PD-1). Never used by a unit test.
    public static let udpTransportFactory: TransportFactory = { destination in
        try NWDatagramTransport(host: destination.host, port: destination.port)
    }

    // MARK: Introspection

    public var isConnected: Bool { phase == .connected }
    public var currentDestination: M17Destination? { destination }
    /// The station currently transmitting, if any.
    public var currentSource: M17Address? { receiver?.source }
    public var queuedInboundFrameCount: Int { receiver?.queuedFrameCount ?? 0 }

    // MARK: - NetworkClient: connecting

    /// Links to `destination`'s module and starts the audio path.
    public func connect(to destination: M17Destination) async throws {
        guard phase == .idle else { throw M17ClientError.alreadyConnected }

        let address: M17Address
        do {
            address = try M17Address(callsign: destination.callsign)
        } catch {
            throw M17ClientError.invalidDestination(
                "callsign '\(destination.callsign)' is not base-40 encodable")
        }

        phase = .connecting
        self.destination = destination
        emit(.connecting)

        let transport: any DatagramTransport
        do {
            transport = try makeTransport(destination)
        } catch {
            phase = .idle
            self.destination = nil
            throw error
        }
        self.transport = transport

        let link: M17ReflectorClient
        do {
            link = try makeReflectorClient(
                destination.callsign, transport, configuration.connectTimeout,
                configuration.linkTimeout)
        } catch {
            await releaseSession()
            throw error
        }
        self.link = link

        // Drain the link's events before connecting, so an ACKN that arrives
        // while `connect` is still suspended is not lost. Same reentrancy
        // hazard M17-3 paid for.
        startEventPump(link: link)

        do {
            try await link.connect(module: destination.module)
        } catch {
            await releaseSession()
            throw error
        }

        // Re-checked after the await: a teardown could have run while we were
        // suspended, and reporting a link that is already gone would be a lie.
        guard phase == .connecting else { throw M17ClientError.notConnected }

        receiver = M17StreamReceiver(codec: codec, buffer: configuration.jitterBuffer)
        transmitter = M17StreamTransmitter(
            streamID: M17StreamTransmitter.randomStreamID(),
            destination: .broadcast,
            source: address)
        leveller = configuration.leveller

        phase = .connected
        setState(.receiving)
        startPlayoutLoop()
        emit(.linked(module: destination.module))
    }

    /// Drops the link, stops the audio path and finishes the public streams.
    public func disconnect() async {
        let wasActive = phase != .idle
        await releaseSession()
        if wasActive { emit(.disconnected(.localRequest)) }
        audioContinuation.finish()
        eventContinuation.finish()
        radioEventContinuation.finish()
    }

    // MARK: - NetworkClient: transmitting

    /// Keys up: arms the watchdog (SF-1) and starts a new over.
    ///
    /// The watchdog is armed *before* ``state`` becomes `.transmitting`, so
    /// there is no window in which audio goes out with no deadline attached.
    /// Idempotent while already transmitting, and deliberately does not re-arm
    /// — a caller that re-keyed per frame would push the deadline out forever.
    public func startTransmit() async throws {
        guard phase == .connected, transmitter != nil else { throw M17ClientError.notConnected }
        if case .transmitting = state { return }

        let timeout = configuration.transmitTimeout
        await watchdog.start(timeout: timeout) { [weak self] in
            await self?.transmitWatchdogExpired(after: timeout)
        }

        guard phase == .connected else {
            await watchdog.cancel()
            throw M17ClientError.notConnected
        }

        // A fresh stream ID and frame counter per PTT, as the protocol
        // requires and as a receiver relies on to tell overs apart.
        transmitter?.reset(streamID: M17StreamTransmitter.randomStreamID())
        pendingHalfFrame = nil

        setState(.transmitting(since: Date()))
        emit(.transmitting)
    }

    /// Unkeys. Idempotent, and safe when not connected — SF-2 and SF-3 both
    /// call this from paths that cannot know the current state.
    ///
    /// Sends a final frame if the over produced any audio, so a receiver sees
    /// the end of the stream rather than inferring it from silence.
    public func stopTransmit() async {
        await watchdog.cancel()
        guard case .transmitting = state else { return }

        if var transmitter, phase == .connected, let link, !transmitter.isFinished,
            transmitter.nextSequenceNumber > 0
        {
            // A half frame left over is padded rather than dropped: it is
            // 20 ms of real audio, and the alternative is clipping the end of
            // every over.
            let tail = pendingHalfFrame ?? [Int16](repeating: 0, count: codec.samplesPerFrame)
            let pcm = tail + [Int16](repeating: 0, count: codec.samplesPerFrame)
            if let packet = try? transmitter.next(pcm: pcm, using: codec, isLast: true) {
                try? await link.send(packet)
            }
            self.transmitter = transmitter
        }
        pendingHalfFrame = nil

        setState(phase == .connected ? .receiving : .idle)
        emit(.receiving)
    }

    /// Offers one 20 ms frame of captured audio.
    ///
    /// Two of these make one datagram, so this returns `nil` on every other
    /// call even while transmitting — that is the 20/40 ms pairing, not a
    /// failure.
    ///
    /// - Parameter pcm: exactly one codec frame of 8 kHz signed 16-bit mono.
    /// - Returns: the datagram sent, or `nil` if none was due. **Not
    ///   transmitting is not an error**: a capture pipeline runs continuously
    ///   and hands over every frame it makes; knowing PTT is released is this
    ///   client's job, and silently dropping is the fail-safe direction —
    ///   the failure mode is dead air, not an open microphone.
    @discardableResult
    public func transmit(pcm: [Int16]) async throws -> M17StreamPacket? {
        guard case .transmitting = state, phase == .connected,
            var transmitter, let link
        else { return nil }
        guard pcm.count == codec.samplesPerFrame else {
            throw M17StreamAudioError.wrongSampleCount(
                expected: codec.samplesPerFrame, actual: pcm.count)
        }

        guard let first = pendingHalfFrame else {
            pendingHalfFrame = pcm
            return nil
        }
        pendingHalfFrame = nil

        let packet = try transmitter.next(pcm: first + pcm, using: codec)
        self.transmitter = transmitter
        try await link.send(packet)
        return packet
    }

    /// `NetworkClient`'s transmit seam: ``transmit(pcm:)``, with the packet
    /// discarded.
    ///
    /// Two methods rather than one because a witness may not return a value the
    /// requirement does not — and the requirement should not, since an
    /// `M17StreamPacket` is exactly the protocol detail the seam exists to keep
    /// out of an application. Note that half the calls legitimately produce no
    /// packet at all: M17 frames 40 ms and this takes 20 ms, so every other
    /// frame is held back.
    public func send(pcm: [Int16]) async throws {
        _ = try await transmit(pcm: pcm)
    }

    // MARK: - The event pump

    private func startEventPump(link: M17ReflectorClient) {
        guard eventTask == nil else { return }
        let incoming = link.events
        eventTask = Task { [weak self] in
            for await event in incoming {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: M17ReflectorEvent) async {
        switch event {
        case .stream(let packet):
            handle(stream: packet)
        case .disconnected(let reason):
            guard phase != .idle else { return }
            await releaseSession()
            emit(.disconnected(reason))
        case .connecting, .linked:
            // Reported by `connect(to:)` once it knows the outcome; echoing
            // the link layer's own transitions here would double them up.
            break
        }
    }

    private func handle(stream packet: M17StreamPacket) {
        guard var receiver else { return }
        let previousSource = receiver.source
        // Whether the over being displaced already ended cleanly. If it did,
        // its `.lastFrame` end has been reported and reporting a preemption on
        // top would be a second ending for the same stream.
        let previousAlreadyEnded = receiver.hasSeenFinalFrame
        let reception = receiver.receive(packet)
        self.receiver = receiver

        switch reception {
        case .acceptedNewStream(let streamID, let source):
            lastReportedRejection = nil
            if let previousSource, !previousAlreadyEnded {
                emit(.streamEnded(source: previousSource, reason: .preempted))
            }
            emit(.streamStarted(source: source, streamID: streamID))
        case .acceptedFinalFrame:
            lastReportedRejection = nil
            emit(.streamEnded(source: packet.source, reason: .lastFrame))
        case .accepted:
            lastReportedRejection = nil
        case .rejected(let rejection):
            // Once per run, not once per datagram: a reflector sending
            // something we refuse sends it 25 times a second.
            guard lastReportedRejection != rejection else { return }
            lastReportedRejection = rejection
            emit(.streamRejected(rejection))
        }
    }

    // MARK: - The playout pump

    private func startPlayoutLoop() {
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
                    next = now + interval
                }
            }
        }
    }

    private func playoutTick() async {
        guard phase == .connected, var receiver else { return }
        var pcm = receiver.pop().pcm
        self.receiver = receiver
        // AU-4: one leveller for the whole session — its gain trajectory is
        // the point, and a per-frame one would be an expensive way to do
        // nothing.
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

    /// Stops every task, drops the link and closes the transport. Does **not**
    /// finish the public streams — that is ``disconnect()``'s doing alone, so
    /// a link that dies remotely can still be reported to a listening app.
    private func releaseSession() async {
        playoutTask?.cancel()
        playoutTask = nil
        eventTask?.cancel()
        eventTask = nil

        await watchdog.cancel()
        if let link { await link.shutdown() }
        link = nil
        transmitter = nil
        receiver = nil
        pendingHalfFrame = nil
        lastReportedRejection = nil
        if let transport { await transport.close() }
        transport = nil

        phase = .idle
        destination = nil
        setState(.idle)
    }

    // MARK: - Small helpers

    private func setState(_ next: TransmitState) {
        stateBox.value = next
    }

    /// The one place events leave this client, so ``events`` and ``radioEvents``
    /// cannot drift apart or disagree on ordering.
    private func emit(_ event: M17ClientEvent) {
        eventContinuation.yield(event)
        if let radio = event.radioEvent { radioEventContinuation.yield(radio) }
    }
}
