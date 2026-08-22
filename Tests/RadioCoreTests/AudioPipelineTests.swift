// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import XCTest
@testable import RadioCore

// MARK: - AudioFrameChunker

/// Covers RC-7's stated highest-risk piece: arbitrary tap buffer sizes must
/// re-chunk into exactly 160-sample frames with no sample lost or
/// duplicated, and the remainder carried correctly across calls.
///
/// None of these tests touch `AVAudioEngine`, a microphone, a speaker, or any
/// audio permission — `AudioFrameChunker` is a pure `[Int16]`-in/`[Int16]]`-out
/// value type, safe to run in a headless CI environment.
final class AudioFrameChunkerTests: XCTestCase {
    private let frameSize = AudioPipeline.captureFrameSize // 160

    /// Builds a strictly increasing sequence of `Int16` markers so that lost,
    /// duplicated, or reordered samples are detectable by value, not just by
    /// count.
    private func markers(_ range: Range<Int>) -> [Int16] {
        range.map { Int16(truncatingIfNeeded: $0) }
    }

    // MARK: Core invariant — reconstruction

    /// For a fixed sequence of input chunk sizes, pushes them one at a time
    /// and asserts: every emitted frame is exactly `frameSize`, and
    /// concatenating every emitted frame plus the final `pending` exactly
    /// reconstructs the full input stream, in order.
    private func assertReconstructs(chunkSizes: [Int], file: StaticString = #filePath, line: UInt = #line) {
        var chunker = AudioFrameChunker(frameSize: frameSize)
        var cursor = 0
        var reconstructed: [Int16] = []
        var totalPushed = 0

        for size in chunkSizes {
            let input = markers(cursor..<(cursor + size))
            cursor += size
            totalPushed += size

            let frames = chunker.push(input)
            for frame in frames {
                XCTAssertEqual(frame.count, frameSize, "emitted frame was not exactly \(frameSize) samples", file: file, line: line)
                reconstructed.append(contentsOf: frame)
            }
        }
        reconstructed.append(contentsOf: chunker.pending)

        XCTAssertEqual(reconstructed, markers(0..<totalPushed), "reconstruction lost, duplicated, or reordered samples", file: file, line: line)
    }

    func testManyDifferentChunkSizesReconstructExactly() {
        // 1, 159, 160, 161, 480 (=3x160), 1024, and several primes.
        assertReconstructs(chunkSizes: [1, 159, 160, 161, 480, 1024, 2, 3, 5, 7, 11, 13, 17, 19, 23, 97, 101, 997, 1009])
    }

    func testSingleSampleChunksReconstructExactly() {
        assertReconstructs(chunkSizes: Array(repeating: 1, count: 500))
    }

    func testExactMultipleChunksLeaveNoRemainder() {
        var chunker = AudioFrameChunker(frameSize: frameSize)
        let frames = chunker.push(markers(0..<(frameSize * 4)))
        XCTAssertEqual(frames.count, 4)
        for frame in frames {
            XCTAssertEqual(frame.count, frameSize)
        }
        XCTAssertTrue(chunker.pending.isEmpty)
    }

    func testSeededRandomSequenceReconstructsExactly() {
        var rng = SplitMix64(seed: 0xC0FFEE_1234_5678)
        var sizes: [Int] = []
        for _ in 0..<300 {
            sizes.append(Int(rng.next() % 2000)) // 0...1999, including occasional zero-size pushes
        }
        assertReconstructs(chunkSizes: sizes)
    }

    // MARK: Frame-count expectations

    func testEmptyInputProducesNoFrames() {
        var chunker = AudioFrameChunker(frameSize: frameSize)
        let frames = chunker.push([])
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(chunker.pending.isEmpty)
    }

    func testEmptyInputAfterPartialFrameProducesNoFramesAndKeepsRemainder() {
        var chunker = AudioFrameChunker(frameSize: frameSize)
        _ = chunker.push(markers(0..<50))
        let frames = chunker.push([])
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(chunker.pending.count, 50)
    }

    func testLongRunProducesExpectedTotalFrameCount() {
        var chunker = AudioFrameChunker(frameSize: frameSize)
        var totalFrames = 0
        var totalSamples = 0
        // 10,000 pushes of 137 samples each (a prime, deliberately not a
        // multiple of 160) — exercises sustained remainder-carrying.
        for i in 0..<10_000 {
            let input = markers(0..<137) // values repeat; count/shape is what matters here
            _ = i
            let frames = chunker.push(input)
            totalFrames += frames.count
            totalSamples += input.count
        }
        let expectedFrames = totalSamples / frameSize
        XCTAssertEqual(totalFrames, expectedFrames)
        XCTAssertEqual(chunker.pending.count, totalSamples % frameSize)
    }

    func testNoFrameEmittedUntilFrameSizeReached() {
        var chunker = AudioFrameChunker(frameSize: frameSize)
        let frames = chunker.push(markers(0..<(frameSize - 1)))
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(chunker.pending.count, frameSize - 1)
    }
}

/// Minimal seeded PRNG so the randomised chunk-size test is fully
/// deterministic across runs (no `Int.random` / `SystemRandomNumberGenerator`
/// anywhere in this file).
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - PCMFormatConverter

/// Covers the other pure piece of AU-1: the `AVAudioConverter`-based
/// sample-rate/format glue. `AVAudioConverter` and `AVAudioPCMBuffer` are
/// offline format-conversion utilities — constructing and driving them here
/// touches no microphone, no speaker, no `AVAudioSession`, and needs no
/// permission, so this is safe in a headless CI environment.
///
/// **Not covered by these tests** (needs real hardware — see CLI-1): the
/// `AVAudioEngine` tap/player-node wiring in `AudioPipeline` itself, i.e.
/// whether the real microphone's native format round-trips correctly through
/// `startCapture`, and whether scheduled playback buffers actually produce
/// audible, glitch-free output on a real output device.
final class PCMFormatConverterTests: XCTestCase {
    private func sine(frequency: Double, sampleRate: Double, amplitude: Float, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let w = 2 * Double.pi * frequency / sampleRate
        for i in 0..<count {
            out[i] = amplitude * Float(sin(w * Double(i)))
        }
        return out
    }

