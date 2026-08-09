// SPDX-License-Identifier: Apache-2.0

import XCTest
import TestSupport
@testable import IAX2Kit

final class InformationElementTests: XCTestCase {

    // MARK: - Round-trip, one of every implemented IE type

    /// One representative value per typed case in `InformationElement`
    /// (RFC 5456 §8.6 Table 1, every non-reserved id). 43 typed IEs.
    private static let allTypedSamples: [InformationElement] = [
        .calledNumber("12345"),
        .callingNumber("N0CALL"),
        .callingANI("5551234567"),
        .callingName("John Doe"),
        .calledContext("default"),
        .username("myuser"),
        .password(rawBytes: [0x70, 0x61, 0x73, 0x73]),
        .capability([.g711MuLaw, .gsmFullRate]),
        .format(.g711MuLaw),
        .language("en-US"),
        .version(0x0002),
        .adsicpe(0x0000),
        .dnid("5551234567"),
        .authMethods([.md5, .rsa]),
        .challenge("abc123challenge"),
        .md5Result("5f4dcc3b5aa765d61d8327deb882cf99"),
        .rsaResult("base64orwhatever=="),
        .apparentAddr(.ipv4(address: (192, 168, 1, 1), port: 4569)),
        .refresh(60),
        .dpStatus([.exists]),
        .callNo(42),
        .cause("Normal call clearing"),
        .iaxUnknown(0x22),
        .msgCount(MessageCount(old: 3, new: 5)),
        .autoAnswer,
        .musicOnHold("default"),
        .transferID(0xDEAD_BEEF),
        .rdnis("5559876543"),
        .datetime(PackedDateTime(yearOffsetFrom2000: 26, month: 8, day: 9, hour: 12, minute: 30, second: 15)),
        .callingPres(0x00),
        .callingTON(0x00),
        .callingTNS(.unknown),
        .samplingRate(8000),
        .causeCode(16),
        .encryption(rawBytes: [0x00, 0x01]),
        .codecPrefs("ulaw,gsm"),
        .rrJitter(120),
        .rrLoss(RRLoss(percent: 2, count: 45)),
        .rrPkts(1000),
        .rrDelay(50),
        .rrDropped(3),
        .rrOOO(1),
        .ospToken(blockIndex: 0, token: [0x01, 0x02, 0x03]),
    ]

    func testExactlyFortyThreeTypedCasesAreCovered() {
        // Guards against silently dropping a sample when the enum grows.
        XCTAssertEqual(Self.allTypedSamples.count, 43)
    }

    func testEachTypedIERoundTripsIndividually() throws {
        for sample in Self.allTypedSamples {
            let bytes = try sample.serialized()
            let parsed = try InformationElement.parseList(bytes)
            XCTAssertEqual(parsed, [sample], "round-trip mismatch for id 0x\(String(sample.id, radix: 16))")
        }
    }

    func testAllTypedIEsRoundTripAsOneList() throws {
        let bytes = try InformationElement.serialize(Self.allTypedSamples)
        let parsed = try InformationElement.parseList(bytes)
        XCTAssertEqual(parsed, Self.allTypedSamples)
    }

    // MARK: - Empty-data IEs

    func testEmptyDataIEsRoundTrip() throws {
        let samples: [InformationElement] = [
            .musicOnHold(""),
            .autoAnswer,
            .password(rawBytes: []),
            .encryption(rawBytes: []),
            .unknown(id: 0xC8, data: []),
            .calledNumber(""), // an empty UTF-8 string is legal data
        ]
        for sample in samples {
            let bytes = try sample.serialized()
            XCTAssertEqual(bytes.count, 2, "id 0x\(String(sample.id, radix: 16)) should encode as just the header")
            XCTAssertEqual(bytes[1], 0)
            let parsed = try InformationElement.parseList(bytes)
            XCTAssertEqual(parsed, [sample])
        }
    }

