// SPDX-License-Identifier: Apache-2.0

#if CODEC2

import Codec2
import Foundation
import RadioCore

/// Codec2 3200 bit/s, the voice codec an M17 stream frame carries (FR-2.4).
///
/// Compiled only when `Codec2.xcframework` has been built — see the note at
/// the top of `Package.swift`, and `docs/reference/CODEC2-XCFRAMEWORK.md` for
/// the build. The framework is linked **dynamically** and never statically,
/// which is LP-4 and the reason the spike existed at all.
///
/// ## Frame arithmetic
///
/// The M17-1 spike confirmed against the built artefact, and this type asserts
/// again at construction: mode 3200 is 160 samples in, 64 bits out. At 8 kHz
/// that is **20 ms of audio per 8-byte frame**, so the 16-byte payload of an
/// `M17StreamPacket` is exactly two of them — 40 ms per datagram. See
/// ``M17StreamPayload``, which owns that split.
///
/// ## Why a lock rather than an actor
///
/// `struct CODEC2` is mutable internal state and is not thread-safe, but
/// ``VoiceCodec`` is a synchronous protocol — it has to be, because the audio
/// path calls it from a real-time context where `await` is not available.
/// So the state is guarded by a lock rather than by actor isolation.
///
/// Encode and decode get **separate** codec2 instances. They are independent
/// state machines and a single instance shared between the two directions
/// would serialise a full-duplex path against itself for no reason.
public final class Codec2VoiceCodec: VoiceCodec, @unchecked Sendable {

    /// `CODEC2_MODE_3200`. Hard-coded rather than taken from the header's
    /// macro, which does not import into Swift as a constant.
    private static let mode3200: Int32 = 0

    /// 160 samples at 8 kHz — 20 ms.
    public let samplesPerFrame: Int

    /// 64 bits.
    public let bytesPerFrame: Int

    private let encoder: OpaquePointer
    private let decoder: OpaquePointer
    private let encodeLock = NSLock()
    private let decodeLock = NSLock()

    /// Creates a codec, or throws if the framework reports a geometry this
    /// code was not written for.
    public init() throws {
        guard let encoder = codec2_create(Codec2VoiceCodec.mode3200),
            let decoder = codec2_create(Codec2VoiceCodec.mode3200)
        else {
            throw Codec2Error.unavailable
        }
        self.encoder = encoder
        self.decoder = decoder

        let samples = Int(codec2_samples_per_frame(encoder))
        let bits = Int(codec2_bits_per_frame(encoder))
        // The spike measured 160 and 64. Checking again here means a future
        // codec2 bump that changed either one fails loudly at construction
        // rather than producing quietly misaligned audio.
        guard samples == 160, bits == 64 else {
            codec2_destroy(encoder)
            codec2_destroy(decoder)
            throw Codec2Error.unexpectedGeometry(samplesPerFrame: samples, bitsPerFrame: bits)
        }
        self.samplesPerFrame = samples
        self.bytesPerFrame = bits / 8
    }

    deinit {
        codec2_destroy(encoder)
        codec2_destroy(decoder)
    }

    public func encode(_ pcm: [Int16]) throws -> [UInt8] {
        guard pcm.count == samplesPerFrame else {
            throw Codec2Error.wrongSampleCount(expected: samplesPerFrame, actual: pcm.count)
        }
        var frame = [UInt8](repeating: 0, count: bytesPerFrame)
        encodeLock.lock()
        defer { encodeLock.unlock() }
        var input = pcm
        frame.withUnsafeMutableBufferPointer { out in
            input.withUnsafeMutableBufferPointer { samples in
                codec2_encode(encoder, out.baseAddress, samples.baseAddress)
            }
        }
        return frame
    }

    public func decode(_ frame: [UInt8]) throws -> [Int16] {
        guard frame.count == bytesPerFrame else {
            throw Codec2Error.wrongFrameSize(expected: bytesPerFrame, actual: frame.count)
        }
        var pcm = [Int16](repeating: 0, count: samplesPerFrame)
        decodeLock.lock()
        defer { decodeLock.unlock() }
        var input = frame
        pcm.withUnsafeMutableBufferPointer { out in
            input.withUnsafeMutableBufferPointer { bits in
                codec2_decode(decoder, out.baseAddress, bits.baseAddress)
            }
        }
        return pcm
    }
}

/// Failures constructing or driving ``Codec2VoiceCodec``.
public enum Codec2Error: Error, Equatable, CustomStringConvertible {
    /// `codec2_create` returned null.
    case unavailable
    /// The framework reports a frame geometry this code was not written for.
    case unexpectedGeometry(samplesPerFrame: Int, bitsPerFrame: Int)
    /// `encode` was handed something other than one frame of PCM.
    case wrongSampleCount(expected: Int, actual: Int)
    /// `decode` was handed something other than one encoded frame.
    case wrongFrameSize(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .unavailable:
            return "codec2_create(CODEC2_MODE_3200) returned null"
        case .unexpectedGeometry(let samples, let bits):
            return """
                codec2 3200 reports \(samples) samples and \(bits) bits per frame; \
                this code is written for 160 and 64
                """
        case .wrongSampleCount(let expected, let actual):
            return "codec2 encode wants exactly \(expected) samples, got \(actual)"
        case .wrongFrameSize(let expected, let actual):
            return "codec2 decode wants exactly \(expected) bytes, got \(actual)"
        }
    }
}

#endif
