// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import RadioCore

/// RC-10: `NetworkClient` as a *complete* protocol.
///
/// The whole point of this file is the generic functions at the bottom. They
/// run a session — connect, transmit a frame, read an event, read an audio
/// frame, disconnect — knowing nothing but `NetworkClient`. **If any of them
/// ever needs a concrete client type, the protocol is missing something and the
/// fix belongs in `NetworkClient`, not in the caller.** That is exactly the
/// failure Currawong hit before this task: it had to translate `IAX2Client`
/// specifics in its composition root because the protocol produced no events,
/// no audio and no way to hand audio back.
///
/// The fake here is deliberately a plain `final class` rather than an actor, to
/// prove the protocol does not oblige a conformer to be one — an app's test
/// double should not have to be an actor to stand in for a client (APP-2).
final class NetworkClientTests: XCTestCase {

    private let frameSamples = 160

    // MARK: - The protocol is usable generically

    /// A whole session, driven through nothing but the protocol.
    func testAWholeSessionRunsThroughTheProtocolAlone() async throws {
        let client = FakeNetworkClient(receivedFrames: [[1, 2, 3]])
        let outgoing = [Int16](repeating: 1000, count: frameSamples)

        let transcript = try await runSession(client, to: "node-55553", transmitting: outgoing)

        XCTAssertEqual(
            transcript.eventsInOrder,
            [.connecting, .connected, .transmitting, .receiving],
            "the lifecycle an application needs, in order, with no mode-specific type in sight")
        XCTAssertEqual(transcript.receivedFrame, [1, 2, 3], "decoded audio arrived through the protocol")
        XCTAssertEqual(
            transcript.stateWhileTransmitting.isTransmitting, true,
            "`state` reports transmission synchronously, without an await")
        XCTAssertEqual(transcript.stateAfterDisconnect, .idle)

        let transmitted = client.transmittedFrames
        XCTAssertEqual(transmitted, [outgoing], "the frame offered through the protocol went out")
    }

    /// SF-1's visibility requirement, seen generically: an observer that knows
    /// only `NetworkClient` still learns that the watchdog stopped the operator
    /// transmitting, and how long it waited before doing so.
    func testWatchdogExpiryIsVisibleThroughTheProtocol() async throws {
        let client = FakeNetworkClient()
        let observer = Task { await firstWatchdogTimeout(client) }

        try await client.connect(to: "node-55553")
        try await client.startTransmit()
        client.simulateTransmitWatchdogExpiry(after: .seconds(180))

        let timeout = await observer.value
        XCTAssertEqual(timeout, .seconds(180))
        XCTAssertEqual(client.state, .receiving, "expiry unkeys without the caller doing anything")

        await client.disconnect()
    }

    // MARK: - `send(pcm:)`

    /// Audio offered while unkeyed is dropped, silently — the semantic
    /// `IAX2Client` already had, now written into the protocol so every mode
    /// keeps it. A capture pipeline runs continuously; deciding whether PTT is
    /// down is the client's job, and the fail-safe direction is dead air rather
    /// than an open microphone.
    func testAudioOfferedWhileNotTransmittingIsDroppedNotThrown() async throws {
        let client = FakeNetworkClient()
        try await client.connect(to: "node-55553")

        let frame = [Int16](repeating: 500, count: frameSamples)
        try await offer(frame, to: client)  // generic, unkeyed
        XCTAssertEqual(client.transmittedFrames, [], "nothing went out")

        try await client.startTransmit()
        try await offer(frame, to: client)
        XCTAssertEqual(client.transmittedFrames, [frame], "and keyed, it does")

        await client.disconnect()
    }

    // MARK: - Lifecycle contract

    /// The contract the app discovered the hard way, now documented on the
    /// protocol and exercised here: `disconnect()` finishes both streams and is
    /// terminal, so reconnecting means a new client.
    func testDisconnectFinishesBothStreamsAndIsTerminal() async throws {
        let client = FakeNetworkClient(receivedFrames: [[7]])
        try await client.connect(to: "node-55553")

        await client.disconnect()
        await client.disconnect()  // idempotent

        var events: [RadioEvent] = []
        for await event in client.radioEvents { events.append(event) }
        var audio: [[Int16]] = []
        for await frame in client.receivedAudio { audio.append(frame) }
        XCTAssertEqual(events, [.connecting, .connected], "the event loop ended rather than hanging")
        XCTAssertEqual(audio, [[7]], "and so did the audio loop")

        do {
            try await client.connect(to: "node-55553")
            XCTFail("a disconnected client must not reconnect: its streams are finished")
        } catch let error as FakeClientError {
            XCTAssertEqual(error, .clientShutDown)
        }
    }

