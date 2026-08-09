// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Errors thrown by ``G711MuLawCodec``.
public enum G711Error: Error, Equatable, Sendable {
    /// `encode`/`decode` requires input of exactly the frame length.
    case wrongFrameLength(expected: Int, got: Int)
}

/// ITU-T G.711 µ-law codec: 8 kHz, 20 ms framing (160 samples / 160 bytes).
///
/// This is a clean-room implementation of the algorithmic description of
/// the standard — sign bit, 3-bit segment (exponent), 4-bit mantissa,
/// bias 0x84, complemented output byte — derived and verified from first
/// principles below, not copied from any table or source file.
///
/// ## Derivation
///
/// A linear PCM sample is split into a sign and a magnitude. The magnitude
/// is clamped to `clip` and then biased by adding `bias` (0x84 = 132); call
/// the result `biased`. Because the smallest possible `biased` value is
/// exactly `bias` itself (132 = `0b1000_0100`, most-significant bit at
/// position 7) and `clip` is chosen so the largest possible `biased` value
/// is `Int16.max` (bit position 14), the position of `biased`'s
/// most-significant set bit ranges over exactly 8 values (7...14) — one
/// per G.711 segment. Subtracting 7 from that bit position gives the
/// 3-bit segment (exponent) directly; the standard defines the 4-bit
/// mantissa as the next 4 bits below the segment's implicit leading bit,
/// i.e. `(biased >> (exponent + 3)) & 0xF`. Everything below that — 3 bits
/// for the finest segment, growing to 10 bits for the coarsest — is
/// discarded as quantisation error; this is the origin of µ-law's usual
/// "14-bit dynamic range in 8 bits" description, and is the shift this
/// implementation actually applies (a per-segment shift of
/// `exponent + 3` bits, rather than a single fixed pre-shift of the raw
/// 16-bit sample). A fixed pre-shift of the sample by 2 bits before
/// biasing was considered, but is incompatible with `bias = 0x84` and
/// full 8-segment coverage: with `bias`'s own most-significant bit fixed
/// at position 7, reaching segment 7 (bit position 14) requires the
/// biased magnitude to range up to ~32767, which a 2-bit pre-shift
/// (capping the magnitude at ~8192) cannot reach. This is noted per
/// development-plan rule 6 (spec/plan constants are re-checked, and
/// disagreements are reported) — see the RC-2 completion report.
///
/// Decoding reconstructs the magnitude at the midpoint of the
/// quantisation interval the encoder collapsed the sample into (implicit
/// leading bit + mantissa bits + half of the discarded low-order bits),
/// then removes the bias. The one exception is the zero-magnitude,
/// negative-sign code (encoded from PCM samples 0 and -1 alike): without
/// adjustment it would decode to 0, colliding with the positive-sign
/// zero code and breaking the "256 distinct decoded values" property, so
/// it decodes to -1 instead (which is also its exact original encode
/// input, preserving the decode→encode round trip).
public struct G711MuLawCodec: VoiceCodec, Sendable {
    /// ITU-T G.711 bias constant.
    static let bias: Int = 0x84 // 132

    /// Maximum magnitude before biasing. Chosen so `magnitude + bias` never
    /// exceeds `Int16.max` (32767 = 0x7FFF), which keeps the biased value's
    /// most-significant bit within bit position 14 — the top of segment 7.
    static let clip: Int = Int(Int16.max) - bias // 32635

    public init() {}

    public var samplesPerFrame: Int { 160 }
    public var bytesPerFrame: Int { 160 }

    public func encode(_ pcm: [Int16]) throws -> [UInt8] {
        guard pcm.count == samplesPerFrame else {
            throw G711Error.wrongFrameLength(expected: samplesPerFrame, got: pcm.count)
        }
        return pcm.map(Self.encodeSample)
    }

    public func decode(_ frame: [UInt8]) throws -> [Int16] {
        guard frame.count == bytesPerFrame else {
            throw G711Error.wrongFrameLength(expected: bytesPerFrame, got: frame.count)
        }
        return frame.map(Self.decodeSample)
    }

    /// Encodes a single 16-bit linear PCM sample to a µ-law byte.
    public static func encodeSample(_ x: Int16) -> UInt8 {
        let signBit: Int
        let magnitude: Int
        if x < 0 {
            signBit = 0x80
            // Widen to Int first: -Int16.min (32768) does not fit in Int16.
            magnitude = -Int(x)
        } else {
            signBit = 0
            magnitude = Int(x)
        }

        let clamped = min(magnitude, clip)
        let biased = clamped + bias // 132...32767

        // Position (7...14) of the most-significant set bit of `biased`.
        var exponent = 7
        var probe = 0x4000 // bit 14
        while exponent > 0 && (biased & probe) == 0 {
            probe >>= 1
            exponent -= 1
        }

        let mantissa = (biased >> (exponent + 3)) & 0x0F
        let preComplement = signBit | (exponent << 4) | mantissa
        return UInt8(~preComplement & 0xFF)
    }

    /// Decodes a single µ-law byte back to a 16-bit linear PCM sample.
    public static func decodeSample(_ b: UInt8) -> Int16 {
        let preComplement = Int(~b) & 0xFF
        let sign = preComplement & 0x80
        let exponent = (preComplement >> 4) & 0x07
        let mantissa = preComplement & 0x0F

        // Implicit leading bit, mantissa bits, and half of the discarded
        // low-order bits (reconstruction at the interval's midpoint).
        let biased = (1 << (exponent + 7)) | (mantissa << (exponent + 3)) | (1 << (exponent + 2))
        let magnitude = biased - bias

        if sign != 0 {
            return magnitude == 0 ? -1 : Int16(-magnitude)
        }
        return Int16(magnitude)
    }
}
