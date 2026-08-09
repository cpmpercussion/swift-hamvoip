// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import TestSupport
import XCTest

@testable import IAX2Kit

/// IAX-6: the voice path (RFC 5456 §8.1.2, §6.10, §8.7).
///
/// Nothing here touches a socket or the wall clock (AU-5): the pure types are
/// driven frame by frame, and the one integration test runs on `MockTransport`
/// and `ManualTestClock`.
final class IAX2VoiceStreamTests: XCTestCase {

    /// The peer's 15-bit source call number in every fixture in this file.
    private let peerCallNumber: UInt16 = 0x0042
    /// Ours. `IAX2CallNumberAllocator` hands out 1 first, deterministically.
    private let localCallNumber: UInt16 = 1

    private let samplesPerFrame = 160

    // MARK: - 16 -> 32 bit expansion (§8.1.2, notes §11)

    /// One expansion case: the reference the receiver holds, the 16-bit field
    /// that arrived, and the exact 32-bit value it must reconstruct to.
    private struct ExpansionCase {
        let reference: UInt32
        let short: UInt16
        let expected: UInt32?
        let what: String
    }

    func testMiniTimestampExpansionTable() {
        let cases: [ExpansionCase] = [
            // --- Ordinary forward progress, nowhere near a boundary --------
            .init(reference: 0, short: 0x0000, expected: 0, what: "the very first frame"),
            .init(reference: 0, short: 0x0014, expected: 20, what: "one 20 ms step from zero"),
            .init(reference: 20, short: 0x0028, expected: 40, what: "a second 20 ms step"),
            .init(
                reference: 0x0002_3456, short: 0x3456, expected: 0x0002_3456,
                what: "a frame whose low half already matches the reference"),
            .init(
                reference: 0x0000_7FFF, short: 0x8000, expected: 0x0000_8000,
                what: "crossing the 0x8000 resync point is not a wrap and changes nothing"),

            // --- Forward across the 16-bit wrap ---------------------------
            .init(
                reference: 0x0000_FFF0, short: 0x0005, expected: 0x0001_0005,
                what: "the low half wrapped: the high half must carry"),
            .init(
                reference: 0x0000_FFFF, short: 0x0000, expected: 0x0001_0000,
                what: "the exact wrap, one millisecond over"),
            .init(
                reference: 0x0001_FFFF, short: 0x0000, expected: 0x0002_0000,
                what: "the second wrap carries just the same"),

            // --- Backward across the wrap: the case that matters ----------
            // A frame from just *before* the boundary, arriving just *after*
            // the reference crossed it. Naively carrying the current high half
            // forward lands it at 0x0001FFF0 — exactly +65536 ms — which is
            // the mis-expansion that used to wedge the jitter buffer.
            .init(
                reference: 0x0001_0005, short: 0xFFF0, expected: 0x0000_FFF0,
                what: "a late frame from before the boundary must NOT jump +65536 ms"),
            .init(
                reference: 0x0001_0000, short: 0xFFFF, expected: 0x0000_FFFF,
                what: "one millisecond behind the boundary, from the far side"),
            .init(
                reference: 0x0002_0000, short: 0xFF00, expected: 0x0001_FF00,
                what: "256 ms behind the second boundary"),

            // --- The half-epoch tie, in both directions -------------------
            // At exactly ±32768 ms the signed distance is -32768, never
            // +32768, so the reconstruction resolves backwards. One
            // millisecond either side flips it. This is the only place the
            // rule has to choose, and it chooses the same way every time.
            .init(
                reference: 0x0001_0000, short: 0x8000, expected: 0x0000_8000,
                what: "exactly half an epoch away resolves backwards"),
            .init(
                reference: 0x0001_0000, short: 0x8001, expected: 0x0000_8001,
                what: "one millisecond nearer, still backwards"),
            .init(
                reference: 0x0001_0000, short: 0x7FFF, expected: 0x0001_7FFF,
                what: "the largest forward distance, +32767 ms"),
            .init(
                reference: 0x0000_8001, short: 0x0000, expected: 0x0001_0000,
                what: "32769 ms forward is nearer the next epoch than this one"),
            .init(
                reference: 0x0000_8000, short: 0x0000, expected: 0x0000_0000,
                what: "32768 ms back to the origin, exactly on the tie"),

            // --- Large but genuine gaps -----------------------------------
            .init(
                reference: 0x0001_0000, short: 0x7000, expected: 0x0001_7000,
                what: "a genuine 28.672 s gap — silence, or a burst of loss"),
            .init(
                reference: 0x0000_0014, short: 0x7FF0, expected: 0x0000_7FF0,
                what: "a 32.7 s gap from near the origin"),
            .init(
                reference: 0x0001_8000, short: 0xFFFF, expected: 0x0001_FFFF,
                what: "the largest representable gap, +32767 ms, landing on the wrap itself"),
            .init(
                reference: 0x0001_7FFF, short: 0xFFFF, expected: 0x0000_FFFF,
                what: "one millisecond more is not a forward gap at all — the tie goes backwards, "
                    + "which is why §6.10 demands a full frame every 0x8000 ms"),

            // --- High in the 32-bit clock (§8.1.1's field is 32 bits) ------
            .init(
                reference: 0x1234_FFF0, short: 0x0005, expected: 0x1235_0005,
                what: "the same wrap 3.4 hours into a call"),
            .init(
                reference: 0x1235_0005, short: 0xFFF0, expected: 0x1234_FFF0,
                what: "and the same late frame, 3.4 hours in"),

            // --- Before the call's zero origin (§6.2.2) --------------------
            .init(
                reference: 10, short: 0xFFFF, expected: nil,
                what: "1 ms before a call that began at zero cannot be right"),
            .init(
                reference: 0, short: 0x8000, expected: nil,
                what: "half an epoch before the origin is refused, not wrapped to 49 days"),
            .init(
                reference: 10, short: 0x0009, expected: 9,
                what: "1 ms behind the reference but still after the origin is fine"),
        ]

        for testCase in cases {
            let actual = IAX2MiniTimestamp.expand(testCase.short, near: testCase.reference)
            XCTAssertEqual(
                actual, testCase.expected,
                "reference 0x\(hex32(testCase.reference)), mini 0x\(hex16(testCase.short)): "
                    + testCase.what)
        }
    }

