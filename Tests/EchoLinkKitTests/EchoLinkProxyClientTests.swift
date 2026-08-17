// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import RadioCore
import TestSupport

/// EL-5 — the proxy session, driven from the EL-2 fixtures over
/// `MockStreamTransport`. No socket is opened (AU-5).
final class EchoLinkProxyClientTests: XCTestCase {
    private static let callsign = "N0CALL"
    private static let nonce = "6fc8b7e3"

    private struct Harness {
        let client: EchoLinkProxyClient
        let transport: MockStreamTransport
        let clock: ManualTestClock
    }

    private func makeHarness(
        openTimeout: Duration = .seconds(5),
        nonceTimeout: Duration = .seconds(5)
    ) -> Harness {
        let transport = MockStreamTransport()
        let clock = ManualTestClock()
        let client = EchoLinkProxyClient(
            callsign: Self.callsign,
            password: .publicProxy,
            transport: transport,
            clock: clock,
            openTimeout: openTimeout,
            nonceTimeout: nonceTimeout
        )
        return Harness(client: client, transport: transport, clock: clock)
    }

    private func fixtureLines(_ name: String) throws -> [Data] {
        try FixtureLoader.datagrams(name, in: Bundle.module)
    }

    /// The captured `STATUS 00 00 00 00`.
    private func statusSuccess() throws -> Data {
        try fixtureLines("live-proxy-login-in.hex")[1]
    }

    /// Runs `login()` with the fixture nonce delivered by the transport.
    @discardableResult
    private func login(_ harness: Harness) async throws -> Data {
        let nonce = Data(Self.nonce.utf8)
        let task = Task { try await harness.client.login() }
        // Injecting after starting mirrors a real session: the proxy speaks
        // first, but the client is already listening.
        harness.transport.inject(nonce)
        try await task.value
        return nonce
    }

    /// Starts `open(peer:)` and returns only once the client has actually
    /// written the `OPEN` frame.
    ///
    /// Injecting a reply before the request has been sent is not a shortcut —
    /// it is a different scenario, and one a real proxy cannot produce. It also
    /// races: the receive loop may see the `STATUS` before `open()` has marked
    /// itself in flight, in which case the frame is forwarded to `frames` as an
    /// unsolicited one and `open()` waits for a reply that has already gone by.
    /// With a `ManualTestClock` no timeout rescues it, so the test hangs rather
    /// than failing. Waiting for the write removes the race by making the
    /// ordering the one the protocol actually has.
    private func startOpen(
        _ harness: Harness,
        peer: EchoLinkPeerAddress
    ) async -> Task<Void, Error> {
        let before = harness.transport.sentCount
        let task = Task { try await harness.client.open(peer: peer) }
        // Deadline-bounded, not iteration-bounded: a fixed number of yields is
        // not a wait, and on a loaded machine it expires before the write.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while harness.transport.sentCount == before, ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return task
    }

    // MARK: - Login

    func testLoginSendsTheCallsignAndDigestForTheProxysNonce() async throws {
        let harness = makeHarness()
        try await login(harness)

        let expected = EchoLinkAuth.proxyLoginMessage(
            callsign: Self.callsign,
            password: .publicProxy,
            nonce: Self.nonce
        )
        XCTAssertEqual(harness.transport.sentBytes, expected)

        let state = await harness.client.sessionState
        XCTAssertEqual(state, .loggedIn)

        let seen = await harness.client.issuedNonce
        XCTAssertEqual(seen, Self.nonce)
    }

    func testLoginReadsTheNonceEvenWhenItArrivesOneByteAtATime() async throws {
        // The nonce is unframed and only 8 bytes, so it is exactly the sort of
        // thing a real TCP stream dribbles out.
        let harness = makeHarness()
        let task = Task { try await harness.client.login() }
        harness.transport.injectByteByByte(Data(Self.nonce.utf8))
        try await task.value

        let seen = await harness.client.issuedNonce
        XCTAssertEqual(seen, Self.nonce)
    }

    func testLoginTolerantOfNonceCoalescedWithTheFirstFrame() async throws {
        // The other chunking: the proxy's nonce and its first framed reply
        // arriving in one TCP segment. The nonce must be lifted off the front
        // and the remainder framed — not read as a 9-byte header.
        let harness = makeHarness()
        let task = Task { try await harness.client.login() }

        var chunk = Data(Self.nonce.utf8)
        chunk.append(try statusSuccess())
        harness.transport.inject(chunk)
        try await task.value

        let seen = await harness.client.issuedNonce
        XCTAssertEqual(seen, Self.nonce)
    }