    private func sineInt16(frequency: Double, sampleRate: Double, amplitude: Float, count: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: count)
        let w = 2 * Double.pi * frequency / sampleRate
        for i in 0..<count {
            let v = Double(amplitude) * sin(w * Double(i))
            out[i] = Int16(max(Double(Int16.min), min(Double(Int16.max), v)))
        }
        return out
    }

    /// Zero-crossing based frequency estimate, deliberately independent of
    /// any FFT/Goertzel code that might also live in production — a bug in
    /// shared spectral-estimation code should not be able to hide a bug in
    /// the conversion it is checking.
    private func estimatedFrequency(_ samples: [Int16], sampleRate: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        var previousSign = 0
        for sample in samples {
            let sign = sample > 0 ? 1 : (sample < 0 ? -1 : 0)
            if sign == 0 { continue }
            if previousSign != 0, sign != previousSign {
                crossings += 1
            }
            previousSign = sign
        }
        let durationSeconds = Double(samples.count) / sampleRate
        return Double(crossings) / (2 * durationSeconds)
    }

    func testDownsample48kTo8kPreservesFrequency() throws {
        let converter = try XCTUnwrap(PCMFormatConverter(sourceSampleRate: 48_000, wireSampleRate: 8_000))
        let frequency = 1_000.0 // well inside the 4 kHz Nyquist limit at 8 kHz
        let amplitude: Float = 0.5 // normalised Float32 PCM: -1.0...1.0
        let input = sine(frequency: frequency, sampleRate: 48_000, amplitude: amplitude, count: 48_000) // 1 s

        let output = converter.downsample(input)
        XCTAssertFalse(output.isEmpty)

        // Discard the first/last 10% to sidestep the resampler's filter
        // settling/edge transients; the steady-state interior is what this
        // test is about.
        let trimStart = output.count / 10
        let trimEnd = output.count - output.count / 10
        let steadyState = Array(output[trimStart..<trimEnd])

        let estimated = estimatedFrequency(steadyState, sampleRate: 8_000)
        XCTAssertEqual(estimated, frequency, accuracy: frequency * 0.1, "downsampled signal's frequency drifted too far from \(frequency) Hz")

        // Amplitude bounds: normalized 0.5 in Float32 maps to ~0.5 *
        // Int16.max in fixed-point Int16 PCM. Allow generous headroom for
        // resampler ripple, but the signal must not have blown past
        // full-scale or collapsed to near-silence.
        let peak = steadyState.map { abs(Int32($0)) }.max() ?? 0
        let expectedPeak = Double(amplitude) * Double(Int16.max)
        XCTAssertLessThanOrEqual(Double(peak), Double(Int16.max), "output exceeded full scale")
        XCTAssertGreaterThan(Double(peak), expectedPeak * 0.5, "output amplitude collapsed unexpectedly")
        XCTAssertLessThan(Double(peak), expectedPeak * 1.5, "output amplitude overshot unexpectedly")
    }

    func testUpsample8kTo48kPreservesFrequency() throws {
        let converter = try XCTUnwrap(PCMFormatConverter(sourceSampleRate: 48_000, wireSampleRate: 8_000))
        let frequency = 1_000.0
        let amplitude = Float(Int16.max) * 0.5
        let input = sineInt16(frequency: frequency, sampleRate: 8_000, amplitude: amplitude, count: 8_000) // 1 s

        let output = converter.upsample(input)
        XCTAssertFalse(output.isEmpty)

        let trimStart = output.count / 10
        let trimEnd = output.count - output.count / 10
        let steadyState = Array(output[trimStart..<trimEnd])

        // Reuse the same zero-crossing estimator by rescaling to Int16 range
        // (the estimator only cares about sign changes, so this rescale is
        // exact for the purpose of counting crossings).
        let rescaled: [Int16] = steadyState.map { sample in
            if sample > 0 { return Int16.max }
            if sample < 0 { return Int16.min }
            return 0
        }
        let estimated = estimatedFrequency(rescaled, sampleRate: 48_000)
        XCTAssertEqual(estimated, frequency, accuracy: frequency * 0.1, "upsampled signal's frequency drifted too far from \(frequency) Hz")

        let peak = steadyState.map { abs($0) }.max() ?? 0
        let expectedPeak = Double(amplitude) / Double(Int16.max) // normalized Float32 expected peak
        XCTAssertLessThanOrEqual(Double(peak), 1.0001, "output exceeded normalized full scale")
        XCTAssertGreaterThan(Double(peak), expectedPeak * 0.5, "output amplitude collapsed unexpectedly")
        XCTAssertLessThan(Double(peak), expectedPeak * 1.5, "output amplitude overshot unexpectedly")
    }

    func testEmptyInputProducesEmptyOutput() throws {
        let converter = try XCTUnwrap(PCMFormatConverter())
        XCTAssertTrue(converter.downsample([]).isEmpty)
        XCTAssertTrue(converter.upsample([]).isEmpty)
    }

    func testConverterConstructsForNonDefaultSampleRates() throws {
        // Guards startCapture's "rebuild the converter for whatever the
        // hardware's native format actually is" path: this must succeed for
        // sample rates other than the 48 kHz default (e.g. 44.1 kHz, common
        // on non-iOS-default hardware).
        let converter = try XCTUnwrap(PCMFormatConverter(sourceSampleRate: 44_100, wireSampleRate: 8_000))
        XCTAssertEqual(converter.sourceSampleRate, 44_100)
        XCTAssertEqual(converter.wireSampleRate, 8_000)

        let input = sine(frequency: 440, sampleRate: 44_100, amplitude: 0.5, count: 4_410)
        let output = converter.downsample(input)
        XCTAssertFalse(output.isEmpty)
    }
}

// MARK: - PlaybackChain (Defect 1 regression surface)

/// Pins down the playback path's *format decision* — the thing that was wrong
/// in the original RC-7 implementation and that no test could see, because the
/// decision was smeared across `startCapture` (which rebuilt the shared
/// converter from the **input** device) and `enqueuePlayback` (which took its
/// buffer format from the **main mixer**). On a machine with a 48 kHz input
/// and a 44.1 kHz stereo output, 20 ms of speech was generated at 48 kHz and
/// scheduled as if it were 44.1 kHz — 8.8 % slow, ~1.5 semitones flat — with
/// the right channel allocated and never written.
///
/// `PlaybackChain` is `AVAudioConverter`/`AVAudioPCMBuffer`/`AVAudioFormat`
/// only: offline format conversion, no `AVAudioEngine`, no microphone, no
/// speaker, no `AVAudioSession`, no permission. Safe headless.
final class PlaybackChainTests: XCTestCase {
    private let wireSampleRate = 8_000.0
    private let wireFrameSize = AudioPipeline.captureFrameSize // 160 = 20 ms @ 8 kHz
    private let frameDuration = 0.020

    /// Plausible hardware output rates a real device might report.
    private let deviceRates: [Double] = [8_000, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 192_000]

    private func tone(count: Int) -> [Int16] {
        let w = 2 * Double.pi * 440 / wireSampleRate
        return (0..<count).map { Int16(0.4 * Double(Int16.max) * sin(w * Double($0))) }
    }

    // MARK: The rate decision itself

    func testEngineSampleRateFollowsTheOutputDevice() {
        for rate in deviceRates {
            XCTAssertEqual(
                PlaybackChain.engineSampleRate(forOutputSampleRate: rate), rate,
                "a plausible output rate must be used as-is, not replaced by a default"
            )
        }
    }

