// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import RadioCore
import TestSupport

/// EL-9 — the `NetworkClient` facade, driven from fixtures over mock
/// transports. No socket is opened (AU-5).
///
/// The codec is a stub, deliberately. `EchoLinkClient` is written against
/// `RadioCore.VoiceCodec` and never names GSM, so the sequencing, the packing
/// and the watchdog are all covered whether or not the vendored codec is
/// present — the precedent `M17Client` set for Codec2.
final class EchoLinkClientTests: XCTestCase {
    private static let callsign = "N0CALL"
    private static let nonce = "6fc8b7e3"
    private static let peer = EchoLinkPeerAddress(13, 57, 14, 183)
    /// The address the captures show in the only OPEN a real client sends.
    private static let directoryServer = EchoLinkPeerAddress(152, 67, 98, 197)

    /// A 33-byte-per-frame, 160-sample-per-frame codec that does no signal
    /// processing: exactly GSM 06.10's frame geometry, so every size assertion
    /// in the client is exercised, with none of the codec's behaviour.
    private struct StubCodec: VoiceCodec {
        let samplesPerFrame = 160
        let bytesPerFrame = 33

        func encode(_ pcm: [Int16]) throws -> [UInt8] {
            // First sample's low byte, repeated: enough to tell frames apart.
            [UInt8](repeating: UInt8(truncatingIfNeeded: pcm.first ?? 0), count: bytesPerFrame)
        }

        func decode(_ frame: [UInt8]) throws -> [Int16] {
            [Int16](repeating: Int16(frame.first ?? 0), count: samplesPerFrame)
        }
    }

    private struct Harness {
        let client: EchoLinkClient
        let transport: MockStreamTransport
    }

    private func makeHarness(
        transmitTimeout: Duration = .seconds(180),
        accountPassword: EchoLinkAccountPassword? = nil,
        directoryServer: EchoLinkPeerAddress? = nil,
        // Generous on purpose. These tests inject the node's answer as soon
        // as the write appears, so a long timeout costs nothing in wall-clock
        // — but a short one turns a loaded CI machine into a spurious
        // .nodeDidNotAnswer. Only the test that *wants* a timeout sets a
        // short one.
        nodeAnswerTimeout: Duration = .seconds(20)
    ) -> Harness {
        let transport = MockStreamTransport()
        let client = EchoLinkClient(
            codec: StubCodec(),
            configuration: .init(
                callsign: Self.callsign,
                operatorName: "Test Operator",
                accountPassword: accountPassword,
                directoryServer: directoryServer,
                transmitTimeout: transmitTimeout,
                frameInterval: .milliseconds(20),
                nodeAnswerTimeout: nodeAnswerTimeout,
                nodeAnswerRetryInterval: .milliseconds(50)
            ),
            clock: ContinuousClock(),
            transportFactory: { _ in transport }
        )
        return Harness(client: client, transport: transport)
    }

    /// An inbound RTCP SDES, which is how a node answers.
    private func nodeAnswer(name: String = "*ECHOTEST* (Conference  [7]) CONF") -> Data {
        let compound = EchoLinkRTCPCompound([
            .receiverReport(ssrc: 9999),
            .sourceDescription(ssrc: 9999, items: [
                EchoLinkSDESItem(.cname, "CALLSIGN"),
                EchoLinkSDESItem(.name, name),
                EchoLinkSDESItem(.tool, "thebridge V 0.81"),
            ]),
        ])
        return EchoLinkProxyFrame(
            type: .udpControl, peer: Self.peer, payload: compound.encoded
        ).encoded
    }

