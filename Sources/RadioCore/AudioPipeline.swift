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
    ///
    /// RC-16 widened it: it is also what a device that never *settles* reports,
    /// i.e. one whose input node and hardware went on disagreeing about the
    /// format through every attempt to reconcile them.
    case inputFormatUnstable

    /// Another install of the capture tap was already in flight, so this one
    /// did nothing rather than racing it (RC-16).
    ///
    /// Ordinarily a genuine race — a PTT press against the rebuild an
    /// `.AVAudioEngineConfigurationChange` started — and retrying is right.
    ///
    /// It is also what a caller sees after an install was unwound by an
    /// Objective-C `NSException`, since a raise runs no `defer` and so never
    /// releases the claim. ``AudioPipeline/stop()`` clears it, which makes
    /// "stop, then start again" the recovery for a fault the process cannot
    /// otherwise observe at all.
    case captureInstallInProgress

    /// The capture session this install was building was ended — by `stop()`,
    /// or by another install — before it had anything to commit (RC-16).
    ///
    /// Nothing was installed and nothing is running: the caller's `stop()` won,
    /// which is what it should do. A `startCapture` that races the caller's own
    /// `stop()` is the ordinary way to see this, and starting again is the
    /// answer if capture was in fact wanted.
    case captureInstallSuperseded

    /// The audio engine could not be reached within the deadline (RC-16).
    ///
    /// Either something else is mid-install, or an `NSException` unwound out of
    /// AVFAudio and left the engine unreachable for good. Deliberately a
    /// bounded failure rather than a wait: a caller that blocks forever on the
    /// audio graph is the deadlock RC-16 is about.
    case audioEngineBusy

    public var description: String {
        switch self {
        case .converterUnavailable:
            return "could not construct an AVAudioConverter for the requested PCM formats"
        case .inputFormatUnstable:
            return "the input device's format kept changing while the capture tap was installed"
        case .captureInstallInProgress:
            return "another capture tap install is already in flight"
        case .captureInstallSuperseded:
            return "the capture session this install was building was ended before it finished"
        case .audioEngineBusy:
            return "the audio engine could not be reached within the deadline"
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
/// * Everything on the caller's side — `isCapturing` and the rest of the
///   capture session's state — is mutated only under ``lock``, which the
///   render thread never touches. The engine *graph* is serialised separately,
///   by ``engineLock``.
/// * ``playback`` and ``signals`` are `let`s established in `init`.
///
/// Public methods (`startCapture`, `enqueuePlayback`, `stop`) may therefore be
/// called from any thread, but **must not** be called from an audio render
/// callback, since they take a lock and allocate.
///
/// ### RC-16 — no lock is held across a call that can raise
///
/// AVFAudio reports some failures as Objective-C `NSException`s, and **a Swift
/// `defer` does not run when an ObjC exception unwinds through it**. A single
/// lock held across such a call is therefore not merely unlocked late, it is
/// orphaned forever — which is how Currawong hung: three threads waiting on
/// this class's `NSLock`, none holding it, the process alive and permanently
/// unresponsive with a dead audio pipeline. On a transmit path that is worse
/// than a crash, because nothing tells the operator the radio has stopped.
///
/// So the two jobs one lock used to do are now two locks, with a rule each:
///
/// * ``lock`` guards **state**, and is never held across a call into AVFAudio.
/// * ``engineLock`` guards the **graph**, is held across those calls, and is
///   only ever taken with a deadline — see ``withEngine(timeout:_:)``.
///
/// A raise can still cost the audio path: an orphaned ``engineLock`` makes the
/// engine unreachable, and every caller then reports
/// ``AudioPipelineError/audioEngineBusy`` instead of blocking. That is a
/// reportable, non-fatal failure of *this object*, which is the most a library
/// can offer against an API that raises; what it is not is a wedged host.
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
    /// when asked.
    ///
    /// A `lazy var` is not thread-safe, so it is *materialised* under ``lock``
    /// — every capture path reads it into a local and then works from that
    /// local, because the calls it makes must happen with ``lock`` released
    /// (RC-16). Reached only where a tap is known to exist or is about to, so
    /// that a receive-only session never instantiates the input audio unit.
    lazy var tapHost: CaptureTapHost = EngineInputTapHost(engine: engine)

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

    /// Serialises the capture session's caller-side **state**: `isCapturing`,
    /// the ring, the chain, the drain task, the sink and the counters.
    ///
    /// **Never acquired from the real-time audio thread.** The tap closure is
    /// built to need nothing this lock protects; see the type-level
    /// concurrency note.
    ///
    /// **Never held across a call into AVFAudio** (RC-16) — that is the whole
    /// of the fix, and every method below is shaped by it: read or commit state
    /// under this lock, touch the graph outside it. A call that raises an
    /// Objective-C `NSException` runs no `defer`, so a lock held across one is
    /// orphaned for the life of the process.
    private let lock = NSLock()

    /// Serialises engine-**graph** calls: installing and removing the tap,
    /// starting and stopping the engine, and building and scheduling playback
    /// buffers.
    ///
    /// Separate from ``lock`` because it is the one that *is* held across
    /// AVFAudio, two threads mutating one engine graph being a fault of its
    /// own. What makes that survivable is that it is only ever taken with a
    /// deadline, through ``withEngine(timeout:_:)``: an orphaned engine lock
    /// costs the audio path, not the caller's thread.
    ///
    /// Acquisition order where both are wanted: ``lock`` first, released before
    /// this one is taken. Never nested, and never the reverse.
    private let engineLock = NSLock()

    /// How long a caller waits for ``engineLock`` before reporting
    /// ``AudioPipelineError/audioEngineBusy``.
    ///
    /// Comfortably longer than an install or an engine start — tens of
    /// milliseconds on real hardware — and short enough that a thread which is
    /// never going to get the lock finds out and says so.
    private static let engineLockTimeout: TimeInterval = 2

    /// The deadline for the paths an operator is waiting on: `stop()`,
    /// `enqueuePlayback`, and the engine nudge after a configuration change.
    ///
    /// One playback frame rather than seconds. Dropping 20 ms of received
    /// audio, or leaving a tap on a bus whose session has already been ended,
    /// both cost less than a PTT release that takes two seconds to return —
    /// and this is the deadline that runs on the app's main thread.
    private static let responsiveEngineLockTimeout: TimeInterval = 0.1

    /// Guarded by ``lock``. Tracks whether a tap is installed, so `stop()` is
    /// idempotent and a second `startCapture` cannot install a second tap on
    /// a bus that already has one.
    private var isCapturing = false

    /// Guarded by ``lock``. Claimed for the length of one install, which now
    /// spans several separately-locked regions rather than one (RC-16), so that
    /// two installs cannot interleave over a bus that holds one tap.
    ///
    /// A dedicated in-flight flag rather than an inference from `isCapturing`,
    /// which the install's own completion path writes — the same rule the
    /// actor-reentrancy hazard in `M17ReflectorClient` is written to.
    ///
    /// **Not released by an `NSException`**, since a raise runs no `defer`. An
    /// orphaned claim makes later installs fail with
    /// ``AudioPipelineError/captureInstallInProgress`` — a catchable error, not
    /// a block — and ``stop()`` clears it.
    private var captureInstallInFlight = false

    /// Guarded by ``lock``. Bumped by every ``retireCaptureSessionLocked()``,
    /// so that an install can tell whether the session it was building for is
    /// still the one wanted by the time it has something to commit.
    ///
    /// Needed because an install is no longer one locked region (RC-16): a
    /// `stop()` can now land in the middle of one, and without this the install
    /// would go on to commit a live tap and a drain task delivering to a caller
    /// who has already said stop. The claim flag cannot answer this — it is
    /// what stops two *installs* overlapping, and `stop()` deliberately does
    /// not wait on it.
    private var captureSessionGeneration = 0

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
    ///   not build a converter for the input device's rate,
    ///   ``AudioPipelineError/inputFormatUnstable`` if the input device would
    ///   not hold still long enough to install a tap in a format it agrees
    ///   with, ``AudioPipelineError/captureInstallInProgress`` if another
    ///   install is already running, or
    ///   ``AudioPipelineError/audioEngineBusy`` if the engine could not be
    ///   reached. Every one of them is a `throw` a caller's `do/catch` can see
    ///   — which is not a given on this path, and is the subject of RC-15 and
    ///   RC-16.
    public func startCapture(onFrame: @escaping ([Int16]) -> Void) throws {
        try installCaptureSession(sink: FrameSink(deliver: onFrame), isRebuild: false)
    }

    /// Runs `body` with ``engineLock`` held, or returns `nil` if that lock
    /// cannot be had within `timeout`.
    ///
    /// **The deadline is the point** (RC-16). This is the lock that is held
    /// across AVFAudio, so it is the one an Objective-C `NSException` can
    /// orphan; a `nil` return says the engine is unreachable — busy, or gone
    /// for good — and every caller has something honest to do with that, from
    /// dropping one playback frame to reporting
    /// ``AudioPipelineError/audioEngineBusy``. What no caller does is wait.
    private func withEngine<T>(timeout: TimeInterval, _ body: () -> T) -> T? {
        guard engineLock.lock(before: Date().addingTimeInterval(timeout)) else { return nil }
        let value = body()
        engineLock.unlock()
        return value
    }

    /// Ends the live capture session's **state** and reports whether a tap is
    /// still on the bus.
    ///
    /// Only the state: taking the tap off the bus is an AVFAudio call like any
    /// other, so it happens in ``removeTap(from:)`` once the caller has
    /// released ``lock`` (RC-16). Splitting it this way is what lets `stop()`
    /// finish its bookkeeping even when the graph is unreachable.
    ///
    /// Must be called with ``lock`` held.
    @discardableResult
    private func retireCaptureSessionLocked() -> Bool {
        let hadTap = isCapturing
        isCapturing = false
        captureTask?.cancel()
        captureTask = nil
        captureChain = nil
        // The dropped count belongs to the *session*, not to the ring, so a
        // chain rebuilt mid-session does not quietly reset the number that says
        // how much transmit audio was lost. `startCapture` clears the
        // carry-over for a session that is genuinely new.
        droppedFramesFromRetiredRings += captureRing?.droppedFrameCount ?? 0
        captureRing = nil
        captureSessionGeneration &+= 1
        return hadTap
    }

    /// Takes the tap off the bus. Call with ``lock`` released, and only when a
    /// tap was actually installed: reaching for `engine.inputNode` instantiates
    /// the input audio unit, which is pointless (and on iOS,
    /// permission-adjacent) in a receive-only or never-started session.
    private func removeTap(from host: CaptureTapHost) {
        _ = withEngine(timeout: Self.engineLockTimeout) { host.removeTap() }
    }

    /// Builds a chain for the input device's current format and installs it,
    /// retiring whatever was there first. The one place a tap is installed:
    /// ``startCapture(onFrame:)`` calls it to begin a session and
    /// ``rebuildCaptureAfterConfigurationChange()`` calls it to replace a chain
    /// the hardware has invalidated (RC-14).
    ///
    /// **Takes ``lock`` several times and holds it across none of the AVFAudio
    /// calls** (RC-16). An install used to be one locked region, which meant a
    /// raise out of `installTap` orphaned the lock and wedged the host. What
    /// serialises it now is ``captureInstallInFlight``, claimed here and
    /// released on every path a Swift `throw` can take — and, deliberately, on
    /// no path an `NSException` can take, because there is no such path: a
    /// caller that finds a stale claim is told
    /// ``AudioPipelineError/captureInstallInProgress`` rather than being made
    /// to wait for something that will never happen.
    private func installCaptureSession(sink: FrameSink, isRebuild: Bool) throws {
        // 1 — claim the install and take a reference to the host, under the
        // state lock and nothing else.
        lock.lock()
        guard !captureInstallInFlight else {
            lock.unlock()
            throw AudioPipelineError.captureInstallInProgress
        }
        captureInstallInFlight = true
        captureSink = sink
        let host = tapHost
        // RC-14: a rebuild's chain is *already* known to be wrong for the
        // buffers arriving, so its tap comes down before anything that can
        // fail. A fresh start keeps the session it was asked to replace until
        // the pre-flight below says a replacement is possible at all.
        let staleTap = isRebuild ? retireCaptureSessionLocked() : false
        // Read after our own retire, so that what invalidates this install is
        // somebody *else* ending the session.
        let generation = captureSessionGeneration
        lock.unlock()
        if staleTap { removeTap(from: host) }

        do {
            try installCaptureSession(
                sink: sink, host: host, isRebuild: isRebuild, generation: generation)
            lock.lock()
            captureInstallInFlight = false
            lock.unlock()
        } catch {
            lock.lock()
            captureInstallInFlight = false
            // A rebuild keeps the sink: it is the running caller's, and it is
            // what a later configuration change would rebuild for. A failed
            // fresh start has no caller waiting on audio at all.
            if !isRebuild { captureSink = nil }
            lock.unlock()
            throw error
        }
    }

    /// The install proper, from the pre-flight to a running engine. Split out
    /// so that every exit is a `throw` the claim-releasing `catch` above sees.
    ///
    /// - Throws: ``AudioPipelineError/converterUnavailable`` if CoreAudio will
    ///   not build a converter for the input device's rate,
    ///   ``AudioPipelineError/audioEngineBusy`` if the graph could not be
    ///   reached, whatever ``CaptureTapInstaller`` throws, or whatever
    ///   `AVAudioEngine.start()` throws.
    private func installCaptureSession(
        sink: FrameSink, host: CaptureTapHost, isRebuild: Bool, generation: Int
    ) throws {
        // The session this install is for. Step 3 replaces it with its own,
        // for the same reason step 1 read it after retiring: what must
        // invalidate the commit is somebody else ending the session, not us.
        var generation = generation
        // 2 — pre-flight, with no lock held: can CoreAudio convert at all from
        // the rate the device is running at now? A `startCapture` that cannot
        // must leave the session it was asked to replace running rather than
        // killing it on the way out, and the installer below cannot offer that
        // because it needs the bus free before its first attempt.
        //
        // A converter rather than a whole chain, because this answer is
        // discarded: the chain that ends up installed is the installer's, built
        // from the format the tap is actually given (RC-15).
        guard RealTimeDownConverter(
            sourceSampleRate: host.currentInputFormat.sampleRate,
            wireSampleRate: Self.wireSampleRate,
            maxInputFrames: Self.maxTapFrames
        ) != nil else {
            throw AudioPipelineError.converterUnavailable
        }

        // 3 — free the bus. Installing a second tap on a bus that already has
        // one is a hard error in AVAudioEngine; this is what makes a repeated
        // `startCapture` mean "restart". A rebuild has already done it.
        if !isRebuild {
            lock.lock()
            let staleTap = retireCaptureSessionLocked()
            generation = captureSessionGeneration
            lock.unlock()
            if staleTap { removeTap(from: host) }
        }

        // 4 — the install, under the engine lock and no other. **This is the
        // call that raises** (RC-16), so nothing whose loss would wedge a
        // caller may be held across it.
        //
        // A chain per capture session, owned by this session's tap alone. Its
        // rate comes from the input device and is never allowed to reach the
        // playback path (RC-7 Defect 1) — and because it is never shared, the
        // stateful converter inside it is only ever driven from the one thread
        // that drives this tap (RC-7 Defect 2).
        //
        // **The installer decides which format that is, not this method**
        // (RC-15). It installs with no format at all, then checks the chain
        // against what the node reports afterwards, so a device that changes
        // inside the window is retried rather than left driving a tap it does
        // not match. The tap body it installs is the only thing the render
        // thread does: no allocation, no lock, no caller code — see
        // CaptureTapProcessor.
        let outcome = withEngine(timeout: Self.engineLockTimeout) {
            Result {
                try CaptureTapInstaller.install(
                    host: host,
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
            }
        }
        guard let outcome else { throw AudioPipelineError.audioEngineBusy }
        let chain = try outcome.get()

        // 5 — commit the session's state, unless the session it was for has
        // been ended in the meantime. `stop()` does not wait for an install —
        // waiting is the whole fault — so it can land here, and an install that
        // committed over it would leave a tap running and a drain task
        // delivering audio to a caller who has already said stop.
        lock.lock()
        guard captureSessionGeneration == generation else {
            lock.unlock()
            removeTap(from: host)
            throw AudioPipelineError.captureInstallSuperseded
        }
        isCapturing = true
        captureChain = chain
        captureRing = chain.ring
        captureTask = Self.makeDrainTask(ring: chain.ring, sink: sink)
        if isRebuild {
            captureChainRebuilds += 1
        } else {
            // A new session, so a new count. Step 3 added the outgoing ring's
            // drops to the carry-over, which is what a *rebuild* wants and a
            // fresh start does not, so it is cleared here rather than there.
            droppedFramesFromRetiredRings = 0
            captureChainRebuilds = 0
            captureChainRebuildFailures = 0
        }
        lock.unlock()

        // 6 — start the engine, again with the state lock released.
        let startFailure: Error? = withEngine(timeout: Self.engineLockTimeout) { () -> Error? in
            guard !engine.isRunning else { return nil }
            do {
                try engine.start()
                return nil
            } catch {
                return error
            }
        } ?? AudioPipelineError.audioEngineBusy
        if let startFailure {
            // A tap installed on an engine that will not run delivers nothing
            // and hides the failure; take the session back down and report it.
            lock.lock()
            let staleTap = retireCaptureSessionLocked()
            lock.unlock()
            if staleTap { removeTap(from: host) }
            throw startFailure
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
        // Everything this needs, read under the state lock and worked from
        // outside it (RC-16). Note this method runs on the `engine` queue,
        // which is one of the three threads the orphaned lock deadlocked.
        lock.lock()
        let running = isCapturing
        let sink = captureSink
        let chain = captureChain
        // Reached only when a session is running: the nothing-to-rebuild branch
        // must not instantiate the input audio unit.
        let host = running ? tapHost : nil
        lock.unlock()

        guard running, let sink, let host else { return }

        if let chain, chain.matches(host.currentInputFormat) {
            // The formats agree, so the tap is still reading correctly. The
            // engine may still have been stopped by the reconfiguration,
            // though, and a stopped engine delivers no buffers at all.
            _ = withEngine(timeout: Self.responsiveEngineLockTimeout) {
                if !engine.isRunning {
                    try? engine.start()
                }
            }
            return
        }

        // **The stale tap comes down first, and unconditionally.** Not as part
        // of installing its replacement: building one can fail — CoreAudio may
        // refuse a converter for the device the system just moved to — and the
        // failure path must not be the one that leaves a tap reading through a
        // format description we already know is wrong. Silence is recoverable;
        // an out-of-bounds read on the audio thread is not. That is what the
        // `isRebuild` flag buys, in step 1 of the install.
        do {
            try installCaptureSession(sink: sink, isRebuild: true)
        } catch {
            // Capture is over. The caller finds out through the `.routeChanged`
            // signal published immediately after this, which for SF-3's sake it
            // has to act on anyway.
            lock.lock()
            captureChainRebuildFailures += 1
            lock.unlock()
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
    ///
    /// **Drops the frame rather than waiting** if the engine cannot be reached
    /// within ``responsiveEngineLockTimeout`` (RC-16). This is the method that
    /// used to block forever behind an orphaned lock, and it is called for
    /// every 20 ms of received audio — a path that waits here does not
    /// eventually recover, it stops the receive side dead. The drop is silent:
    /// received audio has no equivalent of ``droppedCaptureFrameCount``, and
    /// the condition it reports on is the pipeline being wedged, which
    /// ``startCapture(onFrame:)`` says out loud the moment it is asked for
    /// anything.
    public func enqueuePlayback(_ pcm: [Int16]) {
        guard !pcm.isEmpty else { return }

        // Under ``engineLock`` and not ``lock``: nothing here is capture-session
        // state — the playback chain, the engine and the player node are all
        // `let`s. Holding it across `makeBuffer` as well is deliberate twice
        // over: `PlaybackChain` wraps a stateful AVAudioConverter that
        // concurrent callers must not drive at once, and it keeps make and
        // schedule atomic, so two callers cannot schedule out of order.
        _ = withEngine(timeout: Self.responsiveEngineLockTimeout) {
            guard let buffer = playback.makeBuffer(wirePCM: pcm) else { return }

            if !engine.isRunning {
                try? engine.start()
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
            playerNode.scheduleBuffer(buffer, completionHandler: nil)
        }
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
    /// **Also the recovery from an install unwound by an `NSException`**
    /// (RC-16): it clears the in-flight claim such an unwind leaves behind, so
    /// a caller that saw ``AudioPipelineError/captureInstallInProgress`` for a
    /// reason it cannot see can stop and start again. `stop()` is the caller
    /// saying "abandon whatever is going on", which is exactly what a stale
    /// claim needs.
    public func stop() {
        lock.lock()
        let staleTap = retireCaptureSessionLocked()
        // No caller wants audio any more, so there is nothing for a
        // configuration change to rebuild (RC-14).
        captureSink = nil
        captureInstallInFlight = false
        let host = staleTap ? tapHost : nil
        lock.unlock()

        // The state above is now consistent whatever the graph does, which is
        // the point of doing it first: if the engine is unreachable this
        // returns having still ended the session, rather than blocking a
        // caller who has already said stop (RC-16).
        _ = withEngine(timeout: Self.responsiveEngineLockTimeout) {
            host?.removeTap()
            playerNode.stop()
            if engine.isRunning {
                engine.stop()
            }
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

    /// Puts a test double where the input node goes, so the install *sequence*
    /// can be driven with no engine, no device and no permission prompt (AU-5).
    ///
    /// Internal and test-only. Only meaningful before a capture starts: each
    /// install reads the host once, under ``lock``, and works from that
    /// reference for its whole run.
    ///
    /// This is the seam RC-16's regression test needs. What that test pins is
    /// that ``lock`` is not held across ``CaptureTapHost/installTap(bufferSize:body:)``
    /// — a fake host that calls back into the pipeline from inside its own
    /// install either answers or hangs, and the difference between those two is
    /// the difference between a reportable failure and a dead host app.
    func replaceTapHostForTesting(_ host: CaptureTapHost) {
        lock.lock()
        tapHost = host
        lock.unlock()
    }

    /// Leaves the capture-install claim set, the way an `NSException` unwinding
    /// out of AVFAudio leaves it: a raise runs no `defer`, so it releases
    /// nothing (RC-16).
    ///
    /// Internal and test-only. The raise itself cannot be staged in a test
    /// process — an exception no `catch` can intercept would take the runner
    /// down with it, which is the complaint rather than the test. What can be
    /// pinned is the state it leaves behind: every path out of it is bounded,
    /// and ``stop()`` is the way back.
    func orphanCaptureInstallClaimForTesting() {
        lock.lock()
        captureInstallInFlight = true
        lock.unlock()
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
