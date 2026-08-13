// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import EchoLinkKit
import Foundation
import RadioCore

/// `hamvoip-cli echolink` — connect an EchoLink node and pass audio (EL-10).
///
/// The live-validation harness for EchoLink, and the counterpart to `connect`
/// for IAX2 and `m17` for M17. Everything below the CLI is `EchoLinkClient`;
/// this file is a terminal around it.
///
/// **This has never been run against a real node by this software.** The
/// protocol was recovered from captures of a third-party client's sessions
/// (OQ-9); nothing in this repository has yet spoken to an EchoLink proxy.
/// Settling that is Milestone M3, and it is deliberately the first thing the
/// banner says.
struct EchoLinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "echolink",
        abstract: "Connect an EchoLink node and pass audio (EL-10, Milestone M3).",
        discussion: """
            Connects to a node through an EchoLink proxy, plays what the node \
            sends, and transmits while PTT is on. GSM 06.10 (FR-3.2), 80 ms per \
            packet.

            Transmitting on amateur frequencies requires a licence, and an \
            EchoLink node is a shared channel — everything transmitted may be \
            heard by everyone connected to it, and on many nodes goes out over \
            the air. Nothing is sent until PTT is pressed.

            NOT YET VALIDATED ON AIR BY THIS SOFTWARE. The protocol here was \
            recovered from packet captures of the maintainer's own sessions with \
            a third-party client; this client has never connected to a proxy. \
            Expect to be the first.

            *ECHOTEST* is the obvious first contact: it echoes audio back, so one \
            operator alone can confirm the round trip end to end.

            Two different secrets are involved and they are not interchangeable: \
            the PROXY password (--proxy-password, "PUBLIC" on a public proxy, and \
            not a secret) and your own EchoLink ACCOUNT password. Only the \
            account password is secret, and there is deliberately no option for \
            it — a password on the command line leaks into shell history. It is \
            read from $ECHOLINK_PASSWORD, or prompted for.

            The account login is tunnelled to the directory server, so \
            --directory-server needs that server's IPv4 address. There is no \
            default: the proxy's OPEN carries a raw address, nothing here \
            resolves DNS, and baking one operator's choice of a third party's \
            server into the tool would be a guess about infrastructure rather \
            than about the protocol.

            Pass --no-directory-login to skip it and go straight to the node. \
            Whether a node answers a client that never logged in is NOT \
            established — no capture shows the attempt — so that flag is an \
            experiment, not a supported mode.
            """)

    @Option(name: .long, help: "EchoLink proxy host name or address.")
    var proxy: String

    @Option(name: .long, help: "EchoLink proxy TCP port.")
    var proxyPort: UInt16 = EchoLinkProxyClient.defaultPort

    @Option(name: .long, help: "Proxy password. 'PUBLIC' on a public proxy, and not a secret.")
    var proxyPassword: String = EchoLinkProxyPassword.publicProxy.value

    @Option(name: .long, help: "The node's IPv4 address, dotted quad.")
    var peer: String

    @Option(name: .long, help: "The node's callsign, for display. E.g. *ECHOTEST*")
    var node: String = "(unnamed node)"

    @Option(name: .long, help: ArgumentHelp(
        """
        Your callsign. Defaults to the CALLSIGN file in ~/.config/swift-hamvoip/.
        """))
    var callsign: String?

    @Option(name: .long, help: "Your name, shown to the far end alongside the callsign.")
    var operatorName: String = ""

    @Option(name: .long, help: "Directory server IPv4 address, for the account login.")
    var directoryServer: String?

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Log in to the directory server before opening the node session.")
    var directoryLogin: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Open the microphone and speaker.")
    var audio: Bool = true

    @Option(name: .long, help: "Transmit watchdog timeout in seconds (SF-1).")
    var transmitTimeout: Int = 180

    @Option(name: .long, help: ArgumentHelp(
        """
        How long to keep resending the opening SDES while waiting for the node         to answer, in seconds.
        """))
    var nodeAnswerTimeout: Int = 15

    @Option(name: .long, help: "End the session after this many seconds.")
    var duration: Int?

    func run() async throws {
        guard let peerAddress = EchoLinkPeerAddress(peer) else {
            throw ValidationError("--peer must be a dotted-quad IPv4 address, got '\(peer)'")
        }
        guard transmitTimeout > 0 else {
            throw ValidationError("--transmit-timeout must be positive")
        }

        var accountPassword: EchoLinkAccountPassword?
        var directory: EchoLinkPeerAddress?
        var passwordSource: SecretPrompt.Source = .none
        if directoryLogin {
            guard let directoryServer else {
                throw ValidationError(
                    "--directory-server is required for the account login. Pass "
                        + "--no-directory-login to skip it, but note that whether a node "
                        + "answers a client that never logged in is not established.")
            }
            guard let address = EchoLinkPeerAddress(directoryServer) else {
                throw ValidationError(
                    "--directory-server must be a dotted-quad IPv4 address, got "
                        + "'\(directoryServer)'")
            }
            directory = address
            let (secret, source) = try Self.readAccountPassword()
            accountPassword = EchoLinkAccountPassword(secret)
            passwordSource = source
        }

        // Said once, on stderr, before anything else prints: a live credential
        // in a file every user on the machine can read is worth knowing about.
        // Reported, not enforced — see `ConfigFile.permissionWarning`.
        if let warning = ConfigFile.permissionWarning(for: Self.accountPasswordName) {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }

        let session = try EchoLinkSession(
            destination: EchoLinkDestination(
                peer: peerAddress,
                node: node,
                route: .proxy(
                    host: proxy,
                    port: proxyPort,
                    password: EchoLinkProxyPassword(proxyPassword)
                )
            ),
            callsign: try ConfigFile.requireCallsign(commandLineValue: callsign)
                .uppercased(),
            passwordSource: passwordSource,
            operatorName: operatorName,
            accountPassword: accountPassword,
            directoryServer: directory,
            transmitTimeout: .seconds(transmitTimeout),
            nodeAnswerTimeout: .seconds(nodeAnswerTimeout),
            useAudioDevices: audio,
            duration: duration.map { .seconds($0) }
        )
        try await session.run()
    }

    /// The environment variable, and the config file name, for the account
    /// password.
    static let accountPasswordName = "ECHOLINK_PASSWORD"

    /// The account password, from the environment, the config file, or an
    /// unechoed prompt — in that order.
    ///
    /// Same precedence and same reasoning as the IAX2 path's secret handling
    /// (`docs/CLI.md` §4): there is no command-line option, because one would
    /// put a live credential into shell history.
    private static func readAccountPassword() throws -> (String, SecretPrompt.Source) {
        let resolved = try SecretPrompt.resolve(
            commandLineValue: nil,
            name: accountPasswordName,
            promptText: "EchoLink account password: ")

        guard !resolved.secret.isEmpty else {
            throw ValidationError(
                "No account password. Set $\(accountPasswordName), put one in "
                    + "~/.config/swift-hamvoip/\(accountPasswordName), run this on a "
                    + "terminal and type one, or pass --no-directory-login.")
        }
        return (resolved.secret, resolved.source)
    }
}

