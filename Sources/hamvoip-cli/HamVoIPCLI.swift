// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

/// `hamvoip-cli` — the macOS harness for driving swift-hamvoip against a real
/// AllStarLink node from a terminal.
///
/// CLI-1 exists because of a line in the design requirements: wherever
/// possible, set up testing via the command line so nobody has to open Xcode.
/// This command is the whole of that principle for this project. Everything
/// below it — the frame parser, the reliable channel, the jitter buffer, the
/// codec — has unit tests against recorded fixtures, and none of those tests
/// can tell you whether a human can hold a conversation. That is Milestone M2,
/// and this is the only tool that reaches it before an app exists.
///
/// It is macOS-only in practice: it wants a terminal and a Mac's audio
/// devices. The package still builds for iOS, because an iOS app depends on
/// the library products and never on this target.
@main
struct HamVoIPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hamvoip-cli",
        abstract: "Drive swift-hamvoip against a real AllStarLink node from a terminal.",
        discussion: """
            Three subcommands:

              connect  place a call and work it — spacebar for PTT, DTMF for node control,
                       level meters for both directions, and the SF-1 transmit watchdog
                       shown when it fires.
              oq5      settle OQ-5 — how a real node wants the MD5 RESULT information
                       element encoded — by asking one, instead of by reading somebody
                       else's implementation.
              oq7      settle OQ-7 — whether an M17 IP stream frame is 56 bytes or 54 —
                       by measuring what a live reflector sends. Receive-only.

            Transmitting on amateur frequencies requires a licence. Connecting to a node
            can key a repeater; nothing is transmitted until you ask for it.

            Full documentation, including the M2 sign-off checklist: docs/CLI.md
            """,
        version: "0.1.0 (CLI-1)",
        subcommands: [ConnectCommand.self, OQ5Command.self, OQ7Command.self])
}
