// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IAX2Kit
import RadioCore

// MARK: - Command

/// `hamvoip-cli oq5` — settle OQ-5 against a live node, in one session,
/// without recompiling anything.
struct OQ5Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oq5",
        abstract: "Find out how a real node wants the MD5 RESULT information element encoded.",
        discussion: """
            RFC 5456 §8.6.15 says the MD5 RESULT IE "carries the UTF-8-encoded challenge \
            result" and never says what that text looks like — hexadecimal or not, upper \
            or lower case, padded or not. The clean-room policy forbids reading another \
            implementation to find out, so it has to be asked of a node. This subcommand \
            asks, once per candidate encoding, and prints which one the node accepted.

            METHODS
              --method register  (default) REGREQ → REGAUTH → REGREQ+MD5 →
                                 REGACK/REGREJ. A registration exchange, not a call:
                                 nothing rings, no repeater is keyed, no audio is
                                 exchanged. Use this unless the node will not let
                                 this account register.
              --method call      NEW → AUTHREQ → AUTHREP → ACCEPT/REJECT, hanging up
                                 the instant an ACCEPT arrives. This does briefly
                                 place a real call, which on a linked node can key a
                                 transmitter. Only against your own node, and only
                                 if you are licensed to.

            READING THE RESULT
              One encoding accepted   that is the answer to OQ-5.
              All four rejected       the credentials are wrong, or the answer is
                                      something none of these four candidates
                                      covers. Check the secret first.
              Accepted, no challenge  the node does not authenticate this account,
                                      so it cannot answer the question. Configure a
                                      secret on the node and try again.

            The full procedure, and what to do with the answer, is in docs/CLI.md.
            """)

    /// Which exchange to use. `register` is the default because it settles the
    /// same question without placing a call.
    enum Method: String, CaseIterable, ExpressibleByArgument {
        case register
        case call

        static let allValueStrings: [String] = allCases.map(\.rawValue)
    }

    @OptionGroup var node: NodeOptions

    @Option(
        name: .long,
        help: ArgumentHelp(
            "How to provoke a challenge: 'register' (no call placed) or 'call' "
                + "(places a real call and hangs up immediately).",
            valueName: "method"))
    var method: Method = .register

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Candidate encoding to test. Repeat the flag to test several; omit it to test "
                + "all of them in order.",
            valueName: "name"))
    var encoding: [MD5ResultEncoding] = []

    @Option(
        name: .long,
        help: ArgumentHelp("Seconds to wait for the node to answer each probe.", valueName: "seconds"))
    var timeout: Int = 8

    @Flag(name: .long, help: "Keep testing every candidate even after one is accepted.")
    var exhaustive: Bool = false

    func run() async throws {
        let destination: IAX2Destination
        do {
            (destination, _) = try node.resolvedDestination()
        } catch let error as CLIValidationError {
            throw ValidationError(error.description)
        }
        guard !destination.secret.isEmpty else {
            throw ValidationError(
                "OQ-5 is a question about authentication, so this needs a secret. Set "
                    + "$\(SecretPrompt.environmentVariable) or run it on a terminal and type one.")
        }
        guard (1...120).contains(timeout) else {
            throw ValidationError("--timeout must be between 1 and 120 seconds")
        }

        let candidates = encoding.isEmpty ? MD5ResultEncoding.allCases : encoding

        print("OQ-5 experiment — how does \(destination.host) want MD5 RESULT encoded?")
        print("  method    \(method.rawValue)")
        print("  username  \(destination.username)")
        print("  candidates")
        for candidate in candidates {
            print("    \(candidate.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(candidate.explanation)")
        }
        print("")

        var results: [(MD5ResultEncoding, OQ5Probe.Outcome)] = []
        for candidate in candidates {
            print("→ \(candidate.rawValue) …", terminator: "")
            fflush(stdout)
            let outcome = await OQ5Probe.run(
                destination: destination,
                method: method,
                encoding: candidate,
                timeout: .seconds(timeout))
            print(" \(outcome.summary)")
            if let challenge = outcome.challenge {
                print("    challenge  \(challenge)")
                print("    sent       \(candidate.rendering(challenge: challenge, secret: destination.secret))")
            }
            results.append((candidate, outcome))
            if outcome.isAccepted, !exhaustive { break }
            // A node that has just rejected an authentication attempt may
            // rate-limit the next one. A second between probes costs nothing
            // and removes a confounder from the result.
            try? await Task.sleep(for: .seconds(1))
        }

        print("")
        print(OQ5Probe.conclusion(for: results))
    }
}

// MARK: - The probe