/// One `hamvoip-cli echolink` session.
private final class EchoLinkSession: @unchecked Sendable {

    private let destination: EchoLinkDestination
    private let callsign: String
    private let passwordSource: SecretPrompt.Source
    private let useAudioDevices: Bool
    private let duration: Duration?
    private let client: EchoLinkClient
    private let console: Console
    private let bridge = AudioFrameBridge()

    private var pipeline: AudioPipeline?
    private var rxMeter = LevelMeter()
    private var txMeter = LevelMeter()
    private var transmittedPackets = 0
    private var receivedTalkspurts = 0
    private var finished = false
    private var isQuitting = false

    init(
        destination: EchoLinkDestination,
        callsign: String,
        passwordSource: SecretPrompt.Source,
        operatorName: String,
        accountPassword: EchoLinkAccountPassword?,
        directoryServer: EchoLinkPeerAddress?,
        transmitTimeout: Duration,
        nodeAnswerTimeout: Duration,
        useAudioDevices: Bool,
        duration: Duration?
    ) throws {
        self.destination = destination
        self.callsign = callsign
        self.passwordSource = passwordSource
        self.useAudioDevices = useAudioDevices
        self.duration = duration
        self.client = EchoLinkClient(
            codec: try GSMVoiceCodec(),
            configuration: EchoLinkClient.Configuration(
                callsign: callsign,
                operatorName: operatorName,
                accountPassword: accountPassword,
                directoryServer: directoryServer,
                transmitTimeout: transmitTimeout,
                nodeAnswerTimeout: nodeAnswerTimeout
            ),
            clock: ContinuousClock()
        )
        self.console = Console(isInteractive: isatty(STDOUT_FILENO) == 1)
    }

