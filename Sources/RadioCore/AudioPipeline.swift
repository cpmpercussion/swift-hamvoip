// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AudioToolbox
#if os(iOS)
import AVFAudio
#endif

/// Errors surfaced by ``AudioPipeline``.
public enum AudioPipelineError: Error, Equatable, CustomStringConvertible, Sendable {
    /// `AVAudioConverter` could not be constructed for the requested formats.
    case converterUnavailable

    /// The input device's format changed under every attempt to install a
    /// capture tap in it, so no tap could be installed in a format that was
    /// still current when the install finished (RC-15).
    ///
    /// **A recoverable, reportable failure, which is the whole point of it.**
    /// Before RC-15 this condition was not an error at all: AVFAudio raised an
    /// Objective-C `NSException` no Swift `catch` could see, and the host
    /// process was terminated. A caller may now treat it as it would any other
    /// failure to open the microphone — Currawong's connect-path warm-up logs
    /// it and carries on. Retrying is reasonable: it means the hardware was
    /// moving, not that it is unusable.
    case inputFormatUnstable

    public var description: String {
        switch self {
        case .converterUnavailable:
            return "could not construct an AVAudioConverter for the requested PCM formats"
        case .inputFormatUnstable:
            return "the input device's format kept changing while the capture tap was installed"
        }
    }
}

/// The audio-session policy a half-duplex radio needs (AU-2), in the one place
/// it is written down.
///
/// **Raw values rather than `AVAudioSession.Category` and friends**, for two
/// reasons that are both about this being the only copy:
///
/// 1. Those types exist only on iOS, so a typed constant could not be pinned by
///    a test — and this package's tests run on macOS. The policy governs
///    whether the microphone works at all, so it is worth a test that actually
///    runs.
/// 2. It sidesteps the `allowBluetooth` → `allowBluetoothHFP` rename in the
///    iOS 26 SDK. Both spellings are the same option with the same raw value
///    (`0x4`); only one of them compiles against any given SDK, so a typed
///    constant needs a `#if compiler` shim and a raw one does not.
///
/// `AudioPipeline.activateSession()` — iOS-only, so it is not a symbol link
/// here — is what applies it.
public struct AudioSessionPolicy: Equatable, Sendable {
    /// Raw value of `AVAudioSession.Category`.
    public let category: String
    /// Raw value of `AVAudioSession.Mode`.
    public let mode: String
    /// Raw value of `AVAudioSession.CategoryOptions`.
    public let options: UInt

    public init(category: String, mode: String, options: UInt) {
        self.category = category
        self.mode = mode
        self.options = options
    }

    /// `.playAndRecord`, mode `.voiceChat`, `[.allowBluetooth, .defaultToSpeaker]`.
    ///
    /// `.playAndRecord` because transmit and receive share the session;
    /// `.voiceChat` for the echo cancellation and the half-duplex-friendly
    /// routing; `allowBluetooth` for the hands-free profile, which is the
    /// Bluetooth profile that carries a *microphone* (A2DP is output only, and
    /// PTT needs the input half); `defaultToSpeaker` so a phone held in the
    /// hand is audible rather than routed to the earpiece.
    public static let radio = AudioSessionPolicy(
        category: "AVAudioSessionCategoryPlayAndRecord",
        mode: "AVAudioSessionModeVoiceChat",
        options: allowBluetooth | defaultToSpeaker)

    /// **The policy for when nothing is being transmitted (RC-12).**
    ///
    /// `.playback`, mode `.default`, no options — which on a Bluetooth accessory
    /// means **A2DP**, and that is the entire point.
    ///
    /// ## Why a second policy exists
    ///
    /// HFP is the only Bluetooth profile that carries a microphone, so
    /// ``radio`` must ask for it. But an *active* session holding HFP keeps the
    /// SCO link up for the whole call, not only while a tap is installed, and
    /// that has three measured costs on the app side (its `BU-17`):
    ///
    /// 1. Received audio is 16 kHz mono for the entire QSO rather than 44.1 kHz
    ///    stereo — audible, and reported by an operator before it was diagnosed.
    /// 2. A speaker-mic's "in a call" indicator is lit permanently, so it cannot
    ///    serve as a transmit indicator.
    /// 3. Accessory battery, for a voice channel carrying silence.
    ///
    /// macOS does none of this: CoreAudio raises HFP when a client opens the
    /// input and drops it about two seconds after the last one closes, so
    /// listening happens on A2DP and only transmitting is narrowband. **That is
    /// the behaviour this policy exists to reproduce on iOS**, and it is the
    /// right one for a simplex radio, where nobody listens and talks at once.
    ///
    /// ## The hazard a caller must respect
    ///
    /// `AVAudioEngine` never revisits its input format, so an engine whose input
    /// unit is instantiated under a non-recording category reports 0 Hz for the
    /// life of the process — the app's `BU-1`, and the reason
    /// ``activateSession()`` exists at all. A caller that switches to this policy
    /// **must** be able to discard and rebuild its engine when it switches back,
    /// or the first transmit after any receive will fail with a converter error
    /// and every one after it too.
    public static let listening = AudioSessionPolicy(
        category: "AVAudioSessionCategoryPlayback",
        mode: "AVAudioSessionModeDefault",
        options: 0)

    /// `AVAudioSession.CategoryOptions.allowBluetooth`, a.k.a.
    /// `.allowBluetoothHFP` under the iOS 26 SDK — same option, same value.
    public static let allowBluetooth: UInt = 0x4
    /// `AVAudioSession.CategoryOptions.defaultToSpeaker`.
    public static let defaultToSpeaker: UInt = 0x8
    /// `AVAudioSession.CategoryOptions.allowBluetoothA2DP`.
    ///
    /// Not used by either policy above — `.playback` routes to A2DP without it,
    /// and adding it to a `.playAndRecord` policy does *not* stop HFP being
    /// selected when an input is required. Named here because that is a natural
    /// wrong turn and worth closing off: the fix for holding HFP open is a
    /// category that needs no input, not an extra option on one that does.
    public static let allowBluetoothA2DP: UInt = 0x20
}

