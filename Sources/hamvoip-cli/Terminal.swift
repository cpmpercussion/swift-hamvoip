// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Global restoration state
//
// These four globals exist because terminal restoration has to work from a
// **signal handler**, and a signal handler cannot capture context, cannot
// allocate, and cannot safely touch anything that might still be lazily
// initialising. They are written exactly once, by `RawTerminal.enter()`,
// before any handler is installed, and read from nowhere else.
//
// A terminal left in raw mode is a genuinely hostile thing to hand a user: no
// echo, no line editing, no working Ctrl-C, and a shell prompt that appears to
// have stopped responding. The cost of that failure is high enough to justify
// four file-scope variables and belt-and-braces restoration on every exit path
// there is.

/// The attributes to put back. Heap-allocated (rather than a Swift global
/// `termios` value) so the signal handler dereferences an address that was
/// fixed at arm time and needs no lazy-initialisation check.
private let savedAttributes = UnsafeMutablePointer<termios>.allocate(capacity: 1)

/// The descriptor to restore, or -1 when raw mode is not in force. Set last
/// when arming and first when disarming, so it is the single flag the handler
/// tests.
private var savedDescriptor: Int32 = -1

/// "Show the cursor, and start a fresh line" — preformatted at arm time so the
/// handler only has to call `write(2)`, which is async-signal-safe. Building
/// this string inside a handler would allocate.
private let restorationEpilogue: UnsafeMutablePointer<CChar> = {
    let text = "\u{1B}[?25h\r\n"
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: text.utf8.count + 1)
    for (index, byte) in text.utf8.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[text.utf8.count] = 0
    return buffer
}()

private var restorationEpilogueLength = 0

/// Puts the terminal back, from anywhere, at any time, as many times as you
/// like. Async-signal-safe: one `tcsetattr` and one `write`, both on the POSIX
/// safe list, over memory that was allocated before any handler existed.
///
/// **`TCSAFLUSH`, both here and when entering.** It is the only action that
/// puts every flag back *and* discards input typed while raw mode was in force
/// — otherwise the spacebar presses of the last half-second land on the shell
/// prompt as commands. `TCSANOW` was tried and rejected: on a pseudo-terminal
/// it leaves the line discipline in a state that does not match what was
/// saved, which defeats the entire purpose of this function.
///
/// The cost is that `TCSAFLUSH` waits for pending output to drain, so it can
/// block on a terminal that is not draining at all. On a real terminal that is
/// microseconds; the pathological case is a pseudo-terminal nobody is reading,
/// which is a test harness rather than a user.
private func restoreTerminalNow() {
    let descriptor = savedDescriptor
    guard descriptor >= 0 else { return }
    savedDescriptor = -1
    _ = tcsetattr(descriptor, TCSAFLUSH, savedAttributes)
    _ = write(descriptor, restorationEpilogue, restorationEpilogueLength)
}

