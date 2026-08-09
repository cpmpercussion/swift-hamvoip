// SPDX-License-Identifier: Apache-2.0

import AVFoundation
#if os(iOS)
import AVFAudio
#endif

/// Errors surfaced by ``AudioPipeline``.
public enum AudioPipelineError: Error, Equatable, CustomStringConvertible, Sendable {
    /// `AVAudioConverter` could not be constructed for the requested formats.
    case converterUnavailable

    public var description: String {
        switch self {
        case .converterUnavailable:
            return "could not construct an AVAudioConverter for the requested PCM formats"
        }
    }
}

/// SF-3 signal: audio session interruption or route change.
///
/// `AudioPipeline` does not itself stop transmission — the caller (the call
/// layer / app layer) **must** observe ``AudioPipeline/signals`` and react to
/// every event by dropping any in-progress transmit (e.g. calling
/// `stopTransmit()` on the active `NetworkClient`). This type only surfaces
/// the event cleanly; enforcing SF-3 is a decision that belongs one layer up,
/// where PTT state actually lives.
public enum AudioSessionSignal: Sendable, Equatable {
    /// The session was interrupted (e.g. an incoming phone call). Transmit
    /// MUST be dropped immediately.
    case interruptionBegan
    /// The interruption ended. `shouldResume` mirrors
    /// `AVAudioSession.InterruptionOptions.shouldResume` on iOS (always
    /// `false` on macOS, where this case is only reachable via
    /// `interruptionBegan` never having fired). Resuming transmit is a policy
    /// decision for the caller, not this type.
    case interruptionEnded(shouldResume: Bool)
    /// The audio route changed (headset plugged/unplugged, output device
    /// changed, engine configuration changed on macOS). Treated the same as
    /// an interruption per SF-3: transmit MUST be dropped.
    case routeChanged
}

// MARK: - Frame chunker (pure, directly testable — AU-5)

/// Re-chunks an arbitrary-length stream of `Int16` samples into fixed-size
/// frames, carrying any remainder across calls.
///
/// The microphone tap hands `AudioPipeline` buffers of whatever size
/// `AVAudioEngine` feels like delivering (device- and buffer-duration
/// dependent, and *not* guaranteed to be a multiple of the codec frame size).
/// Every codec and the jitter buffer in this package are built around a fixed
/// 20 ms / 160-sample frame, so something has to sit between "arbitrary tap
/// buffer" and "exactly 160 samples" — this is that something, deliberately
/// isolated as a pure value type with no dependency on `AVFoundation` so it
/// can be exercised directly by unit tests without any audio hardware.
///
/// Invariant: for any sequence of calls to ``push(_:)``, concatenating every
/// emitted frame (in order) followed by ``pending`` reconstructs the exact
/// concatenation of every input pushed, in order. No sample is ever dropped
/// or duplicated.
struct AudioFrameChunker {
    /// Fixed output frame size, in samples.
    let frameSize: Int

    /// Samples carried over from previous `push` calls that do not yet fill
    /// a complete frame.
    private(set) var pending: [Int16] = []

    init(frameSize: Int) {
        precondition(frameSize > 0, "frameSize must be positive")
        self.frameSize = frameSize
    }

    /// Appends `samples` to the carried remainder and slices off as many
    /// complete `frameSize`-sample frames as are now available, in order.
    /// Leftover samples that do not fill a full frame remain in `pending`
    /// for the next call.
    mutating func push(_ samples: [Int16]) -> [[Int16]] {
        guard !samples.isEmpty else { return [] }
        pending.append(contentsOf: samples)

        guard pending.count >= frameSize else { return [] }

        var frames: [[Int16]] = []
        frames.reserveCapacity(pending.count / frameSize)
        var offset = 0
        while pending.count - offset >= frameSize {
            frames.append(Array(pending[offset..<(offset + frameSize)]))
            offset += frameSize
        }
        if offset > 0 {
            pending.removeFirst(offset)
        }
        return frames
    }
}

// MARK: - Sample-rate conversion glue (pure, directly testable — AU-5)

/// Wraps a pair of `AVAudioConverter`s for engine-side mono Float32 PCM
/// (`sourceSampleRate`, default 48 kHz per AU-1) ↔ wire-side mono Int16 PCM
/// (`wireSampleRate`, 8 kHz for every codec in scope).
///
/// This type touches only `AVAudioConverter` and `AVAudioPCMBuffer` — pure
/// offline format/rate conversion with no `AVAudioEngine`, no I/O, and no
/// hardware or permission dependency. That is deliberate: it is the piece of
/// AU-1 that unit tests *can* exercise directly in a headless environment.
/// The engine wiring that feeds real microphone/speaker buffers through this
/// converter is exercised later, on real hardware, by CLI-1.
struct PCMFormatConverter {
    private let sourceFormat: AVAudioFormat
    private let wireFormat: AVAudioFormat
    private let downConverter: AVAudioConverter
    private let upConverter: AVAudioConverter

    var sourceSampleRate: Double { sourceFormat.sampleRate }
    var wireSampleRate: Double { wireFormat.sampleRate }

