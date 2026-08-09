// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
import TestSupport
@testable import M17Kit

/// Packet-layer tests for the M17 reflector control protocol (M17-3).
///
/// Every expected byte string here is either hand-written from the
/// specification (see the `reflector-*.hex` fixtures, which cite the table
/// each field comes from) or derived from the specification's own worked
/// example for base-40 encoding, `AB1CD` → `0x9FDD51` (M17 spec Part I §A.2).
final class M17ReflectorProtocolTests: XCTestCase {

    // MARK: - Helpers

    /// The client callsign used throughout: the spec's own worked example.
    private static let callsign = "AB1CD"
    private static let callsignBytes: [UInt8] = [0x00, 0x00, 0x00, 0x9F, 0xDD, 0x51]

    /// The reflector-side address used throughout: text "M17 A", i.e. the
    /// "callsign including module in last character" convention from the
    /// "Control Packets" section.
    private static let reflectorBytes: [UInt8] = [0x00, 0x00, 0x00, 0x27, 0xE8, 0xED]

    private func clientAddress() throws -> M17Address {
        try M17Address(callsign: Self.callsign)
    }

    private func reflectorAddress() throws -> M17Address {
        try M17Address(bytes: Self.reflectorBytes)
    }

    private func fixture(_ name: String) throws -> Data {
        try FixtureLoader.datagram(name, in: Bundle.module)
    }

    // MARK: - Magic

    func testMagicByteValues() {
        // "Control Packets" names six control magics; "Standard IP Framing"
        // Table 27 gives the stream magic as 0x4d313720.
        XCTAssertEqual(M17PacketMagic.connect.bytes, Array("CONN".utf8))
        XCTAssertEqual(M17PacketMagic.acknowledge.bytes, Array("ACKN".utf8))
        XCTAssertEqual(M17PacketMagic.negativeAcknowledge.bytes, Array("NACK".utf8))
        XCTAssertEqual(M17PacketMagic.ping.bytes, Array("PING".utf8))
        XCTAssertEqual(M17PacketMagic.pong.bytes, Array("PONG".utf8))
        XCTAssertEqual(M17PacketMagic.disconnect.bytes, Array("DISC".utf8))
        XCTAssertEqual(M17PacketMagic.stream.bytes, [0x4D, 0x31, 0x37, 0x20])
        XCTAssertEqual(M17PacketMagic.allCases.count, 7)
    }

    func testPermittedLengthsMatchTheSpecificationTables() {
        // Tables 28-33 and Table 27, read as byte offsets.
        XCTAssertEqual(M17PacketMagic.connect.permittedLengths, [11])            // 4 + 6 + 1
        XCTAssertEqual(M17PacketMagic.acknowledge.permittedLengths, [4])         // magic only
        XCTAssertEqual(M17PacketMagic.negativeAcknowledge.permittedLengths, [4]) // magic only
        XCTAssertEqual(M17PacketMagic.ping.permittedLengths, [10])               // 4 + 6
        XCTAssertEqual(M17PacketMagic.pong.permittedLengths, [10])               // 4 + 6
        // DISC alone has two forms: with the callsign, and the 4-byte bare
        // acknowledgement.
        XCTAssertEqual(M17PacketMagic.disconnect.permittedLengths, [10, 4])
        XCTAssertEqual(M17PacketMagic.stream.permittedLengths, [56])             // 4+2+30+2+16+2
    }

    // MARK: - Address field

    func testAddressEncodesTheSpecificationsWorkedExample() throws {
        let address = try M17Address(callsign: "AB1CD")
        XCTAssertEqual(address.value, 0x9F_DD51)
        XCTAssertEqual(address.bytes, Self.callsignBytes)
        XCTAssertEqual(address.callsign, "AB1CD")
    }

    func testAddressAppendsModuleAsCallsignSpaceModule() throws {
        // "Control Packets": "6-byte 'From' callsign including module in last
        // character (e.g. "A1BCD D")". The encoded text is therefore
        // "<callsign> <module>".
        let address = try M17Address(callsign: "AB1CD", module: try M17Module("A"))
        XCTAssertEqual(address.callsign, "AB1CD A")
        XCTAssertEqual(address.bytes, [0x00, 0x00, 0xF4, 0xC3, 0xDD, 0x51])

        // Arithmetically: encode("AB1CD") + 1 * 40^6, because the space
        // contributes 0 and the module sits one place further up (Part I §A.2:
        // the first character is the least significant digit).
        XCTAssertEqual(address.value, 0x9F_DD51 + 4_096_000_000)
    }