/// **Why the audio route changed (RC-13).**
///
/// `SF-3` says transmission must be dropped when the route changes, and that is
/// right for every cause here but one. A **category change the app asked for**
/// is not the world moving under a live transmission; it *is* the transmission
/// starting. Without this distinction a caller that switches category on the
/// transmit path drops the very over it is enabling and then, if it resumes,
/// does it again — measured in Currawong on 2026-08-22, where it made
/// transmitting unusable and had to be reverted.
///
/// So the cause travels with the signal, and the caller decides. **The library
/// still does not decide**: `AudioPipeline` drops nothing, and which causes
/// warrant an unkey is a judgement that belongs where PTT state lives. What
/// changed is that the judgement is now *possible*.
///
/// Raw values rather than `AVAudioSession.RouteChangeReason`, for the same
/// reason ``AudioSessionPolicy`` uses raw strings: that type is iOS-only, and a
/// mapping that cannot be tested on the platform this package's tests run on is
/// a mapping nobody checks.
public enum AudioRouteChangeCause: Equatable, Sendable {

    /// **The category, mode or options changed** — usually because the app asked.
    /// The one cause that does not, on its own, mean a live transmission is in
    /// danger. `AVAudioSession.RouteChangeReason.categoryChange`.
    case categoryChange

    /// Something was plugged in or connected.
    case newDeviceAvailable

    /// **Something was unplugged or went away.** The case `SF-3` exists for: a
    /// microphone that has left while the operator is still talking.
    case oldDeviceUnavailable

    /// The route was overridden, e.g. by `overrideOutputAudioPort`.
    case override

    /// The device woke, and the route was re-evaluated.
    case wakeFromSleep

    /// No route can serve the current category. Transmission cannot continue.
    case noSuitableRouteForCategory

    /// The selected route's own configuration changed — sample rate, channel
    /// count — without the route itself changing.
    case routeConfigurationChange

    /// **The engine's configuration changed**, rather than the session's route.
    /// The only cause on macOS, where there is no `AVAudioSession`, and also
    /// raised on iOS when the graph is rebuilt underneath a running engine.
    case engineConfigurationChange

    /// A reason this version does not recognise, carried through rather than
    /// discarded so a caller can log it. Treated as dangerous by anyone
    /// implementing `SF-3`: an unknown cause is not a safe cause.
    case unknown(reason: UInt)

    /// Map a raw `AVAudioSession.RouteChangeReason` value.
    ///
    /// The numbers are Apple's and are pinned by tests here, including a
    /// round-trip against the symbols themselves on iOS.
    public init(rawReason: UInt) {
        switch rawReason {
        case 1: self = .newDeviceAvailable
        case 2: self = .oldDeviceUnavailable
        case 3: self = .categoryChange
        case 4: self = .override
        case 6: self = .wakeFromSleep
        case 7: self = .noSuitableRouteForCategory
        case 8: self = .routeConfigurationChange
        default: self = .unknown(reason: rawReason)
        }
    }

