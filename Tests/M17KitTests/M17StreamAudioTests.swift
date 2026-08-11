// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import XCTest

@testable import M17Kit

/// A stand-in for Codec2 3200 with the same frame geometry — 160 samples in,
/// 8 bytes out — and an encoding simple enough to assert against.
///
/// Deliberately not the real codec. Everything M17-4's sequencing does is
/// codec-agnostic: the frame numbering, the last-frame flag, the 16-into-2
/// payload split, the jitter-buffer slot arithmetic. Testing that against a
/// codec whose output is predictable makes the assertions about *the
/// sequencing* rather than about the codec's bit-exactness, and it means these
/// tests run on a checkout where `Codec2.xcframework` has not been built —
/// which includes CI. `Codec2VoiceCodecTests` covers the real thing.
struct StubCodec: VoiceCodec {
    let samplesPerFrame = 160
    let bytesPerFrame = 8

    /// The first eight samples, halved into bytes. Enough that a frame's
    /// identity survives a round trip through the payload split.
    func encode(_ pcm: [Int16]) throws -> [UInt8] {
        guard pcm.count == samplesPerFrame else {
            throw M17StreamAudioError.wrongSampleCount(
                expected: samplesPerFrame, actual: pcm.count)
        }
        return (0..<bytesPerFrame).map { UInt8(truncatingIfNeeded: pcm[$0]) }
    }

    func decode(_ frame: [UInt8]) throws -> [Int16] {
        guard frame.count == bytesPerFrame else {
            throw M17StreamAudioError.payloadNotDivisible(
                payloadBytes: frame.count, codecFrameBytes: bytesPerFrame)
        }
        var pcm = [Int16](repeating: 0, count: samplesPerFrame)
        for index in 0..<bytesPerFrame { pcm[index] = Int16(frame[index]) }
        return pcm
    }
}

/// Tests for the M17 stream audio path (M17-4) that do not need codec2.
final class M17StreamAudioTests: XCTestCase {

    private func address(_ callsign: String) throws -> M17Address {
        try M17Address(callsign: callsign)
    }

    private func transmitter(streamID: UInt16 = 0x1234) throws -> M17StreamTransmitter {
        M17StreamTransmitter(
            streamID: streamID,
            destination: try address("VK1XYZ"),
            source: try address("VK2DEF"))
    }

    // MARK: - Payload split

    func testTheFrameArithmeticIsTwoCodecFramesPerDatagram() {
        // 16-byte payload / 8-byte Codec2 3200 frame = 2 frames = 40 ms.
        XCTAssertEqual(M17StreamPayload.framesPerPacket, 2)
        XCTAssertEqual(
            M17StreamPacket.payloadByteCount,
            M17StreamPayload.framesPerPacket * StubCodec().bytesPerFrame)
        XCTAssertEqual(
            M17StreamPayload.samplesPerPacket,
            M17StreamPayload.framesPerPacket * StubCodec().samplesPerFrame)
        XCTAssertEqual(M17StreamPayload.millisecondsPerPacket, 40)
        XCTAssertEqual(M17StreamPayload.millisecondsPerCodecFrame, 20)
    }

