// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import TestSupport

/// EL-5 — the proxy login digest.
///
/// The two vectors below are the whole evidential basis for this construction,
/// so they are worth stating plainly: each is a `(nonce, digest)` pair
/// recovered from a capture of the maintainer's own session, and they come from
/// **two different proxies** with **two different nonces**. One pair can be
/// reproduced by coincidence in a large enough candidate search; two cannot.
///
/// The nonces themselves are also fixtures (`live-proxy-login-in.hex` and
/// `live-proxy-nonce-2.hex`) and are checked against these constants below, so
/// that the vectors cannot silently drift away from the captures they came from.
///
/// The digests are not secret. They are `MD5("PUBLIC" ‖ nonce)`, derived
/// entirely from public inputs: the literal password every public proxy uses,
/// and a nonce the proxy sent in clear.
final class EchoLinkAuthTests: XCTestCase {
    /// Capture 2, proxy 44.137.75.105.
    private static let vector1 = (
        nonce: "6fc8b7e3",
        digest: "71c9fe69024f97c2f34e614823e7b423"
    )

    /// Capture 3, proxy 44.31.100.23. A different proxy and a different nonce.
    private static let vector2 = (
        nonce: "45801e6e",
        digest: "1b4be7f85d6926c0418126b1290e98b7"
    )

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The recorded vectors

    func testFirstRecordedVectorReproduces() {
        let digest = EchoLinkAuth.proxyDigest(
            password: .publicProxy,
            nonce: Self.vector1.nonce
        )
        XCTAssertEqual(hex(digest), Self.vector1.digest)
        XCTAssertEqual(digest.count, EchoLinkAuth.digestLength)
    }

    func testSecondRecordedVectorReproduces() {
        let digest = EchoLinkAuth.proxyDigest(
            password: .publicProxy,
            nonce: Self.vector2.nonce
        )
        XCTAssertEqual(hex(digest), Self.vector2.digest)
    }

    func testVectorNoncesAreTheOnesInTheFixtures() throws {
        let login = try FixtureLoader.datagrams("live-proxy-login-in.hex", in: Bundle.module)
        XCTAssertEqual(
            String(data: login[0], encoding: .ascii), Self.vector1.nonce,
            "vector 1's nonce must be the one the capture recorded"
        )

        let second = try FixtureLoader.datagram("live-proxy-nonce-2.hex", in: Bundle.module)
        XCTAssertEqual(
            String(data: second, encoding: .ascii), Self.vector2.nonce,
            "vector 2's nonce must be the one the capture recorded"
        )
    }

    // MARK: - The four corrections, each as a test

    func testOrderIsPasswordFirst() {
        // MD5(nonce ‖ password) is the ordering RFC 5456's phrasing suggests
        // for IAX2, and it is the obvious guess here. It does not match.
        let wrongWayRound = EchoLinkAuth.proxyDigest(
            password: EchoLinkProxyPassword(Self.vector1.nonce),
            nonce: "PUBLIC"
        )
        XCTAssertNotEqual(hex(wrongWayRound), Self.vector1.digest,
                          "MD5(nonce ‖ password) must not be what reproduces the capture")
    }

    func testNonceIsHashedAsEightAsciiCharactersNotFourRawBytes() {
        // "6fc8b7e3" as the four bytes 0x6f 0xc8 0xb7 0xe3 — the other obvious
        // guess, since the nonce looks exactly like hex text.
        let rawBytes = Data([0x6F, 0xC8, 0xB7, 0xE3])
        let asRawBytes = EchoLinkAuth.proxyDigest(
            password: .publicProxy,
            nonce: String(decoding: rawBytes, as: UTF8.self)
        )
        XCTAssertNotEqual(hex(asRawBytes), Self.vector1.digest)
    }

    func testDigestIsRawBytesNotHexText() {
        // OQ-5 settled that IAX2's MD5 RESULT is a lowercase 32-character hex
        // string. EchoLink is the opposite: 16 raw bytes on the wire. This test
        // exists so the IAX2 convention cannot leak in later — if someone
        // "helpfully" hex-encodes the digest, this fails.
        let digest = EchoLinkAuth.proxyDigest(password: .publicProxy, nonce: Self.vector1.nonce)

        XCTAssertEqual(digest.count, 16, "raw, not the 32 bytes hex text would be")
        XCTAssertNotEqual(
            digest, Data(Self.vector1.digest.utf8),
            "the digest must not be the ASCII of its own hex rendering"
        )

        let message = EchoLinkAuth.proxyLoginMessage(
            callsign: "N0CALL",
            password: .publicProxy,
            nonce: Self.vector1.nonce
        )
        XCTAssertEqual(message.count, 6 + 1 + 16,
                       "callsign + LF + 16 raw bytes; hex text would make this 6 + 1 + 32")
    }

