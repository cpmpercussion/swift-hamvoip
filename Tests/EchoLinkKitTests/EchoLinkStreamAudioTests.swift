// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import RadioCore
import TestSupport

/// EL-7 — the synthesised playout clock, and packets through a real
/// `JitterBuffer`.
final class EchoLinkStreamAudioTests: XCTestCase {
    private func audioPackets(_ name: String) throws -> [EchoLinkRTPPacket] {
        try FixtureLoader.datagrams(name, in: Bundle.module)
            .map { try EchoLinkRTPPacket.parse(EchoLinkProxyFrame.parse($0).frame.payload) }
    }

    private let step = EchoLinkSequenceExpander.packetMilliseconds


    /// Pops until `count` real frames have come out, or the buffer has clearly
    /// stopped producing them.
    ///
    /// `.concealment` and `.silence` are slots, not frames — the buffer emits
    /// them while priming and across gaps — so they are stepped over rather
    /// than failed on. The bound is what stops a regression hanging the suite.
    private func drain(_ buffer: inout JitterBuffer, expecting count: Int) -> [[UInt8]] {
        var played: [[UInt8]] = []
        for _ in 0 ..< (count * 8 + 64) where played.count < count {
            if case .frame(let payload) = buffer.pop() {
                played.append(payload)
            }
        }
        return played
    }

    // MARK: - Signed delta: the thing that makes a wrap a non-event

    func testSignedDeltaTreatsAWrapAsASingleStep() {
        XCTAssertEqual(EchoLinkSequenceExpander.signedDelta(from: 65535, to: 0), 1)
        XCTAssertEqual(EchoLinkSequenceExpander.signedDelta(from: 65534, to: 1), 3)
        XCTAssertEqual(EchoLinkSequenceExpander.signedDelta(from: 0, to: 65535), -1)
        XCTAssertEqual(EchoLinkSequenceExpander.signedDelta(from: 10, to: 11), 1)
        XCTAssertEqual(EchoLinkSequenceExpander.signedDelta(from: 11, to: 10), -1)
    }

    // MARK: - An arbitrary origin

    func testFirstPacketLatchesWhateverOriginItHas() {
        // Ours start at 0; observed inbound streams began at 2126 and 4013.
        for origin in [UInt16(0), 2126, 4013, 23_460, 65_535] {
            var expander = EchoLinkSequenceExpander()
            let first = expander.expand(origin)
            let second = expander.expand(origin &+ 1)

            XCTAssertTrue(first.isNewTalkspurt, "the first packet always starts a talkspurt")
            XCTAssertEqual(second.streamTime, first.streamTime + step,
                           "origin \(origin): the second packet is one packet later")
            XCTAssertFalse(second.isNewTalkspurt)
        }
    }

    func testStreamTimeAdvancesEightyMillisecondsPerPacket() {
        var expander = EchoLinkSequenceExpander()
        let base = expander.expand(5000).streamTime
        for offset in 1 ... 10 {
            let expansion = expander.expand(UInt16(5000 + offset))
            XCTAssertEqual(expansion.streamTime, base + UInt32(offset) * step)
        }
    }

    // MARK: - The 16-bit wrap

    func testWrapIsNotADiscontinuity() {
        var expander = EchoLinkSequenceExpander()
        var last = expander.expand(65_530).streamTime

        for sequence in [UInt16(65_531), 65_532, 65_533, 65_534, 65_535, 0, 1, 2, 3] {
            let expansion = expander.expand(sequence)
            XCTAssertFalse(expansion.isNewTalkspurt,
                           "sequence \(sequence) across the wrap must not read as a new talkspurt")
            XCTAssertEqual(expansion.streamTime, last + step,
                           "the clock must keep advancing across the wrap")
            last = expansion.streamTime
        }
    }

    // MARK: - Reordering

    func testALatePacketExpandsToWhereItBelongs() {
        var expander = EchoLinkSequenceExpander()
        _ = expander.expand(100)
        let at102 = expander.expand(102).streamTime
        // 101 arrives after 102 — the ordinary reordering case.
        let at101 = expander.expand(101)

        XCTAssertEqual(at101.streamTime, at102 - step,
                       "a late packet belongs before the one that overtook it")
        XCTAssertFalse(at101.isNewTalkspurt)

        // And the reference did not move backwards: the next in-order packet
        // must still read as one step on from 102.
        let at103 = expander.expand(103)
        XCTAssertEqual(at103.streamTime, at102 + step,
                       "a late arrival must not drag the reference backwards")
    }

    func testAReorderedPacketBeforeTheOriginHasRoom() {
        // The origin is arbitrary, so the first packet seen is not necessarily
        // the earliest sent. Without headroom below it, an earlier arrival has
        // nowhere to go but a clamp, and duplicate timestamps are worse than a
        // late frame.
        var expander = EchoLinkSequenceExpander()
        let first = expander.expand(1000)
        let earlier = expander.expand(998)

        XCTAssertGreaterThan(first.streamTime, 0, "the origin must sit above zero")
        XCTAssertEqual(earlier.streamTime, first.streamTime - 2 * step)
    }