    func testAddressRoundTripsThroughSixBigEndianBytes() throws {
        let original = try M17Address(callsign: "AB1CD")
        let reparsed = try M17Address(bytes: original.bytes)
        XCTAssertEqual(reparsed, original)
    }

    func testAddressRejectsWrongByteCount() {
        for count in [0, 5, 7] {
            XCTAssertThrowsError(try M17Address(bytes: [UInt8](repeating: 0, count: count))) { error in
                guard case M17PacketError.invalidAddress = error else {
                    return XCTFail("expected .invalidAddress for \(count) bytes, got \(error)")
                }
            }
        }
    }

    func testAddressKeepsUndecodableValuesRatherThanFailing() throws {
        // Broadcast (Part I Table A.2) is legal on the wire but carries no
        // text: the address must still parse.
        let broadcast = try M17Address(bytes: [UInt8](repeating: 0xFF, count: 6))
        XCTAssertEqual(broadcast.value, 0xFFFF_FFFF_FFFF)
        XCTAssertNil(broadcast.callsign)
    }

    func testAddressRejectsCallsignTooLongForModuleSuffix() {
        // Nine characters is the maximum (Part I §A.1); "ABCDEFGH" + space +
        // module would be ten.
        XCTAssertThrowsError(try M17Address(callsign: "ABCDEFGH", module: try M17Module("A")))
    }

    // MARK: - Module field

    func testModuleAcceptsOnlyAsciiUppercaseLetters() throws {
        XCTAssertEqual(try M17Module("A").wireByte, 0x41)
        XCTAssertEqual(try M17Module("Z").wireByte, 0x5A)
        XCTAssertEqual(try M17Module(wireByte: 0x44).letter, "D")

        for bad: Character in ["a", "0", " ", "!", "Ä"] {
            XCTAssertThrowsError(try M17Module(bad), "module '\(bad)' should be rejected")
        }
        for bad: UInt8 in [0x00, 0x40, 0x5B, 0x61, 0xFF] {
            XCTAssertThrowsError(try M17Module(wireByte: bad))
        }
    }

    // MARK: - Serialization against hand-built fixtures

    func testConnSerializesToTheHandBuiltFixture() throws {
        let expected = try fixture("reflector-conn.hex")
        let packet = M17ControlPacket.connect(from: try clientAddress(), module: try M17Module("A"))

        XCTAssertEqual(packet.data, expected)
        XCTAssertEqual(expected.count, 11)
        XCTAssertEqual([UInt8](expected)[0..<4].map { $0 }, Array("CONN".utf8))
        XCTAssertEqual([UInt8](expected)[4..<10].map { $0 }, Self.callsignBytes)
        XCTAssertEqual([UInt8](expected)[10], 0x41)  // 'A'
    }

    func testAcknSerializesToTheHandBuiltFixture() throws {
        let expected = try fixture("reflector-ackn.hex")
        XCTAssertEqual(M17ControlPacket.acknowledge.data, expected)
        // Table 29 lists bytes 0-3 only: no callsign field.
        XCTAssertEqual(expected.count, 4)
    }

    func testNackSerializesToTheHandBuiltFixture() throws {
        let expected = try fixture("reflector-nack.hex")
        XCTAssertEqual(M17ControlPacket.negativeAcknowledge.data, expected)
        XCTAssertEqual(expected.count, 4)
    }

    func testPingSerializesToTheHandBuiltFixture() throws {
        let expected = try fixture("reflector-ping.hex")
        let packet = M17ControlPacket.ping(from: try reflectorAddress())
        XCTAssertEqual(packet.data, expected)
        XCTAssertEqual(expected.count, 10)
    }

    func testPongSerializesToTheHandBuiltFixture() throws {
        let expected = try fixture("reflector-pong.hex")
        let packet = M17ControlPacket.pong(from: try clientAddress())
        XCTAssertEqual(packet.data, expected)
        XCTAssertEqual(expected.count, 10)
    }

