// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import TestSupport
import XCTest

@testable import IAX2Kit

/// IAX-8: `IAX2Client`, the one type applications see — and **Milestone M1**,
/// a full transmit/receive audio path running against recorded fixtures with no
/// radio involved.
///
/// Every test here runs on `MockTransport` and `ManualTestClock`: no socket is
/// opened and nothing waits on real time (AU-5). The two synchronisation
/// primitives are cooperative yielding (the `waitFor…` helpers, which spin the
/// scheduler and never the wall clock) and `ManualTestClock.waitUntilSleepers`,
/// which is what makes the watchdog and connect-deadline tests deterministic
/// instead of racy.
final class IAX2ClientTests: XCTestCase {

    /// The peer's 15-bit source call number in every fixture used here.
    private let peerCallNumber: UInt16 = 0x0042

    /// Ours. Each client has its own `IAX2CallNumberAllocator`, which hands out
    /// 1 first and deterministically, so the fixtures can address us by number.
    private let localCallNumber: UInt16 = 1

    private static let node = IAX2Destination(
        host: "node.example.test",
        callsign: "N0CALL",
        username: "n0call",
        secret: "s3cr3t",
        node: "55553")

    private let samplesPerFrame = 160

    // MARK: - CALLING NUMBER (IAX-12)

    /// Absent by default, so IAX Direct and registered node mode send exactly
    /// what they always sent. A zero-length CALLING NUMBER is not the same as
    /// no CALLING NUMBER, and nodes are entitled to treat it differently.
    func testCallRequestOmitsCallingNumberUnlessAsked() {
        XCTAssertNil(IAX2ClientTests.node.callRequest.callingNumber)
        XCTAssertEqual(IAX2ClientTests.node.callRequest.callingName, "N0CALL")
    }

    /// Web Transceiver needs it: USERNAME there is the shared context name
    /// `allstar-public`, which identifies nobody, so the operator's identity has
    /// to travel separately. See IAX-12 and `experiment-data/wt-oq10-result.txt`.
    func testCallRequestCarriesCallingNumberWhenSet() {
        let destination = IAX2Destination(
            host: "node.example.test",
            callsign: "N0CALL",
            username: "allstar-public",
            secret: "s3cr3t",
            node: "55553",
            callingNumber: "N0CALL")
        XCTAssertEqual(destination.callRequest.callingNumber, "N0CALL")
        XCTAssertEqual(destination.callRequest.username, "allstar-public")
        XCTAssertEqual(destination.callRequest.callingName, "N0CALL")
    }

    /// `callsign` is upper-cased and character-checked, which is right for a
    /// callsign and destroys anything else. The override exists so a caller can
    /// put a lowercase-hex value in CALLING NAME without it being normalised.
    func testCallingNameOverrideIsSentVerbatim() {
        let destination = IAX2Destination(
            host: "node.example.test",
            callsign: "N0CALL",
            username: "allstar-public",
            secret: "allstar",
            node: "s",
            callingNumber: "N0CALL",
            callingName: "1b59df18107e")
        XCTAssertEqual(destination.callRequest.callingName, "1b59df18107e")
        XCTAssertEqual(destination.callRequest.callingNumber, "N0CALL")
    }

    /// Empty override means "send the callsign", so nothing that existed before
    /// CALLING NAME became overridable changes behaviour.
    func testCallingNameFallsBackToTheCallsign() {
        XCTAssertEqual(IAX2ClientTests.node.callRequest.callingName, "N0CALL")
    }

    // MARK: - Harness

    private struct Harness {
        let client: IAX2Client
        let transport: MockTransport
        let clock: ManualTestClock
        let audio: AudioCollector
        let events: EventCollector
        let radioEvents: RadioEventCollector
        let audioTask: Task<Void, Never>
        let eventTask: Task<Void, Never>
        let radioEventTask: Task<Void, Never>
    }

    private func makeHarness(
        configuration: IAX2Client.Configuration = IAX2Client.Configuration()
    ) -> Harness {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let client = IAX2Client(
            clock: clock,
            configuration: configuration,
            transportFactory: { _ in transport })

        let audio = AudioCollector()
        let audioTask = Task {
            for await frame in client.receivedAudio { await audio.append(frame) }
            await audio.finish()
        }
        let events = EventCollector()
        let eventTask = Task {
            for await event in client.events { await events.append(event) }
            await events.finish()
        }
        let radioEvents = RadioEventCollector()
        let radioEventTask = Task {
            for await event in client.radioEvents { await radioEvents.append(event) }
            await radioEvents.finish()
        }
        return Harness(
            client: client, transport: transport, clock: clock,
            audio: audio, events: events, radioEvents: radioEvents,
            audioTask: audioTask, eventTask: eventTask, radioEventTask: radioEventTask)
    }

    private func tearDown(_ harness: Harness) async {
        await harness.client.disconnect()
        harness.transport.finish()
    }

    // MARK: - Synchronisation helpers (scheduler-bound, never real time)

