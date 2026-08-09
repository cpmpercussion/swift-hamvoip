// SPDX-License-Identifier: Apache-2.0

#if canImport(CryptoKit)
import CryptoKit
#else
#error("IAX2Auth requires CryptoKit's Insecure.MD5 for RFC 5456 §8.6.15 MD5 challenge/response. This package targets iOS 16+ / macOS 13+, where CryptoKit is always available; if this fires, the build is targeting an unsupported platform and MD5 authentication has no fallback implementation here.")
#endif

import Foundation

/// IAX2 MD5 challenge/response authentication.
///
/// RFC 5456 §6.2 (call setup with auth), §6.2.6/§6.2.7 (challenge/response
/// exchange), §8.6.13-8.6.15 (AUTHMETHODS, CHALLENGE, MD5 RESULT IEs), and
/// §10 (cleartext eliminated). See `docs/reference/RFC5456-NOTES.md` §13 for
/// the transcription this file was written from.
///
/// Clean-room: written from RFC 5456 and the notes only. In particular, the
/// text encoding of the MD5 RESULT IE (hex? case? padding?) is *not*
/// specified by the RFC (notes §13, "RFC ambiguous"), and that gap is
/// deliberately not resolved by reading Asterisk or iaxclient — see OQ-5 on
/// `textEncodedDigest(_:encoding:)` below.
///
/// Only MD5 is implemented. RSA (AUTHMETHODS `0x0004`, §8.6.16) is
/// recognised only so it can be reported and rejected; it is out of scope
/// for v1. There is no plaintext path at all: AUTHMETHODS `0x0001` is
/// "Reserved (was Plaintext)" (§8.6.13), the PASSWORD IE (`0x07`) has no
/// defining subsection, and §10 says cleartext auth "has been eliminated".
public enum IAX2Auth {

    // MARK: - Auth method negotiation (§8.6.13)

    /// The AUTHMETHODS IE (`0x0e`) bitmask a peer offers in AUTHREQ/REGAUTH.
    public struct AuthMethods: OptionSet, Sendable, Equatable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        /// `0x0001` — "Reserved (was Plaintext)" (§8.6.13). §10: cleartext
        /// auth "has been eliminated". Modelled only so it can be named in
        /// error messages; this client never selects it and has no
        /// plaintext code path to select.
        public static let reserved = AuthMethods(rawValue: 0x0001)

        /// `0x0002` — MD5 challenge/response (§8.6.15). The only method
        /// this client implements.
        public static let md5 = AuthMethods(rawValue: 0x0002)

