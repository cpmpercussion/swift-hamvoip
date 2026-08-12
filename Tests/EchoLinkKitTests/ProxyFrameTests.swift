// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import TestSupport

/// EL-4 — the proxy frame codec, against the EL-2 capture fixtures.
///
/// The central test is `testEveryFixtureFrameRoundTripsByteForByte`: everything
/// else here is a specific hazard, but that one is the claim that this codec
/// reads what a real proxy actually sent.
final class ProxyFrameTests: XCTestCase {
    /// Every EchoLink fixture whose lines are all whole proxy frames.
    ///
    /// `live-proxy-login-in.hex` is excluded on purpose: its first line is the
    /// unframed login nonce, which is not a frame at all. It gets its own test.
    private static let framedFixtures = [
        "live-proxy-open-out.hex",
        "live-proxy-audio-in.hex",
        "live-proxy-audio-out.hex",
        "live-proxy-rtcp.hex",
    ]

    private func lines(_ name: String) throws -> [Data] {
        try FixtureLoader.datagrams(name, in: Bundle.module)
    }

    // MARK: - Round trip

    func testEveryFixtureFrameRoundTripsByteForByte() throws {
        var framesChecked = 0

        for fixture in Self.framedFixtures {
            for (index, line) in try lines(fixture).enumerated() {
                let (frame, consumed) = try EchoLinkProxyFrame.parse(line)
                XCTAssertEqual(
                    consumed, line.count,
                    "\(fixture)[\(index)]: one fixture line must be exactly one frame"
                )
                XCTAssertEqual(
                    frame.encoded, line,
                    "\(fixture)[\(index)]: re-encoding must reproduce the captured octets"
                )
                framesChecked += 1
            }
        }

        // The login fixture, minus its unframed first line.
        let login = try lines("live-proxy-login-in.hex")
        for (index, line) in login.dropFirst().enumerated() {
            let (frame, consumed) = try EchoLinkProxyFrame.parse(line)
            XCTAssertEqual(consumed, line.count)
            XCTAssertEqual(frame.encoded, line, "login fixture line \(index + 1)")
            framesChecked += 1
        }

        // 2 OPEN + 14 inbound audio + 8 outbound audio + 2 RTCP + 4 from the
        // login fixture past its unframed first line.
        XCTAssertEqual(framesChecked, 30, "the fixture set is 30 whole proxy frames")
    }

    func testFixturesCoverEverySixObservedMessageTypes() throws {
        var seen: Set<UInt8> = []
        for fixture in Self.framedFixtures {
            for line in try lines(fixture) {
                seen.insert(try EchoLinkProxyFrame.parse(line).frame.type.rawValue)
            }
        }
        for line in try lines("live-proxy-login-in.hex").dropFirst() {
            seen.insert(try EchoLinkProxyFrame.parse(line).frame.type.rawValue)
        }

        XCTAssertEqual(
            seen.sorted(), [0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
            "the fixture set must carry evidence for every observed type"
        )
    }

    // MARK: - The header, field by field

    func testLittleEndianLengthIsReadAsCaptured() throws {
        // A 4-byte STATUS payload. Big-endian would read this length as
        // 0x04000000 — 67 million bytes — which is exactly how the mistake
        // announces itself.
        let status = try lines("live-proxy-login-in.hex")[1]
        let (frame, _) = try EchoLinkProxyFrame.parse(status)

        XCTAssertEqual(frame.type, .status)
        XCTAssertEqual(frame.payload.count, 4)
        XCTAssertEqual(Array(status[5 ..< 9]), [0x04, 0x00, 0x00, 0x00],
                       "the captured length bytes, for the record")
        XCTAssertEqual(Array(frame.payload), [0x00, 0x00, 0x00, 0x00], "success")
    }

    func testPeerAddressIsUnspecifiedOnDirectoryFrames() throws {
        for line in try lines("live-proxy-login-in.hex").dropFirst() {
            let (frame, _) = try EchoLinkProxyFrame.parse(line)
            XCTAssertTrue(frame.peer.isUnspecified,
                          "\(frame.type) carried peer \(frame.peer), expected 0.0.0.0")
        }
    }

    func testPeerAddressIsCarriedOnAudioFrames() throws {
        let audio = try lines("live-proxy-audio-in.hex")
        let (frame, _) = try EchoLinkProxyFrame.parse(audio[0])

        XCTAssertEqual(frame.type, .udpData)
        XCTAssertFalse(frame.peer.isUnspecified)
        // *ECHOTEST*, the public test conference — see the fixture's header.
        XCTAssertEqual(frame.peer.description, "13.57.14.183")
    }

    func testZeroLengthPayloadIsAFrameNotAnAbsence() throws {
        for line in try lines("live-proxy-open-out.hex") {
            let (frame, consumed) = try EchoLinkProxyFrame.parse(line)
            XCTAssertEqual(frame.type, .open)
            XCTAssertTrue(frame.payload.isEmpty)
            XCTAssertEqual(consumed, EchoLinkProxyFrame.headerSize)
            XCTAssertEqual(line.count, EchoLinkProxyFrame.headerSize)
        }
    }

    func testAudioFramesAreOneHundredAndFortyFourBytePayloads() throws {
        for name in ["live-proxy-audio-in.hex", "live-proxy-audio-out.hex"] {
            for line in try lines(name) {
                let (frame, _) = try EchoLinkProxyFrame.parse(line)
                XCTAssertEqual(frame.type, .udpData)
                XCTAssertEqual(frame.payload.count, 144,
                               "12-byte RTP header + 4 x 33-byte GSM frames")
            }
        }
    }

    // MARK: - Permissive parsing

    func testUnknownMessageTypeSurvivesParsing() throws {
        // 0x7F is not one of the six. It must parse, keep its raw value, and
        // round-trip — a client we have not met is not a protocol error.
        let frame = EchoLinkProxyFrame(
            type: EchoLinkProxyMessageType(rawValue: 0x7F),
            peer: EchoLinkPeerAddress(10, 0, 0, 1),
            payload: Data([0xDE, 0xAD])
        )
        let (parsed, consumed) = try EchoLinkProxyFrame.parse(frame.encoded)

        XCTAssertEqual(parsed, frame)
        XCTAssertEqual(consumed, EchoLinkProxyFrame.headerSize + 2)
        XCTAssertFalse(parsed.type.isObserved)
        XCTAssertEqual(parsed.type.description, "unknown(0x7f)")
    }

    func testObservedTypesAreReportedAsObserved() {
        for raw in UInt8(0x01) ... UInt8(0x06) {
            XCTAssertTrue(EchoLinkProxyMessageType(rawValue: raw).isObserved)
        }
        XCTAssertFalse(EchoLinkProxyMessageType(rawValue: 0x00).isObserved)
        XCTAssertFalse(EchoLinkProxyMessageType(rawValue: 0x07).isObserved)
    }

    // MARK: - Truncation, distinguishably

    func testTruncatedHeaderIsItsOwnError() {
        let short = Data([0x05, 0x0D, 0x39])
        XCTAssertThrowsError(try EchoLinkProxyFrame.parse(short)) { error in
            XCTAssertEqual(error as? EchoLinkProxyFrameError, .truncatedHeader(available: 3))
        }
    }

    func testEmptyInputIsATruncatedHeader() {
        XCTAssertThrowsError(try EchoLinkProxyFrame.parse(Data())) { error in
            XCTAssertEqual(error as? EchoLinkProxyFrameError, .truncatedHeader(available: 0))
        }
    }

    func testTruncatedPayloadIsADifferentError() {
        // A complete header declaring 10 bytes, with 3 present.
        var bytes = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0x01, 0x02, 0x03])