    /// Whether this cause means the *session's route* moved, as opposed to the
    /// app changing its own mind about what it wants.
    ///
    /// Offered as a description, not a decision: a caller implementing `SF-3`
    /// will likely drop transmit for everything except ``categoryChange``, but
    /// that choice stays with the caller. ``unknown(reason:)`` counts as a real
    /// move, because an unrecognised cause must not be the quiet one.
    public var isExternalRouteMove: Bool {
        switch self {
        case .categoryChange: return false
        default: return true
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
    /// The audio route changed. **Carries why** (RC-13): `SF-3` wants transmit
    /// dropped for a route that moved, but a `categoryChange` the app asked for
    /// is the transmission *starting*, not the route being pulled away. See
    /// ``AudioRouteChangeCause``.
    case routeChanged(AudioRouteChangeCause)
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
///
/// ### Status after RC-9 — reference implementation, not the hot path
///
/// This type allocates: `pending.append(contentsOf:)` grows a heap array and
/// `pending.removeFirst(_:)` shuffles it. That is fine for a value type driven
/// from an ordinary thread and fatal on a real-time audio thread, so the
/// microphone tap no longer uses it — ``RealTimeFrameAssembler`` does the same
/// job inside preallocated storage.
///
/// It is kept because it is the *specification* of the chunking invariant, in
/// the clearest form anyone will read it, and because
/// `RealTimeFrameAssemblerTests` runs both implementations over the same
/// randomised input and requires byte-identical output. The simple, already
/// well-tested version is the oracle the pointer-arithmetic version is checked
/// against.
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

// MARK: - Real-time-safe capture conversion (RC-9)

/// The scratch state the `AudioConverter` input callback reads. Lives in one
/// heap allocation made at `startCapture` time and is only ever touched by the
/// tap thread.
private struct CaptureInputFeed {
    /// Preallocated mono Float32 input storage, owned by
    /// ``RealTimeDownConverter``.
    var samples: UnsafeMutablePointer<Float>
    /// How many frames of `samples` are valid for the current conversion.
    var frameCount: UInt32
    /// Set once the converter has been handed this chunk, so a second request
    /// within the same `AudioConverterFillComplexBuffer` call reports "dry"
    /// instead of replaying the same audio.
    var consumed: Bool
}

/// `AudioConverter` input callback. A bare C function pointer with no captured
/// context: everything it needs arrives through `userData`.
///
/// This is the whole reason the capture path uses `AudioConverterRef` rather
/// than `AVAudioConverter` — see ``RealTimeDownConverter``.
private let captureInputProc: AudioConverterComplexInputDataProc = {
    _, packetCount, bufferList, packetDescriptions, userData in

    // PCM is not packet-described.
    if let packetDescriptions { packetDescriptions.pointee = nil }
    bufferList.pointee.mNumberBuffers = 1
    bufferList.pointee.mBuffers.mNumberChannels = 1

    guard let userData else {
        packetCount.pointee = 0
        bufferList.pointee.mBuffers.mData = nil
        bufferList.pointee.mBuffers.mDataByteSize = 0
        return noErr
    }
    let feed = userData.assumingMemoryBound(to: CaptureInputFeed.self)

    // Reporting zero packets with `noErr` is how this API says "input ran dry";
    // the converter then returns whatever it has already produced.
    if feed.pointee.consumed || feed.pointee.frameCount == 0 {
        packetCount.pointee = 0
        bufferList.pointee.mBuffers.mData = nil
        bufferList.pointee.mBuffers.mDataByteSize = 0
        return noErr
    }

    feed.pointee.consumed = true
    packetCount.pointee = feed.pointee.frameCount
    bufferList.pointee.mBuffers.mData = UnsafeMutableRawPointer(feed.pointee.samples)
    bufferList.pointee.mBuffers.mDataByteSize =
        feed.pointee.frameCount * UInt32(MemoryLayout<Float>.size)
    return noErr
}

/// Engine-side mono Float32 → wire-side mono Int16 sample-rate conversion that
/// performs **no allocation per call** (RC-9).
///
/// ### Why not `AVAudioConverter`
///
/// `PCMFormatConverter` above is the right tool everywhere except the render
/// thread. Two things make it unusable there. The obvious one is that it builds
/// a fresh input and output `AVAudioPCMBuffer` on every call; that is fixable
/// by preallocating them. The one that is *not* fixable is the API itself:
/// `-convertToBuffer:error:withInputFromBlock:` does not mark its block
/// parameter `NS_NOESCAPE`, so Swift must produce a heap-allocated block for
/// every call. Measured on this machine (see
/// `RealTimeCapturePathTests.testDownConverterDoesNotAllocate` for the same
/// harness): **2 allocations per `convert` call**, and 4 per call if the
/// closure is hoisted into a stored `@convention(block)` property, which was
/// the obvious workaround. Preallocating the buffers does not move that number.
///
/// The underlying C API, `AudioConverterFillComplexBuffer`, takes a plain
/// `@convention(c)` function pointer plus a `void *` context, so there is
/// nothing to allocate. Measured with the same harness: **0 allocations across
/// 10 000 calls**. It is the same converter — `AVAudioConverter` is a thin
/// Objective-C wrapper over it — so the conversion quality and the resampler
/// are unchanged, which
/// `RealTimeCapturePathTests.testDownConverterAgreesWithPCMFormatConverter`
/// checks directly.
///
/// This is a deliberate deviation from the RC-9 brief's suggested shape ("give
/// `AVAudioConverter` preallocated output buffers"). Preallocated buffers are
/// necessary but, on this API, not sufficient.
///
/// Not thread-safe: an `AudioConverterRef` is stateful, and this one belongs to
/// exactly one capture session's tap thread.
final class RealTimeDownConverter {
    let sourceSampleRate: Double
    let wireSampleRate: Double

    /// Largest run of input frames a single ``convert(from:count:stride:)``
    /// will accept. Callers with more must chunk — ``CaptureTapProcessor``
    /// does — because growing the preallocated buffer is exactly what must not
    /// happen here.
    let maxInputFrames: Int

    /// Frames of Int16 output storage, sized from ``maxInputFrames`` and the
    /// conversion ratio plus headroom for the resampler's internal latency
    /// flushing out on the first calls.
    let outputCapacity: Int

    private let converter: AudioConverterRef
    private let inputStorage: UnsafeMutablePointer<Float>
    private let outputStorage: UnsafeMutablePointer<Int16>
    private let feed: UnsafeMutablePointer<CaptureInputFeed>
    private let outputList: UnsafeMutablePointer<AudioBufferList>

    /// - Returns: `nil` if the rates are not usable or CoreAudio refuses to
    ///   build a converter for them.
    init?(sourceSampleRate: Double, wireSampleRate: Double = 8_000, maxInputFrames: Int = 4_096) {
        guard
            sourceSampleRate.isFinite, sourceSampleRate > 0,
            wireSampleRate.isFinite, wireSampleRate > 0,
            maxInputFrames > 0,
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: 1,
                interleaved: false
            ),
            let wireFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: wireSampleRate,
                channels: 1,
                interleaved: false
            )
        else { return nil }

        // `streamDescription` is owned by the AVAudioFormat, so the format has
        // to outlive the read. Without the extended lifetime, ARC is entitled
        // to release it immediately after the `streamDescription` call and the
        // `pointee` read comes back as garbage — which it does, silently, and
        // then `AudioConverterNew` fails with -50.
        var sourceASBD = AudioStreamBasicDescription()
        var wireASBD = AudioStreamBasicDescription()
        withExtendedLifetime(sourceFormat) {
            withExtendedLifetime(wireFormat) {
                sourceASBD = sourceFormat.streamDescription.pointee
                wireASBD = wireFormat.streamDescription.pointee
            }
        }

        var reference: AudioConverterRef?
        guard AudioConverterNew(&sourceASBD, &wireASBD, &reference) == noErr,
              let reference
        else { return nil }

        self.converter = reference
        self.sourceSampleRate = sourceSampleRate
        self.wireSampleRate = wireSampleRate
        self.maxInputFrames = maxInputFrames
        self.outputCapacity =
            Int((Double(maxInputFrames) * wireSampleRate / sourceSampleRate).rounded(.up)) + 64

        self.inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: maxInputFrames)
        self.inputStorage.initialize(repeating: 0, count: maxInputFrames)
        self.outputStorage = UnsafeMutablePointer<Int16>.allocate(capacity: outputCapacity)
        self.outputStorage.initialize(repeating: 0, count: outputCapacity)
        self.outputList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        self.outputList.initialize(to: AudioBufferList())
        self.feed = UnsafeMutablePointer<CaptureInputFeed>.allocate(capacity: 1)
        self.feed.initialize(
            to: CaptureInputFeed(samples: inputStorage, frameCount: 0, consumed: true)
        )
    }

    deinit {
        AudioConverterDispose(converter)
        inputStorage.deinitialize(count: maxInputFrames)
        inputStorage.deallocate()
        outputStorage.deinitialize(count: outputCapacity)
        outputStorage.deallocate()
        outputList.deinitialize(count: 1)
        outputList.deallocate()
        feed.deinitialize(count: 1)
        feed.deallocate()
    }