    func testAutoAnswerRejectsNonEmptyData() {
        // id 0x19, length 1 (should be 0)
        XCTAssertThrowsError(try InformationElement.parseList([0x19, 0x01, 0xFF])) { error in
            guard case InformationElementError.wrongWidth(let id, _, _, let actual) = error else {
                return XCTFail("expected wrongWidth, got \(error)")
            }
            XCTAssertEqual(id, 0x19)
            XCTAssertEqual(actual, 1)
        }
    }

    // MARK: - Maximum-length (255-byte) IEs

    func test255ByteStringIERoundTrips() throws {
        let longString = String(repeating: "A", count: 255)
        let sample = InformationElement.calledNumber(longString)
        let bytes = try sample.serialized()
        XCTAssertEqual(bytes.count, 257) // 2-byte header + 255 data
        XCTAssertEqual(bytes[1], 255)
        let parsed = try InformationElement.parseList(bytes)
        XCTAssertEqual(parsed, [sample])
    }

    func test255ByteUnknownIERoundTrips() throws {
        let data = (0..<255).map { UInt8($0 % 256) }
        let sample = InformationElement.unknown(id: 0x99, data: data)
        let bytes = try sample.serialized()
        XCTAssertEqual(bytes.count, 257)
        let parsed = try InformationElement.parseList(bytes)
        XCTAssertEqual(parsed, [sample])
    }

    func test255ByteRawBytesIERoundTrips() throws {
        let data = (0..<255).map { UInt8(255 - $0) }
        let sample = InformationElement.password(rawBytes: data)
        let bytes = try sample.serialized()
        XCTAssertEqual(bytes.count, 257)
        let parsed = try InformationElement.parseList(bytes)
        XCTAssertEqual(parsed, [sample])
    }

    func testOversizedDataThrowsOnSerialize() {
        let sample = InformationElement.unknown(id: 0x99, data: Array(repeating: 0, count: 256))
        XCTAssertThrowsError(try sample.serialized()) { error in
            guard case InformationElementError.dataTooLong(let id, let length) = error else {
                return XCTFail("expected dataTooLong, got \(error)")
            }
            XCTAssertEqual(id, 0x99)
            XCTAssertEqual(length, 256)
        }
    }

    // MARK: - Unknown IE passthrough

    func testUnknownIDPassesThroughByteIdentical() throws {
        // Includes RFC-reserved ids, which this parser does not model and
        // must therefore also treat as opaque/unknown.
        let unknownIDs: [UInt8] = [0x1d, 0x1e, 0x20, 0x25, 0x2c, 0x40, 0xFE]
        for id in unknownIDs {
            let originalBytes: [UInt8] = [id, 0x03, 0x11, 0x22, 0x33]
            let parsed = try InformationElement.parseList(originalBytes)
            XCTAssertEqual(parsed, [.unknown(id: id, data: [0x11, 0x22, 0x33])])
            let reserialized = try InformationElement.serialize(parsed)
            XCTAssertEqual(reserialized, originalBytes)
        }
    }

    func testMixedKnownAndUnknownListPreservesOrder() throws {
        let originalBytes: [UInt8] = [
            0x0b, 0x02, 0x00, 0x02, // VERSION (known)
            0x50, 0x02, 0xAA, 0xBB, // unknown id 0x50
            0x06, 0x03, 0x41, 0x42, 0x43, // USERNAME "ABC" (known)
            0x51, 0x00, // unknown id 0x51, zero-length
            0x1d, 0x01, 0x99, // reserved id 0x1d -> unknown
        ]
        let parsed = try InformationElement.parseList(originalBytes)
        XCTAssertEqual(parsed, [
            .version(0x0002),
            .unknown(id: 0x50, data: [0xAA, 0xBB]),
            .username("ABC"),
            .unknown(id: 0x51, data: []),
            .unknown(id: 0x1d, data: [0x99]),
        ])
        let reserialized = try InformationElement.serialize(parsed)
        XCTAssertEqual(reserialized, originalBytes)
    }

    // MARK: - Truncation

