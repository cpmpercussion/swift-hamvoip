// SPDX-License-Identifier: Apache-2.0

import Foundation
import TestSupport
import XCTest

@testable import IAX2Kit

/// IAX-1 — RFC 5456 §8.1 frame model.
///
/// Section references are to RFC 5456 throughout; "notes §n" refers to
/// `docs/reference/RFC5456-NOTES.md`.
final class IAX2FrameTests: XCTestCase {

    // MARK: - Fixtures parsed field by field
    //
    // These are the tests that catch a systematic misreading of the header
    // layout. A round-trip test would pass even if every field were in the
    // wrong place, as long as encode and parse agreed with each other.

    /// `frame-new.hex`: an IAX NEW as a Full Frame (§8.1.1, §8.2, §8.4, §6.2.2).
    func testNewFullFrameFixtureParsesFieldByField() throws {
        let data = try FixtureLoader.datagram("frame-new.hex", in: Bundle.module)
        XCTAssertEqual(data.count, 23, "12-octet header (§8.1.1) + 11 octets of IEs")

        guard case .full(let frame) = try IAX2Frame.parse(data) else {
            return XCTFail("F = 1 must select the Full Frame layout (§8.1.1)")
        }

        XCTAssertEqual(frame.sourceCallNumber, 1, "octets 0–1 & 0x7FFF (§8.1.1)")
        XCTAssertEqual(frame.destinationCallNumber, 0, "a NEW has no destination call number (§6.2.2)")
        XCTAssertFalse(frame.isRetransmission, "R = 0 on first transmission (§8.1.1)")
        XCTAssertEqual(frame.timestamp, 0, "the call clock begins at zero (§6.2.2)")
        XCTAssertEqual(frame.oSeqno, 0, "both counters start at zero (§7)")
        XCTAssertEqual(frame.iSeqno, 0, "both counters start at zero (§7)")
        XCTAssertEqual(frame.type, .iax, "frame type 0x06 (§8.2)")
        XCTAssertEqual(frame.type.rawValue, 0x06)
        XCTAssertEqual(frame.subclass.rawByte, 0x01)
        XCTAssertFalse(frame.subclass.isPowerEncoded, "C = 0 for an ordinal subclass (§8.1.1)")
        XCTAssertEqual(frame.subclass.value, 1)
        XCTAssertEqual(frame.iaxMessage, .new, "IAX subclass 0x01 = NEW (§8.4)")
        XCTAssertNil(frame.control, "a type 0x06 frame carries no control subclass (§8.3)")
        XCTAssertNil(frame.mediaFormat, "a type 0x06 frame carries no media format (§8.7)")

        // The IE block stays opaque here; IAX-2 owns §8.6 parsing.
        XCTAssertEqual(
            frame.payload,
            [0x0b, 0x02, 0x00, 0x02, 0x01, 0x05, 0x35, 0x35, 0x35, 0x35, 0x33],
            "VERSION IE first (§8.6.10, §6.2.2), then CALLED NUMBER (§8.6.1)")

        XCTAssertEqual(IAX2Frame.full(frame).encoded(), data, "re-encoding must be byte-identical")
    }

    /// `frame-mini.hex`: a voice Mini Frame (§8.1.2).
    func testMiniFrameFixtureParsesFieldByField() throws {
        let data = try FixtureLoader.datagram("frame-mini.hex", in: Bundle.module)
        XCTAssertEqual(data.count, 12, "4-octet header (§8.1.2) + 8 octets of media")

        guard case .mini(let frame) = try IAX2Frame.parse(data) else {
            return XCTFail("F = 0 with a nonzero first word must select the Mini Frame layout")
        }

        XCTAssertEqual(frame.sourceCallNumber, 0x1234, "octets 0–1 & 0x7FFF (§8.1.2)")
        XCTAssertEqual(frame.timestamp, 0x0BB8, "16-bit time-stamp, octets 2–3 (§8.1.2)")
        XCTAssertEqual(frame.payload, [0xff, 0xff, 0xff, 0xff, 0x7f, 0x7f, 0x7f, 0x7f])
        XCTAssertEqual(IAX2Frame.mini(frame).encoded(), data)

        // A 12-octet datagram is exactly the length of a Full Frame header.
        // Only the F bit decides which layout applies, not the length.
        XCTAssertEqual(data.count, IAX2FullFrame.headerLength)
    }