    func testCallsignIsSentAlongsideTheDigestNotHashedIntoIt() {
        let a = EchoLinkAuth.proxyDigest(password: .publicProxy, nonce: Self.vector1.nonce)
        let messageOne = EchoLinkAuth.proxyLoginMessage(
            callsign: "N0CALL", password: .publicProxy, nonce: Self.vector1.nonce
        )
        let messageTwo = EchoLinkAuth.proxyLoginMessage(
            callsign: "VK0XYZ", password: .publicProxy, nonce: Self.vector1.nonce
        )

        XCTAssertEqual(messageOne.suffix(16), a, "the digest does not depend on the callsign")
        XCTAssertEqual(messageTwo.suffix(16), a)
        XCTAssertNotEqual(messageOne, messageTwo, "but the callsign is still on the wire")
    }

    // MARK: - Message shape

    func testLoginMessageIsCallsignThenLineFeedThenDigest() {
        let message = EchoLinkAuth.proxyLoginMessage(
            callsign: "N0CALL",
            password: .publicProxy,
            nonce: Self.vector1.nonce
        )

        XCTAssertEqual(Array(message.prefix(6)), Array("N0CALL".utf8))
        XCTAssertEqual(message[message.startIndex + 6], 0x0A, "LF-terminated, not CR or CRLF")
        XCTAssertEqual(
            hex(Data(message.dropFirst(7))), Self.vector1.digest,
            "and no length prefix between the callsign and the digest"
        )
    }

    func testLoginMessageMatchesTheCapturedShape() throws {
        // The captured client half is 23 bytes: a 6-character callsign, LF, and
        // 16 raw digest bytes. The capture's own client half is deliberately not
        // a fixture (it carries the operator's callsign), so this asserts the
        // shape the fixture header records rather than the octets.
        let message = EchoLinkAuth.proxyLoginMessage(
            callsign: "VK0ABC",
            password: .publicProxy,
            nonce: Self.vector1.nonce
        )
        XCTAssertEqual(message.count, 23)
    }

    // MARK: - Nonce validation

    func testPlausibleNonceAcceptsWhatProxiesSend() {
        XCTAssertTrue(EchoLinkAuth.isPlausibleNonce(Data(Self.vector1.nonce.utf8)))
        XCTAssertTrue(EchoLinkAuth.isPlausibleNonce(Data(Self.vector2.nonce.utf8)))
        // Nothing establishes that a proxy must send lowercase — two proxies
        // agreeing is evidence about two proxies.
        XCTAssertTrue(EchoLinkAuth.isPlausibleNonce(Data("6FC8B7E3".utf8)))
    }

    func testPlausibleNonceRejectsEverythingElse() {
        XCTAssertFalse(EchoLinkAuth.isPlausibleNonce(Data("6fc8b7e".utf8)), "7 characters")
        XCTAssertFalse(EchoLinkAuth.isPlausibleNonce(Data("6fc8b7e33".utf8)), "9 characters")
        XCTAssertFalse(EchoLinkAuth.isPlausibleNonce(Data("6fc8b7gz".utf8)), "not hex")
        XCTAssertFalse(EchoLinkAuth.isPlausibleNonce(Data()), "empty")
        XCTAssertFalse(EchoLinkAuth.isPlausibleNonce(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])))
    }

    // MARK: - The two password types

    func testTheTwoPasswordTypesAreNotInterchangeable() {
        // The compiler enforces this; the test records *why* it matters, so
        // nobody collapses them into a typealias later. A proxied session
        // carries both secrets a few bytes apart on the same stream: this one
        // is hashed, the other is relayed in cleartext to the directory server.
        let proxy = EchoLinkProxyPassword.publicProxy
        let account = EchoLinkAccountPassword("not-the-same-thing")

        XCTAssertEqual(proxy.value, "PUBLIC")
        XCTAssertEqual(account.value, "not-the-same-thing")
    }

    func testPasswordsAreRedactedInDescriptions() {
        // String interpolation is the usual way a credential reaches a log.
        let proxy = EchoLinkProxyPassword("s3cret-proxy")
        let account = EchoLinkAccountPassword("s3cret-account")

        XCTAssertFalse("\(proxy)".contains("s3cret"))
        XCTAssertFalse("\(account)".contains("s3cret"))
        XCTAssertEqual(proxy.description, "<proxy password>")
        XCTAssertEqual(account.description, "<account password>")
    }
}
