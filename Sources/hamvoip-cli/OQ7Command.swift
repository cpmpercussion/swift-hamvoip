// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Dispatch
import Foundation
import M17Kit
import RadioCore

// MARK: - Command

/// `hamvoip-cli oq7` — settle OQ-7 by watching a live reflector, in the same
/// spirit as `oq5`: ask the network a question the document cannot answer,
/// rather than read somebody else's implementation.
///
/// Receive-only. It sends the reflector protocol's control packets, because a
/// reflector sends nothing to a client that has not linked and answered its
/// keepalives, and it never sends a stream packet. There is no transmit path in
/// `M17Kit` yet for it to use even if it wanted one — that is M17-4, which this
/// exists to unblock.
struct OQ7Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oq7",
        abstract: "Settle OQ-7 — whether an M17 IP stream frame is 56 bytes or 54 — against a live reflector.",
        discussion: """
            OQ-7 asks whether an M17 stream datagram is 56 bytes or 54. The M17 \
            specification's Table 27 gives LICH as 240 bits, which is the whole 30-byte \
            LSF including its own CRC, and 4+2+30+2+16+2 = 56. The figure quoted widely \
            elsewhere is 54, and the difference is exactly whether that LSF CRC is on the \
            wire. The document cannot settle it — both readings are consistent with the \
            text — and the clean-room policy forbids reading an implementation to find \
            out. So the question goes to a reflector, which answers it every time somebody \
            keys up.

            M17Kit implements 56. M17-4 must not build stream transmit on an unverified \
            frame size, which is why this runs first.

            WHAT IT DOES. Links a reflector module, answers its keepalives, and watches. \
            Every inbound datagram is measured before it reaches the parser — which \
            matters, because M17ReflectorClient correctly discards anything that is not \
            exactly 56 bytes, so a harness built on its event stream would report silence \
            if the answer were 54. Nothing is transmitted: no audio, no stream packets. \
            Your callsign does go out in CONN, so it will appear on the reflector's \
            dashboard as a connected station.

            WHAT IT NEEDS. Somebody talking. A silent module answers nothing. Pick a busy \
            module, or run during a net, and allow enough time for a transmission or two. \
            Twenty or thirty frames of one over is plenty — under two seconds of speech.

            READING THE RESULT
              SETTLED        one length, and FN counts up at that reading's offset
              LENGTH ONLY    one length, too little traffic to check FN; run longer
              CONTRADICTORY  length and sequencing disagree — do not settle OQ-7 on it
              INCONCLUSIVE   the link worked, nobody talked

            For a capture that can be cut into a fixture, run tcpdump alongside:

              sudo tcpdump -i any -w m17-oq7.pcap 'udp port 17000'
            """)

    @Option(name: .long, help: ArgumentHelp(
        "Hostname or IP address of the M17 reflector.", valueName: "host"))
    var reflector: String

    @Option(name: .long, help: ArgumentHelp(
        "UDP port the reflector listens on.", valueName: "port"))
    var port: Int = Int(M17Kit.defaultReflectorPort)

    @Option(name: .long, help: ArgumentHelp(
        "Reflector module to link, a single letter A-Z. Pick a busy one.", valueName: "letter"))
    var module: String

    @Option(name: .long, help: ArgumentHelp(
        "Your callsign, base-40 encoded into the CONN 'From' address.", valueName: "call"))
    var callsign: String

    @Option(name: .long, help: ArgumentHelp(
        "Module letter to append to your own address, the \"A1BCD D\" convention the "
            + "specification shows for the 'From' field. Try this if the reflector answers NACK.",
        valueName: "letter"))
    var sourceModule: String?

    @Option(name: .long, help: ArgumentHelp(
        "Seconds to listen for. 0 listens until Ctrl-C.", valueName: "seconds"))
    var duration: Int = 300

    @Option(name: .long, help: ArgumentHelp(
        "Stop early once this many stream datagrams have arrived. 0 waits out the duration.",
        valueName: "n"))
    var minFrames: Int = 0

    @Option(name: .long, help: ArgumentHelp(
        "Write the report here as well as to the terminal.", valueName: "path"))
    var report: String?

    func run() async throws {
        let module = try validatedModule(module, option: "--module")
        let sourceModule = try sourceModule.map { try validatedModule($0, option: "--source-module") }
        let callsign: String
        let port: UInt16
        do {
            callsign = try ArgumentValidation.requireCallsign(self.callsign)
            port = try ArgumentValidation.requirePort(self.port)
        } catch let error as CLIValidationError {
            throw ValidationError(error.description)
        }
        guard duration >= 0, duration <= 7200 else {
            throw ValidationError("--duration must be between 0 and 7200 seconds")
        }
        guard minFrames >= 0 else {
            throw ValidationError("--min-frames cannot be negative")
        }

        let console = Console(isInteractive: isatty(STDOUT_FILENO) == 1)
        let recorder = OQ7Recorder()

        await console.log("OQ-7 experiment — is the M17 IP stream frame 56 bytes or 54?")
        await console.log("  reflector   \(reflector):\(port) module \(module)")
        await console.log("  as          \(callsign)\(sourceModule.map { " \($0)" } ?? "")")
        await console.log("  listening   \(duration == 0 ? "until Ctrl-C" : "\(duration) s")"
            + (minFrames > 0 ? ", or until \(minFrames) stream frames arrive" : ""))
        await console.log("  transmits   nothing — control packets only")
        await console.log("")

        let transport: NWDatagramTransport
        do {
            transport = try NWDatagramTransport(host: reflector, port: port)
        } catch {
            throw ValidationError("could not open a socket to \(reflector):\(port) — \(error)")
        }

        let tapped = RecordingTransport(
            wrapping: transport,
            onInbound: { recorder.recordInbound($0) },
            onOutbound: { _ in recorder.recordOutbound() })

        let client = try M17ReflectorClient(
            callsign: callsign,
            sourceModule: sourceModule,
            transport: tapped,
            clock: ContinuousClock())

        let events = Task {
            for await event in await client.events {
                switch event {
                case .connecting:
                    await console.log("→ CONN sent, waiting for ACKN")
                case .linked:
                    await console.log("✓ linked — listening. Nothing will appear until somebody keys up.")
                case .stream(let packet):
                    // Only ever reached when the datagram was exactly 56 bytes,
                    // which is itself evidence. The tally is what counts either
                    // way; this is here so a human sees who is talking.
                    recorder.recordParsedStream()
                    if packet.sequenceNumber == 0 || packet.isLastFrame {
                        let who = packet.source.callsign ?? "unknown"
                        let edge = packet.isLastFrame ? "ends" : "starts"
                        await console.log("  over \(edge) — \(who), stream \(packet.streamID), "
                            + "\(packet.playability)")
                    }
                case .disconnected(let reason):
                    await console.log("✗ link down — \(reason)")
                }
            }
        }
        defer { events.cancel() }

        let interrupt = installInterruptHandler(recorder)
        defer { interrupt.cancel() }

        do {
            try await client.connect(module: module)
        } catch let error as M17ReflectorClientError {
            await client.shutdown()
            switch error {
            case .connectionRefused:
                await console.log("")
                await console.log("The reflector answered NACK. Two things worth trying: a module it "
                    + "actually offers, and --source-module \(module) so your own address carries a "
                    + "module letter the way the specification's example does.")
            case .connectTimedOut:
                await console.log("")
                await console.log("No answer at all. Check the host and that UDP \(port) is not "
                    + "being filtered on the way out.")
            default:
                break
            }
            throw error
        }

        await listen(console: console, recorder: recorder)

        await client.shutdown()
        events.cancel()
        await console.clearStatus()

        let text = recorder.tally.report()
        await console.log("")
        await console.log(text)

        if let report {
            let url = URL(fileURLWithPath: report)
            try text.appending("\n").write(to: url, atomically: true, encoding: .utf8)
            await console.log("")
            await console.log("Report written to \(url.path)")
        }
    }

    // MARK: Listening

    /// Waits out the run, redrawing a status line, and returns when the
    /// duration expires, `--min-frames` is met, or Ctrl-C arrives.
    private func listen(console: Console, recorder: OQ7Recorder) async {
        let started = ContinuousClock().now
        let deadline: ContinuousClock.Instant? =
            duration == 0 ? nil : started.advanced(by: .seconds(duration))

        while !Task.isCancelled {
            let tally = recorder.tally
            if recorder.isInterrupted {
                await console.log("")
                await console.log("Ctrl-C — stopping and reporting on what arrived so far.")
                return
            }
            if minFrames > 0, tally.streamDatagramCount >= minFrames { return }
            if let deadline, ContinuousClock().now >= deadline { return }

            let elapsed = Int(started.duration(to: ContinuousClock().now).components.seconds)
            await console.setStatus("  \(elapsed) s — \(tally.inboundDatagramCount) datagrams in, "
                + "\(tally.streamDatagramCount) stream, \(tally.streamIDs.count) overs")
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Ctrl-C should end the run with a verdict, not kill it before the report
    /// is printed. `DispatchSourceSignal` is used rather than `signal(2)`
    /// because the handler only sets a flag and a dispatch source can do that
    /// without any async-signal-safety worry.
    private func installInterruptHandler(_ recorder: OQ7Recorder) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { recorder.interrupt() }
        source.resume()
        return source
    }

    private func validatedModule(_ value: String, option: String) throws -> M17Module {
        guard value.count == 1, let letter = value.uppercased().first else {
            throw ValidationError("\(option) is one letter A-Z, not '\(value)'")
        }
        do {
            return try M17Module(letter)
        } catch {
            throw ValidationError("\(option) must be a letter A-Z, not '\(value)'")
        }
    }
}

