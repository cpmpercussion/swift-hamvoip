// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
import RadioCore
import TestSupport
@testable import M17Kit

// MARK: - Deterministic clock

/// A manually-driven `Clock`, so the connect and keepalive deadlines can be
/// reached instantly and reproducibly. Nothing in this file touches the wall
/// clock: no test here waits in real time, and none can flake on timing.
///
/// The same shape as the clock in `TransmitWatchdogTests` — `M17ReflectorClient`
/// injects its clock for exactly the reason `TransmitWatchdog` does. It is
/// duplicated rather than shared because `TestSupport` is not this task's to
/// modify.
private final class ManualTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        fileprivate var offset: Swift.Duration

        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        static func == (lhs: Instant, rhs: Instant) -> Bool { lhs.offset == rhs.offset }

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
    }

    typealias Duration = Swift.Duration

    private struct Waiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var offset: Swift.Duration = .zero
    private var waiters: [UUID: Waiter] = [:]
    private var sleepCallCount = 0

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var now: Instant { Instant(offset: withLock { offset }) }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        // Counted before the cancellation check so a timer cancelled before it
        // was ever scheduled still registers as "the task got here".
        withLock { sleepCallCount += 1 }
        if Task.isCancelled { throw CancellationError() }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyDue: Bool = withLock {
                    if offset >= deadline.offset { return true }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return false
                }
                if alreadyDue { continuation.resume() }
            }
        } onCancel: {
            let waiter = withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves virtual time forward and wakes every sleeper now due.
    func advance(by duration: Swift.Duration) {
        let ready: [Waiter] = withLock {
            offset += duration
            let due = waiters.filter { $0.value.deadline.offset <= offset }
            for key in due.keys { waiters.removeValue(forKey: key) }
            return Array(due.values)
        }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Yields cooperatively (never sleeps) until `sleep` has been entered at
    /// least `count` times, so a test can be sure a deadline was captured
    /// against the *current* virtual now before advancing it.
    func waitUntilSleeping(count: Int, maxAttempts: Int = 100_000) async -> Bool {
        for _ in 0..<maxAttempts {
            if withLock({ sleepCallCount }) >= count { return true }
            await Task.yield()
        }
        return false
    }
}

// MARK: - Event collection

/// Drains `M17ReflectorClient.events` into an array a test can assert on.
private actor EventCollector {
    private(set) var events: [M17ReflectorEvent] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<M17ReflectorEvent>) {
        task = Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
    }

    private func append(_ event: M17ReflectorEvent) { events.append(event) }

    /// Cooperative poll — no real-time waiting.
    func waitForCount(_ target: Int, maxAttempts: Int = 100_000) async -> Bool {
        for _ in 0..<maxAttempts {
            if events.count >= target { return true }
            await Task.yield()
        }
        return events.count >= target
    }
}

// MARK: - Tests

/// Connection-FSM tests for `M17ReflectorClient` (M17-3).
///
/// Everything runs over `MockTransport` and `ManualTestClock`: no socket is
/// opened, and no test waits on wall-clock time.
final class M17ReflectorClientTests: XCTestCase {

    private static let callsign = "AB1CD"

    // MARK: Harness

    private struct Harness {
        let client: M17ReflectorClient
        let transport: MockTransport
        let clock: ManualTestClock
        let events: EventCollector
    }

    private func makeHarness(
        callsign: String = M17ReflectorClientTests.callsign,
        sourceModule: M17Module? = nil,
        connectTimeout: Duration = .seconds(5),
        linkTimeout: Duration = .seconds(30)
    ) async throws -> Harness {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let client = try M17ReflectorClient(
            callsign: callsign,
            sourceModule: sourceModule,
            transport: transport,
            clock: clock,
            connectTimeout: connectTimeout,
            linkTimeout: linkTimeout)
        let collector = EventCollector()
        await collector.start(client.events)
        return Harness(client: client, transport: transport, clock: clock, events: collector)
    }

