// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import AVFoundation
import Foundation
import RadioCore

#if os(macOS)
import CoreAudio
#endif

// MARK: - Command

/// `hamvoip-cli experiment capture-swap` — pull the input device out from under
/// a running capture and see what `AudioPipeline` does about it (RC-14).
///
/// The measurement this exists for cannot be a unit test. Every other claim in
/// `AudioPipeline` is settled by driving the tap body through its pointer entry
/// point with no hardware (AU-5), but "the chain is rebuilt when the device
/// changes" is a claim about `AVAudioEngine`'s behaviour on a real machine:
/// what a configuration change actually reports, whether the tap survives it,
/// and whether frames keep arriving afterwards. So it is measured here, the
/// same way `oq5` and `oq7` measure things a document cannot answer.
///
/// Local, not on air: nothing is transmitted and no node is dialled. It opens
/// the microphone (macOS will ask, once — see `docs/CLI.md` §1) and changes the
/// system's default input device, which it puts back on the way out, including
/// on `SIGINT`.
struct CaptureSwapCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-swap",
        abstract: "Change the default input device under a live capture and watch the chain rebuild (RC-14).",
        discussion: """
            THE DEFECT THIS MEASURES. Before RC-14, `startCapture` snapshotted the input \
            device's format once — the converter's source rate and the tap's channel \
            stride came from it — and nothing rebuilt them. An \
            AVAudioEngineConfigurationChange, which is exactly what changing the default \
            input device produces, left a live tap resampling from a rate the device no \
            longer ran at and striding by a channel count the buffers no longer had. The \
            stride is the sharp end: a stride of 2 held over a de-interleaved mono buffer \
            reads past the end of channel 0, on the real-time audio thread.

            WHAT IT DOES. Opens capture on the current default input, then swaps the \
            default input device back and forth, printing the input node's format and the \
            pipeline's counters after each swap. Frame delivery is counted throughout: the \
            question is not only whether the chain is rebuilt but whether audio keeps \
            flowing across the rebuild, since a transmission is usually in progress when \
            this happens.

            WORTH RUNNING UNDER AddressSanitizer, which is how the stale-stride read would \
            be caught at the instant it happened rather than inferred from a crash \
            somewhere else later (BU-23):

              swift build -Xswiftc -sanitize=address
              ASAN_OPTIONS=detect_leaks=0 .build/debug/hamvoip-cli experiment capture-swap --swaps 8

            READING THE RESULT
              rebuilds    how many swaps changed the format in a way the chain cares \
            about — the input rate, or the channel stride. Zero is a legitimate result: \
            a swap between two de-interleaved devices at the engine's rate moves neither.
              failures    rebuilds where CoreAudio would not build a converter for the new \
            device. Each one ended capture; any non-zero value wants explaining.
              frames      must keep climbing across every swap. A flat stretch is capture \
            that stopped and did not come back.
              dropped     frames the ring lost. Should be zero; it counts across rebuilds \
            on purpose, so a swap cannot quietly reset it.

            NEEDS TWO INPUT DEVICES. `--list` prints the ones it can see.
            """)

    @Option(name: .long, help: "How many times to change the default input device.")
    var swaps: Int = 4

    @Option(name: .long, help: "Seconds of capture between swaps.")
    var seconds: Double = 1.5

    @Option(name: .long, help: "Substring of the device to swap to. Default: the first other input.")
    var target: String?

    @Flag(name: .long, help: "List the input devices and exit.")
    var list: Bool = false

    func run() async throws {
        #if os(macOS)
        try await CaptureSwapProbe(swaps: swaps, seconds: seconds, target: target, list: list).run()
        #else
        throw ValidationError(
            "capture-swap changes the system default input device, which only macOS exposes.")
        #endif
    }
}

#if os(macOS)

// MARK: - The probe

private struct CaptureSwapProbe {
    let swaps: Int
    let seconds: Double
    let target: String?
    let list: Bool

    func run() async throws {
        let inputs = CoreAudioDevices.inputs()
        guard !inputs.isEmpty else {
            throw ValidationError("no input devices — nothing to capture from.")
        }

        let original = CoreAudioDevices.defaultInput()
        print("Input devices:")
        for device in inputs {
            let marker = device.id == original ? "  <- default" : ""
            print("  \(device.id)  \(device.name)\(marker)")
        }
        if list { return }

        guard inputs.count >= 2 else {
            throw ValidationError("only one input device; this probe needs two to swap between.")
        }
        let other = try pickTarget(from: inputs, avoiding: original)
        print("")
        print("Swapping between \(inputs.first { $0.id == original }?.name ?? "?") and \(other.name).")

        // Put the operator's device back whatever happens, including on ^C:
        // leaving somebody's default input pointed at a webcam because a probe
        // exited early is a rude way to end an experiment.
        let restore = { CoreAudioDevices.setDefaultInput(original) }
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            restore()
            print("\nInterrupted; default input restored.")
            Foundation.exit(130)
        }
        signal(SIGINT, SIG_IGN)
        signalSource.resume()
        defer { restore() }

