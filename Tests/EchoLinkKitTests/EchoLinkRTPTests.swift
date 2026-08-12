// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import RadioCore
import TestSupport

/// EL-7 — RTP framing, against the captured audio.
final class EchoLinkRTPTests: XCTestCase {
    /// The `0x05` payloads out of an audio fixture.
    private func audioPayloads(_ name: String) throws -> [Data] {
        try FixtureLoader.datagrams(name, in: Bundle.module)
            .map { try EchoLinkProxyFrame.parse($0).frame.payload }
    }

    // MARK: - Round trip

    func testEveryCapturedAudioPacketRoundTripsByteForByte() throws {
        var checked = 0
        for name in ["live-proxy-audio-in.hex", "live-proxy-audio-out.hex"] {
            for payload in try audioPayloads(name) {
                let packet = try EchoLinkRTPPacket.parse(payload)
                XCTAssertEqual(packet.encoded, payload, "\(name): re-encode must reproduce")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 22, "14 inbound + 8 outbound audio packets")
    }

    // MARK: - The two departures from RFC 3550

    func testVersionBitsAreThreeInEveryCapturedPacket() throws {
        for payload in try audioPayloads("live-proxy-audio-in.hex") {
            let header = try EchoLinkRTPHeader.parse(payload)
            XCTAssertEqual(header.version, 3,
                           "RFC 3550 says 2; EchoLink sends 3, and a faithful RFC parser would reject this")
        }
    }

    func testVersionTwoIsAcceptedToo() throws {
        // Accept 3 without rejecting 2: nothing establishes that a peer may not
        // send a conformant version, and refusing would be inventing a rule.
        var header = EchoLinkRTPHeader(sequenceNumber: 7)
        header.version = 2
        let packet = EchoLinkRTPPacket(
            header: header,
            codecFrames: [[UInt8]](repeating: [UInt8](repeating: 0xAA, count: 33), count: 4)
        )
        let parsed = try EchoLinkRTPPacket.parse(packet.encoded)
        XCTAssertEqual(parsed.header.version, 2)
        XCTAssertFalse(parsed.header.isObservedShape)
    }

    func testTimestampIsZeroInEveryCapturedPacket() throws {
        // The fact that makes EL-7 necessary: JitterBuffer keys on timestamps
        // and there is nothing here to key on.
        for name in ["live-proxy-audio-in.hex", "live-proxy-audio-out.hex"] {
            for payload in try audioPayloads(name) {
                XCTAssertEqual(try EchoLinkRTPHeader.parse(payload).timestamp, 0)
            }
        }
    }

    // MARK: - Shape

    func testCapturedPacketsAreFourGSMFrames() throws {
        for payload in try audioPayloads("live-proxy-audio-in.hex") {
            let packet = try EchoLinkRTPPacket.parse(payload)
            XCTAssertEqual(packet.codecFrames.count, 4)
            XCTAssertTrue(packet.codecFrames.allSatisfy { $0.count == 33 })
            XCTAssertEqual(packet.duration, .milliseconds(80))
            XCTAssertEqual(payload.count, EchoLinkRTPPacket.observedPacketSize)
        }
    }

    func testPayloadTypeIsGSM() throws {
        for payload in try audioPayloads("live-proxy-audio-in.hex") {
            XCTAssertEqual(try EchoLinkRTPHeader.parse(payload).payloadType, 3)
        }
    }

    func testHeaderFieldsAreBigEndian() throws {
        // The contrast worth pinning: the proxy header wrapping this one has a
        // little-endian length, nine bytes away.
        let header = EchoLinkRTPHeader(
            sequenceNumber: 0x0102,
            timestamp: 0x03040506,
            synchronisationSource: 0x0708090A
        )
        let bytes = Array(header.encoded)
        XCTAssertEqual(Array(bytes[2 ..< 4]), [0x01, 0x02])
        XCTAssertEqual(Array(bytes[4 ..< 8]), [0x03, 0x04, 0x05, 0x06])
        XCTAssertEqual(Array(bytes[8 ..< 12]), [0x07, 0x08, 0x09, 0x0A])

        XCTAssertEqual(try EchoLinkRTPHeader.parse(header.encoded), header)
    }

    func testSequenceNumbersInTheFixtureAreTheCapturedOnes() throws {
        let inbound = try audioPayloads("live-proxy-audio-in.hex")
            .map { try EchoLinkRTPHeader.parse($0).sequenceNumber }
        // The welcome announcement's tail, then our own audio echoed back.
        XCTAssertEqual(inbound, [146, 147, 148, 149, 150, 151, 0, 1, 2, 3, 4, 5, 6, 7])

        let outbound = try audioPayloads("live-proxy-audio-out.hex")
            .map { try EchoLinkRTPHeader.parse($0).sequenceNumber }
        XCTAssertEqual(outbound, [0, 1, 2, 3, 4, 5, 6, 7])
    }

    // MARK: - Not keying on SSRC

    func testAnArbitrarySSRCParsesFine() throws {
        // A single-peer capture suggested SSRC was always zero; a four-peer one
        // found a peer sending 1787057786. Nothing may key on it.
        var header = EchoLinkRTPHeader(sequenceNumber: 1)
        header.synchronisationSource = 1_787_057_786
        let packet = EchoLinkRTPPacket(
            header: header,
            codecFrames: [[UInt8](repeating: 0x11, count: 33)]
        )
        let parsed = try EchoLinkRTPPacket.parse(packet.encoded)
        XCTAssertEqual(parsed.header.synchronisationSource, 1_787_057_786)
    }

    // MARK: - Errors

    func testTruncatedHeaderIsATypedError() {
        XCTAssertThrowsError(try EchoLinkRTPPacket.parse(Data([0xC0, 0x03]))) { error in
            XCTAssertEqual(error as? EchoLinkRTPError, .truncatedHeader(available: 2))
        }
    }

    func testHeaderWithNoPayloadIsATypedError() {
        let header = EchoLinkRTPHeader(sequenceNumber: 1).encoded
        XCTAssertThrowsError(try EchoLinkRTPPacket.parse(header)) { error in
            XCTAssertEqual(error as? EchoLinkRTPError, .emptyPayload)
        }
    }

    func testPartialCodecFrameIsATypedError() {
        var bytes = EchoLinkRTPHeader(sequenceNumber: 1).encoded
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 40))  // not a multiple of 33
        XCTAssertThrowsError(try EchoLinkRTPPacket.parse(bytes)) { error in
            XCTAssertEqual(error as? EchoLinkRTPError, .partialCodecFrame(payloadBytes: 40))
        }
    }

    func testAnyWholeNumberOfCodecFramesParses() throws {
        // Four is what four implementations happened to send, not a rule.
        for count in 1 ... 6 {
            var bytes = EchoLinkRTPHeader(sequenceNumber: 1).encoded
            bytes.append(contentsOf: [UInt8](repeating: 0x55, count: 33 * count))
            let packet = try EchoLinkRTPPacket.parse(bytes)
            XCTAssertEqual(packet.codecFrames.count, count)
        }
    }

    // MARK: - The 0x05 channel is not audio-only

    func testStationInfoTextIsNotMistakenForAudio() {
        // The trap: "oNDATA..." fed to an RTP parser decodes as version 1,
        // payload type 78, because 'o' is 0x6F and 'N' is 0x4E. A client that
        // skips classification plays announcements as noise.
        let text = Data("oNDATA*ECHOTEST*\rConference server\r".utf8)

        guard case .stationInfo(let info) = EchoLinkAudioChannelMessage.classify(text) else {
            return XCTFail("station info must not classify as audio")
        }
        XCTAssertTrue(info.hasPrefix("oNDATA"))

        // And confirm it *would* have parsed, which is why classification is
        // needed rather than merely tidy.
        var padded = text
        padded.append(contentsOf: [UInt8](repeating: 0, count: 66 - text.count % 33))
        let header = try? EchoLinkRTPHeader.parse(padded)
        XCTAssertEqual(header?.version, 1, "the misreading this test exists to prevent")
        XCTAssertEqual(header?.payloadType, 78)
    }

    func testCapturedAudioClassifiesAsAudio() throws {
        for payload in try audioPayloads("live-proxy-audio-in.hex") {
            guard case .audio = EchoLinkAudioChannelMessage.classify(payload) else {
                return XCTFail("captured audio must classify as audio")
            }
        }
    }

    func testUnrecognisedPayloadIsNotAnError() {
        // A client we have not met is not a fault.
        guard case .unrecognised = EchoLinkAudioChannelMessage.classify(Data([0x01, 0x02])) else {
            return XCTFail("expected .unrecognised")
        }
    }
}
