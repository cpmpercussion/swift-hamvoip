// SPDX-License-Identifier: Apache-2.0

#if canImport(CryptoKit)
import CryptoKit
#else
#error("EchoLinkAuth requires CryptoKit's Insecure.MD5 for the proxy login digest. This package targets iOS 16+ / macOS 13+, where CryptoKit is always available; if this fires, the build is targeting an unsupported platform and there is no fallback MD5 here.")
#endif

import Foundation

// MARK: - Two passwords, two types

/// The password used to authenticate to an EchoLink **proxy**.
///
/// Distinct from `EchoLinkAccountPassword` on purpose, and the distinction is
/// load-bearing rather than tidy. A proxied session carries two different
/// secrets a few bytes apart on the same TCP stream:
///
/// - this one, hashed into the proxy login digest, and on a public proxy it is
///   the literal string `PUBLIC` — not a secret at all;
/// - the operator's account password, relayed *in cleartext* to the directory
///   server inside a `0x02` frame (FR-3.4, EL-6).
///
/// Making them separate types means the account password cannot be passed where
/// the proxy password belongs, which would put a real credential into a digest
/// the wrong way round, or — much worse in the other direction — send `PUBLIC`
/// where a real login was needed and fail confusingly.
public struct EchoLinkProxyPassword: Sendable, Equatable, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// The convention for public proxies, and the only value ever observed.
    ///
    /// The digest construction below is confirmed only against this password.
    /// A private proxy with a real password should use the same construction —
    /// that is the natural reading, and nothing in the evidence contradicts it
    /// — but it has not been observed. Treat the password as a configuration
    /// value and the construction as established.
    public static let publicProxy = EchoLinkProxyPassword("PUBLIC")
}

extension EchoLinkProxyPassword: CustomStringConvertible {
    /// Redacted, so a proxy password cannot reach a log through string
    /// interpolation. `PUBLIC` is not secret, but a private proxy's password
    /// is, and the type cannot tell which it holds.
    public var description: String { "<proxy password>" }
}

/// The operator's own EchoLink **account** password (FR-3.4).
///
/// Never hashed and never sent to a proxy: it is relayed to the directory
/// server, in cleartext, inside the directory login line (EL-6). See
/// `EchoLinkProxyPassword` for why this is a separate type.
///
/// ⚠️ This value must never be logged, echoed in an error, or written to a
/// fixture. `description` is redacted, which handles the accidental
/// interpolation; `value` is what actually goes on the wire and is the only
/// place it should ever be read.
public struct EchoLinkAccountPassword: Sendable, Equatable, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension EchoLinkAccountPassword: CustomStringConvertible {
    public var description: String { "<account password>" }
}

// MARK: - Proxy authentication

/// The EchoLink proxy login digest.
///
/// **Clean-room provenance.** EchoLink has no published specification, so
/// unlike `IAX2Auth` — which has RFC 5456 §8.6.15 to read, ambiguous as it is —
/// this construction was recovered from captures of the maintainer's own
/// sessions and nothing else. The method, from the OQ-9 work: two captures each
/// contained a nonce and the digest the client returned; 198 combinations were
/// tested per capture (6 candidate passwords × 3 nonce forms × 11 orderings);
/// exactly one combination reproduced the observed digest, and it reproduced
/// **both**, across two different proxies and two different nonces.
/// Reproducing 128 bits twice rules out coincidence. Both pairs are pinned as
/// test vectors in `EchoLinkAuthTests`.
///
/// Four things that search corrected, each of which had been the obvious guess,
/// and all four are ways this will be "fixed" wrongly later:
///
/// 1. **Password first.** `MD5(nonce ‖ password)` — the ordering RFC 5456's
///    phrasing suggests for IAX2 — does not match. It is
///    `MD5(password ‖ nonce)`.
/// 2. **The nonce is hashed as its eight ASCII characters**, not as the four
///    bytes those characters spell.
/// 3. **The password is not the operator's account password.** On a public
///    proxy it is the literal string `PUBLIC`. The account password never
///    enters proxy authentication at all.
/// 4. **The digest goes on the wire as raw binary, not hex text.** This is the
///    exact opposite of what OQ-5 settled for IAX2's MD5 RESULT, which is a
///    lowercase 32-character hex string. The two protocols demonstrably do not
///    agree here, and assuming they do is the most likely way for the IAX2
///    convention to leak in — `testDigestIsRawBytesNotHexText` exists to catch
///    exactly that.
public enum EchoLinkAuth {
    /// The nonce a proxy sends is always this many ASCII characters.
    public static let nonceLength = 8

    /// The raw digest is MD5, so always this many bytes.
    public static let digestLength = 16

    /// `MD5(password ‖ nonce)` as **16 raw bytes**.
    ///
    /// - Parameters:
    ///   - password: The proxy password — `.publicProxy` on a public proxy.
    ///   - nonce: The proxy's challenge, as the eight ASCII characters it sent,
    ///     verbatim. Not decoded from hex; see point 2 above.
    public static func proxyDigest(password: EchoLinkProxyPassword, nonce: String) -> Data {
        var message = Data(password.value.utf8)
        message.append(contentsOf: nonce.utf8)
        return Data(Insecure.MD5.hash(data: message))
    }

    /// The client's half of the login exchange, ready to write to the stream:
    /// the callsign, LF-terminated, followed by the 16 raw digest bytes with
    /// **no length prefix**.
    ///
    /// The callsign is sent alongside the digest, not hashed into it — which is
    /// worth stating because hashing it in is the natural assumption and would
    /// produce a digest that never matches.
    public static func proxyLoginMessage(
        callsign: String,
        password: EchoLinkProxyPassword,
        nonce: String
    ) -> Data {
        var message = Data(callsign.utf8)
        message.append(0x0A)  // LF
        message.append(proxyDigest(password: password, nonce: nonce))
        return message
    }

    /// Whether `bytes` looks like a proxy nonce: eight ASCII hexadecimal
    /// characters.
    ///
    /// Used to sanity-check the unframed login prefix before treating it as a
    /// challenge. Permissive about case, because nothing establishes that a
    /// proxy must send lowercase — both observed nonces happen to be lowercase,
    /// which is evidence about two proxies and not about the protocol.
    public static func isPlausibleNonce(_ bytes: Data) -> Bool {
        guard bytes.count == nonceLength else { return false }
        return bytes.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte)   // 0-9
                || (0x61 ... 0x66).contains(byte)  // a-f
                || (0x41 ... 0x46).contains(byte)  // A-F
        }
    }
}