    /// Converts one run of engine-side samples. **Real-time safe**: two
    /// `memcpy`-class copies into preallocated storage and one CoreAudio call
    /// that takes no locks the caller can contend on.
    ///
    /// - Parameters:
    ///   - source: channel-0 samples. Read as `source[i * stride]`.
    ///   - count: number of frames to read, at most ``maxInputFrames``.
    ///   - stride: 1 for de-interleaved buffers (what an `AVAudioEngine` tap
    ///     delivers), `channelCount` for interleaved ones.
    /// - Returns: a view of this converter's **preallocated** output storage,
    ///   valid only until the next call. Empty if the conversion produced
    ///   nothing or failed.
    func convert(
        from source: UnsafePointer<Float>,
        count: Int,
        stride: Int = 1
    ) -> UnsafeBufferPointer<Int16> {
        precondition(count <= maxInputFrames, "caller must chunk input to maxInputFrames")
        precondition(stride >= 1, "stride must be at least 1")
        guard count > 0 else { return UnsafeBufferPointer(start: nil, count: 0) }

        if stride == 1 {
            inputStorage.update(from: source, count: count)
        } else {
            var index = 0
            while index < count {
                inputStorage[index] = source[index * stride]
                index += 1
            }
        }
        feed.pointee.frameCount = UInt32(count)
        feed.pointee.consumed = false

        outputList.pointee.mNumberBuffers = 1
        outputList.pointee.mBuffers.mNumberChannels = 1
        outputList.pointee.mBuffers.mData = UnsafeMutableRawPointer(outputStorage)
        outputList.pointee.mBuffers.mDataByteSize =
            UInt32(outputCapacity * MemoryLayout<Int16>.size)

        var packets = UInt32(outputCapacity)
        let status = AudioConverterFillComplexBuffer(
            converter,
            captureInputProc,
            UnsafeMutableRawPointer(feed),
            &packets,
            outputList,
            nil
        )
        guard status == noErr else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: outputStorage, count: Int(packets))
    }
}

// MARK: - Capture tap processor (RC-9)

/// Everything the microphone tap does, in one object that owns all its storage.
///
/// One instance is created per `startCapture` and captured by that call's tap
/// closure alone, so — exactly as in the RC-7 fix this replaces — nothing it
/// touches is reachable from any other thread and it takes no lock. What RC-9
/// adds is that it also allocates nothing and calls nothing unbounded:
///
/// 1. read channel 0 of the tap buffer through a pointer (no `Array`),
/// 2. sample-rate convert it into preallocated storage
///    (``RealTimeDownConverter``),
/// 3. re-chunk to exactly 160 samples in preallocated storage
///    (``RealTimeFrameAssembler``),
/// 4. publish whole frames into a preallocated lock-free ring
///    (``RealTimeRingBuffer``).
///
/// The caller's `onFrame` is *not* called here. It is called by the drain task
/// `AudioPipeline` starts, at ordinary priority, on the other side of the ring.
final class CaptureTapProcessor {
    private let converter: RealTimeDownConverter
    private let assembler: RealTimeFrameAssembler

    /// Distance in `Float`s between consecutive channel-0 samples: 1 for the
    /// de-interleaved buffers `AVAudioEngine` taps normally deliver, otherwise
    /// the channel count. Captured once at `startCapture`, because reading
    /// `buffer.format` inside the callback is an Objective-C property fetch
    /// that has been observed to allocate.
    private let channelStride: Int

    /// The ring the tap publishes into. Held here so the drain task and
    /// `AudioPipeline`'s dropped-frame counter can see the same instance.
    let ring: RealTimeRingBuffer

    init(converter: RealTimeDownConverter, ring: RealTimeRingBuffer, channelStride: Int = 1) {
        precondition(channelStride >= 1, "channelStride must be at least 1")
        self.converter = converter
        self.ring = ring
        self.assembler = RealTimeFrameAssembler(frameSize: ring.frameSize)
        self.channelStride = channelStride
    }

    /// Tap entry point. Called on the real-time audio thread.
    ///
    /// **The frame count is bounded by the buffer, not by the caller (RC-15).**
    /// ``channelStride`` is fixed when the chain is built, and there is always
    /// some window — however short — in which the buffers arriving belong to a
    /// device the chain was not built for: between the tap install and the
    /// verifying read (``CaptureTapInstaller``), and between a device change
    /// and the `.AVAudioEngineConfigurationChange` that announces it (RC-14).
    /// A stride of 2 held over a de-interleaved mono buffer would read twice
    /// the buffer's length — an out-of-bounds read on the real-time audio
    /// thread, which is the one failure in this class that cannot be allowed to
    /// depend on anything upstream being timely. Clamping costs one pointer
    /// dereference and some arithmetic, and turns that read into the far
    /// cheaper failure of half a buffer of wrong-rate audio.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        process(
            channelZero: channels[0],
            frameCount: min(Int(buffer.frameLength), readableFrames(in: buffer))
        )
    }

    /// How many strided channel-0 samples can be read from `buffer` without
    /// leaving channel 0's allocation.
    ///
    /// Reads `audioBufferList`, not `format`: the buffer list is a pointer into
    /// storage the buffer already owns, whereas `buffer.format` is an
    /// Objective-C property fetch that has been observed to allocate — see
    /// ``channelStride``, and the allocation tests that pin both.
    ///
    /// De-interleaved buffers put channel 0 alone in the first `AudioBuffer`
    /// (`mDataByteSize` = frames × 4); interleaved buffers put every channel in
    /// it (frames × channels × 4). Either way the first buffer's byte size is
    /// the bound on what channel-0 reads may touch, and the last readable frame
    /// is the highest `n` with `n × stride` still inside it.
    private func readableFrames(in buffer: AVAudioPCMBuffer) -> Int {
        let bytes = Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize)
        let floats = bytes / MemoryLayout<Float>.size
        guard floats > 0 else { return 0 }
        return 1 + (floats - 1) / channelStride
    }

    /// Pointer-level entry point — the same code path as ``process(_:)``, minus
    /// the `AVAudioPCMBuffer`, so tests can drive the real tap body without an
    /// `AVAudioEngine`, a microphone, or a permission prompt.
    ///
    /// Input longer than the converter's `maxInputFrames` is processed in
    /// chunks rather than by growing anything.
    func process(channelZero source: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        var offset = 0
        while offset < frameCount {
            let chunk = min(frameCount - offset, converter.maxInputFrames)
            let wire = converter.convert(
                from: source + offset * channelStride,
                count: chunk,
                stride: channelStride
            )
            if !wire.isEmpty {
                assembler.push(wire, into: ring)
            }
            offset += chunk
        }
    }
}

// MARK: - Capture chain (RC-14)

