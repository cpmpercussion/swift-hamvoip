// SPDX-License-Identifier: Apache-2.0

import ArgumentParser

/// `hamvoip-cli experiment` — the on-air measurement probes, grouped so the
/// top level stays one-command-per-protocol.
///
/// These are not session tools and never were: each exists to settle a
/// specific open question by measuring a live peer instead of reading
/// somebody else's implementation (the clean-room rule, LP-2). Both
/// questions they were built for are settled — OQ-5 on 2026-08-09, OQ-7 on
/// 2026-08-11 — and the probes are kept because a settled answer is a claim
/// about the peers measured so far, not about every peer: `oq7` in
/// particular is the plan's named tool for re-checking the frame size
/// against a second reflector, and it measures below the parser precisely so
/// it can contradict the code running it.
struct ExperimentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experiment",
        abstract: "Measurement probes: the settled open questions, and the audio path.",
        discussion: """
            oq5  how a node wants the MD5 RESULT information element encoded. \
            Settled 2026-08-09: lowercase hex, confirmed against four independent \
            registration exchanges and corroborated on two further nodes since.
            oq7  the M17 IP stream frame size, measured below the parser at the \
            transport seam. Settled 2026-08-11: 54 bytes, no LSF CRC on the wire. \
            Useful against a second reflector — a different answer there would be \
            new information, not a bug. Receive-only.
            capture-swap  what AudioPipeline does when the input device is pulled out \
            from under a live capture (RC-14). Local, not on air: nothing is transmitted \
            and no node is dialled. The one claim in the capture path that no unit test \
            can reach, because it is a claim about AVAudioEngine on real hardware.
            input-warm-up  how long an input device delivers silence after it is opened, \
            and whether opening it once beforehand removes that delay (Currawong's BU-22). \
            Local, not on air. Needs an input device left alone long enough to go cold, \
            which a USB webcam never does.
            """,
        subcommands: [
            OQ5Command.self, OQ7Command.self, CaptureSwapCommand.self,
            InputWarmUpCommand.self,
        ])
}
