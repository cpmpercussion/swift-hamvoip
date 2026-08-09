// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import TestSupport
import XCTest

@testable import IAX2Kit

/// IAX-5: the outbound call state machine (RFC 5456 §6.2, §6.3, §6.7, §6.9).
///
/// Every test here runs on `MockTransport` and `ManualTestClock`: no socket is
/// opened and no test waits on real time (AU-5). The two synchronisation
/// primitives used are cooperative yielding (``waitFor(_:state:)`` and friends,
/// which spin the scheduler, never the wall clock) and
/// `ManualTestClock.waitUntilSleeping(count:)`, which is what makes the
/// timeout tests deterministic rather than racy.
final class IAX2CallTests: XCTestCase {

    /// The peer's 15-bit source call number in every fixture in this file.
    private let peerCallNumber: UInt16 = 0x0042

    /// Ours. `IAX2CallNumberAllocator` hands out 1 first, deterministically,
    /// which is what lets the fixtures address us by number.
    private let localCallNumber: UInt16 = 1

    // MARK: - Harness

    private struct Harness {
        let call: IAX2Call
        let transport: MockTransport
        let clock: ManualTestClock
        let allocator: IAX2CallNumberAllocator
    }

    private func makeHarness(
        request: IAX2CallRequest = IAX2CallRequest(calledNumber: "55553", username: "n0call"),
        configuration: IAX2Call.Configuration = IAX2Call.Configuration()
    ) async throws -> Harness {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let allocator = IAX2CallNumberAllocator()
        let call = try await IAX2Call.outbound(
            allocator: allocator,
            request: request,
            transport: transport,
            clock: clock,
            configuration: configuration)
        let number = call.sourceCallNumber
        XCTAssertEqual(number, localCallNumber, "the fixtures address us by this number")
        return Harness(call: call, transport: transport, clock: clock, allocator: allocator)
    }

    private func tearDown(_ harness: Harness) async {
        await harness.call.close()
        harness.transport.finish()
    }

    // MARK: - Synchronisation helpers (scheduler-bound, never real time)

    @discardableResult
    private func waitFor(
        _ call: IAX2Call,
        state expected: IAX2CallState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100_000 {
            if await call.state == expected { return true }
            await Task.yield()
        }
        let actual = await call.state
        XCTFail(
            "the call never reached state '\(expected)'; it is in '\(actual)'",
            file: file, line: line)
        return false
    }

    @discardableResult
    private func waitForSent(
        _ count: Int,
        _ transport: MockTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100_000 {
            if transport.sentCount >= count { return true }
            await Task.yield()
        }
        XCTFail(
            "expected \(count) sent datagram(s), saw \(transport.sentCount)",
            file: file, line: line)
        return false
    }

    /// Gives any *incorrect* extra work a fair chance to happen before a
    /// negative assertion, without touching the wall clock.
    private func settle(_ iterations: Int = 200) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    private actor EventLog {
        private(set) var events: [IAX2CallEvent] = []
        func append(_ event: IAX2CallEvent) { events.append(event) }
    }

    /// Starts draining `call.events` into a log. The stream is unbounded and
    /// created at init, so starting the drain after `start()` still sees every
    /// event; it finishes on its own when the call dies.
    private func startEventLog(_ call: IAX2Call) -> (EventLog, Task<Void, Never>) {
        let log = EventLog()
        let task = Task {
            for await event in call.events { await log.append(event) }
        }
        return (log, task)
    }

    // MARK: - Byte helpers

