// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import TestSupport
import XCTest

@testable import IAX2Kit

/// IAX-7: DTMF (RFC 5456 §6.10.1, §8.2.1, §8.2; notes §14).
///
/// No socket and no wall clock (AU-5): `MockTransport` and `ManualTestClock`
/// throughout, and the wire assertions are byte-for-byte against hand-built
/// fixtures.
final class IAX2DTMFTests: XCTestCase {

    private let peerCallNumber: UInt16 = 0x0042
    private let localCallNumber: UInt16 = 1

    // MARK: - The character set (§8.2)

    func testEveryValidDigitIsAcceptedAndCodedAsItsASCIIValue() throws {
        // The §8.2 table gives the DTMF subclass domain as "0-9, A-D, *, #".
        let expected: [(Character, UInt8)] = [
            ("0", 0x30), ("1", 0x31), ("2", 0x32), ("3", 0x33), ("4", 0x34),
            ("5", 0x35), ("6", 0x36), ("7", 0x37), ("8", 0x38), ("9", 0x39),
            ("A", 0x41), ("B", 0x42), ("C", 0x43), ("D", 0x44),
            ("*", 0x2A), ("#", 0x23),
        ]
        XCTAssertEqual(expected.count, 16, "sixteen symbols, no more and no fewer")
        XCTAssertEqual(IAX2DTMFDigit.validCharacters.count, 16)

        for (character, ascii) in expected {
            let digit = try IAX2DTMFDigit(character)
            XCTAssertEqual(digit.character, character)
            XCTAssertEqual(digit.asciiValue, ascii)
            XCTAssertEqual(digit.subclass.rawByte, ascii, "the raw subclass octet")
            XCTAssertFalse(
                digit.subclass.isPowerEncoded,
                "all sixteen fit the 7-bit field, so C = 0 (§8.1.1)")
            XCTAssertEqual(digit.subclass.value, UInt32(ascii))
        }
    }

    /// Not one of the sixteen ASCII codes is an exact power of two, so the
    /// §8.1.1 C-bit overlap that lets µ-law be either `0x04` or `0x82` cannot
    /// arise for a DTMF digit — and a C = 1 octet can never name one.
    func testNoDigitIsAmbiguousUnderTheCBitRule() {
        for digit in IAX2DTMFDigit.all {
            XCTAssertNotEqual(
                digit.asciiValue.nonzeroBitCount, 1,
                "\(digit) would have two legal subclass encodings")
        }
        for exponent in UInt8(0)...6 {
            let subclass = IAX2Subclass.powerOfTwo(exponent: exponent)
            XCTAssertNil(
                IAX2DTMFDigit(subclass: subclass),
                "a power-encoded subclass names 1 << \(exponent), which is no DTMF digit")
        }
    }

    func testInvalidCharactersThrow() {
        let invalid: [Character] = [
            "a", "b", "c", "d",  // lower case: the RFC names A-D
            "E", "F", "Z", "e",  // outside the domain entirely
            " ", "-", "+", ",", ".", "!", "\n", "\0",
            "é", "５", "🙂",  // non-ASCII, including a full-width digit five
        ]
        for character in invalid {
            XCTAssertThrowsError(try IAX2DTMFDigit(character), "'\(character)'") { error in
                XCTAssertEqual(error as? IAX2DTMFError, .invalidDigit(character))
            }
        }
    }

    func testNoOtherASCIICharacterIsAccepted() {
        for code in UInt8(0)...UInt8(127) {
            let character = Character(Unicode.Scalar(code))
            let accepted = (try? IAX2DTMFDigit(character)) != nil
            XCTAssertEqual(
                accepted, IAX2DTMFDigit.validCharacters.contains(character),
                "ASCII 0x\(String(format: "%02x", code))")
        }
    }

    // MARK: - Reading an inbound frame

    func testDigitIsReadOutOfAFullFrame() throws {
        let frame = IAX2FullFrame(
            sourceCallNumber: peerCallNumber,
            destinationCallNumber: localCallNumber,
            timestamp: 1_000,
            oSeqno: 2, iSeqno: 1,
            type: .dtmf,
            subclass: IAX2Subclass.literal(0x39))
        XCTAssertEqual(IAX2DTMFDigit(frame: frame)?.character, "9")
    }

    func testNonDTMFFramesYieldNoDigit() {
        // A Voice frame whose µ-law subclass octet is 0x82 — power-encoded, and
        // in any case the wrong frame type.
        let voice = IAX2FullFrame(
            sourceCallNumber: peerCallNumber,
            destinationCallNumber: localCallNumber,
            timestamp: 0, oSeqno: 2, iSeqno: 1,
            type: .voice,
            subclass: IAX2Subclass(mediaFormat: MediaFormat.g711MuLaw.rawValue)!)
        XCTAssertNil(IAX2DTMFDigit(frame: voice))

        // Right frame type, subclass outside the domain: 'E' is not DTMF.
        let bogus = IAX2FullFrame(
            sourceCallNumber: peerCallNumber,
            destinationCallNumber: localCallNumber,
            timestamp: 0, oSeqno: 2, iSeqno: 1,
            type: .dtmf,
            subclass: IAX2Subclass.literal(0x45))
        XCTAssertNil(IAX2DTMFDigit(frame: bogus))
    }