    func testMalformedNonceIsATypedError() async throws {
        let harness = makeHarness()
        let task = Task { try await harness.client.login() }
        harness.transport.inject(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]))

        do {
            try await task.value
            XCTFail("a nonce that is not ASCII hex must not be accepted")
        } catch let error as EchoLinkProxyError {
            guard case .malformedNonce = error else {
                return XCTFail("expected .malformedNonce, got \(error)")
            }
        }
    }

    func testLoginFailsWhenTheStreamClosesBeforeTheNonce() async throws {
        let harness = makeHarness()
        let task = Task { try await harness.client.login() }
        harness.transport.finish()

        do {
            try await task.value
            XCTFail("login must not succeed on a stream that closed")
        } catch let error as EchoLinkProxyError {
            XCTAssertEqual(error, .streamClosed)
        }
    }

    func testLoginTwiceIsRejected() async throws {
        let harness = makeHarness()
        try await login(harness)

        do {
            try await harness.client.login()
            XCTFail("a second login must be rejected")
        } catch let error as EchoLinkProxyError {
            guard case .invalidTransition = error else {
                return XCTFail("expected .invalidTransition, got \(error)")
            }
        }
    }

    // MARK: - Open

    func testOpenSendsTheFrameAndCompletesOnStatusZero() async throws {
        let harness = makeHarness()
        try await login(harness)
        harness.transport.clearSent()

        let peer = EchoLinkPeerAddress(152, 67, 98, 197)
        let task = await startOpen(harness, peer: peer)
        harness.transport.inject(try statusSuccess())
        try await task.value

        let sent = try EchoLinkProxyFrame.parse(harness.transport.sentBytes).frame
        XCTAssertEqual(sent.type, .open)
        XCTAssertEqual(sent.peer, peer)
        XCTAssertTrue(sent.payload.isEmpty)

        let state = await harness.client.sessionState
        XCTAssertEqual(state, .open)
    }

    func testOpenFrameMatchesTheCapturedOne() async throws {
        // The captured OPEN, byte for byte: this is the fixture's whole point.
        let captured = try fixtureLines("live-proxy-open-out.hex")[0]
        let capturedFrame = try EchoLinkProxyFrame.parse(captured).frame

        let harness = makeHarness()
        try await login(harness)
        harness.transport.clearSent()

        let task = await startOpen(harness, peer: capturedFrame.peer)
        harness.transport.inject(try statusSuccess())
        try await task.value

        XCTAssertEqual(harness.transport.sentBytes, captured)
    }

    func testNonZeroStatusIsATypedError() async throws {
        let harness = makeHarness()
        try await login(harness)

        let rejection = EchoLinkProxyFrame(
            type: .status,
            payload: Data([0x00, 0x00, 0x00, 0x01])
        ).encoded

        let task = await startOpen(harness, peer: EchoLinkPeerAddress(1, 2, 3, 4))
        harness.transport.inject(rejection)

        do {
            try await task.value
            XCTFail("a non-zero status must not read as success")
        } catch let error as EchoLinkProxyError {
            XCTAssertEqual(error, .openRejected(status: 1))
        }

        // And the session is back where it was, not wedged.
        let state = await harness.client.sessionState
        XCTAssertEqual(state, .loggedIn)
    }

    func testOpenBeforeLoginIsRejected() async throws {
        let harness = makeHarness()
        do {
            try await harness.client.open(peer: EchoLinkPeerAddress(1, 2, 3, 4))
            XCTFail("open before login must be rejected")
        } catch let error as EchoLinkProxyError {
            guard case .invalidTransition = error else {
                return XCTFail("expected .invalidTransition, got \(error)")
            }
        }
    }

    func testRejectedLoginSurfacesAsStreamClosedOnOpen() async throws {
        // There is no "login failed" message in this protocol — a proxy that
        // refuses the digest simply drops the connection, which is why login()
        // cannot confirm anything on its own.
        let harness = makeHarness()
        try await login(harness)

        let task = await startOpen(harness, peer: EchoLinkPeerAddress(1, 2, 3, 4))
        harness.transport.finish()

        do {
            try await task.value
            XCTFail("open must fail when the proxy hangs up")
        } catch let error as EchoLinkProxyError {
            XCTAssertEqual(error, .streamClosed)
        }
    }

    // MARK: - Open timeout

    /// The bug this pins: a timed-out `OPEN` left `state` stuck at `.opening`
    /// forever, because `deadlineElapsed` failed the parked continuation but
    /// never restored `state`. Every later `open(peer:)` then threw
    /// `.invalidTransition(from: .opening, ...)` — wedged for the life of the
    /// session, on a link that had every reason to retry.
    func testOpenTimeoutRestoresStateSoARetryIsPossible() async throws {
        let harness = makeHarness(openTimeout: .seconds(5))
        try await login(harness)
        harness.transport.clearSent()

        let peer = EchoLinkPeerAddress(1, 2, 3, 4)
        let task = await startOpen(harness, peer: peer)

        // Don't advance until the deadline has actually armed — advancing
        // early computes the deadline against already-advanced time and the
        // timer never fires.
        let armed = await harness.clock.waitUntilSleepers(1)
        XCTAssertTrue(armed, "the open deadline never armed")
        harness.clock.advance(by: .seconds(5))

        do {
            try await task.value
            XCTFail("open() must time out when no STATUS ever arrives")
        } catch let error as EchoLinkProxyError {
            XCTAssertEqual(error, .timedOut(operation: "open"))
        }

        // Not `.opening`: the login is still good and no channel exists, so
        // this is the state that legally allows a retry.
        let state = await harness.client.sessionState
        XCTAssertEqual(state, .loggedIn)

        // And the retry itself must get past the state check.
        harness.transport.clearSent()
        let retry = await startOpen(harness, peer: peer)
        harness.transport.inject(try statusSuccess())
        try await retry.value

        let finalState = await harness.client.sessionState
        XCTAssertEqual(finalState, .open)
    }

    /// A STATUS that arrives after its OPEN already timed out must be inert:
    /// `openInFlight` was cleared by the timeout, so `handle(_:)` no longer
    /// treats this frame as the outcome of that attempt, and `state` — already
    /// restored to `.loggedIn` — must not be moved again by it.
    func testStatusArrivingAfterAnOpenTimeoutIsIgnored() async throws {
        let harness = makeHarness(openTimeout: .seconds(5))
        try await login(harness)

        let task = await startOpen(harness, peer: EchoLinkPeerAddress(1, 2, 3, 4))

        let armed = await harness.clock.waitUntilSleepers(1)
        XCTAssertTrue(armed, "the open deadline never armed")
        harness.clock.advance(by: .seconds(5))

        do {
            try await task.value
            XCTFail("open() must time out when no STATUS ever arrives")
        } catch let error as EchoLinkProxyError {
            XCTAssertEqual(error, .timedOut(operation: "open"))
        }

        // The STATUS that should have answered the timed-out OPEN, arriving
        // late — after this attempt no longer has anything waiting on it.
        harness.transport.inject(try statusSuccess())
        try? await Task.sleep(for: .milliseconds(50))

        let state = await harness.client.sessionState
        XCTAssertEqual(state, .loggedIn, "a stale STATUS must not resurrect or corrupt state")
    }

    // MARK: - Frame delivery to the session layer

    func testNonReplyFramesReachTheFramesStream() async throws {
        let harness = makeHarness()
        try await login(harness)

        let audio = try fixtureLines("live-proxy-audio-in.hex")
        let collected = Task { () -> [EchoLinkProxyFrame] in
            var frames: [EchoLinkProxyFrame] = []
            for await frame in harness.client.frames {
                frames.append(frame)
                if frames.count == 3 { break }
            }
            return frames
        }

        harness.transport.inject(Array(audio.prefix(3)))
        let frames = await collected.value

        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.encoded), Array(audio.prefix(3)))
        XCTAssertTrue(frames.allSatisfy { $0.type == .udpData })
    }

    func testStatusFrameIsNotForwardedWhileAnOpenIsInFlight() async throws {
        // The STATUS belongs to open(); forwarding it too would make the
        // session layer handle a reply that is not its business.
        let harness = makeHarness()
        try await login(harness)

        let audio = try fixtureLines("live-proxy-audio-in.hex")[0]
        let collected = Task { () -> EchoLinkProxyFrame? in
            for await frame in harness.client.frames { return frame }
            return nil
        }

        let task = await startOpen(harness, peer: EchoLinkPeerAddress(1, 2, 3, 4))
        harness.transport.inject(try statusSuccess())
        try await task.value
        harness.transport.inject(audio)

        let first = await collected.value
        XCTAssertEqual(first?.type, .udpData, "the STATUS must have been consumed, not forwarded")
    }

    // MARK: - Shutdown

    func testCloseSendsACloseFrameAndFinishesTheStream() async throws {
        let harness = makeHarness()
        try await login(harness)
        harness.transport.clearSent()

        await harness.client.close()

        let sent = try EchoLinkProxyFrame.parse(harness.transport.sentBytes).frame
        XCTAssertEqual(sent.type, .close)
        XCTAssertTrue(harness.transport.isClosed)

        let state = await harness.client.sessionState
        XCTAssertEqual(state, .closed)
    }

    func testCloseIsIdempotent() async throws {
        let harness = makeHarness()
        try await login(harness)
        await harness.client.close()
        await harness.client.close()

        let state = await harness.client.sessionState
        XCTAssertEqual(state, .closed)
    }

    func testDesynchronisedFramingFailsTheSession() async throws {
        let harness = makeHarness()
        try await login(harness)

        let task = await startOpen(harness, peer: EchoLinkPeerAddress(1, 2, 3, 4))
        // A length no real frame carries: the framing has come adrift, and a
        // length-prefixed stream cannot be resynchronised.
        harness.transport.inject(Data([0x02, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]))

        do {
            try await task.value
            XCTFail("a desynchronised stream must not look like success")
        } catch let error as EchoLinkProxyError {
            guard case .framing = error else {
                return XCTFail("expected .framing, got \(error)")
            }
        }
    }

    // MARK: - Actor reentrancy (plan rule 10)

    func testOpenReturnsWhenStatusIsProcessedDuringSend() async throws {
        // The test the plan requires: deliver the reply from *inside* the
        // awaited send, so the receive loop handles the STATUS before open()
        // has parked its continuation. A version of this client that inferred
        // "is an open in flight?" from `state` drops the outcome here and
        // hangs — the M17-3 defect, which showed up in 4% of whole-suite runs
        // and never once in 60 runs of its own class.
        let transport = ReplyDuringSendTransport(reply: try statusSuccess())
        let client = EchoLinkProxyClient(
            callsign: Self.callsign,
            password: .publicProxy,
            transport: transport,
            clock: ManualTestClock(),
            openTimeout: .seconds(5),
            nonceTimeout: .seconds(5)
        )

        // Log in first, without the reply-during-send behaviour interfering:
        // the nonce is unframed and arrives before anything is sent.
        transport.deliverOnNextSend = false
        let loginTask = Task { try await client.login() }
        transport.yieldToClient(Data(Self.nonce.utf8))
        try await loginTask.value

        transport.deliverOnNextSend = true

        let completed = Completion()
        let open = Task {
            try await client.open(peer: EchoLinkPeerAddress(1, 2, 3, 4))
            await completed.signal()
        }

        // Bounded cooperative wait — a regression must fail this test, not hang it.
        await waitWhile { await !completed.isSignalled }

        let returned = await completed.isSignalled
        open.cancel()
        XCTAssertTrue(returned, "open() never returned: the STATUS outcome was dropped")

        let state = await client.sessionState
        XCTAssertEqual(state, .open)
    }

    /// The deadline can fire while `open(peer:)` is still suspended in
    /// `send(...)` — before `awaitOpenOutcome()` has run — in which case the
    /// timeout is *stashed* and `finishOpen` has no continuation to resume.
    /// The flags must come down in the timeout path itself, or a STATUS
    /// landing in that window still passes `handle(_:)`'s in-flight gate,
    /// moves `state`, and overwrites the stashed timeout with a success for
    /// an attempt already declared dead. Found by review on the first
    /// version of the timeout fix, whose comment claimed `finishOpen`
    /// cleared the flag — true only on the parked path the other two
    /// timeout tests exercise.
    func testDeadlineFiringDuringTheOpenSendLeavesALateStatusInert() async throws {
        let transport = GatedSendTransport()
        let manualClock = ManualTestClock()
        let client = EchoLinkProxyClient(
            callsign: Self.callsign,
            password: .publicProxy,
            transport: transport,
            clock: manualClock,
            openTimeout: .seconds(5),
            nonceTimeout: .seconds(5)
        )

        let loginTask = Task { try await client.login() }
        transport.yieldToClient(Data(Self.nonce.utf8))
        try await loginTask.value

        // Collect what reaches the session layer, so the late STATUS can be
        // shown to arrive as an ordinary frame rather than vanish.
        let forwarded = Task { () -> EchoLinkProxyFrame? in
            for await frame in client.frames { return frame }
            return nil
        }

        transport.gateNextSend = true
        let open = Task { try await client.open(peer: EchoLinkPeerAddress(1, 2, 3, 4)) }

        // Hold until open() is genuinely inside send(), then fire the deadline
        // while it is still there.
        await waitWhile { !transport.isBlockedInSend }
        let armed = await manualClock.waitUntilSleepers(1)
        XCTAssertTrue(armed, "the open deadline never armed")
        manualClock.advance(by: .seconds(5))

        // The STATUS that would have answered the OPEN, arriving after the
        // deadline but before send() has returned. Hand the receive loop the
        // cooperative thread so it is fully processed while open() is still
        // suspended — the window under test.
        transport.yieldToClient(try statusSuccess())
        for _ in 0 ..< 100 { await Task.yield() }

        transport.releaseSend()

        do {
            _ = try await open.value
            XCTFail("open() must surface the timeout, not the superseded STATUS")
        } catch let error as EchoLinkProxyError {
            XCTAssertEqual(error, .timedOut(operation: "open"))
        }

        let state = await client.sessionState
        XCTAssertEqual(state, .loggedIn, "a STATUS for a dead attempt must not move state")

        // Bounded: under regression the STATUS is consumed as the open's
        // outcome and never reaches `frames`, so an unconditional await here
        // would hang the test instead of failing it. The collector has had
        // the cooperative thread repeatedly by now; cancelling turns a
        // missing frame into a nil and a failed assertion.
        for _ in 0 ..< 100 { await Task.yield() }
        forwarded.cancel()
        let frame = await forwarded.value
        XCTAssertEqual(frame?.type, .status, "the stale STATUS is forwarded, not swallowed")
    }
}

