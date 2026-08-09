// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Serialises everything written to the terminal.
///
/// Two things want the screen at once: a status line that redraws ten times a
/// second, and event lines that arrive whenever the node feels like it. If
/// they interleave without coordination the result is a status line with half
/// a log message written through it. An actor is the smallest thing that fixes
/// that.
///
/// The status line is kept on the bottom row and redrawn after every log line,
/// so scrollback stays a clean transcript of what happened while the live
/// meters stay visible.
actor Console {
    /// `false` when stdout is not a terminal (piped, redirected, CI). Then
    /// there is no cursor to move and no status line worth drawing: every log
    /// line is printed plainly, and status updates are dropped rather than
    /// filling a log file with thousands of escape sequences.
    let isInteractive: Bool

    private var status = ""
    private var statusVisible = false

    init(isInteractive: Bool) {
        self.isInteractive = isInteractive
    }

    /// Writes a permanent line above the status line.
    func log(_ line: String) {
        guard isInteractive else {
            write(line + "\n")
            return
        }
        clearStatusLine()
        write(line + "\n")
        redrawStatus()
    }

    /// Something the operator must not miss: a bell, a blank line either side,
    /// and a banner. Used for the transmit watchdog (SF-1) and for a call the
    /// node tore down underneath us.
    func alert(_ line: String) {
        let rule = String(repeating: "!", count: max(8, min(72, line.count + 8)))
        log("\u{7}\n\(rule)\n!!! \(line)\n\(rule)\n")
    }

    /// Replaces the status line. No-op when not interactive.
    func setStatus(_ line: String) {
        guard isInteractive else { return }
        status = line
        redrawStatus()
    }

    /// Erases the status line for good — call before returning the terminal to
    /// the shell, so the last thing on screen is the transcript, not a frozen
    /// meter.
    func clearStatus() {
        guard isInteractive else { return }
        clearStatusLine()
        status = ""
    }

    // MARK: Private

    private func clearStatusLine() {
        guard statusVisible else { return }
        write("\r\u{1B}[2K")
        statusVisible = false
    }

    private func redrawStatus() {
        guard !status.isEmpty else { return }
        write("\r\u{1B}[2K" + status)
        statusVisible = true
    }

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
