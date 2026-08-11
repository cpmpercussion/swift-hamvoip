// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import M17Kit
import RadioCore

/// `hamvoip-cli m17` — link an M17 reflector module and pass audio (M17-5).
///
/// The live-validation harness for M17, and the counterpart to `connect` for
/// IAX2. Everything below the CLI is `M17Client`; this file is a terminal
/// around it.
///
/// **This has never been run against a real reflector with audio.** M17 RX was
/// confirmed on air on 2026-08-11 (the OQ-7 run, receive-only, no codec), and
/// TX has never been sent to a reflector at all. That is what this command
/// exists to settle, and it is deliberately the first thing its banner says.
struct M17Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "m17",
        abstract: "Link an M17 reflector module and pass audio (M17-5).",
        discussion: """
            Links a reflector module, plays what the module sends, and transmits \
            while PTT is on. Codec2 3200 (FR-2.4), 40 ms per datagram.

            Transmitting on amateur frequencies requires a licence, and a reflector \
            module is a shared channel — everything transmitted is heard by everyone \
            linked to it. Nothing is sent until PTT is pressed.

            NOT YET VALIDATED ON AIR. M17 receive was confirmed against a live \
            reflector on 2026-08-11 (hamvoip-cli oq7, receive-only). Transmit has \
            never been sent to a real reflector, and the audio path has never been \
            listened to. Expect to be the first.

            Requires Codec2.xcframework:

                scripts/build-codec2-xcframework.sh

            Without it this command is built out entirely and will report so.
            """)

    @Option(name: .long, help: "Reflector host name or address.")
    var host: String

    @Option(name: .long, help: "Reflector UDP port.")
    var port: UInt16 = M17Destination.defaultPort

    @Option(name: .long, help: "Module to link, a single letter A-Z.")
    var module: String

    @Option(name: .long, help: "Your callsign — travels in every packet's SRC field.")
    var callsign: String

    @Flag(name: .long, inversion: .prefixedNo, help: "Open the microphone and speaker.")
    var audio: Bool = true

    @Option(name: .long, help: "Transmit watchdog timeout in seconds (SF-1).")
    var transmitTimeout: Int = 180

    @Option(name: .long, help: "End the session after this many seconds.")
    var duration: Int?

    func run() async throws {
        #if !CODEC2
        throw ValidationError(
            """
            This build has no Codec2, so M17 audio is not available.

            Build the framework and rebuild:

                scripts/build-codec2-xcframework.sh
                swift package reset      # SwiftPM caches the manifest
                swift build

            See docs/reference/CODEC2-XCFRAMEWORK.md.
            """)
        #else
        guard let moduleLetter = module.first, module.count == 1,
            moduleLetter.isLetter, moduleLetter.isUppercase, moduleLetter.isASCII
        else {
            throw ValidationError("--module must be a single letter A-Z, got '\(module)'")
        }
        guard transmitTimeout > 0 else {
            throw ValidationError("--transmit-timeout must be positive")
        }

        let session = try M17Session(
            destination: M17Destination(
                host: host, port: port, module: moduleLetter,
                callsign: callsign.uppercased()),
            transmitTimeout: .seconds(transmitTimeout),
            useAudioDevices: audio,
            duration: duration.map { .seconds($0) })
        try await session.run()
        #endif
    }
}

#if CODEC2

/// One `hamvoip-cli m17` session.
private final class M17Session: @unchecked Sendable {

    private let destination: M17Destination
    private let useAudioDevices: Bool
    private let duration: Duration?
    private let client: M17Client
    private let console: Console
    private let bridge = AudioFrameBridge()

    private var pipeline: AudioPipeline?
    private var rxMeter = LevelMeter()
    private var txMeter = LevelMeter()
    private var transmittedDatagrams = 0
    private var receivedStreams = 0
    private var finished = false
    private var isQuitting = false