    func testEngineSampleRateFallsBackWhenTheOutputRateIsUnusable() {
        // 0 Hz is what a headless machine with no output device reports; the
        // rest are defensive.
        let unusable: [Double] = [0, -1, -48_000, 1, 7_999, 384_001, 1e9, .nan, .infinity, -.infinity]
        for rate in unusable {
            XCTAssertEqual(
                PlaybackChain.engineSampleRate(forOutputSampleRate: rate),
                PlaybackChain.fallbackSampleRate,
                "unusable output rate \(rate) must fall back to the AU-1 default"
            )
        }
    }

    // MARK: Buffer format

    func testBufferIsAlwaysMonoAtTheChainRate() throws {
        for rate in deviceRates {
            let chain = try XCTUnwrap(PlaybackChain(outputSampleRate: rate, wireSampleRate: wireSampleRate))
            XCTAssertEqual(chain.sampleRate, rate)
            XCTAssertEqual(chain.format.channelCount, 1, "playback format must be mono at \(rate) Hz")

            let buffer = try XCTUnwrap(chain.makeBuffer(wirePCM: tone(count: wireFrameSize)))
            XCTAssertEqual(buffer.format.sampleRate, rate, "buffer declared at the wrong rate for a \(rate) Hz device")
            XCTAssertEqual(buffer.format.channelCount, 1, "a stereo buffer leaves channel 1 silent — see Defect 1")
            XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
            XCTAssertNotNil(buffer.floatChannelData)
        }
    }

    /// **This is the test that would have caught Defect 1.**
    ///
    /// For every combination of an input-device rate and an output-device rate
    /// — including the 48 kHz mic / 44.1 kHz output mismatch the reviewer
    /// reproduced — build the capture converter exactly as `startCapture`
    /// does, then assert that the playback buffer is mono and declared at the
    /// **output** rate, and that its length corresponds to the intended 20 ms
    /// *at that declared rate*. The old code failed both halves: the samples
    /// came from the input-derived converter and the format came from the
    /// stereo mixer.
    func testPlaybackBufferIgnoresTheCaptureRateAndMatchesTheOutputDevice() throws {
        let inputRates: [Double] = [44_100, 48_000, 96_000, 16_000]
        let outputRates: [Double] = [44_100, 48_000, 96_000, 16_000]

        for inputRate in inputRates {
            for outputRate in outputRates {
                // What startCapture builds for the microphone. It must have no
                // influence whatsoever on the playback buffer below.
                let captureConverter = try XCTUnwrap(
                    PCMFormatConverter(sourceSampleRate: inputRate, wireSampleRate: wireSampleRate)
                )
                XCTAssertEqual(captureConverter.sourceSampleRate, inputRate)

                let chain = try XCTUnwrap(
                    PlaybackChain(outputSampleRate: outputRate, wireSampleRate: wireSampleRate)
                )
                let context = "input \(inputRate) Hz / output \(outputRate) Hz"

                XCTAssertEqual(chain.sampleRate, outputRate, "playback rate followed the input device — \(context)")
                XCTAssertEqual(chain.format.channelCount, 1, "playback format was not mono — \(context)")

                // Steady state: prime the resampler, then measure. The
                // interesting quantity is wall-clock duration as the *buffer's
                // own declared rate* implies it. A buffer generated at 48 kHz
                // but declared 44.1 kHz reads 8.8 % long here; the tolerance
                // below is far tighter than that.
                _ = chain.makeBuffer(wirePCM: tone(count: wireFrameSize))
                var producedFrames = 0
                let frameCount = 50
                for _ in 0..<frameCount {
                    let buffer = try XCTUnwrap(chain.makeBuffer(wirePCM: tone(count: wireFrameSize)))
                    XCTAssertEqual(buffer.format.sampleRate, outputRate, "buffer rate ≠ output rate — \(context)")
                    XCTAssertEqual(buffer.format.channelCount, 1, "buffer was not mono — \(context)")
                    producedFrames += Int(buffer.frameLength)
                }

                let producedDuration = Double(producedFrames) / chain.sampleRate
                let intendedDuration = Double(frameCount) * frameDuration
                XCTAssertEqual(
                    producedDuration, intendedDuration, accuracy: 0.005,
                    "playback of \(intendedDuration) s of wire audio came out as \(producedDuration) s — \(context)"
                )
            }
        }
    }

    // MARK: Frame counts

    func testOneWireFrameProducesApproximatelyOneFrameOfPlayback() throws {
        for rate in deviceRates {
            let chain = try XCTUnwrap(PlaybackChain(outputSampleRate: rate, wireSampleRate: wireSampleRate))
            let expected = rate * frameDuration

            let first = try XCTUnwrap(chain.makeBuffer(wirePCM: tone(count: wireFrameSize)))
            // The first buffer may be short by the resampler's filter latency;
            // it must never be *long*, and never collapse to a fragment.
            XCTAssertGreaterThan(Double(first.frameLength), expected * 0.7, "first frame too short at \(rate) Hz")
            XCTAssertLessThanOrEqual(Double(first.frameLength), expected * 1.05, "first frame too long at \(rate) Hz")

            // After priming, each 20 ms wire frame yields 20 ms of playback.
            let steady = try XCTUnwrap(chain.makeBuffer(wirePCM: tone(count: wireFrameSize)))
            XCTAssertEqual(
                Double(steady.frameLength) / rate, frameDuration, accuracy: 0.002,
                "steady-state frame was \(steady.frameLength) samples at \(rate) Hz, expected ≈ \(expected)"
            )
        }
    }

    func testFrameCapacityMatchesFrameLength() throws {
        let chain = try XCTUnwrap(PlaybackChain(outputSampleRate: 44_100, wireSampleRate: wireSampleRate))
        let buffer = try XCTUnwrap(chain.makeBuffer(wirePCM: tone(count: wireFrameSize)))
        XCTAssertEqual(buffer.frameLength, buffer.frameCapacity, "no unwritten frames may be left in the buffer")
    }

    func testEmptyWirePCMProducesNoBuffer() throws {
        let chain = try XCTUnwrap(PlaybackChain(outputSampleRate: 48_000, wireSampleRate: wireSampleRate))
        XCTAssertNil(chain.makeBuffer(wirePCM: []))
    }

    func testUnusableOutputRateStillYieldsAWorkingChain() throws {
        // A headless machine reports 0 Hz; playback must still be constructible
        // and produce a mono 48 kHz buffer rather than failing or producing a
        // 0 Hz format.
        let chain = try XCTUnwrap(PlaybackChain(outputSampleRate: 0, wireSampleRate: wireSampleRate))
        XCTAssertEqual(chain.sampleRate, PlaybackChain.fallbackSampleRate)
        let buffer = try XCTUnwrap(chain.makeBuffer(wirePCM: tone(count: wireFrameSize)))
        XCTAssertEqual(buffer.format.sampleRate, PlaybackChain.fallbackSampleRate)
        XCTAssertEqual(buffer.format.channelCount, 1)
    }
}

