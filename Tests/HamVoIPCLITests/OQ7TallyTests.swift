// SPDX-License-Identifier: Apache-2.0

import Foundation
import M17Kit
import XCTest

@testable import hamvoip_cli

/// The OQ-7 experiment's analysis, tested against synthesised traffic.
///
/// This matters more than most CLI tests. The harness exists to write an answer
/// into `DESIGN-REQUIREMENTS.md`, and a harness that misreads its own evidence
/// would put the wrong answer there with a live capture behind it. So both
/// readings of Table 27 are synthesised here and the tally is required to tell
/// them apart — including the 54-byte case, which the real client discards
/// before anything sees it.
final class OQ7TallyTests: XCTestCase {

    // MARK: Builders

    /// A stream datagram under either reading.
    ///
    /// Both layouts share bytes 0-33: magic(4) SID(2) DST(6) SRC(6) TYPE(2)
    /// META(14). The 56-byte reading then has LSF-CRC(2) FN(2) payload(16)
    /// CRC(2); the 54-byte reading has FN(2) payload(16) CRC(2). Written out
    /// field by field from Table 27 rather than lifted from anywhere — the
    /// fixture rule in Tests/FIXTURES.md, source 1.
    private func streamDatagram(
        hypothesis: OQ7Hypothesis,
        streamID: UInt16,
        frameNumber: UInt16,
        source: String = "VK1XYZ",
        destination: String = "VK1ABC",
        lsfCRC: UInt16 = 0xBEEF,
        payloadSeed: UInt8 = 0x5A
    ) throws -> Data {
        var bytes = Data("M17 ".utf8)
        bytes.append(contentsOf: [UInt8(streamID >> 8), UInt8(streamID & 0xFF)])
        bytes.append(contentsOf: try M17Address(callsign: destination).bytes)
        bytes.append(contentsOf: try M17Address(callsign: source).bytes)
        bytes.append(contentsOf: [0x00, 0x05])                                  // TYPE: stream, voice
        bytes.append(Data(repeating: 0x00, count: M17StreamPacket.metadataByteCount))
        if hypothesis == .lichIncludesLSFCRC {
            bytes.append(contentsOf: [UInt8(lsfCRC >> 8), UInt8(lsfCRC & 0xFF)])
        }
        bytes.append(contentsOf: [UInt8(frameNumber >> 8), UInt8(frameNumber & 0xFF)])
        bytes.append(Data(repeating: payloadSeed, count: M17StreamPacket.payloadByteCount))
        bytes.append(contentsOf: [0x12, 0x34])                                  // packet CRC
        XCTAssertEqual(bytes.count, hypothesis.byteCount)
        return bytes
    }

    /// One over: `frames` frames of a single stream, the last one flagged.
    private func over(
        hypothesis: OQ7Hypothesis, streamID: UInt16, frames: Int, source: String = "VK1XYZ"
    ) throws -> [Data] {
        try (0..<frames).map { index in
            var frameNumber = UInt16(index)
            if index == frames - 1 { frameNumber |= M17StreamPacket.lastFrameFlag }
            return try streamDatagram(
                hypothesis: hypothesis,
                streamID: streamID,
                frameNumber: frameNumber,
                source: source,
                // Payload varies per frame so the wrong FN offset reads changing
                // bytes rather than a constant that would count as "no change".
                payloadSeed: UInt8(truncatingIfNeeded: index &* 37))
        }
    }

    // MARK: The two readings

    func testFiftySixByteTrafficSettlesOnTheImplementedReading() throws {
        var tally = OQ7Tally()
        for datagram in try over(hypothesis: .lichIncludesLSFCRC, streamID: 0x1234, frames: 25) {
            tally.record(datagram)
        }

        XCTAssertEqual(tally.streamDatagramCount, 25)
        XCTAssertEqual(tally.lengthHistogram, [56: 25])
        XCTAssertEqual(tally.verdict, .settled(byteCount: 56, hypothesis: .lichIncludesLSFCRC))
    }

    func testFiftyFourByteTrafficSettlesOnTheOtherReading() throws {
        var tally = OQ7Tally()
        for datagram in try over(hypothesis: .lichOmitsLSFCRC, streamID: 0x1234, frames: 25) {
            tally.record(datagram)
        }

        XCTAssertEqual(tally.streamDatagramCount, 25)
        XCTAssertEqual(tally.lengthHistogram, [54: 25])
        XCTAssertEqual(tally.verdict, .settled(byteCount: 54, hypothesis: .lichOmitsLSFCRC))
    }

    /// The point of the FN corroboration: at the wrong offset the bytes are a
    /// CRC or payload, and they do not count.
    func testOnlyTheCorrectOffsetCountsAsAFrameCounter() throws {
        var tally = OQ7Tally()
        for datagram in try over(hypothesis: .lichIncludesLSFCRC, streamID: 0x0001, frames: 30) {
            tally.record(datagram)
        }

        XCTAssertEqual(tally.corroboratedHypotheses, [.lichIncludesLSFCRC])
        let wrong = try XCTUnwrap(tally.evidence[.lichOmitsLSFCRC])
        XCTAssertEqual(wrong.consecutivePairs, 0, "a constant LSF CRC must not read as a counter")
    }