    /// `frame-voice-ulaw.hex`: a full Voice frame whose subclass octet is `0x82`
    /// (§8.1.1 C bit, §8.7 µ-law = `1 << 2`). This is the case notes §6 and
    /// trap 3 single out as the easiest to get wrong.
    func testVoiceMuLawFixtureParsesFieldByField() throws {
        let data = try FixtureLoader.datagram("frame-voice-ulaw.hex", in: Bundle.module)
        XCTAssertEqual(data.count, 16)

        guard case .full(let frame) = try IAX2Frame.parse(data) else {
            return XCTFail("F = 1 must select the Full Frame layout (§8.1.1)")
        }

        XCTAssertEqual(frame.sourceCallNumber, 0x1234)
        XCTAssertEqual(frame.destinationCallNumber, 0x0567)
        XCTAssertFalse(frame.isRetransmission)
        XCTAssertEqual(frame.timestamp, 3000, "0x00000BB8 ms since first transmission (§8.1.1)")
        XCTAssertEqual(frame.oSeqno, 2)
        XCTAssertEqual(frame.iSeqno, 3)
        XCTAssertEqual(frame.type, .voice, "frame type 0x02 (§8.2)")

        // The whole point of the fixture.
        XCTAssertEqual(frame.subclass.rawByte, 0x82)
        XCTAssertTrue(frame.subclass.isPowerEncoded, "C = 1 (§8.1.1)")
        XCTAssertEqual(frame.subclass.field, 2, "the 7-bit field is the exponent, not the value")
        XCTAssertEqual(frame.subclass.value, 4, "1 << 2 = 0x00000004 = G.711 µ-law (§8.7)")
        XCTAssertEqual(frame.mediaFormat, 0x0000_0004)

        XCTAssertNil(frame.iaxMessage, "a Voice frame has no IAX subclass (§8.4)")
        XCTAssertEqual(frame.payload, [0xff, 0xff, 0xff, 0xff])
        XCTAssertEqual(IAX2Frame.full(frame).encoded(), data)
    }

    /// `frame-ack-retransmit.hex`: the R bit is a flag, not the top bit of the
    /// destination call number (§8.1.1; notes trap 1).
    func testRetransmittedAckFixtureParsesFieldByField() throws {
        let data = try FixtureLoader.datagram("frame-ack-retransmit.hex", in: Bundle.module)
        XCTAssertEqual(data.count, 12, "an ACK carries no IEs (§6.9.1)")

        guard case .full(let frame) = try IAX2Frame.parse(data) else {
            return XCTFail("F = 1 must select the Full Frame layout (§8.1.1)")
        }

        XCTAssertEqual(frame.sourceCallNumber, 0x0567)
        XCTAssertTrue(frame.isRetransmission, "octet 2 bit 0 is set (§8.1.1)")
        XCTAssertEqual(
            frame.destinationCallNumber, 0x1234,
            "0x9234 & 0x7FFF — masking with 0xFFFF would give 37428 (notes trap 1)")
        XCTAssertEqual(frame.timestamp, 3000, "an ACK echoes the time-stamp it received (§6.9.1)")
        XCTAssertEqual(frame.oSeqno, 1, "an ACK does not advance OSeqno (§7)")
        XCTAssertEqual(frame.iSeqno, 1)
        XCTAssertEqual(frame.type, .iax)
        XCTAssertEqual(frame.iaxMessage, .ack, "IAX subclass 0x04 = ACK (§8.4)")
        XCTAssertTrue(frame.payload.isEmpty)
        XCTAssertEqual(IAX2Frame.full(frame).encoded(), data)
    }

    // MARK: - The F bit (§8.1.1, §8.1.2)

    /// The same twelve octets are a Full Frame or a Mini Frame depending on one
    /// bit. Nothing else — not the length — makes that decision.
    func testFBitAloneSelectsTheFrameLayout() throws {
        let miniOctets: [UInt8] = [0x12, 0x34, 0x0b, 0xb8, 0xff, 0xff, 0xff, 0xff, 0x7f, 0x7f, 0x7f, 0x7f]
        var fullOctets = miniOctets
        fullOctets[0] |= 0x80  // set F

        guard case .mini(let mini) = try IAX2Frame.parse(Data(miniOctets)) else {
            return XCTFail("F = 0 is a Mini Frame (§8.1.2)")
        }
        XCTAssertEqual(mini.sourceCallNumber, 0x1234)
        XCTAssertEqual(mini.timestamp, 0x0BB8)
        XCTAssertEqual(mini.payload.count, 8)

        guard case .full(let full) = try IAX2Frame.parse(Data(fullOctets)) else {
            return XCTFail("F = 1 is a Full Frame (§8.1.1)")
        }
        XCTAssertEqual(full.sourceCallNumber, 0x1234, "F is not part of the source call number")
        XCTAssertEqual(full.destinationCallNumber, 0x0BB8)
        XCTAssertEqual(full.timestamp, 0xFFFF_FFFF)
        XCTAssertEqual(full.oSeqno, 0x7f)
        XCTAssertEqual(full.iSeqno, 0x7f)
        XCTAssertEqual(full.type, .unknown(0x7f))
        XCTAssertEqual(full.subclass.rawByte, 0x7f)
        XCTAssertTrue(full.payload.isEmpty)
    }

    /// Encoding always sets F for a Full Frame and clears it for a Mini Frame,
    /// whatever the call number is.
    func testFBitIsWrittenIndependentlyOfTheCallNumber() {
        for callNumber: UInt16 in [1, 0x00FF, 0x0100, 0x7FFF] {
            let full = IAX2Frame.full(
                IAX2FullFrame(
                    sourceCallNumber: callNumber, destinationCallNumber: 0, timestamp: 0,
                    oSeqno: 0, iSeqno: 0, type: .iax, subclass: IAX2Subclass(.new)))
            let mini = IAX2Frame.mini(
                IAX2MiniFrame(sourceCallNumber: callNumber, timestamp: 0))

            XCTAssertEqual(full.encoded()[0] & 0x80, 0x80, "Full Frame: F = 1 (§8.1.1)")
            XCTAssertEqual(mini.encoded()[0] & 0x80, 0x00, "Mini Frame: F = 0 (§8.1.2)")
            XCTAssertEqual(UInt16(full.encoded()[0] & 0x7F) << 8 | UInt16(full.encoded()[1]), callNumber)
            XCTAssertEqual(UInt16(mini.encoded()[0] & 0x7F) << 8 | UInt16(mini.encoded()[1]), callNumber)
        }
    }

