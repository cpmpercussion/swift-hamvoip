// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

// MARK: - Tap host

/// The three things installing a capture tap needs from the input node, behind
/// a protocol so the install *sequence* can be tested without an
/// `AVAudioEngine`, a microphone, or a permission prompt (AU-5).
///
/// **`installTap` takes no format, and that is the point.** RC-15 was a crash,
/// on air, in Currawong: `AudioPipeline.installCaptureLocked` read
/// `inputNode.outputFormat(forBus: 0)`, built a chain from it, and passed that
/// snapshot back to `installTap(onBus:bufferSize:format:)`. The input device
/// changed inside that window — a Bluetooth headset arriving is enough — so the
/// node had moved on and the snapshot had not, and AVFAudio rejected the
/// install with
///
/// ```
/// 'Failed to create tap due to format mismatch, <AVAudioFormat 1 ch, 16000 Hz, Float32>'
/// ```
///
/// That rejection is an Objective-C `NSException`, **which no Swift `catch` can
/// intercept**: the app died from inside a `do/catch` written to tolerate
/// exactly this failure. A library that can terminate its host out of a
/// `do/catch` is a worse defect than the race that triggers it, so the fix is
/// to narrow the mismatch rather than to try to handle it. Passing `nil` for
/// the format tells AVFAudio to use whatever the *bus* has at the moment of the
/// install, which takes our stale snapshot out of the picture.
///
/// **RC-16: `nil` narrowed the window, it did not close it.** Given no format,
/// AVFAudio uses the input *node's* current format — not the hardware's, and
/// the two are allowed to disagree. A node still carrying a Bluetooth headset's
/// 16 kHz after the hardware had moved to the built-in microphone at 44.1 kHz
/// raised anyway, from one layer further in:
///
/// ```
/// [avae] AVAudioEngineGraph.mm:504 Error, formats don't match!
///        Input HW format: <1 ch, 44100 Hz>, tap format: <1 ch, 16000 Hz>
/// [avae] Failed to initialize active nodes in input chain! err = -10868
/// ```
///
/// A different message from RC-15's, which is the tell that this is a second
/// path to a raise rather than a regression of the first: the mismatch moved
/// from *between our snapshot and the device* to *inside `AVAudioEngine`*. So
/// the install is now preceded by a check that the node and the hardware agree
/// — see ``CaptureTapInstaller`` — and, because no guard can be proved complete
/// against an API that raises, ``AudioPipeline`` no longer holds its lock
/// across the call at all.
///
/// Dropping the format from the call moves the problem rather than solving it,
/// though — the chain would still be built from a snapshot, and a chain built
/// for the wrong format is RC-14's out-of-bounds read. So the format stops
/// being an input to the install and becomes something *checked after* it, by
/// ``CaptureTapInstaller/install(host:bufferSize:makeChain:attempts:)``.
protocol CaptureTapHost: AnyObject {
    /// What the input node reports right now. Two consecutive reads may
    /// legitimately differ — that is the whole subject of RC-15.
    var currentInputFormat: AVAudioFormat { get }

    /// What the input **hardware** reports right now, which is not necessarily
    /// what ``currentInputFormat`` says (RC-16). While these two disagree,
    /// installing a tap raises an `NSException` from inside the engine's graph
    /// initialisation, whatever format the install was given — including none.
    ///
    /// A sample rate of zero means "no opinion": an input node with no device
    /// behind it reports that, and it is not evidence of a disagreement.
    var hardwareInputFormat: AVAudioFormat { get }

    /// Installs a tap on bus 0 **with no format**, i.e. in whatever format the
    /// bus has at that instant.
    ///
    /// **Can raise an Objective-C `NSException`** — not over the format it was
    /// given, since it is given none, but over a node whose format disagrees
    /// with the hardware's (RC-16). Callers must hold no lock across this call.
    func installTap(bufferSize: AVAudioFrameCount, body: @escaping (AVAudioPCMBuffer) -> Void)

    /// Removes the tap on bus 0. Safe to call when there is none.
    func removeTap()

    /// Asks the input node to re-read the hardware, for the case where
    /// ``currentInputFormat`` and ``hardwareInputFormat`` disagree.
    ///
    /// The engine adopts a new input format when it is reconfigured, so this
    /// stops and resets it; the ordinary start paths bring it back up. Best
    /// effort — the caller looks again rather than assuming this worked.
    func reloadInputFormat()
}

/// The real host: `AVAudioEngine`'s input node.
///
/// Holds the engine, not the node. `AVAudioInputNode` does not keep its engine
/// alive, and a node outliving its engine is a use-after-free that reads as a
/// pointer-authentication failure — the crash shape `BU-23` wears, and one that
/// cost half an hour while writing `experiment capture-swap`.
///
/// Every member reaches for `engine.inputNode` on demand rather than caching
/// it, because touching that property instantiates the input audio unit, which
/// is pointless in a receive-only session and permission-adjacent on iOS.
final class EngineInputTapHost: CaptureTapHost {
    private let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    var currentInputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// The hardware's own format, which is `inputFormat(forBus: 0)` — the
    /// node's *input* side. `outputFormat` above is what a tap is handed, and
    /// RC-16 is the case where the engine had not yet carried a device change
    /// from the one to the other.
    var hardwareInputFormat: AVAudioFormat {
        engine.inputNode.inputFormat(forBus: 0)
    }