    /// A session that ends remotely leaves the streams open, so the application
    /// can hear about it — the other half of the same contract.
    func testARemotelyEndedSessionReportsItselfAndLeavesTheStreamsOpen() async throws {
        let client = FakeNetworkClient()
        try await client.connect(to: "node-55553")

        client.simulateRemoteDisconnect(.remoteRequest(detail: "Bye (cause code 16)"))
        XCTAssertEqual(client.state, .idle)

        var events: [RadioEvent] = []
        var iterator = client.radioEvents.makeAsyncIterator()
        while events.count < 3, let event = await iterator.next() { events.append(event) }
        XCTAssertEqual(
            events.last, .disconnected(.remoteRequest(detail: "Bye (cause code 16)")),
            "the reason survives into the mode-agnostic event")

        await client.disconnect()
        let afterDisconnect = await iterator.next()
        XCTAssertNil(afterDisconnect, "and only disconnect() ends the stream")
    }

    // MARK: - `RadioEvent` shape

    /// The five things SF-1…SF-4 and the app need, all representable.
    func testRadioEventCoversTheRequiredVocabulary() {
        let cases: [RadioEvent] = [
            .connecting,
            .connected,
            .disconnected(.rejected(detail: "wrong password")),
            .transmitting,
            .receiving,
            .transmitWatchdogExpired(.seconds(180)),
            .dtmfReceived("7"),
            .incomingAudioDropped(.encrypted),
        ]
        // Equatable is what lets a view model diff state and a test assert an
        // exact sequence; CustomStringConvertible is what puts a reason in front
        // of an operator (SF-1) without the app writing a switch per mode.
        for event in cases {
            XCTAssertEqual(event, event)
            XCTAssertFalse("\(event)".isEmpty)
        }
        XCTAssertNotEqual(RadioEvent.transmitWatchdogExpired(.seconds(180)),
            .transmitWatchdogExpired(.seconds(60)))
    }

    /// A disconnect reason has to be worth showing: every case renders, and the
    /// detail a mode supplies is carried through rather than flattened away.
    func testDisconnectReasonsCarryTheirDetail() {
        XCTAssertTrue("\(RadioDisconnectReason.rejected(detail: "no such node"))"
            .contains("no such node"))
        XCTAssertTrue("\(RadioDisconnectReason.remoteRequest(detail: "Bye"))".contains("Bye"))
        XCTAssertTrue("\(RadioDisconnectReason.connectTimedOut(.seconds(5)))".contains("5"))
        // And the detail-free forms still say something.
        let bare: [RadioDisconnectReason] = [
            .localRequest, .remoteRequest(), .rejected(), .connectTimedOut(),
            .linkTimedOut(), .transportFailure(), .protocolFailure(),
        ]
        for reason in bare { XCTAssertFalse("\(reason)".isEmpty) }
    }

    /// `RadioAudioIssue` has to be able to say "encrypted", because an M17
    /// stream that cannot be played (FR-2.5) is not the same operator
    /// experience as one that never arrived.
    func testAudioIssuesRender() {
        let issues: [RadioAudioIssue] = [
            .unsupportedFormat(detail: "0x00000008"), .encrypted, .undecodable(detail: "160 vs 80"),
        ]
        for issue in issues { XCTAssertFalse("\(issue)".isEmpty) }
        XCTAssertTrue("\(RadioAudioIssue.encrypted)".contains("encrypted"))
    }
}

// MARK: - The generic drivers

/// What ``runSession(_:to:transmitting:)`` observed, all of it through the
/// protocol.
private struct SessionTranscript {
    var eventsInOrder: [RadioEvent]
    var receivedFrame: [Int16]?
    var stateWhileTransmitting: TransmitState
    var stateAfterDisconnect: TransmitState
}

/// Connects, transmits a frame, reads an event and an audio frame, and
/// disconnects — **using nothing but `NetworkClient`**.
///
/// This function is the acceptance test for RC-10. It compiles only if the
/// protocol carries events, received audio and a way to submit captured audio;
/// before RC-10 it could not be written at all.
private func runSession<Client: NetworkClient>(
    _ client: Client,
    to destination: Client.Destination,
    transmitting frame: [Int16]
) async throws -> SessionTranscript {
    var events = client.radioEvents.makeAsyncIterator()
    var audio = client.receivedAudio.makeAsyncIterator()
    var seen: [RadioEvent] = []

    try await client.connect(to: destination)
    if let first = await events.next() { seen.append(first) }

    // Received audio: a frame the client decoded and levelled for us.
    let heard = await audio.next()

    try await client.startTransmit()
    let transmittingState = client.state
    try await client.send(pcm: frame)
    await client.stopTransmit()
    await client.disconnect()
    let idleState = client.state

    // The stream is finished by `disconnect()`, so this loop ends. That
    // guarantee is why the lifecycle contract is what it is.
    while let event = await events.next() { seen.append(event) }

    return SessionTranscript(
        eventsInOrder: seen,
        receivedFrame: heard,
        stateWhileTransmitting: transmittingState,
        stateAfterDisconnect: idleState)
}