    /// Truncation is the exact inverse of expansion for every step of a real
    /// 20 ms grid walked across two wrap boundaries.
    func testTruncateThenExpandRoundTripsAcrossTwoWraps() {
        var reference: UInt32 = 0x0000_FE00
        var timestamp: UInt32 = 0x0000_FE00
        var steps = 0
        while timestamp < 0x0002_0200 {
            let short = IAX2MiniTimestamp.truncate(timestamp)
            XCTAssertEqual(UInt32(short), timestamp & 0xFFFF, "truncation is the low 16 bits")
            guard let expanded = IAX2MiniTimestamp.expand(short, near: reference) else {
                XCTFail("expansion refused a legitimate time-stamp \(timestamp)")
                return
            }
            XCTAssertEqual(expanded, timestamp, "round trip at \(timestamp)")
            reference = expanded
            timestamp += 20
            steps += 1
        }
        // 0x0000FE00 … 0x00020200 spans both the 0x10000 and the 0x20000 wrap.
        XCTAssertEqual(steps, 3_328, "the sweep really did cross two wraps")
    }

    /// The same sweep, but every frame is expanded against a reference three
    /// frames *ahead* of it — network reordering, which is exactly when a
    /// boundary bites.
    func testExpansionIsExactWhenFramesArriveBehindTheReference() {
        var timestamp: UInt32 = 0x0000_FF00
        while timestamp < 0x0001_0100 {
            let reference = timestamp + 60  // three 20 ms frames ahead
            let expanded = IAX2MiniTimestamp.expand(
                IAX2MiniTimestamp.truncate(timestamp), near: reference)
            XCTAssertEqual(expanded, timestamp, "reordered frame at \(timestamp)")
            timestamp += 20
        }
    }

    func testExpanderAdvancesReferenceForwardOnly() {
        var expander = IAX2MiniTimestampExpander()
        XCTAssertEqual(expander.reference, 0)

        XCTAssertEqual(expander.expand(0x0014), 20)
        XCTAssertEqual(expander.reference, 20)
        XCTAssertEqual(expander.expand(0x0050), 80)
        XCTAssertEqual(expander.reference, 80)

        // A late frame is expanded correctly but must not drag the reference
        // back: the next frames are expanded against the newest value seen.
        XCTAssertEqual(expander.expand(0x003C), 60)
        XCTAssertEqual(expander.reference, 80, "a late frame does not rewind the reference")
    }

    func testExpanderCarriesTheReferenceAcrossAWrap() {
        var expander = IAX2MiniTimestampExpander(reference: 0x0000_FFC4)
        XCTAssertEqual(expander.expand(0xFFD8), 0x0000_FFD8)
        XCTAssertEqual(expander.expand(0xFFEC), 0x0000_FFEC)
        XCTAssertEqual(expander.expand(0x0000), 0x0001_0000)
        XCTAssertEqual(expander.reference, 0x0001_0000)
        // Now the late one from the far side of the boundary.
        XCTAssertEqual(expander.expand(0xFFF8), 0x0000_FFF8)
        XCTAssertEqual(expander.reference, 0x0001_0000, "still the newest")
        XCTAssertEqual(expander.expand(0x0014), 0x0001_0014)
    }

    func testResynchroniseReplacesTheReferenceOutright() {
        var expander = IAX2MiniTimestampExpander(reference: 0x0001_0000)
        expander.resynchronise(to: 0x0009_0000)
        XCTAssertEqual(expander.reference, 0x0009_0000)
        // Which is what makes a gap longer than half an epoch recoverable —
        // the reason §6.10 demands a full frame every 0x8000 ms.
        XCTAssertEqual(expander.expand(0x0014), 0x0009_0014)
        expander.reset()
        XCTAssertEqual(expander.reference, 0)
    }

    // MARK: - Outbound frame choice (§8.1.2, §6.10)