/// Everything about a capture session that is derived from the **input
/// device's current format**, built in one place so that it can be rebuilt in
/// one place.
///
/// ### Why this type exists (RC-14)
///
/// `startCapture` used to snapshot the hardware format inline and scatter what
/// it derived from it — the converter's source rate, the tap's channel stride —
/// across three local constants. Nothing rebuilt them, so an
/// `AVAudioEngineConfigurationChange` (the operator changing the default input
/// device is one) left a live tap resampling from a rate the device no longer
/// ran at, striding by a channel count the buffers no longer had. The stride is
/// the sharp end: ``CaptureTapProcessor/process(channelZero:frameCount:)``
/// reads `source[index * channelStride]`, and a stride captured as 2 against a
/// buffer that is now de-interleaved mono reads past the end of channel 0's
/// allocation — an out-of-bounds read on the real-time audio thread.
///
/// Gathering the derivation here makes the rebuild a single expression
/// (``init?(inputFormat:)``) rather than a second copy of `startCapture`'s
/// body, and makes the format decision — which is the part that was wrong —
/// testable without a microphone. See ``AudioPipeline`` for where the rebuild
/// is triggered.
///
/// Compare ``PlaybackChain``, which is deliberately immune: playback buffers
/// are declared in the chain's *own* mono format and `AVAudioMixerNode` adapts
/// them to whatever the output hardware currently wants, so nothing on that
/// side has to be rebuilt when the hardware moves. Capture cannot be symmetric
/// with it, because a tap does not get to choose the format it is handed: the
/// buffers arrive in the input device's format, so the input device's format is
/// a fact this side must track rather than one it can convert away.
struct CaptureChain {
    /// The input rate this chain's converter was built for.
    let sourceSampleRate: Double

    /// Distance in `Float`s between consecutive channel-0 samples — see
    /// ``CaptureTapProcessor``.
    let channelStride: Int

    /// The tap body. Owns the converter, the assembler and the ring.
    let processor: CaptureTapProcessor

    var ring: RealTimeRingBuffer { processor.ring }

    /// The stride channel-0 reads must use for a given input format.
    ///
    /// De-interleaved buffers — what `AVAudioEngine` taps normally deliver —
    /// put channel 0 in its own allocation, so consecutive samples are
    /// adjacent whatever the channel count. Interleaved buffers put the
    /// channels side by side, so channel 0's samples are `channelCount` apart.
    ///
    /// Floored at 1. A format reporting zero channels is not a format we can
    /// read, but a stride of 0 would make every read land on sample 0 rather
    /// than fail, and ``CaptureTapProcessor`` has a `precondition` that says
    /// so; the caller's rate check rejects such a device first.
    static func channelStride(for format: AVAudioFormat) -> Int {
        guard format.isInterleaved else { return 1 }
        return max(1, Int(format.channelCount))
    }

    /// - Returns: `nil` if CoreAudio will not build a converter for the input
    ///   device's rate — the same condition `startCapture` reports as
    ///   ``AudioPipelineError/converterUnavailable``.
    init?(
        inputFormat: AVAudioFormat,
        wireSampleRate: Double,
        maxInputFrames: Int,
        frameSize: Int,
        ringCapacity: Int
    ) {
        guard let converter = RealTimeDownConverter(
            sourceSampleRate: inputFormat.sampleRate,
            wireSampleRate: wireSampleRate,
            maxInputFrames: maxInputFrames
        ) else { return nil }

        self.sourceSampleRate = inputFormat.sampleRate
        self.channelStride = Self.channelStride(for: inputFormat)
        self.processor = CaptureTapProcessor(
            converter: converter,
            ring: RealTimeRingBuffer(frameSize: frameSize, capacity: ringCapacity),
            channelStride: channelStride
        )
    }

    /// Whether this chain is still the right one for `format`.
    ///
    /// Rate and stride are the only two things derived from the format, so they
    /// are the only two that can go stale. A configuration change that moves
    /// neither — most of them, on iOS, where the notification accompanies route
    /// changes that leave the input device alone — needs no rebuild, and
    /// rebuilding anyway would drop the frames in flight for nothing.
    func matches(_ format: AVAudioFormat) -> Bool {
        sourceSampleRate == format.sampleRate && channelStride == Self.channelStride(for: format)
    }
}

/// Carries the caller's `onFrame` closure from ``AudioPipeline/startCapture(onFrame:)``
/// into the drain task.
///
/// `@unchecked Sendable` is honest here: the closure is invoked from exactly
/// one place, the single drain task created alongside it, and never
/// concurrently with itself.
private struct FrameSink: @unchecked Sendable {
    let deliver: ([Int16]) -> Void
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
/// * The microphone tap closure touches **only** the ``CaptureTapProcessor``
///   created for that one capture session. It does not capture `self`, does
///   not read or write any property of this class, and never takes a lock —
///   taking a contended lock on a real-time audio thread would be a bug in its
///   own right.
/// * Everything on the caller's side — the engine graph, `isCapturing` — is
///   mutated only under ``lock``, which the render thread never touches.
/// * ``playback`` and ``signals`` are `let`s established in `init`.
///
/// Public methods (`startCapture`, `enqueuePlayback`, `stop`) may therefore be
/// called from any thread, but **must not** be called from an audio render
/// callback, since they take the lock and allocate.
///
/// ### RC-9 — the capture path is real-time safe
///
/// Freedom from data races is not the same as freedom from *stalls*. `malloc`
/// takes a lock inside the allocator; a real-time thread that blocks on a lock
/// held by a normal-priority thread misses its deadline. The failure mode is
/// not a crash or a wrong answer, it is an occasional dropout under load — the
/// kind of fault that gets blamed on the network.
///
/// So the tap thread now does a strictly bounded amount of work with no
/// allocator involvement at all: pointer read of the tap buffer, sample-rate
/// conversion into preallocated storage, re-chunking in preallocated storage,
/// and a lock-free publish into a preallocated ring. See
/// ``CaptureTapProcessor``. The caller's `onFrame` — arbitrary code that may
/// encode, encrypt, and send a UDP datagram — is invoked from a drain task at
/// ordinary priority on the far side of the ring, never from the callback.
///
/// Two consequences the caller should know about:
///
/// * Frames arrive up to ``captureDrainInterval`` later than before (5 ms),
///   because the drain task polls. Signalling the drain task directly from the
///   render thread would mean a semaphore or a continuation resume, which is
///   the lock this whole design exists to avoid.
/// * If the consumer stalls long enough to fill the ring, frames are dropped
///   and counted — see ``droppedCaptureFrameCount``. Check it.
public final class AudioPipeline: @unchecked Sendable {
    /// Fixed capture frame size: 160 samples = 20 ms at 8 kHz. Matches
    /// `G711MuLawCodec.samplesPerFrame` and `JitterBuffer`'s `frameDuration`
    /// default — every consumer downstream of `AudioPipeline` expects this.
    public static let captureFrameSize = 160

    /// Wire-side sample rate. 8 kHz — every codec in scope is narrowband.
    public static let wireSampleRate: Double = 8_000