        /// `0x0004` — RSA challenge/response (§8.6.16). Recognised for
        /// diagnostics only; out of scope for v1 (see `selectAuthMethod`).
        public static let rsa = AuthMethods(rawValue: 0x0004)
    }

    /// Failure selecting a usable auth method from a peer's AUTHMETHODS.
    public enum AuthMethodError: Error, Equatable, CustomStringConvertible {
        /// The peer's AUTHMETHODS offered nothing this client supports:
        /// RSA only, the withdrawn plaintext bit only, an empty/unknown
        /// bitmask, or any combination thereof without MD5.
        case unsupportedAuthMethod(offered: AuthMethods)

        public var description: String {
            switch self {
            case .unsupportedAuthMethod(let offered):
                let hex = String(format: "0x%04x", offered.rawValue)
                return "IAX2Auth: no supported auth method in AUTHMETHODS \(hex). " +
                    "This client supports MD5 (0x0002) only. RSA (0x0004) is out of " +
                    "scope for v1, and plaintext (0x0001) was withdrawn by RFC 5456 §10."
            }
        }
    }

    /// Chooses an authentication method from the AUTHMETHODS bitmask a peer
    /// offered (§8.6.13). MD5 is selected whenever offered, even alongside
    /// RSA, because MD5 is the only method this client implements. Any
    /// other case — RSA only, the reserved plaintext bit only, or nothing
    /// recognised — fails with a descriptive error. There is deliberately
    /// no silent fallback to a plaintext path: this codebase has none.
    public static func selectAuthMethod(offered: AuthMethods) throws -> AuthMethods {
        guard offered.contains(.md5) else {
            throw AuthMethodError.unsupportedAuthMethod(offered: offered)
        }
        return .md5
    }

    // MARK: - MD5 challenge/response (§8.6.15)

    /// How a raw 128-bit MD5 digest is rendered as the text the MD5 RESULT
    /// IE (`0x10`) carries. A value type (rather than a free function or a
    /// hardcoded format) so a live-node experiment can substitute a
    /// different rendering — e.g. uppercase, or something else entirely —
    /// without touching `md5Response` or the digest computation. See OQ-5
    /// on `textEncodedDigest(_:encoding:)`.
    public struct TextDigestEncoding: Sendable, Equatable, CustomStringConvertible {
        /// A short name for this rendering, used in diagnostics and to give the
        /// type an identity.
        ///
        /// Equality compares names, because Swift closures cannot be compared.
        /// Two encodings sharing a name are therefore treated as the same
        /// encoding — give distinct renderings distinct names.
        public let name: String

        private let render: @Sendable ([UInt8]) -> String

        public init(name: String = "custom", _ render: @escaping @Sendable ([UInt8]) -> String) {
            self.name = name
            self.render = render
        }

        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }

        public var description: String { name }

        fileprivate func callAsFunction(_ digestBytes: [UInt8]) -> String {
            render(digestBytes)
        }

        /// OQ-5's shipped assumption: lowercase, 32-character hexadecimal,
        /// each byte zero-padded to exactly two hex digits. See the
        /// `// OQ-5:` comment on `textEncodedDigest(_:encoding:)` for why
        /// this is a documented guess rather than a spec fact.
        public static let oq5Default = TextDigestEncoding(name: "lowercase-hex") { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Computes the MD5 RESULT value (§8.6.15) for an AUTHREP/REGREQ sent
    /// in response to a CHALLENGE (§8.6.14).
    ///
    /// Per §8.6.15: "The MD5 Result value is computed by taking the MD5
    /// [RFC1321] digest of the challenge string and the password string" —
    /// concatenated **challenge first, then password**, with **no
    /// separator** (none is specified anywhere in the RFC or the notes).
    /// Both strings are taken as their UTF-8 byte representation, per
    /// §8.6's general rule that IE text is UTF-8; this matters for
    /// non-ASCII secrets/challenges, since it is the *bytes* that are
    /// concatenated and hashed, not Unicode scalars or grapheme clusters.
    ///
    /// Related but distinct: §7.4 takes the **same** concatenation
    /// (challenge, then password) but uses the **raw 128-bit digest**
    /// directly as an AES-128 key for optional call encryption, not a text
    /// form. That is a separate feature (call encryption) with its own
    /// negotiation via the ENCRYPTION IE, is out of scope for this task,
    /// and is not implemented anywhere in this file or elsewhere in this
    /// repository — encryption is also not permitted for the amateur radio
    /// service in most jurisdictions, which is a second, independent
    /// reason not to build it.
    ///
    /// - Parameters:
    ///   - challenge: The CHALLENGE IE (`0x0f`) string as received from the
    ///     peer, verbatim (no normalization is applied — see notes §13 on
    ///     the open question of whether stringprep applies here; absent a
    ///     stated requirement, this function does not invent one).
    ///   - secret: The shared secret/password configured for this peer.
    ///   - encoding: How to render the raw digest as text. Defaults to
    ///     `TextDigestEncoding.oq5Default`; override only to run a
    ///     deliberate experiment against a live node (see OQ-5).
    /// - Returns: The text to place in the MD5 RESULT IE (`0x10`).
    public static func md5Response(
        challenge: String,
        secret: String,
        encoding: TextDigestEncoding = .oq5Default
    ) -> String {
        var message = Data(challenge.utf8)
        message.append(contentsOf: secret.utf8)
        let digest = Insecure.MD5.hash(data: message)
        return textEncodedDigest(Array(digest), encoding: encoding)
    }

    /// Renders a raw 16-byte MD5 digest as MD5 RESULT IE text. Isolated as
    /// its own named function for exactly one reason: so the encoding
    /// assumption below lives in one place and can be changed in one place.
    ///
    /// // OQ-5: RFC 5456 §8.6.15 says the MD5 RESULT IE carries the
    /// // "UTF-8-encoded challenge result" but never states what that text
    /// // looks like — hexadecimal or some other scheme, upper or lower
    /// // case, zero-padded to 32 characters or not. §8.6.16 (RSA RESULT)
    /// // has the identical gap. No other part of RFC 5456 speaks to it.
    /// // This cannot be resolved by reading a peer implementation:
    /// // docs/DEVELOPMENT-PLAN.md's clean-room policy forbids consulting
    /// // Asterisk or iaxclient source specifically to settle this
    /// // question, and that prohibition matters unusually much here
    /// // because it is the tempting shortcut. So we SHIP AN ASSUMPTION —
    /// // lowercase, 32-character, zero-padded hexadecimal
    /// // (`TextDigestEncoding.oq5Default`) — as the only rendering that is
    /// // both "UTF-8-encoded" text and preserves all 128 digest bits
    /// // without inventing an unspecified binary-to-text scheme of our
    /// // own. This is a documented guess, not a specification fact.
    /// // IAX-9 / CLI-1 (a real AUTHREQ/AUTHREP exchange with a live
    /// // AllStar node) is what will confirm or correct it. If a live node
    /// // rejects an AUTHREP built this way, change the `encoding`
    /// // argument at the call site (or add a new `TextDigestEncoding`),
    /// // not the digest computation in `md5Response` above.
    static func textEncodedDigest(_ digestBytes: [UInt8], encoding: TextDigestEncoding = .oq5Default) -> String {
        encoding(digestBytes)
    }
}
