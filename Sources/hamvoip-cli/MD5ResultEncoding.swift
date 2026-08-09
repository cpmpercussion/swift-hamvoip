// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IAX2Kit

/// The candidate answers to **OQ-5**.
///
/// RFC 5456 §8.6.15 says the MD5 RESULT information element (`0x10`) "carries
/// the UTF-8-encoded challenge result" and says nothing else: not hexadecimal
/// versus anything else, not case, not padding. `docs/reference/RFC5456-NOTES.md`
/// §13 records the gap and the instruction — "Record what a live peer accepts
/// as an observation; do not treat it as spec." The clean-room policy (LP-2)
/// forbids settling it by reading Asterisk or iaxclient, which is exactly the
/// shortcut that would otherwise be taken here.
///
/// So the question is settled the only honest way: by asking a node. This type
/// is the list of things worth asking about, and each case is a complete,
/// self-contained hypothesis about what those bytes are.
///
/// The four are not arbitrary:
///
/// - ``lowercaseHex`` is what `IAX2Auth.TextDigestEncoding.oq5Default` ships,
///   and therefore what the whole stack currently does. Confirming it is the
///   most likely outcome and the cheapest to check.
/// - ``uppercaseHex`` differs from it in exactly one bit per alphabetic
///   character. If a node is comparing strings rather than parsing them, this
///   is the failure that would look like a wrong password.
/// - ``base64`` is the other common way to render a digest as text, and is
///   still "UTF-8-encoded" in the RFC's sense.
/// - ``rawBytes`` is the hypothesis that the RFC's "UTF-8-encoded" is
///   describing the IE's general string-ness rather than the digest's
///   rendering, and that the 16 digest bytes go on the wire unchanged. It is
///   the one candidate that cannot be expressed through
///   `IAX2Auth.md5Response`, because that function returns a `String` — it is
///   built as a raw IE instead.
enum MD5ResultEncoding: String, CaseIterable, ExpressibleByArgument {
    /// 32 characters, `0`–`9` and `a`–`f`. The shipped assumption.
    case lowercaseHex = "lowercase-hex"
    /// 32 characters, `0`–`9` and `A`–`F`.
    case uppercaseHex = "uppercase-hex"
    /// 24 characters of standard base64, including the trailing `=`.
    case base64 = "base64"
    /// The 16 raw digest bytes, no text encoding at all.
    case rawBytes = "raw-bytes"

    static let allValueStrings: [String] = allCases.map(\.rawValue)

    /// One line explaining what this candidate is, for `--help` and for the
    /// experiment's own transcript.
    var explanation: String {
        switch self {
        case .lowercaseHex:
            return "32 lowercase hex characters — the assumption IAX2Kit ships (oq5Default)"
        case .uppercaseHex:
            return "32 uppercase hex characters"
        case .base64:
            return "24 characters of standard base64 of the 16 digest bytes"
        case .rawBytes:
            return "the 16 raw digest bytes, not text at all"
        }
    }

    /// How this candidate renders a digest, where it is expressible as text.
    /// `nil` for ``rawBytes``, which is the point of that case.
    var textEncoding: IAX2Auth.TextDigestEncoding? {
        switch self {
        case .lowercaseHex:
            return .oq5Default
        case .uppercaseHex:
            return IAX2Auth.TextDigestEncoding { bytes in
                bytes.map { String(format: "%02X", $0) }.joined()
            }
        case .base64:
            return IAX2Auth.TextDigestEncoding { bytes in Data(bytes).base64EncodedString() }
        case .rawBytes:
            return nil
        }
    }

    /// The MD5 RESULT information element to put in an AUTHREP or a REGREQ.
    ///
    /// The text candidates go through `IAX2Auth.md5Response`, so the thing
    /// under test is only the rendering — the concatenation rule
    /// (`MD5(challenge ‖ secret)`, challenge first, no separator, §8.6.15)
    /// stays in IAX2Kit and is not restated here. ``rawBytes`` builds
    /// `.unknown(id: 0x10, …)` because `InformationElement.md5Result` takes a
    /// `String` and would UTF-8-encode any non-ASCII digest byte into two
    /// bytes, which is a different experiment from the one intended.
    func informationElement(challenge: String, secret: String) -> InformationElement {
        if let textEncoding {
            let text = IAX2Auth.md5Response(
                challenge: challenge, secret: secret, encoding: textEncoding)
            return .md5Result(text)
        }
        return .unknown(id: 0x10, data: MD5ResultEncoding.digest(challenge: challenge, secret: secret))
    }

    /// What this candidate would put on the wire, as a printable string, so a
    /// human can see what was tried.
    func rendering(challenge: String, secret: String) -> String {
        if let textEncoding {
            return IAX2Auth.md5Response(challenge: challenge, secret: secret, encoding: textEncoding)
        }
        let bytes = MD5ResultEncoding.digest(challenge: challenge, secret: secret)
        return "<" + bytes.map { String(format: "%02x", $0) }.joined() + " as 16 raw bytes>"
    }

    // MARK: The digest itself

    /// Holds the digest the encoding closure was handed. A class because
    /// `TextDigestEncoding`'s closure is `@Sendable` and a captured `var`
    /// cannot be mutated from one.
    private final class DigestBox: @unchecked Sendable {
        var bytes: [UInt8] = []
    }

    /// The raw 16-byte MD5 digest of `challenge ‖ secret`.
    ///
    /// Obtained by handing `IAX2Auth.md5Response` an encoding that records its
    /// input rather than by hashing here. That looks indirect, and it is
    /// deliberate: **what** gets hashed is a specification question that IAX-4
    /// already answered and tested, and a second copy of the concatenation rule
    /// in this file could drift from it. OQ-5 is a question about the
    /// rendering, so only the rendering is re-implemented.
    static func digest(challenge: String, secret: String) -> [UInt8] {
        let box = DigestBox()
        _ = IAX2Auth.md5Response(
            challenge: challenge,
            secret: secret,
            encoding: IAX2Auth.TextDigestEncoding { bytes in
                box.bytes = bytes
                return ""
            })
        return box.bytes
    }
}