    /// Frames the capture ring holds before it starts dropping: 100 × 20 ms =
    /// 2 s. Two seconds is far more than a healthy consumer ever needs, which
    /// is the point — reaching the end of it means something upstream is
    /// genuinely broken, not merely momentarily busy, and
    /// ``droppedCaptureFrameCount`` should be believed.
    public static let captureRingCapacityFrames = 100

    /// How often the drain task looks for new frames, in nanoseconds (5 ms).
    ///
    /// Polling, rather than being woken by the tap, is deliberate: every
    /// available wake-up primitive (semaphore signal, continuation resume,
    /// `AsyncStream.yield`) either takes a lock or allocates, and doing that on
    /// the render thread is precisely the hazard RC-9 removes. 5 ms costs 200
    /// wake-ups a second and bounds the added latency at a quarter of one
    /// 20 ms frame, which is invisible next to any jitter buffer.
    public static let captureDrainInterval: UInt64 = 5_000_000

    /// Largest run of input frames the capture converter accepts in one call.
    /// `installTap(bufferSize:)` is a request, not a promise, so this is sized
    /// well above the 1024 asked for; anything larger still arrives safely,
    /// processed in chunks rather than by growing a buffer.
    private static let maxTapFrames = 4_096

    private static let tapBufferSize: AVAudioFrameCount = 1_024

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// The input node, behind the seam the tap install is tested through
    /// (RC-15). `lazy` so that constructing an `AudioPipeline` still touches no
    /// input hardware: `EngineInputTapHost` reaches for `engine.inputNode` only
    /// when asked, and this property is only ever reached from the capture path
    /// with ``lock`` held.
    private lazy var tapHost: CaptureTapHost = EngineInputTapHost(engine: engine)

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

    /// Guarded by ``lock``. The **live** capture session's ring; `nil` between
    /// sessions.
    ///
    /// The dropped-frame count of the session that just ended is the number a
    /// caller most wants to read, so it is not thrown away when the ring is —
    /// ``teardownCaptureLocked()`` moves it into
    /// ``droppedFramesFromRetiredRings`` first, and
    /// ``droppedCaptureFrameCount`` adds the two. Before RC-14 the ring itself
    /// was kept for this, which a mid-session rebuild would have made
    /// ambiguous: two rings, one session, one number.
    private var captureRing: RealTimeRingBuffer?

    /// Guarded by ``lock``. Drains ``captureRing`` at ordinary priority and
    /// calls the caller's `onFrame`. Cancelled by `stop()` and by a repeated
    /// `startCapture`.
    private var captureTask: Task<Void, Never>?

    /// Guarded by ``lock``. Everything the current capture session derives from
    /// the input device's format — see ``CaptureChain``. Held so that
    /// ``rebuildCaptureAfterConfigurationChange()`` can tell a chain that has
    /// gone stale from one that has not (RC-14).
    private var captureChain: CaptureChain?

    /// Guarded by ``lock``. The current session's `onFrame`, kept so that a
    /// chain rebuilt under the caller keeps delivering to the same closure
    /// (RC-14). Cleared by `stop()`: without a caller asking for audio there is
    /// nothing to rebuild for.
    private var captureSink: FrameSink?

    /// Guarded by ``lock``. Frames dropped by rings this session has retired —
    /// see ``droppedCaptureFrameCount``, which adds the live ring's own count
    /// to this. Non-zero only when a chain was rebuilt mid-session (RC-14).
    private var droppedFramesFromRetiredRings = 0

    /// Guarded by ``lock``. See ``captureChainRebuildCount``.
    private var captureChainRebuilds = 0

    /// Guarded by ``lock``. See ``captureChainRebuildFailureCount``.
    private var captureChainRebuildFailures = 0

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
        captureTask?.cancel()
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
    /// **RC-9: `onFrame` is no longer called on the audio render thread.** It
    /// is called from a drain task at ordinary priority, one frame at a time,
    /// in order, never concurrently with itself. That means it may now block
    /// briefly — a `send` on a socket is fine — though it should still not
    /// block for long, because the ring behind it is finite and overrun costs
    /// audio (see ``droppedCaptureFrameCount``).
    ///
    /// The tap owns everything it needs: a converter built for this capture
    /// session's input rate, a private frame assembler, and a private ring, all
    /// allocated here, before the tap is installed. Nothing it touches is
    /// reachable from any other thread, so it takes no lock (see the type-level
    /// concurrency note), and `onFrame` cannot be swapped out from under a call
    /// in progress — `stop()` removes the tap and cancels the drain task, which
    /// is what ends delivery.
    ///
    /// Calling this a second time restarts capture: the previous tap and drain
    /// task are torn down first.
    ///
    /// - Throws: ``AudioPipelineError/converterUnavailable`` if CoreAudio will
    ///   not build a converter for the input device's rate.
    public func startCapture(onFrame: @escaping ([Int16]) -> Void) throws {
        let sink = FrameSink(deliver: onFrame)

        lock.lock()
        defer { lock.unlock() }

        captureSink = sink
        // A new session, so a new count. `installCaptureLocked` adds the
        // outgoing ring's drops to the carry-over, which is what a *rebuild*
        // wants and a fresh start does not, so clear it afterwards.
        do {
            try installCaptureLocked(sink: sink)
            droppedFramesFromRetiredRings = 0
            captureChainRebuilds = 0
            captureChainRebuildFailures = 0
        } catch {
            captureSink = nil
            throw error
        }
    }

    /// Builds a chain for the input device's *current* format and installs it,
    /// tearing down whatever was there first. The one place a tap is installed:
    /// ``startCapture(onFrame:)`` calls it to begin a session and
    /// ``rebuildCaptureAfterConfigurationChange()`` calls it to replace a chain
    /// the hardware has invalidated (RC-14).
    ///
    /// Must be called with ``lock`` held.
    ///
    /// - Throws: ``AudioPipelineError/converterUnavailable`` if CoreAudio will
    ///   not build a converter for the input device's rate, or whatever
    ///   `AVAudioEngine.start()` throws.
    private func teardownCaptureLocked() {
        if isCapturing {
            // Only touch the input node if we actually opened it: reaching for
            // `engine.inputNode` instantiates the input audio unit, which is
            // pointless (and on iOS, permission-adjacent) in a receive-only or
            // never-started session.
            tapHost.removeTap()
            isCapturing = false
        }
        captureTask?.cancel()
        captureTask = nil
        captureChain = nil
        // The dropped count belongs to the *session*, not to the ring, so a
        // chain rebuilt mid-session does not quietly reset the number that says
        // how much transmit audio was lost. `startCapture` clears the
        // carry-over for a session that is genuinely new.
        droppedFramesFromRetiredRings += captureRing?.droppedFrameCount ?? 0
        captureRing = nil
    }

