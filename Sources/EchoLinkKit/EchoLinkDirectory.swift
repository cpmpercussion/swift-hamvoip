// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Errors

/// Why a directory login failed.
///
/// ⚠️ No case here carries the account password, and none ever may. The
/// password is on the same line as the callsign in the request, so the
/// temptation to attach "the login line we sent" to an error is real and would
/// put a live credential into every log that catches one.
public enum EchoLinkDirectoryError: Error, Equatable, CustomStringConvertible {
    /// The server answered something other than `OK`.
    ///
    /// The payload is the server's reply, truncated and included because it is
    /// the only diagnostic there is. It is the *server's* half, so it contains
    /// nothing of ours.
    case loginRejected(reply: String)

    /// The stream closed before a reply arrived.
    case streamClosed

    /// No reply arrived before the deadline.
    case timedOut

    /// The reply was not valid ASCII.
    case malformedReply(byteCount: Int)

    public var description: String {
        switch self {
        case .loginRejected(let reply):
            return "directory server rejected the login: \(reply)"
        case .streamClosed:
            return "the directory stream closed before a reply"
        case .timedOut:
            return "directory login timed out"
        case .malformedReply(let count):
            return "directory reply was not ASCII (\(count) bytes)"
        }
    }
}

// MARK: - Login

/// The EchoLink directory server login (FR-3.1).
///
/// Two things about this that are easy to get wrong, both of them consequences
/// of the directory session being *tunnelled* when a proxy is in use:
///
/// - **It is a different secret from the proxy's.** This login carries the
///   operator's own account password (FR-3.4) in cleartext. The proxy login of
///   EL-5 never sees it, and this one never sees the proxy's. That is why
///   `EchoLinkAccountPassword` and `EchoLinkProxyPassword` are separate types.
/// - **The transport is the same TCP connection in proxied mode.** The login
///   line goes inside a `0x02` frame rather than to port 5200 directly, which
///   is why this type takes a `send` closure rather than a transport: the
///   caller decides whether to wrap it.
///
/// ## Provenance
///
/// Both halves are in the captures. The **reply** half is a fixture — the two
/// bytes `4f 4b`, "OK". The **request** half is deliberately not, because it is
/// exactly the credential EL-2 forbids checking in, so the request here is
/// hand-built from the shape the capture shows and tested against that shape
/// rather than against octets.
///
/// **Parsing the station list is not here — that is EL-11**, which is gated on
/// a capture that does not exist yet. Nothing on the path to a QSO needs the
/// list: an operator who knows the node they want can connect without it.
public enum EchoLinkDirectory {
    /// The directory server's TCP port in direct mode.
    public static let defaultPort: UInt16 = 5200

    /// What the server says when the login worked.
    public static let successReply = "OK"

    /// The bytes between the callsign and the password in the login line.
    ///
    /// Two separator bytes, from the capture. They are recorded as a named
    /// constant rather than inlined because "two separator bytes" is the sort
    /// of detail that gets silently changed to one, or to a colon, by someone
    /// reading the shape rather than the octets.
    static let separator: [UInt8] = [0x0A, 0x0A]

    /// The login line: `'l'` + callsign + two separator bytes + password + CR,
    /// all ASCII.
    ///
    /// ⚠️ The returned `Data` contains the account password in cleartext. Write
    /// it to the stream and let it go; never log it, never keep it, and never
    /// put it in an error.
    public static func loginLine(
        callsign: String,
        password: EchoLinkAccountPassword
    ) -> Data {
        var line = Data()
        line.append(0x6C)  // 'l'
        line.append(contentsOf: callsign.utf8)
        line.append(contentsOf: separator)
        line.append(contentsOf: password.value.utf8)
        line.append(0x0D)  // CR
        return line
    }

    /// Whether `reply` is the server's acceptance.
    ///
    /// Permissive about trailing whitespace, because a line-oriented server
    /// terminating its reply is entirely ordinary and nothing establishes which
    /// terminator this one uses — the capture's reply is the bare two bytes,
    /// which is evidence about one exchange.
    public static func isSuccess(_ reply: String) -> Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines) == successReply
    }
}

// MARK: - Session

