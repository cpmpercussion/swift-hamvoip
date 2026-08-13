// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IAX2Kit

/// Everything wrong a user can get on the command line, named.
///
/// A local error type rather than ArgumentParser's `ValidationError` so the
/// rules below are plain functions over plain strings, testable without
/// building a command. The commands translate at the boundary.
enum CLIValidationError: Error, Equatable, CustomStringConvertible {
    case emptyValue(option: String)
    case whitespaceInValue(option: String)
    case portOutOfRange(Int)
    case callsignTooShort(String)
    case callsignHasInvalidCharacters(String)
    case timeoutOutOfRange(seconds: Int)
    case notADTMFDigit(Character)
    /// No callsign on the command line and none in the config file.
    case callsignMissing(configPath: String)

    var description: String {
        switch self {
        case .emptyValue(let option):
            return "\(option) must not be empty"
        case .whitespaceInValue(let option):
            return "\(option) must not contain whitespace"
        case .portOutOfRange(let port):
            return "port \(port) is outside the valid range 1–65535"
        case .callsignTooShort(let callsign):
            return "'\(callsign)' is too short to be a callsign (3 characters minimum)"
        case .callsignHasInvalidCharacters(let callsign):
            return "'\(callsign)' contains characters no callsign has; expected letters, "
                + "digits, '/' or '-'"
        case .timeoutOutOfRange(let seconds):
            return "the transmit timeout must be between 5 and 3600 seconds, not \(seconds)"
        case .notADTMFDigit(let character):
            return "'\(character)' is not a DTMF digit; valid digits are 0-9, *, #, A-D"
        case .callsignMissing(let configPath):
            return "no callsign: pass --callsign, or put one in \(configPath)"
        }
    }
}

/// Pure argument checking.
///
/// Every rule here is a decision about what a user is allowed to type, which
/// makes it exactly the kind of logic that should not be discovered to be
/// wrong in front of a radio. None of it touches the network, the terminal or
/// an audio device, so all of it is unit-tested.
enum ArgumentValidation {
    /// Rejects empty and whitespace-bearing values. Whitespace matters more
    /// than it looks: `--node "55553 "` reaches the node as a CALLED NUMBER
    /// with a trailing space and is rejected with a cause string that does not
    /// mention spaces, which is a miserable thing to debug over the air.
    static func requireSimpleString(_ value: String, option: String) throws -> String {
        guard !value.isEmpty else { throw CLIValidationError.emptyValue(option: option) }
        guard !value.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw CLIValidationError.whitespaceInValue(option: option)
        }
        return value
    }

    static func requirePort(_ port: Int) throws -> UInt16 {
        guard (1...65535).contains(port) else { throw CLIValidationError.portOutOfRange(port) }
        return UInt16(port)
    }

    /// Checks a callsign is plausible and upper-cases it.
    ///
    /// Deliberately loose: callsign formats vary by country and by suffix
    /// (`VK1XYZ/P`, `M0ABC/M`, `2E0ABC`), and a client that refuses a valid
    /// callsign because its author only knew one country's format is worse
    /// than one that accepts a typo. The value goes out as CALLING NAME
    /// (§8.6.4), which is a free-text IE — the point of the check is to catch
    /// an argument in the wrong position, not to police licensing.
    static func requireCallsign(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { throw CLIValidationError.callsignTooShort(value) }
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-"))
        guard trimmed.unicodeScalars.allSatisfy({ permitted.contains($0) }) else {
            throw CLIValidationError.callsignHasInvalidCharacters(value)
        }
        return trimmed.uppercased()
    }

    /// SF-1's timeout. The lower bound stops a user disabling the watchdog by
    /// accident with `--transmit-timeout 0`; the upper bound stops an hour-long
    /// stuck transmission being configured as if it were normal.
    static func requireTransmitTimeout(seconds: Int) throws -> Duration {
        guard (5...3600).contains(seconds) else {
            throw CLIValidationError.timeoutOutOfRange(seconds: seconds)
        }
        return .seconds(seconds)
    }

    /// Validates a typed DTMF string against RFC 5456 §8.2.1's digit set,
    /// returning the digits in order. Whitespace is ignored so `*3 55553` can
    /// be typed the way it reads.
    static func requireDTMFSequence(_ value: String) throws -> [Character] {
        var digits: [Character] = []
        for character in value where !character.isWhitespace {
            let normalised = Character(character.uppercased())
            guard (try? IAX2DTMFDigit(normalised)) != nil else {
                throw CLIValidationError.notADTMFDigit(character)
            }
            digits.append(normalised)
        }
        return digits
    }

    /// Builds the destination, validating every field. The one place a
    /// destination is constructed, so there is no path to a half-checked one.
    static func makeDestination(
        host: String,
        port: Int,
        node: String,
        username: String,
        callsign: String,
        secret: String
    ) throws -> IAX2Destination {
        IAX2Destination(
            host: try requireSimpleString(host, option: "--host"),
            port: try requirePort(port),
            callsign: try requireCallsign(callsign),
            username: try requireSimpleString(username, option: "--username"),
            secret: secret,
            node: try requireSimpleString(node, option: "--node"))
    }
}

// MARK: - Shared options

/// The node-address and identity options `connect` and `oq5` share.
struct NodeOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp(
        "Hostname or IP address of the AllStar node.",
        valueName: "host"))
    var host: String

    @Option(name: .long, help: ArgumentHelp(
        "UDP port the node listens on (RFC 5456 §4).",
        valueName: "port"))
    var port: Int = Int(IAX2Kit.defaultPort)

    @Option(name: .long, help: ArgumentHelp(
        "Node or extension to call, e.g. 55553 — the CALLED NUMBER IE.",
        valueName: "node"))
    var node: String

    @Option(name: .long, help: ArgumentHelp(
        "Account the node authenticates you as — the USERNAME IE.",
        valueName: "user"))
    var username: String

    @Option(name: .long, help: ArgumentHelp(
        """
        Your callsign, sent as the CALLING NAME IE. Defaults to the CALLSIGN         file in ~/.config/swift-hamvoip/.
        """,
        valueName: "call"))
    var callsign: String?

    @Option(name: .long, help: ArgumentHelp(
        """
        Shared secret. HAZARD: a secret passed this way is visible in `ps` to \
        every process on the machine and is written to your shell history. \
        Prefer the HAMVOIP_SECRET environment variable, or omit this flag \
        entirely and type the secret at the prompt (echo is disabled). This \
        flag exists only for scripting.
        """,
        valueName: "secret"))
    var secret: String?

    /// Resolves the secret and builds a validated destination.
    func resolvedDestination() throws -> (destination: IAX2Destination, secretSource: SecretPrompt.Source) {
        let resolved = try SecretPrompt.resolve(commandLineValue: secret)
        let destination = try ArgumentValidation.makeDestination(
            host: host,
            port: port,
            node: node,
            username: username,
            callsign: try ConfigFile.requireCallsign(commandLineValue: callsign),
            secret: resolved.secret)
        return (destination, resolved.source)
    }
}
