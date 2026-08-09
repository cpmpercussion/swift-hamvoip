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
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        process(channelZero: channels[0], frameCount: Int(buffer.frameLength))
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

    /// Guarded by ``lock``. The current (or most recent) capture session's ring.
    ///
    /// Deliberately **not** cleared by `stop()`: the dropped-frame count of the
    /// session that just ended is the number a caller most wants to read, and
    /// throwing it away the moment capture stops would hide exactly what it
    /// exists to reveal. `startCapture` replaces it.
    private var captureRing: RealTimeRingBuffer?

    /// Guarded by ``lock``. Drains ``captureRing`` at ordinary priority and
    /// calls the caller's `onFrame`. Cancelled by `stop()` and by a repeated
    /// `startCapture`.
    private var captureTask: Task<Void, Never>?

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
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // A converter per capture session, owned by this session's tap alone.
        // Its rate comes from the input device and is never allowed to reach
        // the playback path (RC-7 Defect 1) — and because it is never shared,
        // the stateful converter inside it is only ever driven from the one
        // thread that drives this tap (RC-7 Defect 2).
        guard let captureConverter = RealTimeDownConverter(
            sourceSampleRate: hardwareFormat.sampleRate,
            wireSampleRate: Self.wireSampleRate,
            maxInputFrames: Self.maxTapFrames
        ) else {
            throw AudioPipelineError.converterUnavailable
        }

        let ring = RealTimeRingBuffer(
            frameSize: Self.captureFrameSize,
            capacity: Self.captureRingCapacityFrames
        )
        let processor = CaptureTapProcessor(
            converter: captureConverter,
            ring: ring,
            channelStride: hardwareFormat.isInterleaved ? Int(hardwareFormat.channelCount) : 1
        )
        let sink = FrameSink(deliver: onFrame)

        lock.lock()
        defer { lock.unlock() }

        // Installing a second tap on a bus that already has one is a hard
        // error in AVAudioEngine; make a repeated startCapture mean "restart".
        if isCapturing {
            inputNode.removeTap(onBus: 0)
            isCapturing = false
        }
        captureTask?.cancel()
        captureTask = nil

        // The only thing the render thread does. No allocation, no lock, no
        // caller code — see CaptureTapProcessor.
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: hardwareFormat
        ) { buffer, _ in
            processor.process(buffer)
        }
        isCapturing = true
        captureRing = ring
        captureTask = Self.makeDrainTask(ring: ring, sink: sink)

        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            inputNode.removeTap(onBus: 0)
            isCapturing = false
            captureTask?.cancel()
            captureTask = nil
            throw error
        }
    }

    /// Frames the microphone tap had to discard because the ring filled up —
    /// i.e. because whatever `onFrame` does could not keep up with real time.
    ///
    /// Zero is the only good value. A non-zero value is lost transmit audio and
    /// nothing else; it is reported rather than hidden because a silent gap is
    /// indistinguishable, from the operator's chair, from a bad network path.
    /// Resets when ``startCapture(onFrame:)`` begins a new session; survives
    /// ``stop()`` so the session that just ended can still be inspected.
    public var droppedCaptureFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captureRing?.droppedFrameCount ?? 0
    }

    /// Frames currently sitting in the capture ring, waiting for the drain
    /// task. Useful as a health signal in CLI-1: it should hover near zero.
    public var pendingCaptureFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captureRing?.availableFrames ?? 0
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

        captureTask?.cancel()
        captureTask = nil

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
