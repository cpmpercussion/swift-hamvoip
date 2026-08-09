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

// MARK: - Playback format decision (pure, directly testable — AU-5)

/// The playback half of the pipeline: the wire→engine `PCMFormatConverter`
/// and the `AVAudioFormat` that the buffers handed to the player node are
/// declared in, constructed **together from one chosen sample rate** so the
/// two can never disagree.
///
/// ### Why this type exists
///
/// The original RC-7 implementation upsampled with a converter whose rate had
/// been rebuilt from the *input* device in `startCapture`, then wrapped the
/// resulting mono samples in a buffer whose format came from the *main mixer*
/// (`playerNode.outputFormat(forBus: 0)`). On any machine where the two
/// devices disagree — a 48 kHz microphone with a 44.1 kHz output, which is an
/// ordinary Mac configuration — 20 ms of speech was generated at one rate and
/// then played back at another: 8.8 % slow, roughly 1.5 semitones flat. Worse,
/// the mixer's format is stereo, so channel 1 was allocated and never written
/// and the right channel was silent. And because the converter was only ever
/// rebuilt by `startCapture`, whether any of this happened depended on
/// call order and on which devices the user happened to have — it works on the
/// developer's machine and fails on someone else's.
///
/// Input rate and output rate are independent facts about two independent
/// devices. This type makes that structural: only the output side can
/// influence playback, the buffer format is the converter's own format by
/// construction, and the rate decision is a pure function that unit tests pin
/// down for every (input rate, output rate) pair without any hardware.
struct PlaybackChain {
    /// Engine-side rate used when the output device's reported rate is not
    /// usable — a headless CI machine with no output device reports 0 Hz.
    /// 48 kHz per AU-1.
    static let fallbackSampleRate: Double = 48_000
    /// Bounds for believing a rate the output node reports. Anything outside
    /// this (0, negative, NaN, infinity, absurdly high) is a "we don't know"
    /// answer, not a rate.
    static let minimumSampleRate: Double = 8_000
    static let maximumSampleRate: Double = 384_000

    /// The format every playback buffer is declared in: **mono** Float32 at
    /// ``sampleRate``. Mono is deliberate — the wire is mono, so writing one
    /// channel and letting `AVAudioMixerNode` fan it out to however many
    /// channels the hardware has is the only way to avoid silent channels.
    let format: AVAudioFormat
    private let converter: PCMFormatConverter

    var sampleRate: Double { format.sampleRate }
    var wireSampleRate: Double { converter.wireSampleRate }

    /// Chooses the engine-side playback rate from whatever the output node
    /// reports, falling back to ``fallbackSampleRate`` for any rate that is
    /// not a plausible hardware rate.
    ///
    /// Pure, total, and hardware-free on purpose: this is the decision that
    /// Defect 1 got wrong, so it is the decision that gets a unit test.
    static func engineSampleRate(forOutputSampleRate rate: Double) -> Double {
        guard rate.isFinite, rate >= minimumSampleRate, rate <= maximumSampleRate else {
            return fallbackSampleRate
        }
        return rate
    }

    /// - Parameters:
    ///   - outputSampleRate: the rate reported by the engine's output node.
    ///     Sanitised through ``engineSampleRate(forOutputSampleRate:)``, so
    ///     any value at all is accepted.
    ///   - wireSampleRate: network/codec-side rate (8 kHz for every codec in
    ///     scope).
    /// - Returns: `nil` only if `AVAudioFormat`/`AVAudioConverter` reject the
    ///   chosen pair of formats.
    init?(outputSampleRate: Double, wireSampleRate: Double = 8_000) {
        let rate = Self.engineSampleRate(forOutputSampleRate: outputSampleRate)
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: 1,
                interleaved: false
            ),
            let converter = PCMFormatConverter(sourceSampleRate: rate, wireSampleRate: wireSampleRate)
        else { return nil }