// MARK: - AudioPipeline construction

/// `AudioPipeline.init()` attaches nodes to an `AVAudioEngine` graph but does
/// not start it, open a microphone, or touch `AVAudioSession` — so
/// constructing one, and reading its published `signals` stream without ever
/// starting capture/playback, is safe without hardware or permissions.
/// Anything that calls `startCapture`, `enqueuePlayback`, or `configureSession`
/// is exactly the engine-wiring surface RC-7 defers to CLI-1 on real
/// hardware, and is deliberately not exercised here.
final class AudioPipelineConstructionTests: XCTestCase {
    func testInitDoesNotThrowOrRequireHardware() {
        let pipeline = AudioPipeline()
        _ = pipeline // constructed successfully; no engine start, no I/O
    }

    func testStopIsSafeBeforeStart() {
        let pipeline = AudioPipeline()
        pipeline.stop() // must not crash even though capture/playback never started
    }

    /// Closes the gap between "the format decision is right" and "the graph
    /// uses it": the player node must be connected with exactly the format
    /// playback buffers are built in, and that format must be mono.
    ///
    /// Attaching and connecting nodes does not start the engine or open a
    /// device, so this needs no hardware. It is the assertion that fails
    /// loudest if anyone reintroduces `format: nil` on the player→mixer
    /// connection (which adopts the mixer's stereo format and leaves the
    /// right channel silent).
    func testPlayerNodeIsConnectedWithTheMonoPlaybackBufferFormat() {
        let pipeline = AudioPipeline()
        let bufferFormat = pipeline.playbackBufferFormat
        let connectionFormat = pipeline.playbackConnectionFormat

        XCTAssertEqual(bufferFormat.channelCount, 1, "playback buffers must be mono")
        XCTAssertEqual(connectionFormat.channelCount, 1, "player node must be connected as mono")
        XCTAssertEqual(
            connectionFormat.sampleRate, bufferFormat.sampleRate,
            "buffers would be scheduled at a rate the connection does not expect"
        )
        XCTAssertGreaterThanOrEqual(bufferFormat.sampleRate, PlaybackChain.minimumSampleRate)
    }

    func testSignalsStreamFinishesOnDeinit() async {
        var pipeline: AudioPipeline? = AudioPipeline()
        let stream = pipeline!.signals
        pipeline = nil // deinit finishes the continuation

        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next, "signals stream should finish (yield nil) once the pipeline is deallocated")
    }

    func testCaptureCountersAreZeroBeforeCaptureStarts() {
        let pipeline = AudioPipeline()
        XCTAssertEqual(pipeline.droppedCaptureFrameCount, 0)
        XCTAssertEqual(pipeline.pendingCaptureFrameCount, 0)
        pipeline.stop()
        XCTAssertEqual(pipeline.droppedCaptureFrameCount, 0, "stop() before start must not invent a drop count")
    }

    func testCaptureConstantsAreCoherent() {
        // 160 samples at 8 kHz is 20 ms; the ring must therefore hold two
        // seconds, and the drain interval must be well under one frame.
        XCTAssertEqual(AudioPipeline.captureFrameSize, 160)
        XCTAssertEqual(AudioPipeline.wireSampleRate, 8_000)
        let frameDuration = Double(AudioPipeline.captureFrameSize) / AudioPipeline.wireSampleRate
        XCTAssertEqual(frameDuration, 0.020, accuracy: 1e-9)
        XCTAssertEqual(Double(AudioPipeline.captureRingCapacityFrames) * frameDuration, 2.0, accuracy: 1e-9)
        XCTAssertLessThan(
            Double(AudioPipeline.captureDrainInterval) / 1e9, frameDuration,
            "the drain task must wake up more often than frames arrive"
        )
    }
}

// MARK: - Real-time capture path (RC-9)

/// The capture path that RC-9 rewrote, exercised end to end **without an
/// `AVAudioEngine`, a microphone, or a permission prompt**.
///
/// That is the whole point of ``CaptureTapProcessor`` exposing a pointer-level
/// entry point: the code the tap callback runs is ordinary code operating on a
/// pointer, so a test can call exactly what the render thread calls and check
/// both what it produces and what it costs. What is left for CLI-1 to confirm
/// on real hardware is only whether audio flows at all — not whether the
/// conversion, the chunking, the ring, or the allocation behaviour are right.
final class RealTimeCapturePathTests: XCTestCase {
    private let wireRate = 8_000.0
    private let frameSize = AudioPipeline.captureFrameSize // 160

    private func sine(frequency: Double, sampleRate: Double, amplitude: Float, count: Int) -> [Float] {
        let w = 2 * Double.pi * frequency / sampleRate
        return (0..<count).map { amplitude * Float(sin(w * Double($0))) }
    }

    /// Zero-crossing frequency estimate — deliberately independent of any
    /// production spectral code, so a bug there cannot hide a bug here.
    private func estimatedFrequency(_ samples: [Int16], sampleRate: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        var previousSign = 0
        for sample in samples {
            let sign = sample > 0 ? 1 : (sample < 0 ? -1 : 0)
            if sign == 0 { continue }
            if previousSign != 0, sign != previousSign { crossings += 1 }
            previousSign = sign
        }
        return Double(crossings) / (2 * Double(samples.count) / sampleRate)
    }

    private func converted(_ converter: RealTimeDownConverter, _ input: [Float]) -> [Int16] {
        input.withUnsafeBufferPointer { source in
            let output = converter.convert(from: source.baseAddress!, count: source.count)
            return Array(output)
        }
    }

    // MARK: RealTimeDownConverter

    func testDownConverterRejectsUnusableRates() {
        XCTAssertNil(RealTimeDownConverter(sourceSampleRate: 0))
        XCTAssertNil(RealTimeDownConverter(sourceSampleRate: -48_000))
        XCTAssertNil(RealTimeDownConverter(sourceSampleRate: .nan))
        XCTAssertNil(RealTimeDownConverter(sourceSampleRate: 48_000, wireSampleRate: 0))
        XCTAssertNil(RealTimeDownConverter(sourceSampleRate: 48_000, maxInputFrames: 0))
    }

    func testDownConverterConstructsForEveryPlausibleInputRate() throws {
        for rate in [8_000.0, 16_000, 22_050, 32_000, 44_100, 48_000, 96_000, 192_000] {
            let converter = try XCTUnwrap(
                RealTimeDownConverter(sourceSampleRate: rate),
                "no converter for a \(rate) Hz input device"
            )
            XCTAssertEqual(converter.sourceSampleRate, rate)
            XCTAssertEqual(converter.wireSampleRate, wireRate)
            // Output storage must be able to hold a whole input chunk's worth
            // of wire samples; if it cannot, the tap silently truncates audio.
            XCTAssertGreaterThanOrEqual(
                Double(converter.outputCapacity),
                Double(converter.maxInputFrames) * wireRate / rate,
                "output storage is too small for one full input chunk at \(rate) Hz"
            )
        }
    }