    init(
        destination: M17Destination,
        transmitTimeout: Duration,
        useAudioDevices: Bool,
        duration: Duration?
    ) throws {
        self.destination = destination
        self.useAudioDevices = useAudioDevices
        self.duration = duration
        self.client = M17Client(
            codec: try Codec2VoiceCodec(),
            configuration: M17Client.Configuration(transmitTimeout: transmitTimeout),
            clock: ContinuousClock())
        self.console = Console(isInteractive: isatty(STDOUT_FILENO) == 1)
    }

    // MARK: Lifecycle

    func run() async throws {
        await printBanner()

        await console.log(
            "Linking \(destination.host):\(destination.port) module \(destination.module) "
                + "as \(destination.callsign)…")
        do {
            try await client.connect(to: destination)
        } catch {
            await console.log("FAILED: \(error)")
            throw ExitCode.failure
        }
        await console.log("Linked to module \(destination.module).")

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
                    + "until the reflector drops the link or --duration elapses.")
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
            // Capture runs for the whole session, exactly as the IAX2 path
            // does and for the same reason: AVAudioEngine takes tens of
            // milliseconds to start, so starting it on the spacebar would clip
            // the first syllable of every over. `M17Client.send(pcm:)` drops
            // frames while unkeyed by design.
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
                    transmittedDatagrams += 1
                    txMeter.push(frame)
                } else if case .transmitting = client.state {
                    // The held-back half of a 40 ms datagram: still audio, and
                    // the meter should show it rather than blinking at 25 Hz.
                    txMeter.push(frame)
                } else {
                    txMeter.idle()
                }
            } catch {
                await note("transmit error: \(error)")
            }
        }
    }

    /// **SF-3**, same contract as the IAX2 session: `AudioPipeline` reports
    /// interruptions and route changes but does not act on them; acting
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

    private func report(_ event: M17ClientEvent) async {
        switch event {
        case .connecting:
            await console.log("Connecting…")
        case .linked(let module):
            await console.log("Linked to module \(module).")
        case .streamStarted(let source, let streamID):
            receivedStreams += 1
            await console.log(
                String(format: "RX %@ (stream 0x%04X)", source.callsign ?? "?", streamID))
        case .streamEnded(let source):
            await console.log("RX \(source.callsign ?? "?") ended")
        case .streamRejected(let rejection):
            await note("refused: \(rejection)")
        case .transmitting:
            await console.log("PTT ON")
        case .receiving:
            await console.log("PTT off")
        case .transmitWatchdogExpired(let timeout):
            await console.alert("TRANSMIT WATCHDOG (\(timeout)) — unkeyed automatically (SF-1)")
        case .disconnected(let reason):
            await console.log("Link down: \(reason.map(String.init(describing:)) ?? "unknown")")
        }
    }

    private func note(_ text: String) async {
        await console.log(text)
    }

    private func statusLine() -> String {
        let keyed: String
        if case .transmitting = client.state { keyed = "TX" } else { keyed = "rx" }
        return "[\(keyed)] mod \(destination.module)  "
            + "tx \(txMeter.rendered())  rx \(rxMeter.rendered())  "
            + "sent \(transmittedDatagrams)  streams \(receivedStreams)"
    }

    private func printBanner() async {
        await console.log("hamvoip-cli m17 — M17 reflector audio (M17-5)")
        await console.log(
            "NOT YET VALIDATED ON AIR: M17 transmit has never been sent to a real "
                + "reflector, and this audio path has never been listened to.")
        await console.log(
            "A reflector module is a shared channel. Transmitting requires a licence.")
    }

    private func printKeyBindings() async {
        await console.log("Keys:  SPACE toggle PTT   q quit   ? this list")
    }

    private func printSummary() async {
        await console.log("Datagrams transmitted: \(transmittedDatagrams)")
        await console.log("Inbound streams heard: \(receivedStreams)")
        if isQuitting { await console.log("Quit requested by operator.") }
    }
}

#endif
