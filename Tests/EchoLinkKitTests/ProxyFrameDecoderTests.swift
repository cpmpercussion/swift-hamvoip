// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import RadioCore
import TestSupport

/// EL-4 — reassembling proxy frames from a byte stream.
///
/// These are the tests that would pass anyway if the decoder simply assumed one
/// chunk is one frame, *except* for the ones that deliberately chunk against
/// it. Those are the point: a stream decoder that has only ever been fed whole
/// frames is untested, not correct.
final class ProxyFrameDecoderTests: XCTestCase {
    private func fixtureFrames(_ name: String, dropFirst: Int = 0) throws -> [Data] {
        Array(try FixtureLoader.datagrams(name, in: Bundle.module).dropFirst(dropFirst))
    }

    // MARK: - Chunking

    func testFrameSplitAcrossTwoChunksDecodesOnce() throws {
        let frames = try fixtureFrames("live-proxy-audio-in.hex")
        let frame = frames[0]
        var decoder = EchoLinkProxyFrameDecoder()

        // Split inside the header, at the length field: the worst place, since
        // the decoder cannot even know how much more to expect.
        decoder.append(frame.prefix(6))
        XCTAssertNil(try decoder.nextFrame(), "half a header is not a frame yet")
        XCTAssertEqual(decoder.bufferedByteCount, 6)

        decoder.append(frame.dropFirst(6))
        let decoded = try decoder.nextFrame()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.encoded, frame)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testSplitInsideThePayloadDecodesOnce() throws {
        let frame = try fixtureFrames("live-proxy-audio-in.hex")[0]
        var decoder = EchoLinkProxyFrameDecoder()

        decoder.append(frame.prefix(EchoLinkProxyFrame.headerSize + 50))
        XCTAssertNil(try decoder.nextFrame(), "a declared payload that has not all arrived")

        decoder.append(frame.dropFirst(EchoLinkProxyFrame.headerSize + 50))
        XCTAssertEqual(try decoder.nextFrame()?.encoded, frame)
    }

    func testTwoFramesInOneChunkBothDecode() throws {
        let frames = try fixtureFrames("live-proxy-audio-in.hex")
        var coalesced = Data()
        coalesced.append(frames[0])
        coalesced.append(frames[1])

        var decoder = EchoLinkProxyFrameDecoder()
        decoder.append(coalesced)

        XCTAssertEqual(try decoder.nextFrame()?.encoded, frames[0])
        XCTAssertEqual(try decoder.nextFrame()?.encoded, frames[1],
                       "the decoder must keep going past the first frame in a chunk")
        XCTAssertNil(try decoder.nextFrame())
    }

    func testTailOfOneFrameAndHeadOfTheNextInOneChunk() throws {
        let frames = try fixtureFrames("live-proxy-audio-in.hex")
        var decoder = EchoLinkProxyFrameDecoder()

        // Chunk 1: all of frame 0 but its last 10 bytes.
        decoder.append(frames[0].dropLast(10))
        XCTAssertNil(try decoder.nextFrame())

        // Chunk 2: those 10 bytes *and* the head of frame 1 — the misaligned
        // case, where a frame boundary falls in the middle of a chunk.
        var straddling = Data(frames[0].suffix(10))
        straddling.append(frames[1].prefix(20))
        decoder.append(straddling)

        XCTAssertEqual(try decoder.nextFrame()?.encoded, frames[0])
        XCTAssertNil(try decoder.nextFrame(), "frame 1 is still incomplete")

        decoder.append(frames[1].dropFirst(20))
        XCTAssertEqual(try decoder.nextFrame()?.encoded, frames[1])
    }

    func testWholeFixtureDecodesByteByByte() throws {
        // The pathological chunking: if this passes, the decoder is a state
        // machine over a buffer rather than a parser that got lucky.
        let frames = try fixtureFrames("live-proxy-audio-in.hex")
        var stream = Data()
        for frame in frames { stream.append(frame) }

        var decoder = EchoLinkProxyFrameDecoder()
        var decoded: [Data] = []
        for byte in stream {
            decoder.append(Data([byte]))
            while let frame = try decoder.nextFrame() {
                decoded.append(frame.encoded)
            }
        }

        XCTAssertEqual(decoded, frames)
        XCTAssertEqual(decoder.bufferedByteCount, 0, "no bytes left over")
    }

    func testDrainReturnsEveryCompleteFrameAndLeavesThePartialOne() throws {
        let frames = try fixtureFrames("live-proxy-audio-in.hex")
        var stream = Data()
        for frame in frames.prefix(3) { stream.append(frame) }
        stream.append(frames[3].prefix(5))

        var decoder = EchoLinkProxyFrameDecoder()
        decoder.append(stream)

        let drained = try decoder.drain()
        XCTAssertEqual(drained.map(\.encoded), Array(frames.prefix(3)))
        XCTAssertEqual(decoder.bufferedByteCount, 5)
    }