    func testFirstVoiceFrameIsFullAndTheRestAreMini() throws {
        var transmitter = IAX2VoiceTransmitter()
        XCTAssertTrue(transmitter.willSendFull)

        let first = try transmitter.next(timestamp: 0, payload: [0x01])
        guard case .full(let subclass, let timestamp, let payload) = first else {
            return XCTFail("the first voice frame of a stream must be full (§8.1.2, §6.9.3)")
        }
        XCTAssertEqual(subclass.rawByte, 0x82, "C = 1, field 2 => 1 << 2 = µ-law (§8.7)")
        XCTAssertEqual(timestamp, 0)
        XCTAssertEqual(payload, [0x01])
        XCTAssertFalse(transmitter.willSendFull)

        for step in 1...20 {
            let stamp = UInt32(step * 20)
            let frame = try transmitter.next(timestamp: stamp, payload: [UInt8(step)])
            XCTAssertEqual(
                frame, .mini(timestamp: UInt16(stamp), payload: [UInt8(step)]),
                "frame \(step) should be a Mini Frame")
        }
    }

    /// §6.10 (32,768 ms, MUST) and §8.1.2 (65,536 ms, SHOULD) disagree; we
    /// resync at every 0x8000 crossing, which satisfies both. Walk four
    /// boundaries and assert a full frame at each and nowhere else.
    func testFullFrameIsRegeneratedAtEveryResyncBoundary() throws {
        var transmitter = IAX2VoiceTransmitter()
        var fullFrameTimestamps: [UInt32] = []

        var timestamp: UInt32 = 0
        while timestamp <= 0x0002_0100 {
            let frame = try transmitter.next(timestamp: timestamp, payload: [])
            if case .full(_, let stamp, _) = frame { fullFrameTimestamps.append(stamp) }
            timestamp += 20
        }

        // 20 ms frames never land exactly on a multiple of 0x8000, so the full
        // frame is the first one *after* each boundary — 32768 = 20 × 1638.4,
        // so 0x8000 falls between 32760 and 32780.
        XCTAssertEqual(
            fullFrameTimestamps,
            [0, 32_780, 65_540, 98_320, 131_080],
            "one full frame at the start and one just past each 0x8000 boundary")

        for stamp in fullFrameTimestamps.dropFirst() {
            XCTAssertEqual(
                stamp / IAX2VoiceTransmitter.resyncInterval,
                (stamp - 20) / IAX2VoiceTransmitter.resyncInterval + 1,
                "\(stamp) is the first frame of its 0x8000 epoch")
        }
        // Every 16-bit wrap (0x10000, 0x20000) is also a 0x8000 multiple, so
        // §8.1.2's SHOULD is covered by obeying §6.10's MUST.
        XCTAssertTrue(fullFrameTimestamps.contains(65_540), "the 0x10000 wrap is covered")
        XCTAssertTrue(fullFrameTimestamps.contains(131_080), "the 0x20000 wrap is covered")
    }

    /// A sender whose framing happens to divide 32,768 lands exactly on the
    /// boundary; the same rule must fire there too.
    func testFullFrameWhenTheTimestampLandsExactlyOnTheBoundary() throws {
        var transmitter = IAX2VoiceTransmitter()
        _ = try transmitter.next(timestamp: 0x7FF0, payload: [])  // first: full
        let onBoundary = try transmitter.next(timestamp: 0x8000, payload: [])
        XCTAssertTrue(onBoundary.isFull, "a time-stamp that IS a multiple of 0x8000 (§6.10)")
        let after = try transmitter.next(timestamp: 0x8010, payload: [])
        XCTAssertFalse(after.isFull)
    }

    func testFormatChangeForcesAFullFrameCarryingTheNewSubclass() throws {
        var transmitter = IAX2VoiceTransmitter()
        _ = try transmitter.next(timestamp: 0, payload: [])
        _ = try transmitter.next(timestamp: 20, payload: [])

        transmitter.setFormat(.gsmFullRate)
        XCTAssertTrue(transmitter.willSendFull)
        let frame = try transmitter.next(timestamp: 40, payload: [])
        guard case .full(let subclass, _, _) = frame else {
            return XCTFail("on-the-fly codec negotiation is a full voice frame (§8.1.2)")
        }
        XCTAssertEqual(subclass.rawByte, 0x81, "C = 1, field 1 => 1 << 1 = GSM (§8.7)")

        // Setting the same format again changes nothing.
        transmitter.setFormat(.gsmFullRate)
        XCTAssertFalse(transmitter.willSendFull)
        XCTAssertFalse(try transmitter.next(timestamp: 60, payload: []).isFull)
    }

    func testResetSendsAFullFrameAgain() throws {
        var transmitter = IAX2VoiceTransmitter()
        _ = try transmitter.next(timestamp: 0, payload: [])
        XCTAssertFalse(try transmitter.next(timestamp: 20, payload: []).isFull)
        transmitter.reset()
        XCTAssertTrue(try transmitter.next(timestamp: 40, payload: []).isFull)
    }

    func testUnrepresentableFormatThrows() {
        var transmitter = IAX2VoiceTransmitter(format: [.g711MuLaw, .gsmFullRate])
        XCTAssertThrowsError(try transmitter.next(timestamp: 0, payload: [])) { error in
            XCTAssertEqual(
                error as? IAX2VoiceError,
                .formatNotRepresentable([.g711MuLaw, .gsmFullRate]),
                "a subclass names exactly one codec (§8.1.1, §8.6.8)")
        }
    }

    // MARK: - Inbound: the fixture stream

