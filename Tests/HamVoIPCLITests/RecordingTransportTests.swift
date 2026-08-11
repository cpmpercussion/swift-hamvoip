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

    /// A 54-byte stream datagram is exactly what OQ-7 is hunting for, and
    /// exactly what `M17ReflectorClient` throws away: `M17StreamPacket.parse`
    /// requires `M17StreamPacket.byteCount` bytes, so the client's receive loop
    /// drops it and `events` never mentions it. The tap has to see it anyway,
    /// or the experiment cannot reach the conclusion that would refute our
    /// reading of the specification.
    func testADatagramTheClientWouldDiscardIsStillObserved() async throws {
        let fiftyFour = Data("M17 ".utf8) + Data(repeating: 0xAB, count: 50)
        XCTAssertEqual(fiftyFour.count, 54)
        XCTAssertThrowsError(try M17StreamPacket.parse(fiftyFour), "premise: the parser rejects 54 bytes")

        let upstream = MockTransport()
        let observed = Recorder()
        let tap = RecordingTransport(wrapping: upstream, onInbound: { observed.append($0) })

        upstream.inject(fiftyFour)
        await upstream.close()
        for await _ in tap.incoming {}

        XCTAssertEqual(observed.datagrams, [fiftyFour])
    }

    /// The whole experiment through the whole stack, with a fixture-style
    /// synthesised reflector on the other end and no socket anywhere (AU-5): a
    /// 54-byte reality reaches the tally even though the client sees nothing.
    func testTallyReachesAVerdictOnTrafficTheClientDropsEntirely() async throws {
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
                if case .stream = event { parsed += 1 }
            }
            return parsed
        }

        // The reflector accepts the link, then sends one over as 54-byte frames.
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            upstream.inject(M17ControlPacket.acknowledge.data)
        }
        try await client.connect(module: "C")
        await fulfillment(of: [linked], timeout: 2)

        let source = try M17Address(callsign: "VK2DEF").bytes
        for index in 0..<20 {
            var frame = Data("M17 ".utf8)
            frame.append(contentsOf: [0x00, 0x42])                                  // SID
            frame.append(contentsOf: try M17Address(callsign: "VK1XYZ").bytes)      // DST
            frame.append(contentsOf: source)                                        // SRC
            frame.append(contentsOf: [0x00, 0x05])                                  // TYPE
            frame.append(Data(repeating: 0x00, count: M17StreamPacket.metadataByteCount))
            frame.append(contentsOf: [0x00, UInt8(index)])                           // FN at 34
            frame.append(Data(repeating: UInt8(truncatingIfNeeded: index &* 37), count: 16))
            frame.append(contentsOf: [0x12, 0x34])                                   // CRC
            XCTAssertEqual(frame.count, 54)
            upstream.inject(frame)
        }

        // Give the pump task time to drain what was injected.
        try await waitUntil("20 stream datagrams observed") {
            recorder.tally.streamDatagramCount == 20
        }

        await client.shutdown()
        let parsedByTheClient = await streams.value

        XCTAssertEqual(
            parsedByTheClient, 0,
            "premise: none of these reach `events`, because the client cannot parse them")
        XCTAssertEqual(recorder.parsedStreamCount, 0)
        XCTAssertEqual(
            recorder.tally.verdict, .settled(byteCount: 54, hypothesis: .lichOmitsLSFCRC),
            "the tally must reach the answer from traffic the client discarded")
        XCTAssertEqual(recorder.tally.sourceCallsigns, ["VK2DEF": 20])
        XCTAssertGreaterThan(recorder.outboundCount, 0, "CONN at least should have been recorded")
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
