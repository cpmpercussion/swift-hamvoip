// SPDX-License-Identifier: Apache-2.0

import XCTest

#if canImport(Darwin)
import Darwin
#endif

@testable import hamvoip_cli

/// Raw mode, exercised against a real pseudo-terminal.
///
/// This is the one piece of terminal handling that does not need a node, an
/// audio device or a human, and it is also the piece whose failure is worst: a
/// terminal left in raw mode has no echo, no line editing and no working
/// Ctrl-C, and a user who quits the harness and finds their shell apparently
/// broken has been handed a genuinely hostile thing. A `posix_openpt` pty
/// gives a real tty to test against, so "the attributes are put back exactly"
/// is an assertion rather than a hope.
final class RawTerminalTests: XCTestCase {

    /// A pseudo-terminal pair, cleaned up by `tearDown`.
    private var primary: Int32 = -1
    private var replica: Int32 = -1

    override func setUpWithError() throws {
        primary = posix_openpt(O_RDWR | O_NOCTTY)
        try XCTSkipIf(primary < 0, "no pseudo-terminal available in this environment")
        XCTAssertEqual(grantpt(primary), 0)
        XCTAssertEqual(unlockpt(primary), 0)
        guard let name = ptsname(primary) else {
            throw XCTSkip("ptsname failed")
        }
        replica = open(name, O_RDWR | O_NOCTTY)
        try XCTSkipIf(replica < 0, "could not open the pseudo-terminal replica")

        // Nothing is reading the primary side, and `tcsetattr(TCSAFLUSH)`
        // waits for pending output to drain before it applies. Leave the
        // primary non-blocking so `drainPrimary()` can empty it between
        // operations without ever parking this thread.
        let flags = fcntl(primary, F_GETFL, 0)
        XCTAssertEqual(fcntl(primary, F_SETFL, flags | O_NONBLOCK), 0)
    }

    /// Empties whatever the replica has written, returning it as text.
    @discardableResult
    private func drainPrimary() -> String {
        var text = ""
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = read(primary, &buffer, buffer.count)
            guard count > 0 else { return text }
            text += String(decoding: buffer[0..<count], as: UTF8.self)
        }
    }

    override func tearDown() {
        if replica >= 0 { close(replica) }
        if primary >= 0 { close(primary) }
        replica = -1
        primary = -1
    }

    private func attributes(of descriptor: Int32) -> termios {
        var value = termios()
        XCTAssertEqual(tcgetattr(descriptor, &value), 0)
        return value
    }

    private func controlCharacters(_ value: termios) -> [cc_t] {
        var copy = value
        return withUnsafeBytes(of: &copy.c_cc) { raw in
            Array(raw.bindMemory(to: cc_t.self))
        }
    }

    // MARK: Detection

    func testAPseudoTerminalIsRecognisedAsATerminal() {
        XCTAssertTrue(RawTerminal.isTerminal(replica))
    }

    func testAPipeIsNotMistakenForATerminal() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        XCTAssertFalse(RawTerminal.isTerminal(descriptors[0]))
    }

    func testEnteringRawModeOnSomethingThatIsNotATerminalFails() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }

        XCTAssertThrowsError(try RawTerminal.enter(descriptor: descriptors[0])) { error in
            guard case TerminalError.notATerminal = error else {
                return XCTFail("expected .notATerminal, got \(error)")
            }
        }
    }

    // MARK: Raw mode

    func testRawModeDisablesEchoCanonicalInputAndSignalGeneration() throws {
        let terminal = try RawTerminal.enter(descriptor: replica)
        defer { terminal.leave(); drainPrimary() }

        let raw = attributes(of: replica)
        XCTAssertEqual(raw.c_lflag & tcflag_t(ECHO), 0, "keystrokes must not be painted over the status line")
        XCTAssertEqual(raw.c_lflag & tcflag_t(ICANON), 0, "PTT must react to the key, not to the next newline")
        XCTAssertEqual(
            raw.c_lflag & tcflag_t(ISIG), 0,
            "ISIG off is what lets Ctrl-C reach the key loop and take the graceful quit path")
    }

    func testRawModeLeavesOutputPostProcessingOnSoOrdinaryPrintingStillWorks() throws {
        let terminal = try RawTerminal.enter(descriptor: replica)
        defer { terminal.leave(); drainPrimary() }
        // With OPOST off, every "\n" would need to be written "\r\n" by hand,
        // and one missed newline produces a staircase transcript.
        XCTAssertNotEqual(attributes(of: replica).c_oflag & tcflag_t(OPOST), 0)
    }

    func testRawModeReadsOneByteAtATimeWithoutATimer() throws {
        let terminal = try RawTerminal.enter(descriptor: replica)
        defer { terminal.leave(); drainPrimary() }
        let control = controlCharacters(attributes(of: replica))
        XCTAssertEqual(control[Int(VMIN)], 1)
        XCTAssertEqual(control[Int(VTIME)], 0)
    }

    // MARK: Restoration

    func testLeaveRestoresEveryFlagAndControlCharacterExactly() throws {
        let before = attributes(of: replica)

        let terminal = try RawTerminal.enter(descriptor: replica)
        XCTAssertNotEqual(attributes(of: replica).c_lflag, before.c_lflag, "raw mode must have changed something")
        terminal.leave()
        drainPrimary()

        let after = attributes(of: replica)
        XCTAssertEqual(after.c_lflag, before.c_lflag)
        XCTAssertEqual(after.c_iflag, before.c_iflag)
        XCTAssertEqual(after.c_oflag, before.c_oflag)
        XCTAssertEqual(after.c_cflag, before.c_cflag)
        XCTAssertEqual(controlCharacters(after), controlCharacters(before))
    }

    func testLeaveIsIdempotent() throws {
        let before = attributes(of: replica)
        let terminal = try RawTerminal.enter(descriptor: replica)
        terminal.leave()
        terminal.leave()
        terminal.leave()
        drainPrimary()
        XCTAssertEqual(attributes(of: replica).c_lflag, before.c_lflag)
    }

    func testRawModeCanBeEnteredAndLeftRepeatedly() throws {
        let before = attributes(of: replica)
        for _ in 0..<3 {
            let terminal = try RawTerminal.enter(descriptor: replica)
            XCTAssertEqual(attributes(of: replica).c_lflag & tcflag_t(ECHO), 0)
            terminal.leave()
            drainPrimary()
            XCTAssertEqual(attributes(of: replica).c_lflag, before.c_lflag)
        }
    }

    func testLeavingWritesTheCursorBackOnSoATerminalIsNotHandedBackWithAHiddenCursor() throws {
        let terminal = try RawTerminal.enter(descriptor: replica)
        terminal.leave()

        // Whatever the epilogue wrote to the replica shows up on the primary
        // side of the pty.
        let text = drainPrimary()
        try XCTSkipIf(text.isEmpty, "the pty delivered nothing to read")
        XCTAssertTrue(text.contains("\u{1B}[?25h"), "expected the show-cursor sequence, got \(Array(text.utf8))")
    }
}