    func testTruncatedHeaderAtEveryPlausiblePoint() {
        // A single dangling byte (no room for the length octet).
        XCTAssertThrowsError(try InformationElement.parseList([0x06])) { error in
            XCTAssertEqual(error as? InformationElementError, .truncatedHeader(offset: 0))
        }

        // A complete first IE followed by a single dangling byte.
        let oneCompleteThenDangling: [UInt8] = [0x06, 0x01, 0x41, 0x08]
        XCTAssertThrowsError(try InformationElement.parseList(oneCompleteThenDangling)) { error in
            XCTAssertEqual(error as? InformationElementError, .truncatedHeader(offset: 3))
        }

        // Empty buffer is not truncated -- it's just an empty IE list.
        XCTAssertNoThrow(try InformationElement.parseList([]))
    }

    func testTruncatedDataAtEveryPlausiblePoint() {
        // Declares 4 bytes of data, supplies 0, 1, 2, 3.
        for suppliedCount in 0...3 {
            let bytes: [UInt8] = [0x08, 0x04] + Array(repeating: 0xFF, count: suppliedCount)
            XCTAssertThrowsError(try InformationElement.parseList(bytes), "should throw with \(suppliedCount) of 4 bytes supplied") { error in
                guard case InformationElementError.truncatedData(let id, let offset, let declaredLength, let available) = error else {
                    return XCTFail("expected truncatedData, got \(error)")
                }
                XCTAssertEqual(id, 0x08)
                XCTAssertEqual(offset, 0)
                XCTAssertEqual(declaredLength, 4)
                XCTAssertEqual(available, suppliedCount)
            }
        }
    }

    func testDeclaredLengthOverrunsBufferThrows() {
        // Declares 255 bytes of data but the buffer only has 2 bytes total.
        let bytes: [UInt8] = [0x01, 0xFF, 0x41, 0x42]
        XCTAssertThrowsError(try InformationElement.parseList(bytes)) { error in
            guard case InformationElementError.truncatedData(let id, _, let declaredLength, let available) = error else {
                return XCTFail("expected truncatedData, got \(error)")
            }
            XCTAssertEqual(id, 0x01)
            XCTAssertEqual(declaredLength, 255)
            XCTAssertEqual(available, 2)
        }
    }

    // MARK: - Wrong-width known IEs

    func testKnownFixedWidthIEWrongWidthThrows() {
        // VERSION (0x0b) documented as 2 octets; supply 1 and 3.
        for badLength: UInt8 in [1, 3] {
            let bytes: [UInt8] = [0x0b, badLength] + Array(repeating: 0, count: Int(badLength))
            XCTAssertThrowsError(try InformationElement.parseList(bytes)) { error in
                guard case InformationElementError.wrongWidth(let id, let name, _, let actual) = error else {
                    return XCTFail("expected wrongWidth, got \(error)")
                }
                XCTAssertEqual(id, 0x0b)
                XCTAssertEqual(name, "VERSION")
                XCTAssertEqual(actual, Int(badLength))
            }
        }
    }

    func testInvalidUTF8InKnownStringIEThrows() {
        // 0xFF, 0xFE is not valid UTF-8.
        let bytes: [UInt8] = [0x06, 0x02, 0xFF, 0xFE]
        XCTAssertThrowsError(try InformationElement.parseList(bytes)) { error in
            guard case InformationElementError.invalidUTF8(let id, let name) = error else {
                return XCTFail("expected invalidUTF8, got \(error)")
            }
            XCTAssertEqual(id, 0x06)
            XCTAssertEqual(name, "USERNAME")
        }
    }

    func testApparentAddrRejectsUnrecognisedLength() {
        let bytes: [UInt8] = [0x12, 0x05, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try InformationElement.parseList(bytes)) { error in
            guard case InformationElementError.wrongWidth(let id, let name, _, let actual) = error else {
                return XCTFail("expected wrongWidth, got \(error)")
            }
            XCTAssertEqual(id, 0x12)
            XCTAssertEqual(name, "APPARENT_ADDR")
            XCTAssertEqual(actual, 5)
        }
    }

    // MARK: - APPARENT ADDR byte-order tolerance (notes §7 / trap 13)

