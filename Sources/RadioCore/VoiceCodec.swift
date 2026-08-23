// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A frame-oriented voice codec operating on 8 kHz mono signed 16-bit PCM.
///
/// Deliberately narrow: every codec in scope (G.711 µ-law, GSM 06.10,
/// Codec2 3200) is fixed-rate and frame-oriented. Codecs requiring AMBE or
/// AMBE+2 are out of scope while patent-encumbered — see NG-1.
public protocol VoiceCodec: Sendable {
    /// Samples consumed per encoded frame.
    var samplesPerFrame: Int { get }
    /// Encoded bytes produced per frame.
    var bytesPerFrame: Int { get }

    func encode(_ pcm: [Int16]) throws -> [UInt8]
    func decode(_ frame: [UInt8]) throws -> [Int16]
}