    // MARK: - The R bit (§8.1.1)

    /// R changes nothing but itself: the destination call number underneath is
    /// unaffected in both directions.
    func testRBitIsIndependentOfTheDestinationCallNumber() throws {
        for destination: UInt16 in [0, 1, 0x0567, 0x1234, 0x7FFF] {
            let first = IAX2FullFrame(
                sourceCallNumber: 1, destinationCallNumber: destination,
                isRetransmission: false, timestamp: 0, oSeqno: 0, iSeqno: 0,
                type: .iax, subclass: IAX2Subclass(.ack))
            let again = first.retransmitted()

            XCTAssertFalse(first.isRetransmission)
            XCTAssertTrue(again.isRetransmission, "R = 1 on a retransmission (§8.1.1)")
            XCTAssertEqual(again.destinationCallNumber, destination)
            XCTAssertEqual(again.oSeqno, first.oSeqno, "a retransmission reuses OSeqno (§7, §8.1.1)")
            XCTAssertEqual(again.timestamp, first.timestamp, "and reuses the time-stamp")

            let firstBytes = [UInt8](IAX2Frame.full(first).encoded())
            let againBytes = [UInt8](IAX2Frame.full(again).encoded())
            XCTAssertEqual(againBytes[2], firstBytes[2] | 0x80, "R is octet 2 bit 0")
            XCTAssertEqual(againBytes[3], firstBytes[3])
            XCTAssertEqual(Array(againBytes[4...]), Array(firstBytes[4...]))

            guard case .full(let reparsed) = try IAX2Frame.parse(Data(againBytes)) else {
                return XCTFail("expected a Full Frame")
            }
            XCTAssertEqual(reparsed, again)
        }
    }

    // MARK: - The C bit (§8.1.1)

    /// Decoding: `C = 0` means the field is the value; `C = 1` means the field
    /// is a base-2 exponent.
    func testCBitDecoding() {
        // (subclass octet, C, field, decoded value)
        let cases: [(UInt8, Bool, UInt8, UInt32?)] = [
            (0x00, false, 0, 0),  // Text frames always have subclass 0 (§8.2.7)
            (0x01, false, 1, 1),  // IAX NEW (§8.4)
            (0x04, false, 4, 4),  // Control Answer (§8.3) — and the other legal µ-law form
            (0x1E, false, 30, 30),  // IAX POKE (§8.4)
            (0x22, false, 34, 34),  // IAX TRANSFER (§8.4)
            (0x7E, false, 126, 126),
            (0x7F, false, 127, 127),  // the last value expressible with C = 0
            (0x80, true, 0, 1),  // the first value expressible with C = 1
            (0x81, true, 1, 2),  // Voice GSM (§8.7)
            (0x82, true, 2, 4),  // Voice G.711 µ-law (§8.7)
            (0x88, true, 8, 256),  // Voice G.729 (§8.7)
            (0x95, true, 21, 0x0020_0000),  // Video H.264 (§8.7)
            (0x9F, true, 31, 0x8000_0000),  // the largest that fits the 32-bit §8.7 domain
            (0xA0, true, 32, nil),  // 1 << 32 does not fit a §8.7 bitmask
            (0xFF, true, 127, nil),
        ]
        for (octet, expectedC, expectedField, expectedValue) in cases {
            let subclass = IAX2Subclass(rawByte: octet)
            XCTAssertEqual(subclass.isPowerEncoded, expectedC, "C bit of 0x\(hex(octet))")
            XCTAssertEqual(subclass.field, expectedField, "field of 0x\(hex(octet))")
            XCTAssertEqual(subclass.value, expectedValue, "value of 0x\(hex(octet))")
        }
    }

    /// Encoding with the general rule: ≤ 127 goes out as a plain integer,
    /// anything larger must be an exact power of two.
    func testCBitEncodingWithTheGeneralRule() {
        let representable: [(UInt32, UInt8)] = [
            (0, 0x00),
            (1, 0x01),
            (4, 0x04),  // ≤ 127, so C = 0 even though it is a power of two
            (30, 0x1E),
            (34, 0x22),
            (126, 0x7E),
            (127, 0x7F),  // last C = 0 value
            (128, 0x87),  // first value that must use C = 1: 1 << 7
            (256, 0x88),
            (0x0020_0000, 0x95),
            (0x8000_0000, 0x9F),
        ]
        for (value, expected) in representable {
            XCTAssertEqual(
                IAX2Subclass(value: value)?.rawByte, expected,
                "encoding subclass value \(value)")
        }

        // Above 127 and not a power of two: no subclass field can carry it.
        for value: UInt32 in [128 + 1, 129, 200, 255, 300, 0x0000_0006, 0xFFFF_FFFF] where value > 127 {
            if value.nonzeroBitCount == 1 { continue }
            XCTAssertNil(IAX2Subclass(value: value), "\(value) is not representable (§8.1.1)")
        }
    }