    private func installCaptureLocked(sink: FrameSink) throws {
        // Pre-flight, before anything is torn down: can CoreAudio convert at
        // all from the rate the device is running at now? A `startCapture` that
        // cannot must leave the session it was asked to replace running rather
        // than killing it on the way out, and the installer below cannot offer
        // that because it needs the bus free before its first attempt.
        //
        // A converter rather than a whole chain, because this answer is
        // discarded: the chain that ends up installed is the installer's, built
        // from the format the tap is actually given (RC-15).
        guard RealTimeDownConverter(
            sourceSampleRate: tapHost.currentInputFormat.sampleRate,
            wireSampleRate: Self.wireSampleRate,
            maxInputFrames: Self.maxTapFrames
        ) != nil else {
            throw AudioPipelineError.converterUnavailable
        }

        // Installing a second tap on a bus that already has one is a hard error
        // in AVAudioEngine; make a repeated startCapture mean "restart".
        teardownCaptureLocked()

        // A chain per capture session, owned by this session's tap alone. Its
        // rate comes from the input device and is never allowed to reach the
        // playback path (RC-7 Defect 1) — and because it is never shared, the
        // stateful converter inside it is only ever driven from the one thread
        // that drives this tap (RC-7 Defect 2).
        //
        // **The installer decides which format that is, not this method**
        // (RC-15). It installs with no format at all, then checks the chain
        // against what the node reports afterwards, so a device that changes
        // inside the window is retried rather than allowed to raise an
        // uncatchable format-mismatch exception. The tap body it installs is
        // the only thing the render thread does: no allocation, no lock, no
        // caller code — see CaptureTapProcessor.
        let chain = try CaptureTapInstaller.install(
            host: tapHost,
            bufferSize: Self.tapBufferSize,
            makeChain: { format in
                CaptureChain(
                    inputFormat: format,
                    wireSampleRate: Self.wireSampleRate,
                    maxInputFrames: Self.maxTapFrames,
                    frameSize: Self.captureFrameSize,
                    ringCapacity: Self.captureRingCapacityFrames
                )
            })
        isCapturing = true
        captureChain = chain
        captureRing = chain.ring
        captureTask = Self.makeDrainTask(ring: chain.ring, sink: sink)

        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            tapHost.removeTap()
            isCapturing = false
            captureTask?.cancel()
            captureTask = nil
            captureChain = nil
            throw error
        }
    }

    /// **RC-14.** Replaces the capture chain with one built for the input
    /// device's current format, after `AVAudioEngine` has told us the format it
    /// was built for may no longer be the one arriving.
    ///
    /// Called from the `.AVAudioEngineConfigurationChange` observer **before**
    /// the signal is published, so a consumer that acts on `.routeChanged` —
    /// SF-3 ending a transmission, say — never observes a half-rebuilt chain.
    ///
    /// Does nothing when no capture is running (there is no stale chain to
    /// replace; playback restarts the engine on its own — see
    /// ``enqueuePlayback(_:)``) or when the format is unchanged, which is most
    /// of them on iOS, where this notification accompanies route changes that
    /// leave the input device alone.
    ///
    /// The whole of what an `.AVAudioEngineConfigurationChange` means to this
    /// class: rebuild, then announce. Both halves in one method so that the
    /// test hook drives the same two steps in the same order the notification
    /// does, rather than a copy of them.
    private func handleEngineConfigurationChange() {
        rebuildCaptureAfterConfigurationChange()
        signalContinuation.yield(.routeChanged(.engineConfigurationChange))
    }

    private func rebuildCaptureAfterConfigurationChange() {
        lock.lock()
        defer { lock.unlock() }

        guard isCapturing, let sink = captureSink else { return }

        let hardwareFormat = tapHost.currentInputFormat
        if let current = captureChain, current.matches(hardwareFormat) {
            // The formats agree, so the tap is still reading correctly. The
            // engine may still have been stopped by the reconfiguration,
            // though, and a stopped engine delivers no buffers at all.
            if !engine.isRunning {
                try? engine.start()
            }
            return
        }

        // **The stale tap comes down first, and unconditionally.** Not as part
        // of installing its replacement: building one can fail — CoreAudio may
        // refuse a converter for the device the system just moved to — and the
        // failure path must not be the one that leaves a tap reading through a
        // format description we already know is wrong. Silence is recoverable;
        // an out-of-bounds read on the audio thread is not.
        teardownCaptureLocked()
        do {
            try installCaptureLocked(sink: sink)
            captureChainRebuilds += 1
        } catch {
            // Capture is over. The caller finds out through the `.routeChanged`
            // signal published immediately after this, which for SF-3's sake it
            // has to act on anyway.
            captureChainRebuildFailures += 1
        }
    }