    func testFixtureStreamPlaysOutInOrderAndDecodesToTheExpectedPCM() throws {
        let datagrams = try FixtureLoader.datagrams("voice-mulaw-stream.hex", in: Bundle.module)
        XCTAssertEqual(datagrams.count, 8, "one full Voice frame and seven Mini Frames")

        var receiver = makeReceiver()
        var timestamps: [UInt32] = []
        for datagram in datagrams {
            let frame = try IAX2Frame.parse(datagram)
            guard case .queued(let timestamp) = receiver.receive(frame) else {
                return XCTFail("every frame in the fixture is playable audio")
            }
            timestamps.append(timestamp)
        }
        XCTAssertEqual(timestamps, [20, 40, 60, 80, 100, 120, 140, 160])

        // Every octet of fixture frame k is 0xFF - k, and µ-law decodes those
        // to a ramp: 0xFF is the code for PCM zero (RC-2), and each step down
        // is one quantisation interval of the finest segment.
        let expectedLevels: [Int16] = [0, 8, 16, 24, 32, 40, 48, 56]
        for (index, level) in expectedLevels.enumerated() {
            let playout = receiver.pop()
            XCTAssertEqual(playout.kind, .audio, "frame \(index)")
            XCTAssertEqual(playout.pcm.count, samplesPerFrame, "frame \(index)")
            XCTAssertEqual(
                playout.pcm, [Int16](repeating: level, count: samplesPerFrame),
                "frame \(index) decodes to a constant \(level)")
            XCTAssertEqual(
                G711MuLawCodec.decodeSample(UInt8(0xFF - index)), level,
                "and that level is what G.711 says the octet means")
        }

        // Drained: the buffer starves, un-primes, and plays silence.
        let afterwards = receiver.pop()
        XCTAssertEqual(afterwards.kind, .silence)
        XCTAssertEqual(afterwards.pcm, [Int16](repeating: 0, count: samplesPerFrame))
    }

    /// The wrap fixture, delivered deliberately out of order across the
    /// boundary. If expansion were naive the two frames from before the wrap
    /// would land 65,536 ms in the future and the stream would collapse.
    func testWrapFixtureSurvivesReorderingAcrossTheBoundary() throws {
        let datagrams = try FixtureLoader.datagrams("voice-mulaw-wrap.hex", in: Bundle.module)
        XCTAssertEqual(datagrams.count, 7)

        var receiver = makeReceiver()
        // The full Voice frame first: it pins µ-law and anchors the reference.
        guard case .queued(let anchor) = receiver.receive(try IAX2Frame.parse(datagrams[0])) else {
            return XCTFail("the full Voice frame should queue")
        }
        XCTAssertEqual(anchor, 0x0000_FFB0)

        // Mini frames 1…6 in the scrambled arrival order 1, 4, 3, 2, 5, 6 —
        // so 0x0000 (65536, past the wrap) arrives before 0xffec and 0xffd8
        // (65516 and 65496, before it).
        var queued: [UInt32] = []
        for index in [1, 4, 3, 2, 5, 6] {
            guard case .queued(let timestamp) = receiver.receive(
                try IAX2Frame.parse(datagrams[index]))
            else {
                return XCTFail("mini frame \(index) should queue")
            }
            queued.append(timestamp)
        }
        XCTAssertEqual(
            queued, [65_476, 65_536, 65_516, 65_496, 65_556, 65_576],
            "each frame expands to its own true 32-bit time-stamp, arrival order or not")

        // And the jitter buffer replays them in time-stamp order regardless.
        let expectedLevels: [Int16] = [0, 8, 16, 24, 32, 40, 48]
        for (index, level) in expectedLevels.enumerated() {
            let playout = receiver.pop()
            XCTAssertEqual(playout.kind, .audio, "slot \(index)")
            XCTAssertEqual(
                playout.pcm, [Int16](repeating: level, count: samplesPerFrame),
                "slot \(index) plays the frame whose time-stamp comes next")
        }
    }

    // MARK: - Inbound: loss, reordering, starvation

    func testASingleLostFrameIsConcealedByRepeatingTheLastOne() throws {
        let frames = try fixtureFrames("voice-mulaw-stream.hex")
        var receiver = makeReceiver()
        // Drop the frame at 60 ms (index 2).
        for (index, frame) in frames.enumerated() where index != 2 {
            _ = receiver.receive(frame)
        }

        XCTAssertEqual(receiver.pop().pcm, level(0))  // 20 ms
        XCTAssertEqual(receiver.pop().pcm, level(8))  // 40 ms

        let concealed = receiver.pop()  // 60 ms: never arrived
        XCTAssertEqual(concealed.kind, .concealment)
        XCTAssertEqual(
            concealed.pcm, level(8),
            "the first concealed slot repeats the last decoded frame at full gain")

        let resumed = receiver.pop()  // 80 ms
        XCTAssertEqual(resumed.kind, .audio)
        XCTAssertEqual(resumed.pcm, level(24))
    }

    func testAConcealmentRunFadesByHalfEachSlot() throws {
        let frames = try fixtureFrames("voice-mulaw-stream.hex")
        var receiver = makeReceiver()
        // Drop 60, 80 and 100 ms (indices 2, 3, 4).
        for (index, frame) in frames.enumerated() where ![2, 3, 4].contains(index) {
            _ = receiver.receive(frame)
        }

        XCTAssertEqual(receiver.pop().pcm, level(0))
        XCTAssertEqual(receiver.pop().pcm, level(8))

        // -0 dB, -6 dB, -12 dB: an arithmetic right shift per slot, so the
        // output is exact and reproducible with no floating point.
        for (slot, expected) in [Int16(8), 4, 2].enumerated() {
            let concealed = receiver.pop()
            XCTAssertEqual(concealed.kind, .concealment, "concealed slot \(slot)")
            XCTAssertEqual(concealed.pcm, level(expected), "concealed slot \(slot)")
        }

        let resumed = receiver.pop()
        XCTAssertEqual(resumed.kind, .audio)
        XCTAssertEqual(resumed.pcm, level(40), "the 120 ms frame")
    }