    /// Gives any *incorrect* extra work a fair chance to happen before a
    /// negative assertion, without touching the wall clock.
    private func settle(_ iterations: Int = 200) async {
        for _ in 0..<iterations { await Task.yield() }
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

    @discardableResult
    private func waitForQueuedFrames(
        _ count: Int,
        _ client: IAX2Client,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100_000 {
            if await client.queuedInboundFrameCount >= count { return true }
            await Task.yield()
        }
        let actual = await client.queuedInboundFrameCount
        XCTFail(
            "expected \(count) frame(s) queued for playout, saw \(actual)",
            file: file, line: line)
        return false
    }

    @discardableResult
    private func waitForPlayout(
        _ count: Int,
        _ collector: AudioCollector,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100_000 {
            if await collector.count >= count { return true }
            await Task.yield()
        }
        let actual = await collector.count
        XCTFail(
            "expected \(count) played frame(s), saw \(actual)", file: file, line: line)
        return false
    }

    @discardableResult
    private func waitForEvent(
        _ predicate: @escaping @Sendable (IAX2ClientEvent) -> Bool,
        _ collector: EventCollector,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100_000 {
            if await collector.contains(where: predicate) { return true }
            await Task.yield()
        }
        let seen = await collector.events
        XCTFail("never saw \(what); events were \(seen)", file: file, line: line)
        return false
    }

    @discardableResult
    private func waitUntilFinished(_ collector: some FinishTracking) async -> Bool {
        for _ in 0..<200_000 {
            if await collector.isFinished { return true }
            await Task.yield()
        }
        return false
    }

    /// RMS level of a PCM buffer in dBFS relative to `Int16.max`. `AudioLeveller`
    /// has its own copy of this, but it is internal to `RadioCore`, and a test
    /// that measures the leveller's effect should not be reusing the leveller's
    /// own measurement anyway.
    private func rmsDBFS(_ pcm: [Int16]) -> Double {
        guard !pcm.isEmpty else { return -.infinity }
        let sumSquares = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
        let meanSquare = sumSquares / Double(pcm.count)
        guard meanSquare > 0 else { return -.infinity }
        return 20 * log10(sqrt(meanSquare) / Double(Int16.max))
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

    private func fixture(_ name: String) throws -> [Data] {
        try FixtureLoader.datagrams(name, in: Bundle.module)
    }

    // MARK: - Shared steps

    /// Places the call and brings it up from `client-connect.hex`.
    ///
    /// `connect` is started as a task and the fixture injected only once the
    /// NEW is on the wire: a scripted ACCEPT delivered before the NEW would be
    /// a Control frame on an `idle` leg, which is a protocol violation rather
    /// than a shortcut.
    private func connect(
        _ harness: Harness,
        to destination: IAX2Destination = IAX2ClientTests.node,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let connecting = Task { [client = harness.client] in
            try await client.connect(to: destination)
        }
        await waitForSent(1, harness.transport, file: file, line: line)
        harness.transport.inject(try fixture("client-connect.hex"))
        try await connecting.value
        XCTAssertEqual(harness.client.state, .receiving, file: file, line: line)
    }

    /// One second of a 400 Hz tone at 8 kHz, as fifty 160-sample frames with
    /// continuous phase — what `AudioPipeline` would hand over from a
    /// microphone, minus the microphone.
    private func tone(frames: Int = 50, amplitude: Double = 8000) -> [[Int16]] {
        var pcm: [[Int16]] = []
        var sample = 0
        for _ in 0..<frames {
            var frame: [Int16] = []
            frame.reserveCapacity(samplesPerFrame)
            for _ in 0..<samplesPerFrame {
                let value = amplitude * sin(2 * Double.pi * 400 * Double(sample) / 8000)
                frame.append(Int16(value.rounded()))
                sample += 1
            }
            pcm.append(frame)
        }
        return pcm
    }

    private func level(_ value: Int16) -> [Int16] {
        [Int16](repeating: value, count: samplesPerFrame)
    }

    // MARK: - Milestone M1

    /// **Milestone M1.** One scripted session, end to end, with no radio and no
    /// socket: connect, transmit a second of tone and check every datagram it
    /// produced, then play a fixture of inbound voice and check the PCM that
    /// comes out the other side.
    ///
    /// Nothing in the path is stubbed. The bytes asserted below are the bytes
    /// `MockTransport` was handed by `ReliableChannel`; the PCM asserted at the
    /// end came out of `G711MuLawCodec` via `JitterBuffer` and `AudioLeveller`,
    /// driven by a 20 ms tick on the manual clock.
    func testMilestoneOneTransmitsAndReceivesAScriptedSession() async throws {
        let harness = makeHarness()

        // ── 1. Connect ────────────────────────────────────────────────────
        try await connect(harness)

        XCTAssertEqual(harness.transport.sentCount, 3, "NEW, ACK of ACCEPT, ACK of ANSWER")

        // The NEW: F = 1, source 1, destination 0 ("the remote peer's source
        // call identifier is not created until after receipt of this frame",
        // §6.2.2), time-stamp 0, OSeqno 0, ISeqno 0 (§7), type 0x06 IAX,
        // subclass 0x01. VERSION first, as §6.2.2 and §8.6.10 require.
        assertDatagram(
            sentDatagram(harness.transport, 0),
            hex(
                "8001 0000 00000000 00 00 06 01"
                    + "0b02 0002"  // VERSION = 2 (§8.6.10), MUST be first
                    + "0105 3535353533"  // CALLED NUMBER "55553" (§8.6.1)
                    + "0606 6e30 6361 6c6c"  // USERNAME "n0call" (§8.6.6)
                    + "0406 4e304341 4c4c"  // CALLING NAME "N0CALL" (§8.6.4)
                    + "0804 00000004"  // CAPABILITY = µ-law (§8.6.7, §8.7)
                    + "0904 00000004"  // FORMAT = µ-law (§8.6.8)
                    + "2601 00"  // CALLINGPRES (§8.6.29)
                    + "2701 00"  // CALLINGTON (§8.6.30)
                    + "2802 0000"),  // CALLINGTNS (§8.6.31)
            "the NEW message carries the destination's node, username and callsign")
        assertDatagram(
            sentDatagram(harness.transport, 1), hex("8001 0042 00000064 01 01 06 04"),
            "ACK of the ACCEPT, echoing its time-stamp 100 (§6.2.3, §6.9.1)")
        assertDatagram(
            sentDatagram(harness.transport, 2), hex("8001 0042 000000c8 01 02 06 04"),
            "ACK of the ANSWER")

        let format = await harness.client.negotiatedFormat
        XCTAssertEqual(format, .g711MuLaw, "the FORMAT IE of the ACCEPT (§6.2.3)")
        await waitForEvent(
            { if case .connected(.g711MuLaw) = $0 { return true } else { return false } },
            harness.events, "a .connected event naming µ-law")

        // ── 2. Transmit one second of tone ────────────────────────────────
        // Wind the call clock to 32,700 ms first. The transmit grid starts from
        // the call clock, so a second of audio from here steps across the
        // 0x8000 = 32,768 ms resync boundary — the point at which §6.10 says a
        // full frame MUST be substituted for a Mini Frame. Testing that rule
        // any other way means waiting 32.768 real seconds.
        harness.clock.advance(by: .milliseconds(32_700))

        harness.transport.clearSent()
        try await harness.client.startTransmit()
        guard case .transmitting = harness.client.state else {
            return XCTFail("startTransmit did not move the state")
        }

        let pcm = tone()
        for frame in pcm {
            _ = try await harness.client.transmit(pcm: frame)
        }
        await harness.client.stopTransmit()
        XCTAssertEqual(harness.client.state, .receiving)

        let sent = harness.transport.sent
        XCTAssertEqual(sent.count, 50, "one datagram per 20 ms frame, one second of audio")

        let frames = try sent.map { try IAX2Frame.parse($0) }
        let codec = G711MuLawCodec()

        // The shape of the stream: full, mini × 3, full at the boundary, then
        // mini for the rest (§8.1.2, §6.10).
        let fullFrameIndices = frames.indices.filter { frames[$0].fullFrame != nil }
        XCTAssertEqual(
            fullFrameIndices, [0, 4],
            "the first frame pins the codec (§8.1.2) and the frame at 32,780 ms "
                + "resynchronises across the 0x8000 boundary (§6.10)")

        // Frame 0 — the codec pin, byte for byte. Source 1, destination 0x0042,
        // time-stamp 32,700 = 0x7FBC, OSeqno 1 (the NEW consumed 0), ISeqno 2
        // (the ACCEPT and the ANSWER each advanced it), type 0x02 Voice,
        // subclass 0x82: C = 1 with field 2, i.e. 1 << 2 = G.711 µ-law
        // (§8.1.1, §8.7).
        let firstPayload = try codec.encode(pcm[0])
        assertDatagram(
            sentDatagram(harness.transport, 0),
            hex("8001 0042 00007fbc 01 02 02 82") + Data(firstPayload),
            "the first voice frame is a full frame carrying the µ-law subclass")

        // Frame 4 — the resync frame. OSeqno 2, because a full Voice frame is
        // sequenced and Mini Frames are not (§8.1.2).
        assertDatagram(
            sentDatagram(harness.transport, 4),
            hex("8001 0042 0000800c 02 02 02 82") + Data(try codec.encode(pcm[4])),
            "the frame whose time-stamp crosses 0x8000 goes out full again")

        // Frame 1 — a Mini Frame: four octets of header, no destination call
        // number, no sequence numbers, no type, no subclass; the time-stamp is
        // "the lower 16 bits of the transmitting peer's full 32-bit time-stamp"
        // (§8.1.2), 32,720 = 0x7FD0.
        assertDatagram(
            sentDatagram(harness.transport, 1),
            hex("0001 7fd0") + Data(try codec.encode(pcm[1])),
            "the second voice frame is a Mini Frame")

        // Every frame, in order, on the 20 ms grid — and every payload is the
        // µ-law of the tone we handed in, decodable back to it within
        // quantisation error.
        for (index, frame) in frames.enumerated() {
            let expected = UInt32(32_700 + index * 20)
            switch frame {
            case .full(let full):
                XCTAssertEqual(full.timestamp, expected, "frame \(index) time-stamp")
                XCTAssertEqual(full.type, .voice, "frame \(index) is a Voice frame")
                XCTAssertEqual(
                    full.subclass.value, MediaFormat.g711MuLaw.rawValue,
                    "frame \(index) names µ-law in its subclass")
            case .mini(let mini):
                XCTAssertEqual(
                    mini.timestamp, UInt16(truncatingIfNeeded: expected),
                    "frame \(index) carries the low 16 bits of the call clock")
                XCTAssertEqual(mini.sourceCallNumber, localCallNumber)
            }
            XCTAssertEqual(frame.payload.count, 160, "frame \(index): 20 ms of µ-law")
            let decoded = try codec.decode(frame.payload)
            for (sample, original) in zip(decoded, pcm[index]) {
                XCTAssertLessThan(
                    abs(Int(sample) - Int(original)), 256,
                    "frame \(index) survives a µ-law round trip")
            }
        }

        // ── 3. Receive ────────────────────────────────────────────────────
        // The node acknowledges the two full Voice frames (§6.10) and then
        // sends its own: one full Voice frame followed by seven Mini Frames.
        harness.transport.clearSent()
        harness.transport.inject(try fixture("client-voice-ack.hex"))
        harness.transport.inject(try fixture("voice-mulaw-stream.hex"))
        await waitForQueuedFrames(8, harness.client)

        // Our ACK of *their* full Voice frame, which §6.10 also requires. Their
        // frame carried OSeqno 2 and time-stamp 20, so ours echoes 20 and
        // advances ISeqno to 3.
        await waitForSent(1, harness.transport)
        assertDatagram(
            sentDatagram(harness.transport, 0), hex("8001 0042 00000014 03 03 06 04"),
            "the inbound full Voice frame is acknowledged (§6.10)")

        // Eight ticks of the 20 ms playout grid, driven entirely by the manual
        // clock, produce the eight decoded frames.
        let before = await harness.audio.count
        harness.clock.advance(by: .milliseconds(160))
        await waitForPlayout(before + 8, harness.audio)

        let played = await harness.audio.frames
        let expectedLevels: [Int16] = [0, 8, 16, 24, 32, 40, 48, 56]
        for (offset, expected) in expectedLevels.enumerated() {
            let frame = played[before + offset]
            XCTAssertEqual(frame.count, samplesPerFrame, "playout \(offset) is one frame")
            XCTAssertEqual(
                frame, level(expected),
                "playout \(offset): every octet of fixture frame \(offset) is 0xFF - \(offset), "
                    + "which G.711 decodes to a constant \(expected)")
        }

        await tearDown(harness)
    }

    // MARK: - The transmit watchdog (SF-1)

    /// A stuck PTT must not hold a repeater open. The watchdog expires on the
    /// injected clock, stops transmission by itself, and audio offered
    /// afterwards goes nowhere.
    func testWatchdogExpiryStopsTransmissionByItself() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()

        try await harness.client.startTransmit()
        guard case .transmitting = harness.client.state else {
            return XCTFail("startTransmit did not move the state")
        }

        // Two live sleepers now: the playout tick and the watchdog. Waiting for
        // the second is what makes the advance below deterministic — advancing
        // before the watchdog has entered `sleep` would compute its deadline
        // against already-advanced time and it would never fire.
        let armed = await harness.clock.waitUntilSleepers(2)
        XCTAssertTrue(armed, "the watchdog never armed its deadline")
        harness.clock.advance(by: TransmitWatchdog.defaultTimeout)

        await waitForEvent(
            {
                if case .transmitWatchdogExpired(TransmitWatchdog.defaultTimeout) = $0 {
                    return true
                }
                return false
            },
            harness.events, "the watchdog expiry event")

        XCTAssertEqual(
            harness.client.state, .receiving,
            "expiry moves the state back to receiving without the caller doing anything (SF-1)")

        // And it genuinely stopped transmitting: audio offered now is dropped
        // rather than keyed onto the air.
        let before = harness.transport.sentCount
        let frame = try await harness.client.transmit(pcm: tone(frames: 1)[0])
        XCTAssertNil(frame, "audio after expiry is not sent")
        await settle()
        XCTAssertEqual(
            harness.transport.sentCount, before, "and nothing reached the transport")

        await tearDown(harness)
    }

    /// The timeout is configurable, and a `stopTransmit` that beats the
    /// deadline disarms it — a watchdog that fired after an ordinary unkey
    /// would report a fault that never happened.
    func testWatchdogIsConfigurableAndCancelledByStopTransmit() async throws {
        var configuration = IAX2Client.Configuration()
        configuration.transmitTimeout = .seconds(5)
        let harness = makeHarness(configuration: configuration)
        try await connect(harness)

        try await harness.client.startTransmit()
        let armed = await harness.clock.waitUntilSleepers(2)
        XCTAssertTrue(armed, "the watchdog never armed its deadline")
        await harness.client.stopTransmit()
        XCTAssertEqual(harness.client.state, .receiving)

        harness.clock.advance(by: .seconds(60))
        await settle()

        let expired = await harness.events.contains {
            if case .transmitWatchdogExpired = $0 { return true } else { return false }
        }
        XCTAssertFalse(expired, "a cancelled watchdog must not fire")

        await tearDown(harness)
    }

    // MARK: - Teardown

    /// `disconnect()` hangs up, closes the transport, and finishes both public
    /// streams so no consumer is left looping over a client nobody will feed
    /// again.
    func testDisconnectHangsUpAndFinishesTheStreams() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()

        await harness.client.disconnect()

        // HANGUP: OSeqno 1, ISeqno 2, time-stamp 0 (the manual clock has not
        // moved), CAUSE "Normal call clearing" + CAUSECODE 16 (§8.6.21,
        // §8.6.33).
        assertDatagram(
            sentDatagram(harness.transport, 0),
            hex("8001 0042 00000000 01 02 06 05")
                + hex("1614") + Data("Normal call clearing".utf8)
                + hex("2a01 10"),
            "disconnect sends HANGUP (§6.2.5)")

        XCTAssertEqual(harness.client.state, .idle)
        XCTAssertTrue(harness.transport.isClosed, "the transport is closed, not leaked")

        // The consumers' loops end, rather than hanging. Bounded cooperative
        // waits: a regression must fail this test, not stall the suite.
        let audioFinished = await waitUntilFinished(harness.audio)
        XCTAssertTrue(audioFinished, "receivedAudio never finished")
        let eventsFinished = await waitUntilFinished(harness.events)
        XCTAssertTrue(eventsFinished, "events never finished")

        // Idempotent, and terminal.
        await harness.client.disconnect()
        do {
            try await harness.client.connect(to: Self.node)
            XCTFail("a disconnected client must not reconnect: its streams are finished")
        } catch let error as IAX2ClientError {
            XCTAssertEqual(error, .clientShutDown)
        }
    }

