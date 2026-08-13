// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import RadioCore
import TestSupport

/// EL-6 — the directory login, proxied and direct.
///
/// The server's half comes from the capture (`live-proxy-login-in.hex`, the two
/// bytes `4f 4b`). The request half is hand-built from the shape, because the
/// captured request is the operator's account password in cleartext and EL-2
/// forbids checking it in — so the request tests assert the *shape* the fixture
/// header records, not octets.
final class EchoLinkDirectoryTests: XCTestCase {
    private static let callsign = "N0CALL"
    private static let password = EchoLinkAccountPassword("hunter2-not-real")

    /// Collects what the session wrote, so tests can assert on the line.
    private actor Writes {
        private(set) var data = Data()
        private(set) var shouldThrow = false

        func record(_ bytes: Data) throws {
            if shouldThrow { throw StreamTransportError.closed }
            data.append(bytes)
        }

        func failNextSend() { shouldThrow = true }
    }

    private func makeSession(
        writes: Writes,
        replyTimeout: Duration = .seconds(5)
    ) -> EchoLinkDirectorySession {
        EchoLinkDirectorySession(
            callsign: Self.callsign,
            clock: ManualTestClock(),
            replyTimeout: replyTimeout
        ) { bytes in
            try await writes.record(bytes)
        }
    }

    /// The captured `"OK"` payload, out of the `0x02` frame in the fixture.
    private func capturedOKPayload() throws -> Data {
        let frames = try FixtureLoader.datagrams("live-proxy-login-in.hex", in: Bundle.module)
        let data = try frames
            .dropFirst()
            .map { try EchoLinkProxyFrame.parse($0).frame }
            .first { $0.type == .data }
        return try XCTUnwrap(data).payload
    }

