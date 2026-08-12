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

            KNOWN GAP: this command does the PROXY login only. The DIRECTORY \
            server login — your own EchoLink account password, which the capture \
            shows a real client sending before it opens a node channel — is \
            implemented and tested (EL-6) but is not yet wired into the session, \
            so no account password is read or asked for. Whether a node channel \
            works without it has not been established. If M3 fails at the first \
            OPEN, this is the first thing to suspect.

            Two different secrets are involved and they are not interchangeable: \
            the PROXY password (--proxy-password, "PUBLIC" on a public proxy, and \
            not a secret) and your own EchoLink ACCOUNT password. Only the \
            account password is secret, and there is deliberately no option for \
            it — a password on the command line leaks into shell history.
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

    @Option(name: .long, help: "Your callsign.")
    var callsign: String

    @Flag(name: .long, inversion: .prefixedNo, help: "Open the microphone and speaker.")
    var audio: Bool = true

    @Option(name: .long, help: "Transmit watchdog timeout in seconds (SF-1).")
    var transmitTimeout: Int = 180

    @Option(name: .long, help: "End the session after this many seconds.")
    var duration: Int?

    func run() async throws {
        guard let peerAddress = EchoLinkPeerAddress(peer) else {
            throw ValidationError("--peer must be a dotted-quad IPv4 address, got '\(peer)'")
        }
        guard transmitTimeout > 0 else {
            throw ValidationError("--transmit-timeout must be positive")
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
            callsign: callsign.uppercased(),
            transmitTimeout: .seconds(transmitTimeout),
            useAudioDevices: audio,
            duration: duration.map { .seconds($0) }
        )
        try await session.run()
    }
}

/// One `hamvoip-cli echolink` session.
private final class EchoLinkSession: @unchecked Sendable {

    private let destination: EchoLinkDestination
    private let callsign: String
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
        transmitTimeout: Duration,
        useAudioDevices: Bool,
        duration: Duration?
    ) throws {
        self.destination = destination
        self.callsign = callsign
        self.useAudioDevices = useAudioDevices
        self.duration = duration
        self.client = EchoLinkClient(
            codec: try GSMVoiceCodec(),
            configuration: EchoLinkClient.Configuration(
                callsign: callsign,
                transmitTimeout: transmitTimeout
            ),
            clock: ContinuousClock()
        )
        self.console = Console(isInteractive: isatty(STDOUT_FILENO) == 1)
    }

    // MARK: Lifecycle

    func run() async throws {
        await printBanner()

        await console.log(
            "Connecting to \(destination.node) at \(destination.peer) "
                + "via proxy as \(callsign)…")
        do {
            try await client.connect(to: destination)
        } catch {
            await console.log("FAILED: \(error)")
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
            group.addTask { await self.runEventLoop() }
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
