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

    func testSDESPaddingFollowsBothObservedSendersNotTheRFCMinimum() {
        // The rule is: pad the chunk (SSRC + items) to a 32-bit boundary, then
        // append four more null octets.
        //
        // This is NOT RFC 3550 §6.5's minimum, and the difference is four bytes
        // that a live session turned on. Worked through on the two senders in
        // the captures, by chunk size:
        //
        //     EchoHam     chunk 75 -> align 76 -> +4 = 80   (observed 80)
        //     thebridge   chunk 84 -> align 84 -> +4 = 88   (observed 88)
        //
        // The RFC minimum (">=1 null, then align") gives 76 for the first,
        // which no observed sender produced. One rule fits both; the minimum
        // fits only one — which is why an earlier version's "they disagree, so
        // the region is slack" reading was wrong.
        //
        // Item bytes are 2 + text for each item, so these two cases are
        // reconstructed by choosing texts of the right lengths.
        func bodyLength(items: [EchoLinkSDESItem]) -> Int {
            let encoded = EchoLinkRTCPCompound([.sourceDescription(ssrc: 0, items: items)]).encoded
            let words = Int(encoded[2]) << 8 | Int(encoded[3])
            return (words + 1) * 4 - 4  // total minus the 4-byte header
        }

        // 71 bytes of items -> chunk 75 -> body must be 80.
        let seventyOne = [
            EchoLinkSDESItem(.cname, String(repeating: "a", count: 33)),   // 35
            EchoLinkSDESItem(.name, String(repeating: "b", count: 34)),    // 36
        ]
        XCTAssertEqual(bodyLength(items: seventyOne), 80, "EchoHam's case")

        // 80 bytes of items -> chunk 84 -> body must be 88.
        let eighty = [
            EchoLinkSDESItem(.cname, String(repeating: "a", count: 38)),   // 40
            EchoLinkSDESItem(.name, String(repeating: "b", count: 38)),    // 40
        ]
        XCTAssertEqual(bodyLength(items: eighty), 88, "thebridge's case")
    }

    func testEveryEncodedSDESLeavesAtLeastFourTrailingNulls() {
        // The property the rule above guarantees, stated directly so it holds
        // for inputs the two worked examples do not cover.
        for textLength in 0 ... 12 {
            let compound = EchoLinkRTCPCompound([
                .sourceDescription(
                    ssrc: 0,
                    items: [EchoLinkSDESItem(.name, String(repeating: "x", count: textLength))])
            ])
            let encoded = compound.encoded
            XCTAssertEqual(encoded.count % 4, 0, "whole words")
            XCTAssertEqual(Array(encoded.suffix(4)), [0, 0, 0, 0],
                           "text length \(textLength): four trailing nulls")
        }
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