    /// A node that hangs up ends the session and says so, but leaves the
    /// streams open — the application has to be able to hear about it.
    func testRemoteHangupEndsTheSessionAndIsReported() async throws {
        let harness = makeHarness()
        try await connect(harness)

        harness.transport.inject(try fixture("client-hangup.hex"))

        await waitForEvent(
            {
                if case .disconnected(.remoteHangup(cause: "Bye", causeCode: 16)) = $0 {
                    return true
                }
                return false
            },
            harness.events, "the remote hangup, with its CAUSE and CAUSECODE")

        XCTAssertEqual(harness.client.state, .idle)
        let connected = await harness.client.isConnected
        XCTAssertFalse(connected)
        let finished = await harness.events.isFinished
        XCTAssertFalse(finished, "a remote hangup does not end the streams")

        do {
            try await harness.client.startTransmit()
            XCTFail("there is nothing to transmit on")
        } catch let error as IAX2ClientError {
            XCTAssertEqual(error, .notConnected)
        }

        await tearDown(harness)
    }

    // MARK: - Call setup paths

    /// AUTHREQ → AUTHREP → ACCEPT → ANSWER, end to end (§6.2.7, §6.2.6, notes
    /// §12 flow (b)).
    func testAuthenticatedConnectAnswersTheChallenge() async throws {
        let harness = makeHarness()

        let connecting = Task { [client = harness.client] in
            try await client.connect(to: Self.node)
        }
        await waitForSent(1, harness.transport)
        harness.transport.inject(try fixture("call-auth-session.hex"))
        try await connecting.value

        XCTAssertEqual(harness.client.state, .receiving)
        XCTAssertEqual(harness.transport.sentCount, 5, "NEW, ACK, AUTHREP, ACK, ACK")

        // §8.6.15: MD5(challenge ‖ secret), challenge first, no separator,
        // carried as text — the encoding is OQ-5 and lives in `IAX2Auth`. This
        // asserts the *wiring*: that the destination's secret and the fixture's
        // CHALLENGE reached the digest. The digest itself is pinned by
        // hand-computed vectors in `IAX2AuthTests`.
        let digest = IAX2Auth.md5Response(challenge: "1234567890", secret: Self.node.secret)
        assertDatagram(
            sentDatagram(harness.transport, 2),
            hex("8001 0042 00000000 01 01 06 09 10 20") + Data(digest.utf8),
            "AUTHREP carrying MD5 RESULT (IE 0x10, 32 octets)")

        let authrep = try XCTUnwrap(
            IAX2Frame.parse(try XCTUnwrap(sentDatagram(harness.transport, 2))).fullFrame)
        XCTAssertEqual(authrep.iaxMessage, .authrep)
        XCTAssertEqual(
            try InformationElement.parseList(authrep.payload), [.md5Result(digest)],
            "the AUTHREP carries the digest and nothing else — there is no plaintext path")

        await tearDown(harness)
    }