/// Watches for SF-1's watchdog expiry knowing only `NetworkClient`, and reports
/// the timeout it fired after.
private func firstWatchdogTimeout<Client: NetworkClient>(_ client: Client) async -> Duration? {
    for await event in client.radioEvents {
        if case .transmitWatchdogExpired(let timeout) = event { return timeout }
    }
    return nil
}

/// A microphone's-eye view: hand over a frame and let the client decide.
private func offer<Client: NetworkClient>(_ pcm: [Int16], to client: Client) async throws {
    try await client.send(pcm: pcm)
}

extension TransmitState {
    fileprivate var isTransmitting: Bool {
        if case .transmitting = self { return true }
        return false
    }
}

// MARK: - The fake conformer

private enum FakeClientError: Error, Equatable {
    case notConnected
    case clientShutDown
}

/// A minimal, complete `NetworkClient` — proof that the protocol is
/// *implementable*, and the shape of fake an app's view-model tests will use.
///
/// A `final class` with a lock rather than an actor, for two reasons: it proves
/// the protocol does not force actor isolation on a conformer, and `state` is a
/// synchronous requirement, so an actor would need a lock-backed box for it
/// anyway (which is exactly what `IAX2Client` does).
private final class FakeNetworkClient: NetworkClient, @unchecked Sendable {
    typealias Destination = String

    let radioEvents: AsyncStream<RadioEvent>
    let receivedAudio: AsyncStream<[Int16]>

    private let eventContinuation: AsyncStream<RadioEvent>.Continuation
    private let audioContinuation: AsyncStream<[Int16]>.Continuation

    private let lock = NSLock()
    private var storedState: TransmitState = .idle
    private var isShutDown = false
    private var isConnected = false
    private var sent: [[Int16]] = []
    private let audioToDeliver: [[Int16]]

    /// Frames that actually went "on the air".
    var transmittedFrames: [[Int16]] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    var state: TransmitState {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    init(receivedFrames: [[Int16]] = []) {
        self.audioToDeliver = receivedFrames

        var escapedEvents: AsyncStream<RadioEvent>.Continuation!
        radioEvents = AsyncStream(bufferingPolicy: .unbounded) { escapedEvents = $0 }
        eventContinuation = escapedEvents

        var escapedAudio: AsyncStream<[Int16]>.Continuation!
        receivedAudio = AsyncStream(bufferingPolicy: .unbounded) { escapedAudio = $0 }
        audioContinuation = escapedAudio
    }

    func connect(to destination: Destination) async throws {
        try withLock {
            guard !isShutDown else { throw FakeClientError.clientShutDown }
            isConnected = true
            storedState = .receiving
        }
        eventContinuation.yield(.connecting)
        eventContinuation.yield(.connected)
        for frame in audioToDeliver { audioContinuation.yield(frame) }
    }

    func disconnect() async {
        let alreadyDone: Bool = withLock {
            if isShutDown { return true }
            isShutDown = true
            isConnected = false
            storedState = .idle
            return false
        }
        guard !alreadyDone else { return }
        eventContinuation.finish()
        audioContinuation.finish()
    }

    func startTransmit() async throws {
        try withLock {
            guard isConnected else { throw FakeClientError.notConnected }
            storedState = .transmitting(since: Date())
        }
        eventContinuation.yield(.transmitting)
    }

    func stopTransmit() async {
        let wasTransmitting: Bool = withLock {
            guard case .transmitting = storedState else { return false }
            storedState = isConnected ? .receiving : .idle
            return true
        }
        if wasTransmitting { eventContinuation.yield(.receiving) }
    }

    func send(pcm: [Int16]) async throws {
        withLock {
            guard case .transmitting = storedState else { return }
            sent.append(pcm)
        }
    }

    // MARK: Test stimuli

    func simulateTransmitWatchdogExpiry(after timeout: Duration) {
        withLock {
            guard case .transmitting = storedState else { return }
            storedState = .receiving
        }
        eventContinuation.yield(.receiving)
        eventContinuation.yield(.transmitWatchdogExpired(timeout))
    }

    func simulateRemoteDisconnect(_ reason: RadioDisconnectReason) {
        withLock {
            isConnected = false
            storedState = .idle
        }
        eventContinuation.yield(.disconnected(reason))
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
