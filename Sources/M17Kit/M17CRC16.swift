// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The CRC-16 used throughout M17.
///
/// Reference: "M17 Protocol Specification, Part I - Air Interface",
/// Wojciech Kaczmarski SP5WWP et al., version 2.0.4
/// (https://spec.m17project.org/files/M17_spec.pdf), which fixes the
/// polynomial as `0x5935` and the initial value as `0xFFFF`.
///
/// The spec pins those two numbers but not the remaining parameters a CRC
/// needs — bit order, and whether a final XOR is applied. Those were settled
/// the same way OQ-7 was, by measuring: of the eight combinations of
/// reflected input, reflected output and final XOR, exactly one closes over
/// the 52 bytes of a captured stream datagram to give its trailing two, and it
/// does so in 52 of 52 frames of the OQ-7 capture. The other seven match none.
/// So:
///
/// - polynomial `0x5935`, initial value `0xFFFF` (both from the spec);
/// - **MSB-first**, no reflection of input or output;
/// - **no final XOR**.
///
/// For the conventional `"123456789"` check vector this gives ``checkValue``,
/// `0x772B`. That constant is *not* quoted in the spec text we hold — it is
/// recorded here because a check value is the cheapest way to catch a
/// mis-transcribed table, and ``M17CRC16Tests`` pins it.
///
/// The capture the parameters were read off is `experiment-data/m17-oq7.pcap`,
/// which is outside the repository (it is passive capture of other operators'
/// traffic on a public reflector). See `docs/reference/PROVENANCE.md` and the
/// OQ-7 row of `docs/DEVELOPMENT-PLAN.md`.
public enum M17CRC16 {

    /// The generator polynomial, `x^16 + x^14 + x^12 + x^11 + x^8 + x^5 +
    /// x^4 + x^2 + 1`, in the usual truncated MSB-first form.
    public static let polynomial: UInt16 = 0x5935

    /// The value the register starts at, before any message byte is fed in.
    public static let initialValue: UInt16 = 0xFFFF

    /// ``compute(_:)`` over the ASCII bytes of `"123456789"`, the conventional
    /// check vector for a CRC parameterisation.
    public static let checkValue: UInt16 = 0x772B

    /// The CRC-16 of `bytes`.
    public static func compute<Bytes: Sequence>(_ bytes: Bytes) -> UInt16
    where Bytes.Element == UInt8 {
        var register = initialValue
        for byte in bytes {
            register ^= UInt16(byte) << 8
            for _ in 0..<8 {
                register = register & 0x8000 == 0
                    ? register << 1
                    : (register << 1) ^ polynomial
            }
        }
        return register
    }
}