    /// Waits until the client has written at least `count` chunks.
    ///
    /// Deadline-bounded rather than iteration-bounded, and that distinction is
    /// the whole point: a `for _ in 0 ..< 200_000 { await Task.yield() }` loop
    /// is not a synchronisation primitive. On a loaded machine those yields are
    /// consumed by other work and the loop expires *before* the client has done
    /// anything, so the test injects its reply at the wrong moment and fails —
    /// intermittently, and only under load, which is the worst kind. A wall
    /// clock waits longer when the machine is slower, which is what was meant.
    private func waitForWrites(
        _ harness: Harness,
        _ count: Int,
        timeout: Duration = .seconds(10)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while harness.transport.sentCount < count, ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func destination() -> EchoLinkDestination {
        EchoLinkDestination(
            peer: Self.peer,
            node: "*ECHOTEST*",
            route: .proxy(host: "proxy.invalid", port: 8100, password: .publicProxy)
        )
    }

    private func fixtureLines(_ name: String) throws -> [Data] {
        try FixtureLoader.datagrams(name, in: Bundle.module)
    }

    private func statusSuccess() throws -> Data {
        try fixtureLines("live-proxy-login-in.hex")[1]
    }

    /// Connects with no directory login: proxy login, then the node SDES.
    ///
    /// Note what is NOT here: there is no OPEN for the node, and so no STATUS
    /// to inject. Across three captures, 0x01 OPEN was only ever sent for the
    /// directory server — audio channels are connectionless.
    private func connect(_ harness: Harness) async throws {
        let task = Task { try await harness.client.connect(to: destination()) }

        // The proxy speaks first with its unframed nonce.
        harness.transport.inject(Data(Self.nonce.utf8))
        // [0] login, [1] the opening SDES. Answer only once it has gone out.
        await waitForWrites(harness, 2)
        harness.transport.inject(nodeAnswer())
        try await task.value
    }

    /// Connects with the directory login, feeding each reply as it is asked for.
    private func connectWithDirectory(_ harness: Harness) async throws {
        let task = Task { try await harness.client.connect(to: destination()) }

        harness.transport.inject(Data(Self.nonce.utf8))
        // [0] proxy login, [1] OPEN to the directory server.
        await waitForWrites(harness, 2)
        harness.transport.inject(try statusSuccess())
        // [2] the tunnelled account login.
        await waitForWrites(harness, 3)
        harness.transport.inject(
            EchoLinkProxyFrame(type: .data, payload: Data("OK".utf8)).encoded)
        // The proxy closes the directory channel — which must NOT end the
        // session — and then [3] the opening SDES goes to the node.
        harness.transport.inject(EchoLinkProxyFrame(type: .close).encoded)
        await waitForWrites(harness, 4)
        harness.transport.inject(nodeAnswer())
        try await task.value
    }

    // MARK: - Connect

    func testConnectLogsInSendsTheOpeningSDESAndReportsReceiving() async throws {
        let harness = makeHarness()
        try await connect(harness)

        let connected = await harness.client.isConnected
        XCTAssertTrue(connected)
        XCTAssertEqual(harness.client.state, .receiving)

        // What went on the wire: the proxy login, then RR+SDES to the node.
        let writes = harness.transport.sent
        XCTAssertEqual(
            writes[0],
            EchoLinkAuth.proxyLoginMessage(
                callsign: Self.callsign, password: .publicProxy, nonce: Self.nonce
            )
        )
        let frame = try EchoLinkProxyFrame.parse(writes[1]).frame
        XCTAssertEqual(frame.type, .udpControl, "the node session opens on the control channel")
        XCTAssertEqual(frame.peer, Self.peer)

        let compound = try EchoLinkRTCPCompound.parse(frame.payload)
        XCTAssertEqual(compound.packets.count, 2, "RR then SDES, as observed")
        guard case .receiverReport = compound.packets[0] else {
            return XCTFail("first packet must be a receiver report")
        }
        guard case .sourceDescription(_, let items) = compound.packets[1] else {
            return XCTFail("second packet must be an SDES")
        }
        let name = items.first { $0.type == .name }?.text
        XCTAssertEqual(name, "N0CALL         Test Operator",
                       "callsign left-justified in a 15-character field, then the name")
    }

    func testNoOpenIsEverSentForTheNode() async throws {
        // The correction that matters most: across three captures and six
        // distinct audio peers, 0x01 OPEN was only ever sent for the directory
        // server. An earlier version of connect() opened a channel to the node,
        // which no real client does.
        let harness = makeHarness()
        try await connect(harness)

        for write in harness.transport.sent.dropFirst() {
            let frame = try EchoLinkProxyFrame.parse(write).frame
            XCTAssertNotEqual(frame.type, .open, "no OPEN may be sent for an audio peer")
        }
    }

    func testConnectingTwiceIsRejected() async throws {
        let harness = makeHarness()
        try await connect(harness)

        do {
            try await harness.client.connect(to: destination())
            XCTFail("a second connect must be rejected")
        } catch let error as EchoLinkClientError {
            XCTAssertEqual(error, .alreadyConnected)
        }
    }

    func testDirectModeIsRefusedRatherThanGuessedAt() async throws {
        // FR-3.3 keeps direct mode reachable in the model, but no capture of a
        // direct session exists, and building the socket setup from the
        // plausible reading is what this module's position forbids.
        let harness = makeHarness()
        let direct = EchoLinkDestination(peer: Self.peer, node: "*ECHOTEST*", route: .direct)

        do {
            try await harness.client.connect(to: direct)
            XCTFail("direct mode must not silently pretend to work")
        } catch let error as EchoLinkClientError {
            XCTAssertEqual(error, .directModeUnavailable)
        }
    }

    func testProxyFailureSurfacesAndLeavesTheClientIdle() async throws {
        let harness = makeHarness()
        let task = Task { try await harness.client.connect(to: destination()) }
        harness.transport.finish()

        do {
            try await task.value
            XCTFail("connect must fail when the proxy hangs up")
        } catch let error as EchoLinkClientError {
            guard case .proxy = error else {
                return XCTFail("expected .proxy, got \(error)")
            }
        }

        let connected = await harness.client.isConnected
        XCTAssertFalse(connected, "a failed connect must not leave a half-open session")
        XCTAssertEqual(harness.client.state, .idle)
    }

    // MARK: - The directory login, wired into connect

    func testDirectoryLoginRunsInTheRightOrderAndOpensTheSession() async throws {
        // The whole sequence the captures show, in one test:
        //   proxy login -> OPEN(directory) -> account login -> "OK" -> CLOSE
        //   -> SDES to the node.
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword("not-a-real-password"),
            directoryServer: Self.directoryServer
        )
        try await connectWithDirectory(harness)

        let writes = harness.transport.sent
        XCTAssertEqual(writes.count, 4)

        let open = try EchoLinkProxyFrame.parse(writes[1]).frame
        XCTAssertEqual(open.type, .open)
        XCTAssertEqual(open.peer, Self.directoryServer,
                       "the only OPEN a real client sends is to the directory server")

        let login = try EchoLinkProxyFrame.parse(writes[2]).frame
        XCTAssertEqual(login.type, .data, "the account login is tunnelled as 0x02")
        XCTAssertEqual(login.peer, Self.directoryServer,
                       "an outbound 0x02 names the directory server, not 0.0.0.0")
        XCTAssertEqual(login.payload.filter { $0 == 0x0D }.count, 3,
                       "login line, ONLINE declaration, location")
        XCTAssertEqual(login.payload.first, 0x6C)

        let sdes = try EchoLinkProxyFrame.parse(writes[3]).frame
        XCTAssertEqual(sdes.type, .udpControl)
        XCTAssertEqual(sdes.peer, Self.peer)

        let connected = await harness.client.isConnected
        XCTAssertTrue(connected)
    }

