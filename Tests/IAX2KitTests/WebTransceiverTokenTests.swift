// SPDX-License-Identifier: Apache-2.0

import XCTest
import IAX2Kit

/// IAX-13 — fetching a Web Transceiver token.
///
/// Every response here is a canned body copied from the observed contract in
/// `docs/CLI.md` §11.1; nothing in this file makes a request (AU-5). What is
/// under test is the request body's exact field names, the mapping from each
/// observed answer to a typed error, and the seam a caller substitutes.
final class WebTransceiverTokenTests: XCTestCase {

    private typealias Fetcher = AllStarLinkPortalTokenFetcher

    private func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: The token type

    func testObservedTokenIsWellFormed() {
        XCTAssertTrue(WebTransceiverToken("1b59df18107e").isWellFormed)
    }

    /// The three ways a token can look wrong, and each matters for a different
    /// reason: length, non-hex characters, and — the one that would bite in
    /// practice — an upper-cased token, because `--callsign` upper-cases and a
    /// token routed through that path would arrive corrupted.
    func testMalformedTokensAreRecognised() {
        XCTAssertFalse(WebTransceiverToken("1b59df18107").isWellFormed, "11 characters")
        XCTAssertFalse(WebTransceiverToken("1b59df18107z").isWellFormed, "not hex")
        XCTAssertFalse(WebTransceiverToken("1B59DF18107E").isWellFormed, "upper-cased")
        XCTAssertFalse(WebTransceiverToken("").isWellFormed, "empty")
    }

    /// A token reaching a log is the failure this guards against, so the
    /// redaction is pinned rather than left to a doc comment.
    func testDescriptionDoesNotContainTheToken() {
        let token = WebTransceiverToken("1b59df18107e")
        XCTAssertFalse(token.description.contains("1b59df18107e"))
        XCTAssertFalse("\(token)".contains("1b59df18107e"))
        XCTAssertEqual(token.value, "1b59df18107e", "the value is still reachable deliberately")
    }

    // MARK: The request body