    /// A REJECT has to reach the user as something they can act on, which means
    /// carrying the CAUSE and CAUSECODE IEs out of the frame and into the error
    /// (§6.2.4, §8.6.21, §8.6.33).
    func testRejectSurfacesTheCause() async throws {
        let harness = makeHarness()

        let connecting = Task { [client = harness.client] in
            try await client.connect(to: Self.node)
        }
        await waitForSent(1, harness.transport)
        harness.transport.inject(try fixture("call-reject.hex"))

        do {
            try await connecting.value
            XCTFail("a rejected call must not connect")
        } catch let error as IAX2ClientError {
            XCTAssertEqual(
                error, .rejected(cause: "No route to destination", causeCode: 3))
            XCTAssertEqual(
                error.description,
                "the node rejected the call: No route to destination (cause code 3)")
        }

        XCTAssertEqual(harness.client.state, .idle)
        // "REJECT messages require an explicit ACK." (§6.2.4)
        assertDatagram(
            sentDatagram(harness.transport, 1), hex("8001 0042 00000064 01 01 06 04"),
            "the REJECT is acknowledged before the leg is destroyed")

        await tearDown(harness)
    }

    /// A node that never answers surfaces as a timeout rather than a hang. The
    /// deadline is `IAX2Call`'s, on the injected clock; this proves it reaches
    /// the caller as an `IAX2ClientError`.
    ///
    /// The deadline is deliberately shorter than the reliable channel's first
    /// retransmission (500 ms), so exactly one timer is due when the clock
    /// moves and the outcome cannot race the retransmission ladder.
    func testConnectTimeoutSurfacesAsAnError() async throws {
        var configuration = IAX2Client.Configuration()
        configuration.call = IAX2Call.Configuration(connectTimeout: .milliseconds(300))
        let harness = makeHarness(configuration: configuration)

        let connecting = Task { [client = harness.client] in
            try await client.connect(to: Self.node)
        }
        await waitForSent(1, harness.transport)
        // The NEW's retransmission timer, then the connect deadline.
        let armed = await harness.clock.waitUntilSleeping(count: 2)
        XCTAssertTrue(armed, "the connect deadline never armed")
        harness.clock.advance(by: .milliseconds(300))

        do {
            try await connecting.value
            XCTFail("a call nobody answered must not connect")
        } catch let error as IAX2ClientError {
            XCTAssertEqual(error, .connectTimedOut(.milliseconds(300)))
        }

        XCTAssertEqual(harness.client.state, .idle)
        XCTAssertTrue(harness.transport.isClosed, "a failed connect closes its transport")

        // No HANGUP: a peer that never created a leg is not owed a farewell it
        // cannot hear (§6.6, §7).
        let hangups = harness.transport.sent.compactMap {
            try? IAX2Frame.parse($0).fullFrame
        }.filter { $0.iaxMessage == .hangup }
        XCTAssertTrue(hangups.isEmpty)
    }