    /// - Parameters:
    ///   - sourceSampleRate: sample rate of the mono Float32 PCM on the
    ///     engine side (default 48 kHz, AU-1).
    ///   - wireSampleRate: sample rate of the mono Int16 PCM on the
    ///     network/codec side (default 8 kHz — every codec in scope is
    ///     narrowband).
    /// - Returns: `nil` if `AVAudioConverter` cannot be constructed for the
    ///   requested formats (e.g. an unsupported sample rate).
    init?(sourceSampleRate: Double = 48_000, wireSampleRate: Double = 8_000) {
        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: 1,
                interleaved: false
            ),
            let wire = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: wireSampleRate,
                channels: 1,
                interleaved: false
            ),
            let down = AVAudioConverter(from: source, to: wire),
            let up = AVAudioConverter(from: wire, to: source)
        else { return nil }

        self.sourceFormat = source
        self.wireFormat = wire
        self.downConverter = down
        self.upConverter = up
    }

    /// Converts engine-side Float32 PCM at `sourceSampleRate` to wire-side
    /// Int16 PCM at `wireSampleRate`.
    func downsample(_ input: [Float]) -> [Int16] {
        Self.convert(
            input,
            converter: downConverter,
            inputFormat: sourceFormat,
            outputFormat: wireFormat,
            fill: { buffer, samples in
                guard let channel = buffer.floatChannelData else { return }
                samples.withUnsafeBufferPointer { src in
                    channel[0].update(from: src.baseAddress!, count: samples.count)
                }
            },
            drain: { buffer in
                guard let channel = buffer.int16ChannelData else { return [] }
                return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
            }
        )
    }

    /// Converts wire-side Int16 PCM at `wireSampleRate` to engine-side
    /// Float32 PCM at `sourceSampleRate` (e.g. for scheduling on a player
    /// node).
    func upsample(_ input: [Int16]) -> [Float] {
        Self.convert(
            input,
            converter: upConverter,
            inputFormat: wireFormat,
            outputFormat: sourceFormat,
            fill: { buffer, samples in
                guard let channel = buffer.int16ChannelData else { return }
                samples.withUnsafeBufferPointer { src in
                    channel[0].update(from: src.baseAddress!, count: samples.count)
                }
            },
            drain: { buffer in
                guard let channel = buffer.floatChannelData else { return [] }
                return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
            }
        )
    }

    /// Shared one-shot conversion plumbing: wraps `input` in a single
    /// `AVAudioPCMBuffer`, hands it to `converter` exactly once, and drains
    /// whatever the converter produced.
    private static func convert<Input>(
        _ input: [Input],
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        fill: (AVAudioPCMBuffer, [Input]) -> Void,
        drain: (AVAudioPCMBuffer) -> [Input.OutputElement]
    ) -> [Input.OutputElement] where Input: ConversionSample {
        guard !input.isEmpty else { return [] }
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(input.count)
        ) else { return [] }
        inputBuffer.frameLength = inputBuffer.frameCapacity
        fill(inputBuffer, input)

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        // Generous headroom over the naive ratio: resamplers carry a few
        // samples of internal filter latency, and rounding must never leave
        // the output buffer too small to hold everything the converter is
        // willing to produce in one shot.
        let capacity = AVAudioFrameCount((Double(input.count) * ratio).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error else { return [] }
        return drain(outputBuffer)
    }
}

/// Ties an input sample type to the output sample type `PCMFormatConverter`
/// produces from it, so `convert(_:...)` above can be written once for both
/// directions.
private protocol ConversionSample {
    associatedtype OutputElement
}
extension Float: ConversionSample { fileprivate typealias OutputElement = Int16 }
extension Int16: ConversionSample { fileprivate typealias OutputElement = Float }

// MARK: - AudioPipeline

/// Wraps `AVAudioEngine` + `AVAudioConverter` for the capture/playback path
/// (AU-1, AU-2).
///
/// Everything that can be unit-tested without a microphone, a speaker, or
/// audio hardware permission lives in ``AudioFrameChunker`` and
/// ``PCMFormatConverter`` above — pure value types with no dependency on a
/// running `AVAudioEngine`. This class is the wiring that connects them to
/// real hardware, and is deliberately *not* unit-tested here: RC-7's done
/// criterion is that this file builds for macOS and iOS, and that those two
/// pure pieces have direct tests. The engine wiring itself gets its first
/// real exercise from a human on real hardware via CLI-1.
///
/// ### SF-3 — interruption must drop transmit
///
/// `AudioPipeline` surfaces interruption and route-change events on
/// ``signals`` but does not act on them: it has no notion of "transmitting",
/// that state lives in the call layer above (`IAX2Client`/`M17Client` and,
/// later, the app's PTT view model). **The caller MUST consume `signals` and
/// stop any in-progress transmit on every event it yields.** Not doing so is
/// exactly the "stuck open microphone" failure mode DESIGN-REQUIREMENTS.md §7
/// calls out as the dominant on-air failure for software clients.
public final class AudioPipeline: @unchecked Sendable {
    /// Fixed capture frame size: 160 samples = 20 ms at 8 kHz. Matches
    /// `G711MuLawCodec.samplesPerFrame` and `JitterBuffer`'s `frameDuration`
    /// default — every consumer downstream of `AudioPipeline` expects this.
    public static let captureFrameSize = 160

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// Rebuilt by `startCapture` once the input node's actual native format
    /// is known; a default (48 kHz assumption) is installed at `init` so
    /// `enqueuePlayback` also works in a receive-only session that never
    /// calls `startCapture`.
    private var converter: PCMFormatConverter
    private var chunker = AudioFrameChunker(frameSize: AudioPipeline.captureFrameSize)
    private var onFrame: (([Int16]) -> Void)?

