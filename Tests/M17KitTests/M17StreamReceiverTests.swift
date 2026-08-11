// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import XCTest

@testable import M17Kit

/// Tests for `M17StreamReceiver` (M17-4).
///
/// Uses `StubCodec` from `M17StreamAudioTests` — see the note there. Nothing
/// in the receive path is codec-specific, so these run with or without
/// `Codec2.xcframework`.
final class M17StreamReceiverTests: XCTestCase {

    private let codec = StubCodec()

    private func transmitter(streamID: UInt16 = 0x1234) throws -> M17StreamTransmitter {
        M17StreamTransmitter(
            streamID: streamID,
            destination: try M17Address(callsign: "VK1XYZ"),
            source: try M17Address(callsign: "VK2DEF"))
    }

    /// 40 ms of PCM whose two halves both carry `value`, so a decoded frame is
    /// identifiable by its first sample.
    private func pcm(_ value: Int16) -> [Int16] {
        [Int16](repeating: value, count: M17StreamPayload.samplesPerPacket)
    }

    private func receiver() -> M17StreamReceiver {
        M17StreamReceiver(codec: codec)
    }

    // MARK: - Acceptance

    func testTheFirstDatagramStartsAnOver() throws {
        var tx = try transmitter(streamID: 0xABCD)
        var rx = receiver()

        let reception = rx.receive(try tx.next(pcm: pcm(1), using: codec))

        guard case .acceptedNewStream(let streamID, let source) = reception else {
            return XCTFail("expected a new stream, got \(reception)")
        }
        XCTAssertEqual(streamID, 0xABCD)
        XCTAssertEqual(source.callsign, "VK2DEF")
        XCTAssertEqual(rx.streamID, 0xABCD)
    }

    func testEachDatagramQueuesTwoTwentyMillisecondSlots() throws {
        var tx = try transmitter()
        var rx = receiver()

        XCTAssertEqual(rx.queuedFrameCount, 0)
        _ = rx.receive(try tx.next(pcm: pcm(1), using: codec))
        XCTAssertEqual(rx.queuedFrameCount, 2, "one datagram is two codec frames")
        _ = rx.receive(try tx.next(pcm: pcm(2), using: codec))
        XCTAssertEqual(rx.queuedFrameCount, 4)
    }

    func testTheLastFrameIsReportedAsSuch() throws {
        var tx = try transmitter()
        var rx = receiver()

        _ = rx.receive(try tx.next(pcm: pcm(1), using: codec))
        let last = rx.receive(try tx.next(pcm: pcm(2), using: codec, isLast: true))

        XCTAssertEqual(last, .acceptedFinalFrame)
        XCTAssertTrue(rx.hasSeenFinalFrame)
    }

    // MARK: - Refusal

    func testADatagramWhoseCRCFailsIsRefused() throws {
        var tx = try transmitter()
        var rx = receiver()
        let good = try tx.next(pcm: pcm(1), using: codec)

        // Corrupt a payload byte and re-parse, so the CRC no longer closes.
        var bytes = [UInt8](good.data)
        bytes[40] ^= 0xFF
        let corrupt = try M17StreamPacket.parse(Data(bytes))
        XCTAssertFalse(corrupt.isCRCValid, "premise")

        let reception = rx.receive(corrupt)
        guard case .rejected(.crcFailed) = reception else {
            return XCTFail("expected a CRC rejection, got \(reception)")
        }
        XCTAssertEqual(rx.queuedFrameCount, 0, "a corrupt datagram must not be queued")
    }

    func testAnEncryptedStreamIsNeverQueued() throws {
        var rx = receiver()
        // TYPE with a non-zero encryption subtype — FR-2.5, no key anywhere.
        let encrypted = try M17StreamPacket(
            streamID: 0x0001,
            destination: try M17Address(callsign: "VK1XYZ"),
            source: try M17Address(callsign: "VK2DEF"),
            type: M17StreamType(rawValue: 0x000D),
            metadata: Data(repeating: 0, count: 14),
            frameNumber: 0,
            payload: Data(repeating: 0x5A, count: 16))
        XCTAssertEqual(encrypted.playability, .encrypted, "premise")

        XCTAssertEqual(rx.receive(encrypted), .rejected(.encrypted))
        XCTAssertEqual(rx.queuedFrameCount, 0)
    }

    // MARK: - Play out

    func testAudioComesOutInOrderOneCodecFramePerTick() throws {
        var tx = try transmitter()
        var rx = receiver()

        // Four datagrams: eight 20 ms slots, comfortably past the 60 ms prime.
        for value in Int16(1)...4 {
            _ = rx.receive(try tx.next(pcm: pcm(value), using: codec))
        }

        // Both halves of datagram n decode to `n`, so the expected run is
        // 1,1,2,2,3,3,4,4.
        var heard: [Int16] = []
        for _ in 0..<8 {
            let playout = rx.pop()
            XCTAssertEqual(playout.kind, .audio)
            XCTAssertEqual(playout.pcm.count, codec.samplesPerFrame)
            heard.append(playout.pcm[0])
        }
        XCTAssertEqual(heard, [1, 1, 2, 2, 3, 3, 4, 4])
    }