    /// Starts `login` and returns once the line has actually been written.
    private func startLogin(
        _ session: EchoLinkDirectorySession,
        writes: Writes
    ) async -> Task<Void, Error> {
        let task = Task { try await session.login(password: Self.password) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await writes.data.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return task
    }

    // MARK: - The captured reply

    func testCapturedReplyIsExactlyOK() throws {
        let payload = try capturedOKPayload()
        XCTAssertEqual(Array(payload), [0x4F, 0x4B])
        XCTAssertEqual(String(data: payload, encoding: .ascii), "OK")
    }

    func testLoginSucceedsOnTheCapturedReply() async throws {
        let writes = Writes()
        let session = makeSession(writes: writes)

        let task = await startLogin(session, writes: writes)
        await session.received(try capturedOKPayload())
        try await task.value

        let loggedIn = await session.loggedIn
        XCTAssertTrue(loggedIn)
    }

    func testLoginSucceedsWhenTheReplyIsLineTerminated() async throws {
        // Nothing establishes which terminator the server uses — the capture's
        // reply is the bare two bytes, which is evidence about one exchange.
        for terminator in ["", "\r\n", "\n", "\r"] {
            let writes = Writes()
            let session = makeSession(writes: writes)
            let task = await startLogin(session, writes: writes)
            await session.received(Data("OK\(terminator)".utf8))
            try await task.value

            let loggedIn = await session.loggedIn
            XCTAssertTrue(loggedIn, "reply 'OK\(terminator.debugDescription)' must be accepted")
        }
    }

    func testReplySplitAcrossChunksStillSucceeds() async throws {
        let writes = Writes()
        let session = makeSession(writes: writes)
        let task = await startLogin(session, writes: writes)

        await session.received(Data("O".utf8))
        await session.received(Data("K".utf8))
        try await task.value

        let loggedIn = await session.loggedIn
        XCTAssertTrue(loggedIn)
    }

    // MARK: - The request line

    func testLoginLineMatchesTheCapturedShape() {
        // From the capture: 'l' + callsign + two separator bytes + password
        // + CR, all ASCII. 46 bytes for the recorded exchange.
        let line = EchoLinkDirectory.loginLine(
            callsign: Self.callsign,
            password: Self.password
        )
        let bytes = Array(line)

        XCTAssertEqual(bytes.first, 0x6C, "the line begins with 'l'")
        XCTAssertEqual(bytes.last, 0x0D, "and ends with CR, not LF")
        XCTAssertEqual(
            line.count,
            1 + Self.callsign.count + 2 + Self.password.value.count + 1,
            "'l' + callsign + 2 separators + password + CR"
        )

        let callsignRange = 1 ..< (1 + Self.callsign.count)
        XCTAssertEqual(
            String(decoding: bytes[callsignRange], as: UTF8.self), Self.callsign
        )
        XCTAssertTrue(bytes.allSatisfy { $0 < 0x80 }, "all ASCII")
    }

    func testLoginWritesExactlyOneLine() async throws {
        let writes = Writes()
        let session = makeSession(writes: writes)
        let task = await startLogin(session, writes: writes)
        await session.received(Data("OK".utf8))
        try await task.value

        let written = await writes.data
        XCTAssertEqual(
            written,
            EchoLinkDirectory.loginLine(callsign: Self.callsign, password: Self.password)
        )
    }

    // MARK: - Proxied and direct are the same login

    func testTheSameLoginRunsThroughAProxyFrame() async throws {
        // Proxied mode: the login line goes inside a 0x02 frame on the proxy's
        // TCP connection rather than to port 5200 directly. The login is the
        // same login — this test is the claim that the seam actually holds.
        let transport = MockStreamTransport()
        let session = EchoLinkDirectorySession(
            callsign: Self.callsign,
            clock: ManualTestClock()
        ) { bytes in
            try await transport.send(
                EchoLinkProxyFrame(type: .data, payload: bytes).encoded
            )
        }

        let task = Task { try await session.login(password: Self.password) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while transport.sentCount == 0, ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        await session.received(try capturedOKPayload())
        try await task.value

        let frame = try EchoLinkProxyFrame.parse(transport.sentBytes).frame
        XCTAssertEqual(frame.type, .data)
        XCTAssertEqual(
            frame.payload,
            EchoLinkDirectory.loginLine(callsign: Self.callsign, password: Self.password)
        )

        let loggedIn = await session.loggedIn
        XCTAssertTrue(loggedIn)
    }

    // MARK: - Rejection

    func testRejectedLoginIsATypedError() async throws {
        let writes = Writes()
        let session = makeSession(writes: writes)
        let task = await startLogin(session, writes: writes)
        await session.received(Data("NO".utf8))

        do {
            try await task.value
            XCTFail("a rejection must not read as success")
        } catch let error as EchoLinkDirectoryError {
            guard case .loginRejected(let reply) = error else {
                return XCTFail("expected .loginRejected, got \(error)")
            }
            XCTAssertEqual(reply, "NO")
        }

        let loggedIn = await session.loggedIn
        XCTAssertFalse(loggedIn)
    }

    func testStreamClosingBeforeAReplyIsATypedError() async throws {
        let writes = Writes()
        let session = makeSession(writes: writes)
        let task = await startLogin(session, writes: writes)
        await session.streamClosed()

        do {
            try await task.value
            XCTFail("login must not succeed on a closed stream")
        } catch let error as EchoLinkDirectoryError {
            XCTAssertEqual(error, .streamClosed)
        }
    }

    func testFailedSendIsReportedWithoutTheCredential() async throws {
        let writes = Writes()
        await writes.failNextSend()
        let session = makeSession(writes: writes)

        do {
            try await session.login(password: Self.password)
            XCTFail("a failed write must not read as success")
        } catch let error as EchoLinkDirectoryError {
            // Deliberately .streamClosed rather than the transport's own error:
            // the write that failed *was* the credential, and the underlying
            // error is not guaranteed to keep quiet about what it was asked to
            // write.
            XCTAssertEqual(error, .streamClosed)
        }
    }

    // MARK: - The password never escapes

    func testNoErrorDescriptionContainsThePassword() {
        let secret = Self.password.value
        let errors: [EchoLinkDirectoryError] = [
            .loginRejected(reply: "NO"),
            .streamClosed,
            .timedOut,
            .malformedReply(byteCount: 12),
        ]
        for error in errors {
            XCTAssertFalse(error.description.contains(secret),
                           "\(error) leaked the account password")
        }
    }

    func testRejectionReplyIsTheServersHalfOnly() async throws {
        // The reply carried in .loginRejected comes from the server, so it can
        // never contain anything of ours — but assert it, because the obvious
        // "helpful" change is to attach the line we sent.
        let writes = Writes()
        let session = makeSession(writes: writes)
        let task = await startLogin(session, writes: writes)
        await session.received(Data("BAD PASSWORD".utf8))

        do {
            try await task.value
            XCTFail("expected a rejection")
        } catch let error as EchoLinkDirectoryError {
            XCTAssertFalse(error.description.contains(Self.password.value))
            XCTAssertFalse(error.description.contains(Self.callsign))
        }
    }

    // MARK: - Actor reentrancy (plan rule 10)

    func testLoginReturnsWhenReplyIsProcessedDuringSend() async throws {
        // The reply delivered from *inside* the awaited send, so it is handled
        // before login() has parked its continuation. A version that inferred
        // "is a login in flight?" from `isLoggedIn` — which the reply handler
        // writes first — drops the outcome here and hangs.
        let box = ReplyDuringSendBox()
        let session = EchoLinkDirectorySession(
            callsign: Self.callsign,
            clock: ManualTestClock()
        ) { _ in
            await box.deliver()
            for _ in 0 ..< 100 { await Task.yield() }
        }
        await box.attach(session)

        let completed = Completion()
        let task = Task {
            try await session.login(password: Self.password)
            await completed.signal()
        }

        await waitWhile { await !completed.isSignalled }

        let returned = await completed.isSignalled
        task.cancel()
        XCTAssertTrue(returned, "login() never returned: the reply was dropped")

        let loggedIn = await session.loggedIn
        XCTAssertTrue(loggedIn)
    }
}

// MARK: - Reentrancy test doubles

private actor Completion {
    private(set) var isSignalled = false
    func signal() { isSignalled = true }
}

/// Feeds the session its reply from inside the send closure.
private actor ReplyDuringSendBox {
    private var session: EchoLinkDirectorySession?

    func attach(_ session: EchoLinkDirectorySession) {
        self.session = session
    }

    func deliver() async {
        await session?.received(Data("OK".utf8))
    }
}