    func testStarvationAndPrimingPlaySilenceOfTheRightLength() throws {
        var receiver = makeReceiver()

        // Not primed: 60 ms of target depth needs three 20 ms frames.
        for _ in 0..<3 {
            let playout = receiver.pop()
            XCTAssertEqual(playout.kind, .silence)
            XCTAssertEqual(playout.pcm, [Int16](repeating: 0, count: samplesPerFrame))
        }

        let frames = try fixtureFrames("voice-mulaw-stream.hex")
        for frame in frames.prefix(3) { _ = receiver.receive(frame) }
        XCTAssertTrue(receiver.isPrimed || receiver.queuedFrameCount == 3)

        XCTAssertEqual(receiver.pop().kind, .audio)
        XCTAssertEqual(receiver.pop().kind, .audio)
        XCTAssertEqual(receiver.pop().kind, .audio)

        // Starved again.
        let starved = receiver.pop()
        XCTAssertEqual(starved.kind, .silence)
        XCTAssertEqual(starved.pcm, [Int16](repeating: 0, count: samplesPerFrame))
    }

    func testSilenceClearsTheConcealmentMemory() throws {
        let frames = try fixtureFrames("voice-mulaw-stream.hex")
        var receiver = makeReceiver()
        for frame in frames.prefix(3) { _ = receiver.receive(frame) }
        for _ in 0..<3 { _ = receiver.pop() }
        XCTAssertEqual(receiver.pop().kind, .silence, "starved")

        // A new spurt, far enough ahead that the buffer re-anchors rather than
        // concealing its way across. It must start from real audio, not fade in
        // from the frame that ended the last spurt.
        for frame in frames.suffix(3) { _ = receiver.receive(frame) }
        var sawAudio = false
        for _ in 0..<6 {
            let playout = receiver.pop()
            XCTAssertNotEqual(
                playout.kind, .concealment,
                "the gap between spurts is silence, never a fade of stale audio")
            if playout.kind == .audio { sawAudio = true; break }
        }
        XCTAssertTrue(sawAudio, "the new spurt should play")
    }

    func testDuplicateAndLateFramesAreDroppedByTheBuffer() throws {
        let frames = try fixtureFrames("voice-mulaw-stream.hex")
        var receiver = makeReceiver()
        for frame in frames.prefix(4) { _ = receiver.receive(frame) }
        // A duplicate of the 40 ms frame.
        _ = receiver.receive(frames[1])
        XCTAssertEqual(receiver.queuedFrameCount, 4, "the duplicate is dropped, first copy kept")

        XCTAssertEqual(receiver.pop().pcm, level(0))
        XCTAssertEqual(receiver.pop().pcm, level(8))
        // Now the 20 ms frame arrives again: its slot has already played.
        _ = receiver.receive(frames[0])
        XCTAssertEqual(receiver.pop().pcm, level(16), "a late frame does not displace the grid")
    }

    // MARK: - Inbound: what is refused, and why

    func testMiniFrameBeforeTheCodecIsPinnedIsRejected() {
        var receiver = makeReceiver()
        let mini = IAX2Frame.mini(
            IAX2MiniFrame(sourceCallNumber: peerCallNumber, timestamp: 0x0014, payload: payload(0)))
        XCTAssertEqual(receiver.receive(mini), .rejected(.codecNotPinned))
        XCTAssertNil(receiver.format)

        // §8.1.2: the codec may equally be pinned by the initial negotiation,
        // i.e. the FORMAT IE of the ACCEPT (§6.2.3).
        receiver.pinFormat(.g711MuLaw)
        XCTAssertEqual(receiver.receive(mini), .queued(timestamp: 20))
    }

    func testFullVoiceFrameWithAnUndecodableCodecIsRejectedButStillResyncs() {
        var receiver = makeReceiver()
        let frame = IAX2Frame.full(
            IAX2FullFrame(
                sourceCallNumber: peerCallNumber,
                destinationCallNumber: localCallNumber,
                timestamp: 0x0001_0000,
                oSeqno: 2, iSeqno: 1,
                type: .voice,
                subclass: IAX2Subclass(mediaFormat: MediaFormat.gsmFullRate.rawValue)!,
                payload: payload(0)))
        XCTAssertEqual(
            receiver.receive(frame),
            .rejected(.unsupportedFormat(MediaFormat.gsmFullRate.rawValue)))
        XCTAssertEqual(receiver.format, .gsmFullRate, "the pin is still recorded")
        XCTAssertEqual(
            receiver.expandedTimestamp, 0x0001_0000,
            "and the 32-bit anchor is still taken — it is the peer's own clock (§8.1.1)")

        // Mini frames of that stream are then refused for the right reason.
        let mini = IAX2Frame.mini(
            IAX2MiniFrame(sourceCallNumber: peerCallNumber, timestamp: 0x0014, payload: payload(0)))
        XCTAssertEqual(
            receiver.receive(mini), .rejected(.unsupportedFormat(MediaFormat.gsmFullRate.rawValue)))
    }

