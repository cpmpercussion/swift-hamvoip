// SPDX-License-Identifier: Apache-2.0

import XCTest
import TestSupport
@testable import RadioCore

/// RC-1: proves the `DatagramTransport` seam behaves the way every later
/// fixture-driven test will assume — injected datagrams arrive in order, sends
/// are captured in order, and `close()` terminates the stream so consumer loops
/// end instead of hanging. No sockets, no sleeps.
final class MockTransportTests: XCTestCase {

    private func datagram(_ bytes: UInt8...) -> Data { Data(bytes) }

    /// Collect the whole stream. Only safe because every test finishes the
    /// transport; a hung stream would be caught by the XCTest timeout.
    private func drain(_ transport: MockTransport) async -> [Data] {
        var received: [Data] = []
        for await datagram in transport.incoming { received.append(datagram) }
        return received
    }

    // MARK: - Inbound

    func testInjectedDatagramsArriveInOrder() async {
        let transport = MockTransport()
        let expected = [datagram(0x01), datagram(0x02, 0x03), datagram(0xff)]

        // Injected before anyone iterates: the unbounded buffer must hold them.
        for value in expected { transport.inject(value) }
        transport.finish()

        let received = await drain(transport)
        XCTAssertEqual(received, expected)
    }

    func testInjectedDatagramsReachAConsumerAlreadyIterating() async {
        let transport = MockTransport()
        let expected = (0..<32).map { datagram(UInt8($0)) }

        let consumer = Task { await self.drain(transport) }

        // Hand over one at a time while the consumer is live; ordering must
        // still be arrival order.
        for value in expected {
            transport.inject(value)
            await Task.yield()
        }
        transport.finish()

        let received = await consumer.value
        XCTAssertEqual(received, expected)
    }

    func testInjectAcceptsABatch() async {
        let transport = MockTransport()
        let expected = [datagram(0xaa), datagram(0xbb), datagram(0xcc)]

        transport.inject(expected)
        await transport.close()

        let received = await drain(transport)
        XCTAssertEqual(received, expected)
    }

    func testInjectAfterCloseIsIgnored() async {
        let transport = MockTransport()
        transport.inject(datagram(0x01))
        await transport.close()
        transport.inject(datagram(0x02))

        let received = await drain(transport)
        XCTAssertEqual(received, [datagram(0x01)])
    }

    // MARK: - Outbound

    func testSendCapturesDatagramsInOrder() async throws {
        let transport = MockTransport()
        let expected = [datagram(0x10), datagram(0x20, 0x21), datagram(0x30)]

        for value in expected { try await transport.send(value) }

        XCTAssertEqual(transport.sent, expected)
        XCTAssertEqual(transport.sentCount, expected.count)
    }

    func testClearSentDropsTheRecord() async throws {
        let transport = MockTransport()
        try await transport.send(datagram(0x01))
        transport.clearSent()
        try await transport.send(datagram(0x02))

        XCTAssertEqual(transport.sent, [datagram(0x02)])
    }

    func testSendAfterCloseThrows() async {
        let transport = MockTransport()
        await transport.close()

        do {
            try await transport.send(datagram(0x01))
            XCTFail("send after close should throw")
        } catch {
            XCTAssertEqual(error as? DatagramTransportError, .closed)
        }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testConcurrentSendsAreAllRecorded() async {
        let transport = MockTransport()
        let count = 200

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    // Two-byte payload so 200 values stay distinguishable.
                    try? await transport.send(Data([UInt8(index / 256), UInt8(index % 256)]))
                }
            }
        }

        // Order across concurrent tasks is undefined; completeness is not.
        XCTAssertEqual(transport.sentCount, count)
        XCTAssertEqual(Set(transport.sent).count, count)
    }

    // MARK: - Shutdown

    func testCloseTerminatesTheStream() async {
        let transport = MockTransport()

        let consumer = Task { await self.drain(transport) }
        transport.inject(datagram(0x01))
        await transport.close()

        // Completes only because the stream finished.
        let received = await consumer.value
        XCTAssertEqual(received, [datagram(0x01)])
        XCTAssertTrue(transport.isClosed)
    }

    func testStreamIteratorReturnsNilAfterClose() async {
        let transport = MockTransport()
        transport.inject(datagram(0x01))
        transport.finish()

        var iterator = transport.incoming.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()

        XCTAssertEqual(first, datagram(0x01))
        XCTAssertNil(second)
    }

    func testCloseIsIdempotent() async {
        let transport = MockTransport()
        XCTAssertFalse(transport.isClosed)

        await transport.close()
        transport.finish()
        await transport.close()

        XCTAssertTrue(transport.isClosed)
        let received = await drain(transport)
        XCTAssertTrue(received.isEmpty)
    }
}