/// Runs the directory login over whichever transport the caller provides.
///
/// An actor because it parks a continuation waiting for the reply, and the same
/// reentrancy rule applies as everywhere else: `login()` awaits a send and then
/// waits for an answer, so the answer can arrive before the continuation parks.
/// It uses the dedicated in-flight flag, exactly as `EchoLinkProxyClient` does.
///
/// The `send` closure is the seam that makes this work both proxied and direct:
///
/// - **Direct** (TCP 5200): the closure writes to a `StreamTransport`.
/// - **Proxied** (inside TCP 8100): the closure wraps the bytes in a `0x02`
///   frame and hands them to `EchoLinkProxyClient.send(_:)`.
///
/// Nothing here knows which, which is the point — the login is the same login.
public actor EchoLinkDirectorySession {
    /// How long to wait for the server's reply.
    public static let defaultReplyTimeout: Duration = .seconds(15)

    public typealias Send = @Sendable (Data) async throws -> Void

    private let callsign: String
    private let send: Send
    private let clock: any Clock<Duration>
    private let replyTimeout: Duration

    private var isLoggedIn = false
    private var isFinished = false
    private var buffer = Data()

    private var pendingLogin: CheckedContinuation<Void, Error>?
    private var pendingLoginResult: Result<Void, Error>?
    /// Independent of `isLoggedIn`, which the reply handler also writes — the
    /// same reason `EchoLinkProxyClient.openInFlight` exists.
    private var loginInFlight = false

    private var deadlineTask: Task<Void, Never>?
    private var deadlineGeneration: UInt64 = 0

    public init<C: Clock>(
        callsign: String,
        clock: C,
        replyTimeout: Duration = EchoLinkDirectorySession.defaultReplyTimeout,
        send: @escaping Send
    ) where C.Duration == Duration {
        self.callsign = callsign
        self.clock = clock
        self.replyTimeout = replyTimeout
        self.send = send
    }

    /// Whether the server has said `OK`.
    public var loggedIn: Bool { isLoggedIn }

    /// Send the login line and wait for the server's reply.
    ///
    /// - Parameter password: The operator's account password. Consumed here and
    ///   not retained: this type deliberately holds no reference to it after
    ///   the line is written.
    /// - Throws: `EchoLinkDirectoryError`.
    public func login(password: EchoLinkAccountPassword) async throws {
        guard !isFinished else { throw EchoLinkDirectoryError.streamClosed }
        guard !isLoggedIn, !loginInFlight else { return }

        pendingLoginResult = nil
        loginInFlight = true
        armDeadline()

        let line = EchoLinkDirectory.loginLine(callsign: callsign, password: password)
        do {
            try await send(line)
        } catch {
            loginInFlight = false
            pendingLoginResult = nil
            cancelDeadline()
            // Deliberately not `throw error`: whatever the transport threw could
            // in principle stringify something about the write, and the write
            // was the credential.
            throw EchoLinkDirectoryError.streamClosed
        }

        // Reentrancy window: the reply may already have been handled. See
        // `finishLogin`, which stashes rather than drops.
        do {
            try await awaitLoginOutcome()
        } catch {
            cancelDeadline()
            throw error
        }
        cancelDeadline()
    }

    /// Feed the server's bytes in. Chunking is irrelevant — as everywhere else
    /// on a stream, the boundaries mean nothing.
    public func received(_ bytes: Data) {
        guard !isFinished, loginInFlight else { return }
        buffer.append(bytes)

        guard let text = String(data: buffer, encoding: .ascii) else {
            // Not ASCII *yet* may just mean a split multi-byte sequence, but
            // this protocol's replies are ASCII, so anything else is wrong.
            finishLogin(.failure(EchoLinkDirectoryError.malformedReply(byteCount: buffer.count)))
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if EchoLinkDirectory.isSuccess(text) {
            isLoggedIn = true
            finishLogin(.success(()))
        } else if !trimmed.isEmpty, trimmed.count >= EchoLinkDirectory.successReply.count {
            // Long enough to have been "OK" and is not: a rejection. Waiting
            // for more bytes would just hang until the deadline.
            finishLogin(.failure(EchoLinkDirectoryError.loginRejected(reply: String(trimmed.prefix(64)))))
        }
        // Otherwise: a partial reply. Wait for more.
    }

    /// The stream is gone.
    public func streamClosed() {
        guard !isFinished else { return }
        isFinished = true
        cancelDeadline()
        finishLogin(.failure(EchoLinkDirectoryError.streamClosed))
    }

    // MARK: Deadline

    private func armDeadline() {
        deadlineTask?.cancel()
        deadlineGeneration &+= 1
        let generation = deadlineGeneration
        // Both hoisted out: referring to `replyTimeout` inside the closure
        // captures `self` strongly and quietly defeats the `[weak self]`.
        let clock = self.clock
        let timeout = self.replyTimeout

        deadlineTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.deadlineElapsed(generation: generation)
        }
    }

    private func cancelDeadline() {
        deadlineGeneration &+= 1
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func deadlineElapsed(generation: UInt64) {
        guard generation == deadlineGeneration, !isFinished else { return }
        finishLogin(.failure(EchoLinkDirectoryError.timedOut))
    }

    // MARK: Continuation

    private func finishLogin(_ result: Result<Void, Error>) {
        guard loginInFlight else { return }
        if let continuation = pendingLogin {
            pendingLogin = nil
            pendingLoginResult = nil
            loginInFlight = false
            continuation.resume(with: result)
        } else {
            pendingLoginResult = result
        }
    }

    private func awaitLoginOutcome() async throws {
        if let stored = pendingLoginResult {
            pendingLoginResult = nil
            loginInFlight = false
            return try stored.get()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingLogin = continuation
        }
    }
}