    func testEmptyChunksAreHarmless() throws {
        let frame = try fixtureFrames("live-proxy-audio-in.hex")[0]
        var decoder = EchoLinkProxyFrameDecoder()

        decoder.append(Data())
        XCTAssertNil(try decoder.nextFrame())
        decoder.append(frame)
        decoder.append(Data())
        XCTAssertEqual(try decoder.nextFrame()?.encoded, frame)
    }

    // MARK: - The unframed login prefix

    func testTakePrefixLiftsTheUnframedNonceOffTheFront() throws {
        // The exact shape of a real session: 8 unframed ASCII bytes, then
        // framing starts. A decoder that looks for a 9-byte header at byte 0
        // reads the nonce as a header and desynchronises — the EL-1 trap.
        let all = try FixtureLoader.datagrams("live-proxy-login-in.hex", in: Bundle.module)
        let nonce = all[0]
        let frames = Array(all.dropFirst())

        var stream = nonce
        for frame in frames { stream.append(frame) }

        var decoder = EchoLinkProxyFrameDecoder()
        decoder.append(stream)

        XCTAssertEqual(decoder.takePrefix(8), nonce)
        XCTAssertEqual(String(data: nonce, encoding: .ascii), "6fc8b7e3",
                       "the nonce is 8 ASCII hex characters, not 4 raw bytes")

        let rest = try decoder.drain()
        XCTAssertEqual(rest.map(\.encoded), frames)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testTakePrefixWaitsForEnoughBytes() {
        var decoder = EchoLinkProxyFrameDecoder()
        decoder.append(Data([0x36, 0x66, 0x63]))

        XCTAssertNil(decoder.takePrefix(8), "only 3 of 8 bytes have arrived")
        XCTAssertEqual(decoder.bufferedByteCount, 3, "and nothing was consumed")

        decoder.append(Data([0x38, 0x62, 0x37, 0x65, 0x33]))
        XCTAssertEqual(decoder.takePrefix(8)?.count, 8)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testDecodingTheNonceAsAFrameIsWhatGoesWrong() throws {
        // Documents the failure this API exists to prevent, so that anyone who
        // "simplifies" takePrefix away has a test telling them what breaks.
        let all = try FixtureLoader.datagrams("live-proxy-login-in.hex", in: Bundle.module)
        var decoder = EchoLinkProxyFrameDecoder()
        decoder.append(all[0])                        // the 8-byte nonce alone
        decoder.append(all[1])                        // then a real STATUS frame

        // "6fc8b7e3" read as a header is type 0x36 ('6'), peer 102.99.56.98,
        // and a little-endian length spelled by the ASCII "7e3" plus the next
        // frame's first byte — 70477111 bytes. The ceiling catches it.
        //
        // That is luck rather than design, and the comment matters more than
        // the assertion: ASCII text read as a length is *usually* enormous,
        // because printable bytes in the high-order positions are large. It is
        // not guaranteed, and a nonce whose last characters happened to be low
        // bytes would sail through and desynchronise silently. The ceiling is
        // a backstop; `takePrefix` is the fix.
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? EchoLinkProxyFrameError, .implausibleLength(70_477_111))
        }
    }

    // MARK: - Desynchronisation

    func testImplausibleLengthThrowsRatherThanBuffering() {
        var decoder = EchoLinkProxyFrameDecoder()
        decoder.append(Data([0x02, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]))

        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(
                error as? EchoLinkProxyFrameError,
                .implausibleLength(Int(UInt32.max))
            )
        }
    }

    // MARK: - Over the transport seam

    func testDecodesAFixtureSessionDeliveredThroughMockStreamTransport() async throws {
        let frames = try fixtureFrames("live-proxy-audio-in.hex")
        let transport = MockStreamTransport()

        // Deliver the same frames three different ways in one session, because
        // a real connection does not pick one: split, coalesced, then whole.
        transport.injectSplit(frames[0], at: 4)
        transport.injectCoalesced([frames[1], frames[2]])
        transport.inject(frames[3])
        transport.finish()

        var decoder = EchoLinkProxyFrameDecoder()
        var decoded: [Data] = []
        for await chunk in transport.incoming {
            decoder.append(chunk)
            while let frame = try decoder.nextFrame() {
                decoded.append(frame.encoded)
            }
        }

        XCTAssertEqual(decoded, Array(frames.prefix(4)))
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }
}