    /// Both key names are the wire contract. A rename on the Swift side would
    /// otherwise surface only as `Invalid JSON fields` from a live portal.
    func testRequestBodyUsesTheExactFieldNames() throws {
        let data = try Fetcher.requestBody(username: "VK1CPM", password: "hunter2")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["password", "username"])
        XCTAssertEqual(object["username"] as? String, "VK1CPM")
        XCTAssertEqual(object["password"] as? String, "hunter2")
    }

    /// Encoded rather than interpolated: a password holding a quote or a
    /// backslash has to survive the trip, and hand-built JSON is where that
    /// goes wrong.
    func testRequestBodyEscapesAwkwardPasswords() throws {
        let awkward = #"a"b\c\#n{}"#
        let data = try Fetcher.requestBody(username: "VK1CPM", password: awkward)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["password"] as? String, awkward)
    }

    // MARK: Parsing a success

    func testParsesTheObservedSuccessResponse() throws {
        let token = try Fetcher.parse(
            body(#"{"status":"OK","auth":1,"token":"1b59df18107e"}"#))
        XCTAssertEqual(token.value, "1b59df18107e")
        XCTAssertTrue(token.isWellFormed)
    }

    /// The endpoint is expected to be replaced (OQ-10, caveat 2), so a token of
    /// an unfamiliar shape is handed back rather than rejected — only the node
    /// decides whether a token works. `isWellFormed` is how a caller warns.
    func testUnfamiliarlyShapedTokenIsAcceptedButNotCalledWellFormed() throws {
        let token = try Fetcher.parse(
            body(#"{"status":"OK","auth":1,"token":"ZZZZ-not-hex-at-all"}"#))
        XCTAssertEqual(token.value, "ZZZZ-not-hex-at-all")
        XCTAssertFalse(token.isWellFormed)
    }

    /// `status: "OK"` and nothing to use is not a success, and must not become
    /// an empty token that fails later as a mysterious REJECT from a node.
    func testOKWithNoTokenIsMalformed() {
        for json in [#"{"status":"OK","auth":1}"#, #"{"status":"OK","auth":1,"token":""}"#] {
            XCTAssertThrowsError(try Fetcher.parse(body(json))) { error in
                guard case .malformedResponse = error as? WebTransceiverTokenError else {
                    return XCTFail("expected .malformedResponse, got \(error)")
                }
            }
        }
    }

    // MARK: Parsing the three observed failures

    /// The point of the typed errors: "your password is wrong" and "the
    /// endpoint moved" are different operator problems, and a settings screen
    /// re-prompts for only one of them.
    func testEachObservedFailureMessageMapsToItsOwnError() {
        let cases: [(String, WebTransceiverTokenError)] = [
            ("login failed", .loginFailed),
            ("Invalid JSON payload", .invalidJSONPayload),
            ("Invalid JSON fields", .invalidJSONFields),
        ]
        for (message, expected) in cases {
            let json = #"{"status":"ERR","msg":"\#(message)"}"#
            XCTAssertThrowsError(try Fetcher.parse(body(json))) { error in
                XCTAssertEqual(error as? WebTransceiverTokenError, expected, message)
            }
        }
    }

    /// Nothing establishes the portal's capitalisation as stable — two of the
    /// three observed messages are capitalised and one is not.
    func testFailureMessageMatchingIgnoresCaseAndSurroundingSpace() {
        for message in ["LOGIN FAILED", " login failed ", "Login Failed"] {
            let json = #"{"status":"ERR","msg":"\#(message)"}"#
            XCTAssertThrowsError(try Fetcher.parse(body(json))) { error in
                XCTAssertEqual(error as? WebTransceiverTokenError, .loginFailed, message)
            }
        }
    }

    /// An `ERR` with nothing to say is the response not being the documented
    /// shape, not a decision the portal made. `.rejected(message: "")` would show
    /// an operator "the portal refused the login:" and then nothing.
    func testERRWithNoMessageIsMalformedRatherThanARejection() {
        for json in [#"{"status":"ERR"}"#, #"{"status":"ERR","msg":""}"#, #"{"status":"ERR","msg":"  "}"#] {
            XCTAssertThrowsError(try Fetcher.parse(body(json))) { error in
                guard case .malformedResponse = error as? WebTransceiverTokenError else {
                    return XCTFail("expected .malformedResponse for \(json), got \(error)")
                }
            }
        }
    }

    /// A message we have not seen is still the most useful thing to show
    /// someone, so it is carried rather than flattened into "login failed".
    func testUnseenFailureMessageIsCarriedVerbatim() {
        let json = #"{"status":"ERR","msg":"account suspended"}"#
        XCTAssertThrowsError(try Fetcher.parse(body(json))) { error in
            XCTAssertEqual(
                error as? WebTransceiverTokenError, .rejected(message: "account suspended"))
        }
    }

    func testNonJSONAndStatuslessBodiesAreMalformed() {
        for json in ["<html>gateway timeout</html>", #"{"auth":0}"#, #"{"status":"WAT"}"#] {
            XCTAssertThrowsError(try Fetcher.parse(body(json))) { error in
                guard case .malformedResponse = error as? WebTransceiverTokenError else {
                    return XCTFail("expected .malformedResponse for \(json), got \(error)")
                }
            }
        }
    }

    /// Distinguishable in prose too: the errors reach an operator as text, and
    /// "wrong password" must not read like "the service is broken".
    func testErrorDescriptionsAreDistinct() {
        let all: [WebTransceiverTokenError] = [
            .loginFailed, .invalidJSONPayload, .invalidJSONFields,
            .rejected(message: "account suspended"),
            .malformedResponse("no status field"), .requestFailed("timed out"),
            .insecureEndpoint(scheme: "http"),
        ]
        XCTAssertEqual(Set(all.map(\.description)).count, all.count)
        XCTAssertTrue(WebTransceiverTokenError.loginFailed.description.contains("password"))
    }

    // MARK: The seam

    /// What a caller substitutes for the URLSession implementation — the shape
    /// APP-12 will test its settings screen against.
    private struct StubSource: WebTransceiverTokenSource {
        let result: Result<WebTransceiverToken, WebTransceiverTokenError>
        func token(username: String, password: String) async throws -> WebTransceiverToken {
            try result.get()
        }
    }

    func testASubstitutedSourceSatisfiesTheSeam() async throws {
        let source: any WebTransceiverTokenSource =
            StubSource(result: .success(WebTransceiverToken("1b59df18107e")))
        let token = try await source.token(username: "VK1CPM", password: "hunter2")
        XCTAssertEqual(token.value, "1b59df18107e")

        let failing: any WebTransceiverTokenSource = StubSource(result: .failure(.loginFailed))
        do {
            _ = try await failing.token(username: "VK1CPM", password: "wrong")
            XCTFail("expected .loginFailed")
        } catch {
            XCTAssertEqual(error as? WebTransceiverTokenError, .loginFailed)
        }
    }

    // MARK: Where a password may be sent

    /// The endpoint is substitutable so a successor can be pointed at (OQ-10) —
    /// which is exactly how a portal password could end up on the wire in clear.
    /// HTTPS is the only scheme, with no opt-out.
    func testOnlyHTTPSEndpointsArePermitted() throws {
        XCTAssertTrue(
            Fetcher.isPermittedEndpoint(
                try XCTUnwrap(URL(string: "https://allstarlink.org/api/v3/auth-wt"))))
        XCTAssertTrue(
            Fetcher.isPermittedEndpoint(try XCTUnwrap(URL(string: "HTTPS://allstarlink.org/x"))),
            "URL does not normalise the scheme's case")

        for rejected in [
            "http://allstarlink.org/api/v2/auth-wt-legacy",
            "http://localhost:8080/auth",
            "ftp://allstarlink.org/auth",
            "file:///tmp/auth",
        ] {
            XCTAssertFalse(
                Fetcher.isPermittedEndpoint(try XCTUnwrap(URL(string: rejected))), rejected)
        }
    }

    /// And the fetcher refuses rather than trusting its caller to have checked.
    /// The assertion that matters is that this happens *before* any request: the
    /// error says nothing was sent, and it must be true.
    func testAnInsecureEndpointIsRefusedWithoutSendingAnything() async {
        // A session that fails the test if it is ever asked to do anything.
        final class ForbiddenProtocol: URLProtocol {
            nonisolated(unsafe) static var wasUsed = false
            override class func canInit(with request: URLRequest) -> Bool {
                wasUsed = true
                return false
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForbiddenProtocol.self]

        let fetcher = Fetcher(
            url: URL(string: "http://allstarlink.org/api/v2/auth-wt-legacy")!,
            session: URLSession(configuration: configuration))

        do {
            _ = try await fetcher.token(username: "VK1CPM", password: "hunter2")
            XCTFail("expected .insecureEndpoint")
        } catch {
            XCTAssertEqual(
                error as? WebTransceiverTokenError, .insecureEndpoint(scheme: "http"))
        }
        XCTAssertFalse(ForbiddenProtocol.wasUsed, "the password must not reach a URL loader")
        XCTAssertTrue(
            WebTransceiverTokenError.insecureEndpoint(scheme: "http").description
                .contains("nothing was sent"))
    }

    /// The endpoint's own name is part of the OQ-10 caveat, so it is pinned:
    /// a successor arrives as a second conformance, and this constant changing
    /// silently would mean it did not.
    func testEndpointIsTheObservedLegacyURL() {
        XCTAssertEqual(
            Fetcher.endpoint.absoluteString,
            "https://allstarlink.org/api/v2/auth-wt-legacy")
    }
}