    func testDiscSerializesInBothItsForms() throws {
        let long = try fixture("reflector-disc.hex")
        XCTAssertEqual(M17ControlPacket.disconnect(from: try clientAddress()).data, long)
        XCTAssertEqual(long.count, 10)

        let bare = try fixture("reflector-disc-ack.hex")
        XCTAssertEqual(M17ControlPacket.disconnect(from: nil).data, bare)
        XCTAssertEqual(bare.count, 4)
    }

    // MARK: - Parsing the fixtures back

    func testFixturesParseToTheExpectedPackets() throws {
        try XCTAssertEqual(
            M17ControlPacket.parse(fixture("reflector-conn.hex")),
            .connect(from: clientAddress(), module: M17Module("A")))
        try XCTAssertEqual(M17ControlPacket.parse(fixture("reflector-ackn.hex")), .acknowledge)
        try XCTAssertEqual(M17ControlPacket.parse(fixture("reflector-nack.hex")), .negativeAcknowledge)
        try XCTAssertEqual(
            M17ControlPacket.parse(fixture("reflector-ping.hex")), .ping(from: reflectorAddress()))
        try XCTAssertEqual(
            M17ControlPacket.parse(fixture("reflector-pong.hex")), .pong(from: clientAddress()))
        try XCTAssertEqual(
            M17ControlPacket.parse(fixture("reflector-disc.hex")), .disconnect(from: clientAddress()))
        try XCTAssertEqual(
            M17ControlPacket.parse(fixture("reflector-disc-ack.hex")), .disconnect(from: nil))
    }

    func testDecodedPingAddressCarriesTheModuleInItsLastCharacter() throws {
        let packet = try M17ControlPacket.parse(fixture("reflector-ping.hex"))
        guard case .ping(let from) = packet else { return XCTFail("expected PING, got \(packet)") }
        XCTAssertEqual(from.callsign, "M17 A")
    }

    // MARK: - Round trips

    func testEveryControlPacketRoundTrips() throws {
        let packets: [M17ControlPacket] = [
            .connect(from: try clientAddress(), module: try M17Module("A")),
            .connect(from: try M17Address(callsign: "AB1CD", module: try M17Module("D")),
                     module: try M17Module("Z")),
            .acknowledge,
            .negativeAcknowledge,
            .ping(from: try reflectorAddress()),
            .pong(from: try clientAddress()),
            .disconnect(from: try clientAddress()),
            .disconnect(from: nil),
        ]

        for packet in packets {
            let data = packet.data
            XCTAssertTrue(
                packet.magic.permittedLengths.contains(data.count),
                "\(packet.magic.rawValue) serialized to \(data.count) bytes")
            XCTAssertEqual(try M17ControlPacket.parse(data), packet, "round trip failed for \(packet)")
            // ...and through the demultiplexer, which is what the client uses.
            XCTAssertEqual(try M17ReflectorPacket.parse(data), .control(packet))
        }
    }

    func testStreamPacketRoundTrips() throws {
        let data = try fixture("reflector-stream.hex")
        let packet = try M17StreamPacket.parse(data)
        XCTAssertEqual(packet.data, data, "stream serialization is not the inverse of parsing")
        XCTAssertEqual(try M17StreamPacket.parse(packet.data), packet)
        XCTAssertEqual(try M17ReflectorPacket.parse(data), .stream(packet))
    }

    // MARK: - Stream header

    func testStreamHeaderFieldsMatchTheSpecificationLayout() throws {
        let packet = try M17StreamPacket.parse(fixture("reflector-stream.hex"))

        // Table 27, field by field.
        XCTAssertEqual(M17StreamPacket.byteCount, 56)          // 4+2+30+2+16+2
        XCTAssertEqual(M17StreamPacket.lichByteCount, 30)      // 240 bits
        XCTAssertEqual(M17StreamPacket.payloadByteCount, 16)   // 128 bits
        XCTAssertEqual(M17StreamPacket.metadataByteCount, 14)  // 112 bits

        XCTAssertEqual(packet.streamID, 0x1234)
        XCTAssertEqual(packet.destination.value, 0xFFFF_FFFF_FFFF)  // BROADCAST
        XCTAssertEqual(packet.source.callsign, "AB1CD")
        XCTAssertEqual(packet.type.rawValue, 0x0005)
        XCTAssertEqual(packet.metadata, Data(repeating: 0, count: 14))
        XCTAssertEqual(packet.lsfCRC, 0xABCD)
        XCTAssertEqual(packet.frameNumber, 0x0001)
        XCTAssertEqual(packet.payload, Data((0...15).map(UInt8.init)))
        XCTAssertEqual(packet.crc, 0xBEEF)
    }

