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
}