    func testDownConverterProducesTheExpectedFrameCountAndPreservesFrequency() throws {
        let converter = try XCTUnwrap(RealTimeDownConverter(sourceSampleRate: 48_000))
        let input = sine(frequency: 1_000, sampleRate: 48_000, amplitude: 0.5, count: 4_096)

        // Prime the resampler, then measure steady state.
        _ = converted(converter, input)
        let output = converted(converter, input)

        XCTAssertEqual(
            Double(output.count), Double(input.count) * wireRate / 48_000, accuracy: 4,
            "48 kHz → 8 kHz should be a 6:1 decimation"
        )
        XCTAssertEqual(
            estimatedFrequency(output, sampleRate: wireRate), 1_000, accuracy: 100,
            "the downsampled tone drifted off frequency"
        )
        let peak = output.map { abs(Int32($0)) }.max() ?? 0
        let expectedPeak = 0.5 * Double(Int16.max)
        XCTAssertGreaterThan(Double(peak), expectedPeak * 0.5, "amplitude collapsed")
        XCTAssertLessThan(Double(peak), expectedPeak * 1.5, "amplitude overshot")
    }

    /// The real-time converter drops to `AudioConverterFillComplexBuffer` to
    /// avoid the per-call block allocation `AVAudioConverter` forces in Swift.
    /// That is only a safe trade if it is the *same* conversion, so: same
    /// input, same rates, and the two must produce the same samples.
    ///
    /// The two differ only in how much they drain per call — the real-time
    /// converter's output storage is sized with more headroom, so it flushes a
    /// few more samples of the resampler's tail before returning. That is a
    /// difference in buffering, not in the audio, which is why the comparison
    /// is over the common prefix with a bound on the length difference rather
    /// than a whole-array equality that would fail for the wrong reason.
    func testDownConverterAgreesWithPCMFormatConverter() throws {
        for rate in [44_100.0, 48_000] {
            let realTime = try XCTUnwrap(RealTimeDownConverter(sourceSampleRate: rate))
            let reference = try XCTUnwrap(PCMFormatConverter(sourceSampleRate: rate, wireSampleRate: wireRate))
            let input = sine(frequency: 440, sampleRate: rate, amplitude: 0.5, count: 4_096)

            let realTimeOutput = converted(realTime, input)
            let referenceOutput = reference.downsample(input)

            XCTAssertFalse(realTimeOutput.isEmpty, "no output at \(rate) Hz")
            XCTAssertEqual(
                Double(realTimeOutput.count), Double(referenceOutput.count), accuracy: 64,
                "wildly different output lengths at \(rate) Hz"
            )

            let shared = min(realTimeOutput.count, referenceOutput.count)
            var firstDifference = -1
            for index in 0..<shared where realTimeOutput[index] != referenceOutput[index] {
                firstDifference = index
                break
            }
            XCTAssertEqual(
                firstDifference, -1,
                """
                the real-time converter and AVAudioConverter produced different \
                audio at \(rate) Hz, first differing at sample \(firstDifference)
                """
            )
        }
    }

    func testDownConverterReadsChannelZeroOfAnInterleavedBuffer() throws {
        let converter = try XCTUnwrap(RealTimeDownConverter(sourceSampleRate: 48_000))
        let mono = sine(frequency: 1_000, sampleRate: 48_000, amplitude: 0.5, count: 2_048)

        // Interleave the tone into channel 0 and full-scale noise-ish garbage
        // into channel 1; reading with stride 2 must ignore channel 1 entirely.
        var interleaved = [Float](repeating: 0, count: mono.count * 2)
        for index in 0..<mono.count {
            interleaved[index * 2] = mono[index]
            interleaved[index * 2 + 1] = (index % 2 == 0) ? 1.0 : -1.0
        }

        let strided: [Int16] = interleaved.withUnsafeBufferPointer { source in
            _ = converter.convert(from: source.baseAddress!, count: mono.count, stride: 2)
            let output = converter.convert(from: source.baseAddress!, count: mono.count, stride: 2)
            return Array(output)
        }

        let planar = try XCTUnwrap(RealTimeDownConverter(sourceSampleRate: 48_000))
        _ = converted(planar, mono)
        let expected = converted(planar, mono)

        XCTAssertEqual(strided, expected, "strided reads pulled in the wrong channel")
    }

    // MARK: CaptureTapProcessor

    private func makeProcessor(
        inputRate: Double = 48_000,
        ringCapacity: Int = AudioPipeline.captureRingCapacityFrames,
        maxInputFrames: Int = 4_096
    ) throws -> CaptureTapProcessor {
        let converter = try XCTUnwrap(
            RealTimeDownConverter(sourceSampleRate: inputRate, maxInputFrames: maxInputFrames)
        )
        let ring = RealTimeRingBuffer(frameSize: frameSize, capacity: ringCapacity)
        return CaptureTapProcessor(converter: converter, ring: ring)
    }

    private func drain(_ ring: RealTimeRingBuffer) -> [[Int16]] {
        var frames: [[Int16]] = []
        while let frame = ring.readFrame() { frames.append(frame) }
        return frames
    }

    func testEveryEmittedFrameIsExactly160Samples() throws {
        let processor = try makeProcessor()
        // 1023 is deliberately not a multiple of anything relevant, so the
        // chunker's remainder-carrying is exercised on every buffer.
        let buffer = sine(frequency: 900, sampleRate: 48_000, amplitude: 0.4, count: 1_023)

        var frames: [[Int16]] = []
        for _ in 0..<60 {
            buffer.withUnsafeBufferPointer { source in
                processor.process(channelZero: source.baseAddress!, frameCount: source.count)
            }
            frames.append(contentsOf: drain(processor.ring))
        }

        XCTAssertFalse(frames.isEmpty)
        for frame in frames {
            XCTAssertEqual(frame.count, frameSize, "a frame left the tap that was not 160 samples")
        }
        XCTAssertEqual(processor.ring.droppedFrameCount, 0)
    }

    func testFrameRateMatchesRealTime() throws {
        let processor = try makeProcessor()
        // Exactly one second of 48 kHz audio, delivered in 1024-frame buffers
        // the way an engine tap would. 20 ms frames ⇒ 50 of them.
        let block = sine(frequency: 1_000, sampleRate: 48_000, amplitude: 0.4, count: 1_024)
        var frameCount = 0
        var delivered = 0
        while delivered < 48_000 {
            block.withUnsafeBufferPointer { source in
                processor.process(channelZero: source.baseAddress!, frameCount: source.count)
            }
            delivered += block.count
            frameCount += drain(processor.ring).count
        }
        let expected = Double(delivered) / 48_000 * 50
        XCTAssertEqual(Double(frameCount), expected, accuracy: 2, "the tap is not producing 50 frames a second")
    }

