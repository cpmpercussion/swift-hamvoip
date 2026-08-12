// SPDX-License-Identifier: Apache-2.0

import XCTest
import RadioCore
import TestSupport

/// Tests for `MockStreamTransport` itself (EL-3).
///
/// Worth testing a test double because this one has a job beyond standing in
/// for a socket: it is the only thing in the tree that can reproduce the two
/// chunkings a stream decoder gets wrong. If `injectSplit` quietly delivered
/// one chunk, every EL-4 decoder test would still pass and the decoder would
/// still be broken on a real connection.
final class MockStreamTransportTests: XCTestCase {
    /// Collect up to `count` chunks, or everything until the stream finishes.
    private func collect(
        _ stream: AsyncStream<Data>,
        count: Int
    ) async -> [Data] {
        var chunks: [Data] = []
        for await chunk in stream {
            chunks.append(chunk)
            if chunks.count == count { break }
        }
        return chunks
    }

    // MARK: - Chunking

    func testInjectSplitDeliversOneFrameAsTwoChunks() async {
        let transport = MockStreamTransport()
        let frame = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

        transport.injectSplit(frame, at: 2)

        let chunks = await collect(transport.incoming, count: 2)
        XCTAssertEqual(chunks.count, 2, "a split must arrive as two separate chunks")
        XCTAssertEqual(chunks[0], Data([0x01, 0x02]))
        XCTAssertEqual(chunks[1], Data([0x03, 0x04, 0x05, 0x06]))
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, frame,
                       "splitting must not change the bytes")
    }

    func testInjectSplitAtAnImpossibleOffsetDeliversOneChunk() async {
        let transport = MockStreamTransport()
        let frame = Data([0xAA, 0xBB])

        // 0 and count are not splits, they are the whole frame with an empty
        // chunk beside it — which no real transport yields.
        transport.injectSplit(frame, at: 0)
        transport.injectSplit(frame, at: frame.count)
        transport.injectSplit(frame, at: 99)
        transport.finish()

        let chunks = await collect(transport.incoming, count: .max)
        XCTAssertEqual(chunks, [frame, frame, frame])
    }

    func testInjectCoalescedDeliversSeveralFramesAsOneChunk() async {
        let transport = MockStreamTransport()
        let first = Data([0x01, 0x02])
        let second = Data([0x03, 0x04])
        let third = Data([0x05])

        transport.injectCoalesced([first, second, third])
        transport.finish()

        let chunks = await collect(transport.incoming, count: .max)
        XCTAssertEqual(chunks.count, 1, "coalesced frames must arrive as a single chunk")
        XCTAssertEqual(chunks[0], Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    func testInjectByteByByteDeliversOneChunkPerByte() async {
        let transport = MockStreamTransport()

        transport.injectByteByByte(Data([0x11, 0x22, 0x33]))
        transport.finish()

        let chunks = await collect(transport.incoming, count: .max)
        XCTAssertEqual(chunks, [Data([0x11]), Data([0x22]), Data([0x33])])
    }

    func testChunksInjectedBeforeIterationAreStillDelivered() async {
        // Unbounded buffering: a fixture-driven test injects the whole session
        // up front and only then starts the code under test.
        let transport = MockStreamTransport()
        transport.inject(Data([0x01]))
        transport.inject(Data([0x02]))
        transport.finish()

        let chunks = await collect(transport.incoming, count: .max)
        XCTAssertEqual(chunks, [Data([0x01]), Data([0x02])])
    }

    // MARK: - Outbound

    func testSentBytesConcatenatesWrites() async throws {
        let transport = MockStreamTransport()
        try await transport.send(Data([0x01, 0x02]))
        try await transport.send(Data([0x03]))

        XCTAssertEqual(transport.sentCount, 2, "individual writes stay visible")
        XCTAssertEqual(transport.sentBytes, Data([0x01, 0x02, 0x03]),
                       "but the peer sees one stream")
    }

    func testClearSentDropsRecordedWrites() async throws {
        let transport = MockStreamTransport()
        try await transport.send(Data([0x01]))
        transport.clearSent()
        try await transport.send(Data([0x02]))

        XCTAssertEqual(transport.sentBytes, Data([0x02]))
    }

    // MARK: - Shutdown

    func testSendAfterCloseThrowsClosed() async throws {
        let transport = MockStreamTransport()
        await transport.close()

        do {
            try await transport.send(Data([0x01]))
            XCTFail("send after close must throw")
        } catch let error as StreamTransportError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testCloseFinishesIncoming() async {
        let transport = MockStreamTransport()
        await transport.close()

        var iterator = transport.incoming.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next, "close() must finish incoming")
    }

    func testCloseIsIdempotent() async {
        let transport = MockStreamTransport()
        await transport.close()
        await transport.close()
        transport.finish()
        XCTAssertTrue(transport.isClosed)
    }

    func testInjectAfterFinishIsIgnored() async {
        let transport = MockStreamTransport()
        transport.finish()
        transport.inject(Data([0x01]))

        var iterator = transport.incoming.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next, "a finished stream stays finished")
    }
}
