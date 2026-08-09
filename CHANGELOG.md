<!-- SPDX-License-Identifier: Apache-2.0 -->
# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html) — while the
major version is 0, the API may change in any release.

## [Unreleased]

### Milestone

- **M2 passed on 2026-08-09 — a human held a two-way audio conversation
  through this stack.** Against an ASL3 node (Asterisk + app_rpt in a UTM VM),
  via `Echo()` in a plain dialplan context so nothing was keyed. Speech was
  intelligible in both directions with no pitch or rate problem, DTMF was sent
  and echoed back, the SF-1 transmit watchdog stopped transmission at exactly
  its 10 s limit (500 frames × 20 ms), teardown was clean, and no frames were
  dropped. Also exercised live for the first time: PING/PONG, LAGRQ/LAGRP, the
  full-frame-then-mini transmit ordering of §8.1.2, and the retransmission
  engine recovering from a peer `VNAK`. Two checklist items want a re-run
  before v1 — PTT edge timing needs a half-duplex target rather than `Echo()`,
  and the `Ctrl-C`/`kill` teardown paths were not re-confirmed — and the
  transmit-burst wart is tracked as IAX-10. Full result table in
  `docs/CLI.md` §5.

### Resolved

- **OQ-5 — the MD5 RESULT encoding is hexadecimal.** Settled against a live
  ASL3 node on 2026-08-09 with `hamvoip-cli oq5 --method register
  --exhaustive`: lowercase and uppercase hex both accepted, base64 and raw
  bytes both refused with cause code 29. The node decodes the IE back to bytes
  or compares case-insensitively; the refusals prove it checks the digest at
  all. **What IAX2Kit already sent was right, so no behaviour changed** — the
  §8.6.15 encoding is now an observation rather than an assumption. It remains
  an observation about one implementation: `oq5Default` stays lowercase hex,
  because another peer may compare byte-for-byte.
- **The IAX2 registration path has run against a real node.** Four complete
  §6.1 exchanges — REGREQ → REGAUTH → REGREQ+MD5 → REGACK/REGREJ — with
  correct call numbers, sequence progression and ACK discipline in both
  directions. Previously it had only ever been exercised against fixtures.
  The call and voice paths still have not: M2 sign-off remains outstanding.

### Fixed

- **Received audio shorter than 20 ms is played instead of dropped.** A live
  ASL3 node sent a 44-octet media payload — the tail of a playback, 5.5 ms of
  ordinary speech — and `IAX2VoiceReceiver` rejected it for not being exactly
  160 octets. Nothing in RFC 5456 promises a media frame is exactly one 20 ms
  slot: §8.7 gives µ-law as one byte per sample and stops there, and 160 is a
  consequence of 20 ms at 8 kHz rather than a rule about what a peer may send.
  Because µ-law is sample-wise, a partial frame is a shorter frame and not a
  corrupt one. Short payloads are now padded to the slot with encoded silence,
  over-long ones are split across consecutive slots, and only a genuinely
  empty payload is rejected (`Rejection.emptyPayload`). The playout contract
  is unchanged: every tick is still exactly `samplesPerFrame` samples.
- **Quitting no longer announces that your call dropped.** Pressing `q` (or
  `Ctrl-C`, or taking a signal) closes the transport, and the read loop then
  reported it as `DISCONNECTED: the transport closed` — telling the operator
  their call had failed at the exact moment they ended it themselves. The
  banner is now suppressed once a quit is under way. A packet capture confirms
  the HANGUP and its ACK were going out correctly all along, so this was
  always cosmetic; it was also alarming, and it appeared in the middle of a
  sign-off run.
- **`hamvoip-cli connect` no longer reports captured frames as transmitted
  ones.** The closing summary printed the audio bridge's *submitted* count
  under the label `transmitted frames`; because capture runs continuously by
  design, that number rises whether or not PTT is on, so a session with no
  transmission at all reported 55 transmitted frames. It now reports `frames
  captured` and `frames transmitted` separately, the latter counted at the PTT
  gate itself. No behaviour changed — nothing was ever sent unkeyed — but a
  summary that says the client keyed up when it did not is the most alarming
  thing it could get wrong, and it would have been read into an M2 sign-off.
- **`MediaFormat` names the codec instead of printing a bitmask.** A live
  session showed `CONNECTED  codec MediaFormat(rawValue: 4)` where
  `docs/CLI.md` §5 promises the harness names a codec; it now prints
  `G.711 µ-law`, joins multiple bits with `+`, and surfaces unassigned bits
  rather than dropping them.
- `hamvoip-cli oq5` no longer reports a case-insensitive node as an impossible
  result. Accepting both hex renderings while refusing a non-hex one is now
  read as the answer it is; only genuinely contradictory combinations are
  reported as unreliable. Accepting both hex forms with *nothing* refused is
  reported as inconclusive rather than as an answer, since a node that accepts
  anything is indistinguishable from that angle.

### Changed

- The `IAX2Registrar` MD5-encoding seam is downgraded from a defect to a
  hygiene item: it hard-codes the default encoding, and the default turned out
  to be correct, so FR-1.3 registered node mode works as shipped.