    func testAMissingDatagramConcealsAsTwoOrdinaryGaps() throws {
        var tx = try transmitter()
        var rx = receiver()

        let first = try tx.next(pcm: pcm(1), using: codec)
        let dropped = try tx.next(pcm: pcm(2), using: codec)   // never delivered
        let third = try tx.next(pcm: pcm(3), using: codec)
        let fourth = try tx.next(pcm: pcm(4), using: codec)
        _ = dropped

        _ = rx.receive(first)
        _ = rx.receive(third)
        _ = rx.receive(fourth)

        var kinds: [M17StreamPlayout.Kind] = []
        for _ in 0..<6 { kinds.append(rx.pop().kind) }

        // The two slots of the lost datagram conceal individually — not one
        // double-length gap.
        XCTAssertEqual(kinds, [.audio, .audio, .concealment, .concealment, .audio, .audio])
    }

    func testALongGapFadesTheConcealmentAndThenGivesUpToSilence() throws {
        var tx = try transmitter()
        var rx = receiver()

        // Datagram 1 arrives, 2-4 are lost, 5 arrives. The six missing slots
        // are a 120 ms gap — short of the buffer's 200 ms discontinuity bound,
        // so they conceal rather than re-anchor.
        let first = try tx.next(pcm: pcm(1), using: codec)
        for value in Int16(2)...4 { _ = try tx.next(pcm: pcm(value), using: codec) }
        let fifth = try tx.next(pcm: pcm(5), using: codec)

        _ = rx.receive(first)
        _ = rx.receive(fifth)

        var kinds: [M17StreamPlayout.Kind] = []
        var concealmentMagnitudes: [Int] = []
        for _ in 0..<8 {
            let playout = rx.pop()
            kinds.append(playout.kind)
            if playout.kind == .concealment {
                concealmentMagnitudes.append(abs(Int(playout.pcm[0])))
            }
        }

        XCTAssertTrue(kinds.contains(.concealment), "a 120 ms gap should conceal")
        XCTAssertEqual(
            concealmentMagnitudes.count, M17StreamReceiver.maxConcealmentRun,
            "the run is bounded; past that it is silence, not a buzz")
        XCTAssertEqual(
            concealmentMagnitudes, concealmentMagnitudes.sorted(by: >),
            "each concealment must be quieter than the last")
        XCTAssertTrue(
            kinds.contains(.silence),
            "once the run is spent the receiver goes quiet rather than repeating")
    }

    /// Running dry is *not* concealment. The jitter buffer un-primes on
    /// starvation and emits silence, so the end of an over is quiet rather
    /// than a fading repeat of its last frame — which is what should happen
    /// when a station stops transmitting.
    func testStarvingAfterAnOverIsSilenceNotConcealment() throws {
        var tx = try transmitter()
        var rx = receiver()
        for value in Int16(1)...3 {
            _ = rx.receive(try tx.next(pcm: pcm(value), using: codec))
        }
        for _ in 0..<6 { _ = rx.pop() }

        for _ in 0..<5 {
            let playout = rx.pop()
            XCTAssertEqual(playout.kind, .silence)
            XCTAssertEqual(playout.pcm, [Int16](repeating: 0, count: codec.samplesPerFrame))
        }
    }

    // MARK: - Stream changes

    func testANewStreamIDAbandonsWhateverWasQueued() throws {
        var first = try transmitter(streamID: 0x1111)
        var rx = receiver()
        _ = rx.receive(try first.next(pcm: pcm(1), using: codec))
        _ = rx.receive(try first.next(pcm: pcm(2), using: codec))
        XCTAssertEqual(rx.queuedFrameCount, 4)

        var second = try transmitter(streamID: 0x2222)
        let reception = rx.receive(try second.next(pcm: pcm(9), using: codec))

        guard case .acceptedNewStream(let streamID, _) = reception else {
            return XCTFail("expected a new stream, got \(reception)")
        }
        XCTAssertEqual(streamID, 0x2222)
        XCTAssertEqual(
            rx.queuedFrameCount, 2,
            "the previous over's audio must not play across the join")
        XCTAssertEqual(rx.streamID, 0x2222)
    }

    func testResetReturnsTheReceiverToItsInitialState() throws {
        var tx = try transmitter()
        var rx = receiver()
        _ = rx.receive(try tx.next(pcm: pcm(1), using: codec, isLast: true))

        rx.reset()

        XCTAssertNil(rx.streamID)
        XCTAssertNil(rx.source)
        XCTAssertFalse(rx.hasSeenFinalFrame)
        XCTAssertEqual(rx.queuedFrameCount, 0)
        XCTAssertFalse(rx.isPrimed)
    }

    // MARK: - End to end

    func testAWholeOverSurvivesTransmitterToReceiver() throws {
        var tx = try transmitter(streamID: 0x4242)
        var rx = receiver()

        let overLength = 25   // one second at 40 ms a datagram
        for index in 0..<overLength {
            let packet = try tx.next(
                pcm: pcm(Int16(index + 1)),
                using: codec,
                isLast: index == overLength - 1)
            XCTAssertTrue(packet.isCRCValid)
            _ = rx.receive(packet)
        }
        XCTAssertTrue(rx.hasSeenFinalFrame)

        var heard: [Int16] = []
        for _ in 0..<(overLength * M17StreamPayload.framesPerPacket) {
            let playout = rx.pop()
            if playout.kind == .audio { heard.append(playout.pcm[0]) }
        }

        let expected = (1...overLength).flatMap { [Int16($0), Int16($0)] }
        XCTAssertEqual(heard, expected, "every frame of the over should arrive intact and in order")
    }
}