        XCTAssertThrowsError(try EchoLinkProxyFrame.parse(bytes)) { error in
            XCTAssertEqual(
                error as? EchoLinkProxyFrameError,
                .truncatedPayload(expected: 10, available: 3)
            )
        }
    }

    func testHeaderExactlyNineBytesWithDeclaredPayloadIsTruncatedPayload() {
        let bytes = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try EchoLinkProxyFrame.parse(bytes)) { error in
            XCTAssertEqual(
                error as? EchoLinkProxyFrameError,
                .truncatedPayload(expected: 1, available: 0)
            )
        }
    }

    func testImplausibleLengthIsRejectedRatherThanReserved() {
        // 0xFFFFFFFF little-endian. Without the ceiling this is a 4 GB
        // allocation on the strength of four bytes from the network.
        let bytes = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try EchoLinkProxyFrame.parse(bytes)) { error in
            XCTAssertEqual(
                error as? EchoLinkProxyFrameError,
                .implausibleLength(Int(UInt32.max))
            )
        }
    }

    // MARK: - Peer address value type

    func testPeerAddressParsesAndPrintsDottedQuad() {
        XCTAssertEqual(EchoLinkPeerAddress("13.57.14.183")?.bytes, [13, 57, 14, 183])
        XCTAssertEqual(EchoLinkPeerAddress(13, 57, 14, 183).description, "13.57.14.183")
        XCTAssertNil(EchoLinkPeerAddress("13.57.14"))
        XCTAssertNil(EchoLinkPeerAddress("13.57.14.256"))
        XCTAssertNil(EchoLinkPeerAddress("13.57.14.183.9"))
        XCTAssertNil(EchoLinkPeerAddress(""))
    }

    func testPeerAddressEqualityAndHashing() {
        let a = EchoLinkPeerAddress(1, 2, 3, 4)
        let b = EchoLinkPeerAddress(1, 2, 3, 4)
        let c = EchoLinkPeerAddress(1, 2, 3, 5)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b, c]).count, 2)
    }

    // MARK: - Encoding

    func testEncodedLengthIsLittleEndianAcrossAllFourBytes() {
        // 0x00010203 bytes of payload would be absurd, so exercise the byte
        // order on a value that differs in every octet instead: 66051 bytes
        // is 0x00010203, which little-endian writes as 03 02 01 00.
        let frame = EchoLinkProxyFrame(
            type: .data,
            payload: Data(repeating: 0x00, count: 0x010203)
        )
        let encoded = frame.encoded
        XCTAssertEqual(Array(encoded[5 ..< 9]), [0x03, 0x02, 0x01, 0x00])

        let (parsed, consumed) = try! EchoLinkProxyFrame.parse(encoded)
        XCTAssertEqual(parsed.payload.count, 0x010203)
        XCTAssertEqual(consumed, encoded.count)
    }

    func testDescriptionIsUsefulInALog() {
        XCTAssertEqual(
            EchoLinkProxyFrame(type: .open, peer: EchoLinkPeerAddress(1, 2, 3, 4)).description,
            "OPEN peer 1.2.3.4 0B"
        )
        XCTAssertEqual(
            EchoLinkProxyFrame(type: .status, payload: Data([0, 0, 0, 0])).description,
            "STATUS 4B"
        )
    }
}