    private let signalContinuation: AsyncStream<AudioSessionSignal>.Continuation
    private var notificationTokens: [NSObjectProtocol] = []

    /// SF-3 signal stream — see the type-level documentation. Finishes when
    /// this `AudioPipeline` is deallocated.
    public let signals: AsyncStream<AudioSessionSignal>

    public init() {
        var continuation: AsyncStream<AudioSessionSignal>.Continuation!
        self.signals = AsyncStream { continuation = $0 }
        self.signalContinuation = continuation

        guard let converter = PCMFormatConverter() else {
            // Only reachable if AVAudioConverter rejects the fixed 48k/8k
            // formats this package always requests, which does not happen
            // on any Apple platform this package targets.
            preconditionFailure("AudioPipeline: default PCM formats must always construct a converter")
        }
        self.converter = converter

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)

        observeSignals()
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        signalContinuation.finish()
    }

    // MARK: - Capture

    /// Starts the microphone tap and begins delivering exactly
    /// ``captureFrameSize``-sample (160, 20 ms @ 8 kHz) `Int16` PCM frames to
    /// `onFrame`, re-chunking whatever buffer sizes the tap actually hands
    /// back (see ``AudioFrameChunker``).
    ///
    /// `onFrame` is called on whatever queue `AVAudioEngine` delivers tap
    /// buffers on (a real-time audio thread) — callers must hop off it before
    /// doing anything that can block or allocate unpredictably (network I/O,
    /// UI updates).
    public func startCapture(onFrame: @escaping ([Int16]) -> Void) throws {
        self.onFrame = onFrame
        chunker = AudioFrameChunker(frameSize: Self.captureFrameSize)

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        if hardwareFormat.sampleRate != converter.sourceSampleRate {
            guard let rebuilt = PCMFormatConverter(sourceSampleRate: hardwareFormat.sampleRate) else {
                throw AudioPipelineError.converterUnavailable
            }
            converter = rebuilt
        }
        let converter = self.converter

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = Self.floatSamples(from: buffer)
            guard !samples.isEmpty else { return }
            let wirePCM = converter.downsample(samples)
            let frames = self.chunker.push(wirePCM)
            for frame in frames {
                self.onFrame?(frame)
            }
        }

        if !engine.isRunning {
            try engine.start()
        }
    }

    // MARK: - Playback

    /// Enqueues one frame of wire-side 8 kHz Int16 PCM for playback,
    /// converting it up to the engine's Float32 working format and
    /// scheduling it on the player node.
    public func enqueuePlayback(_ pcm: [Int16]) {
        guard !pcm.isEmpty else { return }
        let floatSamples = converter.upsample(pcm)
        guard !floatSamples.isEmpty else { return }

        let outputFormat = playerNode.outputFormat(forBus: 0)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(floatSamples.count)
        ) else { return }
        buffer.frameLength = buffer.frameCapacity
        guard let channel = buffer.floatChannelData else { return }
        floatSamples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: floatSamples.count)
        }

        if !engine.isRunning {
            try? engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Stop

    /// Stops capture and playback and tears down the tap. Safe to call more
    /// than once.
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        onFrame = nil
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Interruption / route-change observation (SF-3)

    private func observeSignals() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        notificationTokens.append(interruptionToken)
        #endif

        // Cross-platform: fires on route/device changes on iOS and on
        // hardware reconfiguration (e.g. a device disappearing) on macOS.
        // Treated identically to a route change for SF-3 purposes.
        let configurationToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.signalContinuation.yield(.routeChanged)
        }
        notificationTokens.append(configurationToken)

        #if os(iOS)
        let routeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.signalContinuation.yield(.routeChanged)
        }
        notificationTokens.append(routeToken)
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            signalContinuation.yield(.interruptionBegan)
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            signalContinuation.yield(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    /// Configures the shared `AVAudioSession` per AU-2: `.playAndRecord`,
    /// mode `.voiceChat`. Call once, before ``startCapture(onFrame:)``.
    /// iOS-only — `AVAudioSession` does not exist on macOS, where the app
    /// (or CLI-1) is responsible for input/output device selection instead.
    public func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
    }
    #endif

    // MARK: - Helpers

    /// Extracts channel 0 as a plain `[Float]` from a Float32 PCM buffer
    /// produced by an `AVAudioEngine` tap.
    private static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