/// One authentication exchange with a real node, using one candidate encoding.
///
/// ### Why this speaks the protocol directly instead of using `IAX2Client`
///
/// The probe varies the encoding per attempt, and one of the candidates —
/// ``MD5ResultEncoding/rawBytes`` — is not a text rendering at all, so it
/// cannot go through `IAX2Auth.md5Response` or the `md5ResultEncoding` seam on
/// `IAX2Call.Configuration`: it needs the MD5 RESULT IE built by hand as
/// `.unknown(id: 0x10, …)`. Driving the exchange here keeps all four
/// candidates on one code path instead of splitting three through the client
/// and one around it.
///
/// Rather than leave OQ-5 unanswerable, this probe drives the exchange itself
/// on the public primitives — `ReliableChannel` for sequence numbers,
/// acknowledgement and retransmission (§7), `InformationElement` for the IE
/// block, `IAX2Auth.md5Response(challenge:secret:encoding:)` for the digest.
/// It re-implements no protocol logic that IAX2Kit already owns; it composes
/// the same pieces `IAX2Call` composes, and varies the one thing under test.
///
/// **When the answer turns out not to be lowercase hex**, the `connect` path
/// is a configuration change (`IAX2Call.Configuration.md5ResultEncoding`), but
/// the registration path has no such seam and `rawBytes` has no text rendering
/// to set — see docs/CLI.md for what each outcome costs.
enum OQ5Probe {
    /// What a node said about one candidate.
    enum Outcome {
        /// The node authenticated us with this encoding. This is the answer.
        case accepted(challenge: String)
        /// The node challenged us and then refused this answer.
        case rejected(challenge: String, cause: String?, causeCode: UInt8?)
        /// The node let us in without a challenge, so it has told us nothing
        /// about the encoding.
        case noChallengeIssued
        /// Nothing came back in time.
        case timedOut
        /// The node answered with something the exchange does not expect.
        case unexpected(String)
        /// We could not get as far as asking.
        case failed(String)

        var isAccepted: Bool { if case .accepted = self { return true }; return false }

        /// The challenge string the node issued, where there was one — worth
        /// printing, because a challenge that varies per attempt and a
        /// challenge that does not are different situations.
        var challenge: String? {
            switch self {
            case .accepted(let challenge): return challenge
            case .rejected(let challenge, _, _): return challenge
            default: return nil
            }
        }