    /// A live ASL3 node sent a 44-octet payload — the tail of a playback —
    /// and the receiver dropped it as malformed. It is not malformed: µ-law is
    /// sample-wise (§8.7), so 44 octets is 5.5 ms of real audio.
    func testAShortPayloadIsPlayedRatherThanDropped() {
        var receiver = makeReceiver()
        receiver.pinFormat(.g711MuLaw)
        let short = IAX2Frame.mini(
            IAX2MiniFrame(
                sourceCallNumber: peerCallNumber, timestamp: 0x0014,
                payload: [UInt8](repeating: 0x00, count: 44)))
        XCTAssertEqual(receiver.receive(short), .queued(timestamp: 20))
        XCTAssertEqual(receiver.queuedFrameCount, 1, "the audio in it is kept, not discarded")
    }

    /// The audio that was actually sent must survive; only the padding is
    /// invented, and it has to be silence rather than whatever was in memory.
    func testAShortPayloadKeepsItsAudioAndPadsTheRestWithSilence() throws {
        var receiver = makeReceiver()
        receiver.pinFormat(.g711MuLaw)
        // 0x00 is µ-law's most-negative code; 0xFF is its code for PCM zero.
        // So the real audio is unmistakable and the padding is unmistakable.
        _ = receiver.receive(
            IAX2Frame.mini(
                IAX2MiniFrame(
                    sourceCallNumber: peerCallNumber, timestamp: 0x0014,
                    payload: [UInt8](repeating: 0x00, count: 44))))
        // Two more slots, only so the jitter buffer primes and plays.
        for timestamp in [UInt16(0x0028), UInt16(0x003c)] {
            _ = receiver.receive(
                IAX2Frame.mini(
                    IAX2MiniFrame(
                        sourceCallNumber: peerCallNumber, timestamp: timestamp,
                        payload: [UInt8](repeating: 0xFF, count: 160))))
        }

        var first: IAX2VoicePlayout?
        for _ in 0..<16 where first == nil {
            let playout = receiver.pop()
            if playout.kind == .audio { first = playout }
        }
        let pcm = try XCTUnwrap(first?.pcm, "the short frame should have played")

        XCTAssertEqual(pcm.count, 160, "the playout contract is still exactly one slot")
        XCTAssertTrue(pcm.prefix(44).allSatisfy { $0 != 0 }, "the real audio survived")
        XCTAssertTrue(pcm.dropFirst(44).allSatisfy { $0 == 0 }, "the padding is silence")
    }

    /// The mirror case: a peer batching more than a slot's worth must not have
    /// the excess thrown away.
    func testAnOverLongPayloadIsSplitAcrossConsecutiveSlots() {
        var receiver = makeReceiver()
        receiver.pinFormat(.g711MuLaw)
        let twoAndAHalf = IAX2Frame.mini(
            IAX2MiniFrame(
                sourceCallNumber: peerCallNumber, timestamp: 0x0014,
                payload: [UInt8](repeating: 0xFF, count: 400)))
        XCTAssertEqual(receiver.receive(twoAndAHalf), .queued(timestamp: 20))
        XCTAssertEqual(receiver.queuedFrameCount, 3, "160 + 160 + 80-padded-to-160")
    }

    /// No audio in it at all is the one case with nothing to salvage.
    func testAnEmptyPayloadIsRejected() {
        var receiver = makeReceiver()
        receiver.pinFormat(.g711MuLaw)
        let empty = IAX2Frame.mini(
            IAX2MiniFrame(sourceCallNumber: peerCallNumber, timestamp: 0x0014, payload: []))
        XCTAssertEqual(receiver.receive(empty), .rejected(.emptyPayload))
        XCTAssertEqual(receiver.queuedFrameCount, 0)
    }

    /// The ordinary case must not have regressed into the padding path.
    func testAnExactlySizedPayloadIsStillOneUntouchedSlot() {
        var receiver = makeReceiver()
        receiver.pinFormat(.g711MuLaw)
        let exact = IAX2Frame.mini(
            IAX2MiniFrame(
                sourceCallNumber: peerCallNumber, timestamp: 0x0014,
                payload: [UInt8](repeating: 0xFF, count: 160)))
        XCTAssertEqual(receiver.receive(exact), .queued(timestamp: 20))
        XCTAssertEqual(receiver.queuedFrameCount, 1)
    }

    func testTimestampBeforeTheCallOriginIsRejected() {
        var receiver = makeReceiver()
        receiver.pinFormat(.g711MuLaw)
        let mini = IAX2Frame.mini(
            IAX2MiniFrame(sourceCallNumber: peerCallNumber, timestamp: 0xFFFF, payload: payload(0)))
        XCTAssertEqual(
            receiver.receive(mini), .rejected(.timestampPrecedesCallOrigin(0xFFFF)),
            "expanding modulo 2^32 would place it ~49 days out (§6.2.2)")
        XCTAssertEqual(receiver.queuedFrameCount, 0)
    }