    /// Plan rule 10. `connect()` awaits `transport.send` before anything parks
    /// a continuation, and an actor is reentrant across that await — so a node
    /// whose ACCEPT and ANSWER are processed *during* the send must still bring
    /// the call up. A test that only exercises the common ordering would not
    /// find a regression here; this one delivers the whole reply from inside
    /// `send`.
    ///
    /// It guards two things at once. `IAX2Call.waitUntilUp()` must return
    /// immediately for a call that came up before it was ever called — it does,
    /// by checking and parking in one isolated region. And `connect()` must not
    /// start reading the transport until the NEW has been written, because
    /// `IAX2Call.start()` moves the FSM out of `idle` only after that write
    /// returns, and an ACCEPT delivered into an `idle` FSM is an illegal
    /// transition that destroys the call. Move `startReadLoop` back above
    /// `call.start()` and this test fails with the call in `idle`.
    func testConnectReturnsWhenTheCallComesUpDuringSend() async throws {
        let transport = ReplyDuringSendTransport(
            reply: try FixtureLoader.datagrams("client-connect.hex", in: Bundle.module))
        let client = IAX2Client(
            clock: ManualTestClock(), transportFactory: { _ in transport })

        let completed = Completion()
        let connecting = Task {
            try await client.connect(to: Self.node)
            await completed.signal()
        }

        // Bounded cooperative wait — a regression must fail this test, not hang it.
        for _ in 0..<200_000 where await !completed.isSignalled { await Task.yield() }

        let returned = await completed.isSignalled
        connecting.cancel()
        XCTAssertTrue(returned, "connect() never returned: the call's outcome was dropped")
        XCTAssertEqual(client.state, .receiving)

        await client.disconnect()
    }