/// Restore, then die the way we were asked to die. Re-raising with the default
/// disposition matters for the crash signals: a SIGSEGV that this handler
/// swallowed would produce no crash report and no non-zero exit status, which
/// would be a second, quieter bug on top of the first.
private func restoreAndReraise(_ signalNumber: Int32) {
    restoreTerminalNow()
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

// MARK: - RawTerminal

/// Errors from terminal setup.
enum TerminalError: Error, CustomStringConvertible {
    case notATerminal
    case attributesUnavailable(errno: Int32)
    case attributesNotApplied(errno: Int32)

    var description: String {
        switch self {
        case .notATerminal:
            return "standard input is not a terminal, so key handling is unavailable"
        case .attributesUnavailable(let code):
            return "could not read the terminal attributes: \(String(cString: strerror(code)))"
        case .attributesNotApplied(let code):
            return "could not set the terminal attributes: \(String(cString: strerror(code)))"
        }
    }
}

/// Raw-mode ownership for one terminal, with restoration on every exit path.
///
/// ### What "raw" means here, and why
///
/// `ICANON` and `ECHO` off: keystrokes arrive one byte at a time, without
/// waiting for Return and without being painted on top of the status line.
/// That is the whole point — spacebar has to key the transmitter on the key
/// down, not on the next newline.
///
/// **`ISIG` is off too, which is the interesting choice.** With `ISIG` on,
/// Ctrl-C would raise `SIGINT` and the only thing a signal handler could
/// honestly do is restore the terminal and let the process die — no HANGUP to
/// the node, no `stopTransmit()`, a call leg left dangling and, in the worst
/// case, a transmitter left keyed. With `ISIG` off, Ctrl-C arrives as byte
/// `0x03` in the ordinary key loop and takes exactly the same graceful path as
/// `q`. The signal handlers below are then a safety net for the signals we
/// *cannot* turn into keystrokes (`SIGTERM`, `SIGHUP`, a crash), rather than
/// the primary quit mechanism.
///
/// ### Restoration paths
///
/// 1. ``leave()`` — the normal one.
/// 2. `atexit` — covers any `exit()`, including ArgumentParser's own.
/// 3. `SIGTERM`/`SIGHUP`/`SIGQUIT` — restore, then die by default disposition.
/// 4. `SIGSEGV`/`SIGBUS`/`SIGILL`/`SIGFPE`/`SIGABRT`/`SIGTRAP` — a crash still
///    hands back a usable terminal, and still crashes.
struct RawTerminal {
    let descriptor: Int32

    /// Whether the given descriptor is a terminal at all. A CLI run with its
    /// input piped (CI, a smoke test, `hamvoip-cli connect < /dev/null`) has
    /// no keyboard, and must not pretend otherwise.
    static func isTerminal(_ descriptor: Int32 = STDIN_FILENO) -> Bool {
        isatty(descriptor) == 1
    }

    /// Saves the current attributes, installs every restoration path, and puts
    /// the terminal into raw mode.
    static func enter(descriptor: Int32 = STDIN_FILENO) throws -> RawTerminal {
        guard isTerminal(descriptor) else { throw TerminalError.notATerminal }

        var original = termios()
        guard tcgetattr(descriptor, &original) == 0 else {
            throw TerminalError.attributesUnavailable(errno: errno)
        }

        // Arm restoration *before* changing anything: if the `tcsetattr` below
        // half-succeeds, or a signal lands between the two calls, the handler
        // already knows what to put back.
        savedAttributes.pointee = original
        restorationEpilogueLength = strlen(restorationEpilogue)
        installRestorationHandlersOnce()
        savedDescriptor = descriptor

        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        // `OPOST` is deliberately left **on**: with output post-processing
        // enabled a bare "\n" still produces CR-LF, so ordinary `print` keeps
        // working and every line does not have to be written "\r\n" by hand.
        withUnsafeMutablePointer(to: &raw.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { control in
                control[Int(VMIN)] = 1
                control[Int(VTIME)] = 0
            }
        }

        guard tcsetattr(descriptor, TCSAFLUSH, &raw) == 0 else {
            let code = errno
            restoreTerminalNow()
            throw TerminalError.attributesNotApplied(errno: code)
        }

        return RawTerminal(descriptor: descriptor)
    }

    /// Restores the terminal. Idempotent, and safe to call from `defer` on a
    /// path where a handler has already run.
    func leave() {
        restoreTerminalNow()
    }

    private static var handlersInstalled = false

    private static func installRestorationHandlersOnce() {
        guard !handlersInstalled else { return }
        handlersInstalled = true

        atexit { restoreTerminalNow() }

        // Asked to stop: restore, then stop.
        for signalNumber in [SIGTERM, SIGHUP, SIGQUIT, SIGINT] {
            signal(signalNumber) { number in restoreAndReraise(number) }
        }
        // Crashing: restore, then still crash.
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            signal(signalNumber) { number in restoreAndReraise(number) }
        }
    }
}

// MARK: - Secret prompting