        var summary: String {
            switch self {
            case .accepted:
                return "ACCEPTED"
            case .rejected(_, let cause, let code):
                let detail = [cause, code.map { "cause code \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: ", ")
                return detail.isEmpty ? "rejected" : "rejected (\(detail))"
            case .noChallengeIssued:
                return "no challenge — the node does not authenticate this account"
            case .timedOut:
                return "no answer"
            case .unexpected(let what):
                return "unexpected: \(what)"
            case .failed(let why):
                return "failed: \(why)"
            }
        }
    }

    /// Runs one probe, bounded by `timeout`, and tears the association down
    /// whatever happens.
    static func run(
        destination: IAX2Destination,
        method: OQ5Command.Method,
        encoding: MD5ResultEncoding,
        timeout: Duration
    ) async -> Outcome {
        let transport: NWDatagramTransport
        do {
            transport = try NWDatagramTransport(host: destination.host, port: destination.port)
        } catch {
            return .failed(describe(error))
        }

        let sourceCallNumber = UInt16.random(in: 1...32767)
        let channel = ReliableChannel(
            sourceCallNumber: sourceCallNumber,
            transport: transport,
            clock: ContinuousClock(),
            // Two attempts, not four: a probe that has heard nothing after a
            // second is measuring reachability, not encoding, and four
            // retransmissions per candidate makes an eight-second timeout
            // expire before the ladder does.
            configuration: ReliableChannel.Configuration(
                initialRetryInterval: .milliseconds(500), maximumRetries: 2))

        let outcome: Outcome = await withTaskGroup(of: Outcome?.self) { group in
            group.addTask {
                await exchange(
                    channel: channel,
                    transport: transport,
                    sourceCallNumber: sourceCallNumber,
                    destination: destination,
                    method: method,
                    encoding: encoding)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return Task.isCancelled ? nil : .timedOut
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .timedOut
        }

        await channel.close()
        await transport.close()
        return outcome
    }

    private static func exchange(
        channel: ReliableChannel,
        transport: NWDatagramTransport,
        sourceCallNumber: UInt16,
        destination: IAX2Destination,
        method: OQ5Command.Method,
        encoding: MD5ResultEncoding
    ) async -> Outcome {
        let origin = ContinuousClock.now
        func timestamp() -> UInt32 {
            let elapsed = origin.duration(to: ContinuousClock.now)
            return UInt32(truncatingIfNeeded: elapsed.components.seconds * 1000
                + elapsed.components.attoseconds / 1_000_000_000_000_000)
        }

        // The opening message: a registration request, or a call setup.
        do {
            switch method {
            case .register:
                try await channel.send(
                    .regreq,
                    timestamp: timestamp(),
                    payload: try InformationElement.serialize([
                        .username(destination.username),
                        // §8.6.18: the registration lifetime. Kept short so a
                        // successful probe leaves the node's registration table
                        // clean a minute later, whatever else happens.
                        .refresh(60),
                    ]))
            case .call:
                try await channel.send(
                    .new,
                    timestamp: timestamp(),
                    payload: try InformationElement.serialize(
                        destination.callRequest.newInformationElements()))
            }
        } catch {
            return .failed(describe(error))
        }

        var challengeSeen: String?

        for await datagram in transport.incoming {
            guard let frame = try? IAX2Frame.parse(datagram) else { continue }
            // One UDP association per probe, so anything arriving should be
            // ours — but a stray datagram fed through the channel would corrupt
            // its sequence state, and silently wrong results are the one thing
            // an experiment must not produce.
            if let full = frame.fullFrame,
                full.destinationCallNumber != 0,
                full.destinationCallNumber != sourceCallNumber {
                continue
            }

            let inbound = await channel.receive(frame)
            guard case .deliver(let full) = inbound else { continue }

            if await channel.destinationCallNumber == 0, full.sourceCallNumber != 0 {
                await channel.setDestinationCallNumber(full.sourceCallNumber)
            }

            let elements = (try? InformationElement.parseList(full.payload)) ?? []

            switch full.iaxMessage {
            case .regauth, .authreq:
                guard let challenge = elements.challengeValue else {
                    return .unexpected("\(full.iaxMessage.map(String.init(describing:)) ?? "?") without a CHALLENGE IE")
                }
                challengeSeen = challenge
                let md5 = encoding.informationElement(
                    challenge: challenge, secret: destination.secret)
                do {
                    switch method {
                    case .register:
                        try await channel.send(
                            .regreq,
                            timestamp: timestamp(),
                            payload: try InformationElement.serialize([
                                .username(destination.username), md5, .refresh(60),
                            ]))
                    case .call:
                        try await channel.send(
                            .authrep,
                            timestamp: timestamp(),
                            payload: try InformationElement.serialize([md5]))
                    }
                } catch {
                    return .failed(describe(error))
                }

            case .regack, .accept:
                guard let challenge = challengeSeen else { return .noChallengeIssued }
                if method == .call {
                    // Do not stay on a call we only placed to ask a question.
                    // §8.6.33 cause code 16 is Q.931 "normal call clearing".
                    let cause = (try? InformationElement.serialize([
                        .cause("OQ-5 probe complete"), .causeCode(16),
                    ])) ?? []
                    _ = try? await channel.send(.hangup, timestamp: timestamp(), payload: cause)
                }
                return .accepted(challenge: challenge)

            case .regrej, .reject:
                let cause = elements.causeValue
                let code = elements.causeCodeValue
                guard let challenge = challengeSeen else {
                    return .unexpected("rejected before any challenge: \(cause ?? "no cause given")")
                }
                return .rejected(challenge: challenge, cause: cause, causeCode: code)

            case .inval:
                return .unexpected("INVAL — the node does not recognise this call leg")

            case .hangup:
                return .unexpected("HANGUP: \(elements.causeValue ?? "no cause given")")

            default:
                // PING, LAGRQ, ANSWER and friends are none of this probe's
                // business; `ReliableChannel` has already ACKed them.
                continue
            }
        }

        return .timedOut
    }

    /// What the whole run means, in words a maintainer can paste into OQ-5.
    static func conclusion(for results: [(MD5ResultEncoding, Outcome)]) -> String {
        let accepted = results.filter { $0.1.isAccepted }.map(\.0)
        if accepted.count == 1 {
            let winner = accepted[0]
            var text = """
                CONCLUSION: this node accepts MD5 RESULT as \(winner.rawValue) \
                (\(winner.explanation)).
                """
            if winner != .lowercaseHex {
                text += """


                    That is NOT what IAX2Kit ships. `IAX2Auth.TextDigestEncoding.oq5Default` \
                    renders lowercase hex, and `IAX2Call.handleAuthenticationRequest` uses it \
                    by default. Record this in OQ-5 and change that one call site.
                    """
            } else {
                text += """


                    That is what IAX2Kit already ships, so no code changes. Record the \
                    observation against OQ-5 — it is now an observation rather than an \
                    assumption.
                    """
            }
            return text
        }
        if accepted.count > 1 {
            return "CONCLUSION: more than one encoding was accepted (\(accepted.map(\.rawValue).joined(separator: ", "))). "
                + "That should not be possible for a node that checks the digest, so treat this "
                + "run as unreliable and repeat it."
        }
        if results.contains(where: { if case .noChallengeIssued = $0.1 { return true }; return false }) {
            return "CONCLUSION: the node did not challenge, so it cannot answer OQ-5. "
                + "Configure a secret for this account on the node and run this again."
        }
        if results.allSatisfy({ if case .timedOut = $0.1 { return true }; return false }) {
            return "CONCLUSION: nothing answered. Check the host, the port, and that UDP can "
                + "reach the node — no encoding was actually tested."
        }
        return "CONCLUSION: every candidate was refused. The most likely explanation is a wrong "
            + "secret or username, not an exotic encoding — check those first, then consider "
            + "that the answer may be something none of these four candidates covers."
    }
}

// MARK: - IE lookups

extension Array where Element == InformationElement {
    var challengeValue: String? {
        for element in self { if case .challenge(let value) = element { return value } }
        return nil
    }

    var causeValue: String? {
        for element in self { if case .cause(let value) = element { return value } }
        return nil
    }

    var causeCodeValue: UInt8? {
        for element in self { if case .causeCode(let value) = element { return value } }
        return nil
    }
}
