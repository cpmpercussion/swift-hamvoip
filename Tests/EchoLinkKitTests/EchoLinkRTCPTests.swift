// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import TestSupport

/// The RTCP control channel — the packets that open and close a node session.
///
/// The plan deferred this as "observed but not needed for a working QSO". That
/// was wrong in the direction that mattered: since `0x01 OPEN` is only ever sent
/// for the tunnelled directory connection, the SDES exchange is the *only*
/// thing that starts a node session, and without it no node ever answers.
final class EchoLinkRTCPTests: XCTestCase {
    /// The two captured `0x06` payloads: `[0]` is the node's SDES, `[1]` is our
    /// own BYE.
    private func controlPayloads() throws -> [Data] {
        try FixtureLoader.datagrams("live-proxy-rtcp.hex", in: Bundle.module)
            .map { try EchoLinkProxyFrame.parse($0).frame.payload }
    }

    // MARK: - The captured packets

    func testTheCapturedInboundCompoundIsAReceiverReportThenAnSDES() throws {
        let compound = try EchoLinkRTCPCompound.parse(try controlPayloads()[0])

        XCTAssertEqual(compound.packets.count, 2)
        guard case .receiverReport(let rrSSRC) = compound.packets[0] else {
            return XCTFail("expected a receiver report first")
        }
        XCTAssertEqual(rrSSRC, 9999)

        guard case .sourceDescription(let ssrc, let items) = compound.packets[1] else {
            return XCTFail("expected an SDES second")
        }
        XCTAssertEqual(ssrc, 9999)
        XCTAssertEqual(items.first { $0.type == .name }?.text,
                       "*ECHOTEST* (Conference  [8]) CONF")
        XCTAssertEqual(items.first { $0.type == .tool }?.text, "thebridge V 0.81")
        XCTAssertEqual(compound.sourceName, "*ECHOTEST* (Conference  [8]) CONF")
        XCTAssertFalse(compound.isGoodbye)
    }

    func testTheCapturedOutboundCompoundIsAReceiverReportThenABye() throws {
        let compound = try EchoLinkRTCPCompound.parse(try controlPayloads()[1])

        XCTAssertEqual(compound.packets.count, 2)
        guard case .goodbye(let ssrc, let reason) = compound.packets[1] else {
            return XCTFail("expected a BYE second")
        }
        XCTAssertEqual(ssrc, 0)
        XCTAssertEqual(reason, "jan2002", "the reason string every observed BYE carries")
        XCTAssertTrue(compound.isGoodbye)
    }

    func testCNAMEIsTheLiteralPlaceholderBothImplementationsSend() throws {
        // Not a redaction and not something we invented: EchoHam and thebridge
        // both put the eight characters "CALLSIGN" here. The identity is in
        // NAME.
        let compound = try EchoLinkRTCPCompound.parse(try controlPayloads()[0])
        guard case .sourceDescription(_, let items) = compound.packets[1] else {
            return XCTFail("expected an SDES")
        }
        XCTAssertEqual(items.first { $0.type == .cname }?.text, "CALLSIGN")
        XCTAssertEqual(EchoLinkRTCPCompound.cnamePlaceholder, "CALLSIGN")
    }

    func testEveryCapturedPayloadConsumesExactly() throws {
        // A wrong length field would leave a tail or overrun, and the compound
        // walk is driven entirely by those lengths.
        for payload in try controlPayloads() {
            let compound = try EchoLinkRTCPCompound.parse(payload)
            XCTAssertFalse(compound.packets.isEmpty)
            XCTAssertTrue(
                compound.packets.allSatisfy { packet in
                    if case .other = packet { return false }
                    return true
                },
                "every packet in the captures should be recognised"
            )
        }
    }

    // MARK: - What we emit

    func testSessionOpeningHasTheObservedShape() {
        let compound = EchoLinkRTCPCompound.sessionOpening(
            callsign: "N0CALL",
            operatorName: "A Person",
            localTime: "18:44",
            tool: "swift-hamvoip"
        )

        XCTAssertEqual(compound.packets.count, 2)
        guard case .receiverReport(let rrSSRC) = compound.packets[0] else {
            return XCTFail("RR first, as every observed compound has")
        }
        XCTAssertEqual(rrSSRC, 0, "what this client sends, as observed")

        guard case .sourceDescription(_, let items) = compound.packets[1] else {
            return XCTFail("SDES second")
        }
        XCTAssertEqual(items.map(\.type), [.cname, .name, .email, .phone, .tool],
                       "the five items, in the captured order")
        XCTAssertEqual(items.first { $0.type == .name }?.text, "N0CALL         A Person")
        XCTAssertEqual(items.first { $0.type == .phone }?.text, "18:44")
    }

