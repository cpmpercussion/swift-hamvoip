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
/// to make the mismatch unreachable rather than to try to handle it. Passing
/// `nil` for the format tells AVFAudio to use whatever the bus has *at the
/// moment of the install*, which cannot mismatch by construction.
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

    /// Installs a tap on bus 0 **with no format**, i.e. in whatever format the
    /// bus has at that instant. Cannot raise the format-mismatch `NSException`.
    func installTap(bufferSize: AVAudioFrameCount, body: @escaping (AVAudioPCMBuffer) -> Void)

    /// Removes the tap on bus 0. Safe to call when there is none.
    func removeTap()
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
            guard let chain = makeChain(host.currentInputFormat) else {
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
}
