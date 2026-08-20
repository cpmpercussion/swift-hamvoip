// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IAX2Kit
import RadioCore

// MARK: - Command

/// `hamvoip-cli iax2` — one live call to an AllStar node, driven from a
/// terminal.
struct ConnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        // Renamed from `connect` when the CLI went protocol-first (one command
        // per mode, like `m17` and `echolink`). The old name stays as an
        // alias: it appears throughout docs/CLI.md's session records and in
        // three milestones' worth of muscle memory.
        commandName: "iax2",
        abstract: "Place an IAX2 call to an AllStarLink node and work it from the terminal.",
        discussion: """
            Connects, plays received audio through the default output device, and \
            transmits the default input device when PTT is on. Keys are read one at a \
            time, so the spacebar takes effect immediately rather than at the next \
            newline; the terminal is put back exactly as it was on every exit path, \
            including Ctrl-C, a kill, and a crash.

            KEY BINDINGS
              SPACE        toggle PTT (transmit on/off)
              0-9 * # A-D  send that DTMF digit immediately
              d            type a DTMF sequence, RETURN to send, ESC to cancel
              ?            reprint these bindings
              q / Ctrl-C   quit: unkey, hang up, disconnect, restore the terminal

            THE SECRET
              Do not use --secret unless you are scripting. A secret in argv is
              visible in `ps` to every process on this machine, and is written to
              your shell history. Set IAX2_SECRET instead, or supply nothing and
              type it at the prompt, where echo is disabled.

            WEB TRANSCEIVER
              To reach a node you have no credentials for, use your allstarlink.org
              portal account instead. Fetch a token from /api/v2/auth-wt-legacy, then
              call with --username allstar-public, --node s, the token in
              --calling-name and the destination node number in --calling-number;
              the secret is the static string `allstar`. None of that is guessable,
              and all of it is spelled out in docs/CLI.md section 11.

            DIAGNOSTICS
              HAMVOIP_TRACE=1 writes every received frame, and the reason the call
              ended, to stderr. Reach for it before theorising: a rejected call is
              answered by some nodes before being dropped, so "connected" is not by
              itself evidence of anything.

            LICENSING
              Transmitting on amateur frequencies requires a licence, and connecting
              to a node may key a repeater. Nothing is transmitted until you press
              the spacebar.
            """,
        aliases: ["connect"])

    @OptionGroup var node: NodeOptions

    @Option(
        name: .long,
        help: ArgumentHelp(
            "SF-1 transmit watchdog, in seconds. The watchdog unkeys for you if a "
                + "transmission runs this long.",
            valueName: "seconds"))
    var transmitTimeout: Int = 180

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Do not open the microphone or speaker. Signalling, auth and DTMF only — "
                + "useful for checking credentials without a headset."))
    var noAudio: Bool = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Send this DTMF sequence once the call is up, then carry on normally.",
            valueName: "digits"))
    var dtmf: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Hang up automatically after this many seconds. Without it the session runs "
                + "until you press q.",
            valueName: "seconds"))
    var duration: Int?

    func run() async throws {
        let transmitTimeout: Duration
        let destination: IAX2Destination
        let secretSource: SecretPrompt.Source
        let queuedDTMF: [Character]
        do {
            transmitTimeout = try ArgumentValidation.requireTransmitTimeout(seconds: self.transmitTimeout)
            queuedDTMF = try dtmf.map { try ArgumentValidation.requireDTMFSequence($0) } ?? []
            (destination, secretSource) = try node.resolvedDestination()
        } catch let error as CLIValidationError {
            throw ValidationError(error.description)
        }

        let session = ConnectSession(
            destination: destination,
            secretSource: secretSource,
            transmitTimeout: transmitTimeout,
            useAudioDevices: !noAudio,
            queuedDTMF: queuedDTMF,
            duration: duration.map { Duration.seconds($0) })
        try await session.run()
    }
}

// MARK: - Session