    func testComfortNoiseAndVideoCarryNoPlayableAudio() {
        var receiver = makeReceiver()
        let comfortNoise = IAX2Frame.full(
            IAX2FullFrame(
                sourceCallNumber: peerCallNumber,
                destinationCallNumber: localCallNumber,
                timestamp: 0x0000_4000,
                oSeqno: 3, iSeqno: 1,
                type: .comfortNoise,
                subclass: IAX2Subclass.literal(30)))  // level in -dBov (§8.2.10)
        XCTAssertEqual(receiver.receive(comfortNoise), .rejected(.notAudio))
        XCTAssertEqual(
            receiver.expandedTimestamp, 0x0000_4000,
            "comfort noise is still the peer's own media clock, so it may re-anchor")

        let video = IAX2Frame.full(
            IAX2FullFrame(
                sourceCallNumber: peerCallNumber,
                destinationCallNumber: localCallNumber,
                timestamp: 0x0000_5000,
                oSeqno: 4, iSeqno: 1,
                type: .video,
                subclass: IAX2Subclass(mediaFormat: MediaFormat.h264.rawValue)!,
                payload: [0x00]))
        XCTAssertEqual(receiver.receive(video), .rejected(.notAudio))
        XCTAssertEqual(receiver.expandedTimestamp, 0x0000_4000, "and video does not")
    }

    func testReceiverResetReturnsToTheOpeningState() throws {
        let frames = try fixtureFrames("voice-mulaw-stream.hex")
        var receiver = makeReceiver()
        for frame in frames { _ = receiver.receive(frame) }
        XCTAssertEqual(receiver.queuedFrameCount, 8)

        receiver.reset()
        XCTAssertEqual(receiver.queuedFrameCount, 0)
        XCTAssertNil(receiver.format)
        XCTAssertEqual(receiver.expandedTimestamp, 0)
        XCTAssertEqual(receiver.pop().kind, .silence)
    }

    // MARK: - End to end over a call