    // MARK: - Talkspurt boundaries — the common case

    func testTheCapturedTalkspurtBoundaryIsDetected() throws {
        // The fixture is cut to span one: sequence 146..151 (the tail of
        // ECHOTEST's welcome) then 0..7 (our own audio echoed back).
        let packets = try audioPackets("live-proxy-audio-in.hex")
        var expander = EchoLinkSequenceExpander()

        var boundaries: [Int] = []
        var streamTimes: [UInt32] = []
        for (index, packet) in packets.enumerated() {
            let expansion = expander.expand(packet.header.sequenceNumber)
            if expansion.isNewTalkspurt { boundaries.append(index) }
            streamTimes.append(expansion.streamTime)
        }

        XCTAssertEqual(boundaries, [0, 6],
                       "the first packet, and the 151 -> 0 boundary at index 6")

        // And the clock never goes backwards across it, which is the point.
        XCTAssertEqual(streamTimes, streamTimes.sorted(),
                       "the synthesised clock must be monotonic across a talkspurt")
        for (earlier, later) in zip(streamTimes, streamTimes.dropFirst()) {
            XCTAssertEqual(later, earlier + step,
                           "and continue smoothly rather than jumping")
        }
    }

    func testASequenceThatJumpsBackwardsFarStartsANewTalkspurt() {
        var expander = EchoLinkSequenceExpander()
        _ = expander.expand(151)
        let next = expander.expand(0)

        XCTAssertTrue(next.isNewTalkspurt, "151 -> 0 is a new over, not reordering")
    }

    func testAHugeForwardJumpStartsANewTalkspurt() {
        // Calling a 20-second forward jump "loss" would insert 20 s of silence
        // into the playout clock and stall the buffer.
        var expander = EchoLinkSequenceExpander()
        let first = expander.expand(100)
        let jumped = expander.expand(100 + 1000)

        XCTAssertTrue(jumped.isNewTalkspurt)
        XCTAssertEqual(jumped.streamTime, first.streamTime + step,
                       "a new talkspurt continues from the highest time emitted")
    }

    func testModestLossStaysWithinTheTalkspurt() {
        // Real packet loss must keep its timing, so the buffer conceals a gap
        // rather than treating it as a new transmission.
        var expander = EchoLinkSequenceExpander()
        let first = expander.expand(200)
        let after = expander.expand(205)

        XCTAssertFalse(after.isNewTalkspurt)
        XCTAssertEqual(after.streamTime, first.streamTime + 5 * step,
                       "five packets' worth of time really did pass")
    }

    func testResetForgetsTheOrigin() {
        var expander = EchoLinkSequenceExpander()
        _ = expander.expand(5000)
        expander.reset()
        XCTAssertTrue(expander.expand(9).isNewTalkspurt)
    }

    // MARK: - Packets to timed frames

    func testOnePacketBecomesFourFramesTwentyMillisecondsApart() throws {
        let packet = try audioPackets("live-proxy-audio-in.hex")[0]
        var audio = EchoLinkStreamAudio()
        let reception = audio.receive(packet)

        XCTAssertEqual(reception.frames.count, 4)
        XCTAssertTrue(reception.isNewTalkspurt)

        let base = reception.frames[0].timestamp
        XCTAssertEqual(reception.frames.map(\.timestamp),
                       [base, base + 20, base + 40, base + 60])
        XCTAssertEqual(reception.frames.map { $0.payload.count }, [33, 33, 33, 33])
        XCTAssertEqual(reception.frames.map(\.payload), packet.codecFrames)
    }

    func testConsecutivePacketsProduceAContiguousFrameClock() throws {
        let packets = try audioPackets("live-proxy-audio-out.hex")
        var audio = EchoLinkStreamAudio()

        var timestamps: [UInt32] = []
        for packet in packets {
            timestamps.append(contentsOf: audio.receive(packet).frames.map(\.timestamp))
        }

        XCTAssertEqual(timestamps.count, 32, "8 packets x 4 frames")
        for (earlier, later) in zip(timestamps, timestamps.dropFirst()) {
            XCTAssertEqual(later, earlier + 20,
                           "20 ms per frame, with no seam between packets")
        }
    }

    func testStationInfoDoesNotProduceFrames() {
        var audio = EchoLinkStreamAudio()
        XCTAssertNil(audio.receive(payload: Data("oNDATA*ECHOTEST*\r".utf8)),
                     "text must never be handed to the codec as speech")
    }