    // MARK: - Audio path details

    /// AU-4: received audio is levelled. A hot inbound stream is pulled down
    /// toward the target instead of arriving at whatever level the node felt
    /// like sending.
    func testReceivedAudioIsLevelled() async throws {
        let harness = makeHarness()
        try await connect(harness)

        // Eight frames of a full-scale tone: one full Voice frame to pin the
        // codec and re-anchor the time-stamp reference, then seven Mini Frames.
        let codec = G711MuLawCodec()
        let hot = tone(frames: 8, amplitude: 30_000)
        let payloads = try hot.map { try codec.encode($0) }

        harness.transport.inject(
            IAX2Frame.full(
                IAX2FullFrame(
                    sourceCallNumber: peerCallNumber,
                    destinationCallNumber: localCallNumber,
                    timestamp: 20,
                    oSeqno: 2,
                    iSeqno: 1,
                    type: .voice,
                    subclass: try XCTUnwrap(
                        IAX2Subclass(mediaFormat: MediaFormat.g711MuLaw.rawValue)),
                    payload: payloads[0])
            ).encoded())
        for (index, payload) in payloads.dropFirst().enumerated() {
            harness.transport.inject(
                IAX2Frame.mini(
                    IAX2MiniFrame(
                        sourceCallNumber: peerCallNumber,
                        timestamp: UInt16(40 + index * 20),
                        payload: payload)
                ).encoded())
        }
        await waitForQueuedFrames(8, harness.client)

        let before = await harness.audio.count
        harness.clock.advance(by: .milliseconds(160))
        await waitForPlayout(before + 8, harness.audio)
        let played = await harness.audio.frames

        let inputLevel = rmsDBFS(hot[7])
        let outputLevel = rmsDBFS(played[before + 7])
        XCTAssertLessThan(
            outputLevel, inputLevel - 6,
            "a hot stream is pulled down by at least 6 dB within eight frames (AU-4)")
        XCTAssertGreaterThan(outputLevel, -60, "and not silenced")

        await tearDown(harness)
    }

