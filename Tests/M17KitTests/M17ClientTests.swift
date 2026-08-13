// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import TestSupport
import XCTest

@testable import M17Kit

/// M17-5: `M17Client`, the one type an application sees for M17.
///
/// Every test runs on `MockTransport`, `ManualTestClock` and `StubCodec`: no
/// socket, no real time, and no dependence on `Codec2.xcframework` (AU-5).
final class M17ClientTests: XCTestCase {

    private static let reflector = M17Destination(
        host: "reflector.example.test", module: "C", callsign: "VK2DEF")

    private let codec = StubCodec()

    // MARK: - Harness

    private struct Harness {
        let client: M17Client
        let transport: MockTransport
        let clock: ManualTestClock
        let audio: AudioSink
        let events: EventSink
        let audioTask: Task<Void, Never>
        let eventTask: Task<Void, Never>
    }

    private func makeHarness(
        configuration: M17Client.Configuration = M17Client.Configuration()
    ) -> Harness {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let client = M17Client(
            codec: codec,
            configuration: configuration,
            clock: clock,
            transportFactory: { _ in transport })

        let audio = AudioSink()
        let audioTask = Task {
            for await frame in client.receivedAudio { await audio.append(frame) }
            await audio.finish()
        }
        let events = EventSink()
        let eventTask = Task {
            for await event in client.events { await events.append(event) }
            await events.finish()
        }
        return Harness(
            client: client, transport: transport, clock: clock,
            audio: audio, events: events, audioTask: audioTask, eventTask: eventTask)
    }

    private func tearDown(_ harness: Harness) async {
        await harness.client.disconnect()
        harness.transport.finish()
    }

    /// Links the client, answering the `CONN` with an `ACKN` the way a
    /// reflector would.
    private func connect(_ harness: Harness) async throws {
        let connecting = Task { try await harness.client.connect(to: Self.reflector) }
        _ = await waitForSent(1, harness.transport)
        harness.transport.inject(M17ControlPacket.acknowledge.data)
        try await connecting.value
    }

    private func settle(_ iterations: Int = 200) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    @discardableResult
    private func waitForSent(
        _ count: Int, _ transport: MockTransport,
        file: StaticString = #filePath, line: UInt = #line
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
    private func waitForEvent(
        _ predicate: @escaping @Sendable (M17ClientEvent) -> Bool,
        _ sink: EventSink, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100_000 {
            if await sink.contains(where: predicate) { return true }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        return false
    }

    /// One 20 ms frame whose samples all carry `value`.
    private func frame(_ value: Int16) -> [Int16] {
        [Int16](repeating: value, count: codec.samplesPerFrame)
    }

    /// A stream datagram from another station, as a reflector would relay it.
    private func inboundStream(
        streamID: UInt16 = 0x5151,
        sequence: UInt16,
        value: Int16,
        isLast: Bool = false
    ) throws -> Data {
        var tx = M17StreamTransmitter(
            streamID: streamID,
            destination: .broadcast,
            source: try M17Address(callsign: "VK3ABC"))
        for _ in 0..<sequence { _ = try tx.next(payload: Data(repeating: 0, count: 16)) }
        let pcm = [Int16](repeating: value, count: M17StreamPayload.samplesPerPacket)
        return try tx.next(pcm: pcm, using: codec, isLast: isLast).data
    }

    // MARK: - Connecting

    func testConnectLinksAndReportsTheModule() async throws {
        let harness = makeHarness()
        try await connect(harness)

        let connected = await harness.client.isConnected
        XCTAssertTrue(connected)
        XCTAssertEqual(harness.client.state, .receiving)
        _ = await waitForEvent({ $0 == .linked(module: "C") }, harness.events, "linked")

        // The first datagram out is the CONN for module C.
        let conn = try M17ControlPacket.parse(harness.transport.sent[0])
        guard case .connect(let address, let module) = conn else {
            return XCTFail("expected a CONN, got \(conn)")
        }
        XCTAssertEqual(address.callsign, "VK2DEF")
        XCTAssertEqual(module.letter, "C")

        await tearDown(harness)
    }

    func testConnectingTwiceIsRefused() async throws {
        let harness = makeHarness()
        try await connect(harness)

        do {
            try await harness.client.connect(to: Self.reflector)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? M17ClientError, .alreadyConnected)
        }
        await tearDown(harness)
    }

    func testAnUnencodableCallsignIsRefusedBeforeAnySocketIsMade() async {
        let harness = makeHarness()
        do {
            try await harness.client.connect(
                to: M17Destination(host: "h", module: "C", callsign: "not a callsign!"))
            XCTFail("expected a refusal")
        } catch {
            guard case .invalidDestination = error as? M17ClientError else {
                return XCTFail("expected invalidDestination, got \(error)")
            }
        }
        XCTAssertEqual(harness.transport.sentCount, 0, "nothing should have gone on the wire")
        await tearDown(harness)
    }

    // MARK: - Transmitting

    func testTwoTwentyMillisecondFramesMakeOneDatagram() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()
        try await harness.client.startTransmit()

        // The first half is held back; the second completes the datagram.
        let first = try await harness.client.transmit(pcm: frame(1))
        XCTAssertNil(first, "the first 20 ms frame is held for its partner")
        XCTAssertEqual(harness.transport.sentCount, 0)

        let second = try await harness.client.transmit(pcm: frame(2))
        XCTAssertNotNil(second, "the second 20 ms frame completes a 40 ms datagram")
        _ = await waitForSent(1, harness.transport)

        // And it carries both halves, in order.
        let packet = try M17StreamPacket.parse(harness.transport.sent[0])
        let halves = try M17StreamPayload.split(packet.payload, bytesPerCodecFrame: 8)
        XCTAssertEqual(halves[0], [UInt8](repeating: 1, count: 8))
        XCTAssertEqual(halves[1], [UInt8](repeating: 2, count: 8))
        XCTAssertTrue(packet.isCRCValid)

        await tearDown(harness)
    }

