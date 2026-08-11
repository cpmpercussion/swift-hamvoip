// SPDX-License-Identifier: Apache-2.0

#if CODEC2

import Foundation
import RadioCore
import XCTest

@testable import M17Kit

/// Tests for the real Codec2 3200 binding (M17-4).
///
/// Compiled only when `Codec2.xcframework` has been built — see the note at
/// the top of `Package.swift`. Everything else in the M17 stream path is
/// tested against `StubCodec` and runs everywhere, including CI.
///
/// These deliberately do **not** assert bit-exact codec output. Pinning
/// codec2's bits would be asserting that a specific upstream build produces
/// specific bytes, which tells us nothing about our code and breaks on any
/// upstream bump. What matters here is the contract M17-4 depends on: the
/// frame geometry, and that audio survives a round trip well enough to be
/// recognisable.
final class Codec2VoiceCodecTests: XCTestCase {

    /// 20 ms of a 440 Hz tone at 8 kHz — something a speech codec can carry.
    private func tone(samples: Int, frequency: Double = 440, amplitude: Double = 8000)
        -> [Int16]
    {
        (0..<samples).map { index in
            Int16(amplitude * sin(2 * .pi * frequency * Double(index) / 8000))
        }
    }

    private func rootMeanSquare(_ pcm: [Int16]) -> Double {
        guard !pcm.isEmpty else { return 0 }
        let total = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (total / Double(pcm.count)).squareRoot()
    }

    // MARK: - Geometry

    /// The arithmetic the whole M17 stream layout rests on: 160 samples in,
    /// 8 bytes out, so a 16-byte payload is exactly two frames of 20 ms.
    func testFrameGeometryIsWhatTheStreamLayoutAssumes() throws {
        let codec = try Codec2VoiceCodec()

        XCTAssertEqual(codec.samplesPerFrame, 160)
        XCTAssertEqual(codec.bytesPerFrame, 8)
        XCTAssertEqual(
            codec.bytesPerFrame * M17StreamPayload.framesPerPacket,
            M17StreamPacket.payloadByteCount)
        XCTAssertEqual(
            codec.samplesPerFrame * M17StreamPayload.framesPerPacket,
            M17StreamPayload.samplesPerPacket)
    }

    // MARK: - Round trip

    func testEncodeProducesOneFrameAndDecodeReturnsOneFrameOfSamples() throws {
        let codec = try Codec2VoiceCodec()
        let frame = try codec.encode(tone(samples: codec.samplesPerFrame))

        XCTAssertEqual(frame.count, codec.bytesPerFrame)
        XCTAssertEqual(try codec.decode(frame).count, codec.samplesPerFrame)
    }

    func testAToneSurvivesTheRoundTripWithItsEnergyRoughlyIntact() throws {
        let codec = try Codec2VoiceCodec()
        let input = tone(samples: codec.samplesPerFrame)

        // Codec2 is a vocoder with internal state, so the first frame or two
        // out of a cold codec are not representative. Run a short warm-up and
        // measure after it.
        var output: [Int16] = []
        for _ in 0..<10 {
            output = try codec.decode(try codec.encode(input))
        }

        let inputRMS = rootMeanSquare(input)
        let outputRMS = rootMeanSquare(output)
        XCTAssertGreaterThan(inputRMS, 0, "premise: the input is not silence")
        XCTAssertGreaterThan(outputRMS, inputRMS * 0.25, "the tone should survive, roughly")
        XCTAssertLessThan(outputRMS, inputRMS * 4.0, "and not be wildly amplified")
    }

    func testSilenceInIsNearSilenceOut() throws {
        let codec = try Codec2VoiceCodec()
        let silence = [Int16](repeating: 0, count: codec.samplesPerFrame)

        var output: [Int16] = []
        for _ in 0..<10 {
            output = try codec.decode(try codec.encode(silence))
        }
        XCTAssertLessThan(rootMeanSquare(output), 500, "silence must not decode to noise")
    }

    func testDistinctAudioProducesDistinctFrames() throws {
        let codec = try Codec2VoiceCodec()
        let low = try codec.encode(tone(samples: codec.samplesPerFrame, frequency: 300))
        let high = try codec.encode(tone(samples: codec.samplesPerFrame, frequency: 1800))
        XCTAssertNotEqual(low, high, "two very different tones should not encode identically")
    }

    // MARK: - Refusals

    func testEncodeRefusesAnythingButExactlyOneFrame() throws {
        let codec = try Codec2VoiceCodec()
        for count in [0, 159, 161, 320] {
            XCTAssertThrowsError(try codec.encode([Int16](repeating: 0, count: count))) { error in
                XCTAssertEqual(
                    error as? Codec2Error, .wrongSampleCount(expected: 160, actual: count))
            }
        }
    }

    func testDecodeRefusesAnythingButExactlyOneFrame() throws {
        let codec = try Codec2VoiceCodec()
        for count in [0, 7, 9, 16] {
            XCTAssertThrowsError(try codec.decode([UInt8](repeating: 0, count: count))) { error in
                XCTAssertEqual(
                    error as? Codec2Error, .wrongFrameSize(expected: 8, actual: count))
            }
        }
    }

    // MARK: - Through the stream path

    /// The real codec driving the real sequencing: an over goes out through
    /// `M17StreamTransmitter` and comes back as recognisable audio through
    /// `M17StreamReceiver`. No socket (AU-5).
    func testAnOverRoundTripsThroughTransmitterAndReceiverWithTheRealCodec() throws {
        let codec = try Codec2VoiceCodec()
        var tx = M17StreamTransmitter(
            streamID: 0x4242,
            destination: try M17Address(callsign: "VK1XYZ"),
            source: try M17Address(callsign: "VK2DEF"))
        var rx = M17StreamReceiver(codec: codec)

        let speechLike = tone(samples: M17StreamPayload.samplesPerPacket, frequency: 700)
        let overLength = 25   // one second

        for index in 0..<overLength {
            let packet = try tx.next(
                pcm: speechLike, using: codec, isLast: index == overLength - 1)
            XCTAssertEqual(packet.data.count, M17StreamPacket.byteCount)
            XCTAssertTrue(packet.isCRCValid)
            _ = rx.receive(packet)
        }

        var audioTicks = 0
        var energy = 0.0
        for _ in 0..<(overLength * M17StreamPayload.framesPerPacket) {
            let playout = rx.pop()
            if playout.kind == .audio {
                audioTicks += 1
                energy += rootMeanSquare(playout.pcm)
            }
        }

        XCTAssertGreaterThan(audioTicks, overLength, "most of the over should play as audio")
        XCTAssertGreaterThan(
            energy / Double(audioTicks), 100,
            "the decoded over should carry real signal, not silence")
    }
}

#endif
