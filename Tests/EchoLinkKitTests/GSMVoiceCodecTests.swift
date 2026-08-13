// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import RadioCore
import TestSupport

/// EL-8 — GSM 06.10 over vendored libgsm (FR-3.2, LP-4).
final class GSMVoiceCodecTests: XCTestCase {
    private func makeCodec() throws -> GSMVoiceCodec {
        try GSMVoiceCodec()
    }

    /// A 20 ms tone at `frequency`, which is what a voice codec is built to
    /// carry — unlike noise, which GSM has no obligation to reproduce.
    private func tone(frequency: Double, amplitude: Double = 8000, samples: Int = 160) -> [Int16] {
        (0 ..< samples).map { index in
            let phase = 2 * Double.pi * frequency * Double(index) / 8000
            return Int16(amplitude * sin(phase))
        }
    }

    /// The 0x05 payloads of the captured inbound audio.
    private func audioPayloads() throws -> [Data] {
        try FixtureLoader.datagrams("live-proxy-audio-in.hex", in: Bundle.module)
            .map { try EchoLinkProxyFrame.parse($0).frame.payload }
    }

    private func rms(_ pcm: [Int16]) -> Double {
        guard !pcm.isEmpty else { return 0 }
        let total = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (total / Double(pcm.count)).squareRoot()
    }

    // MARK: - Frame geometry

    func testFrameSizesAreTheOnesTheStackExpects() throws {
        let codec = try makeCodec()
        XCTAssertEqual(codec.bytesPerFrame, 33)
        XCTAssertEqual(codec.samplesPerFrame, 160, "160 samples at 8 kHz is exactly 20 ms")
        XCTAssertEqual(codec.bytesPerFrame, EchoLinkRTPPacket.gsmFrameSize,
                       "the codec and the packer must agree")
    }

    func testFourFramesFillAnObservedPacket() throws {
        let codec = try makeCodec()
        XCTAssertEqual(
            EchoLinkRTPHeader.size + codec.bytesPerFrame * 4,
            EchoLinkRTPPacket.observedPacketSize,
            "4 x 33 bytes plus the header is the 144 bytes every captured packet had"
        )
    }

    func testEncodeProducesExactlyOneFrame() throws {
        let codec = try makeCodec()
        XCTAssertEqual(try codec.encode(tone(frequency: 440)).count, 33)
    }

    func testDecodeProducesExactlyOneFrameOfSamples() throws {
        let codec = try makeCodec()
        let encoded = try codec.encode(tone(frequency: 440))
        XCTAssertEqual(try codec.decode(encoded).count, 160)
    }

    // MARK: - Round trip

    func testRoundTripPreservesEnergy() throws {
        // A lossy codec will not reproduce samples, so the claim under test is
        // that the signal survives, not that the bytes do.
        let codec = try makeCodec()
        let input = tone(frequency: 440)

        // Prime: GSM carries filter history across frames, so the very first
        // frame out of a fresh codec is not representative.
        for _ in 0 ..< 4 { _ = try codec.decode(try codec.encode(input)) }

        let output = try codec.decode(try codec.encode(input))
        let inputRMS = rms(input)
        let outputRMS = rms(output)

        XCTAssertGreaterThan(outputRMS, inputRMS * 0.5,
                             "the decoded frame must not be near-silent")
        XCTAssertLessThan(outputRMS, inputRMS * 2.0,
                          "nor wildly amplified")
    }

    func testSilenceStaysQuiet() throws {
        let codec = try makeCodec()
        let silence = [Int16](repeating: 0, count: 160)
        for _ in 0 ..< 4 { _ = try codec.decode(try codec.encode(silence)) }

        let output = try codec.decode(try codec.encode(silence))
        XCTAssertLessThan(rms(output), 50, "silence in, silence out")
    }

    func testASustainedToneSurvivesManyFrames() throws {
        // The real usage: a continuous stream, not one frame in isolation.
        let codec = try makeCodec()
        let input = tone(frequency: 300)

        var energies: [Double] = []
        for _ in 0 ..< 25 {  // half a second
            energies.append(rms(try codec.decode(try codec.encode(input))))
        }

        let settled = energies.dropFirst(4)
        XCTAssertTrue(settled.allSatisfy { $0 > rms(input) * 0.4 },
                      "energy must not decay across a sustained stream: \(energies)")
    }