    func testPayloadSplitsIntoTwoFramesInOrder() throws {
        let payload = Data((0..<16).map(UInt8.init))
        let frames = try M17StreamPayload.split(payload, bytesPerCodecFrame: 8)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], Array(0..<8).map(UInt8.init))
        XCTAssertEqual(frames[1], Array(8..<16).map(UInt8.init))
    }

    func testPayloadJoinIsTheInverseOfSplit() throws {
        let payload = Data((0..<16).map { UInt8($0 &* 11 % 251) })
        let frames = try M17StreamPayload.split(payload, bytesPerCodecFrame: 8)
        XCTAssertEqual(try M17StreamPayload.join(frames, bytesPerCodecFrame: 8), payload)
    }

    func testAPayloadThatIsNotWholeCodecFramesIsRefused() {
        // 16 bytes is not two whole 7-byte frames.
        XCTAssertThrowsError(
            try M17StreamPayload.split(Data(repeating: 0, count: 16), bytesPerCodecFrame: 7))
        XCTAssertThrowsError(
            try M17StreamPayload.split(Data(repeating: 0, count: 15), bytesPerCodecFrame: 8))
        XCTAssertThrowsError(
            try M17StreamPayload.split(Data(repeating: 0, count: 16), bytesPerCodecFrame: 0))
    }

    // MARK: - Frame numbering

    func testFrameNumberExpanderCountsStraightThroughWhenNothingWraps() {
        var expander = M17FrameNumberExpander()
        for sequence in UInt16(0)..<100 {
            XCTAssertEqual(expander.expand(sequence), UInt32(sequence))
        }
    }

    func testTheLastFrameFlagIsNotPartOfTheSequence() {
        var expander = M17FrameNumberExpander()
        _ = expander.expand(0)
        // FN 1 with the last-frame flag set must expand to 1, not to 32769.
        XCTAssertEqual(expander.expand(1 | M17StreamPacket.lastFrameFlag), 1)
    }

    func testFrameNumberExpanderCarriesAcrossTheFifteenBitWrap() {
        var expander = M17FrameNumberExpander()
        XCTAssertEqual(expander.expand(0x7FFE), 0x7FFE)
        XCTAssertEqual(expander.expand(0x7FFF), 0x7FFF)
        // 0x7FFF -> 0 is a wrap, not a 21-minute jump backwards.
        XCTAssertEqual(expander.expand(0x0000), 0x8000)
        XCTAssertEqual(expander.expand(0x0001), 0x8001)
    }

    func testASmallStepBackwardsIsAReorderNotAWrap() {
        var expander = M17FrameNumberExpander()
        _ = expander.expand(10)
        // A frame arriving out of order must not advance the epoch.
        XCTAssertEqual(expander.expand(9), 9)
        XCTAssertEqual(expander.expand(11), 11)
    }

    func testResetReturnsTheExpanderToTheStartOfAnOver() {
        var expander = M17FrameNumberExpander()
        _ = expander.expand(0x7FFF)
        _ = expander.expand(0x0000)
        expander.reset()
        XCTAssertEqual(expander.expand(0x0005), 5)
    }

    // MARK: - Transmit

    func testFrameNumbersCountFromZeroAndTheCRCIsValid() throws {
        var tx = try transmitter()
        let payload = Data(repeating: 0xA5, count: 16)

        for expected in UInt16(0)..<5 {
            let packet = try tx.next(payload: payload)
            XCTAssertEqual(packet.frameNumber, expected)
            XCTAssertEqual(packet.sequenceNumber, expected)
            XCTAssertFalse(packet.isLastFrame)
            XCTAssertTrue(packet.isCRCValid, "TX must produce a datagram that checks")
        }
    }

    func testLSFFieldsAreConstantAcrossTheOver() throws {
        var tx = try transmitter(streamID: 0xBEEF)
        let payload = Data(repeating: 0x11, count: 16)

        let first = try tx.next(payload: payload)
        let second = try tx.next(payload: payload)

        // "consistent from frame to frame within a stream".
        XCTAssertEqual(first.streamID, 0xBEEF)
        XCTAssertEqual(second.streamID, first.streamID)
        XCTAssertEqual(second.destination, first.destination)
        XCTAssertEqual(second.source, first.source)
        XCTAssertEqual(second.type, first.type)
        XCTAssertEqual(second.metadata, first.metadata)
    }

    func testTheLastFrameFlagEndsTheStream() throws {
        var tx = try transmitter()
        let payload = Data(repeating: 0x22, count: 16)

        _ = try tx.next(payload: payload)
        let last = try tx.next(payload: payload, isLast: true)

        XCTAssertTrue(last.isLastFrame)
        XCTAssertEqual(last.sequenceNumber, 1)
        XCTAssertEqual(last.frameNumber, 1 | M17StreamPacket.lastFrameFlag)
        XCTAssertTrue(tx.isFinished)
        XCTAssertThrowsError(try tx.next(payload: payload)) { error in
            XCTAssertEqual(error as? M17StreamTransmitError, .streamAlreadyEnded)
        }
    }

    func testResetStartsANewOverWithANewStreamID() throws {
        var tx = try transmitter(streamID: 0x0001)
        let payload = Data(repeating: 0x33, count: 16)
        _ = try tx.next(payload: payload, isLast: true)

        tx.reset(streamID: 0x0002)
        XCTAssertFalse(tx.isFinished)
        let first = try tx.next(payload: payload)
        XCTAssertEqual(first.streamID, 0x0002)
        XCTAssertEqual(first.sequenceNumber, 0, "a new over counts from zero again")
    }

    func testTheSequenceCounterWrapsWithoutColidingWithTheLastFrameFlag() throws {
        var tx = try transmitter()
        let payload = Data(repeating: 0x44, count: 16)

        // Walk the counter to the top of its 15-bit range.
        for _ in 0..<0x7FFF { _ = try tx.next(payload: payload) }
        let atTop = try tx.next(payload: payload)
        XCTAssertEqual(atTop.sequenceNumber, 0x7FFF)
        XCTAssertFalse(atTop.isLastFrame, "the counter must never set the flag by itself")

        let wrapped = try tx.next(payload: payload)
        XCTAssertEqual(wrapped.sequenceNumber, 0)
        XCTAssertFalse(wrapped.isLastFrame)
    }

    func testEncodingPCMProducesTheTwoCodecFramesInOrder() throws {
        var tx = try transmitter()
        let codec = StubCodec()
        // Two halves distinguishable from each other.
        let pcm = (0..<320).map { Int16($0 < 160 ? 1 : 2) }

        let packet = try tx.next(pcm: pcm, using: codec)

        XCTAssertEqual(packet.payload.count, 16)
        let frames = try M17StreamPayload.split(packet.payload, bytesPerCodecFrame: 8)
        XCTAssertEqual(frames[0], [UInt8](repeating: 1, count: 8))
        XCTAssertEqual(frames[1], [UInt8](repeating: 2, count: 8))
        XCTAssertTrue(packet.isCRCValid)
    }

    func testEncodingRefusesAnythingButExactlyFortyMillisecondsOfAudio() throws {
        var tx = try transmitter()
        let codec = StubCodec()
        for count in [0, 160, 319, 321, 640] {
            XCTAssertThrowsError(
                try tx.next(pcm: [Int16](repeating: 0, count: count), using: codec),
                "\(count) samples is not one datagram")
        }
    }
}