    func testFrameNumberSplitsIntoSequenceAndLastFrameFlag() throws {
        // Table 27: "including the last frame indicator at (FN & 0x8000)".
        let base = try M17StreamPacket.parse(fixture("reflector-stream.hex"))
        XCTAssertFalse(base.isLastFrame)
        XCTAssertEqual(base.sequenceNumber, 1)

        var bytes = [UInt8](base.data)
        bytes[36] = 0x80  // set bit 15 of FN
        bytes[37] = 0x2A
        let last = try M17StreamPacket.parse(Data(bytes))
        XCTAssertTrue(last.isLastFrame)
        XCTAssertEqual(last.sequenceNumber, 0x2A)
    }

    func testTypeFieldBitAssignments() {
        // Part I Table 3.2, with byte 1 as the least significant byte.
        // bit 0 stream, bits 1-2 data type, bits 3-4 encryption,
        // bits 5-6 subtype, bits 7-10 CAN, bit 11 signed.
        let voice = M17StreamType(rawValue: 0b0000_0000_0000_0101)
        XCTAssertTrue(voice.isStreamMode)
        XCTAssertEqual(voice.dataType, .voice)
        XCTAssertFalse(voice.isEncrypted)
        XCTAssertEqual(voice.channelAccessNumber, 0)
        XCTAssertFalse(voice.isSignedStream)
        XCTAssertEqual(voice.playability, .playable)

        // CAN = 15, signed, voice+data, stream mode.
        let busy = M17StreamType(rawValue: 0b0000_1111_1000_0111)
        XCTAssertTrue(busy.isStreamMode)
        XCTAssertEqual(busy.dataType, .voiceAndData)
        XCTAssertEqual(busy.channelAccessNumber, 15)
        XCTAssertTrue(busy.isSignedStream)
        XCTAssertFalse(busy.isEncrypted)

        // Packet mode: bit 0 clear.
        XCTAssertEqual(M17StreamType(rawValue: 0b0000_0000_0000_0100).playability, .notStreamMode)
        // Stream mode, data type = data (01): nothing to play.
        XCTAssertEqual(M17StreamType(rawValue: 0b0000_0000_0000_0011).playability, .notVoice)
    }

    /// FR-2.5: encryption bits are parsed, never acted on.
    func testEncryptedStreamIsParsedButReportedUnplayable() throws {
        let packet = try M17StreamPacket.parse(fixture("reflector-stream-encrypted.hex"))

        XCTAssertEqual(packet.type.rawValue, 0x0015)
        XCTAssertTrue(packet.type.isEncrypted)
        XCTAssertEqual(packet.playability, .encrypted)
        XCTAssertFalse(packet.type.isPlayable)
        // The header still parses fully — refusing to play is a policy of the
        // layer above, not a parse failure.
        XCTAssertEqual(packet.source.callsign, "AB1CD")
        XCTAssertEqual(packet.streamID, 0x1234)
    }

    func testEveryNonZeroEncryptionTypeIsUnplayable() {
        // Part I Table 3.5: 00 none, 01 scrambler, 10 AES, 11 other/reserved.
        for encryptionType: UInt16 in 1...3 {
            let type = M17StreamType(rawValue: 0b101 | (encryptionType << 3))
            XCTAssertTrue(type.isEncrypted, "encryption type \(encryptionType) should read as encrypted")
            XCTAssertEqual(type.playability, .encrypted)
        }
        XCTAssertFalse(M17StreamType(rawValue: 0b101).isEncrypted)
    }

    // MARK: - Rejection

    func testMalformedFixturesAreAllRejected() throws {
        let datagrams = try FixtureLoader.datagrams("reflector-malformed.hex", in: Bundle.module)
        XCTAssertEqual(datagrams.count, 9, "fixture should hold nine bad datagrams")

        for (index, datagram) in datagrams.enumerated() {
            XCTAssertThrowsError(
                try M17ReflectorPacket.parse(datagram),
                "malformed datagram \(index + 1) (\(datagram.count) bytes) was accepted")
        }
    }

