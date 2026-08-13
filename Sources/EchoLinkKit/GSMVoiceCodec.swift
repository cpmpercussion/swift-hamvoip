// SPDX-License-Identifier: Apache-2.0

import CGSM
import Foundation
import RadioCore

/// Why a GSM codec operation failed.
public enum GSMVoiceCodecError: Error, Equatable, CustomStringConvertible {
    /// `gsm_create` returned null — only ever an allocation failure.
    case unavailable

    /// Wrong number of PCM samples handed to `encode`.
    case wrongSampleCount(expected: Int, actual: Int)

    /// Wrong number of encoded bytes handed to `decode`.
    case wrongFrameSize(expected: Int, actual: Int)

    /// `gsm_decode` refused the frame. It validates the magic nibble, so this
    /// means the 33 bytes are not a GSM 06.10 frame at all.
    case corruptFrame

    public var description: String {
        switch self {
        case .unavailable:
            return "gsm_create failed"
        case .wrongSampleCount(let expected, let actual):
            return "GSM encode expects \(expected) samples, got \(actual)"
        case .wrongFrameSize(let expected, let actual):
            return "GSM decode expects \(expected) bytes, got \(actual)"
        case .corruptFrame:
            return "gsm_decode rejected the frame"
        }
    }
}

/// GSM 06.10 full-rate at 13 kbit/s (FR-3.2), over vendored libgsm (LP-4).
///
/// ## Why this is so much smaller than the Codec2 wiring
///
/// Not because GSM is simpler, but because its licence is. libgsm is BSD-style,
/// so LP-4 permits vendoring the source outright: no XCFramework, no build
/// script, no `#if` guarding a target that may not exist, and nothing for CI to
/// install. A bare checkout builds and tests it. **Do not import the Codec2
/// pattern here** — it exists to work around LGPL-2.1 and has no purpose in
/// this file.
///
/// ## Frame geometry
///
/// 33 bytes per frame, 160 samples per frame, 8 kHz mono signed 16-bit. That
/// 160 samples is exactly 20 ms, which lines up with the frame size the rest of
/// the stack already uses — so unlike M17's 40 ms datagrams there is no
/// pairing or accommodation anywhere: one captured frame in, one codec frame
/// out. `EchoLinkStreamTransmitter` packs four of them into an 80 ms packet,
/// which is a packing decision and not a codec one.
///
/// ## Thread safety
///
/// `gsm_create` allocates a state object that `gsm_encode` and `gsm_decode`
/// both mutate — the encoder and decoder each carry filter history across
/// frames, which is what makes the codec work at all. So this type is a
/// reference type holding two *separate* handles, one per direction, and it is
/// **not** safe to call `encode` (or `decode`) concurrently with itself.
///
/// It is nonetheless `Sendable`, because `VoiceCodec` requires it and because
/// the sequencing above guarantees the discipline: `EchoLinkClient` calls
/// `encode` only from the actor-isolated transmit path and `decode` only from
/// the playout tick, so neither ever overlaps itself. Two directions running at
/// once is fine — they touch different handles. The `@unchecked` is that
/// argument, not an oversight.
public final class GSMVoiceCodec: VoiceCodec, @unchecked Sendable {
    public let samplesPerFrame = 160
    public let bytesPerFrame = 33

    /// Separate state per direction: full duplex is the normal case, and
    /// sharing one handle would make the decoder's history depend on what we
    /// happened to be transmitting.
    private let encoder: gsm
    private let decoder: gsm

    public init() throws {
        guard let encoder = gsm_create(), let decoder = gsm_create() else {
            throw GSMVoiceCodecError.unavailable
        }
        self.encoder = encoder
        self.decoder = decoder
    }

    deinit {
        gsm_destroy(encoder)
        gsm_destroy(decoder)
    }

    /// 160 samples of 8 kHz mono signed 16-bit PCM to one 33-byte frame.
    public func encode(_ pcm: [Int16]) throws -> [UInt8] {
        guard pcm.count == samplesPerFrame else {
            throw GSMVoiceCodecError.wrongSampleCount(
                expected: samplesPerFrame, actual: pcm.count)
        }

        var input = pcm
        var output = [UInt8](repeating: 0, count: bytesPerFrame)
        input.withUnsafeMutableBufferPointer { samples in
            output.withUnsafeMutableBufferPointer { bytes in
                // gsm_encode takes non-const pointers but does not modify the
                // input; the signature is 1992 C, not a contract.
                gsm_encode(encoder, samples.baseAddress, bytes.baseAddress)
            }
        }
        return output
    }

    /// One 33-byte frame back to 160 samples.
    ///
    /// - Throws: `.corruptFrame` if libgsm rejects it. It checks the magic
    ///   nibble, so a rejection means these are not GSM 06.10 octets — worth
    ///   surfacing rather than playing as noise.
    public func decode(_ frame: [UInt8]) throws -> [Int16] {
        guard frame.count == bytesPerFrame else {
            throw GSMVoiceCodecError.wrongFrameSize(
                expected: bytesPerFrame, actual: frame.count)
        }

        var input = frame
        var output = [Int16](repeating: 0, count: samplesPerFrame)
        let result: Int32 = input.withUnsafeMutableBufferPointer { bytes in
            output.withUnsafeMutableBufferPointer { samples in
                gsm_decode(decoder, bytes.baseAddress, samples.baseAddress)
            }
        }
        guard result == 0 else { throw GSMVoiceCodecError.corruptFrame }
        return output
    }
}