    func testFrameNumbersAdvanceOncePerDatagram() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()
        try await harness.client.startTransmit()

        for index in 0..<6 { _ = try await harness.client.transmit(pcm: frame(Int16(index))) }
        _ = await waitForSent(3, harness.transport)

        let numbers = try harness.transport.sent.prefix(3).map {
            try M17StreamPacket.parse($0).sequenceNumber
        }
        XCTAssertEqual(numbers, [0, 1, 2])

        await tearDown(harness)
    }

    func testEachPTTGetsItsOwnStreamID() async throws {
        let harness = makeHarness()
        try await connect(harness)

        var streamIDs: [UInt16] = []
        for _ in 0..<2 {
            harness.transport.clearSent()
            try await harness.client.startTransmit()
            _ = try await harness.client.transmit(pcm: frame(1))
            _ = try await harness.client.transmit(pcm: frame(2))
            _ = await waitForSent(1, harness.transport)
            streamIDs.append(try M17StreamPacket.parse(harness.transport.sent[0]).streamID)
            await harness.client.stopTransmit()
        }

        // "Random bits, changed for each PTT or stream" — and it is what lets a
        // receiver tell one over from the next.
        XCTAssertNotEqual(streamIDs[0], streamIDs[1])

        await tearDown(harness)
    }

    func testSendingWithoutPTTIsDroppedRatherThanThrown() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()

        // A capture pipeline runs continuously; knowing PTT is up is the
        // client's job, and dropping is the fail-safe direction.
        let sent = try await harness.client.transmit(pcm: frame(1))
        XCTAssertNil(sent)
        await settle()
        XCTAssertEqual(harness.transport.sentCount, 0)

        await tearDown(harness)
    }

    func testUnkeyingSendsALastFrame() async throws {
        let harness = makeHarness()
        try await connect(harness)
        harness.transport.clearSent()
        try await harness.client.startTransmit()
        _ = try await harness.client.transmit(pcm: frame(1))
        _ = try await harness.client.transmit(pcm: frame(2))
        _ = await waitForSent(1, harness.transport)

        await harness.client.stopTransmit()
        _ = await waitForSent(2, harness.transport)

        let last = try M17StreamPacket.parse(harness.transport.sent[1])
        XCTAssertTrue(last.isLastFrame, "a receiver should see the over end, not just stop")
        XCTAssertEqual(harness.client.state, .receiving)

        await tearDown(harness)
    }

    func testStartTransmitWithoutALinkIsRefused() async {
        let harness = makeHarness()
        do {
            try await harness.client.startTransmit()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? M17ClientError, .notConnected)
        }
        await tearDown(harness)
    }

    // MARK: - The transmit watchdog (SF-1)

    func testTheWatchdogUnkeysAStuckPTT() async throws {
        var configuration = M17Client.Configuration()
        configuration.transmitTimeout = .seconds(5)
        let harness = makeHarness(configuration: configuration)
        try await connect(harness)
        try await harness.client.startTransmit()
        guard case .transmitting = harness.client.state else {
            return XCTFail("premise: PTT is down")
        }

        // Three live sleepers now: the playout tick, the link's keepalive
        // deadline, and the watchdog. (One more than the IAX2 equivalent —
        // M17's link layer runs a deadline of its own.) Waiting for the third
        // is what makes the advance deterministic: advancing before the
        // watchdog has entered `sleep` computes its deadline against
        // already-advanced time, and it never fires.
        let armed = await harness.clock.waitUntilSleepers(3)
        XCTAssertTrue(armed, "the watchdog never armed its deadline")
        harness.clock.advance(by: .seconds(5))

        _ = await waitForEvent(
            { if case .transmitWatchdogExpired = $0 { return true } else { return false } },
            harness.events, "the watchdog to fire")
        XCTAssertEqual(harness.client.state, .receiving, "a stuck PTT must not hold a repeater")

        await tearDown(harness)
    }

    // MARK: - Receiving

    func testAnInboundOverBecomesPlayableAudio() async throws {
        let harness = makeHarness()
        try await connect(harness)

        for sequence in UInt16(0)..<4 {
            harness.transport.inject(
                try inboundStream(sequence: sequence, value: Int16(sequence + 1)))
        }

        _ = await waitForEvent(
            { if case .streamStarted = $0 { return true } else { return false } },
            harness.events, "a stream to start")

        // Eight 20 ms slots queued from four datagrams.
        for _ in 0..<100_000 {
            if await harness.client.queuedInboundFrameCount >= 8 { break }
            await Task.yield()
        }
        let queued = await harness.client.queuedInboundFrameCount
        XCTAssertEqual(queued, 8, "four datagrams are eight codec frames")

        await tearDown(harness)
    }

    func testACorruptDatagramIsRefusedAndReportedOnce() async throws {
        let harness = makeHarness()
        try await connect(harness)

        // Same corruption ten times over: the report must not repeat.
        for _ in 0..<10 {
            var bytes = [UInt8](try inboundStream(sequence: 0, value: 1))
            bytes[40] ^= 0xFF
            harness.transport.inject(Data(bytes))
        }

        _ = await waitForEvent(
            { if case .streamRejected(.crcFailed) = $0 { return true } else { return false } },
            harness.events, "a CRC rejection")
        await settle()

        let rejections = await harness.events.events.filter {
            if case .streamRejected = $0 { return true } else { return false }
        }
        XCTAssertEqual(rejections.count, 1, "a corrupt stream must report once, not 25 times a second")
        let queued = await harness.client.queuedInboundFrameCount
        XCTAssertEqual(queued, 0, "nothing corrupt should reach playout")

        await tearDown(harness)
    }

    func testTheLastFrameOfAnOverIsReportedAsACleanEnd() async throws {
        let harness = makeHarness()
        try await connect(harness)

        harness.transport.inject(try inboundStream(sequence: 0, value: 1))
        harness.transport.inject(try inboundStream(sequence: 1, value: 2, isLast: true))

        _ = await waitForEvent(
            { $0 == .streamEnded(source: try! M17Address(callsign: "VK3ABC"), reason: .lastFrame) },
            harness.events, "a clean end of over")

        await tearDown(harness)
    }

    /// A station displaced mid-over is reported as cut off, not as having
    /// finished. Raised in review: both cases used to emit the same event,
    /// whose documentation only described the clean one.
    func testAStationTalkedOverIsReportedAsPreempted() async throws {
        let harness = makeHarness()
        try await connect(harness)

        // One station starts and does *not* send a last frame…
        harness.transport.inject(try inboundStream(streamID: 0x1111, sequence: 0, value: 1))
        _ = await waitForEvent(
            { if case .streamStarted = $0 { return true } else { return false } },
            harness.events, "the first stream to start")

        // …and another takes the channel.
        harness.transport.inject(try inboundStream(streamID: 0x2222, sequence: 0, value: 9))

        _ = await waitForEvent(
            {
                if case .streamEnded(_, .preempted) = $0 { return true } else { return false }
            },
            harness.events, "the displaced station to be reported as cut off")

        await tearDown(harness)
    }

    /// And an over that ended cleanly must not *also* be reported as
    /// preempted when the next station keys up.
    func testACleanlyEndedOverIsNotAlsoReportedAsPreempted() async throws {
        let harness = makeHarness()
        try await connect(harness)

        harness.transport.inject(
            try inboundStream(streamID: 0x1111, sequence: 0, value: 1, isLast: true))
        _ = await waitForEvent(
            { if case .streamEnded(_, .lastFrame) = $0 { return true } else { return false } },
            harness.events, "the clean end")

        harness.transport.inject(try inboundStream(streamID: 0x2222, sequence: 0, value: 9))
        _ = await waitForEvent(
            { if case .streamStarted(_, 0x2222) = $0 { return true } else { return false } },
            harness.events, "the second stream to start")
        await settle()

        let preemptions = await harness.events.events.filter {
            if case .streamEnded(_, .preempted) = $0 { return true } else { return false }
        }
        XCTAssertTrue(preemptions.isEmpty, "a stream must not end twice")

        await tearDown(harness)
    }

    // MARK: - Teardown

    func testDisconnectFinishesBothPublicStreams() async throws {
        let harness = makeHarness()
        try await connect(harness)

        await harness.client.disconnect()
        harness.transport.finish()

        _ = await harness.audioTask.value
        _ = await harness.eventTask.value
        let audioFinished = await harness.audio.isFinished
        let eventsFinished = await harness.events.isFinished
        XCTAssertTrue(audioFinished)
        XCTAssertTrue(eventsFinished)

        let connected = await harness.client.isConnected
        XCTAssertFalse(connected)
        XCTAssertEqual(harness.client.state, .idle)
    }
}

// MARK: - Collectors

private actor AudioSink {
    private(set) var frames: [[Int16]] = []
    private(set) var isFinished = false
    var count: Int { frames.count }
    func append(_ frame: [Int16]) { frames.append(frame) }
    func finish() { isFinished = true }
}

private actor EventSink {
    private(set) var events: [M17ClientEvent] = []
    private(set) var isFinished = false
    func append(_ event: M17ClientEvent) { events.append(event) }
    func finish() { isFinished = true }
    func contains(where predicate: (M17ClientEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }
}