    private func hex(_ string: String) -> Data {
        let characters = string.filter { !$0.isWhitespace }
        precondition(characters.count % 2 == 0, "odd-length hex literal in a test")
        var bytes: [UInt8] = []
        var index = characters.startIndex
        while index < characters.endIndex {
            let next = characters.index(index, offsetBy: 2)
            guard let byte = UInt8(characters[index..<next], radix: 16) else {
                preconditionFailure("bad hex literal in a test: \(string)")
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Byte-for-byte datagram comparison, reported as hex so a failure is
    /// readable.
    private func assertDatagram(
        _ actual: Data?,
        _ expected: Data,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("\(what): no datagram was sent", file: file, line: line)
            return
        }
        XCTAssertEqual(hexString(actual), hexString(expected), what, file: file, line: line)
    }

    private func sentDatagram(_ transport: MockTransport, _ index: Int) -> Data? {
        let all = transport.sent
        return all.indices.contains(index) ? all[index] : nil
    }

    // MARK: - Frames as the peer would send them

    private func peerFrame(
        type: IAX2FrameType,
        subclass: IAX2Subclass,
        timestamp: UInt32,
        oSeqno: UInt8,
        iSeqno: UInt8,
        destination: UInt16? = nil,
        payload: [UInt8] = []
    ) -> Data {
        IAX2Frame.full(
            IAX2FullFrame(
                sourceCallNumber: peerCallNumber,
                destinationCallNumber: destination ?? localCallNumber,
                timestamp: timestamp,
                oSeqno: oSeqno,
                iSeqno: iSeqno,
                type: type,
                subclass: subclass,
                payload: payload)
        ).encoded()
    }

    private func peerIAX(
        _ message: IAX2Message,
        timestamp: UInt32,
        oSeqno: UInt8,
        iSeqno: UInt8,
        destination: UInt16? = nil,
        elements: [InformationElement] = []
    ) throws -> Data {
        peerFrame(
            type: .iax,
            subclass: IAX2Subclass(message),
            timestamp: timestamp,
            oSeqno: oSeqno,
            iSeqno: iSeqno,
            destination: destination,
            payload: try InformationElement.serialize(elements))
    }

    private func peerControl(
        _ control: IAX2Control,
        timestamp: UInt32,
        oSeqno: UInt8,
        iSeqno: UInt8
    ) -> Data {
        peerFrame(
            type: .control,
            subclass: IAX2Subclass(control),
            timestamp: timestamp,
            oSeqno: oSeqno,
            iSeqno: iSeqno)
    }

    /// Drives a call to `up` through ACCEPT + ANSWER, for tests that are about
    /// what happens *after* setup. The scripted-session test below is the one
    /// that proves this exchange against a fixture.
    private func bringUp(_ harness: Harness) async throws {
        try await harness.call.start()
        harness.transport.inject(
            try peerIAX(
                .accept, timestamp: 100, oSeqno: 0, iSeqno: 1,
                elements: [.format(.g711MuLaw)]))
        await waitFor(harness.call, state: .accepted)
        harness.transport.inject(peerControl(.answer, timestamp: 200, oSeqno: 1, iSeqno: 1))
        await waitFor(harness.call, state: .up)
    }

    // MARK: - The scripted session (§6.2, §6.3, §9.6; notes §12 flow (a))

    /// NEW → ACCEPT → RINGING → ANSWER → `up`, then HANGUP → `dead`, driven
    /// entirely by a fixture of the inbound datagram sequence, asserting the
    /// exact bytes the client put on the wire at each step.
    func testScriptedSessionReachesUpThenDeadOnHangup() async throws {
        let harness = try await makeHarness()
        let (log, logTask) = startEventLog(harness.call)

        try await harness.call.start()
        harness.transport.inject(
            try FixtureLoader.datagrams("call-basic-session.hex", in: Bundle.module))

        await waitFor(harness.call, state: .dead)
        await logTask.value
        let events = await log.events

        // --- The FSM walked the §6.2 path exactly once ------------------
        let states = events.compactMap { event -> IAX2CallState? in
            guard case .stateChanged(_, let to) = event else { return nil }
            return to
        }
        XCTAssertEqual(
            states, [.newSent, .accepted, .answered, .up, .receivedHangup, .dead],
            "idle → newSent → accepted → answered → up → receivedHangup → dead")

        XCTAssertTrue(events.contains(.accepted(format: .g711MuLaw)))
        XCTAssertTrue(events.contains(.control(.ringing)), "RINGING is surfaced (§6.3.3)")
        XCTAssertTrue(events.contains(.control(.answer)), "ANSWER is surfaced (§6.3.4)")
        XCTAssertEqual(
            events.last, .ended(.remoteHangup(cause: "Bye", causeCode: 16)),
            "the CAUSE and CAUSECODE IEs of the HANGUP reach the caller (§8.6.21, §8.6.33)")

        let peer = await harness.call.destinationCallNumber
        XCTAssertEqual(peer, peerCallNumber, "the peer's call number is learned from its ACCEPT")
        let format = await harness.call.negotiatedFormat
        XCTAssertEqual(format, .g711MuLaw, "the FORMAT IE of the ACCEPT (§6.2.3)")

        // --- The exact wire output --------------------------------------
        XCTAssertEqual(harness.transport.sentCount, 5, "NEW + one ACK per inbound full frame")

        // NEW: F=1 source 1, destination 0 ("the remote peer's source call
        // identifier is not created until after receipt of this frame",
        // §6.2.2), time-stamp 0, OSeqno 0, ISeqno 0 (§7), type 0x06, subclass
        // 0x01. IEs in the order §6.2.2/§8.6.10 require — VERSION first.
        assertDatagram(
            sentDatagram(harness.transport, 0),
            hex(
                "8001 0000 00000000 00 00 06 01"
                    + "0b02 0002"  // VERSION = 2 (§8.6.10), MUST be first
                    + "0105 3535353533"  // CALLED NUMBER "55553" (§8.6.1)
                    + "0606 6e30 6361 6c6c"  // USERNAME "n0call" (§8.6.6)
                    + "0804 00000004"  // CAPABILITY = mu-law (§8.6.7, §8.7)
                    + "0904 00000004"  // FORMAT = mu-law (§8.6.8)
                    + "2601 00"  // CALLINGPRES (§8.6.29)
                    + "2701 00"  // CALLINGTON (§8.6.30)
                    + "2802 0000"),  // CALLINGTNS (§8.6.31)
            "the NEW message")

        // Every ACK: OSeqno unchanged at 1 ("the ACK… does not change the
        // message count", §7), ISeqno advancing one per inbound full frame,
        // and the acknowledged frame's time-stamp echoed back (§6.9.1).
        assertDatagram(
            sentDatagram(harness.transport, 1), hex("8001 0042 00000064 01 01 06 04"),
            "ACK of the ACCEPT — required by §6.2.3, echoing time-stamp 100")
        assertDatagram(
            sentDatagram(harness.transport, 2), hex("8001 0042 000000c8 01 02 06 04"),
            "ACK of the RINGING — §8.1.1 and the §9.6 flow, not the §6.9.1 list")
        assertDatagram(
            sentDatagram(harness.transport, 3), hex("8001 0042 0000012c 01 03 06 04"),
            "ACK of the ANSWER")
        assertDatagram(
            sentDatagram(harness.transport, 4), hex("8001 0042 00000190 01 04 06 04"),
            "ACK of the HANGUP — \"MUST immediately respond with an ACK\" (§6.2.5)")

        await tearDown(harness)
    }

    /// After a HANGUP the leg is gone, and "any messages received that
    /// reference that call leg… MUST be answered with an INVAL message"
    /// (§6.2.5).
    func testFramesAfterHangupAreAnsweredWithINVAL() async throws {
        let harness = try await makeHarness()
        try await harness.call.start()
        harness.transport.inject(
            try FixtureLoader.datagrams("call-basic-session.hex", in: Bundle.module))
        await waitFor(harness.call, state: .dead)
        await waitForSent(5, harness.transport)

        harness.transport.inject(try peerIAX(.ping, timestamp: 500, oSeqno: 4, iSeqno: 1))
        await waitForSent(6, harness.transport)

        let reply = try XCTUnwrap(IAX2Frame.parse(XCTUnwrap(sentDatagram(harness.transport, 5))).fullFrame)
        XCTAssertEqual(reply.iaxMessage, .inval, "RFC 5456 §6.2.5")
        XCTAssertEqual(reply.sourceCallNumber, localCallNumber)
        XCTAssertEqual(reply.destinationCallNumber, peerCallNumber)
        XCTAssertEqual(reply.timestamp, 500, "the offending frame's time-stamp is echoed")

        await tearDown(harness)
    }

    // MARK: - Authentication (§6.2.6, §6.2.7, §8.6.13–§8.6.15; notes §13)

    /// NEW → AUTHREQ → AUTHREP → ACCEPT → ANSWER, asserting the MD5 RESULT IE
    /// for a known challenge and secret.
    func testAuthenticatedSessionSendsExpectedMD5Result() async throws {
        // MD5( challenge ‖ password ), challenge first, no separator (§8.6.15).
        // Independently computed:
        //     printf '%s' '1234567890hunter2' | md5
        //     423705a562413ef5e90f24f5a4bd2a53
        // Rendered as lowercase 32-character hex — OQ-5's documented
        // assumption, which lives in IAX2Auth and nowhere else.
        let expectedDigest = "423705a562413ef5e90f24f5a4bd2a53"
        XCTAssertEqual(
            IAX2Auth.md5Response(challenge: "1234567890", secret: "hunter2"), expectedDigest,
            "the digest this test asserts on must be the one IAX2Auth computes")

        let harness = try await makeHarness(
            request: IAX2CallRequest(
                calledNumber: "55553", username: "n0call", secret: "hunter2"))
        let (log, logTask) = startEventLog(harness.call)

        try await harness.call.start()
        harness.transport.inject(
            try FixtureLoader.datagrams("call-auth-session.hex", in: Bundle.module))
        await waitFor(harness.call, state: .up)
        await waitForSent(5, harness.transport)

        // ACK of the AUTHREQ (§6.9.1 permits an ACK alongside the AUTHREP that
        // §6.2.7 requires), then the AUTHREP itself.
        assertDatagram(
            sentDatagram(harness.transport, 1), hex("8001 0042 00000032 01 01 06 04"),
            "ACK of the AUTHREQ, echoing its time-stamp 50")
        assertDatagram(
            sentDatagram(harness.transport, 2),
            hex("8001 0042 00000000 01 01 06 09 10 20") + Data(expectedDigest.utf8),
            "AUTHREP carrying MD5 RESULT (IE 0x10, 32 octets) — OSeqno 1, ISeqno 1")

        // The AUTHREP carries the MD5 RESULT and nothing else: §8.6.6 does not
        // list USERNAME as an AUTHREP IE, and there is no plaintext PASSWORD
        // path at all (§8.6.13, §10).
        let authrep = try XCTUnwrap(
            IAX2Frame.parse(XCTUnwrap(sentDatagram(harness.transport, 2))).fullFrame)
        XCTAssertEqual(authrep.iaxMessage, .authrep)
        XCTAssertEqual(
            try InformationElement.parseList(authrep.payload), [.md5Result(expectedDigest)])

        assertDatagram(
            sentDatagram(harness.transport, 3), hex("8001 0042 00000064 02 02 06 04"),
            "ACK of the ACCEPT — OSeqno 2 now that the AUTHREP consumed 1")
        assertDatagram(
            sentDatagram(harness.transport, 4), hex("8001 0042 000000c8 02 03 06 04"),
            "ACK of the ANSWER")

        // Read the event log only once the stream has finished — `close()`
        // finishes it — so every event has certainly been drained.
        await tearDown(harness)
        await logTask.value
        let events = await log.events
        let states = events.compactMap { event -> IAX2CallState? in
            guard case .stateChanged(_, let to) = event else { return nil }
            return to
        }
        XCTAssertEqual(
            Array(states.prefix(6)),
            [.newSent, .authRequested, .authReplied, .accepted, .answered, .up],
            "idle → newSent → authRequested → authReplied → accepted → answered → up")
        XCTAssertTrue(
            events.contains(.challenged(challenge: "1234567890", methods: .md5)),
            "the AUTHREQ's CHALLENGE and AUTHMETHODS are surfaced")
    }

    /// "If a peer offers only 0x0001, we cannot authenticate under RFC 5456 and
    /// should abandon the exchange." (notes §13) The same holds for RSA-only,
    /// which is out of scope for v1: it fails clearly rather than sending an
    /// AUTHREP the peer cannot check.
    func testRSAOnlyChallengeFailsClearly() async throws {
        let harness = try await makeHarness(
            request: IAX2CallRequest(
                calledNumber: "55553", username: "n0call", secret: "hunter2"))
        try await harness.call.start()

        let authreq = try peerIAX(
            .authreq, timestamp: 50, oSeqno: 0, iSeqno: 1,
            elements: [
                .username("n0call"),
                .authMethods(IEAuthMethods.rsa),
                .challenge("1234567890"),
            ])

        do {
            try await harness.call.deliver(datagram: authreq)
            XCTFail("an RSA-only AUTHREQ must not be answered")
        } catch let error as IAX2CallError {
            XCTAssertEqual(error, .unsupportedAuthentication(offered: .rsa))
        }

        // Nothing beyond the NEW and the channel's ACK of the AUTHREQ: no
        // AUTHREP was invented, and there is no plaintext path to fall back to.
        await settle()
        XCTAssertEqual(harness.transport.sentCount, 2)
        await tearDown(harness)
    }

    /// An AUTHREQ with no CHALLENGE IE is malformed (§8.6.14 marks it MUST).
    func testAuthRequestWithoutChallengeFails() async throws {
        let harness = try await makeHarness(
            request: IAX2CallRequest(calledNumber: "55553", secret: "hunter2"))
        try await harness.call.start()

        let authreq = try peerIAX(
            .authreq, timestamp: 50, oSeqno: 0, iSeqno: 1,
            elements: [.authMethods(IEAuthMethods.md5)])
        do {
            try await harness.call.deliver(datagram: authreq)
            XCTFail("an AUTHREQ without a CHALLENGE must not be answered")
        } catch let error as IAX2CallError {
            XCTAssertEqual(error, .missingChallenge)
        }
        await tearDown(harness)
    }

    // MARK: - REJECT (§6.2.4; notes §12 flow (c))

    func testRejectIsAckedAndSurfacesTheCause() async throws {
        let harness = try await makeHarness()
        let (log, logTask) = startEventLog(harness.call)

        try await harness.call.start()
        harness.transport.inject(try FixtureLoader.datagrams("call-reject.hex", in: Bundle.module))
        await waitFor(harness.call, state: .dead)
        await logTask.value

        let termination = await harness.call.termination
        XCTAssertEqual(
            termination, .rejected(cause: "No route to destination", causeCode: 3),
            "the CAUSE IE (§8.6.21) and CAUSECODE IE (§8.6.33) reach the caller")

        let events = await log.events
        let states = events.compactMap { event -> IAX2CallState? in
            guard case .stateChanged(_, let to) = event else { return nil }
            return to
        }
        XCTAssertEqual(states, [.newSent, .rejected, .dead])

        // "(Note: REJECT messages require an explicit ACK.)" (§6.2.4)
        XCTAssertEqual(harness.transport.sentCount, 2)
        assertDatagram(
            sentDatagram(harness.transport, 1), hex("8001 0042 00000064 01 01 06 04"),
            "the explicit ACK the REJECT requires, echoing its time-stamp")

        await tearDown(harness)
    }

    // MARK: - Network monitoring (§6.7; notes §12)

    /// "Receipt of a PING requires an acknowledging PONG be sent." (§6.7.2)
    /// PONG and LAGRP each echo the time-stamp of the message they answer
    /// (§6.7.3, §6.7.5, trap 9).
    func testPingIsAnsweredWithPongAndLagrqWithLagrp() async throws {
        let harness = try await makeHarness()
        try await harness.call.start()
        harness.transport.inject(
            try FixtureLoader.datagrams("call-ping-lagrq.hex", in: Bundle.module))
        await waitForSent(5, harness.transport)
        await settle()

        XCTAssertEqual(harness.transport.sentCount, 5, "NEW, ACK, PONG, ACK, LAGRP")

        assertDatagram(
            sentDatagram(harness.transport, 1), hex("8001 0042 000003e8 01 01 06 04"),
            "ACK of the PING")
        assertDatagram(
            sentDatagram(harness.transport, 2), hex("8001 0042 000003e8 01 01 06 03"),
            "PONG echoing the PING's time-stamp 1000, OSeqno 1")
        assertDatagram(
            sentDatagram(harness.transport, 3), hex("8001 0042 000007d0 02 02 06 04"),
            "ACK of the LAGRQ")
        assertDatagram(
            sentDatagram(harness.transport, 4), hex("8001 0042 000007d0 02 02 06 0c"),
            "LAGRP echoing the LAGRQ's time-stamp 2000, OSeqno 2")

        // Neither message touches call state (§6.7 is orthogonal to §6.2).
        let state = await harness.call.state
        XCTAssertEqual(state, .newSent)

        await tearDown(harness)
    }

    // MARK: - Demultiplexing (§4, §6.2.1, §6.9.2; notes §15)

    /// A frame naming a call number we do not have is answered with INVAL
    /// (§6.9.2), mirroring the call-number pair so the peer can destroy its own
    /// side, and echoing the time-stamp so it can tell which frame provoked it.
    func testFrameForUnknownCallNumberIsAnsweredWithINVAL() async throws {
        let harness = try await makeHarness()
        try await harness.call.start()
        harness.transport.inject(
            try FixtureLoader.datagrams("call-unknown-callno.hex", in: Bundle.module))
        await waitForSent(2, harness.transport)
        await settle()

        XCTAssertEqual(harness.transport.sentCount, 2, "the NEW, then exactly one INVAL")
        assertDatagram(
            sentDatagram(harness.transport, 1), hex("8009 0042 00000064 00 00 06 0a"),
            "INVAL for call 9: source 9, destination 0x42, echoed time-stamp, OSeqno/ISeqno 0")

        // The FSM did not budge, and nothing was fed to the reliable channel.
        let state = await harness.call.state
        XCTAssertEqual(state, .newSent)
        let iSeqno = await harness.call.expectedInboundSequenceNumber()
        XCTAssertEqual(iSeqno, 0, "a frame for another call must not advance our ISeqno")

        await tearDown(harness)
    }

    /// A full frame addressed to us but bearing the wrong *source* call number
    /// is not ours either: "A call leg is marked with two unique integers, one
    /// assigned by each peer" (§4).
    func testFrameFromTheWrongPeerCallNumberIsAnsweredWithINVAL() async throws {
        let harness = try await makeHarness()
        try await bringUp(harness)
        harness.transport.clearSent()

        let impostor = IAX2Frame.full(
            IAX2FullFrame(
                sourceCallNumber: 0x0099,
                destinationCallNumber: localCallNumber,
                timestamp: 700,
                oSeqno: 2,
                iSeqno: 1,
                type: .iax,
                subclass: IAX2Subclass(.ping))
        ).encoded()
        harness.transport.inject(impostor)
        await waitForSent(1, harness.transport)

        let reply = try XCTUnwrap(
            IAX2Frame.parse(XCTUnwrap(sentDatagram(harness.transport, 0))).fullFrame)
        XCTAssertEqual(reply.iaxMessage, .inval)
        XCTAssertEqual(reply.destinationCallNumber, 0x0099)
        let state = await harness.call.state
        XCTAssertEqual(state, .up, "our call is unaffected")

        await tearDown(harness)
    }

    /// Mini frames carry no destination call number (§8.1.2), so they are
    /// matched on the peer's source call number alone — and handed to IAX-6
    /// untouched.
    func testMiniFramesAreMatchedOnSourceCallNumberAndSurfacedAsMedia() async throws {
        let harness = try await makeHarness()
        let (log, logTask) = startEventLog(harness.call)
        try await bringUp(harness)
        harness.transport.clearSent()

        let ours = IAX2MiniFrame(
            sourceCallNumber: peerCallNumber, timestamp: 320, payload: [0xFF, 0x7F])
        let strangers = IAX2MiniFrame(
            sourceCallNumber: 0x0099, timestamp: 320, payload: [0x01, 0x02])
        harness.transport.inject(IAX2Frame.mini(ours).encoded())
        harness.transport.inject(IAX2Frame.mini(strangers).encoded())
        await settle()

        XCTAssertEqual(
            harness.transport.sentCount, 0,
            "a mini frame is never ACKed (§6.10) and an unmatched one cannot be INVALed")

        await tearDown(harness)
        await logTask.value
        let logged = await log.events
        let media = logged.filter { event in
            if case .media = event { return true }
            return false
        }
        XCTAssertEqual(media, [.media(.mini(ours))], "the stranger's mini frame is dropped")
    }

    // MARK: - Illegal transitions throw (§6.2.3, §6.3.1)

    /// "These messages MUST only be sent after an IAX call leg has been
    /// ACCEPTed." (§6.3.1) An ANSWER answering a NEW is a protocol violation,
    /// not a shortcut to `up`.
    func testAnsweringBeforeAcceptingThrows() async throws {
        let harness = try await makeHarness()
        try await harness.call.start()

        do {
            try await harness.call.deliver(
                datagram: peerControl(.answer, timestamp: 100, oSeqno: 0, iSeqno: 1))
            XCTFail("a Control ANSWER before the ACCEPT must throw")
        } catch let error as IAX2CallError {
            guard case .illegalTransition(let from, _) = error else {
                return XCTFail("expected an illegal transition, got \(error)")
            }
            XCTAssertEqual(from, .newSent)
        }

        let state = await harness.call.state
        XCTAssertEqual(state, .newSent, "the FSM did not move")
        await tearDown(harness)
    }

    func testStartingTwiceThrows() async throws {
        let harness = try await makeHarness()
        try await harness.call.start()
        do {
            try await harness.call.start()
            XCTFail("a second NEW on the same leg must throw")
        } catch let error as IAX2CallError {
            XCTAssertEqual(error, .illegalTransition(from: .newSent, attempted: "start"))
        }
        XCTAssertEqual(harness.transport.sentCount, 1, "no second NEW went out")
        await tearDown(harness)
    }

    func testHangingUpAnIdleCallThrows() async throws {
        let harness = try await makeHarness()
        do {
            try await harness.call.hangup()
            XCTFail("there is no call leg to hang up")
        } catch let error as IAX2CallError {
            XCTAssertEqual(error, .illegalTransition(from: .idle, attempted: "hangup"))
        }
        XCTAssertEqual(harness.transport.sentCount, 0)
        await tearDown(harness)
    }

    func testSendingMediaBeforeTheCallIsAcceptedThrows() async throws {
        let harness = try await makeHarness()
        try await harness.call.start()
        do {
            _ = try await harness.call.send(
                type: .voice, subclass: IAX2Subclass(mediaFormat: MediaFormat.g711MuLaw.rawValue)!,
                payload: [0xFF])
            XCTFail("media before the ACCEPT must throw")
        } catch let error as IAX2CallError {
            XCTAssertEqual(error, .notEstablished(state: .newSent))
        }
        do {
            try await harness.call.sendMini(payload: [0xFF])
            XCTFail("a mini frame requires an established call (§8.1.2)")
        } catch let error as IAX2CallError {
            XCTAssertEqual(error, .notEstablished(state: .newSent))
        }
        XCTAssertEqual(harness.transport.sentCount, 1)
        await tearDown(harness)
    }

    /// The one inbound message the RFC says to ignore rather than reject: "If a
    /// subsequent ACCEPT message is received for a call that has already
    /// started… the message MUST be ignored." (§6.2.3)
    func testASecondAcceptIsIgnoredRatherThanThrown() async throws {
        let harness = try await makeHarness()
        try await bringUp(harness)
        harness.transport.clearSent()

        try await harness.call.deliver(
            datagram: try peerIAX(
                .accept, timestamp: 300, oSeqno: 2, iSeqno: 1, elements: [.format(.gsmFullRate)]))

        let state = await harness.call.state
        XCTAssertEqual(state, .up)
        let format = await harness.call.negotiatedFormat
        XCTAssertEqual(format, .g711MuLaw, "the second ACCEPT must not renegotiate the codec")
        await tearDown(harness)
    }

    // MARK: - Teardown (§6.2.5; notes trap 18)

    func testLocalHangupSendsCauseAndDestroysTheLegImmediately() async throws {
        let harness = try await makeHarness()
        try await bringUp(harness)
        harness.transport.clearSent()

        try await harness.call.hangup()

        let state = await harness.call.state
        XCTAssertEqual(
            state, .dead,
            "\"After sending a HANGUP message, the sender MUST destroy the call\" (§6.2.5) — "
                + "without waiting for the ACK")
        let termination = await harness.call.termination
        XCTAssertEqual(
            termination, .localHangup(cause: "Normal call clearing", causeCode: 16))

        // OSeqno 1: the NEW consumed 0 and the two ACKs since are exempt (§7).
        // ISeqno 2: the ACCEPT and the ANSWER have been received.
        let hangup = try XCTUnwrap(
            IAX2Frame.parse(XCTUnwrap(sentDatagram(harness.transport, 0))).fullFrame)
        XCTAssertEqual(hangup.iaxMessage, .hangup)
        XCTAssertEqual(hangup.oSeqno, 1)
        XCTAssertEqual(hangup.iSeqno, 2)
        XCTAssertEqual(
            try InformationElement.parseList(hangup.payload),
            [.cause("Normal call clearing"), .causeCode(16)])

        await tearDown(harness)
    }

    /// Control HANGUP (frame type `0x04`, subclass `0x01`) is **not** IAX
    /// HANGUP (type `0x06`, subclass `0x05`). Only the latter destroys a call
    /// leg under §6.2.5 (notes trap 18).
    func testControlHangupIsNotIAXHangup() async throws {
        let harness = try await makeHarness()
        let (log, logTask) = startEventLog(harness.call)
        try await bringUp(harness)

        try await harness.call.deliver(
            datagram: peerControl(.hangup, timestamp: 300, oSeqno: 2, iSeqno: 1))
        await settle()

        var state = await harness.call.state
        XCTAssertEqual(state, .up, "Control 0x01 reports; it does not tear the leg down")

        // The IAX one does tear it down.
        try await harness.call.deliver(
            datagram: try peerIAX(
                .hangup, timestamp: 400, oSeqno: 3, iSeqno: 1,
                elements: [.cause("Bye"), .causeCode(16)]))
        state = await harness.call.state
        XCTAssertEqual(state, .dead)
        let termination = await harness.call.termination
        XCTAssertEqual(termination, .remoteHangup(cause: "Bye", causeCode: 16))

        await tearDown(harness)
        await logTask.value
        let events = await log.events
        XCTAssertTrue(
            events.contains(.control(.hangup)),
            "the Control HANGUP is surfaced to the caller, it just does not end the call")
    }

    /// "Upon receipt of an INVAL, a peer MUST destroy its side of a call."
    /// (§6.9.2)
    func testInvalDestroysTheCall() async throws {
        let harness = try await makeHarness()
        try await bringUp(harness)
        harness.transport.clearSent()

        try await harness.call.deliver(
            datagram: try peerIAX(.inval, timestamp: 300, oSeqno: 2, iSeqno: 1))

        let state = await harness.call.state
        XCTAssertEqual(state, .dead)
        let termination = await harness.call.termination
        XCTAssertEqual(termination, .invalidated)
        await settle()
        XCTAssertEqual(harness.transport.sentCount, 0, "an INVAL is not itself acknowledged (§7)")

        await tearDown(harness)
    }

    // MARK: - Timeouts (local policy; RC-1's note, §7, §6.6)

    /// `NWConnection` retries an unreachable peer internally and never
    /// surfaces the failure, so the deadline has to live here. When it fires
    /// the leg is destroyed **silently** — the peer never answered, and §6.6
    /// forbids "other indications over the errant IAX call leg".
    func testConnectTimeoutFiresAndSendsNoHangup() async throws {
        // A retransmission interval far beyond the connect deadline, so this
        // test isolates the deadline: the only timer that can fire is ours.
        let configuration = IAX2Call.Configuration(
            connectTimeout: .seconds(5),
            channel: ReliableChannel.Configuration(initialRetryInterval: .seconds(600)))
        let harness = try await makeHarness(configuration: configuration)
        let (log, logTask) = startEventLog(harness.call)

        try await harness.call.start()

        // Two timers are now armed against the clock's current `now`: the NEW's
        // retransmission timer and the connect deadline. Waiting for both to be
        // asleep before advancing is what makes this deterministic.
        let armed = await harness.clock.waitUntilSleeping(count: 2)
        XCTAssertTrue(
            armed, "expected the retransmission timer and the connect deadline to be armed")

        let waiter = Task { try await harness.call.waitUntilUp() }
        harness.clock.advance(by: .seconds(5))

        await waitFor(harness.call, state: .dead)
        await logTask.value

        let termination = await harness.call.termination
        XCTAssertEqual(termination, .connectTimedOut(.seconds(5)))
        let lastEvent = await log.events.last
        XCTAssertEqual(lastEvent, .ended(.connectTimedOut(.seconds(5))))

        do {
            try await waiter.value
            XCTFail("waitUntilUp must not return for a call that never came up")
        } catch let error as IAX2CallEnded {
            XCTAssertEqual(error.reason, .connectTimedOut(.seconds(5)))
        }

        XCTAssertEqual(
            harness.transport.sentCount, 1,
            "the NEW and nothing else — no HANGUP to a peer that never answered")

        await tearDown(harness)
    }

    /// The deadline is a reachability check, not an answer timer: once the peer
    /// has ACCEPTed, "the called party's service… is being alerted to the call"
    /// (§6.3.3) may take as long as it likes.
    func testConnectDeadlineIsCancelledByTheAcceptAndDoesNotBoundRinging() async throws {
        let configuration = IAX2Call.Configuration(connectTimeout: .seconds(5))
        let harness = try await makeHarness(configuration: configuration)
        try await harness.call.start()

        harness.transport.inject(
            try peerIAX(
                .accept, timestamp: 100, oSeqno: 0, iSeqno: 1, elements: [.format(.g711MuLaw)]))
        await waitFor(harness.call, state: .accepted)

        // Both timers are now gone: the ACCEPT's ISeqno retired the NEW, and
        // the ACCEPT itself cancelled the deadline.
        let disarmed = await harness.clock.waitUntilSleepers(0)
        XCTAssertTrue(disarmed, "the connect deadline should be cancelled by the ACCEPT")

        harness.transport.inject(peerControl(.ringing, timestamp: 200, oSeqno: 1, iSeqno: 1))
        harness.clock.advance(by: .seconds(3600))
        await settle()

        let state = await harness.call.state
        XCTAssertEqual(state, .accepted, "a long ring must not be timed out by this deadline")

        harness.transport.inject(peerControl(.answer, timestamp: 200, oSeqno: 2, iSeqno: 1))
        await waitFor(harness.call, state: .up)

        await tearDown(harness)
    }

    /// "If no acknowledgment is received after a locally configured number of
    /// retries (default 4), the call leg SHOULD be considered unusable and the
    /// call MUST be torn down without any further interaction on this call
    /// leg." (§7) The call surfaces that as a termination — and stays silent.
    func testRetransmissionExhaustionTearsTheCallDownSilently() async throws {
        let configuration = IAX2Call.Configuration(
            connectTimeout: .seconds(3600),  // far beyond the retry ladder
            channel: ReliableChannel.Configuration())
        let harness = try await makeHarness(configuration: configuration)
        try await harness.call.start()

        // Connect deadline + the NEW's retransmission timer.
        let armed = await harness.clock.waitUntilSleeping(count: 2)
        XCTAssertTrue(armed, "the connect deadline and the NEW's retransmission timer")

        // Four retransmissions, each re-arming the timer; the fifth deadline
        // is the one that declares the leg unusable.
        for attempt in 1...4 {
            harness.clock.advance(by: .seconds(30))
            let rearmed = await harness.clock.waitUntilSleeping(count: 2 + attempt)
            XCTAssertTrue(
                rearmed, "retransmission \(attempt) should re-arm the backoff timer")
        }
        harness.clock.advance(by: .seconds(30))

        await waitFor(harness.call, state: .dead)
        let termination = await harness.call.termination
        XCTAssertEqual(
            termination,
            .channelFailed(.retriesExhausted(oSeqno: 0, timestamp: 0, attempts: 4)))

        XCTAssertEqual(harness.transport.sentCount, 5, "the NEW plus four retransmissions")
        for index in 1...4 {
            let frame = try XCTUnwrap(
                IAX2Frame.parse(XCTUnwrap(sentDatagram(harness.transport, index))).fullFrame)
            XCTAssertTrue(frame.isRetransmission, "retransmissions set the R bit (§8.1.1)")
            XCTAssertEqual(frame.iaxMessage, .new)
            XCTAssertEqual(frame.oSeqno, 0, "OSeqno is retransmitted unchanged")
        }
        let hangups = harness.transport.sent.compactMap {
            try? IAX2Frame.parse($0).fullFrame?.iaxMessage
        }.filter { $0 == .hangup }
        XCTAssertTrue(hangups.isEmpty, "no HANGUP is sent when the transport gives up (§6.6, §7)")

        await tearDown(harness)
    }

    // MARK: - Call number allocation (§8.1.1, §4; notes §15)

    func testAllocatorHandsOutDistinctNumbersInRange() async throws {
        let allocator = IAX2CallNumberAllocator()
        var seen: Set<UInt16> = []
        for _ in 0..<64 {
            let number = try await allocator.allocate()
            XCTAssertTrue(
                IAX2CallNumberAllocator.range.contains(number),
                "\(number) is outside 1…32767; 0 would be indistinguishable from a meta frame")
            XCTAssertTrue(seen.insert(number).inserted, "\(number) was handed out twice")
        }
        let count = await allocator.allocatedCount
        XCTAssertEqual(count, 64)
    }

    /// The uniqueness rule is per client, not per call: "The source call number
    /// for an active call MUST NOT be in use by another call on the same
    /// client." (§8.1.1) Concurrent calls sharing one transport therefore share
    /// one allocator, and must not collide.
    func testConcurrentAllocationDoesNotCollide() async throws {
        let allocator = IAX2CallNumberAllocator()
        let count = 500

        let numbers = await withTaskGroup(of: UInt16?.self) { group -> [UInt16] in
            for _ in 0..<count {
                group.addTask { try? await allocator.allocate() }
            }
            var collected: [UInt16] = []
            for await number in group {
                if let number { collected.append(number) }
            }
            return collected
        }

        XCTAssertEqual(numbers.count, count)
        XCTAssertEqual(Set(numbers).count, count, "every concurrent caller got a distinct number")
        for number in numbers {
            XCTAssertTrue(IAX2CallNumberAllocator.range.contains(number))
        }
    }

    /// Several calls on one transport, each with its own leg: the numbers
    /// differ, and each call addresses its own frames with its own.
    func testConcurrentCallsOnOneTransportUseDistinctCallNumbers() async throws {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let allocator = IAX2CallNumberAllocator()

        var calls: [IAX2Call] = []
        for index in 0..<3 {
            // Only the first call may own the read loop — one AsyncStream has
            // one consumer. A multi-call client (IAX-8) drives the rest through
            // `deliver(datagram:)`.
            let call = try await IAX2Call.outbound(
                allocator: allocator,
                request: IAX2CallRequest(calledNumber: "5555\(index)"),
                transport: transport,
                clock: clock,
                readsTransport: false)
            calls.append(call)
        }

        let numbers = calls.map(\.sourceCallNumber)
        XCTAssertEqual(Set(numbers).count, 3)

        for call in calls { try await call.start() }
        let sources = transport.sent.compactMap { try? IAX2Frame.parse($0).sourceCallNumber }
        XCTAssertEqual(Set(sources), Set(numbers), "each NEW carries its own call's number")

        for call in calls { await call.close() }
        // Closing returns every number to the pool (§8.1.1's reuse rule).
        let outstanding = await allocator.allocatedCount
        XCTAssertEqual(outstanding, 0)
        transport.finish()
    }

    /// A released number becomes available again, but the rotating cursor does
    /// not hand it straight back out — stray retransmissions of the old call
    /// may still be in flight (§8.1.1's reuse caveat).
    func testReleasedNumbersAreReusedButNotImmediately() async throws {
        let allocator = IAX2CallNumberAllocator()
        let first = try await allocator.allocate()
        let second = try await allocator.allocate()
        let third = try await allocator.allocate()
        XCTAssertEqual([first, second, third], [1, 2, 3])

        await allocator.release(second)
        let fourth = try await allocator.allocate()
        XCTAssertEqual(fourth, 4, "the cursor moves on rather than reusing 2 immediately")

        let isAllocated = await allocator.isAllocated(2)
        XCTAssertFalse(isAllocated)
    }

    /// Exhaustion is a thrown error, never a fall-through to the frame layer's
    /// `precondition` on the 15-bit field.
    func testAllocatorExhaustionThrows() async throws {
        let allocator = IAX2CallNumberAllocator()
        let span = Int(IAX2CallNumberAllocator.maximum - IAX2CallNumberAllocator.minimum) + 1
        for _ in 0..<span {
            _ = try await allocator.allocate()
        }

        do {
            _ = try await allocator.allocate()
            XCTFail("allocation must throw once 1…32767 is exhausted")
        } catch let error as IAX2CallNumberError {
            XCTAssertEqual(error, .exhausted(inUse: span))
        }

        // And a released number is usable again immediately afterwards.
        await allocator.release(5)
        let recovered = try await allocator.allocate()
        XCTAssertEqual(recovered, 5)
    }

    func testReservingZeroOrAnOversizedNumberThrows() async throws {
        let allocator = IAX2CallNumberAllocator()
        do {
            try await allocator.reserve(0)
            XCTFail("0 is not a usable source call number (§8.1.3, notes §15)")
        } catch let error as IAX2CallNumberError {
            XCTAssertEqual(error, .outOfRange(0))
        }
        do {
            try await allocator.reserve(0x8000)
            XCTFail("a source call number is a 15-bit field (§8.1.1)")
        } catch let error as IAX2CallNumberError {
            XCTAssertEqual(error, .outOfRange(0x8000))
        }
    }

    // MARK: - Unrecognised subclasses (§6.9.5, §6.3.1, §8.6.22)

    func testUnrecognisedIAXSubclassIsAnsweredWithUnsupport() async throws {
        let harness = try await makeHarness()
        try await bringUp(harness)
        harness.transport.clearSent()

        // 0x1F is "Reserved for future use" in the §8.4 table.
        harness.transport.inject(
            peerFrame(
                type: .iax, subclass: IAX2Subclass.literal(0x1F), timestamp: 300, oSeqno: 2,
                iSeqno: 1))
        await waitForSent(2, harness.transport)

        let unsupport = try XCTUnwrap(
            IAX2Frame.parse(XCTUnwrap(sentDatagram(harness.transport, 1))).fullFrame)
        XCTAssertEqual(unsupport.iaxMessage, .unsupport)
        XCTAssertEqual(
            try InformationElement.parseList(unsupport.payload), [.iaxUnknown(0x1F)],
            "UNSUPPORT MUST carry the IAX UNKNOWN IE (§8.6.22)")

        await tearDown(harness)
    }

    // MARK: - Time-stamps (§8.1.1, §6.2.2)

    /// "A time-stamp MUST also be assigned for the call, beginning at zero and
    /// incrementing by one each millisecond." (§6.2.2) Zero is the moment of
    /// the first transmission, not the moment the object was made.
    func testCallTimestampRunsFromTheFirstTransmission() async throws {
        let harness = try await makeHarness()
        harness.clock.advance(by: .seconds(7))  // time passes before we dial

        try await harness.call.start()
        let newFrame = try XCTUnwrap(
            IAX2Frame.parse(XCTUnwrap(sentDatagram(harness.transport, 0))).fullFrame)
        XCTAssertEqual(newFrame.timestamp, 0, "the NEW *is* the first transmission")

        harness.clock.advance(by: .milliseconds(340))
        let now = await harness.call.timestampMilliseconds
        XCTAssertEqual(now, 340)

        await tearDown(harness)
    }

    /// The configured MD5 RESULT encoding must actually reach the wire.
    ///
    /// OQ-5 is the open question of how §8.6.15's "UTF-8 encoded" MD5 result is
    /// rendered — hex or not, upper or lower case. The RFC does not say, and
    /// LP-2 forbids reading another implementation to find out, so it has to be
    /// settled against a live node. `Configuration.md5ResultEncoding` exists so
    /// that the answer is a one-line change; this test is what makes that true,
    /// because a setting nothing asserts on is a setting that can silently stop
    /// working.
    func testConfiguredMD5ResultEncodingIsWhatGoesOnTheWire() async throws {
        // Same digest as the test above, rendered uppercase instead.
        //     printf '%s' '1234567890hunter2' | md5
        //     423705a562413ef5e90f24f5a4bd2a53
        let uppercase = IAX2Auth.TextDigestEncoding(name: "uppercase-hex") { bytes in
            bytes.map { String(format: "%02X", $0) }.joined()
        }
        let expected = "423705A562413EF5E90F24F5A4BD2A53"

        var configuration = IAX2Call.Configuration()
        configuration.md5ResultEncoding = uppercase

        let harness = try await makeHarness(
            request: IAX2CallRequest(
                calledNumber: "55553", username: "n0call", secret: "hunter2"),
            configuration: configuration)

        try await harness.call.start()
        harness.transport.inject(
            try FixtureLoader.datagrams("call-auth-session.hex", in: Bundle.module))
        await waitFor(harness.call, state: .up)
        await waitForSent(5, harness.transport)

        let authrep = try XCTUnwrap(
            IAX2Frame.parse(XCTUnwrap(sentDatagram(harness.transport, 2))).fullFrame)
        XCTAssertEqual(authrep.iaxMessage, .authrep)
        XCTAssertEqual(
            try InformationElement.parseList(authrep.payload), [.md5Result(expected)],
            "the AUTHREP must carry the digest in the configured rendering, not the default")

        await tearDown(harness)
    }

    // MARK: - Actor reentrancy (plan rule 10)

    /// A peer that answers before our own `send` resumes must not be treated as
    /// a protocol fault.
    ///
    /// `start()` awaits `channel.send(.new…)`, and an actor is reentrant across
    /// an await, so with the default `readsTransport: true` the read loop can
    /// deliver the ACCEPT while `start()` is still suspended. The transition to
    /// `.newSent` used to happen *after* that await, so the reply arrived at an
    /// FSM still in `.idle`, where ACCEPT is illegal — and the call was
    /// destroyed as a protocol error rather than connecting.
    ///
    /// `ReplyDuringSendTransport` makes that interleaving deterministic; against
    /// `MockTransport` it is a narrow race that ordinary tests never hit.
    func testAcceptArrivingDuringTheNewSendIsNotAProtocolError() async throws {
        let session = try FixtureLoader.datagrams("call-basic-session.hex", in: Bundle.module)
        // ACCEPT, RINGING, ANSWER — everything up to `up`, all delivered inside
        // the NEW's own send. The HANGUP is deliberately left out.
        let transport = CallReplyDuringSendTransport(reply: Array(session.prefix(3)))
        let call = try await IAX2Call.outbound(
            allocator: IAX2CallNumberAllocator(),
            request: IAX2CallRequest(calledNumber: "55553", username: "n0call"),
            transport: transport,
            clock: ManualTestClock())

        try await call.start()
        await waitFor(call, state: .up)

        let state = await call.state
        XCTAssertEqual(state, .up, "the peer answered during our send and the call still came up")
        let termination = await call.termination
        XCTAssertNil(termination, "the call must not have been torn down as a protocol error")

        await call.close()
        await transport.close()
    }
}

/// Delivers canned datagrams to `incoming` from *inside* `send`, then yields so
/// the receive loop processes them before `send` returns. See plan rule 10.
private final class CallReplyDuringSendTransport: DatagramTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let reply: [Data]
    private let lock = NSLock()
    private var sentDatagrams: [Data] = []
    private var hasReplied = false

    var sent: [Data] { lock.withLock { sentDatagrams } }

    init(reply: [Data]) {
        self.reply = reply
        var escaped: AsyncStream<Data>.Continuation!
        incoming = AsyncStream<Data>(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
    }

    func send(_ datagram: Data) async throws {
        let shouldReply: Bool = lock.withLock {
            sentDatagrams.append(datagram)
            guard !hasReplied else { return false }
            hasReplied = true
            return true
        }
        guard shouldReply else { return }
        for datagram in reply { continuation.yield(datagram) }
        for _ in 0..<500 { await Task.yield() }
    }

    func close() async {
        continuation.finish()
    }
}