    /// Media formats always go out with `C = 1`, which is what makes µ-law
    /// `0x82` rather than `0x04` (notes §6 encoding convention, §8.7).
    func testCBitEncodingForMediaFormats() {
        XCTAssertEqual(IAX2Subclass(mediaFormat: 0x0000_0002)?.rawByte, 0x81, "GSM")
        XCTAssertEqual(IAX2Subclass(mediaFormat: 0x0000_0004)?.rawByte, 0x82, "G.711 µ-law")
        XCTAssertEqual(IAX2Subclass(mediaFormat: 0x0000_0008)?.rawByte, 0x83, "G.711 a-law")
        XCTAssertEqual(IAX2Subclass(mediaFormat: 0x0000_0100)?.rawByte, 0x88, "G.729")
        XCTAssertEqual(IAX2Subclass(mediaFormat: 0x0020_0000)?.rawByte, 0x95, "H.264")

        // "Only one CODEC MUST be specified" (§8.6.8) — and with C = 1 a
        // subclass field can only ever name one.
        XCTAssertNil(IAX2Subclass(mediaFormat: 0x0000_0006), "µ-law | GSM is not one codec")
        XCTAssertNil(IAX2Subclass(mediaFormat: 0))
    }

    /// RFC ambiguous (notes §6): a value that is both ≤ 127 and a power of two
    /// has two legal encodings and the RFC does not say which a sender MUST
    /// use, so a decoder MUST accept both.
    func testCBitOverlapIsAcceptedInBothForms() {
        for exponent in 0...6 {  // 1, 2, 4, 8, 16, 32, 64 — all ≤ 127
            let value = UInt32(1) << UInt32(exponent)
            let cClear = IAX2Subclass(rawByte: UInt8(value))
            let cSet = IAX2Subclass.powerOfTwo(exponent: UInt8(exponent))
            XCTAssertNotEqual(cClear.rawByte, cSet.rawByte, "different octets on the wire")
            XCTAssertEqual(cClear.value, value)
            XCTAssertEqual(cSet.value, value, "both forms decode to the same subclass value")
        }

        // Concretely, for the codec we actually use.
        let asOrdinal = IAX2FullFrame(
            sourceCallNumber: 1, destinationCallNumber: 2, timestamp: 0, oSeqno: 0, iSeqno: 0,
            type: .voice, subclass: IAX2Subclass(rawByte: 0x04))
        let asPower = IAX2FullFrame(
            sourceCallNumber: 1, destinationCallNumber: 2, timestamp: 0, oSeqno: 0, iSeqno: 0,
            type: .voice, subclass: IAX2Subclass(rawByte: 0x82))
        XCTAssertEqual(asOrdinal.mediaFormat, 4)
        XCTAssertEqual(asPower.mediaFormat, 4)
        XCTAssertNotEqual(asOrdinal, asPower, "but the frames are not byte-identical")
    }

    /// The C bit survives a round trip on both sides of the boundary, for every
    /// possible subclass octet.
    func testEverySubclassOctetRoundTrips() throws {
        for raw in UInt8.min...UInt8.max {
            let frame = IAX2Frame.full(
                IAX2FullFrame(
                    sourceCallNumber: 1, destinationCallNumber: 2, timestamp: 0,
                    oSeqno: 0, iSeqno: 0, type: .voice, subclass: IAX2Subclass(rawByte: raw)))
            let data = frame.encoded()
            XCTAssertEqual(data[11], raw, "the subclass is octet 11 (§8.1.1)")
            XCTAssertEqual(try IAX2Frame.parse(data), frame)
        }
    }

    // MARK: - Meta frames (§8.1.3)

    /// The meta test comes before the F-bit test, so a meta frame is never
    /// mistaken for a mini frame (notes trap 17).
    func testMetaFramesAreRejectedWithTheMetaFrameError() {
        let metaDatagrams: [(String, [UInt8])] = [
            ("bare meta indicator", [0x00, 0x00]),
            // Meta video (§8.1.3.1): V = 1 then a 15-bit source call number.
            ("meta video", [0x00, 0x00, 0x80, 0x01, 0x0b, 0xb8, 0xff, 0xff]),
            // Meta trunk (§8.1.3.2): V = 0, meta command 1, cmd data, 32-bit ts.
            ("meta trunk, no per-call time-stamps", [0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0b, 0xb8]),
            ("meta trunk, per-call time-stamps", [0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x0b, 0xb8]),
            // "All other values are reserved for future use" (§8.1.3.2) — still meta.
            ("meta trunk, reserved command", [0x00, 0x00, 0x7f, 0xff, 0x00, 0x00, 0x00, 0x00]),
            ("meta with a full-frame-length body", [UInt8](repeating: 0, count: 32)),
        ]

        for (name, octets) in metaDatagrams {
            XCTAssertThrowsError(try IAX2Frame.parse(Data(octets)), name) { error in
                XCTAssertEqual(
                    error as? IAX2FrameError, .metaFrame,
                    "\(name) must be distinguishable from every other failure")
            }
        }
    }