    func testInboundFixtureDigitsParse() throws {
        let datagrams = try FixtureLoader.datagrams("dtmf-inbound-abcd.hex", in: Bundle.module)
        XCTAssertEqual(datagrams.count, 4)

        var digits: [Character] = []
        for datagram in datagrams {
            guard case .full(let full) = try IAX2Frame.parse(datagram) else {
                return XCTFail("a DTMF digit is a Full Frame (§8.2.1)")
            }
            XCTAssertEqual(full.type, .dtmf)
            XCTAssertTrue(
                full.payload.isEmpty,
                "the §8.2 table gives the DTMF Data field as 'Undefined' — no payload")
            guard let digit = IAX2DTMFDigit(frame: full) else {
                return XCTFail("fixture digit did not parse")
            }
            digits.append(digit.character)
        }
        XCTAssertEqual(digits, ["A", "B", "C", "D"])
    }

    // MARK: - Transmitting: byte-for-byte against the fixtures

    func testTransmittedDigitsMatchTheHandBuiltFixtures() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)
        harness.transport.clearSent()

        _ = try await stream.send(dtmf: "5", timestamp: 1_000)
        _ = try await stream.send(dtmf: "#", timestamp: 2_000)

        let sent = harness.transport.sent
        XCTAssertEqual(sent.count, 2, "one frame per digit — RFC 5456 has no BEGIN or END")

        assertBytes(
            sent[0], try FixtureLoader.datagram("dtmf-digit-5.hex", in: Bundle.module),
            "the digit '5'")
        assertBytes(
            sent[1], try FixtureLoader.datagram("dtmf-digit-hash.hex", in: Bundle.module),
            "the digit '#'")

        // Explicitly: a DTMF frame is a bare 12-octet header.
        XCTAssertEqual(sent[0].count, IAX2FullFrame.headerLength)
        XCTAssertEqual(sent[1].count, IAX2FullFrame.headerLength)

        await harness.call.close()
    }

    /// §6.10.1 and §8.2 define one frame per digit and nothing else: no BEGIN,
    /// no END, no duration, no volume, no repeat (notes §14).
    func testOneDigitSendsExactlyOneFrameAndNothingFollows() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)
        harness.transport.clearSent()

        _ = try await stream.send(dtmf: "7", timestamp: 500)
        for _ in 0..<500 { await Task.yield() }
        XCTAssertEqual(
            harness.transport.sentCount, 1,
            "nothing is scheduled to close the digit, because there is nothing to send")

        await harness.call.close()
    }

    func testEveryValidDigitGoesOnTheWireWithTheRightSubclass() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)
        harness.transport.clearSent()

        for digit in IAX2DTMFDigit.all {
            _ = try await stream.send(dtmf: digit, timestamp: 0)
        }

        let sent = harness.transport.sent
        XCTAssertEqual(sent.count, 16)
        for (index, datagram) in sent.enumerated() {
            guard case .full(let full) = try IAX2Frame.parse(datagram) else {
                return XCTFail("frame \(index) should be a Full Frame")
            }
            XCTAssertEqual(full.type, .dtmf)
            XCTAssertEqual(full.sourceCallNumber, localCallNumber)
            XCTAssertEqual(full.destinationCallNumber, peerCallNumber)
            XCTAssertTrue(full.payload.isEmpty)
            XCTAssertEqual(IAX2DTMFDigit(frame: full), IAX2DTMFDigit.all[index])
            // Reliable: "each reliable message that is sent increments the
            // message count by one" (§7), starting from OSeqno 1 here.
            XCTAssertEqual(full.oSeqno, UInt8(1 + index))
        }

        await harness.call.close()
    }

    func testInvalidDigitThrowsAndSendsNothing() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)
        harness.transport.clearSent()

        do {
            _ = try await stream.send(dtmf: "a", timestamp: 0)
            XCTFail("lower-case 'a' is not in the §8.2 domain")
        } catch let error as IAX2DTMFError {
            XCTAssertEqual(error, .invalidDigit("a"))
        }
        XCTAssertEqual(harness.transport.sentCount, 0)

        await harness.call.close()
    }

    func testASequenceIsValidatedWholeBeforeAnythingIsSent() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)
        harness.transport.clearSent()

        do {
            _ = try await stream.send(dtmfSequence: "12X4")
            XCTFail("'X' is not a DTMF digit")
        } catch let error as IAX2DTMFError {
            XCTAssertEqual(error, .invalidDigit("X"))
        }
        XCTAssertEqual(
            harness.transport.sentCount, 0,
            "half a sequence on the wire would dial something the caller never asked for")

        let frames = try await stream.send(dtmfSequence: "1*2")
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(harness.transport.sentCount, 3)

        await harness.call.close()
    }

    func testDTMFBeforeTheCallIsEstablishedIsRefused() async throws {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let allocator = IAX2CallNumberAllocator()
        let call = try await IAX2Call.outbound(
            allocator: allocator, request: IAX2CallRequest(calledNumber: "55553"),
            transport: transport, clock: clock)
        let stream = IAX2VoiceStream(call: call)

        do {
            _ = try await stream.send(dtmf: "1")
            XCTFail("media requires an established leg (§6.3.1, §9.6)")
        } catch let error as IAX2CallError {
            XCTAssertEqual(error, .notEstablished(state: .idle))
        }
        XCTAssertEqual(transport.sentCount, 0)

        await call.close()
        transport.finish()
    }

    // MARK: - Inbound, end to end over a call

    func testInboundDTMFIsSurfacedAsACallEventAndDecodedByTheStream() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)

        let log = EventLog()
        let drain = Task { for await event in harness.call.events { await log.append(event) } }
        defer { drain.cancel() }

        let datagrams = try FixtureLoader.datagrams("dtmf-inbound-abcd.hex", in: Bundle.module)
        harness.transport.inject(datagrams)

        var others: [IAX2FullFrame] = []
        for _ in 0..<100_000 {
            others = await log.events.compactMap {
                if case .other(let full) = $0 { return full }
                return nil
            }
            if others.count == 4 { break }
            await Task.yield()
        }
        XCTAssertEqual(
            others.count, 4,
            "inbound DTMF reaches this client as IAX2CallEvent.other (already ACKed)")

        var digits: [Character] = []
        for full in others {
            guard case .dtmf(let digit) = await stream.handle(.other(full)) else {
                return XCTFail("the stream should recognise an inbound DTMF frame")
            }
            digits.append(digit.character)
        }
        XCTAssertEqual(digits, ["A", "B", "C", "D"])

        // "Upon receiving any media message, except the abbreviated audio and
        // video Mini Frames, an ACK message MUST be sent." (§6.10)
        let acks = harness.transport.sent.compactMap { datagram -> IAX2FullFrame? in
            guard case .full(let full)? = try? IAX2Frame.parse(datagram),
                full.iaxMessage == .ack
            else { return nil }
            return full
        }
        XCTAssertGreaterThanOrEqual(acks.count, 4, "each inbound DTMF frame is ACKed")

        await harness.call.close()
    }

    func testStreamIgnoresNonDTMFOtherEvents() async throws {
        let harness = try await makeUpCall()
        defer { harness.transport.finish() }
        let stream = IAX2VoiceStream(call: harness.call)

        let text = IAX2FullFrame(
            sourceCallNumber: peerCallNumber,
            destinationCallNumber: localCallNumber,
            timestamp: 0, oSeqno: 2, iSeqno: 1,
            type: .text,
            subclass: IAX2Subclass.literal(0),
            payload: Array("hello".utf8))
        let event = await stream.handle(.other(text))
        XCTAssertNil(event, "a Text frame is not this stream's business")

        await harness.call.close()
    }

    // MARK: - Helpers

    private actor EventLog {
        private(set) var events: [IAX2CallEvent] = []
        func append(_ event: IAX2CallEvent) { events.append(event) }
    }

    private func assertBytes(
        _ actual: Data,
        _ expected: Data,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.map { String(format: "%02x", $0) }.joined(),
            expected.map { String(format: "%02x", $0) }.joined(),
            what, file: file, line: line)
    }

    private struct Harness {
        let call: IAX2Call
        let transport: MockTransport
        let clock: ManualTestClock
    }

    /// NEW → ACCEPT → ACK → ANSWER → ACK (§9.6), leaving the call `up` with
    /// OSeqno 1 and ISeqno 2 — the counters the DTMF fixtures were built for.
    private func makeUpCall() async throws -> Harness {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let allocator = IAX2CallNumberAllocator()
        let call = try await IAX2Call.outbound(
            allocator: allocator,
            request: IAX2CallRequest(calledNumber: "55553", username: "n0call"),
            transport: transport,
            clock: clock)
        XCTAssertEqual(call.sourceCallNumber, localCallNumber)

        try await call.start()

        transport.inject(
            IAX2Frame.full(
                IAX2FullFrame(
                    sourceCallNumber: peerCallNumber,
                    destinationCallNumber: localCallNumber,
                    timestamp: 0, oSeqno: 0, iSeqno: 1,
                    type: .iax,
                    subclass: IAX2Subclass(.accept),
                    payload: try InformationElement.serialize([.format(.g711MuLaw)]))
            ).encoded())

        transport.inject(
            IAX2Frame.full(
                IAX2FullFrame(
                    sourceCallNumber: peerCallNumber,
                    destinationCallNumber: localCallNumber,
                    timestamp: 0, oSeqno: 1, iSeqno: 1,
                    type: .control,
                    subclass: IAX2Subclass(.answer))
            ).encoded())

        for _ in 0..<100_000 {
            if await call.state == .up { break }
            await Task.yield()
        }
        let state = await call.state
        XCTAssertEqual(state, .up)

        return Harness(call: call, transport: transport, clock: clock)
    }
}