    /// The application layer's capture pipeline runs whether or not PTT is
    /// pressed. Audio offered while not transmitting is dropped, silently and
    /// deliberately: the fail-safe direction is dead air, never an open
    /// microphone.
    func testAudioOfferedWhileNotTransmittingIsDropped() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()

        let frame = try await harness.client.transmit(pcm: tone(frames: 1)[0])
        XCTAssertNil(frame)
        await settle()
        XCTAssertEqual(harness.transport.sentCount, 0)

        await tearDown(harness)
    }

    /// Transmitting without a call is a caller bug, and says so.
    func testStartTransmitWithoutACallThrows() async throws {
        let harness = makeHarness()
        do {
            try await harness.client.startTransmit()
            XCTFail("there is no call to transmit on")
        } catch let error as IAX2ClientError {
            XCTAssertEqual(error, .notConnected)
        }
        XCTAssertEqual(harness.client.state, .idle)

        // And `stopTransmit` is safe from anywhere: SF-2 and SF-3 both call it
        // from paths that cannot know the current state.
        await harness.client.stopTransmit()
        XCTAssertEqual(harness.client.state, .idle)

        await tearDown(harness)
    }

    /// Connecting twice is a caller bug too.
    func testConnectingTwiceThrows() async throws {
        let harness = makeHarness()
        try await connect(harness)
        do {
            try await harness.client.connect(to: Self.node)
            XCTFail("a second call on one client is not supported")
        } catch let error as IAX2ClientError {
            XCTAssertEqual(error, .alreadyConnected)
        }
        await tearDown(harness)
    }

    /// DTMF is signalling, not audio: it needs a call but not PTT (FR-1.5,
    /// §8.2.1).
    func testDTMFIsSentAsAFullFrameWithoutTransmitting() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()

        try await harness.client.send(dtmf: "5")

        await waitForSent(1, harness.transport)
        assertDatagram(
            sentDatagram(harness.transport, 0), hex("8001 0042 00000000 01 02 01 35"),
            "one full frame, type 0x01 DTMF, subclass = ASCII '5' (§8.2.1)")

        await tearDown(harness)
    }

    /// Inbound DTMF reaches the application (§8.2.1, notes §14).
    func testInboundDTMFIsReported() async throws {
        let harness = makeHarness()
        try await connect(harness)

        harness.transport.inject(
            IAX2Frame.full(
                IAX2FullFrame(
                    sourceCallNumber: peerCallNumber,
                    destinationCallNumber: localCallNumber,
                    timestamp: 300,
                    oSeqno: 2,
                    iSeqno: 1,
                    type: IAX2DTMFDigit.frameType,
                    subclass: try IAX2DTMFDigit("7").subclass)
            ).encoded())

        await waitForEvent(
            { if case .dtmf(let digit) = $0 { return digit.character == "7" } else { return false } },
            harness.events, "the inbound digit 7")

        await tearDown(harness)
    }

    /// The playout grid re-anchors instead of replaying a backlog. Thirty
    /// seconds of stalled clock must not dump thirty seconds of stale audio
    /// into a speaker at once.
    func testPlayoutGridResynchronisesAfterALongStall() async throws {
        let harness = makeHarness()
        try await connect(harness)

        let before = await harness.audio.count
        harness.clock.advance(by: .seconds(30))
        await waitForPlayout(before + 1, harness.audio)
        await settle()

        let after = await harness.audio.count
        XCTAssertLessThanOrEqual(
            after - before, 11,
            "a 30 s stall must not emit 1,500 frames; the grid re-anchors after "
                + "the configured maximum lag")

        // And the grid still runs afterwards, on the new anchor.
        harness.clock.advance(by: .milliseconds(100))
        await waitForPlayout(after + 5, harness.audio)

        await tearDown(harness)
    }

    // MARK: - The mode-agnostic event stream (RC-10)

    /// `events` and `radioEvents` are fed from one place, so a live session must
    /// see the same things in the same order on both — and `radioEvents` is what
    /// an application actually reads, so a gap here is a gap in the app.
    func testRadioEventsMirrorTheModeSpecificStreamThroughAWholeSession() async throws {
        let harness = makeHarness()
        try await connect(harness)

        await waitForEvent(
            { if case .connected = $0 { return true } else { return false } },
            harness.events, "the call came up")

        try await harness.client.startTransmit()
        await harness.client.stopTransmit()

        // An inbound DTMF digit, so the stream carries something that is neither
        // lifecycle nor transmit state.
        harness.transport.inject(
            IAX2Frame.full(
                IAX2FullFrame(
                    sourceCallNumber: peerCallNumber,
                    destinationCallNumber: localCallNumber,
                    timestamp: 300,
                    oSeqno: 2,
                    iSeqno: 1,
                    type: IAX2DTMFDigit.frameType,
                    subclass: try IAX2DTMFDigit("7").subclass)
            ).encoded())
        await waitForEvent(
            { if case .dtmf = $0 { return true } else { return false } },
            harness.events, "the node sent a digit")
        await settle()

        let modeSpecific = await harness.events.events
        let radio = await harness.radioEvents.events
        XCTAssertEqual(
            radio, modeSpecific.compactMap(\.radioEvent),
            "radioEvents is exactly the translation of events, in order")

        // And the specific things an app has to be able to see.
        XCTAssertTrue(radio.contains(.connected))
        XCTAssertTrue(radio.contains(.transmitting))
        XCTAssertTrue(radio.contains(.receiving))
        XCTAssertTrue(radio.contains { if case .dtmfReceived = $0 { return true } else { return false } })

        await tearDown(harness)
    }

    /// SF-1 requires the operator to see the watchdog fire, and `radioEvents` is
    /// the stream an application reads — so the expiry has to arrive there, with
    /// its timeout intact, not only on the IAX2-specific stream.
    func testWatchdogExpiryReachesTheModeAgnosticStream() async throws {
        let timeout = Duration.seconds(3)
        var configuration = IAX2Client.Configuration()
        configuration.transmitTimeout = timeout
        let harness = makeHarness(configuration: configuration)
        try await connect(harness)

        try await harness.client.startTransmit()
        let armed = await harness.clock.waitUntilSleepers(2)
        XCTAssertTrue(armed, "the watchdog never armed its deadline")
        harness.clock.advance(by: timeout)
        await waitForEvent(
            { if case .transmitWatchdogExpired = $0 { return true } else { return false } },
            harness.events, "the watchdog fired")
        await settle()

        let radio = await harness.radioEvents.events
        XCTAssertTrue(
            radio.contains(.transmitWatchdogExpired(timeout)),
            "the watchdog expiry, carrying its own timeout, on the stream the app reads")
        XCTAssertEqual(harness.client.state, .receiving, "and it actually unkeyed")

        await tearDown(harness)
    }

    /// `disconnect()` is terminal for both streams, or a consumer's `for await`
    /// never ends.
    func testDisconnectFinishesTheModeAgnosticStreamToo() async throws {
        let harness = makeHarness()
        try await connect(harness)

        await harness.client.disconnect()
        await settle()

        let modeSpecificFinished = await harness.events.isFinished
        let radioFinished = await harness.radioEvents.isFinished
        XCTAssertTrue(modeSpecificFinished)
        XCTAssertTrue(radioFinished, "or a consumer's `for await` never ends")
        harness.transport.finish()
    }
}

