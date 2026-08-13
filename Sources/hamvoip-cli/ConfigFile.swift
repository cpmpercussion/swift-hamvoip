// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Per-operator defaults kept in a config directory, so the values that never
/// change between runs — a callsign, an account password — do not have to be
/// typed or exported every time.
///
/// The layout is deliberately dull: **one file per value, named for the
/// setting, containing nothing but the value.** No format, no parser, no
/// escaping rules, nothing to get wrong. `cat` shows you what a setting is and
/// `echo >` sets it, which also means a wrong value fails obviously rather than
/// being silently mis-parsed.
///
///     ~/.config/swift-hamvoip/CALLSIGN
///     ~/.config/swift-hamvoip/ECHOLINK_PASSWORD
///     ~/.config/swift-hamvoip/HAMVOIP_SECRET
///
/// The file names match the environment variables they stand in for, which is
/// the whole convention: if you know the variable, you know the file.
///
/// ## Precedence, and why the file is third
///
/// Command line → environment → config file → interactive prompt.
///
/// The file sits *below* the environment so a one-off override is always
/// possible without editing anything, and *above* the prompt so the common case
/// is silent. It is the least surprising order, and it is the same one `git`
/// and `ssh` use for their own per-user configuration.
enum ConfigFile {
    /// The directory, honouring `XDG_CONFIG_HOME` where it is set.
    static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("swift-hamvoip", isDirectory: true)
        }
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config/swift-hamvoip", isDirectory: true)
    }

    /// The path a named setting would live at, whether or not it exists.
    static func url(
        for name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        directory(environment: environment)?.appendingPathComponent(name)
    }

    /// The value of a named setting, or `nil` if the file is absent, empty or
    /// unreadable.
    ///
    /// Whitespace is trimmed, which matters more than it sounds: a file written
    /// with `echo` ends in a newline, and a callsign with a trailing `\n` would
    /// go out on the wire and be rejected by something far away, for a reason
    /// nobody would guess from the error.
    ///
    /// Only the first line is taken, so a file that has acquired a comment or a
    /// second value still yields something sane rather than a credential with a
    /// paragraph attached.
    ///
    /// Unreadable is deliberately `nil` rather than an error: a config file is
    /// a convenience, and the layers below it — the prompt, or a clear "this is
    /// required" message — are better failure modes than a stack trace about
    /// file permissions.
    static func read(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let url = url(for: name, environment: environment),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }

        let value = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Whether a settings file is readable by anyone but its owner.
    ///
    /// Checked for files holding credentials, and reported rather than
    /// enforced: refusing to run because of a permission bit would be a worse
    /// failure than the risk it prevents, and the operator is the one who gets
    /// to decide how their own machine is set up. Saying so once is the useful
    /// middle.
    static func isReadableByOthers(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let url = url(for: name, environment: environment),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        // Group or other, read or write.
        return permissions.intValue & 0o077 != 0
    }

    /// The file name holding the operator's callsign.
    static let callsignName = "CALLSIGN"

    /// The callsign from the config file, if it is there.
    ///
    /// Separate from `read` only so the one file name every command wants is
    /// written down once.
    static func callsign(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        read(callsignName, environment: environment)
    }

    /// Resolves a callsign from the command line, then the config file.
    ///
    /// - Throws: a `ValidationError` naming both places when neither has one,
    ///   because "callsign is required" is not much help to somebody who
    ///   thought they had set it.
    static func requireCallsign(
        commandLineValue: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if let commandLineValue, !commandLineValue.isEmpty {
            return commandLineValue
        }
        if let fromFile = callsign(environment: environment) {
            return fromFile
        }
        let path = url(for: callsignName, environment: environment)?.path
            ?? "~/.config/swift-hamvoip/\(callsignName)"
        throw CLIValidationError.callsignMissing(configPath: path)
    }

    /// A one-line warning for a credential file others can read, or `nil` if
    /// there is nothing to say.
    static func permissionWarning(
        for name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard isReadableByOthers(name, environment: environment),
              let url = url(for: name, environment: environment)
        else { return nil }
        return "WARNING: \(url.path) is readable by other users on this machine. "
            + "It holds a live credential. Consider: chmod 600 '\(url.path)'"
    }
}
