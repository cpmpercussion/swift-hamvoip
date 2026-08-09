// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import IAX2Kit

/// Tests for RFC 5456 §8.6.15 MD5 challenge/response authentication.
///
/// All "expected" digests below were computed independently of this code,
/// using the macOS `md5` CLI (cross-checked with `openssl dgst -md5` for the
/// first two) on the literal challenge‖secret byte string, e.g.:
///
///   printf '%s' '12345password' | md5
///
/// Nothing here was derived by running `md5Response` and copying its output
/// — that would test nothing. Nor were any expected values taken from
/// Asterisk, iaxclient, or any other implementation (CLEAN-ROOM, see
/// docs/DEVELOPMENT-PLAN.md); they come only from the `md5`/`openssl` CLI
/// tools applied to the exact byte string RFC 5456 §8.6.15 specifies:
/// challenge string, then password string, no separator.
final class IAX2AuthTests: XCTestCase {

    // MARK: - Hand-computed test vectors

    /// `printf '%s' '' | md5`  ->  d41d8cd98f00b204e9800998ecf8427e
    /// (the well-known MD5 of the empty string; also covers "both empty").
    func testVectorEmptyChallengeEmptySecret() {
        XCTAssertEqual(
            IAX2Auth.md5Response(challenge: "", secret: ""),
            "d41d8cd98f00b204e9800998ecf8427e"
        )
    }

    /// `printf '%s' '12345password' | md5`  ->  40b1b887502902a8ce61a16e44630f7c
    /// Cross-checked: `printf '%s' '12345password' | openssl md5` gives the
    /// same digest.
    func testVectorNumericChallengeWithSecret() {
        XCTAssertEqual(
            IAX2Auth.md5Response(challenge: "12345", secret: "password"),
            "40b1b887502902a8ce61a16e44630f7c"
        )
    }

    /// `printf '%s' 'helloworld' | md5`  ->  fc5e038d38a57032085441e7fe7010b0
    func testVectorWordChallengeWithWordSecret() {
        XCTAssertEqual(
            IAX2Auth.md5Response(challenge: "hello", secret: "world"),
            "fc5e038d38a57032085441e7fe7010b0"
        )
    }

    /// `python3 -c "print('a'*1000+'zzz', end='')" | md5`
    ///   ->  a9275e3457919a89105c761cfad63dc3
    /// A 1000-character challenge plus a short secret, to exercise inputs
    /// far larger than a single MD5 block (64 bytes).
    func testVectorVeryLongChallenge() {
        let challenge = String(repeating: "a", count: 1000)
        XCTAssertEqual(
            IAX2Auth.md5Response(challenge: challenge, secret: "zzz"),
            "a9275e3457919a89105c761cfad63dc3"
        )
    }

    // MARK: - Empty inputs, individually

    /// `printf '%s' 'abc' | md5`  ->  900150983cd24fb0d6963f7d28e17f72
    /// Used for both "challenge empty, secret non-empty" and "challenge
    /// non-empty, secret empty" below: concatenation with an empty operand
    /// on either side reduces to the MD5 of the other operand alone, so the
    /// same reference digest checks both cases.
    func testVectorEmptyChallengeNonEmptySecret() {
        XCTAssertEqual(
            IAX2Auth.md5Response(challenge: "", secret: "abc"),
            "900150983cd24fb0d6963f7d28e17f72"
        )
    }

    func testVectorNonEmptyChallengeEmptySecret() {
        XCTAssertEqual(
            IAX2Auth.md5Response(challenge: "abc", secret: ""),
            "900150983cd24fb0d6963f7d28e17f72"
        )
    }

    // MARK: - Non-ASCII / multi-byte UTF-8

    /// `printf '%s' 'héllowörld' | md5`  ->  eb009122ba992fce97ed9592286d6bfb
    /// (cross-checked with `openssl dgst -md5`).
    ///
    /// "héllo" and "wörld" each contain one 2-byte UTF-8 character (é and ö
    /// are U+00E9 / U+00F6, each encoded as 2 bytes), so the concatenated
    /// UTF-8 byte string is 12 bytes long even though the two Swift
    /// `String`s together have 10 `Character`s. `md5Response` must hash the
    /// UTF-8 *bytes* of challenge‖secret, not some per-character or
    /// per-Unicode-scalar encoding, for this to match.
    func testVectorNonASCIITwoByteCharacters() {
        XCTAssertEqual(
            IAX2Auth.md5Response(challenge: "héllo", secret: "wörld"),
            "eb009122ba992fce97ed9592286d6bfb"
        )
    }

