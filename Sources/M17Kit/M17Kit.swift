// SPDX-License-Identifier: Apache-2.0

/// M17 reflector support.
///
/// IP/reflector side only — the 4FSK RF layer, FEC and interleaving are out of
/// scope permanently (NG-4).
public enum M17Kit {
    /// Conventional UDP port for M17 reflectors.
    public static let defaultReflectorPort: UInt16 = 17000
}