    func testRawAudioPayloadProducesFrames() throws {
        let payload = try FixtureLoader
            .datagrams("live-proxy-audio-in.hex", in: Bundle.module)
            .map { try EchoLinkProxyFrame.parse($0).frame.payload }[0]

        var audio = EchoLinkStreamAudio()
        XCTAssertEqual(audio.receive(payload: payload)?.frames.count, 4)
    }

    // MARK: - Through a real JitterBuffer

    func testCapturedPacketsPlayOutInOrderThroughAJitterBuffer() throws {
        // The end-to-end claim of EL-7: what a real peer sent, expanded by the
        // synthesised clock, plays back in the order it was spoken.
        let packets = try audioPackets("live-proxy-audio-in.hex")
        var audio = EchoLinkStreamAudio()
        var buffer = JitterBuffer(frameDuration: .milliseconds(20))

        var pushed: [[UInt8]] = []
        for packet in packets {
            for frame in audio.receive(packet).frames {
                pushed.append(frame.payload)
                buffer.push(frame)
            }
        }

        let played = drain(&buffer, expecting: pushed.count)
        XCTAssertEqual(played, pushed,
                       "every captured codec frame must play back, in the order it was sent")
    }

    func testReorderedArrivalsPlayBackInTheOrderTheyWereSent() throws {
        let packets = try audioPackets("live-proxy-audio-out.hex")
        var audio = EchoLinkStreamAudio()
        var buffer = JitterBuffer(frameDuration: .milliseconds(20))

        // Deliver 0,1,2,3,4,5,6,7 as 0,2,1,3,5,4,6,7 — pairwise swaps, the
        // shape real reordering takes.
        let order = [0, 2, 1, 3, 5, 4, 6, 7]
        let expected = packets.flatMap(\.codecFrames)

        for index in order {
            for frame in audio.receive(packets[index]).frames {
                buffer.push(frame)
            }
        }

        let played = drain(&buffer, expecting: expected.count)
        XCTAssertEqual(played, expected, "the buffer must undo the reordering")
    }

    // MARK: - Transmit

    func testTransmitterEmitsAPacketEveryFourFrames() {
        var transmitter = EchoLinkStreamTransmitter()
        let frame = [UInt8](repeating: 0xD2, count: 33)

        XCTAssertNil(transmitter.push(frame))
        XCTAssertNil(transmitter.push(frame))
        XCTAssertNil(transmitter.push(frame))
        let packet = transmitter.push(frame)

        XCTAssertEqual(packet?.codecFrames.count, 4)
        XCTAssertEqual(packet?.header.sequenceNumber, 0)
        XCTAssertEqual(packet?.encoded.count, EchoLinkRTPPacket.observedPacketSize)
    }

    func testTransmitterEmitsWhatWasObserved() {
        var transmitter = EchoLinkStreamTransmitter()
        let frame = [UInt8](repeating: 0x00, count: 33)
        for _ in 0 ..< 3 { _ = transmitter.push(frame) }
        let packet = transmitter.push(frame)!

        XCTAssertEqual(packet.header.version, 3, "3, as every observed sender sends")
        XCTAssertEqual(packet.header.timestamp, 0, "always zero, as observed")
        XCTAssertEqual(packet.header.synchronisationSource, 0)
        XCTAssertEqual(packet.header.payloadType, 3)
        XCTAssertTrue(packet.header.isObservedShape)
    }

    func testSequenceNumbersIncrementAndWrap() {
        var transmitter = EchoLinkStreamTransmitter(initialSequenceNumber: 65_534)
        let frame = [UInt8](repeating: 0, count: 33)

        var sequences: [UInt16] = []
        for _ in 0 ..< 12 {
            if let packet = transmitter.push(frame) {
                sequences.append(packet.header.sequenceNumber)
            }
        }
        XCTAssertEqual(sequences, [65_534, 65_535, 0])
    }

    func testFlushEmitsAShortPacketRatherThanClippingTheOver() {
        // Holding three frames for a fourth that never comes would clip the
        // last 60 ms of every transmission.
        var transmitter = EchoLinkStreamTransmitter()
        let frame = [UInt8](repeating: 0x7F, count: 33)
        _ = transmitter.push(frame)
        _ = transmitter.push(frame)

        let packet = transmitter.flush()
        XCTAssertEqual(packet?.codecFrames.count, 2)
        XCTAssertEqual(packet?.duration, .milliseconds(40))
        XCTAssertNil(transmitter.flush(), "and nothing is left behind")
    }

    func testTransmittedPacketsSurviveOurOwnParser() throws {
        var transmitter = EchoLinkStreamTransmitter()
        let frame = [UInt8](repeating: 0x3C, count: 33)
        for _ in 0 ..< 3 { _ = transmitter.push(frame) }
        let packet = transmitter.push(frame)!

        XCTAssertEqual(try EchoLinkRTPPacket.parse(packet.encoded), packet)
    }
}