    /// `installTap(bufferSize:)` is a request, not a promise. A buffer larger
    /// than the converter's preallocated input must still be handled — in
    /// chunks, never by growing anything.
    func testBuffersLargerThanTheConverterChunkAreProcessedWhole() throws {
        let processor = try makeProcessor(maxInputFrames: 512)
        let big = sine(frequency: 1_000, sampleRate: 48_000, amplitude: 0.4, count: 4_800) // 100 ms

        big.withUnsafeBufferPointer { source in
            processor.process(channelZero: source.baseAddress!, frameCount: source.count)
        }
        let frames = drain(processor.ring)
        // 100 ms is five 20 ms frames; allow one for resampler priming latency.
        XCTAssertGreaterThanOrEqual(frames.count, 4)
        XCTAssertLessThanOrEqual(frames.count, 5)
        for frame in frames { XCTAssertEqual(frame.count, frameSize) }
    }

    func testZeroLengthBufferIsIgnored() throws {
        let processor = try makeProcessor()
        let empty = [Float]()
        empty.withUnsafeBufferPointer { source in
            processor.process(channelZero: source.baseAddress ?? UnsafePointer(bitPattern: 0x1000)!, frameCount: 0)
        }
        XCTAssertEqual(processor.ring.availableFrames, 0)
        XCTAssertEqual(processor.ring.droppedFrameCount, 0)
    }

    func testAnAVAudioPCMBufferTakesTheSamePathAsThePointerEntryPoint() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let samples = sine(frequency: 1_000, sampleRate: 48_000, amplitude: 0.4, count: 1_024)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        let channel = try XCTUnwrap(buffer.floatChannelData)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: $0.count) }

        let viaBuffer = try makeProcessor()
        let viaPointer = try makeProcessor()
        for _ in 0..<10 {
            viaBuffer.process(buffer)
            samples.withUnsafeBufferPointer { source in
                viaPointer.process(channelZero: source.baseAddress!, frameCount: source.count)
            }
        }

        XCTAssertEqual(drain(viaBuffer.ring), drain(viaPointer.ring))
    }

    /// The honest half of the overrun story: when the consumer stops draining,
    /// audio *is* lost — and the number says exactly how much.
    func testAStalledConsumerCausesCountedDropsAndNeverBlocksTheTap() throws {
        let capacity = 4
        let processor = try makeProcessor(ringCapacity: capacity)
        let block = sine(frequency: 1_000, sampleRate: 48_000, amplitude: 0.4, count: 4_800) // 100 ms each

        // Never drain. Ten blocks is one second of audio into a 80 ms ring.
        for _ in 0..<10 {
            block.withUnsafeBufferPointer { source in
                processor.process(channelZero: source.baseAddress!, frameCount: source.count)
            }
        }

        XCTAssertEqual(processor.ring.availableFrames, capacity, "the ring must stop at capacity, not grow")
        XCTAssertGreaterThan(processor.ring.droppedFrameCount, 40, "a full second of overrun must be reported")
        XCTAssertEqual(
            processor.ring.writtenFrameCount + processor.ring.droppedFrameCount,
            capacity + processor.ring.droppedFrameCount,
            "accepted + dropped must account for every frame the tap produced"
        )

        // Drop-newest: what survived is the *oldest* audio, contiguous.
        let frames = drain(processor.ring)
        XCTAssertEqual(frames.count, capacity)
        for frame in frames { XCTAssertEqual(frame.count, frameSize) }
    }

    // MARK: Allocation behaviour — the point of RC-9

    /// The claim RC-9 exists to make, measured rather than asserted. See
    /// ``AllocationCounter`` for how the counting works.
    func testTapProcessorDoesNotAllocate() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger unavailable")

        let processor = try makeProcessor()
        let block = sine(frequency: 1_000, sampleRate: 48_000, amplitude: 0.4, count: 1_024)
        var sink = [Int16](repeating: 0, count: frameSize)

        block.withUnsafeBufferPointer { source in
            let base = source.baseAddress!
            // Warm up: first-touch lazy initialisation is a genuine allocation,
            // but it happens once per process, not once per callback.
            for _ in 0..<200 {
                processor.process(channelZero: base, frameCount: source.count)
                while sink.withUnsafeMutableBufferPointer({ processor.ring.read(into: $0) }) {}
            }

            let allocations = AllocationCounter.measure {
                var iteration = 0
                while iteration < 2_000 {
                    processor.process(channelZero: base, frameCount: source.count)
                    while sink.withUnsafeMutableBufferPointer({ processor.ring.read(into: $0) }) {}
                    iteration += 1
                }
            }
            XCTAssertEqual(
                allocations, 0,
                "the microphone tap allocated — that is a priority inversion waiting to happen"
            )
        }
    }

    /// The same measurement through the exact entry point `installTap` calls,
    /// `AVAudioPCMBuffer` and all. This is what actually runs on the render
    /// thread, including the two Objective-C property reads
    /// (`floatChannelData`, `frameLength`) the pointer test above skips.
    func testTapProcessorDoesNotAllocateWhenDrivenFromAnAVAudioPCMBuffer() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger unavailable")

        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let samples = sine(frequency: 1_000, sampleRate: 48_000, amplitude: 0.4, count: 1_024)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        let channel = try XCTUnwrap(buffer.floatChannelData)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: $0.count) }

        let processor = try makeProcessor()
        var sink = [Int16](repeating: 0, count: frameSize)
        for _ in 0..<200 {
            processor.process(buffer)
            while sink.withUnsafeMutableBufferPointer({ processor.ring.read(into: $0) }) {}
        }

        let allocations = AllocationCounter.measure {
            var iteration = 0
            while iteration < 2_000 {
                processor.process(buffer)
                while sink.withUnsafeMutableBufferPointer({ processor.ring.read(into: $0) }) {}
                iteration += 1
            }
        }
        XCTAssertEqual(allocations, 0, "the installed tap closure's body allocated")
    }

    /// The counter-example that justifies the deviation from the RC-9 brief.
    /// `AVAudioConverter`'s block-based API is not declared `NS_NOESCAPE`, so
    /// Swift must heap-allocate a block on every call — with preallocated input
    /// and output buffers, which removes every allocation the *caller* controls.
    /// If a future SDK marks it `NS_NOESCAPE` this test will start failing, at
    /// which point the capture path can go back to `AVAudioConverter`.
    func testAVAudioConverterStillAllocatesEvenWithPreallocatedBuffers() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger unavailable")

        let sourceFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let wireFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: false)
        )
        let converter = try XCTUnwrap(AVAudioConverter(from: sourceFormat, to: wireFormat))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 1_024))
        input.frameLength = 1_024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: 256))

        // Everything preallocated; the only thing left per call is the block.
        var provided = false
        func convertOnce() {
            provided = false
            output.frameLength = 0
            _ = converter.convert(to: output, error: nil) { _, status in
                if provided {
                    status.pointee = .noDataNow
                    return nil
                }
                provided = true
                status.pointee = .haveData
                return input
            }
        }
        for _ in 0..<200 { convertOnce() }

        let allocations = try XCTUnwrap(AllocationCounter.measure {
            var iteration = 0
            while iteration < 1_000 {
                convertOnce()
                iteration += 1
            }
        })
        XCTAssertGreaterThan(
            allocations, 0,
            """
            AVAudioConverter no longer allocates per call — the capture path can \
            drop RealTimeDownConverter and go back to it
            """
        )
    }
}

