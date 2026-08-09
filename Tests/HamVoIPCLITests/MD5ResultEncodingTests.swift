// SPDX-License-Identifier: Apache-2.0

import Foundation
import IAX2Kit
import XCTest

@testable import hamvoip_cli

/// OQ-5's candidate encodings.
///
/// The experiment these feed is run against a live node and cannot be
/// unit-tested. What *can* be tested — and must be, because a wrong candidate
/// would make the experiment produce a confident wrong answer — is that each
/// candidate renders the digest the way its name claims, that they are all
/// renderings of the *same* digest, and that the digest is the one RFC 5456
/// §8.6.15 describes.
final class MD5ResultEncodingTests: XCTestCase {

    // The vector is computed independently of this codebase:
    //   printf '%s' '12345abcdesecret' | md5
    //   931e06eee10cf8038c95d442cfac0ffb
    private let challenge = "12345abcde"
    private let secret = "secret"
    private let expectedHex = "931e06eee10cf8038c95d442cfac0ffb"

    // MARK: The digest itself

    func testTheDigestIsMD5OfChallengeThenSecretWithNoSeparator() {
        let digest = MD5ResultEncoding.digest(challenge: challenge, secret: secret)
        XCTAssertEqual(digest.count, 16)
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), expectedHex)
    }

    func testTheDigestMatchesWhatIAX2KitItselfComputes() {
        // The capture trick must not have changed what is hashed — only how it
        // is rendered. If these ever disagree, the probe is testing something
        // other than the encoding.
        let viaCapture = MD5ResultEncoding.digest(challenge: challenge, secret: secret)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(viaCapture, IAX2Auth.md5Response(challenge: challenge, secret: secret))
    }

    func testEmptyChallengeAndSecretStillProduceADigest() {
        // printf '%s' '' | md5  →  d41d8cd98f00b204e9800998ecf8427e
        let digest = MD5ResultEncoding.digest(challenge: "", secret: "")
        XCTAssertEqual(
            digest.map { String(format: "%02x", $0) }.joined(),
            "d41d8cd98f00b204e9800998ecf8427e")
    }

    // MARK: Each candidate renders what its name says

    func testLowercaseHexIsThirtyTwoLowercaseCharacters() {
        let rendered = MD5ResultEncoding.lowercaseHex.rendering(challenge: challenge, secret: secret)
        XCTAssertEqual(rendered, expectedHex)
        XCTAssertEqual(rendered.count, 32)
        XCTAssertEqual(rendered, rendered.lowercased())
    }

    func testLowercaseHexIsExactlyWhatIAX2KitShips() {
        // This candidate must reproduce `TextDigestEncoding.oq5Default`
        // byte-for-byte, or "the shipped assumption was confirmed" would be a
        // claim about something else.
        XCTAssertEqual(
            MD5ResultEncoding.lowercaseHex.rendering(challenge: challenge, secret: secret),
            IAX2Auth.md5Response(challenge: challenge, secret: secret))
    }

    func testUppercaseHexDiffersFromLowercaseOnlyInCase() {
        let rendered = MD5ResultEncoding.uppercaseHex.rendering(challenge: challenge, secret: secret)
        XCTAssertEqual(rendered, expectedHex.uppercased())
        XCTAssertEqual(rendered.lowercased(), expectedHex)
    }

    func testHexCandidatesZeroPadEveryByteToTwoCharacters() {
        // A digest with a leading zero byte is where an unpadded renderer
        // would silently produce 31 characters.
        var found = false
        for attempt in 0..<4096 {
            let digest = MD5ResultEncoding.digest(challenge: "c\(attempt)", secret: secret)
            guard digest.contains(where: { $0 < 0x10 }) else { continue }
            found = true
            let rendered = MD5ResultEncoding.lowercaseHex.rendering(challenge: "c\(attempt)", secret: secret)
            XCTAssertEqual(rendered.count, 32)
            break
        }
        XCTAssertTrue(found, "expected at least one digest with a byte below 0x10")
    }

    func testBase64DecodesBackToTheSameSixteenBytes() {
        let rendered = MD5ResultEncoding.base64.rendering(challenge: challenge, secret: secret)
        XCTAssertEqual(rendered.count, 24)
        let decoded = Data(base64Encoded: rendered)
        XCTAssertEqual(decoded.map(Array.init), MD5ResultEncoding.digest(challenge: challenge, secret: secret))
    }

    func testRawBytesHasNoTextEncodingAtAll() {
        XCTAssertNil(MD5ResultEncoding.rawBytes.textEncoding)
        XCTAssertNotNil(MD5ResultEncoding.lowercaseHex.textEncoding)
        XCTAssertNotNil(MD5ResultEncoding.uppercaseHex.textEncoding)
        XCTAssertNotNil(MD5ResultEncoding.base64.textEncoding)
    }

    func testEveryCandidateIsADistinctHypothesis() {
        let renderings = MD5ResultEncoding.allCases.map {
            $0.rendering(challenge: challenge, secret: secret)
        }
        XCTAssertEqual(Set(renderings).count, renderings.count,
            "two candidates that put the same bytes on the wire would make the experiment ambiguous")
    }

    // MARK: The information element that actually goes on the wire

    func testTextCandidatesBuildAnMD5ResultElementWithTheirRendering() throws {
        for candidate in [MD5ResultEncoding.lowercaseHex, .uppercaseHex, .base64] {
            let element = candidate.informationElement(challenge: challenge, secret: secret)
            guard case .md5Result(let text) = element else {
                return XCTFail("\(candidate.rawValue) should build an MD5 RESULT element")
            }
            XCTAssertEqual(text, candidate.rendering(challenge: challenge, secret: secret))
        }
    }

    func testRawBytesBuildsIEZeroXTenCarryingTheDigestUnchanged() throws {
        let element = MD5ResultEncoding.rawBytes.informationElement(challenge: challenge, secret: secret)
        guard case .unknown(let id, let data) = element else {
            return XCTFail("raw-bytes must bypass the String-typed MD5 RESULT case")
        }
        XCTAssertEqual(id, 0x10, "MD5 RESULT is IE 0x10 (§8.6.15)")
        XCTAssertEqual(data, MD5ResultEncoding.digest(challenge: challenge, secret: secret))
        XCTAssertEqual(data.count, 16, "the whole point of this candidate is 16 bytes, not 32 characters")
    }

    func testEveryCandidateSerialisesToAWellFormedElement() throws {
        for candidate in MD5ResultEncoding.allCases {
            let element = candidate.informationElement(challenge: challenge, secret: secret)
            let bytes = try element.serialized()
            XCTAssertEqual(bytes[0], 0x10, "\(candidate.rawValue) must be IE 0x10")
            XCTAssertEqual(Int(bytes[1]), bytes.count - 2, "\(candidate.rawValue) length field")
        }
    }

    // MARK: Command-line surface

    func testEveryCandidateIsSelectableByNameAndExplained() {
        for candidate in MD5ResultEncoding.allCases {
            XCTAssertEqual(MD5ResultEncoding(argument: candidate.rawValue), candidate)
            XCTAssertFalse(candidate.explanation.isEmpty)
        }
        XCTAssertEqual(Set(MD5ResultEncoding.allValueStrings).count, MD5ResultEncoding.allCases.count)
        XCTAssertNil(MD5ResultEncoding(argument: "rot13"))
    }
}