// MARK: - Recorder

/// The mutable side of the experiment: an ``OQ7Tally`` reachable from the
/// transport tap, the event loop and the status line at once.
///
/// The tap's observer is a `@Sendable` closure called from the transport's pump
/// task, so the tally cannot simply be a `var` in `run()`.
final class OQ7Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Storage()

    private struct Storage {
        var tally = OQ7Tally()
        var outboundCount = 0
        var parsedStreamCount = 0
        var interrupted = false
    }

    /// A snapshot. Cheap enough to take once per status redraw.
    var tally: OQ7Tally {
        lock.lock()
        defer { lock.unlock() }
        return storage.tally
    }

    /// Datagrams the client put on the wire — CONN, PONG, DISC. Zero PONGs on a
    /// link that stayed up would mean the keepalive path never ran.
    var outboundCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.outboundCount
    }

    /// Stream datagrams that got as far as `M17StreamPacket.parse` succeeding —
    /// so, by definition, ones that were exactly `M17StreamPacket.byteCount`
    /// bytes.
    var parsedStreamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.parsedStreamCount
    }

    var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.interrupted
    }

    func recordInbound(_ datagram: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.tally.record(datagram)
    }

    func recordOutbound() {
        lock.lock()
        defer { lock.unlock() }
        storage.outboundCount += 1
    }

    func recordParsedStream() {
        lock.lock()
        defer { lock.unlock() }
        storage.parsedStreamCount += 1
    }

    func interrupt() {
        lock.lock()
        defer { lock.unlock() }
        storage.interrupted = true
    }
}