- `docs/CLI.md` gains one-shot and Keychain forms for supplying the secret,
  and an explanation of why `HAMVOIP_SECRET` can appear not to take effect.

## [0.1.0] — 2026-08-09

First release. The AllStarLink/IAX2 path is complete and tested against
recorded fixtures; **none of it has been validated against a real node.** See
"Known limitations" below before depending on it.

### Added

**`RadioCore`** — the mode-independent layer.

- `DatagramTransport`, the seam every network mode is written against, with a
  `Network.framework` UDP implementation (PD-1) and a mock for tests.
- G.711 µ-law encode and decode (FR-1.4).
- Adaptive jitter buffer, target depth 60–200 ms, adjusting to measured arrival
  variance (AU-3).
- Transmit watchdog (SF-1), default 180 s.
- Received-audio leveller (AU-4).
- `AVAudioEngine` capture and playback pipeline with 48 kHz ↔ 8 kHz conversion
  (AU-1, AU-2), and a real-time-safe capture path that does not allocate or
  lock on the audio thread.

**`IAX2Kit`** — AllStarLink over IAX2 (RFC 5456).

- Full frame model: parse and serialise, full frames and mini-frames.
- Information elements.
- Sequence numbering and the retransmission engine.
- MD5 challenge authentication (§8.6.15) — see Known limitations.
- Outbound call state machine: NEW, ACCEPT, ANSWER, HANGUP, PING/PONG,
  LAGRQ/LAGRP (FR-1.1).
- Voice path and DTMF (FR-1.5).
- Registration and registered-node mode (FR-1.3), including refresh with
  jittered renewal and a geometric retry ladder.
- `IAX2Client`, an actor composing the above with the jitter buffer, watchdog
  and leveller, exposing `receivedAudio` and `events` as `nonisolated` streams.

**`M17Kit`** — partial.

- Reflector control: CONN, ACKN, NACK, PING, PONG, DISC and module selection
  (FR-2.1).
- Base-40 callsign encoding into the 48-bit address field (FR-2.3).
- Stream packet parse and serialise, with encryption surfaced only as
  `isEncrypted` / `playability == .encrypted` and no decrypt path (FR-2.5).

**`hamvoip-cli`** — a macOS harness for validating the stack against a real
node: connect, level metering, keying, DTMF, and an `oq5` subcommand that
settles the authentication-encoding question without placing a call.

**Project**

- Apache-2.0 throughout, with an SPDX identifier on every source file, enforced
  in CI (LP-5).
- Every timer injected via `Clock`, so a full session runs in tests with no
  real-time waits (AU-5).

### Known limitations

- **The `MD5_RESULT` encoding is an unverified assumption.** RFC 5456 §8.6.15
  does not state how the digest is textually encoded, and the clean-room policy
  (LP-2) forbids reading an implementation to find out. Lowercase 32-character
  hex ships as the default. If it is wrong, authentication fails against real
  nodes; the fix is `IAX2Call.Configuration.md5ResultEncoding`, reachable from
  `IAX2Client.Configuration.call`. Run `hamvoip-cli oq5` against a live node to
  settle it (OQ-5).
- **That override does not extend to registration.** `IAX2Registrar` computes
  its digest with the default encoding and carries no configuration point, so
  if OQ-5 resolves to anything other than lowercase hex, registered node mode
  (FR-1.3) remains broken after the call path has been corrected. Threading
  `md5ResultEncoding` through `IAX2Registrar.Configuration` is the fix.
- **A `raw-bytes` outcome is not expressible at all.** `TextDigestEncoding`
  renders to a `String` and `InformationElement.md5Result` takes a `String`,
  so should that candidate win, IAX2Kit needs a byte-valued MD5 RESULT path
  before either code path can authenticate.
- **No on-air validation of any kind.** There is no capture-replay conformance
  test against a recorded session of a real node (IAX-9).
- **M17 has no audio path.** Stream mode is unimplemented pending OQ-7, the
  question of whether the IP stream frame is 56 or 54 bytes, which cannot be
  settled from the specification. There is no `M17Client`.
- **The M17 reflector specification is offline** (OQ-8). The chapter this code
  was written against was published as HTML at a host that now 404s; the
  implementation was taken from an Internet Archive capture, cross-checked
  against a second capture. Provenance is recorded in
  `docs/reference/PROVENANCE.md`.
- **Codec2 shipping under LGPL-2.1 is unresolved for App Store distribution**
  (OQ-6). Shipping it as a dynamic framework satisfies the letter of LP-4, but
  a signed iOS app cannot have its framework substituted, which is what
  LGPL §6 relinking exists to permit. A licensing judgement, still open.
- **EchoLink is not implemented.** The service's terms are not the obstacle
  (OQ-1, resolved); the obstacle is that there is no published protocol
  specification and LP-2 forbids the implementations that document it (OQ-9).

### Not in scope, permanently

DMR, System Fusion (YSF), D-STAR, P25 and NXDN. All require AMBE or AMBE+2,
which is patent-encumbered (NG-1). No MMDVM or USB modem support (NG-2), no MFi
(NG-3), and no RF layer (NG-4).

[Unreleased]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/cpmpercussion/swift-hamvoip/releases/tag/v0.1.0