        let pipeline = AudioPipeline()
        let frames = FrameCounter()
        let began = Date()
        let signals = Task {
            for await signal in pipeline.signals {
                print(String(format: "  [%6.2fs] signal: %@", Date().timeIntervalSince(began),
                                    String(describing: signal)))
            }
        }
        defer { signals.cancel() }

        print("Input node format before: \(Self.inputNodeFormat())")
        try pipeline.startCapture { _ in frames.increment() }
        defer { pipeline.stop() }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        print(String(format: "  [%6.2fs] capture running, %d frames", Date().timeIntervalSince(began),
                            frames.value))

        var framesBeforeSwap = frames.value
        var stalled: [Int] = []
        for swap in 1...max(1, swaps) {
            let destination = swap.isMultiple(of: 2) ? original : other.id
            let status = CoreAudioDevices.setDefaultInput(destination)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

            let delivered = frames.value - framesBeforeSwap
            if delivered == 0 { stalled.append(swap) }
            framesBeforeSwap = frames.value
            let name: String = inputs.first { $0.id == destination }?.name ?? "?"
            let outcome: String = status == noErr ? "" : " (set failed, status \(status))"
            let counters: String = "rebuilds \(pipeline.captureChainRebuildCount), "
                + "failures \(pipeline.captureChainRebuildFailureCount), "
                + "dropped \(pipeline.droppedCaptureFrameCount)"
            print("swap \(swap) -> \(name)\(outcome): format \(Self.inputNodeFormat()), "
                  + "+\(delivered) frames, \(counters)")
        }

        print("")
        print("Frames delivered: \(frames.value)")
        print("Chain rebuilds:   \(pipeline.captureChainRebuildCount)")
        print("Rebuild failures: \(pipeline.captureChainRebuildFailureCount)")
        print("Frames dropped:   \(pipeline.droppedCaptureFrameCount)")
        print("")
        if !stalled.isEmpty {
            print("FAILED: capture delivered nothing across swap(s) \(stalled.map(String.init).joined(separator: ", ")).")
        } else if pipeline.captureChainRebuildFailureCount > 0 {
            print("FAILED: a rebuild could not construct a converter for the device swapped to.")
        } else if pipeline.captureChainRebuildCount > 0 {
            print("PASSED: the chain was rebuilt and audio kept flowing across every swap.")
        } else {
            print(
                "PASSED, nothing to rebuild: every swap left the input node's rate and channel "
                + "stride unchanged, so the snapshotted chain stayed correct. Capture never "
                + "stopped. This is the expected result on a Mac whose input devices are all "
                + "de-interleaved at the engine's rate — see docs/CLI.md §12.")
        }
    }

    private func pickTarget(from inputs: [CoreAudioDevices.Device], avoiding original: AudioDeviceID)
        throws -> CoreAudioDevices.Device
    {
        if let target {
            guard let match = inputs.first(where: { $0.name.localizedCaseInsensitiveContains(target) }) else {
                throw ValidationError("no input device whose name contains \"\(target)\".")
            }
            guard match.id != original else {
                throw ValidationError("\"\(match.name)\" is already the default input; pick another.")
            }
            return match
        }
        guard let other = inputs.first(where: { $0.id != original }) else {
            throw ValidationError("no second input device to swap to.")
        }
        return other
    }

    /// What `AudioPipeline` would see if it built a chain right now. Read from
    /// a separate engine so the probe does not have to reach inside the
    /// pipeline it is measuring.
    ///
    /// **The engine is held in a local for the duration of the call, and must
    /// be.** `AVAudioEngine().inputNode.outputFormat(forBus: 0)` — the same
    /// thing as one expression — segfaults in `AVAudioIONodeImpl::
    /// GetOutputFormat`, because the node does not keep its engine alive and
    /// the temporary is released before the format is read. It is a bad
    /// pointer dereference with garbage high bits, which macOS reports as a
    /// *possible pointer authentication failure*: the same crash shape as
    /// `BU-23`, from an ordinary use-after-free. Noted here because it cost
    /// half an hour on the way to writing this probe.
    private static func inputNodeFormat() -> String {
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        let description = "\(format.sampleRate) Hz, \(format.channelCount) ch, "
            + "interleaved=\(format.isInterleaved)"
        withExtendedLifetime(engine) {}
        return description
    }
}

/// Counted off the audio path: `onFrame` runs on the drain task, this is read
/// from the probe's own task.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

// MARK: - CoreAudio device access

/// The two CoreAudio properties this probe needs. `AVAudioEngine` has no API
/// for either: which devices exist, and which one is the default input.
private enum CoreAudioDevices {
    struct Device {
        let id: AudioDeviceID
        let name: String
    }

    static func inputs() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard hasInputChannels(id) else { return nil }
            return Device(id: id, name: name(of: id))
        }
    }

    static func defaultInput() -> AudioDeviceID {
        var address = property(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> OSStatus {
        var address = property(kAudioHardwarePropertyDefaultInputDevice)
        var value = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    private static func property(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = property(kAudioDevicePropertyStreamConfiguration,
                               scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String {
        var address = property(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return "device \(id)" }
        return value as String
    }
}

#endif