    /// This is the reason source call number 0 is never allocated (notes §15):
    /// a Mini Frame carrying it would be read back as a Meta Frame.
    func testAMiniFrameWithSourceCallNumberZeroWouldReadAsMeta() {
        let octets: [UInt8] = [0x00, 0x00, 0x0b, 0xb8, 0xff, 0xff]
        XCTAssertThrowsError(try IAX2Frame.parse(Data(octets))) { error in
            XCTAssertEqual(error as? IAX2FrameError, .metaFrame)
        }
        // A Full Frame with source call number 0 is not ambiguous — F = 1 makes
        // the first word nonzero — so it parses normally.
        var asFullFrame: [UInt8] = [0x80, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0x06, 0x01]
        asFullFrame.append(contentsOf: [0xaa])
        XCTAssertNoThrow(try IAX2Frame.parse(Data(asFullFrame)))
    }

    // MARK: - Truncation

    /// Every prefix shorter than the header the frame's own first octets imply
    /// must throw, never trap and never read past the end of the buffer.
    func testTruncatedInputThrowsAtEveryLength() throws {
        let fixtures = [
            "frame-new.hex", "frame-mini.hex", "frame-voice-ulaw.hex", "frame-ack-retransmit.hex",
        ]
        for name in fixtures {
            let data = try FixtureLoader.datagram(name, in: Bundle.module)
            let headerLength = (data[data.startIndex] & 0x80) != 0
                ? IAX2FullFrame.headerLength : IAX2MiniFrame.headerLength

            for length in 0..<headerLength {
                let truncated = data.prefix(length)
                XCTAssertThrowsError(try IAX2Frame.parse(truncated), "\(name) truncated to \(length)") {
                    error in
                    guard case .tooShort(let expected, let actual)? = error as? IAX2FrameError else {
                        return XCTFail("\(name)@\(length): expected .tooShort, got \(error)")
                    }
                    XCTAssertEqual(actual, length)
                    XCTAssertGreaterThan(expected, actual)
                }
            }

            // The header length itself is enough.
            XCTAssertNoThrow(try IAX2Frame.parse(data.prefix(headerLength)))
        }
    }

    /// Truncation of an arbitrary frame at an arbitrary point never traps —
    /// it either parses (payloads may be any length) or throws.
    func testTruncationOfArbitraryFramesNeverTraps() {
        var rng = SplitMix64(seed: 0x1AC1_F0A1_5EED_0001)
        for _ in 0..<2_000 {
            let length = Int.random(in: 0...40, using: &rng)
            let octets = (0..<length).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
            for cut in 0...length {
                let data = Data(octets.prefix(cut))
                if let frame = try? IAX2Frame.parse(data) {
                    XCTAssertEqual(frame.encoded(), data)
                }
            }
        }
    }

    // MARK: - Garbage

    /// Random datagrams either throw or parse to something that re-encodes
    /// byte-for-byte. Nothing traps. Seeded, so this is reproducible.
    func testRandomInputEitherThrowsOrReEncodesIdentically() {
        var rng = SplitMix64(seed: 0x5A17_C0DE_D00D_2222)
        var parsedFull = 0
        var parsedMini = 0
        var rejected = 0

        for _ in 0..<20_000 {
            let length = Int.random(in: 0...48, using: &rng)
            let data = Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
            do {
                let frame = try IAX2Frame.parse(data)
                XCTAssertEqual(frame.encoded(), data, "parse must lose nothing: \(data as NSData)")
                switch frame {
                case .full: parsedFull += 1
                case .mini: parsedMini += 1
                }
            } catch let error as IAX2FrameError {
                rejected += 1
                _ = error.description  // exercise the description path too
            } catch {
                XCTFail("parse threw something that is not an IAX2FrameError: \(error)")
            }
        }

        // Sanity: the corpus actually exercised all three outcomes.
        XCTAssertGreaterThan(parsedFull, 0)
        XCTAssertGreaterThan(parsedMini, 0)
        XCTAssertGreaterThan(rejected, 0)
    }

    // MARK: - Round-trip property tests

