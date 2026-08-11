<!-- SPDX-License-Identifier: Apache-2.0 -->
# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html) — while the
major version is 0, the API may change in any release.

## [Unreleased]

## [0.2.0] — 2026-08-11

M17 stream mode. `M17Kit` goes from parsing reflector control traffic to
producing and consuming stream-mode audio, with a public `M17Client` and a CLI
harness to validate it. **None of the M17 audio path has been run against a
real reflector** — see "Known limitations".

### Resolved

- **OQ-7 — the M17 IP stream frame is 54 bytes, not 56.** Settled on air on
  2026-08-11 against a live reflector, receive-only. The LICH is 28 bytes, the
  LSF *without* its own CRC; Table 27's stated 240 bits would make it 56. One
  over of 52 consecutive datagrams, and three independent readings agree and
  only on this layout: every datagram was 54 bytes, FN counted 0…51 at offset
  34, and the trailing CRC16 closed over the preceding 52 bytes in 52 of 52.
  That third test is what rules out a truncated 56-byte frame. Recorded as an
  observation about what M17-over-IP carries rather than as a correction to the
  specification. Evidence in the OQ-7 row of `docs/DEVELOPMENT-PLAN.md`.

### Added

**`M17Kit`** — stream mode (M17-4, M17-5).

- `M17CRC16` and whole-datagram CRC validation on `M17StreamPacket`
  (`computedCRC`, `isCRCValid`) plus a CRC-computing initialiser for transmit.
  Parsing deliberately does **not** enforce the CRC: a corrupt datagram is
  still parsed and reported, so a receiver can count or conceal it rather than
  have it vanish into a thrown error.
- `Codec2VoiceCodec` — Codec2 3200 as a `RadioCore.VoiceCodec` (FR-2.4), bound
  directly to the XCFramework. No C shim target proved necessary. Dynamic
  linking only (LP-4).
- `M17StreamPayload`, `M17StreamTransmitter`, `M17StreamReceiver` — stream
  sequencing as clock-free value types, mirroring the IAX2 pair. The 16-byte
  payload is two 8-byte codec frames; both halves are queued as separate 20 ms
  slots, so a lost datagram conceals as two ordinary gaps and the rest of the
  stack keeps its 20 ms tick.
- `M17FrameNumberExpander` — FN is 15 bits and wraps every 21.8 minutes.
- `M17Client` — conforms to `NetworkClient`, composing the reflector link,
  codec, jitter buffer, transmit watchdog (SF-1) and received-audio leveller
  (AU-4). The 20/40 ms mismatch is absorbed here: `send(pcm:)` takes the same
  20 ms frame the IAX2 path takes and holds every other one back.
- `M17ReflectorClient.send(_:)`, and `M17Address.broadcast`.

**`hamvoip-cli`**

- `m17` subcommand — link a reflector module and pass audio. The live
  validation harness, and compiled out with a pointer to the build script when
  `Codec2.xcframework` is absent.

### Changed

- **`Package.swift` now adapts to whether `Codec2.xcframework` is present.**
  The framework is never committed, but CI builds a bare checkout and a
  `binaryTarget` naming a missing path is a hard manifest error. The manifest
  probes for it and adds the binary target plus a `CODEC2` compilation
  condition only when it is there. Stream sequencing is written against
  `RadioCore.VoiceCodec` rather than against codec2, so it is covered either
  way — 616 tests without the framework, 624 with it.

  ⚠️ SwiftPM caches the evaluated manifest against its *contents*, not against
  the filesystem this probe reads. Run `swift package reset` after building or
  deleting the framework, or the next build can fail with `local binary target
  'Codec2' … does not contain a binary artifact`. A fresh checkout is
  unaffected.
- `TransmitStateBox` moved from `IAX2Kit` to `RadioCore`, now that both clients
  need it. Source-compatible for anything outside the package, which could not
  see it before.

### Known limitations

Everything listed under 0.1.0 still applies except the M17 entry, which is
superseded by:

- **The M17 audio path has never been run against a real reflector.** Not
  once. The 2026-08-11 on-air session that settled OQ-7 was receive-only and
  had no codec in it. M17 transmit has never been sent to a reflector, the
  decoded audio has never been listened to, and whether a reflector accepts our
  stream at all — the stream ID, the `BROADCAST` destination address, the LSF
  fields — is reasoned from the specification rather than observed.
  `hamvoip-cli m17` exists to settle exactly that, and says so when it starts.
  Treat M17 as believed-working, not as working.
- **The M17 CRC is under-specified by its own specification.** The polynomial
  (`0x5935`) and initial value (`0xFFFF`) are stated; bit order and the
  presence of a final XOR are not, and those are also required to determine a
  CRC. They were settled by measurement against the OQ-7 capture — of the eight
  combinations, exactly one validates the captured frames and it validates all
  52 — and are documented as an observation in
  `docs/reference/PROVENANCE.md`, not as a quotation.
- **Building M17 audio needs a manual step.** `Codec2.xcframework` is not
  committed; run `scripts/build-codec2-xcframework.sh` (needs `cmake`) before
  the codec, its tests, or `hamvoip-cli m17` will build. See
  `docs/reference/CODEC2-XCFRAMEWORK.md`.

## [0.1.0] — 2026-08-10