    func testTheDirectoryChannelClosingDoesNotEndTheSession() async throws {
        // The bug this replaces would have torn down every session a few
        // hundred milliseconds after connecting: the proxy CLOSEs the
        // directory channel on purpose, with all the audio still to come.
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword("not-a-real-password"),
            directoryServer: Self.directoryServer
        )
        try await connectWithDirectory(harness)

        // Another CLOSE, well after connecting.
        harness.transport.inject(EchoLinkProxyFrame(type: .close).encoded)
        // Give the CLOSE a moment to be processed; the assertion below is
        // that it changed nothing.
        try? await Task.sleep(for: .milliseconds(50))

        let connected = await harness.client.isConnected
        XCTAssertTrue(connected, "a CLOSE closes a tunnelled channel, not the session")
        XCTAssertEqual(harness.client.state, .receiving)
    }

    func testRejectedDirectoryLoginIsATypedErrorAndLeavesTheClientIdle() async throws {
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword("wrong"),
            directoryServer: Self.directoryServer
        )
        let task = Task { try await harness.client.connect(to: destination()) }

        harness.transport.inject(Data(Self.nonce.utf8))
        await waitForWrites(harness, 2)
        harness.transport.inject(try statusSuccess())
        await waitForWrites(harness, 3)
        harness.transport.inject(
            EchoLinkProxyFrame(type: .data, payload: Data("Bad password".utf8)).encoded)

        do {
            try await task.value
            XCTFail("a rejected account login must not read as connected")
        } catch let error as EchoLinkClientError {
            guard case .directory(let inner) = error else {
                return XCTFail("expected .directory, got \(error)")
            }
            guard case .loginRejected = inner else {
                return XCTFail("expected .loginRejected, got \(inner)")
            }
        }

        let connected = await harness.client.isConnected
        XCTAssertFalse(connected)
        XCTAssertEqual(harness.client.state, .idle)
    }

    func testHalfADirectoryConfigurationIsRefused() async throws {
        // A password with nowhere to send it would silently skip the login it
        // was given for, which is worse than refusing.
        let passwordOnly = makeHarness(
            accountPassword: EchoLinkAccountPassword("x"),
            directoryServer: nil
        )
        do {
            try await passwordOnly.client.connect(to: destination())
            XCTFail("a password with no directory server must be refused")
        } catch let error as EchoLinkClientError {
            XCTAssertEqual(error, .directoryLoginIncomplete)
        }

        let serverOnly = makeHarness(accountPassword: nil, directoryServer: Self.directoryServer)
        do {
            try await serverOnly.client.connect(to: destination())
            XCTFail("a directory server with no password must be refused")
        } catch let error as EchoLinkClientError {
            XCTAssertEqual(error, .directoryLoginIncomplete)
        }
    }

    func testAccountPasswordNeverAppearsInAConnectError() async throws {
        let secret = "hunter2-not-real"
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword(secret),
            directoryServer: Self.directoryServer
        )
        let task = Task { try await harness.client.connect(to: destination()) }

        harness.transport.inject(Data(Self.nonce.utf8))
        await waitForWrites(harness, 2)
        harness.transport.inject(try statusSuccess())
        await waitForWrites(harness, 3)
        harness.transport.inject(
            EchoLinkProxyFrame(type: .data, payload: Data("NO".utf8)).encoded)

        do {
            try await task.value
            XCTFail("expected a rejection")
        } catch {
            XCTAssertFalse("\(error)".contains(secret), "the error leaked the password")
        }
    }

    // MARK: - The node handshake

    func testConnectFailsWhenTheNodeNeverAnswers() async throws {
        // Better than reporting success and then sitting in silence: if nothing
        // answers the SDES, there is no session.
        let harness = makeHarness(nodeAnswerTimeout: .milliseconds(300))
        let task = Task { try await harness.client.connect(to: destination()) }
        harness.transport.inject(Data(Self.nonce.utf8))

        do {
            try await task.value
            XCTFail("a node that never answers must not read as connected")
        } catch let error as EchoLinkClientError {
            XCTAssertEqual(error, .nodeDidNotAnswer)
        }

        let connected = await harness.client.isConnected
        XCTAssertFalse(connected)
    }

    func testTheOpeningSDESIsRetransmittedUntilAnswered() async throws {
        // The observed client sent it twice, ~0.8 s apart, before the node
        // replied ~1.5 s in.
        let harness = makeHarness(nodeAnswerTimeout: .seconds(20))
        let task = Task { try await harness.client.connect(to: destination()) }
        harness.transport.inject(Data(Self.nonce.utf8))

        await waitForWrites(harness, 3)  // login + at least two SDES
        harness.transport.inject(nodeAnswer())
        try await task.value

        XCTAssertGreaterThanOrEqual(harness.transport.sentCount, 3,
                                    "the SDES must be resent while waiting")
    }

    func testInboundAudioCountsAsTheNodeAnswering() async throws {
        // ECHOTEST's first reply in the capture was oNDATA text, before its
        // RTCP — so anything from the peer means it is there.
        let harness = makeHarness()
        let task = Task { try await harness.client.connect(to: destination()) }
        harness.transport.inject(Data(Self.nonce.utf8))
        await waitForWrites(harness, 2)

        harness.transport.inject(
            EchoLinkProxyFrame(
                type: .udpData, peer: Self.peer,
                payload: Data("oNDATA*ECHOTEST*\r".utf8)
            ).encoded)
        try await task.value

        let connected = await harness.client.isConnected
        XCTAssertTrue(connected)
    }

    func testANodeGoodbyeEndsTheSession() async throws {
        let harness = makeHarness()
        try await connect(harness)

        let goodbye = EchoLinkProxyFrame(
            type: .udpControl, peer: Self.peer,
            payload: EchoLinkRTCPCompound.sessionClosing(ssrc: 9999).encoded
        )
        harness.transport.inject(goodbye.encoded)
        await waitWhile { await harness.client.isConnected }

        let connected = await harness.client.isConnected
        XCTAssertFalse(connected, "a BYE from the node ends the session")
    }

    func testDisconnectSendsAGoodbye() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()

        await harness.client.disconnect()

        let frames = try harness.transport.sent.map { try EchoLinkProxyFrame.parse($0).frame }
        let byes = try frames
            .filter { $0.type == .udpControl }
            .map { try EchoLinkRTCPCompound.parse($0.payload) }
            .filter(\.isGoodbye)
        XCTAssertEqual(byes.count, 1,
                       "the far end should see a clean end, not infer one from silence")
    }

    func testConcurrentTeardownsSendOnlyOneGoodbye() async throws {
        // Plan rule 10, in teardown. Saying goodbye means awaiting a send, and
        // an actor is reentrant across that await — so two teardown paths
        // (disconnect(), and the frame pump noticing the stream end) could both
        // be inside releaseSession(), both see phase == .connected, and both
        // send a BYE.
        //
        // This reproduced as an intermittent failure of the test above, at
        // roughly one run in eight and only under load. Racing the two paths
        // deliberately is what makes it a test rather than a coincidence.
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()

        async let first: Void = harness.client.disconnect()
        async let second: Void = harness.client.disconnect()
        harness.transport.finish()
        _ = await (first, second)

        let byes = try harness.transport.sent
            .map { try EchoLinkProxyFrame.parse($0).frame }
            .filter { $0.type == .udpControl }
            .map { try EchoLinkRTCPCompound.parse($0.payload) }
            .filter(\.isGoodbye)
        XCTAssertLessThanOrEqual(byes.count, 1, "exactly one teardown may claim the goodbye")
    }

    // MARK: - Receive

    func testCapturedAudioReachesTheReceivedAudioStream() async throws {
        let harness = makeHarness()
        try await connect(harness)

        let audio = try fixtureLines("live-proxy-audio-in.hex")
        let collected = Task { () -> [[Int16]] in
            var frames: [[Int16]] = []
            for await pcm in harness.client.receivedAudio {
                frames.append(pcm)
                if frames.count == 8 { break }
            }
            return frames
        }

        harness.transport.inject(audio)
        let frames = await collected.value

        XCTAssertEqual(frames.count, 8)
        XCTAssertTrue(frames.allSatisfy { $0.count == 160 },
                      "one 20 ms frame of 8 kHz mono per tick")
    }

    func testANewTalkspurtIsReported() async throws {
        let harness = makeHarness()
        try await connect(harness)

        let events = Task { () -> [EchoLinkClientEvent] in
            var seen: [EchoLinkClientEvent] = []
            for await event in harness.client.events {
                seen.append(event)
                if seen.filter({ $0 == .talkspurtStarted }).count == 2 { break }
            }
            return seen
        }

        // The fixture spans a talkspurt boundary: 146..151 then 0..7.
        harness.transport.inject(try fixtureLines("live-proxy-audio-in.hex"))
        let seen = await events.value

        XCTAssertEqual(seen.filter { $0 == .talkspurtStarted }.count, 2,
                       "the first packet, and the 151 -> 0 boundary")
    }

    func testStationInfoIsReportedAndNotPlayed() async throws {
        // The 0x05 channel is not audio-only. Text played as speech is noise.
        let harness = makeHarness()
        try await connect(harness)

        let events = Task { () -> EchoLinkClientEvent? in
            for await event in harness.client.events {
                if case .stationInfo = event { return event }
            }
            return nil
        }

        let info = EchoLinkProxyFrame(
            type: .udpData,
            peer: Self.peer,
            payload: Data("oNDATA*ECHOTEST*\rConference\r".utf8)
        )
        harness.transport.inject(info.encoded)

        guard case .stationInfo(let text) = await events.value else {
            return XCTFail("station info must be surfaced as an event")
        }
        XCTAssertTrue(text.hasPrefix("oNDATA"))
    }

    // MARK: - Playout continuity

    func testEveryPlayoutTickYieldsAFrameEvenWithNothingBuffered() async throws {
        // The bug this pins: an earlier version yielded nothing on
        // .concealment/.silence, leaving holes in the output stream. The device
        // underruns on a hole, and the result is continuous grinding rather
        // than an obvious fault.
        let harness = makeHarness()
        try await connect(harness)

        // Nothing is injected, so every tick is a starved one.
        let collected = Task { () -> [[Int16]] in
            var frames: [[Int16]] = []
            for await pcm in harness.client.receivedAudio {
                frames.append(pcm)
                if frames.count == 5 { break }
            }
            return frames
        }
        let frames = await collected.value

        XCTAssertEqual(frames.count, 5, "a starved buffer must still tick")
        XCTAssertTrue(frames.allSatisfy { $0.count == 160 },
                      "and every frame is a whole 20 ms of samples")
        XCTAssertTrue(frames.allSatisfy { $0.allSatisfy { $0 == 0 } },
                      "with nothing to conceal from, silence is zeros")
    }

    func testCapturedAudioPlaysOutWithoutSkippingATick() async throws {
        let harness = makeHarness()
        try await connect(harness)

        let collected = Task { () -> [[Int16]] in
            var frames: [[Int16]] = []
            for await pcm in harness.client.receivedAudio {
                frames.append(pcm)
                if frames.count == 12 { break }
            }
            return frames
        }

        harness.transport.inject(try fixtureLines("live-proxy-audio-in.hex"))
        let frames = await collected.value

        XCTAssertEqual(frames.count, 12, "the tick never skips")
        XCTAssertTrue(frames.allSatisfy { $0.count == 160 })
        XCTAssertTrue(frames.contains { $0.contains { $0 != 0 } },
                      "the captured audio must reach the stream")
    }

    func testTheJitterBufferDefaultAbsorbsTheMeasuredBurstiness() {
        // Sizing for one 80 ms packet is not enough, and the reason is the
        // transport rather than the protocol: the proxy tunnels UDP inside TCP,
        // and TCP bunches it. Measured on a live 65-second session with ZERO
        // packet loss in either direction:
        //
        //     inter-arrival p50 0 ms, p90 184 ms, max 375 ms
        //     worst shortfall against a steady 20 ms grid: 265 ms
        //
        // Nothing was lost; it was all late, together. The buffer has to hold
        // the burst, so the target sits above that worst shortfall.
        let buffer = EchoLinkClient.defaultJitterBuffer

        XCTAssertGreaterThanOrEqual(
            buffer.currentTargetDepth, .milliseconds(265),
            "the initial target must cover the worst measured shortfall")
        XCTAssertGreaterThanOrEqual(
            buffer.minDepth, .milliseconds(240),
            "the floor must sit above the measured arrival rhythm — adaptation "
                + "can drive the target down to it, and a floor below the "
                + "bunching starves on every clump")
        XCTAssertGreaterThanOrEqual(
            buffer.maxDepth, .milliseconds(375),
            "the ceiling must reach the largest observed gap")
        XCTAssertEqual(buffer.frameDuration, .milliseconds(20))
    }

    // MARK: - Transmit

    func testTransmitEmitsAPacketEveryFourFrames() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()

        try await harness.client.startTransmit()
        guard case .transmitting = harness.client.state else {
            return XCTFail("state must be .transmitting after startTransmit")
        }

        let pcm = [Int16](repeating: 1000, count: 160)
        for index in 0 ..< 3 {
            let early = try await harness.client.transmit(pcm: pcm)
            XCTAssertNil(early, "frame \(index) must not complete a packet on its own")
        }
        let packet = try await harness.client.transmit(pcm: pcm)

        XCTAssertEqual(packet?.codecFrames.count, 4)
        XCTAssertEqual(harness.transport.sentCount, 1, "four 20 ms frames, one 80 ms packet")

        let frame = try EchoLinkProxyFrame.parse(harness.transport.sentBytes).frame
        XCTAssertEqual(frame.type, .udpData)
        XCTAssertEqual(frame.peer, Self.peer)
        XCTAssertEqual(frame.payload.count, EchoLinkRTPPacket.observedPacketSize)
    }

    func testSendWhileNotTransmittingIsDroppedNotThrown() async throws {
        // A capture pipeline runs continuously. Dropping silently is the
        // fail-safe direction: the failure mode is dead air, not an open
        // microphone.
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()

        for _ in 0 ..< 8 {
            let sent = try await harness.client.transmit(pcm: [Int16](repeating: 5, count: 160))
            XCTAssertNil(sent)
        }
        XCTAssertEqual(harness.transport.sentCount, 0, "nothing may go out unkeyed")
    }

    func testStopTransmitFlushesRatherThanClippingTheOver() async throws {
        let harness = makeHarness()
        try await connect(harness)
        try await harness.client.startTransmit()
        harness.transport.clearSent()

        // Two frames — not a full packet.
        let pcm = [Int16](repeating: 700, count: 160)
        _ = try await harness.client.transmit(pcm: pcm)
        _ = try await harness.client.transmit(pcm: pcm)
        XCTAssertEqual(harness.transport.sentCount, 0)

        await harness.client.stopTransmit()

        XCTAssertEqual(harness.transport.sentCount, 1, "the part-filled packet must go out")
        let frame = try EchoLinkProxyFrame.parse(harness.transport.sentBytes).frame
        let packet = try EchoLinkRTPPacket.parse(frame.payload)
        XCTAssertEqual(packet.codecFrames.count, 2)
        XCTAssertEqual(harness.client.state, .receiving)
    }

    func testStartTransmitIsIdempotent() async throws {
        let harness = makeHarness()
        try await connect(harness)

        try await harness.client.startTransmit()
        guard case .transmitting(let since) = harness.client.state else {
            return XCTFail("expected .transmitting")
        }
        try await harness.client.startTransmit()
        guard case .transmitting(let stillSince) = harness.client.state else {
            return XCTFail("expected .transmitting")
        }
        XCTAssertEqual(since, stillSince, "re-keying must not restart the over")
    }

    func testTransmitBeforeConnectIsRejected() async {
        let harness = makeHarness()
        do {
            try await harness.client.startTransmit()
            XCTFail("cannot transmit before connecting")
        } catch {
            XCTAssertEqual(error as? EchoLinkClientError, .notConnected)
        }
    }

    // MARK: - The watchdog (SF-1)

    func testWatchdogCutsTransmissionAtItsLimit() async throws {
        // The safety requirement lives in the library, not the app.
        let harness = makeHarness(transmitTimeout: .milliseconds(120))
        try await connect(harness)

        let timedOut = Task { () -> Duration? in
            for await event in harness.client.events {
                if case .transmitTimedOut(let after) = event { return after }
            }
            return nil
        }

        try await harness.client.startTransmit()
        guard case .transmitting = harness.client.state else {
            return XCTFail("expected .transmitting")
        }

        let after = await timedOut.value
        XCTAssertEqual(after, .milliseconds(120))
        XCTAssertEqual(harness.client.state, .receiving,
                       "the watchdog must return the client to receive, not leave it keyed")
    }

    func testAudioStopsGoingOutAfterTheWatchdogFires() async throws {
        let harness = makeHarness(transmitTimeout: .milliseconds(80))
        try await connect(harness)

        let timedOut = Task { () -> Bool in
            for await event in harness.client.events {
                if case .transmitTimedOut = event { return true }
            }
            return false
        }
        try await harness.client.startTransmit()
        _ = await timedOut.value
        harness.transport.clearSent()

        for _ in 0 ..< 8 {
            _ = try await harness.client.transmit(pcm: [Int16](repeating: 9, count: 160))
        }
        XCTAssertEqual(harness.transport.sentCount, 0,
                       "a cut transmission must stay cut")
    }

    // MARK: - Disconnect

    func testDisconnectClosesEverythingAndFinishesTheStreams() async throws {
        let harness = makeHarness()
        try await connect(harness)

        await harness.client.disconnect()

        let connected = await harness.client.isConnected
        XCTAssertFalse(connected)
        XCTAssertEqual(harness.client.state, .idle)
        XCTAssertTrue(harness.transport.isClosed)

        var audio = harness.client.receivedAudio.makeAsyncIterator()
        let next = await audio.next()
        XCTAssertNil(next, "receivedAudio must finish")
    }

    func testDisconnectIsIdempotent() async throws {
        let harness = makeHarness()
        try await connect(harness)
        await harness.client.disconnect()
        await harness.client.disconnect()
        XCTAssertEqual(harness.client.state, .idle)
    }

    func testDisconnectWhileTransmittingUnkeys() async throws {
        let harness = makeHarness()
        try await connect(harness)
        try await harness.client.startTransmit()

        await harness.client.disconnect()
        XCTAssertEqual(harness.client.state, .idle, "PTT must not survive a disconnect")
    }

    // MARK: - The whole cycle

    func testFullConnectReceiveTransmitDisconnectCycle() async throws {
        // EL-9's done-when, as one test.
        let harness = makeHarness()
        try await connect(harness)

        // Receive.
        let heard = Task { () -> Int in
            var count = 0
            for await _ in harness.client.receivedAudio {
                count += 1
                if count == 4 { break }
            }
            return count
        }
        harness.transport.inject(Array(try fixtureLines("live-proxy-audio-in.hex").prefix(2)))
        let received = await heard.value
        XCTAssertEqual(received, 4)

        // Transmit.
        harness.transport.clearSent()
        try await harness.client.startTransmit()
        for _ in 0 ..< 4 {
            _ = try await harness.client.transmit(pcm: [Int16](repeating: 300, count: 160))
        }
        await harness.client.stopTransmit()
        XCTAssertGreaterThanOrEqual(harness.transport.sentCount, 1)

        // Disconnect.
        await harness.client.disconnect()
        XCTAssertEqual(harness.client.state, .idle)
    }

    // MARK: - Destination

    func testProxyIsTheDefaultRoute() {
        // FR-3.3: the proxy is the default, because direct mode is unusable
        // behind the CGNAT the app's main target sits behind.
        let destination = EchoLinkDestination(peer: Self.peer, node: "*ECHOTEST*")
        XCTAssertTrue(destination.isProxied)
    }

    // MARK: - Station list (EL-11)

    /// A small invented list. Not capture data — see `EchoLinkStationListTests`
    /// for why this target has no station-list fixture and cannot have one.
    private func inventedList() -> Data {
        Data("""
            @@@
            2:64244576
            N0CALL
            Nowhere                    [ON 19:43]
            100001
            192.0.2.11
            *ECHOTEST*
            Audio test server          [ON 09:12]
            9999
            198.51.100.7
            +++
            """.utf8)
    }

    /// Connects for the directory alone: no node, no SDES, no answer to inject.
    private func connectForDirectory(_ harness: Harness) async throws {
        let task = Task {
            try await harness.client.connect(to: destination(), mode: .directoryOnly)
        }
        harness.transport.inject(Data(Self.nonce.utf8))
        // [0] proxy login, [1] OPEN to the directory server.
        await waitForWrites(harness, 2)
        harness.transport.inject(try statusSuccess())
        // [2] the tunnelled account login.
        await waitForWrites(harness, 3)
        harness.transport.inject(
            EchoLinkProxyFrame(type: .data, payload: Data("OK".utf8)).encoded)
        try await task.value
    }

    /// `.directoryOnly` must stop after the directory login. If it opened a
    /// node session, `--list` could fail because a node was unreachable — a
    /// failure that has nothing to do with the station list.
    func testDirectoryOnlyModeNeverOpensANodeSession() async throws {
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword("secret"),
            directoryServer: Self.peer,
            // Short on purpose: if this mode did wait for a node, the test
            // fails in a second instead of hanging for twenty.
            nodeAnswerTimeout: .seconds(1))
        try await connectForDirectory(harness)

        let connected = await harness.client.isConnected
        XCTAssertTrue(connected)

        // The opening SDES is a 0x06 frame. None may have gone out.
        let control = harness.transport.sent
            .compactMap { try? EchoLinkProxyFrame.parse($0) }
            .filter { $0.frame.type == .udpControl }
        XCTAssertTrue(control.isEmpty, "directoryOnly sent an SDES to a node")
    }

    /// And the list can then be fetched over that session.
    func testStationListCanBeFetchedWithoutEverReachingANode() async throws {
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword("secret"),
            directoryServer: Self.peer,
            nodeAnswerTimeout: .seconds(1))
        try await connectForDirectory(harness)

        let before = harness.transport.sentCount
        let task = Task { try await harness.client.fetchStationList(timeout: .seconds(10)) }
        await waitForWrites(harness, before + 1)
        harness.transport.inject(try statusSuccess())
        await waitForWrites(harness, before + 2)
        harness.transport.inject(
            EchoLinkProxyFrame(type: .data, payload: inventedList()).encoded)

        let list = try await task.value
        XCTAssertEqual(list.stations.count, 2)
    }

    /// The whole point of the reader: the list arrives split across frames at
    /// boundaries that fall inside records. Splitting mid-field here is what
    /// the real 129-frame download did.
    func testStationListArrivesAcrossFramesAndParses() async throws {
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword("secret"),
            directoryServer: Self.peer)
        try await connectWithDirectory(harness)

        let before = harness.transport.sentCount
        let task = Task { try await harness.client.fetchStationList(timeout: .seconds(10)) }

        // [n] OPEN for the second directory channel. `proxy.open` waits for
        // the STATUS before the request goes out, so the status must be fed
        // between the two writes rather than after both — waiting for both
        // first deadlocks until the open times out.
        await waitForWrites(harness, before + 1)
        harness.transport.inject(try statusSuccess())
        // [n+1] the "f0" request.
        await waitForWrites(harness, before + 2)

        let bytes = Array(inventedList())
        for chunk in stride(from: 0, to: bytes.count, by: 17) {
            let slice = Data(bytes[chunk ..< min(chunk + 17, bytes.count)])
            harness.transport.inject(
                EchoLinkProxyFrame(type: .data, payload: slice).encoded)
        }

        let list = try await task.value
        XCTAssertEqual(list.declaredCount, 2)
        XCTAssertEqual(list.stations.map(\.callsign), ["N0CALL", "*ECHOTEST*"])
        XCTAssertEqual(list.stations[0].nodeNumber, 100_001)
        XCTAssertEqual(list.stations[1].status, "ON")
    }

    /// The request is the three measured bytes, sent on a channel of its own —
    /// the capture shows a *second* OPEN rather than the login channel reused.
    func testFetchOpensASecondChannelAndSendsTheMeasuredRequest() async throws {
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword("secret"),
            directoryServer: Self.peer)
        try await connectWithDirectory(harness)

        let before = harness.transport.sentCount
        let task = Task { try await harness.client.fetchStationList(timeout: .seconds(2)) }
        await waitForWrites(harness, before + 1)
        harness.transport.inject(try statusSuccess())
        await waitForWrites(harness, before + 2)

        let written = harness.transport.sent
        let open = try EchoLinkProxyFrame.parse(written[before])
        let request = try EchoLinkProxyFrame.parse(written[before + 1])
        XCTAssertEqual(open.frame.type, .open)
        XCTAssertEqual(request.frame.type, .data)
        XCTAssertEqual(Array(request.frame.payload), [0x66, 0x30, 0x0D])

        _ = try? await task.value
    }

    /// A download that stalls must not read as a complete short list. This is
    /// the failure the whole reader exists to make loud.
    func testAStalledDownloadIsATimeoutErrorNotAShortList() async throws {
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword("secret"),
            directoryServer: Self.peer)
        try await connectWithDirectory(harness)

        let before = harness.transport.sentCount
        let task = Task { try await harness.client.fetchStationList(timeout: .milliseconds(300)) }
        await waitForWrites(harness, before + 1)
        harness.transport.inject(try statusSuccess())
        await waitForWrites(harness, before + 2)

        // Half a list, and then nothing.
        let half = Data(Array(inventedList()).prefix(60))
        harness.transport.inject(EchoLinkProxyFrame(type: .data, payload: half).encoded)

        do {
            _ = try await task.value
            XCTFail("expected a stalled download to throw")
        } catch let error as EchoLinkClientError {
            guard case .stationList(.missingTerminator) = error else {
                return XCTFail("expected .stationList(.missingTerminator), got \(error)")
            }
        }
    }

    func testFetchingWithoutASessionIsRejected() async {
        let harness = makeHarness(directoryServer: Self.peer)
        do {
            _ = try await harness.client.fetchStationList()
            XCTFail("expected .notConnected")
        } catch let error as EchoLinkClientError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("expected EchoLinkClientError, got \(error)")
        }
    }

    /// `connect` must not have grown a 433 kB download. M3 signed off the
    /// sequence as it stands, and the list is not on the path to a QSO.
    func testConnectDoesNotFetchTheStationList() async throws {
        let harness = makeHarness(
            accountPassword: EchoLinkAccountPassword("secret"),
            directoryServer: Self.peer)
        try await connectWithDirectory(harness)

        let requests = harness.transport.sent.compactMap { try? EchoLinkProxyFrame.parse($0) }
            .filter { $0.frame.type == .data
                && Array($0.frame.payload) == Array(EchoLinkStationList.stationListRequest) }
        XCTAssertTrue(requests.isEmpty, "connect sent a station-list request")
    }
}

/// Spins until `condition` goes false, or a wall-clock deadline passes.
///
/// Deliberately not a fixed iteration count. Those look like waits and are not:
/// under load the yields get consumed by other work and the loop expires before
/// the thing it is waiting for has happened, which fails the assertion that
/// follows — intermittently, and only on a busy machine.
func waitWhile(
    _ timeout: Duration = .seconds(10),
    _ condition: () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while await condition(), ContinuousClock.now < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}
