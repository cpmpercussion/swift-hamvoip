// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IAX2Kit

/// `hamvoip-cli wt-token` — exchange an allstarlink.org portal login for a Web
/// Transceiver token.
///
/// This exists so `docs/CLI.md` §11.1 is a command rather than a `curl` with a
/// hand-built JSON body: the token is the identity proof for a WT call, and
/// composing one by hand is where a stray shell quote turns into an
/// unexplained `Invalid JSON payload`.
///
/// On success **only the token goes to stdout**, so it substitutes directly:
///
/// ```sh
/// TOKEN="$(hamvoip-cli wt-token --callsign VK1CPM)"
/// ```
///
/// Everything else — the prompt, the source of the password, any complaint —
/// goes to stderr, for the same reason.
struct WebTransceiverTokenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wt-token",
        abstract: "Fetch a Web Transceiver token from your allstarlink.org portal account.",
        discussion: """
            Web Transceiver reaches a node you have no credentials for, using your \
            allstarlink.org portal account. This command does the first of its two \
            steps; `hamvoip-cli iax2` does the second. docs/CLI.md section 11 is the \
            full walkthrough.

            THE PASSWORD
              This is your allstarlink.org portal password — not a node secret, and
              not the static `allstar` secret the WT call itself presents. As with
              --secret, do not pass it in argv: set ALLSTARLINK_PORTAL_PASSWORD, or
              supply nothing and type it at the prompt, where echo is disabled.

            THE TOKEN
              12 lowercase hex characters, and stable across calls — a credential
              with a lifetime rather than a nonce. Treat it as one: it resolves to
              your callsign on any WT-enabled node. Only the token is printed, so
              TOKEN="$(hamvoip-cli wt-token --callsign VK1CPM)" works.

              Pass it to `iax2` as --calling-name, never as --callsign: --callsign
              is upper-cased, which would corrupt it.
            """)

    /// The environment variable checked before prompting. Deliberately not
    /// `HAMVOIP_SECRET`: that holds a node secret, and the two are different
    /// credentials that a shared name would invite mixing up.
    static let passwordEnvironmentVariable = "ALLSTARLINK_PORTAL_PASSWORD"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Your callsign — allstarlink.org portal logins are callsign/password. Falls "
                + "back to the config file, as every other command's does.",
            valueName: "callsign"))
    var callsign: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Portal password. Prefer $\(WebTransceiverTokenCommand.passwordEnvironmentVariable) "
                + "or the prompt: a password in argv is visible in `ps` and lands in your "
                + "shell history.",
            valueName: "password"))
    var password: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Login endpoint. Only for pointing at the replacement when there is one "
                + "(OQ-10); the default is the observed `auth-wt-legacy` URL. Must be https:// — "
                + "this request carries your portal password.",
            valueName: "url"))
    var endpoint: String?

    func run() async throws {
        let callsign: String
        do {
            callsign = try ArgumentValidation.requireCallsign(
                try ConfigFile.requireCallsign(commandLineValue: self.callsign))
        } catch let error as CLIValidationError {
            throw ValidationError(error.description)
        }

        let url: URL
        if let endpoint {
            guard let parsed = URL(string: endpoint), parsed.scheme != nil else {
                throw ValidationError("--endpoint is not a URL: \(endpoint)")
            }
            // Checked here as well as in the library, which refuses the request
            // outright: this is a password going to a public web service, and
            // being told before the prompt beats being told after typing it.
            guard AllStarLinkPortalTokenFetcher.isPermittedEndpoint(parsed) else {
                throw ValidationError(
                    "--endpoint must be https:// — this request carries your portal password, "
                    + "and \(parsed.scheme ?? "that scheme") would send it in clear")
            }
            url = parsed
        } else {
            url = AllStarLinkPortalTokenFetcher.endpoint
        }

        let resolved = try SecretPrompt.resolve(
            commandLineValue: password,
            commandLineFlag: "--password",
            name: Self.passwordEnvironmentVariable,
            promptText: "allstarlink.org portal password for \(callsign): ")
        guard !resolved.secret.isEmpty else {
            throw ValidationError(
                "no portal password supplied — set $\(Self.passwordEnvironmentVariable), "
                    + "or run this from a terminal and type it at the prompt")
        }
        FileHandle.standardError.write(
            Data("Portal password from \(resolved.source).\n".utf8))

        let token: WebTransceiverToken
        do {
            token = try await AllStarLinkPortalTokenFetcher(url: url)
                .token(username: callsign, password: resolved.secret)
        } catch let error as WebTransceiverTokenError {
            FileHandle.standardError.write(Data("FAILED: \(error)\n\(hint(for: error))\n".utf8))
            throw ExitCode.failure
        }

        if !token.isWellFormed {
            // Not refused — only the node decides whether a token works — but
            // said out loud, because the shape has been the same on every
            // observation and a change in it is the first sign of the
            // replacement endpoint arriving.
            let note =
                "NOTE: the token is not the usual 12 lowercase hex characters. Passing "
                + "it on anyway; if the call is rejected, this is why.\n"
            FileHandle.standardError.write(Data(note.utf8))
        }
        print(token.value)
    }

    /// What to do about each failure. The typed errors exist so these three can
    /// be different sentences.
    private func hint(for error: WebTransceiverTokenError) -> String {
        switch error {
        case .loginFailed:
            return
                "Check the callsign and password at allstarlink.org itself. This is the "
                + "portal login, not a node secret."
        case .invalidJSONPayload, .invalidJSONFields:
            return
                "The endpoint did not recognise a request that has not changed, so the "
                + "endpoint has. See OQ-10 in docs/DEVELOPMENT-PLAN.md; --endpoint points "
                + "this at a successor."
        case .rejected(let message):
            return "The portal said: \(message). Nothing here can act on that."
        case .malformedResponse:
            return
                "The answer was not the documented JSON — a captive portal or a proxy in "
                + "the way would look like this."
        case .requestFailed:
            return "Check the network, then that allstarlink.org is up."
        case .insecureEndpoint:
            return "Give --endpoint an https:// URL. Nothing was sent."
        }
    }
}