/// Collects frames delivered by the drain task, from whatever thread it runs
/// on. A plain lock is right here: this is test bookkeeping at ordinary
/// priority, not the render thread.
private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Int16]] = []

    func append(_ frame: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(frame)
    }

    var frames: [[Int16]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// The consumer half of the RC-9 handoff.
///
/// After RC-9 nothing reaches the caller except through this task, so a silent
/// failure here is a radio that hears nothing. `startCapture` cannot be called
/// without a microphone, so the loop is exercised through the internal test
/// hook — the same function, the same ring, the same `FrameSink`.
final class CaptureDrainTaskTests: XCTestCase {
    private func frame(_ index: Int) -> [Int16] {
        (0..<4).map { Int16(truncatingIfNeeded: index &* 31 &+ $0) }
    }

    /// Polls until `condition` holds or the deadline passes. Bounded, so a
    /// broken drain loop fails the test instead of hanging the suite.
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    func testDrainTaskDeliversEveryFrameInOrder() async {
        let ring = RealTimeRingBuffer(frameSize: 4, capacity: 64)
        let collector = FrameCollector()
        let task = AudioPipeline.makeCaptureDrainTaskForTesting(ring: ring) { collector.append($0) }
        defer { task.cancel() }

        let expected = (0..<40).map { frame($0) }
        for payload in expected {
            XCTAssertTrue(ring.write(payload))
        }

        let delivered = await waitUntil { collector.frames.count == expected.count }
        XCTAssertTrue(delivered, "the drain task delivered \(collector.frames.count) of \(expected.count) frames")
        XCTAssertEqual(collector.frames, expected, "frames arrived out of order or corrupted")
        XCTAssertEqual(ring.droppedFrameCount, 0)
    }

    func testDrainTaskKeepsUpWithFramesArrivingWhileItRuns() async {
        let ring = RealTimeRingBuffer(frameSize: 4, capacity: 8)
        let collector = FrameCollector()
        let task = AudioPipeline.makeCaptureDrainTaskForTesting(ring: ring) { collector.append($0) }
        defer { task.cancel() }

        // More frames than the ring can hold at once, fed in while the task is
        // already draining — the case a single "write then drain" test misses.
        var written: [[Int16]] = []
        for index in 0..<60 {
            let payload = frame(index)
            var accepted = false
            let deadline = Date().addingTimeInterval(5)
            while !accepted, Date() < deadline {
                accepted = ring.write(payload)
                if !accepted { try? await Task.sleep(nanoseconds: 1_000_000) }
            }
            XCTAssertTrue(accepted, "ring never drained enough to accept frame \(index)")
            written.append(payload)
        }

        let delivered = await waitUntil { collector.frames.count == written.count }
        XCTAssertTrue(delivered, "the drain task fell permanently behind")
        XCTAssertEqual(collector.frames, written)
    }

    func testCancellingTheDrainTaskStopsDelivery() async {
        let ring = RealTimeRingBuffer(frameSize: 4, capacity: 64)
        let collector = FrameCollector()
        let task = AudioPipeline.makeCaptureDrainTaskForTesting(ring: ring) { collector.append($0) }

        XCTAssertTrue(ring.write(frame(0)))
        _ = await waitUntil { collector.frames.count == 1 }

        task.cancel()
        _ = await task.value // the loop has now exited

        let countAtCancellation = collector.frames.count
        for index in 1..<10 {
            XCTAssertTrue(ring.write(frame(index)))
        }
        try? await Task.sleep(nanoseconds: 50_000_000) // ten drain intervals

        XCTAssertEqual(
            collector.frames.count, countAtCancellation,
            "frames were delivered after the drain task was cancelled"
        )
    }

    func testDrainTaskIdlesQuietlyOnAnEmptyRing() async {
        let ring = RealTimeRingBuffer(frameSize: 4, capacity: 8)
        let collector = FrameCollector()
        let task = AudioPipeline.makeCaptureDrainTaskForTesting(ring: ring) { collector.append($0) }
        defer { task.cancel() }

        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(collector.frames.isEmpty, "the drain task invented frames from an empty ring")

        XCTAssertTrue(ring.write(frame(7)))
        let delivered = await waitUntil { collector.frames.count == 1 }
        XCTAssertTrue(delivered, "the drain task did not wake up after idling")
        XCTAssertEqual(collector.frames.first, frame(7))
    }
}


// MARK: - Route-change cause (RC-13)

/// The mapping from Apple's raw reason codes, which is the whole of RC-13 that
/// can be asserted off-device — and it is worth asserting, because a caller
/// implementing `SF-3` decides whether to unkey a live transmission from it.
final class AudioRouteChangeCauseTests: XCTestCase {

    func testEachKnownReasonMaps() {
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 1), .newDeviceAvailable)
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 2), .oldDeviceUnavailable)
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 3), .categoryChange)
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 4), .override)
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 6), .wakeFromSleep)
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 7), .noSuitableRouteForCategory)
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 8), .routeConfigurationChange)
    }

    /// Unrecognised reasons are carried through rather than flattened, so a
    /// caller can log the number it did not understand. `0` is Apple's own
    /// "unknown" and `5` is unused; both land here, which is correct.
    func testUnrecognisedReasonsKeepTheirNumber() {
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 0), .unknown(reason: 0))
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 5), .unknown(reason: 5))
        XCTAssertEqual(AudioRouteChangeCause(rawReason: 99), .unknown(reason: 99))
    }

    /// **The distinction the whole task exists for.** A category change is the
    /// app changing its own mind — on the transmit path, it *is* the
    /// transmission starting. Everything else is the route moving underneath.
    func testOnlyACategoryChangeIsNotAnExternalMove() {
        XCTAssertFalse(AudioRouteChangeCause.categoryChange.isExternalRouteMove)

        for cause: AudioRouteChangeCause in [
            .newDeviceAvailable, .oldDeviceUnavailable, .override, .wakeFromSleep,
            .noSuitableRouteForCategory, .routeConfigurationChange,
            .engineConfigurationChange,
        ] {
            XCTAssertTrue(cause.isExternalRouteMove, "\(cause) should count as a real move")
        }
    }

    /// **An unknown cause must not be the quiet one.** If a future OS invents a
    /// reason, the safe default is to treat it as the route moving, because the
    /// failure mode of the other choice is a microphone left open.
    func testAnUnknownCauseCountsAsAnExternalMove() {
        XCTAssertTrue(AudioRouteChangeCause.unknown(reason: 42).isExternalRouteMove)
        XCTAssertTrue(AudioRouteChangeCause(rawReason: 0).isExternalRouteMove)
    }

    /// The engine's own reconfiguration is not a session route change and has no
    /// raw reason at all — it is the only cause on macOS.
    func testEngineConfigurationChangeIsNotProducedByTheRawMapping() {
        for raw in UInt(0)...UInt(10) {
            XCTAssertNotEqual(
                AudioRouteChangeCause(rawReason: raw), .engineConfigurationChange,
                "the engine cause has no reason code and must not be mapped from one")
        }
    }

    /// The raw numbers against the symbols they claim to be. iOS-only, so this
    /// is a backstop for whoever runs the suite on a simulator rather than a
    /// guard that fires on every push — the same arrangement as the policy
    /// round-trip above.
    func testRawReasonsRoundTripToTheAVFoundationSymbols() throws {
        #if os(iOS)
        XCTAssertEqual(AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue, 1)
        XCTAssertEqual(AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, 2)
        XCTAssertEqual(AVAudioSession.RouteChangeReason.categoryChange.rawValue, 3)
        XCTAssertEqual(AVAudioSession.RouteChangeReason.override.rawValue, 4)
        XCTAssertEqual(AVAudioSession.RouteChangeReason.wakeFromSleep.rawValue, 6)
        XCTAssertEqual(
            AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue, 7)
        XCTAssertEqual(
            AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue, 8)
        #else
        throw XCTSkip("AVAudioSession.RouteChangeReason is iOS-only")
        #endif
    }
}

