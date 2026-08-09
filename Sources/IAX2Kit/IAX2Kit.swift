// SPDX-License-Identifier: Apache-2.0

/// AllStarLink support via IAX2 (RFC 5456).
///
/// Clean-room: everything in this target is written from RFC 5456 and from
/// packet captures of our own sessions. See §3 of the design requirements.
public enum IAX2Kit {
    /// The IANA-registered IAX port. Both the source and destination port for
    /// a standard IAX2 session.
    public static let defaultPort: UInt16 = 4569
}