    /// Frames the microphone tap had to discard because the ring filled up —
    /// i.e. because whatever `onFrame` does could not keep up with real time.
    ///
    /// Zero is the only good value. A non-zero value is lost transmit audio and
    /// nothing else; it is reported rather than hidden because a silent gap is
    /// indistinguishable, from the operator's chair, from a bad network path.
    /// Resets when ``startCapture(onFrame:)`` begins a new session; survives
    /// ``stop()`` so the session that just ended can still be inspected, and
    /// survives a chain rebuilt under a running session (RC-14) — a device
    /// swap mid-over must not make the audio lost before it disappear.
    public var droppedCaptureFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedFramesFromRetiredRings + (captureRing?.droppedFrameCount ?? 0)
    }

    /// Frames currently sitting in the capture ring, waiting for the drain
    /// task. Useful as a health signal in CLI-1: it should hover near zero.
    public var pendingCaptureFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captureRing?.availableFrames ?? 0
    }

    /// How many times a running capture session has had its chain rebuilt for
    /// a changed input format (RC-14).
    ///
    /// Diagnostic. This package has no logger, and a rebuild is deliberately
    /// invisible to the caller — the same `onFrame` goes on being called — so
    /// this is how a harness or a bug report gets to say the device moved under
    /// an over. Cleared by ``startCapture(onFrame:)``; survives `stop()`.
    public var captureChainRebuildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captureChainRebuilds
    }

    /// How many of those rebuilds failed, each of which ended capture (RC-14).
    ///
    /// Non-zero means the system moved to an input device CoreAudio will not
    /// build a converter for, and any transmission running at the time went
    /// silent. Counts and clears with ``captureChainRebuildCount``.
    public var captureChainRebuildFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captureChainRebuildFailures
    }

    /// The normal-priority side of the handoff: drain everything the ring has,
    /// hand each frame to the caller, then sleep briefly and look again.
    ///
    /// The inner loop is bounded by the ring's capacity so that a producer
    /// faster than the consumer cannot keep this task from ever observing
    /// cancellation.
    private static func makeDrainTask(ring: RealTimeRingBuffer, sink: FrameSink) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            // One reusable frame buffer for the whole session; `deliver` gets a
            // copy because the closure takes `[Int16]` by value.
            var frame = [Int16](repeating: 0, count: ring.frameSize)
            while !Task.isCancelled {
                var drained = 0
                while drained < ring.capacity,
                      frame.withUnsafeMutableBufferPointer({ ring.read(into: $0) }) {
                    sink.deliver(frame)
                    drained += 1
                }
                do {
                    try await Task.sleep(nanoseconds: AudioPipeline.captureDrainInterval)
                } catch {
                    return // cancelled
                }
            }
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
    ///
    /// Any frames still sitting in the capture ring are discarded rather than
    /// delivered: once the caller has said stop, delivering more audio after
    /// the call returns would be worse than losing 20 ms of it. The ring itself
    /// is kept so ``droppedCaptureFrameCount`` still answers for the session
    /// that just ended.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        teardownCaptureLocked()
        // No caller wants audio any more, so there is nothing for a
        // configuration change to rebuild (RC-14).
        captureSink = nil

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
            guard let self else { return }
            // Not a session route change: the engine itself was reconfigured.
            // The only one of these on macOS, and on iOS it accompanies a graph
            // rebuild.
            //
            // **RC-14: rebuild first, announce second.** The format this
            // session's tap was built for may no longer be the format arriving
            // in it, and a stale channel stride is an out-of-bounds read on the
            // audio thread. Doing it here rather than leaving it to the
            // consumer is not a convenience: the consumer cannot reach the
            // chain, and the ~7 ms it takes one to notice and stop is 7 ms of a
            // live tap reading through a format description the system has
            // already told us is wrong. Ordering it before the `yield` means a
            // consumer acting on the signal never races a half-rebuilt chain.
            self.handleEngineConfigurationChange()
        }
        notificationTokens.append(configurationToken)

        #if os(iOS)
        let routeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            self?.signalContinuation.yield(
                .routeChanged(AudioRouteChangeCause(rawReason: raw ?? 0)))
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

    /// Configures the shared `AVAudioSession` per AU-2, then activates it.
    /// Call once, before ``startCapture(onFrame:)``.
    ///
    /// Delegates to ``AudioPipeline/activateSession()``, which holds the policy
    /// and needs no pipeline. Prefer the static form: reaching the policy
    /// through an instance means having built an `AVAudioEngine` first, which
    /// is the ordering RC-11 exists to break.
    public func configureSession() throws {
        try Self.activateSession()
    }

    /// Applies ``AudioSessionPolicy/radio`` to the shared `AVAudioSession` and
    /// activates it — **without constructing an `AudioPipeline` or an
    /// `AVAudioEngine`** (RC-11).
    ///
    /// That order is the whole point. An engine whose input unit is
    /// instantiated under the default `.soloAmbient` category reports a 0 Hz
    /// input rate and never recovers, which is a converter failure on every
    /// PTT press for the life of the process — the app's `BU-1`. Callers
    /// therefore need to set the category *before* deciding to build anything,
    /// and until this existed the only way to reach the policy was to violate
    /// that order or to spell the policy out a second time.
    ///
    /// iOS-only. `AVAudioSession` does not exist on macOS, where input/output
    /// device selection is the user's, via System Settings.
    public static func activateSession() throws {
        try activateSession(AudioSessionPolicy.radio)
    }

    /// Apply `policy` and activate the session (RC-12).
    ///
    /// The same operation as ``activateSession()``, with the policy as an
    /// argument so a caller can hold ``AudioSessionPolicy/listening`` while idle
    /// and ``AudioSessionPolicy/radio`` only while transmitting. See the note on
    /// `listening` for why that matters and for the engine-rebuild obligation it
    /// carries.
    ///
    /// Activating rather than deactivating between the two: received audio still
    /// has to play while idle, so the session stays up and only the *category*
    /// changes. A deactivated session cannot play anything.
    public static func activateSession(_ policy: AudioSessionPolicy) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            AVAudioSession.Category(rawValue: policy.category),
            mode: AVAudioSession.Mode(rawValue: policy.mode),
            options: AVAudioSession.CategoryOptions(rawValue: policy.options))
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

    /// Runs exactly what the `.AVAudioEngineConfigurationChange` observer runs
    /// (RC-14), without a device having to disappear underneath the test.
    ///
    /// Internal and test-only. It reaches no hardware while no capture is
    /// running — ``rebuildCaptureAfterConfigurationChange()`` returns before
    /// touching `engine.inputNode`, which is the line that would instantiate
    /// the input audio unit and, on iOS, raise a permission prompt — so this
    /// is safe to call on a headless machine. Under a *running* capture it
    /// does the real rebuild, which is why the hardware half of RC-14 is
    /// confirmed by `hamvoip-cli` rather than here (AU-5).
    func simulateEngineConfigurationChange() {
        handleEngineConfigurationChange()
    }

    /// Starts the same drain loop `startCapture` starts, against a
    /// caller-supplied ring.
    ///
    /// Internal and test-only. It exists because the drain task is the entire
    /// delivery path after RC-9 — if it stops, the radio goes quiet — and the
    /// only other way to reach it is through `startCapture`, which opens a
    /// microphone. This hook makes the loop testable with no hardware and no
    /// permission, using exactly the code path production uses.
    static func makeCaptureDrainTaskForTesting(
        ring: RealTimeRingBuffer,
        onFrame: @escaping ([Int16]) -> Void
    ) -> Task<Void, Never> {
        makeDrainTask(ring: ring, sink: FrameSink(deliver: onFrame))
    }
}