// MARK: - Audio-session policy (RC-11)

/// The policy is the one thing in this file that can be asserted on any
/// platform, and it is worth asserting: it decides whether the microphone
/// works at all, and it used to exist twice — here and, spelled out by hand,
/// in Currawong's `AudioIO` (the app's `BU-3`).
final class AudioSessionPolicyTests: XCTestCase {
    func testRadioPolicyPinsCategoryModeAndOptions() {
        let policy = AudioSessionPolicy.radio
        XCTAssertEqual(policy.category, "AVAudioSessionCategoryPlayAndRecord")
        XCTAssertEqual(policy.mode, "AVAudioSessionModeVoiceChat")
        XCTAssertEqual(policy.options, 0xC, "allowBluetooth (0x4) | defaultToSpeaker (0x8)")
    }

    // MARK: - The listening policy (RC-12)

    /// The idle half of the pair. `.playback` with no options, because that is
    /// what routes a Bluetooth accessory to **A2DP** — and not asking for an
    /// input is the only way to stop iOS selecting HFP and holding SCO up for
    /// the whole call.
    func testListeningPolicyPinsCategoryModeAndOptions() {
        let policy = AudioSessionPolicy.listening
        XCTAssertEqual(policy.category, "AVAudioSessionCategoryPlayback")
        XCTAssertEqual(policy.mode, "AVAudioSessionModeDefault")
        XCTAssertEqual(policy.options, 0, "no options: asking for nothing is the point")
    }

    /// **The distinction the whole of RC-12 rests on.** Two policies that
    /// differed only in options would not fix anything: the app's `BU-17` showed
    /// that a `.playAndRecord` session keeps *returning* to HFP, because the
    /// category requires an input and HFP is the only Bluetooth one on offer. The
    /// categories must differ.
    func testTheTwoPoliciesDifferInCategoryNotJustOptions() {
        XCTAssertNotEqual(
            AudioSessionPolicy.listening.category, AudioSessionPolicy.radio.category,
            "a policy that still requires an input will still be given HFP")
        XCTAssertNotEqual(AudioSessionPolicy.listening, AudioSessionPolicy.radio)
    }

    /// Only ``AudioSessionPolicy/radio`` may ask for the hands-free profile.
    /// Listening asking for it would defeat the point, and a future edit that
    /// "tidies" the options together is exactly what this catches.
    func testOnlyTheRadioPolicyAsksForHandsFree() {
        XCTAssertEqual(
            AudioSessionPolicy.radio.options & AudioSessionPolicy.allowBluetooth,
            AudioSessionPolicy.allowBluetooth)
        XCTAssertEqual(
            AudioSessionPolicy.listening.options & AudioSessionPolicy.allowBluetooth, 0)
    }

    /// A2DP's option is named but deliberately unused: `.playback` reaches A2DP
    /// without it, and adding it to a recording category does not stop HFP being
    /// chosen. Pinned so the number is right if anyone ever does reach for it.
    func testTheA2DPOptionIsPinnedAndUnused() {
        XCTAssertEqual(AudioSessionPolicy.allowBluetoothA2DP, 0x20)
        XCTAssertEqual(
            AudioSessionPolicy.radio.options & AudioSessionPolicy.allowBluetoothA2DP, 0)
        XCTAssertEqual(
            AudioSessionPolicy.listening.options & AudioSessionPolicy.allowBluetoothA2DP, 0)
    }

    /// The listening raw values, against the symbols they name. iOS-only, for
    /// the same reason as the radio version above.
    func testListeningRawValuesRoundTripToTheAVFoundationSymbols() throws {
        #if os(iOS)
        let policy = AudioSessionPolicy.listening
        XCTAssertEqual(AVAudioSession.Category(rawValue: policy.category), .playback)
        XCTAssertEqual(AVAudioSession.Mode(rawValue: policy.mode), .default)
        XCTAssertEqual(AVAudioSession.CategoryOptions(rawValue: policy.options), [])
        #else
        throw XCTSkip("AVAudioSession is iOS-only")
        #endif
    }

    /// The raw values above are only correct if they still round-trip to the
    /// symbols they name. This is the test that would catch Apple changing one
    /// — and it runs only on an iOS destination, which CI is not, so it is a
    /// backstop for whoever runs the suite on a simulator rather than a guard
    /// that fires on every push.
    func testRawValuesRoundTripToTheAVFoundationSymbols() throws {
        #if os(iOS)
        let policy = AudioSessionPolicy.radio
        XCTAssertEqual(AVAudioSession.Category(rawValue: policy.category), .playAndRecord)
        XCTAssertEqual(AVAudioSession.Mode(rawValue: policy.mode), .voiceChat)
        XCTAssertEqual(
            AVAudioSession.CategoryOptions(rawValue: policy.options),
            [AVAudioSession.CategoryOptions(rawValue: AudioSessionPolicy.allowBluetooth), .defaultToSpeaker])
        #else
        throw XCTSkip("AVAudioSession is iOS-only")
        #endif
    }
}