    /// Polls a condition by yielding, never by sleeping.
    private func waitUntil(
        _ description: String,
        maxAttempts: Int = 100_000,
        _ condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<maxAttempts {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for: \(description)")
    }

    /// Runs `connect(module:)` concurrently, waits for `CONN` to hit the wire,
    /// then hands back the in-flight task so the test can decide what the
    /// reflector answers.
    private func startConnect(_ harness: Harness, module: Character = "A") async -> Task<Void, Error> {
        let client = harness.client
        let task = Task { try await client.connect(module: module) }
        await waitUntil("CONN to be sent") { harness.transport.sentCount >= 1 }
        return task
    }

    private func fixture(_ name: String) throws -> Data {
        try FixtureLoader.datagram(name, in: Bundle.module)
    }

    private func expectError<T>(
        _ body: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (Error) -> Void
    ) async {
        do {
            _ = try await body()
            XCTFail("expected an error but the call returned", file: file, line: line)
        } catch {
            check(error)
        }
    }

    // MARK: Successful connect

    func testConnectSendsSpecExactConnAndLinksOnAckn() async throws {
        let harness = try await makeHarness()

        var state = await harness.client.linkState
        XCTAssertEqual(state, .disconnected)

        let connect = await startConnect(harness, module: "A")

        // Exactly the hand-built CONN fixture: magic, 6-byte address, module.
        XCTAssertEqual(harness.transport.sent.first, try fixture("reflector-conn.hex"))
        state = await harness.client.linkState
        XCTAssertEqual(state, .connecting)

        harness.transport.inject(try fixture("reflector-ackn.hex"))
        try await connect.value

        state = await harness.client.linkState
        XCTAssertEqual(state, .linked)

        let sawEvents = await harness.events.waitForCount(2)
        XCTAssertTrue(sawEvents)
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .linked])
    }

    func testSourceModuleIsAppendedToTheFromAddress() async throws {
        // "Control Packets": the 'From' field carries the callsign "including
        // module in last character (e.g. "A1BCD D")".
        let harness = try await makeHarness(sourceModule: try M17Module("D"))
        XCTAssertEqual(harness.client.address.callsign, "AB1CD D")

        let connect = await startConnect(harness, module: "A")
        let sent = try M17ControlPacket.parse(XCTUnwrap(harness.transport.sent.first))
        XCTAssertEqual(sent.address?.callsign, "AB1CD D")
        XCTAssertEqual(sent.magic, .connect)

        harness.transport.inject(try fixture("reflector-ackn.hex"))
        try await connect.value
    }

    func testConnectRejectsAModuleOutsideAToZ() async throws {
        let harness = try await makeHarness()
        await expectError({ try await harness.client.connect(module: "a") }) { error in
            guard case M17PacketError.invalidModule = error else {
                return XCTFail("expected .invalidModule, got \(error)")
            }
        }
        let state = await harness.client.linkState
        XCTAssertEqual(state, .disconnected)
        XCTAssertEqual(harness.transport.sentCount, 0, "no CONN should go out for a bad module")
    }

    // MARK: NACK

    func testNackSurfacesADescriptiveErrorAndLeavesTheClientDisconnected() async throws {
        let harness = try await makeHarness()
        let connect = await startConnect(harness, module: "B")

        harness.transport.inject(try fixture("reflector-nack.hex"))

        await expectError({ try await connect.value }) { error in
            XCTAssertEqual(error as? M17ReflectorClientError, .connectionRefused(module: "B"))
            XCTAssertTrue(
                "\(error)".contains("NACK"),
                "the error should say the reflector NACKed: '\(error)'")
            XCTAssertTrue("\(error)".contains("'B'"), "the error should name the module")
        }

        let state = await harness.client.linkState
        XCTAssertEqual(state, .disconnected)

        let sawEvents = await harness.events.waitForCount(2)
        XCTAssertTrue(sawEvents)
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .disconnected(.rejectedByReflector)])
    }

    // MARK: Connect timeout

    func testConnectTimesOutWhenTheReflectorNeverAnswers() async throws {
        let harness = try await makeHarness(connectTimeout: .seconds(5))
        let connect = await startConnect(harness)

        let sawSleep = await harness.clock.waitUntilSleeping(count: 1)
        XCTAssertTrue(sawSleep)
        harness.clock.advance(by: .seconds(5))

        await expectError({ try await connect.value }) { error in
            XCTAssertEqual(error as? M17ReflectorClientError, .connectTimedOut(.seconds(5)))
        }

        let state = await harness.client.linkState
        XCTAssertEqual(state, .disconnected)
        let sawEvents = await harness.events.waitForCount(2)
        XCTAssertTrue(sawEvents)
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .disconnected(.connectTimeout)])
    }

    // MARK: PING / PONG keepalive

    func testInboundPingIsAnsweredWithPong() async throws {
        let harness = try await makeHarness()
        try await link(harness)
        harness.transport.clearSent()

        harness.transport.inject(try fixture("reflector-ping.hex"))
        await waitUntil("PONG to be sent") { harness.transport.sentCount >= 1 }

        // The PONG carries our own 'From' address (Table 32), not the
        // reflector's.
        XCTAssertEqual(harness.transport.sent, [try fixture("reflector-pong.hex")])

        let state = await harness.client.linkState
        XCTAssertEqual(state, .linked, "answering a PING must not change the state")
    }

    func testRepeatedPingsKeepTheLinkUpIndefinitely() async throws {
        let harness = try await makeHarness(linkTimeout: .seconds(30))
        try await link(harness)

        // Two arms so far: the connect deadline, then the link deadline.
        var expectedSleeps = 2
        let sawInitialSleep = await harness.clock.waitUntilSleeping(count: expectedSleeps)
        XCTAssertTrue(sawInitialSleep)

        for round in 1...4 {
            // Nearly to the deadline, then a PING resets it.
            harness.clock.advance(by: .seconds(29))
            harness.transport.clearSent()
            harness.transport.inject(try fixture("reflector-ping.hex"))
            await waitUntil("PONG \(round)") { harness.transport.sentCount >= 1 }

            expectedSleeps += 1
            let sawResetSleep = await harness.clock.waitUntilSleeping(count: expectedSleeps)
            XCTAssertTrue(sawResetSleep)

            let state = await harness.client.linkState
            XCTAssertEqual(state, .linked, "link should survive keepalive round \(round)")
        }
    }

    func testLinkDropsWhenPingsStopArriving() async throws {
        let harness = try await makeHarness(linkTimeout: .seconds(30))
        try await link(harness)

        let sawLinkDeadlineArmed = await harness.clock.waitUntilSleeping(count: 2)
        XCTAssertTrue(sawLinkDeadlineArmed)

        // One keepalive lands, then the reflector goes quiet.
        harness.transport.inject(try fixture("reflector-ping.hex"))
        await waitUntil("PONG") { harness.transport.sentCount >= 2 }
        let sawDeadlineReset = await harness.clock.waitUntilSleeping(count: 3)
        XCTAssertTrue(sawDeadlineReset)

        harness.clock.advance(by: .seconds(30))

        await waitUntil("link to drop") { await harness.client.linkState == .disconnected }
        let sawEvents = await harness.events.waitForCount(3)
        XCTAssertTrue(sawEvents)
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .linked, .disconnected(.keepaliveTimeout)])
    }

    // MARK: Disconnect

    func testDisconnectSendsDiscAndTearsTheLinkDown() async throws {
        let harness = try await makeHarness()
        try await link(harness)
        harness.transport.clearSent()

        try await harness.client.disconnect()

        // Table 33: the long form, carrying our 'From' address.
        XCTAssertEqual(harness.transport.sent, [try fixture("reflector-disc.hex")])
        let state = await harness.client.linkState
        XCTAssertEqual(state, .disconnected)

        let sawEvents = await harness.events.waitForCount(3)
        XCTAssertTrue(sawEvents)
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .linked, .disconnected(.localRequest)])
    }

    func testInboundDiscIsAcknowledgedWithTheBareFourByteForm() async throws {
        let harness = try await makeHarness()
        try await link(harness)
        harness.transport.clearSent()

        harness.transport.inject(try fixture("reflector-disc.hex"))
        await waitUntil("DISC acknowledgement") { harness.transport.sentCount >= 1 }

        // "Acknowledged with 4-byte packet "DISC" (without the callsign
        // field)."
        XCTAssertEqual(harness.transport.sent, [try fixture("reflector-disc-ack.hex")])
        XCTAssertEqual(harness.transport.sent.first?.count, 4)

        await waitUntil("link to drop") { await harness.client.linkState == .disconnected }
        let sawEvents = await harness.events.waitForCount(3)
        XCTAssertTrue(sawEvents)
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .linked, .disconnected(.remoteRequest)])
    }

    func testTransportClosingDropsTheLink() async throws {
        let harness = try await makeHarness()
        try await link(harness)

        harness.transport.finish()

        await waitUntil("link to drop") { await harness.client.linkState == .disconnected }
        let sawEvents = await harness.events.waitForCount(3)
        XCTAssertTrue(sawEvents)
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .linked, .disconnected(.transportClosed)])
    }

    // MARK: Illegal transitions

    func testConnectWhileLinkedThrows() async throws {
        let harness = try await makeHarness()
        try await link(harness)
        harness.transport.clearSent()

        await expectError({ try await harness.client.connect(module: "B") }) { error in
            XCTAssertEqual(
                error as? M17ReflectorClientError,
                .invalidTransition(from: .linked, operation: "connect"))
        }
        XCTAssertEqual(harness.transport.sentCount, 0, "a rejected connect must not put bytes on the wire")
        let state = await harness.client.linkState
        XCTAssertEqual(state, .linked, "a rejected connect must not disturb the existing link")
    }

    func testConnectWhileConnectingThrows() async throws {
        let harness = try await makeHarness()
        let connect = await startConnect(harness)

        await expectError({ try await harness.client.connect(module: "B") }) { error in
            XCTAssertEqual(
                error as? M17ReflectorClientError,
                .invalidTransition(from: .connecting, operation: "connect"))
        }
        XCTAssertEqual(harness.transport.sentCount, 1, "only the first CONN should be on the wire")

        harness.transport.inject(try fixture("reflector-ackn.hex"))
        try await connect.value
    }

    func testDisconnectWhileDisconnectedThrows() async throws {
        let harness = try await makeHarness()
        await expectError({ try await harness.client.disconnect() }) { error in
            XCTAssertEqual(
                error as? M17ReflectorClientError,
                .invalidTransition(from: .disconnected, operation: "disconnect"))
        }
        XCTAssertEqual(harness.transport.sentCount, 0)
    }

    func testDisconnectTwiceThrowsTheSecondTime() async throws {
        let harness = try await makeHarness()
        try await link(harness)
        try await harness.client.disconnect()

        await expectError({ try await harness.client.disconnect() }) { error in
            XCTAssertEqual(
                error as? M17ReflectorClientError,
                .invalidTransition(from: .disconnected, operation: "disconnect"))
        }
    }

    func testClientCanReconnectAfterDisconnecting() async throws {
        let harness = try await makeHarness()
        try await link(harness)
        try await harness.client.disconnect()
        harness.transport.clearSent()

        let connect = await startConnect(harness, module: "Z")
        harness.transport.inject(try fixture("reflector-ackn.hex"))
        try await connect.value

        let state = await harness.client.linkState
        XCTAssertEqual(state, .linked)
        let sent = try M17ControlPacket.parse(XCTUnwrap(harness.transport.sent.first))
        let ownAddress = harness.client.address
        XCTAssertEqual(sent, .connect(from: ownAddress, module: try M17Module("Z")))
    }

    // MARK: Robustness

    func testUnparsableDatagramsAreIgnoredAndDoNotDisturbTheLink() async throws {
        let harness = try await makeHarness()
        try await link(harness)
        harness.transport.clearSent()

        let junk = try FixtureLoader.datagrams("reflector-malformed.hex", in: Bundle.module)
        harness.transport.inject(junk)
        // Then a real PING, to prove the loop is still alive and still linked.
        harness.transport.inject(try fixture("reflector-ping.hex"))
        await waitUntil("PONG after the junk") { harness.transport.sentCount >= 1 }

        XCTAssertEqual(harness.transport.sent, [try fixture("reflector-pong.hex")],
                       "malformed datagrams must produce no replies of their own")
        let state = await harness.client.linkState
        XCTAssertEqual(state, .linked)
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .linked])
    }

    func testStrayControlPacketsInTheWrongStateAreIgnored() async throws {
        let harness = try await makeHarness()

        // ACKN, PING and DISC arriving while disconnected must do nothing —
        // in particular they must not fabricate a link.
        harness.transport.inject(try fixture("reflector-ackn.hex"))
        harness.transport.inject(try fixture("reflector-ping.hex"))

        let connect = await startConnect(harness)
        harness.transport.inject(try fixture("reflector-ackn.hex"))
        try await connect.value

        // A second ACKN, and a PONG we should never receive, are both ignored.
        harness.transport.clearSent()
        harness.transport.inject(try fixture("reflector-ackn.hex"))
        harness.transport.inject(try fixture("reflector-pong.hex"))
        harness.transport.inject(try fixture("reflector-ping.hex"))
        await waitUntil("PONG") { harness.transport.sentCount >= 1 }

        XCTAssertEqual(harness.transport.sent.count, 1, "only the PING should have drawn a reply")
        let state = await harness.client.linkState
        XCTAssertEqual(state, .linked)
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .linked])
    }

    // MARK: Stream packets

    func testStreamPacketsOnALiveLinkAreSurfacedAsEvents() async throws {
        let harness = try await makeHarness()
        try await link(harness)

        harness.transport.inject(try fixture("reflector-stream.hex"))
        let sawEvents = await harness.events.waitForCount(3)
        XCTAssertTrue(sawEvents)

        let events = await harness.events.events
        guard case .stream(let packet) = events[2] else {
            return XCTFail("expected a stream event, got \(events[2])")
        }
        XCTAssertEqual(packet.source.callsign, "AB1CD")
        XCTAssertEqual(packet.playability, .playable)
    }

    /// FR-2.5 end to end: an encrypted stream reaches the client, and the
    /// client reports it as unplayable rather than offering to decrypt it.
    func testEncryptedStreamIsDeliveredButMarkedUnplayable() async throws {
        let harness = try await makeHarness()
        try await link(harness)

        harness.transport.inject(try fixture("reflector-stream-encrypted.hex"))
        let sawEvents = await harness.events.waitForCount(3)
        XCTAssertTrue(sawEvents)

        let events = await harness.events.events
        guard case .stream(let packet) = events[2] else {
            return XCTFail("expected a stream event, got \(events[2])")
        }
        XCTAssertTrue(packet.type.isEncrypted)
        XCTAssertEqual(packet.playability, .encrypted)
        XCTAssertFalse(packet.type.isPlayable)
    }

    func testStreamPacketsArrivingWhileDisconnectedAreDropped() async throws {
        let harness = try await makeHarness()
        try await link(harness)
        try await harness.client.disconnect()

        harness.transport.inject(try fixture("reflector-stream.hex"))
        for _ in 0..<200 { await Task.yield() }

        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .linked, .disconnected(.localRequest)])
    }

    // MARK: Whole session, fixture driven

    func testFullSessionFromTheRecordedFixture() async throws {
        let harness = try await makeHarness()
        let session = try FixtureLoader.datagrams("reflector-session.hex", in: Bundle.module)
        XCTAssertEqual(session.count, 4, "ACKN, PING, PING, DISC")

        let connect = await startConnect(harness)
        harness.transport.clearSent()

        harness.transport.inject(session[0])  // ACKN
        try await connect.value

        harness.transport.inject(session[1])  // PING
        await waitUntil("first PONG") { harness.transport.sentCount >= 1 }
        harness.transport.inject(session[2])  // PING
        await waitUntil("second PONG") { harness.transport.sentCount >= 2 }
        harness.transport.inject(session[3])  // DISC
        await waitUntil("DISC acknowledgement") { harness.transport.sentCount >= 3 }

        let pong = try fixture("reflector-pong.hex")
        XCTAssertEqual(harness.transport.sent, [pong, pong, try fixture("reflector-disc-ack.hex")])

        await waitUntil("link to drop") { await harness.client.linkState == .disconnected }
        let events = await harness.events.events
        XCTAssertEqual(events, [.connecting, .linked, .disconnected(.remoteRequest)])
    }

    // MARK: Shutdown

    func testShutdownDropsTheLinkAndClosesTheTransport() async throws {
        let harness = try await makeHarness()
        try await link(harness)
        harness.transport.clearSent()

        await harness.client.shutdown()

        XCTAssertEqual(harness.transport.sent, [try fixture("reflector-disc.hex")])
        XCTAssertTrue(harness.transport.isClosed)
        let state = await harness.client.linkState
        XCTAssertEqual(state, .disconnected)

        // Idempotent.
        await harness.client.shutdown()
    }

    // MARK: Reentrancy

    /// `connect()` must still return when `ACKN` is processed *during*
    /// `transport.send`, before the continuation is parked.
    ///
    /// This is a regression test for a real hang. `connect()` awaits
    /// `transport.send`, and an actor is reentrant across an await, so the
    /// receive loop can handle `ACKN` in that window. The `ACKN` handler sets
    /// `state = .linked` before delivering the outcome, and the delivery path
    /// used to stash an early result only while `state == .connecting` — so in
    /// this interleaving the success was dropped on the floor and `connect()`
    /// waited forever.
    ///
    /// Against the real `MockTransport` the window is narrow: it showed up as a
    /// whole-suite hang in roughly 4% of runs and never once in 60 runs of this
    /// class alone. `ReplyDuringSendTransport` makes the interleaving
    /// deterministic by yielding to the receive loop from inside `send`.
    func testConnectReturnsWhenAcknIsProcessedDuringSend() async throws {
        let transport = ReplyDuringSendTransport(reply: try fixture("reflector-ackn.hex"))
        let client = try M17ReflectorClient(
            callsign: Self.callsign,
            transport: transport,
            clock: ManualTestClock(),
            connectTimeout: .seconds(5),
            linkTimeout: .seconds(30))

        let completed = Completion()
        let connect = Task {
            try await client.connect(module: "A")
            await completed.signal()
        }

        // Bounded cooperative wait — a regression must fail this test, not hang it.
        for _ in 0..<200_000 where await !completed.isSignalled {
            await Task.yield()
        }

        let returned = await completed.isSignalled
        connect.cancel()
        XCTAssertTrue(returned, "connect() never returned: the ACKN outcome was dropped")

        let state = await client.linkState
        XCTAssertEqual(state, .linked)
    }

    // MARK: Shared steps

    /// Connects and links, leaving the harness in `.linked`.
    private func link(_ harness: Harness, module: Character = "A") async throws {
        let connect = await startConnect(harness, module: module)
        harness.transport.inject(try fixture("reflector-ackn.hex"))
        try await connect.value
        let state = await harness.client.linkState
        XCTAssertEqual(state, .linked)
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
private final class ReplyDuringSendTransport: DatagramTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let reply: Data
    private let lock = NSLock()
    private var sentDatagrams: [Data] = []

    var sent: [Data] { lock.withLock { sentDatagrams } }

    init(reply: Data) {
        var escaped: AsyncStream<Data>.Continuation!
        incoming = AsyncStream<Data>(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
        self.reply = reply
    }

    func send(_ datagram: Data) async throws {
        lock.withLock { sentDatagrams.append(datagram) }
        continuation.yield(reply)
        // Hand the receive loop the cooperative thread while this send is still
        // in flight, so the reply is fully handled before `connect()` resumes.
        for _ in 0..<100 { await Task.yield() }
    }

    func close() async {
        continuation.finish()
    }
}