    /// `printf '%s' '🎙️📻' | md5`  ->  6d4f965cc83f530939b5cae0f718911c
    ///
    /// "🎙️" is itself two Unicode scalars (U+1F399 MICROPHONE, 4 UTF-8
    /// bytes, followed by U+FE0F VARIATION SELECTOR-16, 3 UTF-8 bytes) that
    /// Swift presents as a single `Character` (extended grapheme cluster);
    /// "📻" is one scalar, U+1F4FB, 4 UTF-8 bytes. The concatenated UTF-8
    /// byte string is therefore 11 bytes from what Swift sees as 2
    /// `Character`s. This vector specifically catches any accidental
    /// per-`Character`/per-scalar processing instead of raw UTF-8 bytes.
    func testVectorMultiScalarGraphemeClusters() {
        XCTAssertEqual(
            IAX2Auth.md5Response(challenge: "🎙️", secret: "📻"),
            "6d4f965cc83f530939b5cae0f718911c"
        )
    }

    // MARK: - Output shape

    func testOutputIsAlways32LowercaseHexCharacters() {
        let cases: [(String, String)] = [
            ("", ""),
            ("x", "y"),
            ("héllo", "wörld"),
            (String(repeating: "q", count: 5000), String(repeating: "r", count: 5000)),
        ]
        let hexDigits = Set("0123456789abcdef")
        for (challenge, secret) in cases {
            let result = IAX2Auth.md5Response(challenge: challenge, secret: secret)
            XCTAssertEqual(result.count, 32, "expected 32 hex characters for (\(challenge.debugDescription), \(secret.debugDescription))")
            XCTAssertTrue(
                result.allSatisfy { hexDigits.contains($0) },
                "expected only lowercase hex digits, got \(result)"
            )
            XCTAssertEqual(result, result.lowercased())
        }
    }

    // MARK: - Determinism

    func testSameInputsAlwaysProduceTheSameOutput() {
        let a = IAX2Auth.md5Response(challenge: "repeatable-challenge", secret: "s3cr3t")
        let b = IAX2Auth.md5Response(challenge: "repeatable-challenge", secret: "s3cr3t")
        let c = IAX2Auth.md5Response(challenge: "repeatable-challenge", secret: "s3cr3t")
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }

    func testDifferentInputsProduceDifferentOutput() {
        // Not a cryptographic claim, just a sanity check that the function
        // is actually sensitive to its inputs (concatenation order matters,
        // per §8.6.15 "challenge string and the password string" in that
        // order) rather than e.g. accidentally hashing a constant.
        XCTAssertNotEqual(
            IAX2Auth.md5Response(challenge: "abc", secret: "def"),
            IAX2Auth.md5Response(challenge: "def", secret: "abc")
        )
    }

    // MARK: - Custom encoding hook (OQ-5 swap point)

    func testCustomEncodingIsUsedInsteadOfTheDefault() {
        let upper = IAX2Auth.TextDigestEncoding { bytes in
            bytes.map { String(format: "%02X", $0) }.joined()
        }
        let lower = IAX2Auth.md5Response(challenge: "abc", secret: "")
        let asUpper = IAX2Auth.md5Response(challenge: "abc", secret: "", encoding: upper)
        XCTAssertEqual(asUpper, lower.uppercased())
        XCTAssertEqual(asUpper, "900150983CD24FB0D6963F7D28E17F72")
    }

    // MARK: - Auth method selection (§8.6.13)

    func testMD5OfferedAloneIsSelected() throws {
        let chosen = try IAX2Auth.selectAuthMethod(offered: .md5)
        XCTAssertEqual(chosen, .md5)
    }

    func testMD5OfferedAlongsideRSAIsStillSelected() throws {
        let chosen = try IAX2Auth.selectAuthMethod(offered: [.md5, .rsa])
        XCTAssertEqual(chosen, .md5)
    }

    func testRSAOnlyIsUnsupported() {
        XCTAssertThrowsError(try IAX2Auth.selectAuthMethod(offered: .rsa)) { error in
            guard case IAX2Auth.AuthMethodError.unsupportedAuthMethod(let offered) = error else {
                return XCTFail("expected unsupportedAuthMethod, got \(error)")
            }
            XCTAssertEqual(offered, .rsa)
        }
    }

    func testReservedPlaintextBitOnlyIsUnsupported() {
        XCTAssertThrowsError(try IAX2Auth.selectAuthMethod(offered: .reserved)) { error in
            guard case IAX2Auth.AuthMethodError.unsupportedAuthMethod(let offered) = error else {
                return XCTFail("expected unsupportedAuthMethod, got \(error)")
            }
            XCTAssertEqual(offered, .reserved)
        }
    }

    func testNothingOfferedIsUnsupported() {
        XCTAssertThrowsError(try IAX2Auth.selectAuthMethod(offered: [])) { error in
            guard case IAX2Auth.AuthMethodError.unsupportedAuthMethod(let offered) = error else {
                return XCTFail("expected unsupportedAuthMethod, got \(error)")
            }
            XCTAssertEqual(offered, [])
        }
    }

    func testAuthMethodErrorDescriptionMentionsUnsupportedMethodsByName() {
        let error = IAX2Auth.AuthMethodError.unsupportedAuthMethod(offered: .rsa)
        let text = error.description
        XCTAssertTrue(text.contains("MD5"))
        XCTAssertTrue(text.contains("RSA") || text.contains("0x0004"))
    }
}