First release. The AllStarLink/IAX2 path is complete and has been validated
against a real node, including a two-way audio session; `M17Kit` has reflector
control but no audio path and has never been run against a reflector. See
"Known limitations" below before depending on it.

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
- **The IAX2 registration path has run against a real node**, in the session
  that settled OQ-5: four complete §6.1 exchanges — REGREQ → REGAUTH →
  REGREQ+MD5 → REGACK/REGREJ — with correct call numbers, sequence progression
  and ACK discipline in both directions.

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
- MD5 challenge authentication (§8.6.15), lowercase hexadecimal — confirmed
  against a live node, see "Resolved" below.
- Outbound call state machine: NEW, ACCEPT, ANSWER, HANGUP, PING/PONG,
  LAGRQ/LAGRP (FR-1.1).
- Voice path and DTMF (FR-1.5). Media payloads are treated as sample-wise
  rather than as fixed 20 ms slots: a short payload is padded to the slot with
  encoded silence, an over-long one is split across consecutive slots, and only
  an empty payload is rejected. Nothing in §8.7 promises a peer sends exactly
  160 octets, and a live node does not — it sent 44 at the tail of a playback.
  The playout contract is unchanged: every tick is exactly `samplesPerFrame`
  samples.
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

**Tests**

- **Capture-replay conformance tests (IAX-9).** Six fixtures cut from packet
  captures of the maintainer's own sessions against their own ASL3 node, and
  `IAX2ConformanceTests`, which replays the *node's* datagrams through
  `MockTransport` and asserts our side is protocol-valid — frames that parse,
  the peer's call number on every frame after it identifies itself, §7
  sequence numbering with ACKs exempt from the message count, and one ACK per
  acknowledgeable inbound frame echoing its time-stamp (§6.9.1). Covered:
  registration and rejection (§6.1), a full call setup with the node's
  mid-call PING/LAGRQ/DTMF traffic (§6.2, §6.3, §6.7), an inbound over
  switching to mini frames (§8.1.2), and both `0x8000` time-stamp boundaries
  of a 77-second call (§6.10). `scripts/pcap-to-fixture.py` cuts a fixture out
  of a capture; `Tests/FIXTURES.md` records the rules these follow.

  Nothing in `IAX2Kit` had to change to pass them. What they add is a
  regression pin on the parts of the protocol where the RFC leaves room and
  this node took its own path: a Control subclass, an information element and
  a frame type that RFC 5456 does not define, all of which we ACK and carry
  through untouched; a media format written literally where we write it as a
  power of two; and — the one that would be hardest to find any other way — an
  inbound 16-bit time-stamp wrap with no full frame at the boundary, which
  §6.10 says the peer MUST send and this node does not.

**Project**

- Apache-2.0 throughout, with an SPDX identifier on every source file, enforced
  in CI (LP-5).
- Every timer injected via `Clock`, so a full session runs in tests with no
  real-time waits (AU-5).

### Resolved

- **OQ-5 — the MD5 RESULT encoding is hexadecimal.** Settled against a live
  ASL3 node on 2026-08-09 with `hamvoip-cli oq5 --method register
  --exhaustive`: lowercase and uppercase hex both accepted, base64 and raw
  bytes both refused with cause code 29. The node decodes the IE back to bytes
  or compares case-insensitively; the refusals prove it checks the digest at
  all. **What IAX2Kit sends was right, so nothing changed** — the §8.6.15
  encoding is an observation rather than an assumption. It remains an
  observation about one implementation: `oq5Default` stays lowercase hex,
  because another peer may compare byte-for-byte.

### Known limitations

- **The MD5 RESULT encoding is confirmed against one implementation, not
  against the protocol.** RFC 5456 §8.6.15 still does not state it, and the
  clean-room policy (LP-2) forbids reading an implementation to find out. A
  peer that compares the digest byte-for-byte would refuse what we send.
  `IAX2Call.Configuration.md5ResultEncoding` overrides the call path;
  `IAX2Registrar` hard-codes the default and has no such seam, and a
  `raw-bytes` encoding is not expressible at all — `TextDigestEncoding` renders
  to a `String` and `InformationElement.md5Result` takes one. Both are hygiene
  items rather than defects while hex is what nodes accept.
- **Each over opens by bursting the buffered capture frames** rather than
  pacing them at 20 ms. One node answered with `VNAK` ×3 at the first voice
  frame; the retransmission engine recovered and audio was intelligible
  throughout. Tracked as IAX-10.
- **Two on-air checks are outstanding**: PTT edge timing, which a full-duplex
  `Echo()` target cannot show, and the `Ctrl-C` / `kill` teardown paths. The
  `q` teardown path is verified on the wire.
- **On-air validation is against one node.** Every live observation here comes
  from a single ASL3 node (Asterisk + app_rpt) in a VM. No hardware node, no
  other Asterisk version, no other implementation.
- **M17 is unvalidated and has no audio path.** Stream mode is unimplemented
  pending OQ-7, the question of whether the IP stream frame is 56 or 54 bytes,
  which cannot be settled from the specification. There is no `M17Client`, and
  none of `M17Kit` has been run against a reflector.
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

[Unreleased]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/cpmpercussion/swift-hamvoip/releases/tag/v0.1.0