    func testApparentAddrIPv4RoundTripsAndExposesBothFamilyReadings() throws {
        // RFC 5456 §8.6.17's own worked example: family bytes 0x02,0x00,
        // port bytes 0x11,0xd9 (= 4569 big-endian), then a 4-octet address
        // and 8 octets of padding.
        let data: [UInt8] = [0x02, 0x00, 0x11, 0xD9, 10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        let bytes: [UInt8] = [0x12, UInt8(data.count)] + data
        let parsed = try InformationElement.parseList(bytes)
        guard case .apparentAddr(let addr) = parsed[0] else {
            return XCTFail("expected apparentAddr")
        }
        XCTAssertEqual(addr.port, 4569, "port is unambiguously big-endian per the RFC's own example")
        XCTAssertEqual(addr.familyAsLittleEndian, ApparentAddress.addressFamilyINET, "little-endian reading matches AF_INET, per the sockaddr_in theory")
        XCTAssertEqual(addr.familyAsBigEndian, 0x0200, "big-endian reading is exposed too -- we do not discard it")
        XCTAssertEqual(addr.addressBytes, [10, 0, 0, 1])
        XCTAssertFalse(addr.isIPv6Layout)

        // Round-trips byte-identical regardless of which family reading is "right".
        let reserialized = try InformationElement.serialize(parsed)
        XCTAssertEqual(reserialized, bytes)
    }

    func testApparentAddrIPv6RoundTrips() throws {
        var data: [UInt8] = [0x0A, 0x00, 0x11, 0xD9] // family (LE AF_INET6=10), port 4569
        data += [0, 0, 0, 0] // flow info
        data += Array(repeating: 0, count: 15) + [1] // ::1
        data += [0, 0, 0, 0] // scope id
        XCTAssertEqual(data.count, 28)
        let bytes: [UInt8] = [0x12, UInt8(data.count)] + data
        let parsed = try InformationElement.parseList(bytes)
        guard case .apparentAddr(let addr) = parsed[0] else {
            return XCTFail("expected apparentAddr")
        }
        XCTAssertTrue(addr.isIPv6Layout)
        XCTAssertEqual(addr.addressBytes.count, 16)
        XCTAssertEqual(addr.familyAsLittleEndian, ApparentAddress.addressFamilyINET6)
        let reserialized = try InformationElement.serialize(parsed)
        XCTAssertEqual(reserialized, bytes)
    }

    // MARK: - Hand-built NEW payload fixture

    func testNewFramePayloadFixtureParsesToExpectedIEs() throws {
        let bytes = Array(try FixtureLoader.datagram("ie-new-payload.hex", in: Bundle.module))
        let parsed = try InformationElement.parseList(bytes)
        XCTAssertEqual(parsed, [
            .version(0x0002),
            .calledNumber("55553"),
            .username("KC1ABC"),
            .capability([.gsmFullRate, .g711MuLaw]),
            .format(.g711MuLaw),
        ])
        // VERSION MUST be the first IE on NEW (§8.6.10).
        XCTAssertEqual(parsed.first?.id, 0x0b)
    }

    // MARK: - Media format bitmask (RFC 5456 §8.7, notes §8)

    func testGDotSevenElevenMuLawIsBitTwo() {
        XCTAssertEqual(MediaFormat.g711MuLaw.rawValue, 0x0000_0004)
    }

    func testMediaFormatSetOperations() {
        let voiceCodecs: MediaFormat = [.g711MuLaw, .gsmFullRate, .g729]
        XCTAssertTrue(voiceCodecs.contains(.g711MuLaw))
        XCTAssertTrue(voiceCodecs.contains(.gsmFullRate))
        XCTAssertFalse(voiceCodecs.contains(.h264))

        let union = voiceCodecs.union(.h264)
        XCTAssertTrue(union.contains(.h264))
        XCTAssertTrue(union.contains(.g711MuLaw))

        let intersection = voiceCodecs.intersection([.g711MuLaw, .h264])
        XCTAssertEqual(intersection, [.g711MuLaw])

        var mutable: MediaFormat = [.g711MuLaw]
        mutable.insert(.g711ALaw)
        XCTAssertEqual(mutable.rawValue, 0x0000_0004 | 0x0000_0008)
        mutable.remove(.g711MuLaw)
        XCTAssertEqual(mutable, [.g711ALaw])

        XCTAssertEqual(MediaFormat.gsmFullRate.rawValue, 1 << 1)
        XCTAssertEqual(MediaFormat.g729.rawValue, 1 << 8)
        XCTAssertEqual(MediaFormat.h264.rawValue, 1 << 21)
    }

    func testCapabilityAndFormatIEsCarryTheBitmaskCorrectly() throws {
        let capability = InformationElement.capability([.g711MuLaw, .gsmFullRate, .g729])
        let bytes = try capability.serialized()
        // 0x00000004 (mu-law) | 0x00000002 (GSM) | 0x00000100 (G.729) = 0x00000106
        XCTAssertEqual(bytes, [0x08, 0x04, 0x00, 0x00, 0x01, 0x06])
    }

    // MARK: - Integer IEs at extremes

    func testUInt8IEsRoundTripAtExtremes() throws {
        for value: UInt8 in [0x00, 0xFF] {
            for sample in [InformationElement.callingPres(value), .callingTON(value), .causeCode(value), .iaxUnknown(value)] {
                let bytes = try sample.serialized()
                let parsed = try InformationElement.parseList(bytes)
                XCTAssertEqual(parsed, [sample])
            }
        }
    }

    func testUInt16IEsRoundTripAtExtremes() throws {
        for value: UInt16 in [0x0000, 0xFFFF] {
            let samples: [InformationElement] = [
                .version(value), .adsicpe(value), .refresh(value), .callNo(value), .samplingRate(value), .rrDelay(value),
            ]
            for sample in samples {
                let bytes = try sample.serialized()
                let parsed = try InformationElement.parseList(bytes)
                XCTAssertEqual(parsed, [sample])
            }
        }
    }

    func testUInt32IEsRoundTripAtExtremes() throws {
        for value: UInt32 in [0x0000_0000, 0xFFFF_FFFF] {
            let samples: [InformationElement] = [
                .transferID(value), .rrJitter(value), .rrPkts(value), .rrDropped(value), .rrOOO(value),
            ]
            for sample in samples {
                let bytes = try sample.serialized()
                let parsed = try InformationElement.parseList(bytes)
                XCTAssertEqual(parsed, [sample])
            }
        }
    }

    func testMediaFormatBitmaskIEsRoundTripAtExtremes() throws {
        for raw: UInt32 in [0x0000_0000, 0xFFFF_FFFF] {
            for sample in [InformationElement.capability(MediaFormat(rawValue: raw)), .format(MediaFormat(rawValue: raw))] {
                let bytes = try sample.serialized()
                let parsed = try InformationElement.parseList(bytes)
                XCTAssertEqual(parsed, [sample])
            }
        }
    }

    func testPackedDateTimeRoundTripsThroughRawValue() {
        let dt = PackedDateTime(yearOffsetFrom2000: 26, month: 8, day: 9, hour: 23, minute: 59, second: 31)
        let restored = PackedDateTime(rawValue: dt.rawValue)
        XCTAssertEqual(dt, restored)
    }

    // MARK: - PASSWORD dead id

    func testPasswordIDRoundTripsAsRawBytesOnly() throws {
        // Preserved for interop, never a decoded string -- see the doc
        // comment on `InformationElement.password`.
        let sample = InformationElement.password(rawBytes: [0x73, 0x65, 0x63, 0x72, 0x65, 0x74])
        let bytes = try sample.serialized()
        XCTAssertEqual(bytes, [0x07, 0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74])
        let parsed = try InformationElement.parseList(bytes)
        XCTAssertEqual(parsed, [sample])
    }

    // MARK: - Convenience lookup

    func testFirstWithIDConvenience() {
        let list: [InformationElement] = [.version(2), .username("x"), .format(.g711MuLaw)]
        XCTAssertEqual(list.first(withID: 0x09), .format(.g711MuLaw))
        XCTAssertNil(list.first(withID: 0xEE))
    }
}