    func testTheCallsignFieldIsFifteenCharacters() {
        // Measured off the capture: a six-character callsign followed by nine
        // spaces before the operator name, so the field is fifteen wide.
        for callsign in ["W1AW", "N0CALL", "VK1ABC"] {
            let compound = EchoLinkRTCPCompound.sessionOpening(
                callsign: callsign, operatorName: "X", localTime: "00:00", tool: "t"
            )
            guard case .sourceDescription(_, let items) = compound.packets[1],
                  let name = items.first(where: { $0.type == .name })?.text
            else { return XCTFail("expected a NAME item") }

            XCTAssertTrue(name.hasPrefix(callsign))
            XCTAssertEqual(name.count, 15 + 1, "15-character field then the name")
            XCTAssertTrue(name.hasSuffix("X"))
        }
    }

    func testAnOverlongCallsignIsNotTruncated() {
        // Padding must never become truncation: a callsign is an identity, and
        // a silently shortened one is worse than an unpadded field.
        let compound = EchoLinkRTCPCompound.sessionOpening(
            callsign: "AVERYLONGCALLSIGNINDEED",
            operatorName: "X", localTime: "00:00", tool: "t"
        )
        guard case .sourceDescription(_, let items) = compound.packets[1],
              let name = items.first(where: { $0.type == .name })?.text
        else { return XCTFail("expected a NAME item") }
        XCTAssertTrue(name.hasPrefix("AVERYLONGCALLSIGNINDEED"))
    }

    func testSessionClosingIsAReceiverReportAndABye() {
        let compound = EchoLinkRTCPCompound.sessionClosing()
        XCTAssertTrue(compound.isGoodbye)
        guard case .goodbye(_, let reason) = compound.packets[1] else {
            return XCTFail("expected a BYE")
        }
        XCTAssertEqual(reason, "jan2002")
    }

    // MARK: - Round trip

    func testWhatWeEmitSurvivesOurOwnParser() throws {
        let compounds = [
            EchoLinkRTCPCompound.sessionOpening(
                callsign: "N0CALL", operatorName: "A Person",
                localTime: "18:44", tool: "swift-hamvoip"),
            EchoLinkRTCPCompound.sessionClosing(),
        ]
        for compound in compounds {
            XCTAssertEqual(try EchoLinkRTCPCompound.parse(compound.encoded), compound)
        }
    }

    func testEncodedPacketsAreWholeWordsAndCarryTheRightLength() throws {
        let encoded = EchoLinkRTCPCompound.sessionOpening(
            callsign: "N0CALL", operatorName: "A Person",
            localTime: "18:44", tool: "swift-hamvoip"
        ).encoded

        XCTAssertEqual(encoded.count % 4, 0, "RTCP packets are whole 32-bit words")

        // Walk it the way a receiver does: by the declared lengths alone.
        var offset = encoded.startIndex
        var packets = 0
        while offset + 4 <= encoded.endIndex {
            XCTAssertEqual(encoded[offset] >> 6, 3, "version bits are 3 here too")
            let words = Int(encoded[offset + 2]) << 8 | Int(encoded[offset + 3])
            offset += (words + 1) * 4
            packets += 1
        }
        XCTAssertEqual(offset, encoded.endIndex, "the lengths must consume the payload exactly")
        XCTAssertEqual(packets, 2)
    }

    func testVersionBitsAreThreeInTheCaptures() throws {
        for payload in try controlPayloads() {
            XCTAssertEqual(payload[payload.startIndex] >> 6, 3)
        }
    }

    // MARK: - Permissive parsing

    func testAnUnknownPayloadTypeIsKeptRatherThanDropped() throws {
        var bytes = Data([0xC0, 0xFE, 0x00, 0x01])  // pt 254, one extra word
        bytes.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        let compound = try EchoLinkRTCPCompound.parse(bytes)
        guard case .other(let type, let body) = compound.packets.first else {
            return XCTFail("expected .other")
        }
        XCTAssertEqual(type, 254)
        XCTAssertEqual(Array(body), [0xDE, 0xAD, 0xBE, 0xEF])
    }

    func testATruncatedPayloadIsATypedError() {
        XCTAssertThrowsError(try EchoLinkRTCPCompound.parse(Data([0xC0, 0xC9]))) { error in
            XCTAssertEqual(error as? EchoLinkRTCPError, .truncated(available: 2))
        }
    }

    func testALengthRunningPastTheEndIsATypedError() {
        // Declares 40 bytes, 8 present.
        let bytes = Data([0xC0, 0xC9, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try EchoLinkRTCPCompound.parse(bytes)) { error in
            XCTAssertEqual(
                error as? EchoLinkRTCPError,
                .lengthOverrun(declared: 40, available: 8)
            )
        }
    }

    func testAnSDESWithNoItemsParses() throws {
        let compound = EchoLinkRTCPCompound([.sourceDescription(ssrc: 7, items: [])])
        let parsed = try EchoLinkRTCPCompound.parse(compound.encoded)
        guard case .sourceDescription(let ssrc, let items) = parsed.packets[0] else {
            return XCTFail("expected an SDES")
        }
        XCTAssertEqual(ssrc, 7)
        XCTAssertTrue(items.isEmpty)
        XCTAssertNil(parsed.sourceName)
    }
}