    func installTap(bufferSize: AVAudioFrameCount, body: @escaping (AVAudioPCMBuffer) -> Void) {
        // `format: nil` — see the protocol's documentation. This is the line
        // RC-15 is about.
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { buffer, _ in
            body(buffer)
        }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func reloadInputFormat() {
        // Deliberately does not restart the engine: whichever path needs it
        // next starts it — the end of a successful capture install, or the next
        // `enqueuePlayback` — and starting it here would only re-initialise the
        // graph we are asking to be re-read.
        engine.stop()
        engine.reset()
    }
}

// MARK: - Installer

/// Installs a capture tap and a chain that agree with each other, on hardware
/// that is allowed to move underneath both (RC-15).
///
/// ### Why this is a loop rather than a line
///
/// The format cannot be an *input* to the install any more (see
/// ``CaptureTapHost``), and it cannot be read before the install and trusted
/// either, because that is the stale-chain fault RC-14 was about. So it is
/// **read after**: install with no format, ask the node what format it now has,
/// and keep the chain only if the chain is right for that answer. A device that
/// changed inside the window fails that check, and the attempt is retried
/// against the format it changed to.
///
/// The retry converges as soon as the hardware sits still for the length of one
/// install, which is the ordinary case even when a device has just arrived —
/// devices change occasionally, not continuously. ``maxAttempts`` bounds it
/// anyway, because a bounded failure the caller can see beats an unbounded loop
/// on the connect path.
///
/// ### The check that happens *before* the install (RC-16)
///
/// Reading the format after the fact is not enough on its own, because the
/// install itself can raise: when the input node's format and the hardware's
/// disagree, `AVAudioEngine` fails to initialise the input chain and throws an
/// Objective-C `NSException` no `catch` here can see (see ``CaptureTapHost``).
/// So each attempt first asks whether those two agree, and when they do not it
/// spends the attempt asking the node to re-read the hardware
/// (``CaptureTapHost/reloadInputFormat()``) rather than installing into a state
/// already known to raise. A device that never settles exhausts the attempts
/// and fails as ``AudioPipelineError/inputFormatUnstable`` — the same
/// catchable error a device that keeps moving under the *after* check gets, and
/// for the same reason.
///
/// That guard is a narrowing, not a proof: `AVAudioEngine` may have other ways
/// to raise from this call, and nothing observable here would distinguish them.
/// What makes the raise survivable rather than fatal is ``AudioPipeline``
/// holding no lock across the install.
///
/// ### What is still true after this returns
///
/// The format can change again immediately, and nothing here can prevent that.
/// The guarantee is only that the tap was installed in a format the node
/// accepted and the chain was built for the same one. Keeping them in step from
/// then on is `.AVAudioEngineConfigurationChange`'s job (RC-14), and surviving
/// the gap before that notification arrives is ``CaptureTapProcessor``'s, which
/// bounds its reads by the buffer it is actually handed rather than by the
/// stride it was built with.
enum CaptureTapInstaller {
    /// Installs to try before giving up. Four is enough for any plausible run
    /// of device changes and small enough that a genuinely flapping device
    /// reports a failure rather than spinning the connect path.
    static let maxAttempts = 4

    /// - Parameter makeChain: builds a chain for a format, or returns `nil` if
    ///   CoreAudio will not convert that device's rate.
    /// - Returns: the installed chain. The tap is live and calls its processor.
    /// - Throws: ``AudioPipelineError/converterUnavailable`` if no chain can be
    ///   built for the format the node reports, or
    ///   ``AudioPipelineError/inputFormatUnstable`` if the format changed under
    ///   every attempt. **No tap is left installed on either path.**
    static func install(
        host: CaptureTapHost,
        bufferSize: AVAudioFrameCount,
        makeChain: (AVAudioFormat) -> CaptureChain?,
        attempts: Int = maxAttempts
    ) throws -> CaptureChain {
        for _ in 0..<max(1, attempts) {
            // The format the tap would be installed in, and the one read the
            // chain is built from.
            let nodeFormat = host.currentInputFormat

            // RC-16, before anything is installed: a node that disagrees with
            // the hardware raises out of `installTap`, so spend the attempt
            // asking it to re-read rather than making the call.
            guard Self.agrees(node: nodeFormat, hardware: host.hardwareInputFormat) else {
                host.reloadInputFormat()
                continue
            }

            guard let chain = makeChain(nodeFormat) else {
                throw AudioPipelineError.converterUnavailable
            }

            let processor = chain.processor
            host.installTap(bufferSize: bufferSize) { buffer in
                processor.process(buffer)
            }

            // The format the tap was actually given. Equal to the one read
            // above unless the device moved in between, which is the fault this
            // type exists for.
            if chain.matches(host.currentInputFormat) { return chain }

            // The chain is wrong for the format now arriving. Take the tap down
            // before building another: a tap reading through a format
            // description already known to be wrong is what RC-14 called the
            // sharp end, and silence is the recoverable failure.
            host.removeTap()
        }
        throw AudioPipelineError.inputFormatUnstable
    }

    /// Whether the input node's format and the hardware's are close enough that
    /// installing a tap will not fail graph initialisation (RC-16).
    ///
    /// Rate and channel count only. Those are what the engine's own message
    /// names (`Input HW format: <1 ch, 44100 Hz>, tap format: <1 ch, 16000 Hz>`)
    /// and they are what a device change moves; interleaving is a property of
    /// the buffers the tap is handed, which is the *chain's* problem and is
    /// checked after the install, not before it.
    ///
    /// A hardware rate of zero is no opinion rather than a disagreement — an
    /// input node with no device behind it reports that, and the chain check
    /// below refuses it as ``AudioPipelineError/converterUnavailable``, which
    /// says far more about what is wrong than "unstable" would.
    static func agrees(node: AVAudioFormat, hardware: AVAudioFormat) -> Bool {
        guard hardware.sampleRate > 0 else { return true }
        return node.sampleRate == hardware.sampleRate
            && node.channelCount == hardware.channelCount
    }
}