    func testDifferentInputsProduceDifferentFrames() throws {
        let codec = try makeCodec()
        let quiet = try codec.encode(tone(frequency: 440, amplitude: 500))
        let loud = try codec.encode(tone(frequency: 440, amplitude: 12000))
        XCTAssertNotEqual(quiet, loud, "the codec must actually encode the input")
    }

    // MARK: - Directions are independent

    func testEncodeAndDecodeKeepSeparateState() throws {
        // Full duplex is the normal case. Sharing one libgsm handle would make
        // the decoder's filter history depend on what we were transmitting.
        let codec = try makeCodec()
        let input = tone(frequency: 440)

        let reference = try makeCodec()
        for _ in 0 ..< 3 { _ = try reference.encode(input) }
        let referenceFrame = try reference.encode(input)

        for _ in 0 ..< 3 {
            _ = try codec.encode(input)
            // Interleave decoding, which would corrupt a shared handle.
            _ = try codec.decode(referenceFrame)
        }
        let interleaved = try codec.encode(input)

        XCTAssertEqual(interleaved, referenceFrame,
                       "decoding must not disturb the encoder's history")
    }

    // MARK: - Errors

    func testWrongSampleCountIsATypedError() throws {
        let codec = try makeCodec()
        for count in [0, 159, 161, 320] {
            XCTAssertThrowsError(try codec.encode([Int16](repeating: 0, count: count))) { error in
                XCTAssertEqual(
                    error as? GSMVoiceCodecError,
                    .wrongSampleCount(expected: 160, actual: count)
                )
            }
        }
    }

    func testWrongFrameSizeIsATypedError() throws {
        let codec = try makeCodec()
        for count in [0, 32, 34, 66] {
            XCTAssertThrowsError(try codec.decode([UInt8](repeating: 0, count: count))) { error in
                XCTAssertEqual(
                    error as? GSMVoiceCodecError,
                    .wrongFrameSize(expected: 33, actual: count)
                )
            }
        }
    }

    func testACorruptFrameIsRejectedRatherThanPlayed() throws {
        // libgsm checks the magic nibble, so a rejection means these 33 bytes
        // are not GSM 06.10 at all — worth surfacing rather than playing.
        let codec = try makeCodec()
        let notGSM = [UInt8](repeating: 0x00, count: 33)

        XCTAssertThrowsError(try codec.decode(notGSM)) { error in
            XCTAssertEqual(error as? GSMVoiceCodecError, .corruptFrame)
        }
    }

    func testAValidFrameIsAccepted() throws {
        let codec = try makeCodec()
        let valid = try codec.encode(tone(frequency: 440))
        XCTAssertNoThrow(try codec.decode(valid))
        XCTAssertEqual(valid[0] >> 4, 0xD, "GSM_MAGIC, the nibble libgsm checks")
    }

    // MARK: - Against the captured audio

    func testCapturedFramesDecodeWithoutBeingRejected() throws {
        // The strongest available check short of listening: real GSM 06.10 off
        // the wire, from a peer that is not us, decoded by this codec.
        let codec = try makeCodec()
        let payloads = try audioPayloads()

        var decoded = 0
        for payload in payloads {
            let packet = try EchoLinkRTPPacket.parse(payload)
            for frame in packet.codecFrames {
                let pcm = try codec.decode(frame)
                XCTAssertEqual(pcm.count, 160)
                decoded += 1
            }
        }
        XCTAssertEqual(decoded, 56, "14 captured packets x 4 frames")
    }

    func testCapturedAudioIsNotSilent() throws {
        // If the frames were being decoded as garbage-but-valid, this is what
        // would catch it: real speech has energy.
        let codec = try makeCodec()
        let payloads = try audioPayloads()

        var loudest = 0.0
        for payload in payloads {
            for frame in try EchoLinkRTPPacket.parse(payload).codecFrames {
                loudest = max(loudest, rms(try codec.decode(frame)))
            }
        }
        XCTAssertGreaterThan(loudest, 100,
                             "captured speech must decode to something audible")
    }
}
