// SPDX-License-Identifier: Apache-2.0

import Foundation

/// EchoLink over the proxy protocol (TCP 8100) and the directory server
/// (TCP 5200).
///
/// **Where this protocol's definition comes from, and what that costs.**
/// EchoLink has no published specification. IAX2 has RFC 5456 and M17 has its
/// own spec; this kit has neither, and LP-1/LP-2 forbid reading any existing
/// implementation. So every wire fact here comes from packet captures of the
/// maintainer's own sessions, taken 2026-08-12 — the OQ-9 work — and from the
/// fixtures cut from them in `Tests/EchoLinkKitTests/Fixtures/`.
///
/// That is a weaker footing than the other two kits have, in a specific way
/// worth stating rather than discovering: **a capture records what happened,
/// never what is permitted.** Four independent peers all sending four GSM
/// frames per packet is strong evidence about practice and silent about the
/// legal range. The rule that follows, and it applies to every parser in this
/// module: *parse permissively, emit what was observed.* An unfamiliar message
/// type is not a protocol error — it is a client we have not met.
///
/// RFC 3550 deserves a specific warning. EchoLink's audio is RTP-shaped but
/// **not** RFC 3550-conformant as written: the version bits are 3, not 2, and
/// the timestamp is always zero. A parser written faithfully from the RFC
/// rejects every real packet. The RFC is background reading here; the capture
/// is the primary source.
public enum EchoLinkKit {
    /// The version of this kit's protocol knowledge, for provenance in bug
    /// reports: the date of the captures every wire constant here derives from.
    public static let evidenceDate = "2026-08-12"
}
