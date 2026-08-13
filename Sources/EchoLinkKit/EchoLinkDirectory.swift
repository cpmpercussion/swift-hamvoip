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

    /// The two bytes between the callsign and the password.
    ///
    /// **`0xAC 0xAC`**, measured off the wire — not `0x0A 0x0A`. An earlier
    /// version assumed LF LF, because the OQ-9 write-up said "two separator
    /// bytes" without saying which, and LF is what "separator" suggests to
    /// someone reading prose rather than octets. The directory server answers
    /// `OK` either way, so the mistake survived until a live comparison against
    /// a working client found it. Recorded as a named constant precisely
    /// because it is the kind of detail that gets "tidied" back to a newline.
    static let separator: [UInt8] = [0xAC, 0xAC]

    /// The status keyword that declares a station available.
    static let onlineKeyword = "ONLINE"

    /// The login **message**: three CR-terminated lines.
    ///
    ///     l<callsign><AC AC><password>CR
    ///     ONLINE<version>Y(<HH:MM>)CR
    ///     <location>CR
    ///
    /// ⚠️ **All three lines are required**, and the second is the one that
    /// matters most. An earlier version sent only the first. The server still
    /// answered `OK` — it had authenticated us — but without the `ONLINE` line
    /// the station is never listed as available, so no node will accept a
    /// connection from it. That is why a live `*ECHOTEST*` session went
    /// unanswered while every step reported success: authentication is not
    /// registration.
    ///
    /// The `Y` after the version is observed and its meaning is unknown; it is
    /// emitted verbatim rather than guessed at.
    ///
    /// ⚠️ The returned `Data` contains the account password in cleartext. Write
    /// it to the stream and let it go; never log it, never keep it, and never
    /// put it in an error.
    ///
    /// - Parameters:
    ///   - version: this client's version, as it should appear in the
    ///     directory listing.
    ///   - localTime: `HH:MM`, passed in rather than read from a clock so this
    ///     stays a pure function.
    ///   - location: the short location string shown beside the callsign.
    public static func loginMessage(
        callsign: String,
        password: EchoLinkAccountPassword,
        version: String,
        localTime: String,
        location: String
    ) -> Data {
        var message = Data()

        message.append(0x6C)  // 'l'
        message.append(contentsOf: callsign.utf8)
        message.append(contentsOf: separator)
        message.append(contentsOf: password.value.utf8)
        message.append(0x0D)  // CR

        message.append(contentsOf: "\(onlineKeyword)\(version)Y(\(localTime))".utf8)
        message.append(0x0D)

        message.append(contentsOf: location.utf8)
        message.append(0x0D)

        return message
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
    private let version: String
    private let location: String
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
        version: String = "0.1",
        location: String = "",
        clock: C,
        replyTimeout: Duration = EchoLinkDirectorySession.defaultReplyTimeout,
        send: @escaping Send
    ) where C.Duration == Duration {
        self.callsign = callsign
        self.version = version
        self.location = location
        self.clock = clock
        self.replyTimeout = replyTimeout
        self.send = send
    }

    /// Whether the server has said `OK`.
    public var loggedIn: Bool { isLoggedIn }

    /// `HH:MM` local time, which is what the observed client puts in the
    /// `ONLINE` line.
    static func localTimeHHMM() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

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

        let line = EchoLinkDirectory.loginMessage(
            callsign: callsign,
            password: password,
            version: version,
            localTime: Self.localTimeHHMM(),
            location: location)
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