    func testTooShortForAMagicIsRejected() {
        for count in 0..<4 {
            XCTAssertThrowsError(try M17ReflectorPacket.parse(Data(repeating: 0x43, count: count))) { error in
                XCTAssertEqual(error as? M17PacketError, .tooShort(byteCount: count))
            }
        }
    }

    func testUnknownMagicIsRejected() {
        // "M17" without its trailing space is not the stream magic.
        let almost = Data([0x4D, 0x31, 0x37, 0x21] + [UInt8](repeating: 0, count: 52))
        XCTAssertNil(
            try? M17ReflectorPacket.parse(almost),
            "0x4D313721 must not be accepted as the stream magic")

        XCTAssertThrowsError(try M17ReflectorPacket.parse(Data("QSOX".utf8))) { error in
            XCTAssertEqual(error as? M17PacketError, .unknownMagic(Array("QSOX".utf8)))
        }
    }

    func testWrongLengthForAKnownMagicIsRejected() throws {
        // Every magic, tried at every length from 0 to 60 bytes: only the
        // lengths the specification permits may parse.
        for magic in M17PacketMagic.allCases {
            for length in 0...60 {
                var bytes = magic.bytes
                // Pad with 0x41 ('A') so a CONN of the right length has a
                // valid module byte and would otherwise succeed.
                bytes.append(contentsOf: [UInt8](repeating: 0x41, count: max(0, length - bytes.count)))
                let datagram = Data(bytes.prefix(length))
                let parsed = try? M17ReflectorPacket.parse(datagram)
                if magic.permittedLengths.contains(length) {
                    XCTAssertNotNil(parsed, "\(magic.rawValue) at \(length) bytes should parse")
                } else {
                    XCTAssertNil(parsed, "\(magic.rawValue) at \(length) bytes should be rejected")
                }
            }
        }
    }

    func testConnWithNonLetterModuleIsRejected() throws {
        var bytes = [UInt8](try fixture("reflector-conn.hex"))
        for bad: UInt8 in [0x00, 0x20, 0x40, 0x5B, 0x61, 0xFF] {
            bytes[10] = bad
            XCTAssertThrowsError(try M17ControlPacket.parse(Data(bytes))) { error in
                guard case M17PacketError.invalidModule = error else {
                    return XCTFail("expected .invalidModule for byte 0x\(String(bad, radix: 16))")
                }
            }
        }
    }

    func testControlParseRejectsAStreamDatagram() throws {
        // The control parser must not try to make sense of "M17 " framing.
        XCTAssertThrowsError(try M17ControlPacket.parse(fixture("reflector-stream.hex")))
    }

    func testStreamParseRejectsAControlDatagram() throws {
        XCTAssertThrowsError(try M17StreamPacket.parse(fixture("reflector-conn.hex")))
    }

    func testStreamPacketRejectsWrongSizedMetadataOrPayload() throws {
        let address = try clientAddress()
        XCTAssertThrowsError(
            try M17StreamPacket(
                streamID: 0, destination: address, source: address,
                type: M17StreamType(rawValue: 5), metadata: Data(repeating: 0, count: 13),
                lsfCRC: 0, frameNumber: 0, payload: Data(repeating: 0, count: 16), crc: 0))
        XCTAssertThrowsError(
            try M17StreamPacket(
                streamID: 0, destination: address, source: address,
                type: M17StreamType(rawValue: 5), metadata: Data(repeating: 0, count: 14),
                lsfCRC: 0, frameNumber: 0, payload: Data(repeating: 0, count: 15), crc: 0))
    }

    // MARK: - Error descriptions

    func testErrorsDescribeThemselvesUsefully() {
        XCTAssertTrue(M17PacketError.tooShort(byteCount: 2).description.contains("2 bytes"))
        XCTAssertTrue(
            M17PacketError.unknownMagic(Array("XMIT".utf8)).description.contains("XMIT"))
        XCTAssertTrue(
            M17PacketError.wrongLength(magic: "DISC", expected: [10, 4], actual: 7)
                .description.contains("10 or 4"))
    }
}
