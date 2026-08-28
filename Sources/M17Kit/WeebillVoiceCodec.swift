// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import Weebill

/// Codec 2 3200 bit/s in pure Swift, via Weebill (M17-7, FR-2.4).
///
/// The same codec ``Codec2VoiceCodec`` binds, from a different implementation:
/// Weebill is BSD-2-Clause Swift source rather than an LGPL-2.1 C library, so
/// it needs no XCFramework, no build script and no conditional compilation.
/// This type is therefore **always** available, where `Codec2VoiceCodec`
/// exists only on a checkout where `Codec2.xcframework` has been built.
///
/// Both conform to ``RadioCore/VoiceCodec`` and either can be handed to
/// `M17Client`. That interchangeability is not incidental — it is what lets
/// `WeebillVoiceCodecTests` check one against the other frame by frame, and it
/// is the reason M17-7 could add this without touching the stream path.
///
/// ## Frame arithmetic
///
/// Identical to the framework's, and asserted here the same way: 160 samples
/// in, 8 bytes out, so 20 ms per frame and exactly two frames in the 16-byte
/// payload of an `M17StreamPacket`. See ``M17StreamPayload``, which owns that
/// split.
///
/// ## Why a lock rather than an actor
///
/// Weebill's `Codec2_3200` documents itself as stateful and not thread-safe
/// across concurrent frames, and ``RadioCore/VoiceCodec`` is synchronous
/// because the audio path calls it from a real-time context where `await` is
/// not available. So the state is guarded by a lock, exactly as in
/// ``Codec2VoiceCodec``.
///
/// Encode and decode get **separate** `Codec2_3200` instances. They are
/// independent state machines and one instance shared between the directions
/// would serialise a full-duplex path against itself for no reason. Each
/// facade carries an encoder *and* a decoder, so one half of each goes unused;
/// that costs a few small buffers and buys the stable public API.
public final class WeebillVoiceCodec: VoiceCodec, @unchecked Sendable {

    /// 160 samples at 8 kHz — 20 ms.
    public let samplesPerFrame: Int

    /// 8 bytes — 64 bits.
    public let bytesPerFrame: Int

    private let encoder: Codec2_3200
    private let decoder: Codec2_3200
    private let encodeLock = NSLock()
    private let decodeLock = NSLock()

    /// Creates a codec, or throws if Weebill reports a geometry this code was
    /// not written for.
    ///
    /// - Parameter phaseSeed: seeds the decoder's unvoiced-phase PRNG. Weebill
    ///   synthesises unvoiced phases stochastically, so decoded audio is not
    ///   waveform-identical between runs unless this is pinned. It is pinned by
    ///   default — a codec that returns different samples for the same bytes
    ///   would make every downstream test unreproducible — and nothing on the
    ///   audio path should pass anything else.
    public init(phaseSeed: UInt64? = nil) throws {
        self.encoder = phaseSeed.map(Codec2_3200.init(phaseSeed:)) ?? Codec2_3200()
        self.decoder = phaseSeed.map(Codec2_3200.init(phaseSeed:)) ?? Codec2_3200()

        // Checked rather than assumed, for the same reason the framework's
        // geometry is checked at construction: a future Weebill that changed
        // either number must fail loudly here rather than produce quietly
        // misaligned audio downstream.
        let samples = Codec2_3200.frameSamples
        let bytes = Codec2_3200.frameBytes
        guard samples == 160, bytes == 8 else {
            throw WeebillCodecError.unexpectedGeometry(
                samplesPerFrame: samples, bytesPerFrame: bytes)
        }
        self.samplesPerFrame = samples
        self.bytesPerFrame = bytes
    }

    public func encode(_ pcm: [Int16]) throws -> [UInt8] {
        // Weebill's `encode` is non-throwing and assumes a full frame, so the
        // count is checked here rather than there.
        guard pcm.count == samplesPerFrame else {
            throw WeebillCodecError.wrongSampleCount(expected: samplesPerFrame, actual: pcm.count)
        }
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return encoder.encode(pcm)
    }

    public func decode(_ frame: [UInt8]) throws -> [Int16] {
        guard frame.count == bytesPerFrame else {
            throw WeebillCodecError.wrongFrameSize(expected: bytesPerFrame, actual: frame.count)
        }
        decodeLock.lock()
        defer { decodeLock.unlock() }
        return decoder.decode(frame)
    }

    /// Samples the decoder had to substitute because synthesis produced a
    /// non-finite value.
    ///
    /// Weebill's own health check, surfaced because it is otherwise invisible
    /// through an `[Int16]` return. It must stay 0 for every input, including
    /// a corrupted bitstream off the air, so a non-zero reading is a defect
    /// report rather than a signal-quality measure.
    public var nonFiniteSampleCount: Int {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        return decoder.nonFiniteSampleCount
    }

    /// Returns both directions to their initial state, for a new stream.
    public func reset() {
        encodeLock.lock()
        encoder.reset()
        encodeLock.unlock()
        decodeLock.lock()
        decoder.reset()
        decodeLock.unlock()
    }
}

/// Failures constructing or driving ``WeebillVoiceCodec``.
public enum WeebillCodecError: Error, Equatable, CustomStringConvertible {
    /// Weebill reports a frame geometry this code was not written for.
    case unexpectedGeometry(samplesPerFrame: Int, bytesPerFrame: Int)
    /// `encode` was handed something other than one frame of PCM.
    case wrongSampleCount(expected: Int, actual: Int)
    /// `decode` was handed something other than one encoded frame.
    case wrongFrameSize(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .unexpectedGeometry(let samples, let bytes):
            return """
                Weebill reports \(samples) samples and \(bytes) bytes per frame; \
                this code is written for 160 and 8
                """
        case .wrongSampleCount(let expected, let actual):
            return "Weebill encode wants exactly \(expected) samples, got \(actual)"
        case .wrongFrameSize(let expected, let actual):
            return "Weebill decode wants exactly \(expected) bytes, got \(actual)"
        }
    }
}