        self.format = format
        self.converter = converter
    }

    /// Converts one frame of wire-side Int16 PCM up to the engine-side rate
    /// and wraps it in a buffer declared in exactly ``format`` — the same
    /// format the samples were just produced at, and the same format the
    /// player node is connected with.
    ///
    /// Returns `nil` for empty input or if the converter produced nothing.
    ///
    /// Not thread-safe: `AVAudioConverter` is stateful, so callers must
    /// serialise calls (``AudioPipeline`` does this under its lock, off the
    /// render thread).
    func makeBuffer(wirePCM: [Int16]) -> AVAudioPCMBuffer? {
        guard !wirePCM.isEmpty else { return nil }
        let samples = converter.upsample(wirePCM)
        guard !samples.isEmpty else { return nil }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let channel = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

// MARK: - Capture tap state

/// Mutable state owned **solely** by one installed microphone tap.
///
/// `AVAudioEngine` delivers tap buffers serially on a real-time audio thread.
/// A fresh instance is created per `startCapture` and captured by that call's
/// tap closure and by nothing else, so the chunker it holds is only ever
/// touched from that one thread — no lock is taken on the render thread, and
/// no other thread can observe or mutate it. `stop()` removes the tap; the
/// closure (and this box with it) is then released by `AVAudioEngine`.
private final class CaptureTapState {
    var chunker: AudioFrameChunker

    init(frameSize: Int) {
        self.chunker = AudioFrameChunker(frameSize: frameSize)
    }
}

// MARK: - AudioPipeline

/// Wraps `AVAudioEngine` + `AVAudioConverter` for the capture/playback path
/// (AU-1, AU-2).
///
/// Everything that can be unit-tested without a microphone, a speaker, or
/// audio hardware permission lives in ``AudioFrameChunker``,
/// ``PCMFormatConverter`` and ``PlaybackChain`` above — value types with no
/// dependency on a running `AVAudioEngine`. This class is the wiring that
/// connects them to real hardware. Keeping the *decisions* (what rate, how
/// many channels, how many frames) in those types and leaving only
/// `attach`/`connect`/`installTap`/`scheduleBuffer` here is what makes the
/// untestable part small: what remains for CLI-1 to check on real hardware is
/// whether audio flows at all, not whether the formats are right.
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
///
/// ### Concurrency
///
/// `@unchecked Sendable` here is backed by an actual design, not by hope:
///
/// * The microphone tap closure touches **only** values captured at
///   `installTap` time (an immutable `PCMFormatConverter` built for that one
///   capture session, and the caller's `onFrame`) plus a private
///   ``CaptureTapState`` box created for that one tap. It does not capture
///   `self`, does not read or write any property of this class, and never
///   takes a lock — taking a contended lock on a real-time audio thread would
///   be a bug in its own right.
/// * Everything on the caller's side — the engine graph, `isCapturing` — is
///   mutated only under ``lock``, which the render thread never touches.
/// * ``playback`` and ``signals`` are `let`s established in `init`.
///
/// Public methods (`startCapture`, `enqueuePlayback`, `stop`) may therefore be
/// called from any thread, but **must not** be called from an audio render
/// callback, since they take the lock and allocate.
public final class AudioPipeline: @unchecked Sendable {
    /// Fixed capture frame size: 160 samples = 20 ms at 8 kHz. Matches
    /// `G711MuLawCodec.samplesPerFrame` and `JitterBuffer`'s `frameDuration`
    /// default — every consumer downstream of `AudioPipeline` expects this.
    public static let captureFrameSize = 160

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// Wire→engine conversion and buffer format for the playback path,
    /// derived from the **output** device only (see ``PlaybackChain``).
    ///
    /// Immutable for the pipeline's lifetime: the player→mixer connection is
    /// made once, in `init`, with `playback.format`, and `AVAudioMixerNode`
    /// converts from there to whatever the hardware currently wants —
    /// including after a route change, which is why nothing here needs
    /// rebuilding when the route changes. Capture deliberately does *not*
    /// share this: the input device's rate is a fact about a different piece
    /// of hardware.
    private let playback: PlaybackChain

    /// Serialises caller-side state and engine-graph mutations.
    ///
    /// **Never acquired from the real-time audio thread.** The tap closure is
    /// built to need nothing this lock protects; see the type-level
    /// concurrency note.
    private let lock = NSLock()

    /// Guarded by ``lock``. Tracks whether a tap is installed, so `stop()` is
    /// idempotent and a second `startCapture` cannot install a second tap on
    /// a bus that already has one.
    private var isCapturing = false

    private let signalContinuation: AsyncStream<AudioSessionSignal>.Continuation

    /// Written only during `init` (by `observeSignals`) and read only during
    /// `deinit`. Neither point can overlap with another thread's access to
    /// this instance, so it needs no lock.
    private var notificationTokens: [NSObjectProtocol] = []

    /// SF-3 signal stream — see the type-level documentation. Finishes when
    /// this `AudioPipeline` is deallocated.
    public let signals: AsyncStream<AudioSessionSignal>

    public init() {
        var continuation: AsyncStream<AudioSessionSignal>.Continuation!
        self.signals = AsyncStream { continuation = $0 }
        self.signalContinuation = continuation

        // Ask the output node — not the input node, and not the main mixer's
        // channel layout — what rate playback should run at.
        let outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let playback = PlaybackChain(outputSampleRate: outputSampleRate) else {
            // Unreachable: PlaybackChain sanitises the rate to 48 kHz when the
            // hardware's answer is unusable, and AVAudioConverter does not
            // reject mono 48k/8k Float32↔Int16 on any platform this package
            // targets.
            preconditionFailure("AudioPipeline: playback formats must always construct a converter")
        }
        self.playback = playback

        engine.attach(playerNode)
        // Explicit mono format: the player node speaks exactly the format the
        // playback buffers are built in, and the mixer does the rate and
        // channel conversion to the hardware. Passing `nil` here would adopt
        // the mixer's (typically stereo) format and leave every channel but
        // the first unwritten.
        engine.connect(playerNode, to: engine.mainMixerNode, format: playback.format)

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
    ///
    /// The tap owns everything it needs: a converter built for this capture
    /// session's input rate and a private chunker. Nothing it touches is
    /// reachable from any other thread, so it takes no lock (see the
    /// type-level concurrency note), and `onFrame` cannot be swapped out from
    /// under a call in progress — `stop()` removes the tap, which is what ends
    /// delivery.
    public func startCapture(onFrame: @escaping ([Int16]) -> Void) throws {
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // A converter per capture session, owned by this session's tap alone.
        // Its rate comes from the input device and is never allowed to reach
        // the playback path (Defect 1) — and because it is never shared, the
        // stateful `AVAudioConverter` inside it is only ever driven from the
        // one thread that drives this tap (Defect 2).
        guard let captureConverter = PCMFormatConverter(sourceSampleRate: hardwareFormat.sampleRate) else {
            throw AudioPipelineError.converterUnavailable
        }
        let tapState = CaptureTapState(frameSize: Self.captureFrameSize)

        lock.lock()
        defer { lock.unlock() }

        // Installing a second tap on a bus that already has one is a hard
        // error in AVAudioEngine; make a repeated startCapture mean "restart".
        if isCapturing {
            inputNode.removeTap(onBus: 0)
            isCapturing = false
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
            let samples = Self.floatSamples(from: buffer)
            guard !samples.isEmpty else { return }
            let wirePCM = captureConverter.downsample(samples)
            for frame in tapState.chunker.push(wirePCM) {
                onFrame(frame)
            }
        }
        isCapturing = true

        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            inputNode.removeTap(onBus: 0)
            isCapturing = false
            throw error
        }
    }

    // MARK: - Playback

    /// Enqueues one frame of wire-side 8 kHz Int16 PCM for playback,
    /// converting it up to the playback chain's mono Float32 format and
    /// scheduling it on the player node.
    ///
    /// The buffer is built in ``PlaybackChain/format`` — the same format the
    /// samples were produced at and the same format the player node is
    /// connected with — so the mixer, not this method, is what adapts to the
    /// output device's rate and channel count.
    ///
    /// Call from an ordinary thread (typically the jitter buffer's drain
    /// task), **not** from an audio render callback: this takes a lock and
    /// allocates.
    public func enqueuePlayback(_ pcm: [Int16]) {
        guard !pcm.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        // Under the lock: `PlaybackChain` wraps a stateful AVAudioConverter,
        // so concurrent callers must not drive it at the same time.
        guard let buffer = playback.makeBuffer(wirePCM: pcm) else { return }

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
    /// than once, and safe to call before ever starting.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        if isCapturing {
            // Only touch the input node if we actually opened it: reaching for
            // `engine.inputNode` instantiates the input audio unit, which is
            // pointless (and on iOS, permission-adjacent) in a receive-only or
            // never-started session.
            engine.inputNode.removeTap(onBus: 0)
            isCapturing = false
        }
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

    // MARK: - Test hooks (AU-5)

    /// The format every playback buffer is built in.
    ///
    /// Internal, read-only, and free of hardware: exists so tests can assert
    /// that the graph the pipeline actually wires up agrees with the format
    /// decision ``PlaybackChain`` made, which is precisely where Defect 1
    /// lived.
    var playbackBufferFormat: AVAudioFormat { playback.format }

    /// The format the player node is actually connected to the mixer with.
    /// Must equal ``playbackBufferFormat`` — a buffer scheduled in a format
    /// other than its connection's is the bug this pair of hooks guards.
    var playbackConnectionFormat: AVAudioFormat { playerNode.outputFormat(forBus: 0) }

    // MARK: - Helpers

    /// Extracts channel 0 as a plain `[Float]` from a Float32 PCM buffer
    /// produced by an `AVAudioEngine` tap.
    private static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