// MARK: - Reentrancy test doubles

/// Signals completion without the observer having to `await` the task itself.
private actor Completion {
    private(set) var isSignalled = false
    func signal() { isSignalled = true }
}

/// Delivers a canned reply to `incoming` from *inside* `send`, then yields
/// enough times for the client's receive loop to process it before `send`
/// returns — reproducing the actor-reentrancy window deterministically.
///
/// The stream counterpart of `M17ReflectorClientTests`'s double, with a switch
/// so the unframed login exchange can run before the behaviour is armed.
private final class ReplyDuringSendTransport: StreamTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let reply: Data
    private let lock = NSLock()
    private var sentChunks: [Data] = []
    private var deliverFlag = true

    var sent: [Data] { lock.withLock { sentChunks } }

    var deliverOnNextSend: Bool {
        get { lock.withLock { deliverFlag } }
        set { lock.withLock { deliverFlag = newValue } }
    }

    init(reply: Data) {
        var escaped: AsyncStream<Data>.Continuation!
        incoming = AsyncStream<Data>(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
        self.reply = reply
    }

    /// Deliver a chunk from outside a send, for the login handshake.
    func yieldToClient(_ bytes: Data) {
        continuation.yield(bytes)
    }

    func send(_ bytes: Data) async throws {
        lock.withLock { sentChunks.append(bytes) }
        guard deliverOnNextSend else { return }
        continuation.yield(reply)
        // Hand the receive loop the cooperative thread while this send is still
        // in flight, so the reply is fully handled before `open()` resumes.
        for _ in 0 ..< 100 { await Task.yield() }
    }

    func close() async {
        continuation.finish()
    }
}

