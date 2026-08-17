// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - The token

/// A Web Transceiver token: the thing an AllStarLink node accepts in place of
/// an entry in its `iax.conf`.
///
/// The node passes CALLING NAME to allstarlink.org, which resolves the token to
/// a callsign — so this string *is* the operator's identity proof for a WT call
/// (see `docs/CLI.md` §11). Two consequences shape this type:
///
/// - **It is a credential with a lifetime, not a nonce.** The portal returns the
///   same 12 lowercase-hex characters on every call, which is why an app is
///   expected to store it (Keychain) rather than fetch one per session.
/// - **It must not fall into a log.** ``description`` is redacted for that
///   reason; the string itself is only available through ``value``, so leaking
///   it takes a deliberate keystroke.
public struct WebTransceiverToken: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The token as the portal returned it. Pass this as IAX2's CALLING NAME —
    /// unmodified, and in particular not upper-cased, which would corrupt it.
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// The number of characters every token observed so far has had.
    public static let expectedLength = 12

    /// Whether the token has the shape every observed token has had: exactly 12
    /// lowercase hexadecimal characters.
    ///
    /// Advisory, and deliberately not enforced by ``AllStarLinkPortalTokenFetcher``.
    /// The endpoint is named `legacy` and a replacement is expected (OQ-10,
    /// caveat 2); refusing an unfamiliar-looking token would turn a widened
    /// format into a hard failure, when the only thing that decides whether a
    /// token works is the node. A caller that wants to warn can ask.
    public var isWellFormed: Bool {
        value.count == Self.expectedLength
            && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Redacted. See the type's note on logging.
    public var description: String { "WebTransceiverToken(<\(value.count) chars redacted>)" }
}

// MARK: - Errors

/// Why fetching a Web Transceiver token failed.
///
/// The three `status: "ERR"` messages the endpoint is known to return are
/// separate cases because they are separate operator problems: a wrong password
/// is fixed by typing it again, and a rejected payload means the endpoint moved
/// and no amount of retyping will help.
public enum WebTransceiverTokenError: Error, Equatable, CustomStringConvertible {
    /// `msg: "login failed"` — the callsign/password pair was not accepted.
    /// The one case where re-prompting the operator is the right response.
    case loginFailed

    /// `msg: "Invalid JSON payload"` — the body was not JSON the endpoint would
    /// read. We always send well-formed JSON, so in practice this means the
    /// contract changed.
    case invalidJSONPayload

    /// `msg: "Invalid JSON fields"` — the JSON parsed but `username` and
    /// `password` were not both there under those exact names. Again: from this
    /// client, a contract change rather than anything the operator did.
    case invalidJSONFields

    /// `status: "ERR"` with a `msg` we have not seen before. Carried verbatim
    /// because a message we cannot interpret is still the most useful thing to
    /// show someone.
    case rejected(message: String)

    /// The response was not the JSON object documented in `docs/CLI.md` §11.1 —
    /// unparseable, or parsed with no `status` we could act on. Payload is for
    /// logging; it deliberately does not contain the request.
    case malformedResponse(String)

    /// The request never completed, or the server answered with an HTTP error.
    case requestFailed(String)

    public var description: String {
        switch self {
        case .loginFailed:
            return
                "the portal rejected the callsign and password — allstarlink.org portal "
                + "logins are callsign/password, and this is not your node secret"
        case .invalidJSONPayload:
            return
                "the portal did not accept the request body as JSON, which from this client "
                + "means the login endpoint has changed (see OQ-10)"
        case .invalidJSONFields:
            return
                "the portal did not find the fields it wanted in the request, which from "
                + "this client means the login endpoint has changed (see OQ-10)"
        case .rejected(let message):
            return "the portal refused the login: \(message)"
        case .malformedResponse(let detail):
            return "the portal's answer was not the expected JSON: \(detail)"
        case .requestFailed(let detail):
            return "could not reach the portal login endpoint: \(detail)"
        }
    }
}

// MARK: - The seam

/// Where a Web Transceiver token comes from.
///
/// A protocol for two reasons. The first is the usual one (AU-5): the real
/// implementation makes an HTTPS request and no unit test may touch the
/// network. The second is specific — the endpoint behind it is named
/// `auth-wt-legacy`, and AllStarLink's ASL3-Manual issue #229 sits under a
/// project called "WebTransceiver Login API Replacement" (OQ-10, caveat 2). The
/// successor should be a second conformance to this protocol, not a rewrite of
/// everything that wanted a token.
public protocol WebTransceiverTokenSource: Sendable {
    /// Exchanges portal credentials for a token.
    ///
    /// - Parameters:
    ///   - username: the operator's callsign — portal logins are
    ///     callsign/password.
    ///   - password: the **portal** password. Not a node secret, and not the
    ///     static `allstar` secret a WT call presents.
    /// - Throws: ``WebTransceiverTokenError``.
    func token(username: String, password: String) async throws -> WebTransceiverToken
}

// MARK: - The portal implementation

