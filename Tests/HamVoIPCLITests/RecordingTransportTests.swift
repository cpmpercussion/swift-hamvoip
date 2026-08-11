// SPDX-License-Identifier: Apache-2.0

import Foundation
import M17Kit
import RadioCore
import TestSupport
import XCTest

@testable import hamvoip_cli

/// The transport tap the OQ-7 experiment measures through.
///
/// The test that carries the weight is
/// ``testADatagramTheClientWouldDiscardIsStillObserved``: it encodes the reason
/// this decorator exists at all, and it would fail loudly if someone later
/// "simplified" the harness to listen on `M17ReflectorClient.events`.
final class RecordingTransportTests: XCTestCase {

    func testInboundDatagramsAreObservedAndForwardedUnchanged() async throws {
        let upstream = MockTransport()
        let observed = Recorder()
        let tap = RecordingTransport(wrapping: upstream, onInbound: { observed.append($0) })

        upstream.inject(Data([0x01, 0x02]))
        upstream.inject(Data([0x03]))
        await upstream.close()

        var forwarded: [Data] = []
        for await datagram in tap.incoming { forwarded.append(datagram) }

        XCTAssertEqual(forwarded, [Data([0x01, 0x02]), Data([0x03])])
        XCTAssertEqual(observed.datagrams, forwarded, "the observer must see exactly what is forwarded")
    }

    /// The tap must observe a stream datagram of a length the parser refuses,
    /// because `M17StreamPacket.parse` requires exactly `byteCount` bytes and
    /// `M17ReflectorClient` drops what it cannot parse — such a datagram never
    /// reaches `events`.
    ///
    /// The length used here is 56, which is the reading OQ-7 refuted. Before
    /// 2026-08-11 this test used 54 and the roles were the other way round; the
    /// structural point is the one that survived the answer, and it is why the
    /// experiment could reach a conclusion that contradicted the code running
    /// it. If a future reflector turns out to send 56, the harness will report
    /// it rather than fall silent.
    func testADatagramTheClientWouldDiscardIsStillObserved() async throws {
        let fiftySix = Data("M17 ".utf8) + Data(repeating: 0xAB, count: 52)
        XCTAssertEqual(fiftySix.count, 56)
        XCTAssertThrowsError(try M17StreamPacket.parse(fiftySix), "premise: the parser rejects 56 bytes")

        let upstream = MockTransport()
        let observed = Recorder()
        let tap = RecordingTransport(wrapping: upstream, onInbound: { observed.append($0) })

        upstream.inject(fiftySix)
        await upstream.close()
        for await _ in tap.incoming {}

        XCTAssertEqual(observed.datagrams, [fiftySix])
    }

    /// The settled reality through the whole stack, with a synthesised reflector
    /// on the other end and no socket anywhere (AU-5): 54-byte frames reach the
    /// tally *and* the client parses them, which is the state of the world after
    /// OQ-7. The end-to-end check that the layout change is coherent from the
    /// socket seam up to `events`.
    func testTheSettledFiftyFourByteRealityIsBothParsedAndTallied() async throws {
        let (recorder, parsedByTheClient) = try await runOver(hypothesis: .lichOmitsLSFCRC)

        XCTAssertEqual(parsedByTheClient, 20, "54 bytes is what the parser now accepts")
        XCTAssertEqual(recorder.parsedStreamCount, 20)
        XCTAssertEqual(
            recorder.tally.verdict, .settled(byteCount: 54, hypothesis: .lichOmitsLSFCRC))
        XCTAssertEqual(recorder.tally.sourceCallsigns, ["VK2DEF": 20])
        XCTAssertGreaterThan(recorder.outboundCount, 0, "CONN at least should have been recorded")
    }

    /// The property that let OQ-7 be settled at all, kept pointing the other
    /// way: a reality the parser cannot parse still reaches a verdict.
    ///
    /// Now that 54 is implemented, the length the client drops is 56 — so this
    /// injects 56-byte frames and requires the tally to name them while `events`
    /// stays empty. Had the harness been built on `events` it would report a
    /// silent reflector here, which is the failure mode `RecordingTransport`
    /// exists to prevent, and which would matter again the moment a reflector
    /// sends something other than 54.
    func testTallyReachesAVerdictOnTrafficTheClientDropsEntirely() async throws {
        let (recorder, parsedByTheClient) = try await runOver(hypothesis: .lichIncludesLSFCRC)

        XCTAssertEqual(
            parsedByTheClient, 0,
            "premise: none of these reach `events`, because the client cannot parse them")
        XCTAssertEqual(recorder.parsedStreamCount, 0)
        XCTAssertEqual(
            recorder.tally.verdict, .settled(byteCount: 56, hypothesis: .lichIncludesLSFCRC),
            "the tally must reach an answer from traffic the client discarded")
        XCTAssertEqual(recorder.tally.sourceCallsigns, ["VK2DEF": 20])
    }