// MARK: - Collectors

/// Lets one bounded wait serve both collectors.
private protocol FinishTracking: Actor {
    var isFinished: Bool { get }
}

/// Accumulates the received-audio stream off the test's own task, so the test
/// never has to be the thing draining it.
private actor AudioCollector: FinishTracking {
    private(set) var frames: [[Int16]] = []
    private(set) var isFinished = false

    var count: Int { frames.count }

    func append(_ frame: [Int16]) { frames.append(frame) }
    func finish() { isFinished = true }
}

private actor EventCollector: FinishTracking {
    private(set) var events: [IAX2ClientEvent] = []
    private(set) var isFinished = false

    func append(_ event: IAX2ClientEvent) { events.append(event) }
    func finish() { isFinished = true }
    func contains(where predicate: (IAX2ClientEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }
}

/// The mode-agnostic half of the same stream (RC-10).
private actor RadioEventCollector: FinishTracking {
    private(set) var events: [RadioEvent] = []
    private(set) var isFinished = false

    func append(_ event: RadioEvent) { events.append(event) }
    func finish() { isFinished = true }
}

// MARK: - Reentrancy test doubles

/// Signals completion without the observer having to `await` the task itself.
private actor Completion {
    private(set) var isSignalled = false
    func signal() { isSignalled = true }
}

/// Delivers a canned reply to `incoming` from *inside* the first `send`, then
/// yields enough times for the client's read loop to process it before `send`
/// returns — reproducing the actor-reentrancy window deterministically.
///
/// Only the first send replies: the client ACKs what it receives, and an
/// unconditional reply would recurse.
private final class ReplyDuringSendTransport: DatagramTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let reply: [Data]
    private let lock = NSLock()
    private var sentDatagrams: [Data] = []
    private var hasReplied = false
    private var isClosed = false

    var sent: [Data] { lock.withLock { sentDatagrams } }

    init(reply: [Data]) {
        self.reply = reply
        var escaped: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream<Data>(bufferingPolicy: .unbounded) { escaped = $0 }
        self.continuation = escaped
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
        // Give the read loop every chance to run the reply all the way through
        // the call's state machine before this send returns.
        for _ in 0..<500 { await Task.yield() }
    }

    func close() async {
        let alreadyClosed: Bool = lock.withLock {
            defer { isClosed = true }
            return isClosed
        }
        guard !alreadyClosed else { return }
        continuation.finish()
    }
}