/// Fetches a token from allstarlink.org's Web Transceiver login endpoint.
///
/// The observed contract, established against the live portal on 2026-08-17 and
/// written up in `docs/CLI.md` §11.1: `POST` a JSON body of exactly
/// `{"username":…,"password":…}`, and a success is
/// `{"status":"OK","auth":1,"token":"1b59df18107e"}`.
///
/// This is the only thing in `IAX2Kit` that speaks HTTP. It lives here rather
/// than in the CLI because the app needs it too — the alternative was every
/// caller of the library reimplementing the same POST.
public struct AllStarLinkPortalTokenFetcher: WebTransceiverTokenSource {
    /// AllStarLink's Web Transceiver login endpoint.
    public static let endpoint = URL(string: "https://allstarlink.org/api/v2/auth-wt-legacy")!

    private let url: URL
    private let timeout: TimeInterval
    private let session: URLSession

    public init(
        url: URL = AllStarLinkPortalTokenFetcher.endpoint,
        timeout: TimeInterval = 15,
        session: URLSession = .shared
    ) {
        self.url = url
        self.timeout = timeout
        self.session = session
    }

    public func token(username: String, password: String) async throws -> WebTransceiverToken {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A login response is never worth reusing, and a cached one would hide
        // a password that has since changed.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try Self.requestBody(username: username, password: password)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebTransceiverTokenError.requestFailed(
                (error as? URLError)?.localizedDescription ?? String(describing: error))
        }

        // The endpoint reports a failed login in the body with HTTP 200, so the
        // status code is checked only to catch the endpoint being gone — and
        // the body is still parsed first when there is one, because its `msg`
        // says more than a number does.
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            if let error = Self.errorFromBody(data) { throw error }
            throw WebTransceiverTokenError.requestFailed("HTTP \(http.statusCode)")
        }
        return try Self.parse(data)
    }

    // MARK: The wire format, without the wire

    /// Encodes the request body.
    ///
    /// Hand-built with `JSONEncoder` over a two-field type rather than string
    /// interpolation so that a password containing a quote or a backslash is
    /// escaped rather than producing `Invalid JSON payload`.
    ///
    /// - Throws: ``WebTransceiverTokenError/requestFailed(_:)`` if the
    ///   credentials cannot be encoded, which in practice they always can.
    public static func requestBody(username: String, password: String) throws -> Data {
        // The key names are the wire contract and both are exact; a Swift
        // property name that happened to differ would be a silent 400.
        struct Body: Encodable {
            let username: String
            let password: String
        }
        do {
            return try JSONEncoder().encode(Body(username: username, password: password))
        } catch {
            throw WebTransceiverTokenError.requestFailed(
                "could not encode the login request: \(error)")
        }
    }

    /// Reads a response body.
    ///
    /// Exposed (and free of any I/O) so the mapping from every observed answer
    /// to a typed error is tested against canned bodies rather than against the
    /// portal.
    ///
    /// - Throws: ``WebTransceiverTokenError``.
    public static func parse(_ data: Data) throws -> WebTransceiverToken {
        let body: Response
        do {
            body = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WebTransceiverTokenError.malformedResponse(
                "\(data.count) bytes that did not decode: \(error)")
        }

        switch body.status?.uppercased() {
        case "OK":
            guard let token = body.token, !token.isEmpty else {
                throw WebTransceiverTokenError.malformedResponse("status OK with no token")
            }
            // `auth` has been 1 on every success. Treated as corroboration
            // rather than as the decision: a token we were handed under
            // `status: "OK"` is the thing the node checks, and discarding it
            // over a companion field would be inventing a failure.
            return WebTransceiverToken(token)
        case "ERR":
            throw Self.error(forMessage: body.msg ?? "")
        case let other:
            throw WebTransceiverTokenError.malformedResponse(
                other.map { "unrecognised status \"\($0)\"" } ?? "no status field")
        }
    }

    /// Maps the three observed `msg` values, and keeps anything else verbatim.
    ///
    /// Compared case-insensitively after trimming: two of the three observed
    /// messages are capitalised and one is not, which is enough to say the
    /// capitalisation is nobody's contract.
    static func error(forMessage message: String) -> WebTransceiverTokenError {
        let normalised = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalised {
        case "login failed": return .loginFailed
        case "invalid json payload": return .invalidJSONPayload
        case "invalid json fields": return .invalidJSONFields
        default: return .rejected(message: message)
        }
    }

    /// The typed error a non-2xx body describes, if it describes one at all.
    private static func errorFromBody(_ data: Data) -> WebTransceiverTokenError? {
        guard let body = try? JSONDecoder().decode(Response.self, from: data),
            body.status?.uppercased() == "ERR"
        else { return nil }
        return Self.error(forMessage: body.msg ?? "")
    }

    /// The success and failure bodies are the same object with different fields
    /// present, so every field is optional and the decision is made in
    /// ``parse(_:)``.
    private struct Response: Decodable {
        let status: String?
        let auth: Int?
        let token: String?
        let msg: String?
    }
}