    // MARK: Lifecycle

    func run() async throws {
        await printBanner()

        // Started BEFORE connect, not with the other loops after it.
        //
        // connect() emits an event per step — the directory login, the node
        // answering — and those are exactly what you need when it fails
        // part-way. Starting the pump with the other loops meant a failed
        // connect printed only its final error, so "proxy login worked, the
        // directory accepted us, the node never answered" was indistinguishable
        // from "nothing worked at all". That cost real time during the first
        // live attempt.
        let eventPump = Task { await self.runEventLoop() }

        await console.log(
            "Connecting to \(destination.node) at \(destination.peer) "
                + "via proxy as \(callsign)…")
        do {
            try await client.connect(to: destination)
        } catch {
            // The event pump has been running since before connect, so the
            // steps that DID succeed are already on screen above this line.
            // Give the last few events a moment to drain before the summary.
            try? await Task.sleep(for: .milliseconds(50))
            await console.log("FAILED: \(error)")
            eventPump.cancel()
            throw ExitCode.failure
        }
        await console.log("Connected to \(destination.node).")

        if useAudioDevices {
            await startAudioDevices()
        } else {
            await console.log("Audio devices not opened (--no-audio): PTT will send silence.")
        }

        var terminal: RawTerminal?
        if RawTerminal.isTerminal() {
            terminal = try? RawTerminal.enter()
            if terminal == nil {
                await console.log("Could not enter raw mode; keys are unavailable this session.")
            }
        } else {
            await console.log(
                "Standard input is not a terminal: no key handling. The session runs "
                    + "until the node drops the link or --duration elapses.")
        }
        defer { terminal?.leave() }

        await printKeyBindings()
        var keyReader: KeyReader?
        if terminal != nil { keyReader = KeyReader() }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await eventPump.value }
            group.addTask { await self.runReceiveLoop() }
            group.addTask { await self.runTransmitLoop() }
            group.addTask { await self.runAudioSignalLoop() }
            group.addTask { await self.runStatusTicker() }
            if let keyReader {
                group.addTask { await self.runKeyLoop(keyReader) }
            }
            if let duration {
                group.addTask {
                    try? await Task.sleep(for: duration)
                    await self.note("--duration elapsed")
                    await self.requestQuit()
                }
            }
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
        pipeline?.stop()
        bridge.finish()
        await client.disconnect()
    }

    private func requestQuit() async {
        isQuitting = true
        await teardown()
    }

    // MARK: Audio devices

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
            // Capture runs for the whole session, as on the IAX2 and M17 paths
            // and for the same reason: AVAudioEngine takes tens of milliseconds
            // to start, so starting it on the spacebar would clip the first
            // syllable of every over. `EchoLinkClient.send(pcm:)` drops frames
            // while unkeyed by design.
            try pipeline.startCapture { frame in bridge.submit(frame) }
            await console.log(
                "Microphone and speaker open. Capture runs continuously; audio is only "
                    + "transmitted while PTT is on.")
        } catch {
            self.pipeline = nil
            await console.log("Could not start capture: \(error). Receive-only for this session.")
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
                if try await client.send(pcm: frame) != nil {
                    transmittedPackets += 1
                    txMeter.push(frame)
                } else if case .transmitting = client.state {
                    // One of the three 20 ms frames held back waiting to fill
                    // an 80 ms packet: still audio, and the meter should show
                    // it rather than blinking.
                    txMeter.push(frame)
                } else {
                    txMeter.idle()
                }
            } catch {
                await note("transmit error: \(error)")
            }
        }
    }

    /// **SF-3**, same contract as the IAX2 and M17 sessions: `AudioPipeline`
    /// reports interruptions and route changes but does not act on them; acting
    /// belongs to whoever owns PTT.
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
            switch key {
            case 0x20:  // SPACE
                await toggleTransmit()
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03, 0x04:
                await note("quitting")
                await requestQuit()
                return
            case UInt8(ascii: "?"), UInt8(ascii: "h"):
                await printKeyBindings()
            default:
                break
            }
        }
    }

    // MARK: Transmit

    private func toggleTransmit() async {
        if case .transmitting = client.state {
            await client.stopTransmit()
        } else {
            do {
                try await client.startTransmit()
            } catch {
                await note("could not key up: \(error)")
            }
        }
    }

    // MARK: Reporting

    private func report(_ event: EchoLinkClientEvent) async {
        switch event {
        case .connecting:
            await console.log("Connecting…")
        case .directoryLoggedIn:
            await console.log("Directory login accepted.")
        case .nodeAnswered(let name):
            await console.log("Node answered: \(name)")
        case .connected(let node):
            await console.log("Connected to \(node).")
        case .talkspurtStarted:
            receivedTalkspurts += 1
            await console.log("RX started")
        case .stationInfo(let text):
            // The station-info channel is not decoded past its outer shape
            // anywhere in this repository, so it is shown raw rather than
            // parsed into fields we have not established exist.
            await console.log("INFO \(text.replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespacesAndNewlines))")
        case .transmitting:
            await console.log("PTT ON")
        case .receiving:
            await console.log("PTT off")
        case .transmitTimedOut(let timeout):
            await console.alert("TRANSMIT WATCHDOG (\(timeout)) — unkeyed automatically (SF-1)")
        case .disconnected(let reason):
            await console.log("Link down: \(reason)")
        }
    }

    private func note(_ text: String) async {
        await console.log(text)
    }

    private func statusLine() -> String {
        let keyed: String
        if case .transmitting = client.state { keyed = "TX" } else { keyed = "rx" }
        return "[\(keyed)] \(destination.node)  "
            + "tx \(txMeter.rendered())  rx \(rxMeter.rendered())  "
            + "sent \(transmittedPackets)  rx spurts \(receivedTalkspurts)"
    }

    private func printBanner() async {
        await console.log("hamvoip-cli echolink — EchoLink audio (EL-10, Milestone M3)")
        await console.log(
            "NOT YET VALIDATED ON AIR BY THIS SOFTWARE: this client has never connected "
                + "to an EchoLink proxy. The protocol came from captures, not a spec.")
        await console.log(
            "An EchoLink node is a shared channel and may be a radio transmitter. "
                + "Transmitting requires a licence.")
        // Where the credential came from, as the IAX2 path does: somebody who
        // can see it arrived from argv is somebody who can go and fix their
        // shell history.
        if case .none = passwordSource {} else {
            await console.log("Callsign \(callsign); account password from \(passwordSource).")
        }
    }

    private func printKeyBindings() async {
        await console.log("Keys:  SPACE toggle PTT   q quit   ? this list")
    }

    private func printSummary() async {
        await console.log("Packets transmitted: \(transmittedPackets)")
        await console.log("Inbound talkspurts heard: \(receivedTalkspurts)")
        if isQuitting { await console.log("Quit requested by operator.") }
    }
}