/// Holds `send` open — cooperatively, no real blocking — until the test
/// releases it, so a deadline can be driven to fire *while* `open(peer:)` is
/// still suspended in its send: the window where the timeout outcome is
/// stashed rather than resumed, which is the case
/// `testDeadlineFiringDuringTheOpenSendLeavesALateStatusInert` exists for.
private final class GatedSendTransport: StreamTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var gateFlag = false
    private var releasedFlag = false
    private var inSendFlag = false

    /// When true, the next `send` parks until `releaseSend()`.
    var gateNextSend: Bool {
        get { lock.withLock { gateFlag } }
        set { lock.withLock { gateFlag = newValue } }
    }

    /// Whether a gated `send` is currently parked.
    var isBlockedInSend: Bool { lock.withLock { inSendFlag } }

    init() {
        var escaped: AsyncStream<Data>.Continuation!
        incoming = AsyncStream<Data>(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
    }

    func yieldToClient(_ bytes: Data) {
        continuation.yield(bytes)
    }

    func releaseSend() {
        lock.withLock { releasedFlag = true }
    }

    func send(_ bytes: Data) async throws {
        guard lock.withLock({ gateFlag }) else { return }
        lock.withLock { inSendFlag = true }
        defer { lock.withLock { inSendFlag = false } }
        while !lock.withLock({ releasedFlag }) {
            await Task.yield()
        }
    }

    func close() async {
        continuation.finish()
    }
}