    /// Frame numbers are tracked per stream, so two overs interleaved on the
    /// reflector do not look like a broken counter.
    func testFrameNumbersAreTrackedPerStream() throws {
        var tally = OQ7Tally()
        let first = try over(hypothesis: .lichIncludesLSFCRC, streamID: 0xAAAA, frames: 12, source: "VK1XYZ")
        let second = try over(hypothesis: .lichIncludesLSFCRC, streamID: 0xBBBB, frames: 12, source: "VK2DEF")
        for (a, b) in zip(first, second) {
            tally.record(a)
            tally.record(b)
        }

        XCTAssertEqual(tally.streamIDs, [0xAAAA, 0xBBBB])
        XCTAssertEqual(tally.sourceCallsigns, ["VK1XYZ": 12, "VK2DEF": 12])
        XCTAssertEqual(tally.verdict, .settled(byteCount: 56, hypothesis: .lichIncludesLSFCRC))
    }

    /// A UDP path may drop a frame. One gap must not unsettle a verdict.
    func testAMissingFrameDoesNotUnsettleTheVerdict() throws {
        var tally = OQ7Tally()
        var frames = try over(hypothesis: .lichIncludesLSFCRC, streamID: 0x0002, frames: 25)
        frames.remove(at: 10)
        for datagram in frames { tally.record(datagram) }

        XCTAssertEqual(tally.verdict, .settled(byteCount: 56, hypothesis: .lichIncludesLSFCRC))
    }

    // MARK: Refusing to conclude

    func testSilenceIsNotAnAnswer() {
        var tally = OQ7Tally()
        // A link's worth of control traffic and nothing else.
        for _ in 0..<40 {
            tally.record(Data("PING".utf8) + Data(repeating: 0, count: 6))
        }

        XCTAssertEqual(tally.streamDatagramCount, 0)
        XCTAssertEqual(tally.verdict, .noStreamDatagrams(inboundDatagrams: 40))
        XCTAssertEqual(tally.nonStreamHistogram, ["\"PING\"": 40])
    }

    func testTooFewFramesReportsLengthWithoutClaimingCorroboration() throws {
        var tally = OQ7Tally()
        for datagram in try over(hypothesis: .lichIncludesLSFCRC, streamID: 0x0003, frames: 4) {
            tally.record(datagram)
        }

        XCTAssertEqual(tally.verdict, .lengthConsistentOnly(byteCount: 56))
    }

    func testMixedLengthsAreReportedAsMixed() throws {
        var tally = OQ7Tally()
        for datagram in try over(hypothesis: .lichIncludesLSFCRC, streamID: 0x0004, frames: 10) {
            tally.record(datagram)
        }
        for datagram in try over(hypothesis: .lichOmitsLSFCRC, streamID: 0x0005, frames: 10) {
            tally.record(datagram)
        }

        XCTAssertEqual(tally.verdict, .mixedLengths([56: 10, 54: 10]))
    }

    func testALengthNeitherReadingPredictsIsNotForcedIntoOne() throws {
        var tally = OQ7Tally()
        for index in 0..<12 {
            var datagram = try streamDatagram(
                hypothesis: .lichIncludesLSFCRC, streamID: 0x0006, frameNumber: UInt16(index))
            datagram.append(contentsOf: [0x00, 0x00])  // 58 bytes: neither reading
            tally.record(datagram)
        }

        XCTAssertEqual(tally.verdict, .unexpectedLength(byteCount: 58))
    }

    /// Length says 56, but the counter is at the 54-byte reading's offset. That
    /// is not an answer, and the tally must not dress it up as one.
    func testLengthAndSequencingDisagreeingIsReportedAsContradictory() throws {
        var tally = OQ7Tally()
        for index in 0..<20 {
            // A 54-byte frame padded to 56 — what a padding middlebox would do,
            // and the shape the verdict must refuse.
            var datagram = try streamDatagram(
                hypothesis: .lichOmitsLSFCRC,
                streamID: 0x0007,
                frameNumber: UInt16(index),
                payloadSeed: UInt8(truncatingIfNeeded: index &* 37))
            datagram.append(contentsOf: [0x00, 0x00])
            tally.record(datagram)
        }

        XCTAssertEqual(
            tally.verdict, .contradictory(byteCount: 56, corroborated: .lichOmitsLSFCRC))
    }

    // MARK: Robustness

    func testShortAndUnrecognisedDatagramsAreCountedNotCrashedOn() {
        var tally = OQ7Tally()
        tally.record(Data())
        tally.record(Data([0x4D]))
        tally.record(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        // Stream magic, but far too short to carry a SID or SRC.
        tally.record(Data("M17 ".utf8) + Data([0x00, 0x01]))

        XCTAssertEqual(tally.inboundDatagramCount, 4)
        XCTAssertEqual(tally.streamDatagramCount, 1)
        XCTAssertEqual(tally.lengthHistogram, [6: 1])
        XCTAssertEqual(tally.nonStreamHistogram["DEADBEEF"], 1)
        XCTAssertEqual(tally.nonStreamHistogram["<0 bytes, shorter than a magic>"], 1)
        XCTAssertEqual(tally.nonStreamHistogram["<1 bytes, shorter than a magic>"], 1)
    }

    func testReportNamesTheVerdictAndTheEvidence() throws {
        var tally = OQ7Tally()
        for datagram in try over(hypothesis: .lichOmitsLSFCRC, streamID: 0x0008, frames: 20) {
            tally.record(datagram)
        }

        let report = tally.report()
        XCTAssertTrue(report.contains("54 bytes  ×20"), report)
        XCTAssertTrue(report.contains("VK1XYZ"), report)
        XCTAssertTrue(report.contains("SETTLED"), report)
        // The guidance for a 54-byte answer must point at the one constant that
        // changes, or the next agent will go looking.
        XCTAssertTrue(report.contains("M17StreamPacket.byteCount"), report)
    }
}