    /// The §9.6 shape on the wire: a full Voice frame pinning µ-law, then Mini
    /// Frames, then another full Voice frame at the resync boundary.
    func testTransmitPutsAFullVoiceFrameThenMiniFramesOnTheWire() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)
        harness.transport.clearSent()

        // PCM zero encodes to 0xFF in µ-law (RC-2), so every payload here is
        // 160 octets of 0xFF — the same shape as the inbound fixtures.
        let silence = [Int16](repeating: 0, count: samplesPerFrame)
        let expectedPayload = [UInt8](repeating: 0xFF, count: 160)

        let first = try await stream.send(pcm: silence, timestamp: 0)
        XCTAssertTrue(first.isFull, "the first voice frame of a call is full (§8.1.2)")
        let second = try await stream.send(pcm: silence, timestamp: 20)
        let third = try await stream.send(pcm: silence, timestamp: 40)
        XCTAssertFalse(second.isFull)
        XCTAssertFalse(third.isFull)
        // Straight past the first 0x8000 boundary.
        let resync = try await stream.send(pcm: silence, timestamp: 0x8004)
        XCTAssertTrue(resync.isFull, "§6.10 MUST, and §8.1.2's SHOULD along with it")

        let sent = harness.transport.sent
        XCTAssertEqual(sent.count, 4)

        // Frame 1: full Voice, OSeqno 1 (the NEW was 0 and ACKs do not
        // advance the counter, §7), ISeqno 2 (ACCEPT then ANSWER), µ-law.
        assertBytes(
            sent[0], hex("8001 0042 00000000 01 02 02 82") + Data(expectedPayload),
            "the full Voice frame that pins the codec")
        // Frames 2 and 3: Mini Frames — 4 octets of header and nothing else.
        assertBytes(sent[1], hex("0001 0014") + Data(expectedPayload), "mini frame at 20 ms")
        assertBytes(sent[2], hex("0001 0028") + Data(expectedPayload), "mini frame at 40 ms")
        // Frame 4: the resync full frame, OSeqno 2 — the mini frames in
        // between carry no sequence numbers at all (§8.1.2, §7).
        assertBytes(
            sent[3], hex("8001 0042 00008004 02 02 02 82") + Data(expectedPayload),
            "the resync full Voice frame")

        await harness.call.close()
    }

    func testInboundMediaEventsFlowThroughTheStreamToPCM() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)

        // The ACCEPT's FORMAT IE pins the codec in both directions (§6.2.3).
        let negotiated = await stream.handle(.accepted(format: .g711MuLaw))
        XCTAssertEqual(negotiated, .formatNegotiated(.g711MuLaw))
        let inbound = await stream.inboundFormat
        XCTAssertEqual(inbound, .g711MuLaw)

        for frame in try fixtureFrames("voice-mulaw-stream.hex") {
            let event = await stream.handle(.media(frame))
            guard case .audioQueued = event else {
                return XCTFail("every fixture frame should queue, got \(String(describing: event))")
            }
        }

        for (index, level) in [Int16(0), 8, 16, 24, 32, 40, 48, 56].enumerated() {
            let playout = await stream.pop()
            XCTAssertEqual(playout.kind, .audio, "slot \(index)")
            XCTAssertEqual(playout.pcm, self.level(level), "slot \(index)")
        }

        await harness.call.close()
    }

    func testSendingPCMForANonMuLawStreamThrowsRatherThanSendingNoise() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)
        await stream.setOutboundFormat(.gsmFullRate)
        harness.transport.clearSent()

        do {
            _ = try await stream.send(pcm: [Int16](repeating: 0, count: samplesPerFrame))
            XCTFail("µ-law is the only codec this client encodes")
        } catch let error as IAX2VoiceError {
            XCTAssertEqual(error, .unsupportedFormat(.gsmFullRate))
        }
        XCTAssertEqual(harness.transport.sentCount, 0, "and nothing went on the wire")

        await harness.call.close()
    }

    func testWrongPCMLengthThrows() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)
        harness.transport.clearSent()

        do {
            _ = try await stream.send(pcm: [Int16](repeating: 0, count: 80))
            XCTFail("a µ-law frame is 160 samples")
        } catch let error as G711Error {
            XCTAssertEqual(error, .wrongFrameLength(expected: 160, got: 80))
        }
        XCTAssertEqual(harness.transport.sentCount, 0)

        await harness.call.close()
    }

    /// A send refused because the leg is not ready must not consume the
    /// full-frame slot: otherwise the codec pin the peer needs is lost for the
    /// whole 0x8000 epoch.
    func testARefusedSendDoesNotConsumeTheFullFrameSlot() async throws {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let allocator = IAX2CallNumberAllocator()
        let call = try await IAX2Call.outbound(
            allocator: allocator, request: IAX2CallRequest(calledNumber: "55553"),
            transport: transport, clock: clock)
        let stream = IAX2VoiceStream(call: call)

        do {
            _ = try await stream.send(
                pcm: [Int16](repeating: 0, count: samplesPerFrame), timestamp: 0)
            XCTFail("media before the call is established must be refused")
        } catch let error as IAX2CallError {
            XCTAssertEqual(error, .notEstablished(state: .idle))
        }
        let stillOwesAFullFrame = await stream.willSendFullFrame
        XCTAssertTrue(stillOwesAFullFrame, "the codec pin is still owed to the peer")

        await call.close()
        transport.finish()
    }

    // MARK: - Helpers

    private func makeReceiver() -> IAX2VoiceReceiver {
        IAX2VoiceReceiver(
            buffer: JitterBuffer(frameDuration: .milliseconds(20), targetDepth: .milliseconds(60)))
    }

    private func fixtureFrames(_ name: String) throws -> [IAX2Frame] {
        try FixtureLoader.datagrams(name, in: Bundle.module).map { try IAX2Frame.parse($0) }
    }

    /// 160 octets, every one of them `0xFF - index` — the fixture payload rule.
    private func payload(_ index: Int) -> [UInt8] {
        [UInt8](repeating: UInt8(0xFF - index), count: 160)
    }

    /// A whole frame of one constant PCM level.
    private func level(_ value: Int16) -> [Int16] {
        [Int16](repeating: value, count: samplesPerFrame)
    }

    private func hex32(_ value: UInt32) -> String { String(format: "%08x", value) }
    private func hex16(_ value: UInt16) -> String { String(format: "%04x", value) }

    private func hex(_ string: String) -> Data {
        let characters = string.filter { !$0.isWhitespace }
        precondition(characters.count % 2 == 0, "odd-length hex literal in a test")
        var bytes: [UInt8] = []
        var index = characters.startIndex
        while index < characters.endIndex {
            let next = characters.index(index, offsetBy: 2)
            guard let byte = UInt8(characters[index..<next], radix: 16) else {
                preconditionFailure("bad hex literal in a test: \(string)")
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private func assertBytes(
        _ actual: Data,
        _ expected: Data,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.map { String(format: "%02x", $0) }.joined(),
            expected.map { String(format: "%02x", $0) }.joined(),
            what, file: file, line: line)
    }

    // MARK: - A call driven to `up`, on MockTransport and a manual clock

    private struct Harness {
        let call: IAX2Call
        let transport: MockTransport
        let clock: ManualTestClock
    }

    /// NEW → ACCEPT → ACK → ANSWER → ACK, exactly the §9.6 flow, leaving the
    /// call `up` with OSeqno 1 and ISeqno 2.
    private func makeUpCall() async throws -> Harness {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let allocator = IAX2CallNumberAllocator()
        let call = try await IAX2Call.outbound(
            allocator: allocator,
            request: IAX2CallRequest(calledNumber: "55553", username: "n0call"),
            transport: transport,
            clock: clock)
        XCTAssertEqual(call.sourceCallNumber, localCallNumber)

        try await call.start()

        let accept = IAX2Frame.full(
            IAX2FullFrame(
                sourceCallNumber: peerCallNumber,
                destinationCallNumber: localCallNumber,
                timestamp: 0,
                oSeqno: 0, iSeqno: 1,
                type: .iax,
                subclass: IAX2Subclass(.accept),
                payload: try InformationElement.serialize([.format(.g711MuLaw)])))
        transport.inject(accept.encoded())

        let answer = IAX2Frame.full(
            IAX2FullFrame(
                sourceCallNumber: peerCallNumber,
                destinationCallNumber: localCallNumber,
                timestamp: 0,
                oSeqno: 1, iSeqno: 1,
                type: .control,
                subclass: IAX2Subclass(.answer)))
        transport.inject(answer.encoded())

        for _ in 0..<100_000 {
            if await call.state == .up { break }
            await Task.yield()
        }
        let state = await call.state
        XCTAssertEqual(state, .up, "the fixture flow should bring the call up")

        return Harness(call: call, transport: transport, clock: clock)
    }
}