/// Reading a secret from a human without putting it anywhere it can be read
/// back.
enum SecretPrompt {
    /// The environment variable checked before prompting.
    static let environmentVariable = "HAMVOIP_SECRET"

    /// Where a secret came from, so the session banner can say so. A user who
    /// can see that their password arrived from `argv` is a user who can go and
    /// fix their shell history.
    enum Source: CustomStringConvertible, Equatable {
        /// Carries the flag it actually came from. `resolve` serves more than
        /// one secret now — the EchoLink account password among them — so a
        /// banner that says `--secret` regardless would name a flag the
        /// operator never typed, and send them to the wrong place in their
        /// shell history.
        case commandLine(flag: String)
        case environment(String)
        /// Read from a file in the config directory (`ConfigFile`).
        case configFile(String)
        case prompt
        case none

        var description: String {
            switch self {
            case .commandLine(let flag): return "\(flag) (visible in argv and shell history)"
            case .environment(let name): return "$\(name)"
            case .configFile(let path): return path
            case .prompt: return "interactive prompt"
            case .none: return "none supplied"
            }
        }
    }

    /// Resolves a secret from, in order: the command line, the environment, the
    /// config file, an interactive prompt with echo disabled.
    ///
    /// The config file sits below the environment so a one-off override never
    /// needs an edit, and above the prompt so the common case is silent.
    ///
    /// - Parameters:
    ///   - commandLineValue: whatever the flag carried, if anything.
    ///   - commandLineFlag: the flag's name, for the banner. Only ever read
    ///     when `commandLineValue` is non-nil.
    ///   - name: the environment variable, which is also the config file's
    ///     name — that correspondence *is* the convention.
    ///   - promptText: shown when it comes to asking.
    ///   - environment: the process environment (injected so this is testable).
    ///   - allowPrompt: `false` when stdin is not a terminal — there is nobody
    ///     to prompt, and blocking on a pipe forever is worse than proceeding
    ///     without.
    static func resolve(
        commandLineValue: String?,
        commandLineFlag: String = "--secret",
        name: String = SecretPrompt.environmentVariable,
        promptText: String = "Secret (leave empty for an unauthenticated node): ",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowPrompt: Bool = RawTerminal.isTerminal()
    ) throws -> (secret: String, source: Source) {
        if let commandLineValue {
            return (commandLineValue, .commandLine(flag: commandLineFlag))
        }
        if let fromEnvironment = environment[name], !fromEnvironment.isEmpty {
            return (fromEnvironment, .environment(name))
        }
        if let fromFile = ConfigFile.read(name, environment: environment) {
            let path = ConfigFile.url(for: name, environment: environment)?.path ?? name
            return (fromFile, .configFile(path))
        }
        guard allowPrompt else { return ("", .none) }
        let typed = try readWithoutEcho(prompt: promptText)
        return (typed, typed.isEmpty ? .none : .prompt)
    }

    /// Reads one line from the terminal with echo disabled.
    ///
    /// `getpass(3)` would do this in one call, but it is documented as legacy,
    /// keeps its result in a static buffer, and on some platforms truncates.
    /// Doing it directly is barely longer and the restoration is visible.
    static func readWithoutEcho(prompt: String) throws -> String {
        let descriptor = STDIN_FILENO
        guard RawTerminal.isTerminal(descriptor) else { throw TerminalError.notATerminal }

        var original = termios()
        guard tcgetattr(descriptor, &original) == 0 else {
            throw TerminalError.attributesUnavailable(errno: errno)
        }
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(descriptor, TCSAFLUSH, &quiet) == 0 else {
            throw TerminalError.attributesNotApplied(errno: errno)
        }
        defer {
            _ = tcsetattr(descriptor, TCSAFLUSH, &original)
            FileHandle.standardError.write(Data("\n".utf8))
        }

        FileHandle.standardError.write(Data(prompt.utf8))
        guard let line = readLine(strippingNewline: true) else { return "" }
        return line
    }
}