    /// Full Frames across the whole parameter space: call numbers at both ends
    /// of the 15-bit range, every defined frame type plus unknown ones,
    /// subclasses on both sides of the C-bit boundary, time-stamp extremes,
    /// and empty and non-empty payloads.
    func testFullFrameRoundTripAcrossTheParameterSpace() throws {
        let callNumbers: [UInt16] = [0, 1, 2, 0x00FF, 0x0100, 0x3FFF, 0x4000, 0x7FFE, 0x7FFF]
        let timestamps: [UInt32] = [
            0, 1, 0x0000_7FFF, 0x0000_8000, 0x0000_FFFF, 0x0001_0000,
            0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF,
        ]
        let types: [IAX2FrameType] = IAX2FrameType.defined + [
            .unknown(0x00), .unknown(0x0B), .unknown(0x7F), .unknown(0x80), .unknown(0xFF),
        ]
        // Straddling the C-bit boundary at 0x7F/0x80 in both directions.
        let subclassOctets: [UInt8] = [0x00, 0x01, 0x04, 0x7E, 0x7F, 0x80, 0x81, 0x82, 0xFE, 0xFF]
        let payloads: [[UInt8]] = [
            [],
            [0x00],
            [0xFF],
            [0x0b, 0x02, 0x00, 0x02],
            (0..<160).map { UInt8($0 & 0xFF) },
        ]

        var index = 0
        for source in callNumbers {
            for destination in callNumbers {
                for timestamp in timestamps {
                    for type in types {
                        for subclassOctet in subclassOctets {
                            let frame = IAX2FullFrame(
                                sourceCallNumber: source,
                                destinationCallNumber: destination,
                                isRetransmission: index % 2 == 0,
                                timestamp: timestamp,
                                oSeqno: UInt8(truncatingIfNeeded: index),
                                iSeqno: UInt8(truncatingIfNeeded: index &* 7 &+ 3),
                                type: type,
                                subclass: IAX2Subclass(rawByte: subclassOctet),
                                payload: payloads[index % payloads.count])
                            index += 1

                            let data = IAX2Frame.full(frame).encoded()
                            XCTAssertEqual(
                                data.count, IAX2FullFrame.headerLength + frame.payload.count)
                            let parsed = try IAX2Frame.parse(data)
                            XCTAssertEqual(parsed, .full(frame))
                            XCTAssertEqual(parsed.encoded(), data)
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(index, 50_000, "the sweep should be broad")
    }

    /// Mini Frames across the whole parameter space.
    ///
    /// Source call number 0 is deliberately absent: a Mini Frame carrying it
    /// encodes to a first word of all zeroes, which is by definition a Meta
    /// Frame (§8.1.3), which is exactly why call numbers are allocated from
    /// 1…32767 (notes §15). That case is covered separately above.
    func testMiniFrameRoundTripAcrossTheParameterSpace() throws {
        let callNumbers: [UInt16] = [1, 2, 0x00FF, 0x0100, 0x3FFF, 0x4000, 0x7FFE, 0x7FFF]
        let timestamps: [UInt16] = [0, 1, 0x00FF, 0x0100, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]
        let payloads: [[UInt8]] = [
            [],
            [0x00],
            [0xFF, 0x7F],
            (0..<160).map { UInt8($0 & 0xFF) },
        ]

        for callNumber in callNumbers {
            for timestamp in timestamps {
                for payload in payloads {
                    let frame = IAX2MiniFrame(
                        sourceCallNumber: callNumber, timestamp: timestamp, payload: payload)
                    let data = IAX2Frame.mini(frame).encoded()
                    XCTAssertEqual(data.count, IAX2MiniFrame.headerLength + payload.count)
                    let parsed = try IAX2Frame.parse(data)
                    XCTAssertEqual(parsed, .mini(frame))
                    XCTAssertEqual(parsed.encoded(), data)
                }
            }
        }
    }

    /// Randomised round trip, seeded for determinism.
    func testRandomValidFramesRoundTrip() throws {
        var rng = SplitMix64(seed: 0xF17E_B00C_1234_5678)
        for iteration in 0..<10_000 {
            let payloadLength = Int.random(in: 0...200, using: &rng)
            let payload = (0..<payloadLength).map { _ in UInt8.random(in: .min ... .max, using: &rng) }

            let frame: IAX2Frame
            if iteration % 2 == 0 {
                frame = .full(
                    IAX2FullFrame(
                        sourceCallNumber: UInt16.random(in: 0...0x7FFF, using: &rng),
                        destinationCallNumber: UInt16.random(in: 0...0x7FFF, using: &rng),
                        isRetransmission: Bool.random(using: &rng),
                        timestamp: UInt32.random(in: .min ... .max, using: &rng),
                        oSeqno: UInt8.random(in: .min ... .max, using: &rng),
                        iSeqno: UInt8.random(in: .min ... .max, using: &rng),
                        type: IAX2FrameType(rawValue: UInt8.random(in: .min ... .max, using: &rng)),
                        subclass: IAX2Subclass(rawByte: UInt8.random(in: .min ... .max, using: &rng)),
                        payload: payload))
            } else {
                frame = .mini(
                    IAX2MiniFrame(
                        sourceCallNumber: UInt16.random(in: 1...0x7FFF, using: &rng),
                        timestamp: UInt16.random(in: .min ... .max, using: &rng),
                        payload: payload))
            }

            let data = frame.encoded()
            XCTAssertEqual(try IAX2Frame.parse(data), frame)
            XCTAssertEqual(try IAX2Frame.parse(data).encoded(), data)
        }
    }

    // MARK: - Unknown values are preserved

    func testUnknownFrameTypesAndSubclassesRoundTrip() throws {
        for rawType: UInt8 in [0x00, 0x0B, 0x40, 0x7F, 0x80, 0xFE, 0xFF] {
            let type = IAX2FrameType(rawValue: rawType)
            XCTAssertEqual(type, .unknown(rawType))
            XCTAssertEqual(type.rawValue, rawType)

            let frame = IAX2FullFrame(
                sourceCallNumber: 7, destinationCallNumber: 8, timestamp: 9,
                oSeqno: 10, iSeqno: 11, type: type,
                subclass: IAX2Subclass(rawByte: 0xC3), payload: [0xde, 0xad])
            let parsed = try IAX2Frame.parse(IAX2Frame.full(frame).encoded())
            XCTAssertEqual(parsed, .full(frame))
            XCTAssertEqual(parsed.fullFrame?.type.rawValue, rawType)
            XCTAssertEqual(parsed.fullFrame?.subclass.rawByte, 0xC3)
            XCTAssertNil(parsed.fullFrame?.iaxMessage)
        }
    }

    /// A reserved IAX subclass has no case (§8.4) but still survives the wire,
    /// so a peer can answer UNSUPPORT with `subclass.rawByte` in the IAX
    /// UNKNOWN IE (§6.9.5, §8.6.22).
    func testReservedIAXSubclassesRoundTripAsRawOctets() throws {
        for reserved: UInt8 in [0x00, 0x1F, 0x23, 0x24, 0x25, 0x26, 0x7F] {
            XCTAssertNil(IAX2Message(rawValue: reserved), "0x\(hex(reserved)) is not in §8.4")
            let frame = IAX2FullFrame(
                sourceCallNumber: 1, destinationCallNumber: 2, timestamp: 0, oSeqno: 0, iSeqno: 0,
                type: .iax, subclass: IAX2Subclass(rawByte: reserved))
            let parsed = try IAX2Frame.parse(IAX2Frame.full(frame).encoded())
            XCTAssertEqual(parsed, .full(frame))
            XCTAssertEqual(parsed.fullFrame?.subclass.rawByte, reserved)
            XCTAssertNil(parsed.fullFrame?.iaxMessage)
        }
    }

    /// `IAX2FrameType` equality is defined on `rawValue`, so a hand-built
    /// `.unknown` can never shadow a defined case.
    func testUnknownFrameTypeEqualsTheDefinedCaseWithTheSameRawValue() {
        XCTAssertEqual(IAX2FrameType.unknown(0x02), IAX2FrameType.voice)
        XCTAssertEqual(
            Set([IAX2FrameType.unknown(0x02), .voice]).count, 1, "and hashes consistently")
    }

    // MARK: - Tables (notes §4, §5)

    func testFrameTypeTableMatchesRFC5456Section82() {
        XCTAssertEqual(IAX2FrameType.dtmf.rawValue, 0x01)
        XCTAssertEqual(IAX2FrameType.voice.rawValue, 0x02)
        XCTAssertEqual(IAX2FrameType.video.rawValue, 0x03)
        XCTAssertEqual(IAX2FrameType.control.rawValue, 0x04)
        XCTAssertEqual(IAX2FrameType.null.rawValue, 0x05)
        XCTAssertEqual(IAX2FrameType.iax.rawValue, 0x06)
        XCTAssertEqual(IAX2FrameType.text.rawValue, 0x07)
        XCTAssertEqual(IAX2FrameType.image.rawValue, 0x08)
        XCTAssertEqual(IAX2FrameType.html.rawValue, 0x09)
        XCTAssertEqual(IAX2FrameType.comfortNoise.rawValue, 0x0A)
        XCTAssertEqual(IAX2FrameType.defined.map(\.rawValue), Array(0x01...0x0A))
    }

    func testIAXSubclassTableMatchesRFC5456Section84() {
        let expected: [(IAX2Message, UInt8)] = [
            (.new, 0x01), (.ping, 0x02), (.pong, 0x03), (.ack, 0x04), (.hangup, 0x05),
            (.reject, 0x06), (.accept, 0x07), (.authreq, 0x08), (.authrep, 0x09), (.inval, 0x0A),
            (.lagrq, 0x0B), (.lagrp, 0x0C), (.regreq, 0x0D), (.regauth, 0x0E), (.regack, 0x0F),
            (.regrej, 0x10), (.regrel, 0x11), (.vnak, 0x12), (.dpreq, 0x13), (.dprep, 0x14),
            (.dial, 0x15), (.txreq, 0x16), (.txcnt, 0x17), (.txacc, 0x18), (.txready, 0x19),
            (.txrel, 0x1A), (.txrej, 0x1B), (.quelch, 0x1C), (.unquelch, 0x1D), (.poke, 0x1E),
            (.mwi, 0x20), (.unsupport, 0x21), (.transfer, 0x22),
        ]
        for (message, raw) in expected {
            XCTAssertEqual(message.rawValue, raw, "\(message)")
            XCTAssertEqual(IAX2Message(rawValue: raw), message)
        }
        XCTAssertEqual(IAX2Message.allCases.count, expected.count, "the §8.4 table is complete")

        // The reserved gaps in §8.4.
        for reserved: UInt8 in [0x00, 0x1F, 0x23, 0x24, 0x25] {
            XCTAssertNil(IAX2Message(rawValue: reserved))
        }

        // §7: these five do not advance the message count (notes trap 4).
        XCTAssertEqual(IAX2Message.sequenceNumberExempt, [.ack, .inval, .txcnt, .txacc, .vnak])
    }

    func testControlSubclassTableMatchesRFC5456Section83() {
        let expected: [(IAX2Control, UInt8)] = [
            (.hangup, 0x01), (.ringing, 0x03), (.answer, 0x04), (.busy, 0x05),
            (.congestion, 0x08), (.flashHook, 0x09), (.option, 0x0B), (.keyRadio, 0x0C),
            (.unkeyRadio, 0x0D), (.callProgress, 0x0E), (.callProceeding, 0x0F),
            (.hold, 0x10), (.unhold, 0x11),
        ]
        for (control, raw) in expected {
            XCTAssertEqual(control.rawValue, raw, "\(control)")
            XCTAssertEqual(IAX2Control(rawValue: raw), control)
        }
        XCTAssertEqual(IAX2Control.allCases.count, expected.count)
        for reserved: UInt8 in [0x00, 0x02, 0x06, 0x07, 0x0A] {
            XCTAssertNil(IAX2Control(rawValue: reserved))
        }
    }

    /// Control HANGUP (type 0x04 / subclass 0x01) is not IAX HANGUP
    /// (type 0x06 / subclass 0x05) — notes trap 18.
    func testControlHangupIsNotIAXHangup() {
        let controlHangup = IAX2FullFrame(
            sourceCallNumber: 1, destinationCallNumber: 2, timestamp: 0, oSeqno: 0, iSeqno: 0,
            type: .control, subclass: IAX2Subclass(IAX2Control.hangup))
        let iaxHangup = IAX2FullFrame(
            sourceCallNumber: 1, destinationCallNumber: 2, timestamp: 0, oSeqno: 0, iSeqno: 0,
            type: .iax, subclass: IAX2Subclass(IAX2Message.hangup))

        XCTAssertEqual(controlHangup.control, .hangup)
        XCTAssertNil(controlHangup.iaxMessage)
        XCTAssertEqual(iaxHangup.iaxMessage, .hangup)
        XCTAssertNil(iaxHangup.control)
        XCTAssertNotEqual(controlHangup.subclass, iaxHangup.subclass)
    }

    /// The subclass views only apply to their own frame type, and never to a
    /// power-encoded subclass.
    func testSubclassViewsAreScopedToTheFrameType() {
        func frame(_ type: IAX2FrameType, _ subclass: UInt8) -> IAX2FullFrame {
            IAX2FullFrame(
                sourceCallNumber: 1, destinationCallNumber: 2, timestamp: 0, oSeqno: 0, iSeqno: 0,
                type: type, subclass: IAX2Subclass(rawByte: subclass))
        }
        XCTAssertNil(frame(.voice, 0x04).iaxMessage, "a Voice subclass is a media format (§8.2.2)")
        XCTAssertNil(frame(.voice, 0x04).control)
        XCTAssertNil(frame(.iax, 0x82).iaxMessage, "C = 1 is never an IAX ordinal (§8.4)")
        XCTAssertNil(frame(.iax, 0x01).mediaFormat)
        XCTAssertEqual(frame(.image, 0x91).mediaFormat, 0x0002_0000, "PNG = 1 << 17 (§8.7)")
    }

    // MARK: - Transmission validation

    func testNullFramesAreRejectedForTransmission() {
        let null = IAX2Frame.full(
            IAX2FullFrame(
                sourceCallNumber: 1, destinationCallNumber: 2, timestamp: 0, oSeqno: 0, iSeqno: 0,
                type: .null, subclass: IAX2Subclass(rawByte: 0)))
        XCTAssertThrowsError(try null.validateForTransmission()) { error in
            guard case .malformed? = error as? IAX2FrameError else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
        // But a Null frame received from a peer still parses and round-trips —
        // we tolerate on receive what we refuse to send.
        XCTAssertNoThrow(try IAX2Frame.parse(null.encoded()))
        XCTAssertEqual(try IAX2Frame.parse(null.encoded()), null)
    }

    func testWellFormedFramesPassValidation() throws {
        for name in ["frame-new.hex", "frame-mini.hex", "frame-voice-ulaw.hex", "frame-ack-retransmit.hex"] {
            let frame = try IAX2Frame.parse(FixtureLoader.datagram(name, in: Bundle.module))
            XCTAssertNoThrow(try frame.validateForTransmission(), name)
        }
    }

    // MARK: - Error descriptions

    func testErrorsAreDistinguishableAndDescribed() {
        let errors: [IAX2FrameError] = [
            .tooShort(expected: 12, actual: 5), .metaFrame, .malformed(reason: "x"),
        ]
        XCTAssertEqual(Set(errors.map(\.description)).count, 3)
        XCTAssertNotEqual(IAX2FrameError.metaFrame, .tooShort(expected: 12, actual: 5))
        XCTAssertEqual(IAX2FrameError.metaFrame, .metaFrame)
    }

    // MARK: - Helpers

    private func hex(_ value: UInt8) -> String {
        String(format: "%02x", value)
    }
}

/// SplitMix64 — a small, seeded, fully deterministic generator so the
/// randomised tests above give the same corpus on every run and on every
/// platform (Swift's `SystemRandomNumberGenerator` gives neither).
///
/// Deliberately `private`: sibling IAX-2/IAX-4 test files live in this same
/// target and may want a generator of their own under the same name.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
