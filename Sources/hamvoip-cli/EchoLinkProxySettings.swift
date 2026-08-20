// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import EchoLinkKit
import Foundation

/// The EchoLink proxy setting, resolved from the command line, the environment
/// and the config directory.
///
/// A private proxy is **one setting with three parts** — host, port, password —
/// and they resolve together rather than independently, for two reasons. A
/// password on its own is not a usable setting: the config directory grew an
/// `ECHOLINK_PROXY_PASSWORD` that nothing could act on, because no file beside
/// it said which proxy it was *for*. And a password paired with the wrong host
/// is worse than no password at all — see `passwordWithheld` below.
///
/// The same shape is what APP-13 gives the app: host and port in
/// `UserDefaults`, password in the Keychain, as one app-wide value. The CLI
/// mirrors it rather than inventing a second arrangement for the same setting.
///
/// File names match the environment variables, which is the whole convention
/// (`ConfigFile`). Precedence is the usual one: command line → environment →
/// config file → default.
enum EchoLinkProxySettings {
    /// The proxy's host name or address.
    static let hostName = "ECHOLINK_PROXY"
    /// The proxy's TCP port. Optional; `EchoLinkProxyClient.defaultPort` stands in.
    static let portName = "ECHOLINK_PROXY_PORT"
    /// The proxy password — the *proxy's*, not the EchoLink account's.
    static let passwordName = "ECHOLINK_PROXY_PASSWORD"

    /// What the three parts came out as, and where from.
    struct Resolved: Equatable {
        /// The proxy to dial, or `nil` when `--auto-proxy` will choose one.
        var host: String?
        var port: UInt16
        var password: String
        var passwordSource: SecretPrompt.Source
        /// A configured password was found and deliberately **not** used,
        /// because the proxy being dialled is not the one it belongs to.
        ///
        /// Reported rather than silent: a password that stops applying without
        /// saying so is how somebody ends up debugging a login failure against
        /// their own proxy for an hour.
        var passwordWithheld: Bool
    }

    /// Resolves the three parts together.
    ///
    /// - Throws: a `ValidationError` when a configured port is not a number in
    ///   range. A malformed port is worth failing on rather than quietly
    ///   falling back to 8100 — the fallback would connect to *something* and
    ///   the operator would never learn their file was wrong.
    static func resolve(
        commandLineHost: String?,
        commandLinePort: UInt16?,
        commandLinePassword: String?,
        autoProxy: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Resolved {
        let configuredHost = value(hostName, environment)?.value

        // With --auto-proxy the selector chooses, and an explicitly named host
        // has already been rejected as a conflict by the time we get here.
        let host = autoProxy ? nil : (commandLineHost ?? configuredHost)

        var port = EchoLinkProxyClient.defaultPort
        if let commandLinePort {
            port = commandLinePort
        } else if let configured = value(portName, environment) {
            guard let parsed = UInt16(configured.value), parsed > 0 else {
                throw ValidationError(
                    "\(configured.source) holds '\(configured.value)', which is not a TCP "
                        + "port. Expected a number from 1 to 65535.")
            }
            port = parsed
        }

        let configured = value(passwordName, environment)
        let (password, source, withheld) = resolvePassword(
            commandLineValue: commandLinePassword,
            configured: configured,
            host: host,
            configuredHost: configuredHost)

        return Resolved(
            host: host,
            port: port,
            password: password,
            passwordSource: source,
            passwordWithheld: withheld)
    }

    /// Which password applies, and whether a configured one was held back.
    ///
    /// **The rule that matters: a configured proxy password is used only for
    /// the proxy it was configured for.** `PUBLIC` is the public-proxy password
    /// by definition — a convention, not a secret — so it is the right default
    /// and the right thing to fall back to.
    ///
    /// Anything else is a real per-station credential, and sending it anywhere
    /// but its own proxy is a genuine hazard rather than a tidiness point: the
    /// proxy login hashes the password into a digest, so a stranger's proxy
    /// that receives one gets something to attack offline, and gains us
    /// nothing — a public proxy would have accepted `PUBLIC` regardless. So the
    /// configured password applies only when the host being dialled *is* the
    /// configured host, and never under `--auto-proxy`, where the host is by
    /// definition somebody else's.
    ///
    /// An explicit `--proxy-password` always wins: the operator naming a
    /// password for a host they also named is not a mistake to second-guess.
    private static func resolvePassword(
        commandLineValue: String?,
        configured: (value: String, source: SecretPrompt.Source)?,
        host: String?,
        configuredHost: String?
    ) -> (password: String, source: SecretPrompt.Source, withheld: Bool) {
        let publicProxy = EchoLinkProxyPassword.publicProxy.value

        if let commandLineValue {
            return (commandLineValue, .commandLine(flag: "--proxy-password"), false)
        }
        guard let configured else { return (publicProxy, .none, false) }

        // Host names are case-insensitive; a config file written with different
        // capitalisation is the same proxy and should not silently lose its
        // password.
        let isOwnProxy =
            host != nil && configuredHost != nil
            && host!.caseInsensitiveCompare(configuredHost!) == .orderedSame

        guard isOwnProxy else { return (publicProxy, .none, true) }
        return (configured.value, configured.source, false)
    }

    /// A setting from the environment, then the config file — no prompt.
    ///
    /// Unlike an account password there is always a sane default here
    /// (`PUBLIC`, or no proxy at all and a clear error), so stopping to ask a
    /// human would be an interruption rather than a rescue.
    private static func value(
        _ name: String,
        _ environment: [String: String]
    ) -> (value: String, source: SecretPrompt.Source)? {
        if let fromEnvironment = environment[name], !fromEnvironment.isEmpty {
            return (fromEnvironment, .environment(name))
        }
        if let fromFile = ConfigFile.read(name, environment: environment) {
            let path = ConfigFile.url(for: name, environment: environment)?.path ?? name
            return (fromFile, .configFile(path))
        }
        return nil
    }
}