/// One connected session: the client, the audio devices, the terminal and the
/// four loops that tie them together.
///
/// An actor because five concurrent tasks mutate the same meters and flags —
/// keystrokes, client events, received audio, captured audio, and the status
/// ticker — and the alternative to isolation would be a lock around every
/// field.
actor ConnectSession {
    private enum InputMode {
        case normal
        case dtmfEntry(String)
    }

    private let destination: IAX2Destination
    private let secretSource: SecretPrompt.Source
    private let transmitTimeout: Duration
    private let useAudioDevices: Bool
    private let queuedDTMF: [Character]
    private let duration: Duration?

    private let client: IAX2Client
    private let console: Console
    private let bridge = AudioFrameBridge()
    private var pipeline: AudioPipeline?
    private var silentSource: Task<Void, Never>?

    private var rxMeter = LevelMeter()
    private var txMeter = LevelMeter()
    private var mode: InputMode = .normal
    private var lastNote = ""
    private var watchdogExpiries = 0
    private var dtmfSent = 0
    private var dtmfReceived = 0
    /// Frames that actually reached the wire — counted where `send(pcm:)`
    /// returns a frame rather than `nil`, which is the PTT gate itself.
    ///
    /// Kept separate from the bridge's *submitted* count on purpose. Capture
    /// runs continuously, so the submitted count rises whether or not PTT is
    /// on; reporting it as "transmitted" says the client keyed up when it did
    /// not, which is the single most alarming thing a summary could get wrong.
    private var transmittedFrames = 0
    /// Set the moment a quit is requested, so the disconnection our own
    /// teardown causes is not reported as though the call had dropped.
    private var isQuitting = false
    private var finished = false

    init(
        destination: IAX2Destination,
        secretSource: SecretPrompt.Source,
        transmitTimeout: Duration,
        useAudioDevices: Bool,
        queuedDTMF: [Character],
        duration: Duration?
    ) {
        self.destination = destination
        self.secretSource = secretSource
        self.transmitTimeout = transmitTimeout
        self.useAudioDevices = useAudioDevices
        self.queuedDTMF = queuedDTMF
        self.duration = duration
        self.client = IAX2Client(
            configuration: IAX2Client.Configuration(transmitTimeout: transmitTimeout))
        self.console = Console(isInteractive: isatty(STDOUT_FILENO) == 1)
    }

    // MARK: Lifecycle

    func run() async throws {
        await printBanner()

        await console.log("Connecting to \(destination.host):\(destination.port), node \(destination.node)…")
        do {
            try await client.connect(to: destination)
        } catch {
            await console.log("FAILED: \(describe(error))")
            await console.log(hintFor(error))
            throw ExitCode.failure
        }

        if useAudioDevices {
            await startAudioDevices()
        } else {
            startSilentSource()
            await console.log(
                "Audio devices not opened (--no-audio): PTT sends silence, 20 ms at a time.")
        }

        // Sent here rather than as a task in the group below, because a task
        // that *completes* in that group ends the session — `group.next()`
        // returns on the first one to finish — and a one-shot DTMF burst would
        // hang the call up half a second after it came up.
        if !queuedDTMF.isEmpty {
            // A node that has just answered is often still playing its own
            // announcement, and DTMF sent into the first milliseconds of a call
            // is the classic "the node ignored my command" report.
            try? await Task.sleep(for: .milliseconds(500))
            await send(dtmf: queuedDTMF)
        }

        // Raw mode goes on only once the call is up. Before that, Ctrl-C should
        // behave the way it does in every other command-line program.
        var terminal: RawTerminal?
        if RawTerminal.isTerminal() {
            terminal = try? RawTerminal.enter()
            if terminal == nil {
                await console.log("Could not enter raw mode; keys are unavailable this session.")
            }
        } else {
            await console.log("Standard input is not a terminal: no key handling. "
                + "The session will run until the node hangs up or --duration elapses.")
        }
        defer { terminal?.leave() }

        await printKeyBindings()

        var keyReader: KeyReader?
        if terminal != nil { keyReader = KeyReader() }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.runEventLoop() }
            group.addTask { await self.runStatusTicker() }
            // The media loops end the session when they finish — which is right
            // when audio is live and the devices go away, and wrong under
            // --no-audio, where their streams are empty and finish at once. Left
            // in the group unconditionally they ended every signalling-only
            // session the instant it connected, so `--duration` never applied and
            // a node-side hangup could never be observed. Found while working
            // IAX-12; see experiment-data/wt-oq10-result.txt.
            if pipeline != nil {
                group.addTask { await self.runReceiveLoop() }
                group.addTask { await self.runAudioSignalLoop() }
            }
            // The transmit loop also runs under `--no-audio`, where its frames
            // come from `SilentCaptureSource` instead of a microphone. That is
            // what makes the flag's promise true: without this the silence is
            // produced and nothing consumes it, and PTT still puts nothing on
            // air. The loop is safe to add here for the same reason the comment
            // above gives — `AudioFrameBridge.frames` no longer finishes at
            // once, because something is now feeding it.
            if pipeline != nil || silentSource != nil {
                group.addTask { await self.runTransmitLoop() }
            }
            if let keyReader {
                group.addTask { await self.runKeyLoop(keyReader) }
            }
            if let duration {
                group.addTask {
                    // `try?` here would swallow the CancellationError raised when
                    // another task ends the session first, and we would announce a
                    // timer that never fired — which is exactly what happened while
                    // investigating IAX-12: every node-side hangup was reported as
                    // "--duration elapsed", hiding the real reason for ten straight
                    // calls. On cancellation, say nothing and let the task that
                    // actually ended the session do the reporting.
                    do {
                        try await Task.sleep(for: duration)
                    } catch {
                        return
                    }
                    await self.note("--duration elapsed")
                    await self.requestQuit()
                }
            }
            // Whichever loop finishes first ends the session: the key loop
            // returns when the operator quits, the event loop when the node
            // hangs up. Everything else is cancelled behind it.
            await group.next()
            keyReader?.cancel()
            group.cancelAll()
        }

        await teardown()
        terminal?.leave()
        await console.clearStatus()
        await console.log("Session ended. Terminal restored.")
        await printSummary()
    }

    private func teardown() async {
        guard !finished else { return }
        finished = true
        await client.stopTransmit()
        silentSource?.cancel()
        pipeline?.stop()
        bridge.finish()
        await client.disconnect()
    }

    /// Every quit path goes through here — the `q`/`Ctrl-C`/`Ctrl-D`
    /// keystrokes and the signal handlers alike — so this is the one place the
    /// flag needs setting.
    private func requestQuit() async {
        isQuitting = true
        await teardown()
    }

    // MARK: Audio devices

    /// `--no-audio`'s stand-in for the microphone tap. Continuous, like the
    /// tap, because the client drops frames while unkeyed.
    private func startSilentSource() {
        let bridge = self.bridge
        silentSource = SilentCaptureSource.start { frame in bridge.submit(frame) }
    }

    private func startAudioDevices() async {
        let pipeline = AudioPipeline()
        self.pipeline = pipeline
        #if os(iOS)
        do {
            try pipeline.configureSession()
        } catch {
            await console.log("Audio session could not be configured: \(error)")
        }
        #endif
        do {
            let bridge = self.bridge
            // Capture runs for the whole session, not just while keyed. That is
            // what makes the PTT edge crisp: `AVAudioEngine` takes tens of
            // milliseconds to start, and starting it on the spacebar would clip
            // the first syllable of every over. `IAX2Client.send(pcm:)` drops
            // frames while unkeyed by design — "not transmitting is not an
            // error" — so the gate lives in one place instead of two.
            try pipeline.startCapture { frame in bridge.submit(frame) }
            await console.log("Microphone and speaker open. Capture runs continuously; "
                + "audio is only transmitted while PTT is on.")
        } catch {
            self.pipeline = nil
            await console.log("Could not start capture: \(error). "
                + "Receive-only for this session.")
        }
    }

    // MARK: Loops

    private func runEventLoop() async {
        for await event in client.events {
            await report(event)
            if case .disconnected = event { return }
        }
    }

    private func runReceiveLoop() async {
        for await pcm in client.receivedAudio {
            rxMeter.push(pcm)
            pipeline?.enqueuePlayback(pcm)
        }
    }

    private func runTransmitLoop() async {
        for await frame in bridge.frames {
            do {
                if try await client.transmit(pcm: frame) != nil {
                    transmittedFrames += 1
                    txMeter.push(frame)
                } else {
                    txMeter.idle()
                }
            } catch {
                await note("transmit error: \(describe(error))")
            }
        }
    }

    /// **SF-3.** `AudioPipeline` surfaces interruptions and route changes but
    /// deliberately does not act on them; acting is the job of whoever owns PTT
    /// state, which here is this session. An unplugged headset that left the
    /// transmitter keyed is precisely the stuck-microphone failure the design
    /// requirements name.
    private func runAudioSignalLoop() async {
        guard let pipeline else { return }
        for await signal in pipeline.signals {
            if case .transmitting = client.state {
                await client.stopTransmit()
                await console.alert("AUDIO \(signal) — transmit stopped (SF-3)")
            } else {
                await note("audio \(signal)")
            }
        }
    }

    private func runStatusTicker() async {
        while !Task.isCancelled {
            await console.setStatus(statusLine())
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func runKeyLoop(_ reader: KeyReader) async {
        for await key in reader.keys {
            if await handle(key: key) == .quit { return }
        }
    }

    // MARK: Key handling

    private enum KeyOutcome { case handled, quit }

    private func handle(key: UInt8) async -> KeyOutcome {
        if case .dtmfEntry(let buffer) = mode {
            switch key {
            case 0x0D, 0x0A:  // RETURN
                mode = .normal
                let digits = (try? ArgumentValidation.requireDTMFSequence(buffer)) ?? []
                if digits.isEmpty, !buffer.isEmpty {
                    await note("not a DTMF sequence: \(buffer)")
                } else {
                    await send(dtmf: digits)
                }
            case 0x1B:  // ESC
                mode = .normal
                await note("DTMF entry cancelled")
            case 0x7F, 0x08:  // DEL / BACKSPACE
                mode = .dtmfEntry(String(buffer.dropLast()))
            case 0x03:  // Ctrl-C aborts entry, not the session
                mode = .normal
                await note("DTMF entry cancelled")
            default:
                if let scalar = Unicode.Scalar(UInt32(key)), key >= 0x20, key < 0x7F {
                    mode = .dtmfEntry(buffer + String(Character(scalar)))
                }
            }
            return .handled
        }

        switch key {
        case 0x20:  // SPACE
            await toggleTransmit()
        case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03, 0x04:  // q, Ctrl-C, Ctrl-D
            await note("quitting")
            await requestQuit()
            return .quit
        case UInt8(ascii: "?"), UInt8(ascii: "h"):
            await printKeyBindings()
        case UInt8(ascii: "d"):
            mode = .dtmfEntry("")
            await note("DTMF sequence — RETURN to send, ESC to cancel")
        default:
            if let scalar = Unicode.Scalar(UInt32(key)), key < 0x80 {
                let character = Character(String(scalar).uppercased())
                if (try? IAX2DTMFDigit(character)) != nil {
                    await send(dtmf: [character])
                }
            }
        }
        return .handled
    }

    private func toggleTransmit() async {
        if case .transmitting = client.state {
            await client.stopTransmit()
        } else {
            do {
                try await client.startTransmit()
            } catch {
                await note("cannot transmit: \(describe(error))")
            }
        }
    }

    private func send(dtmf digits: [Character]) async {
        guard !digits.isEmpty else { return }
        do {
            for digit in digits {
                try await client.send(dtmf: digit)
                dtmfSent += 1
            }
            await console.log("TX DTMF  \(String(digits))")
        } catch {
            await note("DTMF failed: \(describe(error))")
        }
    }

    // MARK: Reporting

    private func report(_ event: IAX2ClientEvent) async {
        switch event {
        case .connected(let format):
            let codec = format.map { "\($0)" } ?? "unspecified"
            await console.log("CONNECTED  codec \(codec)")
        case .transmitting:
            await console.log("TX ON")
        case .receiving:
            await console.log("TX OFF")
        case .transmitWatchdogExpired(let timeout):
            watchdogExpiries += 1
            await console.alert(
                "TRANSMIT WATCHDOG EXPIRED after \(timeout) — transmission was stopped for you (SF-1)")
        case .dtmf(let digit):
            dtmfReceived += 1
            await console.log("RX DTMF  \(digit)")
        case .mediaRejected(let rejection):
            await console.log("RX media dropped: \(rejection)")
        case .disconnected(let reason):
            // Quitting closes the transport ourselves, so the read loop reports
            // a disconnection a moment later. Alarming somebody with
            // "DISCONNECTED: the transport closed" immediately after they
            // pressed `q` is telling them their call dropped when in fact they
            // ended it, so the banner is suppressed once a quit is under way.
            // The packet capture of the 75 s session shows the HANGUP and its
            // ACK going out perfectly while that banner was on screen.
            guard !isQuitting else { break }
            if let reason {
                await console.alert("DISCONNECTED: \(reason)")
            } else {
                await console.alert("DISCONNECTED: the transport closed")
            }
        }
    }

    private func note(_ text: String) async {
        lastNote = text
        await console.log("· \(text)")
    }

    private func statusLine() -> String {
        var transmitField = "RX"
        if case .transmitting(let since) = client.state {
            let elapsed = Int(Date().timeIntervalSince(since))
            let limit = Int(transmitTimeout.components.seconds)
            transmitField = "TX \(elapsed)s/\(limit)s"
        }
        if case .dtmfEntry(let buffer) = mode {
            return "DTMF> \(buffer)_  (RETURN send, ESC cancel)"
        }
        let dropped = bridge.droppedFrameCount
        let droppedField = dropped > 0 ? "  drop \(dropped)" : ""
        return "[\(transmitField)]  rx \(rxMeter.rendered(width: 12))"
            + "  tx \(txMeter.rendered(width: 12))\(droppedField)"
    }

    private func printBanner() async {
        await console.log("hamvoip-cli — IAX2 harness for AllStarLink (RFC 5456)")
        await console.log("  node      \(destination.node) at \(destination.host):\(destination.port)")
        await console.log("  username  \(destination.username)")
        await console.log("  callsign  \(destination.callsign)")
        if !destination.callingNumber.isEmpty {
            await console.log("  calling#  \(destination.callingNumber)")
        }
        await console.log("  secret    \(secretSource)")
        await console.log("  watchdog  \(transmitTimeout) (SF-1)")
        if case .commandLine = secretSource {
            await console.log(
                "  WARNING: the secret came from --secret, so it is in your shell history "
                    + "and was visible in `ps` while this process started. Rotate it if that "
                    + "matters, and prefer $\(SecretPrompt.environmentVariable) next time.")
        }
        await console.log("")
    }

    private func printKeyBindings() async {
        await console.log("""
            Keys:  SPACE toggle PTT   0-9 * # A-D send DTMF   d DTMF sequence   ? help   q quit
            """)
    }

    private func printSummary() async {
        await console.log("""
            Summary:
              frames captured      \(bridge.submittedFrameCount)  (microphone runs continuously)
              frames transmitted   \(transmittedFrames)  (PTT on)
              frames dropped       \(bridge.droppedFrameCount)
              DTMF sent/received   \(dtmfSent)/\(dtmfReceived)
              watchdog expiries    \(watchdogExpiries)
            """)
    }

    private func hintFor(_ error: Error) -> String {
        if case IAX2ClientError.rejected(let cause, let code) = error {
            if cause == nil {
                // A REJECT with no CAUSE IE says nothing about whether the
                // secret was ever examined: the peer may have refused the NEW
                // before challenging, in which case the credentials are
                // untested rather than wrong. IAX-12 later captured exactly
                // that — three datagrams, NEW / REJECT / ACK, no AUTHREQ — so
                // this is now an observed case rather than a supposition.
                return "The node gave no CAUSE, which leaves it open whether it ever asked for "
                    + "the secret. A node that refuses the NEW outright never checks the "
                    + "credentials, so a rejection here is not evidence that --username or the "
                    + "secret is wrong. Run again with HAMVOIP_TRACE=1 and look for an AUTHREQ "
                    + "before the REJECT: if none arrives, the node refused the account rather "
                    + "than the password, which is a conversation with its operator and not a "
                    + "credential to change. The usual cause is a username the node does not "
                    + "know — Web Transceiver's is the literal `allstar-public`, and putting a "
                    + "callsign there produces precisely this."
            }
            if code == 50 {
                // "No authority found". The node authenticated the call and
                // then refused to authorise it, which is a different failure
                // from a bad secret and wants a different fix (IAX-12).
                return "Cause 50 is the authority check failing rather than a bad secret: the "
                    + "node accepted the credentials, then asked allstarlink.org whether to "
                    + "admit you and was told no. For Web Transceiver that means CALLING NAME "
                    + "is not carrying a token the portal recognises — see docs/CLI.md §11. "
                    + "Changing the secret will not help."
            }
            return "The node gave its reason above. That usually means the username or the "
                + "secret is wrong, or that this account is not permitted to call this node."
        }
        if case IAX2ClientError.connectTimedOut = error {
            return "No answer. Check the host and port, and that this machine can reach UDP "
                + "\(destination.port) — the transport cannot tell an unreachable host from a "
                + "slow one."
        }
        return "Check --host, --port, --node and --username."
    }
}

/// An error as text a human should read.
///
/// `String(describing:)` rather than `localizedDescription`: every error type
/// in IAX2Kit and RadioCore conforms to `CustomStringConvertible` and says
/// something specific and useful ("the node rejected the call: No such user"),
/// and `String(describing:)` is what picks those up. `localizedDescription`
/// bridges through `NSError` and turns most of them into "The operation
/// couldn't be completed", which discards exactly the part worth printing.
func describe(_ error: Error) -> String {
    String(describing: error)
}