    /// Links to a synthesised reflector and takes one 20-frame over from it,
    /// framed under `hypothesis`. Returns the recorder and how many stream
    /// events the client managed to parse.
    private func runOver(hypothesis: OQ7Hypothesis) async throws -> (OQ7Recorder, Int) {
        let upstream = MockTransport()
        let recorder = OQ7Recorder()
        let tap = RecordingTransport(
            wrapping: upstream,
            onInbound: { recorder.recordInbound($0) },
            onOutbound: { _ in recorder.recordOutbound() })

        let client = try M17ReflectorClient(
            callsign: "VK1XYZ", transport: tap, clock: ContinuousClock())

        let linked = expectation(description: "linked")
        let streams = Task {
            var parsed = 0
            for await event in client.events {
                if case .linked = event { linked.fulfill() }
                if case .stream = event {
                    parsed += 1
                    recorder.recordParsedStream()  // as OQ7Command does
                }
            }
            return parsed
        }

        Task {
            try? await Task.sleep(for: .milliseconds(20))
            upstream.inject(M17ControlPacket.acknowledge.data)
        }
        try await client.connect(module: "C")
        await fulfillment(of: [linked], timeout: 2)

        for index in 0..<20 {
            let frame = try streamFrame(hypothesis: hypothesis, index: index)
            XCTAssertEqual(frame.count, hypothesis.byteCount)
            upstream.inject(frame)
        }

        // The tap records ahead of the client, so "20 datagrams tallied" does
        // not mean the client has looked at them yet. A PING behind the over
        // does: the receive loop is sequential, so a PONG on the wire proves
        // every stream datagram ahead of it has already been through
        // `handleInbound` — whether it parsed or was dropped.
        try await waitUntil("20 stream datagrams observed") {
            recorder.tally.streamDatagramCount == 20
        }
        let outboundBeforePing = recorder.outboundCount
        upstream.inject(M17ControlPacket.ping(from: try M17Address(callsign: "VK3REF")).data)
        try await waitUntil("the PING behind the over answered with a PONG") {
            recorder.outboundCount > outboundBeforePing
        }

        await client.shutdown()
        return (recorder, await streams.value)
    }

    /// One stream frame, laid out as `hypothesis` reads Table 27. The two differ
    /// only in the two bytes after META: an LSF CRC under the 56-byte reading,
    /// the start of FN under the 54-byte one.
    private func streamFrame(hypothesis: OQ7Hypothesis, index: Int) throws -> Data {
        var frame = Data("M17 ".utf8)
        frame.append(contentsOf: [0x00, 0x42])                                   // SID
        frame.append(contentsOf: try M17Address(callsign: "VK1XYZ").bytes)       // DST
        frame.append(contentsOf: try M17Address(callsign: "VK2DEF").bytes)       // SRC
        frame.append(contentsOf: [0x00, 0x05])                                   // TYPE
        frame.append(Data(repeating: 0x00, count: M17StreamPacket.metadataByteCount))
        if hypothesis == .lichIncludesLSFCRC {
            frame.append(contentsOf: [0xAB, 0xCD])                               // LSF CRC
        }
        XCTAssertEqual(frame.count, hypothesis.frameNumberOffset)
        frame.append(contentsOf: [0x00, UInt8(index)])                           // FN
        frame.append(Data(repeating: UInt8(truncatingIfNeeded: index &* 37), count: 16))
        frame.append(contentsOf: [0x12, 0x34])                                   // CRC
        return frame
    }

    func testOutboundDatagramsAreObservedAndForwarded() async throws {
        let upstream = MockTransport()
        let observed = Recorder()
        let tap = RecordingTransport(
            wrapping: upstream, onInbound: { _ in }, onOutbound: { observed.append($0) })

        try await tap.send(Data([0xAA]))

        XCTAssertEqual(observed.datagrams, [Data([0xAA])])
        XCTAssertEqual(upstream.sent, [Data([0xAA])])
    }

    func testCloseClosesUpstreamAndFinishesTheStream() async throws {
        let upstream = MockTransport()
        let tap = RecordingTransport(wrapping: upstream, onInbound: { _ in })

        await tap.close()
        for await _ in tap.incoming {}  // returns only if the stream finished

        XCTAssertTrue(upstream.isClosed)
        await tap.close()  // idempotent
    }

    // MARK: Helpers

    /// Polls a condition rather than sleeping a fixed time, so the test is not
    /// pinned to how fast the pump task happens to run.
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)")
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Data] = []

        var datagrams: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ datagram: Data) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(datagram)
        }
    }
}
