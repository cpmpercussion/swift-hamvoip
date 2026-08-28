# swift-hamvoip — Development Plan

**Status:** v1.0 — derived from `DESIGN-REQUIREMENTS.md` (Draft v0.1)
**Audience:** implementation agents executing one task at a time.

This document decomposes the requirements into small, ordered, independently
verifiable tasks. **It is the library's task list.** The app's — `APP-*` and
`BLE-*` — moved to `currawong/docs/DEVELOPMENT-PLAN.md` on 2026-08-21; §1 below
still governs both, and `docs/DESIGN-REQUIREMENTS.md` is still the one authority
for requirement IDs on both sides. Design decisions have already been made here; do not
re-litigate them. If a task is impossible as written, stop and report why —
do not improvise a different design.

---

## 1. How to work (read before every task)

1. **One task per branch per PR.** Branch name: `task/<task-id>`, e.g.
   `task/rc-2`. PR title: `[RC-2] G.711 µ-law codec`. Wait for CI to pass and
   address review comments before merge.
2. **Verify before starting:** `swift build && swift test` must pass on `main`
   before you branch. It must still pass, with your new tests included, before
   you open the PR. (Exception: BOOT-1 exists precisely because `main` does
   not currently build — it is the only task allowed to start from a red
   baseline.)
3. **Clean-room policy is absolute (LP-1, LP-2).** You may consult: RFC 5456,
   the M17 specification (spec.m17project.org), ITU-T G.711, and fixtures
   already in this repository. You MUST NOT fetch, read, or search the source
   code of DroidStar, SvxLink, EchoLib, thebridge, iaxclient, Asterisk, or any
   other implementation of these protocols. If a web search result is a source
   file from such a project, close it. Do not copy test fixtures from other
   projects.
4. **Every new Swift file starts with** `// SPDX-License-Identifier: Apache-2.0`
   on line 1. CI rejects files without it.
5. **No network in unit tests (AU-5).** Anything that touches a socket lives
   behind `DatagramTransport` (task RC-1). Tests use `MockTransport` and
   recorded byte fixtures only.
6. **Numeric constants in this plan are a convenience, not an authority.**
   Before implementing a parser, check every constant against the cited spec
   section. If plan and spec disagree, the spec wins; note the discrepancy in
   the PR description.
7. **Don't expand scope.** No extra codecs, no encryption UI (FR-2.5), no
   CallKit (PD-4), no volume-button PTT (PT-6), no AMBE modes while AMBE is
   patent-encumbered (NG-1), no `voip` background mode (PD-2 — it is PD-4 by
   another route; the reasoning is written out there now rather than left
   implicit).
8. **Style:** Swift 5.9, `async/await`, actors for stateful components,
   value types for frames/parsers, XCTest. No third-party Swift dependencies
   without a task that says so.
9. **Do not edit `Package.swift`** unless your task explicitly says to. Every
   target, test target and resource directory later tasks need already
   exists. Tasks that do need a manifest change: CLI-1 (executable target),
   M17-4 (codec2 shim target).
10. **Actor reentrancy: never infer "is an operation in flight?" from mutable
   state.** This cost a real hang in M17-3. `connect()` awaited
   `transport.send`, and an actor is reentrant across an await, so the receive
   loop handled the reply *before* `connect()` parked its continuation. The
   reply handler set `state = .linked` and then delivered the outcome, but the
   delivery path only stashed an early result while `state == .connecting` — so
   the success was dropped and `connect()` waited forever. It reproduced in
   about 4% of whole-suite runs and never once in 60 runs of that class alone.

   Two patterns that are safe, both in the codebase now:
   - Track the in-flight operation with its own dedicated flag, independent of
     any state the completion path mutates (`M17ReflectorClient`).
   - Re-check the terminal conditions and park the continuation in the **same
     actor-isolated synchronous region**, with no await between the check and
     the park, so no interleaving is possible (`IAX2Call.waitUntilUp()`).

   When you write a continuation-parking API, add a test that delivers the
   completion from *inside* the awaited call. See
   `testConnectReturnsWhenAcknIsProcessedDuringSend`. A test that only exercises
   the common ordering will not find this.
11. **Working in the app? §1 still applies; the task list does not live here.**
   Every rule above is repository-independent and binds `currawong` too — one
   task per branch, the clean-room policy, SPDX, no unit test that opens a
   socket, no dependency without a task. The tasks themselves are in
   `currawong/docs/DEVELOPMENT-PLAN.md`, and that file's own "How to work"
   carries the four rules that are the app's alone (the generated project file,
   the terminal-only build, `CompositionRoot.swift` as the only place a
   protocol-specific client may be named, and the versioned dependency).
12. **Shared test helpers live in `Tests/TestSupport/`** (target `TestSupport`,
   depended on by all three test targets, deliberately not a product). Put
   anything more than one test target needs there — `FixtureLoader` is
   already in place; `MockTransport` joins it in RC-1.

## 2. Current state

**Updated 2026-08-17.** Everything below is checked against the tree, not
remembered; if it disagrees with the repository, the repository is right.

- `Package.swift` defines four library products — `RadioCore`, `IAX2Kit`,
  `M17Kit`, `EchoLinkKit` — plus the `hamvoip-cli` executable, the vendored
  `CGSM` target, a test-only `TestSupport` target and five test targets. One
  Swift dependency, `swift-argument-parser`, authorised by CLI-1; `CGSM` is
  vendored C, not a dependency (EL-8, LP-4).
- `swift build` and `swift test` are green: **1016 tests, no failures**
  (checked 2026-08-20, at the v0.5.3 tag). One of those is skipped unless
  `HAMVOIP_TEST_STATION_LIST` names a directory-list download — the EL-11
  conformance test, which cannot ship its data. CI runs the SPDX check on
  Ubuntu and build + test on macOS 14.
- **`EchoLinkKit` is complete, and Phase 6 is done.** Proxy framing, proxy
  login, directory login, RTP, the synthesised playout clock, GSM 06.10,
  `EchoLinkClient` and the station list are all in and tested. **Milestone M3
  passed 2026-08-13**: a live QSO through `*ECHOTEST*` from `hamvoip-cli
  echolink`, audio intelligible both ways. `--list` was confirmed against a
  live directory server the same day — 6389 entries, count matching — so
  nothing in Phase 6 is now unproven on air.

  **One declared-but-unbuilt piece, deliberately:** `Route.direct` throws
  `.directModeUnavailable`, because no capture of a direct (non-proxied) session
  exists and the port assignment and socket setup are therefore unobserved. The
  framing is known — strip a proxy frame's 9-byte header and what remains is
  what direct mode would put on the wire. FR-3.3 requires the *proxy* and makes
  it the default on cellular, so nothing on mobile data is blocked, and no task
  is open for this. Building it needs an on-air direct session captured first;
  whether that is worth doing is a maintainer call, not an oversight.
- **Released as `v0.3.0`, 2026-08-13** — the release that carries Phase 6.
  `v0.2.0` predates `EchoLinkKit` entirely, so Currawong's `from: 0.2.0` pin
  resolves forward to it without a manifest change.
- **Released as `v0.5.0`, 2026-08-17** — Web Transceiver (IAX-12) plus a
  pre-release review's fixes, the largest being an SF-1 reentrancy race that
  could key the transmitter with the watchdog disarmed, present in all three
  clients and now fixed in all three (with `TransmitWatchdog` gaining a
  token-scoped `cancel(ifCurrent:)` to make the fix race-proof against a
  concurrent double key-up). This is the release Currawong's APP-11 pins.
  962 tests green at the tag.
- **Released as `v0.5.1`, 2026-08-17** — a CLI and docs pass, no library
  behaviour change: one command per protocol (`iax2` with `connect` kept as an
  alias, `echolink`, `m17`), the OQ probes moved under `experiment`, and
  `--version` now reports the package version instead of a stale `0.1.0`.
- **Released as `v0.5.3`, 2026-08-20** — RC-11, EL-15, CLI-2, CLI-3 and OQ-10.
  Cut because Currawong's BU-3 needs a tag carrying RC-11's
  `AudioPipeline.activateSession()` before it can delete the app's hand-kept copy
  of the audio-session policy. **A patch bump carrying two renames**, both
  without a fallback: `HAMVOIP_SECRET` → `IAX2_SECRET` (CLI-3) and the test-only
  `HAMVOIP_ECHOLINK_STATION_LIST` → `HAMVOIP_TEST_STATION_LIST`. Patch rather
  than minor is the maintainer's call, on the grounds that no library API
  changed — all four products are source-compatible with v0.5.2 — and the breaks
  belong to the CLI harness and a test knob. 1016 tests green at the tag, 2
  skipped.
- **Released as `v0.5.2`, 2026-08-17** — IAX-13, the Web Transceiver token
  fetch, plus `hamvoip-cli wt-token`. Cut on its own because Currawong's APP-12
  settings screen has the portal-login pane written and disabled until a tag
  carries the fetch; nothing else changed behaviour. 981 tests green at the tag.
- **Released as `v0.4.0`, 2026-08-13** — EL-12, public proxy discovery. Cut as
  its own release because the app needs it: FR-3.3 makes the proxy the default on
  cellular, so every EchoLink session Currawong opens needs a proxy host, and
  until this there was no way to get one that did not involve a human reading
  echolink.org. `EchoLinkProxySelector` is what the composition root calls
  instead.
- **`NetworkClient` is now a seam an app can actually be written against**
  (RC-10, 2026-08-13). It carries `radioEvents`, `receivedAudio` and
  `send(pcm:)` besides `state` and the four verbs, so Phase 4 can report why a
  link dropped without naming a protocol-specific type. All three clients
  translate their own event vocabulary onto `RadioEvent` from inside their single
  `emit`. **Note for anything already calling the clients directly:** the
  frame-returning `send(pcm:)` is now `transmit(pcm:)`; `send(pcm:)` returns
  `Void` and is the protocol requirement.
- `RadioCore` and `IAX2Kit` are complete. `M17Kit` has reflector control,
  base-40 callsigns and stream-packet parse/serialise, but **no codec wiring
  and no `M17Client`** — M17-4 and M17-5 are the remaining work there.
- **`IAX2Kit` has been validated against a real node** (ASL3 in a VM,
  2026-08-09): registration, authentication — which settled OQ-5 — and then a
  full two-way audio session. **Milestone M2 has passed** (`docs/CLI.md` §6):
  speech intelligible both ways, DTMF round-tripped, the SF-1 watchdog cut
  transmission at exactly its limit, teardown clean. Two items want a re-run
  before v1 (PTT edges, the signal teardown paths) and one wart is tracked as
  IAX-10. **IAX-9 is done:** those sessions are now six `live-*.hex` fixtures
  replayed by `IAX2ConformanceTests`, so registration, call setup, an inbound
  over and both `0x8000` time-stamp boundaries are regression-tested against
  what a real node put on the wire, not only against our reading of the RFC.
- **A second live node, 2026-08-10** — `wintermute`, node 44309, ASL on a LAN,
  reached over `hamvoip-cli`. MD5 authentication, `ulaw` call setup and
  teardown all worked, which corroborates OQ-5 on the `connect` path against a
  *different* implementation than the one that settled it. The session also
  turned up **IAX-11**: the node has two interfaces and answers from the one
  that was not dialled, which the transport cannot cope with and reports as an
  unrelated socket error.

Per-task status is on the task headings themselves — `✅ DONE` where the work
has merged and the code it describes exists.

## 3. Phase map and dependencies

```
Phase 0  Bootstrap        BOOT-1             ✅ complete
Phase 1  RadioCore        RC-1 … RC-13       ✅ complete
Phase 2  IAX2Kit          IAX-1 … IAX-13     IAX-10, IAX-11 open
Phase 3  CLI harness      CLI-1 … CLI-3      ✅ complete
Phase 4  SwiftUI app      APP-1 … APP-22     ✅ all closed → the app's own plan
Phase 5  BLE PTT          BLE-1 … BLE-3      ✅ shipped as APP-5 → the app's plan
Phase 6  EchoLink         EL-1 … EL-15       ✅ complete; M3 2026-08-13, and
                                             since run from the app
Phase 7  M17Kit           M17-1 … M17-7      RX proven 2026-08-16; TX heard
                                             2026-08-17. M17-6 re-scoped, open;
                                             M17-7 added Weebill alongside codec2
Phase 8  Silent mode      SIL-1              🔬 spike first — nothing scheduled
```

**Everything still open, in one list**, as of 2026-08-21:

| | What | Where | Size |
|---|---|---|---|
| **M17-6** | A chosen destination — DST is still hard-coded `BROADCAST`. The parrot half of this task is no longer needed: transmit was confirmed heard 2026-08-17 (see the M17-5 row) | here | Small library change; no longer gates anything |
| **IAX-10** | Pace transmitted frames instead of bursting them | here | Small |
| **IAX-11** | Say "the node answered from another address" instead of `ENOTCONN` | here | Small; decided, unimplemented |
| **SIL-1** | Silent operating mode — design spike, on-device STT/TTS. The one app task never scoped; Phase 8 below still holds its write-up, and it moves to the app's plan when it is taken up | `currawong` | Unscoped by design |
| **OQ-6** | Codec2 LGPL relinking vs App Store signing | maintainer | Deferred until submission, deliberately — and *avoidable* since M17-7, not resolved |

**Phases 4 and 5 are somebody else's file now** — both moved to
`currawong/docs/DEVELOPMENT-PLAN.md` on 2026-08-21, closed, with the reasoning
under the stub where they used to be. Neither had an open row when they went.

That is not the same as the app being finished; what remains for it is in
`currawong/docs/BRINGUP.md`, its fault list. As of 2026-08-21: **BU-7** (the
watchdog and a phone call dropping transmit, neither ever *observed*), **BU-10**
(the Live Activity, never seen on a locked iPhone), **BU-11** (AppKit's empty
one-time-code AutoFill panel — diagnosed, nothing to fix in the app, a decision
about whether to report it to Apple) and **BU-13/BU-14** (the first Bluetooth
accessory, whose audio and whose button both stop working; neither diagnosed).
**BU-12** closed the same day this file stopped carrying app tasks — the app was
taller than its window because of a `fixedSize` in the sidebar. **None of those
are tracked here**, and the two lists are read in the app's repository, not this
one.

**OQ-1b is not on that list on purpose.** It is settled as a *standing
constraint* rather than an open decision: "EchoLink" is nominative use only,
never in the app's name, icon, launch screen or App Store metadata. It binds
every future task and needs no further answer.

✅ **The last claim gap closed on 2026-08-17: our M17 transmit has been
confirmed heard.** The maintainer transmitted from Currawong to M17-434 module
B and monitored the reflector with Mseven, an independent M17 client, on the
same session — audio readable both ways. That is the "second receiver" the
M17-5 row asked for: an implementation this project did not write found our
transmission intelligible. Every mode now has both directions confirmed on air
— EchoLink from the app on 2026-08-16 (`*ECHOTEST*` end to end, and VK1RBM
heard live off-air on UHF), M17 receive the same evening against a net on
M17-434, and re-verified 2026-08-17 alongside AllStarLink audio on a parrot
node. Scope caveat, in the standing style: one reflector, one receiving
implementation, one operator at both ends — a stronger claim (another
*operator's* station and decoder) is still available cheaply and worth taking
when it offers itself, but nothing is gated on it.
App-side bring-up state lives in `currawong/docs/BRINGUP.md` (`BU-2`, `BU-4`,
`BU-5`), which this file does not own and which is behind these findings.

Within a phase, tasks are ordered; a task lists its hard dependencies. Tasks
with no unmet dependency may proceed in parallel on separate branches.

**Milestone M1** (end of Phase 2): a full transmit/receive audio path runs
against `MockTransport` from recorded IAX2 fixtures — no radio required.
**Milestone M2** (end of Phase 3): a human completes a live QSO with an
AllStar node using the CLI harness on macOS.
**Milestone M3** (end of Phase 6, task EL-10): a human completes a live
EchoLink QSO using the CLI harness. ✅ **passed 2026-08-13.**

---

## Phase 0 — Bootstrap

### BOOT-1 — Make the package build and test green ✅ DONE
**Depends on:** nothing. **Blocks:** every other task.

Created the missing source directories so every declared target is non-empty,
plus the fixture infrastructure originally scoped as RC-8 (folded in here
because it changes `Package.swift`, which no parallel task may touch):

- `Sources/IAX2Kit/IAX2Kit.swift`, `Sources/M17Kit/M17Kit.swift` — namespace
  enums holding the default ports.
- `TestSupport` target at `Tests/TestSupport/` with `FixtureLoader`
  (hex-dump fixtures, `#` comments, loaded via a passed-in `Bundle`).
- Three test targets — `RadioCoreTests`, `IAX2KitTests`, `M17KitTests` —
  each with a `Fixtures/` resource directory.
- `Tests/FIXTURES.md` records the fixture provenance rule (LP-1).

**RC-8 is therefore complete**; later tasks just add fixture files.

## Phase 1 — RadioCore

### RC-1 — `DatagramTransport` abstraction + mock ✅ DONE
**Depends on:** nothing.
**Files:** `Sources/RadioCore/DatagramTransport.swift`,
`Sources/RadioCore/NWDatagramTransport.swift`,
`Tests/RadioCoreTests/MockTransportTests.swift`.

Define the seam that keeps sockets out of protocol code:

```swift
public protocol DatagramTransport: Sendable {
    /// Datagrams received from the peer, in arrival order.
    var incoming: AsyncStream<Data> { get }
    func send(_ datagram: Data) async throws
    func close() async
}
```

Provide `NWDatagramTransport` (final class wrapping `NWConnection`, UDP,
per PD-1 — `Network.framework`, never BSD sockets) and, in
`Tests/TestSupport/MockTransport.swift`, `MockTransport`: records sent
datagrams into an array, exposes a method to inject inbound datagrams into
`incoming`. It goes in `TestSupport`, not a test target, because IAX-3,
IAX-5, IAX-8 and M17-3 all need it.

**Done when:** tests prove MockTransport round-trips injected datagrams in
order and captures sends; `NWDatagramTransport` compiles (no live-network
test — that's deliberate).

✅ **DONE.** Note for IAX-8: `NWConnection` treats `.waiting` as recoverable
and retries internally, so an unreachable node makes `send` hang rather than
throw. **A connect timeout must be implemented one layer up, in `IAX2Call`
or `IAX2Client` — the transport will not surface it.**

Two lifecycle bugs found in review and fixed: `send` ignored task cancellation
while awaiting readiness (leaking a task and a continuation per attempt, which
booby-trapped exactly the connect-timeout pattern above), and `incoming` never
finished when a transport was dropped without `close()`, contradicting the
protocol's documented contract and leaking a live UDP connection.

⚠️ **Known remaining hazard.** The `connection.send(...)` *completion*
continuation — as distinct from the readiness wait — is still not
cancellation-aware. It is safe today because only the connect phase is raced
against a deadline. **If any caller ever races an in-flight `send` against a
timeout, fix this first**; doing so needs double-resume protection, since the
real `NWConnection` completion can fire after a cancellation-triggered early
resume.

### RC-2 — G.711 µ-law codec ✅ DONE
**Depends on:** nothing. **Spec:** ITU-T G.711 (µ-law).
**Files:** `Sources/RadioCore/Codecs/G711MuLawCodec.swift`,
`Tests/RadioCoreTests/G711MuLawCodecTests.swift`.

`struct G711MuLawCodec: VoiceCodec`. 8 kHz, 20 ms framing:
`samplesPerFrame = 160`, `bytesPerFrame = 160`. Implement encode/decode as
the standard segment/mantissa bit algorithm from the ITU spec (bias 0x84,
8 segments, complemented output byte) — computed, not a table pasted from
elsewhere.

**Done when:** tests cover: PCM 0 encodes to 0xFF; decode(encode(x)) is
within µ-law quantisation error for a sweep of values including ±32767 and
±1; encode is monotonic in |x| per sign; wrong-length input throws.

### RC-3 — Jitter buffer, fixed depth ✅ DONE
**Depends on:** nothing. **Files:** rewrite
`Sources/RadioCore/JitterBuffer.swift`,
`Tests/RadioCoreTests/JitterBufferTests.swift`.

Pull-model buffer, no clocks, no threads — the caller owns time (AU-5):

```swift
public struct TimedFrame: Sendable, Equatable {
    public let timestamp: UInt32   // ms, monotonic per stream
    public let payload: [UInt8]
}
public enum JitterOutput: Sendable, Equatable {
    case frame([UInt8])        // in-sequence payload
    case concealment           // gap: caller repeats/fades last frame
    case silence               // buffer starving or not yet primed
}
public struct JitterBuffer {
    public init(frameDuration: Duration, targetDepth: Duration)
    public mutating func push(_ frame: TimedFrame)
    public mutating func pop() -> JitterOutput   // called once per frame tick
}
```

Behaviour: buffer primes until `targetDepth` of audio is queued, then emits
one frame per `pop()`. Late frames (timestamp older than last popped) are
dropped. Out-of-order frames within the window are reordered by timestamp.
A missing timestamp slot yields `.concealment`. Duplicate timestamps: keep
first, drop rest.

**Done when:** table-driven tests cover in-order, reordered, duplicate,
late, single-loss, burst-loss, and starvation sequences, asserting the exact
`JitterOutput` sequence for each.

### RC-4 — Jitter buffer, adaptive depth (AU-3) ✅ DONE
**Depends on:** RC-3.

Add an inter-arrival variance estimator (running mean absolute deviation of
arrival deltas is sufficient). Target depth = clamp(k·deviation, 60 ms,
200 ms), defaults per AU-3. Depth changes apply at talk-spurt boundaries
(after ≥ 200 ms of `.silence`), never mid-stream. `push` gains an
`arrivedAt: ContinuousClock.Instant` (or plain `Duration` offset) parameter
supplied by the caller so tests fully control time.

**Done when:** tests show depth grows under jittery synthetic arrival
patterns, shrinks back under steady ones, stays within [60, 200] ms, and
never changes mid-spurt.

✅ **DONE.** Estimator is the RFC 3550-style relative transit difference
`D = (arrival₂ − arrival₁) − (timestamp₂ − timestamp₁)`, EWMA'd with
α = 1/8; target = clamp(4 · deviation, 60 ms, 200 ms). Starvation un-primes
the buffer and re-anchors the playout grid to the new head frame — without
that, resuming after a long gap emits one concealment per missed slot.
Timestamp wraparound at 2³² ms is explicitly out of scope here:
**IAX-6 owns 16→32-bit timestamp expansion** before frames reach the buffer.

### RC-5 — Transmit watchdog (SF-1) ✅ DONE
**Depends on:** nothing.
**Files:** `Sources/RadioCore/TransmitWatchdog.swift` + tests.

`actor TransmitWatchdog`: `start(timeout: Duration, onExpiry: @Sendable () async -> Void)`,
`cancel()`. Default timeout 180 s. Inject the clock
(`any Clock<Duration>`) so tests drive expiry without waiting.

**Done when:** tests prove expiry fires exactly once, cancel prevents it,
and restart resets the deadline.

### RC-6 — Received-audio leveller (AU-4) ✅ DONE
**Depends on:** nothing.
**Files:** `Sources/RadioCore/AudioLeveller.swift` + tests.

`struct AudioLeveller`: `mutating func process(_ pcm: inout [Int16])`.
Slow AGC toward a target RMS (default −18 dBFS), attack ≈ 50 ms, release
≈ 500 ms, hard gain ceiling +18 dB, never amplifies frames below a noise
floor (default −55 dBFS RMS). Pure DSP on buffers — no AVFoundation.

**Done when:** tests: a −30 dBFS sine converges near target within 2 s of
synthetic frames; a −60 dBFS noise frame is not boosted; a 0 dBFS input is
attenuated without wrap-around clipping artifacts (output clamped).

### RC-7 — Audio pipeline (AU-1, AU-2) ✅ DONE
**Depends on:** RC-2, RC-3, RC-6.
**Files:** `Sources/RadioCore/AudioPipeline.swift`.

`final class AudioPipeline`: wraps `AVAudioEngine` + `AVAudioConverter` for
48 kHz Float32 ↔ 8 kHz Int16 mono. API: `startCapture(onFrame: ([Int16]) -> Void)`
delivering 160-sample frames; `enqueuePlayback(_ pcm: [Int16])`;
`stop()`. Configure `AVAudioSession` `.playAndRecord`/`.voiceChat` under
`#if os(iOS)`. Keep every pure-DSP piece (frame chunking, format conversion
glue) in small internal functions with direct unit tests; the engine wiring
itself is exercised later by CLI-1, not by unit tests.

**Done when:** builds for macOS and iOS; chunking/conversion helpers have
unit tests (e.g. 48 k→8 k of a known sine preserves frequency, output frames
are exactly 160 samples).

### RC-8 — Fixture infrastructure ✅ DONE (folded into BOOT-1)

---

## Phase 2 — IAX2Kit (RFC 5456)

**Read `docs/reference/RFC5456-NOTES.md` first.** It is a transcription of the
RFC's tables and rules made specifically for these tasks, with section
citations throughout. The RFC itself remains the authority; the notes exist so
five tasks do not re-derive the same tables five times.

The notes confirmed every numeric constant this plan asserts — frame types,
IAX subclasses, the fourteen IEs, and µ-law = `1<<2`. They also turned up
things that change how these tasks must be written:

- **The RFC contradicts itself in four places.** Mini-frame resync interval
  (32,768 ms MUST in §6.10 vs 65,536 ms SHOULD in §8.1.2 — satisfy both by
  resyncing at every 0x8000 boundary); retransmit timing (§7.2.1 vs §8.1.1);
  the §6.9.1 ACK list omitting RINGING/ANSWER, which §9.6 does ACK; and
  ISeqno's definition (§8.1.1 "next expected" vs §7 "highest received", off by
  one — implement §8.1.1, be tolerant on receive). Each is documented in the
  notes with both citations. Follow the notes and do not silently pick a side.
- **OSeqno is not incremented by ACK, INVAL, TXCNT, TXACC or VNAK** — this
  plan previously named only ACK and INVAL. See IAX-3.
- **An ACK echoes the timestamp of the frame it acknowledges** (§6.9.1). That
  echo is how a peer matches an ACK to an outstanding frame; the
  retransmission engine depends on it.
- **There is no plaintext auth path.** IE PASSWORD (0x07) is in Table 1 but
  has no defining subsection, AUTHMETHODS 0x0001 is "Reserved (was
  Plaintext)", and §10 says cleartext has been eliminated. Only MD5 (0x0002)
  and RSA (0x0004) are live. Do not build a plaintext path.
- **Control HANGUP (type 0x04, subclass 0x01) is not IAX HANGUP (type 0x06,
  subclass 0x05).** Do not conflate them.
- **The RFC never says "network byte order" anywhere.** Big-endian is an
  inference from the packet diagrams. APPARENT_ADDR is worse: the RFC's own
  example shows family `0x0200` (little-endian 2) beside port `0x11d9`
  (big-endian 4569) in the same struct. Treat its family field as suspect and
  tolerate both readings.
- **Retry limit is 4, and exhausting it tears the call down silently** — no
  HANGUP is sent to a peer that has stopped answering.

### IAX-1 — Frame model: parse + serialize ✅ DONE
**Depends on:** RC-8.
**Files:** `Sources/IAX2Kit/IAX2Frame.swift`,
`Tests/IAX2KitTests/IAX2FrameTests.swift`.

Value types for the two wire formats (RFC 5456 §8.1):

- **Full frame** (12-byte header): bit F=1 + 15-bit source call number;
  bit R (retransmission) + 15-bit destination call number; 32-bit
  timestamp; 8-bit OSeqno; 8-bit ISeqno; 8-bit frame type; bit C +
  7-bit subclass. Payload follows.
- **Mini frame:** F=0 + 15-bit source call number; 16-bit timestamp;
  payload (voice data).

Frame types (verify §8.2): DTMF=1, Voice=2, Video=3, Control=4, Null=5,
IAX=6, Text=7, Image=8, HTML=9, ComfortNoise=10.
IAX subclasses (verify §8.4): NEW=1, PING=2, PONG=3, ACK=4, HANGUP=5,
REJECT=6, ACCEPT=7, AUTHREQ=8, AUTHREP=9, INVAL=10, LAGRQ=11, LAGRP=12,
REGREQ=13, REGAUTH=14, REGACK=15, REGREJ=16, REGREL=17, VNAK=18.

`parse(Data) throws -> IAX2Frame` and `func encoded() -> Data`. All
multi-byte fields big-endian.

**Done when:** round-trip property tests (random valid frames encode→parse
identically); truncated/garbage input throws rather than crashes; a
hand-written hex fixture of a NEW frame built field-by-field from the RFC
parses to the expected values.

### IAX-2 — Information elements ✅ DONE
**Depends on:** IAX-1.
**Files:** `Sources/IAX2Kit/InformationElement.swift` + tests.

TLV parser/serializer for the IE block in full-frame payloads (§8.6): one
byte IE id, one byte length, data. Implement at minimum (verify ids):
CALLED_NUMBER=0x01, CALLING_NUMBER=0x02, CALLING_NAME=0x04, USERNAME=0x06,
PASSWORD=0x07, CAPABILITY=0x08, FORMAT=0x09, VERSION=0x0b, ADSICPE=0x0c,
CHALLENGE=0x0f, MD5_RESULT=0x10, APPARENT_ADDR=0x12, REFRESH=0x13,
CAUSE=0x16. Unknown IEs are preserved as raw (id, bytes) — never a parse
failure. Codec bitmask: µ-law = 1<<2 (verify against §8.7).

**Done when:** round-trip tests; unknown-IE passthrough test; a NEW
payload fixture with USERNAME+CALLED_NUMBER+CAPABILITY+FORMAT+VERSION
parses correctly.

### IAX-3 — Sequence/retransmission engine ✅ DONE
**Depends on:** IAX-1.
**Files:** `Sources/IAX2Kit/ReliableChannel.swift` + tests.

Actor owning OSeqno/ISeqno bookkeeping per RFC 5456 §7: full frames (except
**ACK, INVAL, TXCNT, TXACC, VNAK**, and mini frames) increment OSeqno and
require acknowledgement — note that list is longer than earlier drafts of this
plan claimed, and that an ACK **echoes the acknowledged frame's timestamp**,
which is how you match it to an outstanding frame;
retransmit with backoff (initial 500 ms, ×2, max 4 attempts, then declare
the call dead); inbound full frames update ISeqno and trigger ACK where the
RFC requires it. Inject the clock. Transport is `DatagramTransport`.

**Done when:** tests with MockTransport + manual clock cover: ACK stops
retransmission; missing ACK retransmits with R bit set and correct backoff;
exhausted retries surface an error; inbound frame ordering updates ISeqno
correctly.

### IAX-4 — MD5 challenge authentication ✅ DONE
**Depends on:** IAX-2.
**Files:** `Sources/IAX2Kit/IAX2Auth.swift` + tests.

AUTHREQ → AUTHREP flow (§6.2, §8.6.15): MD5_RESULT = the MD5 of the challenge
string concatenated with the password string, challenge first, no separator.
Use `Insecure.MD5` from CryptoKit, guarded with `#if canImport(CryptoKit)`.
Pure function: `md5Response(challenge: String, secret: String) -> String`.

**Support MD5 only.** There is no plaintext path (see the Phase 2 preamble);
RSA (AUTHMETHODS 0x0004) is out of scope for v1 — reject it with a clear
error rather than failing obscurely.

✅ **OQ-5 lived here, and is settled.** §8.6.15 says the IE carries the
*UTF-8-encoded* MD5 result, but the RFC never states the text encoding — hex
or not, upper or lower case. LP-2 forbade reading an implementation to settle
it, so it shipped as an assumption — **lowercase 32-character hex**, isolated
behind a single named function with a `// OQ-5:` comment — and was confirmed
against a live ASL3 node on 2026-08-09. The assumption was right; the
function stays as it is. See the open-questions table for the evidence and for
what the result does and does not license.

**Done when:** test vectors computed by hand (e.g. via the `md5` CLI, noted in
a comment) pass; empty challenge/secret handled; the encoding assumption is
isolated and commented.

### IAX-5 — Call state machine ✅ DONE
**Depends on:** IAX-2, IAX-3.
**Files:** `Sources/IAX2Kit/IAX2Call.swift` + tests.

Actor implementing the outbound-call FSM (§6.2):
`idle → newSent → (authreq→authrep) → accepted → answered → up`, plus
`hangupSent/receivedHangup → dead`, REJECT handling, PING/PONG and
LAGRQ/LAGRP responders, INVAL on frames for unknown calls. States are an
enum; illegal transitions throw. Local call number allocation (1…32767).

**Done when:** a scripted MockTransport session (fixture: the datagram
sequence of a successful NEW→ACCEPT→ANSWER call, then HANGUP) drives the
FSM to `up` and back to `dead`; REJECT path and auth path each have a test;
PING receives PONG with matching timestamp.

### IAX-6 — Voice path ✅ DONE
**Depends on:** IAX-5, RC-2, RC-3.

Wire audio through the call: outbound — first voice frame after format
change is a full VOICE frame carrying the codec subclass (µ-law), then
mini frames with 16-bit truncated timestamps; regenerate a full frame
whenever the 16-bit timestamp would wrap. Inbound — mini-frame timestamps
are re-expanded against the call's 32-bit clock and pushed into
`JitterBuffer`; popped output is decoded via `G711MuLawCodec`.

**Done when:** tests: timestamp truncation/expansion across a wrap
boundary; full-frame-then-mini ordering on transmit; a fixture stream of
mini frames plays out of the jitter buffer in correct order.

### IAX-7 — DTMF (FR-1.5) ✅ DONE
**Depends on:** IAX-5.

`send(dtmf: Character)` on the call actor: full frame, type DTMF, subclass =
ASCII digit (verify §8.3 for begin/end semantics — implement what the RFC
requires, RFC-level only). Validate character set `0-9*#A-D`.

**Done when:** encoded frames match hand-built fixtures; invalid characters
throw.

### IAX-8 — `IAX2Client`: public API ✅ DONE
**Depends on:** IAX-4…IAX-7, RC-5.
**Files:** `Sources/IAX2Kit/IAX2Client.swift` + tests.

The one type apps see. Conforms to `NetworkClient` with
`Destination = IAX2Destination`:

```swift
public struct IAX2Destination: Sendable {
    public let host: String
    public let port: UInt16          // default 4569
    public let callsign: String
    public let username: String
    public let secret: String
    public let node: String          // called number, e.g. "55553"
}
```

Composes transport, call actor, watchdog (start on `startTransmit`, auto
`stopTransmit` + state change on expiry — SF-1), jitter buffer, codec,
leveller. Exposes `AsyncStream<[Int16]>` of received PCM and accepts
transmit PCM frames; `AudioPipeline` is attached by the app layer, not here.
Covers FR-1.2 (direct); registered-node/Web-Transceiver REGREQ flow
(FR-1.3) is a follow-up subtask IAX-8b using the same fixture pattern.

⚠️ **Two things IAX-6 deliberately left for you:**
1. **VNAK is not sent** when a mini frame arrives before the codec is pinned,
   though §6.9.3 says one should be. VNAK is a sequenced full frame that only
   `ReliableChannel` may emit, and IAX-6 was not permitted to touch it — the
   frame is dropped and reported as `.codecNotPinned` instead. You own both
   sides of that seam, so wire it up if you agree it is worth it.
2. IAX-6/7 have no clock: **IAX-8 supplies the 20 ms playout tick** and pumps
   `call.events` into `IAX2VoiceStream.handle(_:)`.

**Done when:** end-to-end test: scripted fixture session connects,
transmits 1 s of synthetic tone (asserting emitted datagram shapes),
receives fixture voice datagrams and yields decoded PCM; watchdog expiry
forces stopTransmit. **This is Milestone M1.**

### IAX-8b — Registration, registered node mode (FR-1.3, first half) ✅ DONE

⚠️ **This delivers registered node mode only.** FR-1.3 also asks for Web
Transceiver mode, which **IAX-12 delivered on 2026-08-17** (OQ-10 resolved the
same day). Read a ✅ on this row as "registration works" — FR-1.3 is met by
this row *and* IAX-12 together, not by this one alone.

**Depends on:** IAX-8 ✅. Written up after the fact: the work merged in
`9794a8d` while the plan still mentioned it only as "a follow-up subtask"
inside IAX-8, with no entry of its own.

`IAX2Registrar` (`Sources/IAX2Kit/IAX2Registration.swift`) implements the
REGREQ → REGAUTH → REGREQ+MD5 → REGACK exchange of §6.1, plus REGREL,
refresh at a jittered fraction of the granted validity period (§7.2.2) and a
geometric retry ladder with a configurable ceiling. Events surface as
`refreshScheduled`, `retryScheduled` and `gaveUp`.

**Validated live on 2026-08-09** against an ASL3 node (Asterisk + app_rpt, in
a UTM VM), by the four `hamvoip-cli oq5 --method register` probes that settled
OQ-5. All four completed the §6.1 exchange end to end — REGREQ → ACK →
REGAUTH → ACK → REGREQ+MD5 → ACK → REGACK/REGREJ → ACK — with correct call
numbers, correct `OSeqno`/`ISeqno` progression, ACKs not consuming a sequence
number, and well-formed IEs in both directions. This is the first time the
registration path has run against anything other than a fixture.

ℹ️ **One seam left open**, no longer urgent: the registrar calls
`IAX2Auth.md5Response(challenge:secret:)` with the **default** encoding and
carries no override, where `IAX2Call.Configuration` gained one in `c77ce86`.
OQ-5 resolved *to* lowercase hex, so registered node mode works as
shipped and this is now a symmetry/hygiene item rather than a defect. Thread
`md5ResultEncoding` through `IAX2Registrar.Configuration` in the same shape
when convenient. See `docs/CLI.md`.

### IAX-12 — Web Transceiver, FR-1.3's second half ✅ DONE
**Depends on:** IAX-8b ✅, OQ-10 ✅ (both resolved 2026-08-17). **Delivered** the
same day, and proven on the air rather than only in tests.

**What it is.** An operator with an allstarlink.org portal account and no node
of their own can reach any node whose owner permits it, with no entry in
anyone's `iax.conf`. That was the half of FR-1.3 nobody had built.

**The call.** Four of these five are not what anyone would guess, which is why
OQ-10 sat open:

    USERNAME        allstar-public       literal; a callsign draws a bare REJECT
    secret          allstar              static, ships in every ASL3 iax.conf
    CALLED NUMBER   s                    WT never dials the node number
    CALLING NAME    <token>              from POST /api/v2/auth-wt-legacy
    CALLING NUMBER  <target node>        becomes NODENUM, passed to Rpt()

`IAX2Destination` gained `callingNumber` and `callingName`, both defaulting to
the previous behaviour so IAX Direct and registered node mode are untouched.
`--calling-name` is sent verbatim: `--callsign` is upper-cased and
character-checked, which would corrupt a lowercase-hex token.

**Proven, not asserted.** Confirmed against **61624**, a node we do not operate
and which has no local knowledge of our callsign: the call held, and our
callsign appeared in that node's *published* link list as `TVK1CPM`. Every
earlier result came from our own node, where a passing authority check could
always have been explained by the node knowing us locally.

**The token is the identity proof.** The client never asserts a callsign — it
presents a token and the authority server *returns* the callsign. So CallerID
is not spoofable here, which is the opposite of how it looked halfway through.

**Three bugs in our own code fell out of this**, each of which had been
producing misleading evidence for hours: `--no-audio` sessions ended the instant
they connected; every session end was announced as `--duration elapsed`; and
Asterisk's `command '255'` NOTICE turned out to be our own RFC-correct
UNSUPPORT. `HAMVOIP_TRACE=1` was added to tell such things apart and is what
finally did. See `docs/CLI.md` §10 and §11, and the method note in
`experiment-data/wt-oq10-result.txt` — client-side success was never a usable
oracle, and three conclusions were drawn and retracted before the node's own
console was consulted.

**Left for the app:** Currawong does not expose WT yet. APP-11.

### IAX-9 — Capture-replay conformance test ✅ DONE
**Depends on:** IAX-8. **Delivered** as
`Tests/IAX2KitTests/IAX2ConformanceTests.swift` (6 tests), six `live-*.hex`
fixtures, and `scripts/pcap-to-fixture.py`, which cuts a fixture out of a
capture. See "What it found" at the end of this entry.

**The signalling half now exists.** The OQ-5 session of 2026-08-09 produced a
capture of the maintainer's own traffic against their own ASL3 node —
`oq5-confirm.pcap`, four complete §6.1 registration exchanges, both
directions, 32 datagrams. That is a legitimate fixture source under LP-1 and
covers REGREQ, REGAUTH, REGREQ+MD5, REGACK, REGREJ and ACK discipline. It
contains no secret: only the challenges and the digests derived from them.

**The voice half now exists too.** `connect3.pcap`, captured 2026-08-09 during
the M2 sign-off against the maintainer's own ASL3 node: two sessions of 36.7 s
and 15.7 s, ~1100 datagrams, covering NEW → AUTHREQ → AUTHREP → ACCEPT →
ANSWER, full VOICE frames and the switch to mini frames (§8.1.2), 1135 mini
frames each way at 160 octets, DTMF out and echoed back, PING/PONG,
LAGRQ/LAGRP, VNAK with the retransmission that recovered it, and a clean
client-initiated HANGUP with cause IEs.

**The timestamp wrap is captured too.** `wrap.pcap` — a 77 s session, 3780
datagrams, keyed throughout — crosses the 16-bit mini-frame boundary in *both*
directions, and the two directions do it differently, which is what makes the
fixture worth having:

- **Outbound**, mini time-stamps run `65521 → 25`, and at the boundary the
  client sends a **full VOICE frame carrying the 32-bit time-stamp 65541**,
  which the node ACKs. That is the §8.1 re-anchoring, on the wire.
- **Inbound**, the node's mini time-stamps run `65520 → 4` with **no full
  frame at the boundary at all** — a bare wrap, which `IAX2MiniTimestamp`
  must expand from context alone. It did: not one frame was rejected across
  the boundary.

A replay of the inbound half is therefore a direct regression test for the
expander, and the outbound half pins the client's own resync obligation.

Then, for both halves: convert to hex fixtures and replay the server-side
datagrams through MockTransport, asserting the client's responses are
protocol-valid (parseable, correct call numbers, sequence numbers, ACK
discipline).

**What it found.** Everything in `IAX2Kit` survived the replay unchanged: all
six tests passed on the first run against the library. The value came out as
documentation of what a real node does, and one defect outside the library.

Four behaviours of the live node that no fixture written from RFC 5456 would
have contained, each now pinned by an assertion:

- It uses a **Control subclass of `0xff`**, which §8.3 does not define, and an
  **information element `0x38`** and a **frame type `0x0c`**, which §8.6 and
  §8.2 do not define either. All three are ACKed, the control draws an
  UNSUPPORT (§6.5.5), and none disturbs the sequence numbering. The
  `.unknown`/`.unassigned` cases that carry them were built on the RFC's own
  "refer to the IANA registry" wording; this is the first evidence they were
  needed.
- It writes the **media format literally** (`0x04`) where we write it as a
  power of two (`0x82` = 2^2). §8.1.1 allows both. A parser that handled only
  our own spelling would pass every hand-built fixture and fail here.
- It **never lets an answer double as an acknowledgement**: every request draws
  a bare ACK and then the answer, as two frames.
- It **crosses the 16-bit mini-frame boundary without the full frame §6.10 says
  it MUST send there** — inbound time-stamps step 65500 → 65520 → 4 with
  nothing to say an epoch ended. `IAX2MiniTimestampExpander` reconstructs it
  from the low half alone. Our own side does obey §6.10, at both `0x8000`
  crossings of the same call, and the transmitter still makes the same choice
  frame for frame when driven with the captured time-stamps.

Two things the fixtures deliberately do **not** contain: the capture files
themselves (large, and personal traffic — each fixture carries the regeneration
command and the capture's SHA-256 instead), and our own half of any
authenticated exchange, which would mean checking in a digest of the
maintainer's live node password. `Tests/FIXTURES.md` records both rules.

**The one defect, and it was not in the library.** The registration captures
show every ACK-of-REGAUTH leaving with **destination call number 0** instead of
the node's (§6.2.1, §8.1.1). That is `hamvoip-cli oq5`, not `IAX2Registrar`:
the probe called `channel.receive` *before* `setDestinationCallNumber`, and
learned the number only on `.deliver`, so the node's opening bare ACK — which
is `.consumed` — never taught it anything. `IAX2Call` and `IAX2Registrar` both
already learn the number first, which is why the replay produces the correct
destination where the capture has 0. Fixed in `OQ5Command.swift`; Asterisk had
tolerated it, so nothing about OQ-5's conclusion changes.

---

### IAX-10 — Pace transmitted frames instead of bursting them ⚠️ NEW ⏳ OPEN
**Depends on:** CLI-1. **Found by:** the M2 sign-off session, 2026-08-09.

Every over in `connect3.pcap` opens with the whole of the first capture
buffer's worth of frames leaving in the *same millisecond* — a full VOICE
frame plus a dozen or more mini frames, timestamped 20 ms apart but sent at
once. The capture tap hands `AudioFrameBridge` a buffer, the transmit loop
drains it as fast as it can, and nothing paces the result to the 20 ms grid
those timestamps claim.

On one of the two sessions the node answered the first voice frame with
`VNAK` ×3; the retransmission engine resent and the call carried on unharmed,
which is why this is a wart and not a defect. But a burst is not what the
timestamps describe, it gives the peer's jitter buffer a worse arrival
distribution than it needs, and it is the most likely explanation for a VNAK
that appeared on one session and not the other.

**Done when:** frames leave at roughly the interval their timestamps claim,
a test asserts the pacing against a mock clock, and a re-captured session
shows no VNAK at the start of an over.

---

### IAX-11 — A node may answer from an address other than the one dialled ⚠️ NEW ⏳ OPEN
**Decided, not implemented.** The 2026-08-13 resolution below settles *what to
build* — diagnose it, do not handle it — and `2464828` recorded that decision
in this file. No code has changed: there is still no error naming the likely
cause. The "Done when" at the end of this row is the task.

**Depends on:** RC-1, IAX-8. **Found by:** a live LAN session against a
multi-homed ASL node, 2026-08-10.
**Files:** `Sources/RadioCore/NWDatagramTransport.swift` + tests.

`NWDatagramTransport` opens an `NWConnection` in UDP mode against one host and
port, which is a *connected* socket. A node with more than one interface on the
same subnet answers from whichever address its routing table prefers, not from
the address that was dialled, and a connected socket will not accept those
datagrams.

Observed on node 44309 (`wintermute`), which has eth0 `192.168.0.224` and wlan
`192.168.0.170`. A raw UDP POKE sent to `.224:4569` was answered with PONG
**from `.170:4569`**. Through `NWDatagramTransport` aimed at `.224` the first
send succeeded, the next failed with `POSIXErrorCode 57` (`ENOTCONN`), and no
datagram was ever delivered upward. Aimed at `.170` the same client completed
registration, MD5 authentication, `ulaw` call setup and a clean teardown.

The exact mechanism behind the `ENOTCONN` — presumably the kernel rejecting a
datagram from a non-peer address, and Network.framework tearing the flow down
after the resulting ICMP — was **not** confirmed on the wire. The reply from
the unexpected address was.

Two things make this worth a task rather than a footnote. IAX2 multiplexes
calls by call number on a well-known port; nothing in RFC 5456 promises that a
peer answers from the address it was called on, so a node behaving this way is
not misconfigured. And the failure is unreadable: `hamvoip-cli` reports
`the call could not be set up: … send failed: Socket is not connected`, which
points at the socket rather than at the node's routing, and gives nobody a
reason to try the other address.

**DECIDED 2026-08-13 — diagnose it, do not handle it. The maintainer's call.**
The connected socket stays; what changes is the error. The observed harm is an
unreadable message rather than a lost capability — the same client completed
registration, MD5 authentication, call setup and a clean teardown against the
same node's other address — so the fix is to say so, not to weaken the
transport's binding to its peer for one node on one LAN. If a second such node
turns up, handling it can be reconsidered with better evidence about which
Network.framework primitive fits.

**Done when:** a datagram arriving from an address other than the dialled peer,
or a send failing the way this one did, produces an error that names the likely
cause — the peer answered from a different address — and suggests trying the
node's other address. A test drives that at the `DatagramTransport` seam.

The rejected alternative, recorded so it is not re-litigated from scratch:
*handle it* — receive from any source rather than from one peer. PD-1 keeps this
inside Network.framework, so it would need confirming which primitive actually
fits before writing code, and it trades away the transport's binding to its
peer.

AU-5 stands: no sockets in unit tests, so the mismatch must be
modelled at the `DatagramTransport` seam rather than reproduced against a real
multi-homed host.

---

### RC-9 — Real-time-safe capture path ⚠️ NEW, do before CLI-1 sign-off ✅ DONE
**Depends on:** RC-7. **Files:** `Sources/RadioCore/AudioPipeline.swift` + tests.

The `AVAudioEngine` tap callback runs on a real-time thread and currently
allocates on every callback: `AudioFrameChunker.push` grows and `removeFirst`s
a heap array, `downsample` allocates two `AVAudioPCMBuffer`s per callback, and
`onFrame` calls unbounded caller code. None of this is a data race — the
RC-7 fix removed those — but allocating, locking or calling unbounded code on
the audio render thread is a priority-inversion hazard.

This will not show up as a hard failure. It shows up as **intermittent audio
dropouts under load**, which is exactly the kind of fault that gets blamed on
the network and chased for weeks.

Fix properly: preallocated ring buffers, a lock-free handoff to a non-real-time
consumer, no allocation and no unbounded calls inside the tap. This is a
rewrite of the capture path rather than a defect fix, which is why it is its
own task.

**Done when:** no allocation occurs on the tap thread (verify by inspection and,
if practical, an allocation-counting test on the chunker); frames still arrive
as exact 160-sample buffers; existing tests still pass.

---

### RC-10 — `NetworkClient` carries events, audio and a transmit seam ✅ DONE
**Depends on:** RC-1. **Files:** `Sources/RadioCore/RadioEvent.swift`,
`NetworkClient.swift`, all three clients + tests.

`NetworkClient` had `state` and four verbs. That is enough to drive a PTT button
and nothing else: an app could not report *why* a link dropped without knowing
about `IAX2CallTermination`, could not read received audio, and could not offer
captured audio — so it could not be written against the protocol at all, which
is the one thing the protocol exists for. Phase 4 would have discovered this on
its first screen.

Added `RadioEvent`, `RadioDisconnectReason` and `RadioAudioIssue` — one coarse,
mode-agnostic vocabulary, carrying `String?` details rather than mode-specific
types so that adding a mode does not change its shape — plus three protocol
requirements: `radioEvents`, `receivedAudio` and `send(pcm:)`. Each client keeps
its own detailed `events` stream and translates onto the shared one from inside
its single `emit`, so the two cannot disagree about what happened or in what
order.

**This task has unusual provenance.** It was written, finished and left
uncommitted in a background job's worktree, found during a pre-0.3.0 branch
audit, and preserved on `salvage/rc-10-radio-events` before being ported. The
port is not a rebase: the original predated `M17Client` and `EchoLinkClient`, so
two of the three translations are new, and three cases
(`remoteTransmitStarted`, `remoteTransmitEnded`, `stationInfo`) were added
because a third mode showed the vocabulary was short.

Two decisions worth not re-litigating:

- **The translation returns `RadioEvent?`.** IAX2 maps totally; EchoLink drops
  `directoryLoggedIn` and `nodeAnswered`, which happen *inside* a `connect(to:)`
  that has not returned, so no application can act on them. `nil` is a decision
  recorded per case, not a gap.
- **The frame-returning `send(pcm:)` became `transmit(pcm:)`** on all three
  clients, and `send(pcm:)` is now the Void-returning protocol requirement. A
  witness may not return a value the requirement does not, and the requirement
  must not — an `IAX2VoiceFrame` is exactly the RFC 5456 detail the seam exists
  to keep out of an app. Anything wanting to know what reached the wire (the CLI
  counts frames) calls `transmit(pcm:)`. Breaking for `IAX2Kit`/`M17Kit`
  consumers, which is why it landed in 0.3.0 rather than later.

**Done when:** a whole session — connect, transmit, read an event, read audio,
disconnect — runs against nothing but `NetworkClient`, proven by a fake client
in `RadioCoreTests` that is a plain `final class` rather than an actor; every
mode's mapping table is asserted case by case; and a live IAX2 session shows
`radioEvents` is exactly `events.compactMap(\.radioEvent)`, in order.

### RC-13 — `routeChanged` carries why ✅ DONE

**Why, and it is a defect this package enabled rather than a feature request.**
`SF-3` says transmission must be dropped when the audio route changes, and
`AudioSessionSignal.routeChanged` carried no reason — so nothing above this
package could tell *"the category changed because the app just asked for it"*
from *"the microphone was unplugged"*.

That is not academic. Currawong tried `RC-12`'s listening policy on the transmit
path on 2026-08-22 and had to revert the same day: a category change **is** a
route change, so asking for the recording policy at key-down dropped the very
transmission it was enabling, and the automatic resume did it again.

```
key down → activateSession(radio) → route change → SF-3 drops transmit
         → resume keys back down → route change → …
```

Every component behaved as specified. The loop was the consequence of a signal
that could not say why it fired, so `RC-12` was unusable without this.

**What shipped.**

- `AudioRouteChangeCause` — `categoryChange`, `newDeviceAvailable`,
  `oldDeviceUnavailable`, `override`, `wakeFromSleep`,
  `noSuitableRouteForCategory`, `routeConfigurationChange`,
  `engineConfigurationChange`, and `unknown(reason:)` carrying the number it did
  not recognise.
- `init(rawReason:)`, mapping Apple's raw codes. Raw rather than typed for the
  same reason ``AudioSessionPolicy`` uses raw strings: `AVAudioSession` is
  iOS-only and a mapping that cannot be tested on macOS is one nobody checks.
- `routeChanged(AudioRouteChangeCause)`.
- `isExternalRouteMove` — false for `categoryChange`, **true for everything
  else, `unknown` included**. An unrecognised cause must not be the quiet one:
  the failure mode of the other choice is a microphone left open.

**This package still does not decide.** `AudioPipeline` drops nothing, and which
causes warrant an unkey stays where PTT state lives — the note on
`AudioSessionSignal` has always said so. What changed is that the judgement is
now *possible*.

**Source break, deliberate and small.** `.routeChanged` gains an associated
value, so a `switch` that matches without binding still compiles and any code
*constructing* the case does not. The only construction sites are in this
package; Currawong's test fakes emit it and will need the cause.

Tests: six on macOS — the mapping, unrecognised numbers keeping their value, the
`categoryChange`-is-not-external distinction, unknown-is-external, the engine
cause never coming from a raw code — plus the raw-to-symbol round-trip on iOS.

### RC-12 — A listening policy, so HFP is held only while transmitting ✅ DONE

**Why.** `AudioSessionPolicy.radio` asks for `allowBluetooth`, which is the
hands-free profile, which is the only Bluetooth profile carrying a microphone —
so it has to. But an *active* session holding HFP keeps the SCO link up for the
whole call rather than only while a tap is installed, and Currawong measured
three costs for that on a phone (its `BU-17`, 2026-08-22):

1. **Received audio is 16 kHz mono for an entire QSO** instead of 44.1 kHz
   stereo. Audible — the operator reported it by ear before it was diagnosed.
2. A speaker-mic's "in a call" LED is lit permanently, so it cannot serve as a
   transmit indicator, which is what an operator naturally reads it as.
3. Accessory battery, for a voice channel carrying silence.

macOS does none of this: CoreAudio raises HFP when a client opens the input and
drops it ~2 s after the last one closes, so listening is on A2DP and only
transmitting is narrowband. That is the right behaviour for a simplex radio —
nobody listens and talks at once — and this task is what lets iOS reproduce it.

**What shipped.**

- `AudioSessionPolicy.listening` — `.playback`, `.default`, no options. The
  **category** differs from `radio`, not just the options, and that is the whole
  point: `BU-17` showed a `.playAndRecord` session keeps *returning* to HFP
  because the category requires an input and HFP is the only Bluetooth one on
  offer. A policy that still asks for an input cannot fix this.
- `activateSession(_:)` taking a policy, with `activateSession()` delegating to
  it with `.radio` so no caller changes.
- `allowBluetoothA2DP` (`0x20`) named but **unused**, with a test pinning that it
  is unused: `.playback` reaches A2DP without it, and adding it to a recording
  category does not stop HFP being chosen. It is a natural wrong turn and worth
  closing off explicitly.

**The obligation this puts on callers, and it is the reason this is not just a
constant.** `AVAudioEngine` never revisits its input format, so an engine whose
input unit is instantiated under a non-recording category reports 0 Hz for the
life of the process — the app's `BU-1`, and why `activateSession()` exists at
all. A caller that idles under `listening` **must** be able to discard and
rebuild its engine when it switches back to `radio`, or the first transmit after
any receive fails with a converter error and so does every one after it.
Currawong's `AudioPipelineIO` already rebuilds once on a failed `startCapture`,
which is the machinery this relies on.

**Not done here:** the app-side switching. This task ships the policy and the
entry point; deciding *when* to switch is Currawong's `BU-17`, in Currawong's
repo, against a released tag.

Tests: six, all on macOS except the symbol round-trip, which stays iOS-only.

### RC-11 — Audio-session policy without an engine ✅ DONE
**Depends on:** RC-7 ✅. **Files:** `Sources/RadioCore/AudioPipeline.swift` +
tests. **Raised by:** the app, as `BU-3` in `currawong/docs/BRINGUP.md`. Small,
and unblocked.

`AudioPipeline.configureSession()` is an **instance** method, so reaching the
audio-session policy means owning an `AudioPipeline` — and owning one means
having built an `AVAudioEngine`. That is the exact thing the app's `BU-1` says
must not happen before the session is configured: an engine whose input unit is
instantiated under the default `.soloAmbient` category reports a 0 Hz input
rate and never recovers, which is a converter failure on every PTT press for
the life of the process.

So Currawong spells the category, mode and options itself, in
`Sources/Currawong/AudioIO.swift`, with a comment saying why. **Two copies of
the audio-session policy, kept in step by hand, on the path that governs
whether the microphone works at all.**

The fix is a static or free function holding the policy —
`AudioPipeline.activateSession()` or similar — with the instance method calling
it, so a caller can configure the session before deciding to build anything.

**Done when:** the policy can be applied without constructing an
`AVAudioPipeline` or an `AVAudioEngine`, the instance method delegates to it so
the two cannot drift, and a test pins the category/mode/options. Then the app
deletes its duplicate and the comment explaining it — **but that deletion is
the app's own change, made in its repository after this ships in a release it
depends on.** This repository does not write to Currawong.

**Delivered.** `AudioSessionPolicy` holds the policy; `AudioPipeline
.activateSession()` is a static, iOS-only method that applies and activates it
with no engine anywhere in the call; `configureSession()` delegates to it and
is now three words long.

Two decisions worth knowing before touching it:

- **The policy is raw values, not `AVAudioSession.Category` and friends.**
  Those types are iOS-only, and this package's tests run on macOS, so a typed
  constant could not be pinned by a test that actually runs. It also disposes
  of the `allowBluetooth` → `allowBluetoothHFP` rename in the iOS 26 SDK: same
  option, same raw value (`0x4`), and only one spelling compiles against any
  given SDK — the app carries a `#if compiler` shim for exactly this, and does
  not need to any more.
- **Two tests, and only one of them runs in CI.** The raw values are pinned on
  any platform; the round-trip from those raws back to `.playAndRecord` /
  `.voiceChat` / the options is `#if os(iOS)` and therefore skipped on the
  macOS runner. That second one is the test that would catch Apple changing a
  raw string, so it is a backstop for whoever runs the suite on a simulator,
  not a guard that fires on every push.

The app's deletion of its copy is `BU-3` in `currawong/docs/BRINGUP.md`, and
waits on a release.

### CLI-2 — `--no-audio` sends the silence it promises ✅ DONE
**Depends on:** CLI-1 ✅. **Raised by:** the app, 2026-08-20, while settling
Currawong's `BU-8` with two CLI instances.

`--no-audio` printed "PTT will send silence" and sent **nothing at all**. The
only frame source was `AudioPipeline.startCapture(onFrame:)`, inside the branch
the flag switches off, so a key-down changed the client's state and then
offered it no PCM — `Datagrams transmitted: 0`, and a second client on the same
reflector heard no stream. Two key-ups went on air as nothing before anyone
noticed the flag was the reason.

That matters more than a wrong banner, because `--no-audio` is the mode an
*unattended* on-air test runs in: nobody is there to talk into a microphone, so
its one job is to produce carrier without hardware.

**Two faults, and the second is the one that hid the first.**
`SilentCaptureSource` now feeds the same bridge the microphone tap feeds —
`AudioPipeline.captureFrameSize` samples of zero every 20 ms, continuously, as
capture does, because the client drops frames while unkeyed. But the transmit
loop was only added to the task group when a pipeline existed, so at first the
silence was produced and nothing consumed it. The loop is now added whenever
*either* source is live; the receive and audio-signal loops stay
pipeline-gated, since those are the ones whose streams finish instantly and end
the session (the trap IAX-12 spent an afternoon on).

Silence rather than a tone: this stands in for an operator not talking, and a
tone left running by accident on a shared module is somebody else's problem to
listen to. µ-law has an exact zero and Codec2 3200 encodes a silent frame like
any other, so what goes on air is properly framed, last frame included.

**Confirmed on air, 2026-08-20**, two instances against
`m17-cbr.charlesmartin.au` module A with `--no-audio` on both: 69 datagrams for
a three-second over, and the observer printed `RX VK1CPM ended — end of over`.
Five unit tests cover the frame shape, the cadence, cancellation, and frames
actually arriving at the bridge — that last being the one that would have
caught this.

### CLI-3 — `HAMVOIP_SECRET` becomes `IAX2_SECRET` ✅ DONE
**Depends on:** nothing. **Blocks:** nothing. **Breaking**, and released as such.
**Files:** `Sources/hamvoip-cli/Terminal.swift` (the one definition),
`ConnectCommand.swift`, `NodeOptions.swift`, `WebTransceiverTokenCommand.swift`,
`ConfigFile.swift`, both CLI test files, `docs/CLI.md`, `README.md`, `CHANGELOG.md`.

Raised by the maintainer, 2026-08-20: **the name is out of date given the
current library state.** It dates from when the CLI had one protocol in it, and
`echolink` and `m17` are equally "hamvoip" — so `HAMVOIP_SECRET` named the
*project* the file belonged to rather than the credential it held. The tell was
in `docs/CLI.md`, which had to gloss it as "the IAX2 node secret" wherever it
appeared; a name needing a gloss at every use is a name doing no work.

Every other credential already followed the better convention — `ECHOLINK_PASSWORD`
and the EL-15 `ECHOLINK_PROXY*` files are named for the `echolink` subcommand, so
the file name says which command wants it. `IAX2_SECRET` puts the node secret on
the same footing as the `iax2` subcommand that reads it.

**Clean break, on the maintainer's call** — the old name is not read at all, not
even with a deprecation warning. The reasoning: a fallback would keep a
misleading name alive in scripts indefinitely, and the failure mode without one
is loud in the common case (a prompt appears where none did before) and
documented in the CHANGELOG with the one-line `mv` that fixes it. AllStarLink is
the only protocol of the three that involves a node secret at all, so the
population affected is small and knows exactly which file it holds.

**Done when:** one definition changed, no reference to the old name outside a
historical note, and the full suite green. ✅ 1008 tests, unchanged in number —
this renames a constant, it does not alter behaviour, and the existing
`SecretResolutionTests` cover the precedence chain either way.

### IAX-13 — Fetch the Web Transceiver token ✅ DONE
**Depends on:** IAX-12 ✅ (OQ-10's observed contract). **Raised by:** the
maintainer, 2026-08-17 — an app settings screen (APP-12) wants "log in, get
the token" as one action, and today the fetch exists only as a curl in
`docs/CLI.md` §11.1.

Mirror the EL-12 shape (`EchoLinkPublicProxySource` / `EchoLinkProxyFinder`):
a protocol seam in `IAX2Kit` plus one `URLSession` implementation against
`https://allstarlink.org/api/v2/auth-wt-legacy` — POST, JSON body
`{"username","password"}`, both key names exact, `username` the callsign.
Success is `{"status":"OK","auth":1,"token":…}`: a 12-character lowercase-hex
token, stable across calls — a credential with a lifetime, not a nonce. Map
the three observed failures (`Invalid JSON payload`, `Invalid JSON fields`,
`login failed`) to typed errors; "wrong password" and "the endpoint changed"
are different operator problems and must be distinguishable. Tests run
against canned responses in the same style EL-12's do — no test touches the
network.

Why a seam rather than a function: the endpoint is named `legacy`, and
ASL3-Manual #229 sits under "WebTransceiver Login API Replacement" — the
successor must be a substitution, not a rewrite (OQ-10, caveat 2). Small
enough to also give `hamvoip-cli iax2` a portal-login convenience so §11.1
stops requiring curl; include it if it stays small.

**Delivered** (2026-08-17): `WebTransceiverTokenSource` and
`AllStarLinkPortalTokenFetcher` in `IAX2Kit/WebTransceiverToken.swift`, with
the three observed messages mapped to `.loginFailed`, `.invalidJSONPayload` and
`.invalidJSONFields`, and anything else carried verbatim as
`.rejected(message:)`. 18 tests against canned bodies; none makes a request.
Four decisions worth recording, the last two raised by review on PR #32:

- **A token of an unfamiliar shape is accepted, not refused.** Only the node
  decides whether a token works, and the endpoint is expected to be replaced —
  so `isWellFormed` is advisory (12 lowercase hex), and the CLI says so on
  stderr rather than failing.
- **`WebTransceiverToken.description` is redacted.** The token resolves to the
  operator's callsign on any WT-enabled node, so it is a credential; the string
  is reachable only through `.value`, and a test pins that.
- **The endpoint must be `https://`, with no opt-out.** Substitutability is the
  point of the seam, and it is also how a portal password could reach the wire in
  clear — so `isPermittedEndpoint(_:)` gates the request and
  `.insecureEndpoint(scheme:)` says nothing was sent.
- **`status: "ERR"` with no `msg` is `.malformedResponse`, not `.rejected("")`.**
  Every observed failure carried a message, so a missing one means the answer is
  not the documented shape — and `.rejected("")` would have shown an operator
  "the portal refused the login:" followed by nothing.

The convenience landed as its own subcommand rather than a flag on `iax2`:
`hamvoip-cli wt-token` prints only the token, which makes §11.1 a
`TOKEN="$(…)"` and keeps the two steps as separable as the portal makes them.
`--endpoint` points it at a successor without a rebuild. APP-12 consumes the
seam; it needs a release carrying this to do so, since Currawong depends by
version.

## Phase 3 — CLI harness

### CLI-1 — `hamvoip-cli` (macOS) ✅ DONE (build/run/CI; live-node sign-off tracked separately via OQ-5)
**Depends on:** IAX-8, RC-7.
**Files:** new executable target in `Package.swift`
(`.executableTarget(name: "hamvoip-cli", dependencies: ["IAX2Kit", "RadioCore"])`),
`Sources/hamvoip-cli/main.swift`. Use `swift-argument-parser`
(apple/swift-argument-parser, Apache-2.0 — the one permitted dependency).

`hamvoip-cli connect --host … --node … --username … --secret …` — connects,
prints RX state, spacebar toggles PTT via `AudioPipeline` mic/speaker.
This exists so a human can validate against a real node from a terminal
(per "set up testing via CLI" in the requirements) before any GUI exists.

**Done when:** builds and runs on macOS; a human sign-off comment on the PR
records a successful live connection (**Milestone M2**). CI only builds it.

---

## Phases 4 and 5 — the app, and its PTT input layer → moved 2026-08-21

**`APP-*` and `BLE-*` now live in `currawong/docs/DEVELOPMENT-PLAN.md`.** Both
task lists moved there verbatim on 2026-08-21, with their write-ups; this file no
longer carries them, and the app's fault list (`BU-*`) never was here.

**Why.** Every app task is executed in the app's repository, tested by its
`make test`, and closed by a commit in its log — while the plan PR recording it
came here, to a repository the work never touched. The requirements stayed one
document, which was the actual reason the plan was one document:
`docs/DESIGN-REQUIREMENTS.md` is still the sole authority for `FR-*`, `SF-*`,
`PD-*`, `PT-*`, `OQ-*` and `NG-*`, and the app's plan cites it rather than
restating it. Two plans, one requirements document.

**What did not change.** Currawong reads this library and never writes to it, and
the seam is `NetworkClient` plus a versioned SPM dependency. An app task that
needs a library change still gets a library task here, on its own branch, with
its own PR — `BU-3` → `RC-11` is the worked example — cited from the app's plan
by ID. The corollary is new only in direction: this plan does not carry the app's
task list either.

**Phase numbering is kept** — the app's file still says "Phase 4" and "Phase 5",
because `project.yml`, several source comments and this file's phase map cite
those numbers, and renumbering to tidy the split would break more references than
the split itself touched.

**Both lists are closed.** Phase 4's twenty-two tasks were closed 2026-08-21, and
Phase 5's `BLE-1 … BLE-3` shipped inside it as APP-5 — read that task before
opening a `task/ble-1` branch expecting to find the work undone. `SIL-1` is the
one app task never scoped; its row is in §3's open list, pointing at the app.

## Phase 6 — EchoLink ✅ COMPLETE (M3 passed 2026-08-13)

**Both gates are now cleared:** the terms (OQ-1, 2026-08-09) and the clean-room
sourcing question (OQ-9, 2026-08-12). Permitted sources are fixed by the OQ-9
resolution in the open-questions table below and are not restated here to avoid
drift — read that row before opening the first task. In short: captures of the
maintainer's own sessions are the primary source; RFC 3550 and GSM 06.10 anchor
only the parts they cover, and where the wire disagrees with the RFC the wire
wins; prose write-ups (candidate d) are admitted only under a high provenance
bar and never when their derivation from a forbidden implementation cannot be
ruled out.

The clean-room rules are **unchanged and absolute**. **Do not read SvxLink,
EchoLib, thebridge, MicroLink or any other EchoLink implementation** at source
level, ever — the resolution permits observing wire output, not reading code.
**Do not use "EchoLink" as a product name** — nominative, descriptive use only,
per OQ-1b. When a protocol detail is ambiguous, the answer is another on-air
capture, not an implementation; capture work spans multiple peers (a single-peer
capture already yielded two wrong conclusions — see the PROVENANCE.md OQ-9 entry).

Cutting new captures remains the maintainer's action to run, not an agent's.

The task breakdown below was cut 2026-08-12. It covers the directory on TCP
5200, RTP/GSM on UDP 5198/5199, the proxy transport (mandatory and
default-on-cellular per FR-3.3), and vendored BSD-licensed `libgsm` per LP-4.

### What is already known, and how well

Everything the captures settled is written up in `experiment-data/echolink-oq9-result.txt`
(SHA-256s of the three captures are in the same file) and the boundary call is
logged in the PROVENANCE.md OQ-9 entry. Four facts drive the task shapes below
and are repeated here because getting any of them wrong is silent:

1. **Proxy framing:** a 9-byte header — type(1), peer IPv4 raw octets(4),
   payload length(4) — and that length is **little-endian**. It is the one
   length field in this tree that is not big-endian; RFC 5456 and M17 are both
   the other way. Types observed: `0x01` open, `0x02` TCP/directory data,
   `0x03` close, `0x04` status, `0x05` UDP data (the 5198 channel), `0x06` UDP
   control (the 5199 channel).
2. **Login digest:** `MD5(password ‖ nonce-as-8-ASCII-characters)`, emitted as
   **raw 16 bytes**. Password-first, the nonce hashed as its eight ASCII
   characters rather than the four bytes they spell, and raw binary on the wire
   — the **opposite** of OQ-5's lowercase hex for IAX2. Three of those four
   were the obvious guess and all three were wrong. The proxy password is a
   configuration value (observed only as the public-proxy literal `PUBLIC`);
   the operator's account password never enters proxy authentication and is
   relayed onward inside a `0x02` frame.
3. **RTP is not RFC 3550 as written.** Version bits are **3**, not 2. Code
   written faithfully from the RFC does not interoperate. Payload type 3
   (GSM 06.10), 144-byte packets = 12-byte header + 4 × 33-byte GSM frames =
   80 ms, held across all 475 RTP packets from four independent peers.
4. **The RTP timestamp is always zero** — across all four peers, both
   directions. It is a protocol property, not one client's quirk, and it means
   the existing `JitterBuffer` has nothing to key on. See EL-7.

Two things are evidenced *less* well than the above, and tasks must not
overstate them. SSRC and sequence origin are **not** fixed: a single-peer
capture produced two confident wrong conclusions (SSRC always zero, sequences
start at zero) that a four-peer capture corrected. And captures record what
happened, never what is *permitted* — four peers agreeing on 4 GSM frames per
packet is strong evidence about practice and silent about the legal range.
Parse permissively, emit what was observed.

### Sequencing

```
EL-1 ─→ EL-2 ─┬─→ EL-4 ─┬─→ EL-5 ─→ EL-6 ─┬─→ EL-9 ─→ EL-10   (M3)
EL-3 ─────────┘         └─→ EL-7 ─────────┤
EL-8 (no dependencies, any time) ─────────┘
                             EL-6 ─→ EL-11 ⛔ gated, off the M3 path
```

`EL-8` (the codec) depends on nothing and can run in parallel from the start.
`EL-4` owns the only `Package.swift` change in this phase — per plan rule 9, no
other EL task may touch the manifest.

---

### EL-1 — Teach `pcap-to-fixture.py` to read TCP streams ✅ DONE
**Depends on:** nothing. **Blocks:** EL-2.
**Files:** `scripts/pcap-to-fixture.py`, `Tests/FIXTURES.md`.

The whole EchoLink capture set is TCP 8100 — the proxy tunnels the directory
session and both UDP channels inside it, so a 5198/5199/5200 filter comes back
empty. The existing script cannot read any of it: `udp_datagrams()` hard-filters
on IP protocol 17, and there is no reassembly, no handling of out-of-order or
retransmitted segments, and no notion of application framing. "One datagram per
line" has no direct analogue in a byte stream.

What carries over unchanged is worth keeping: `read_pcap`, `strip_link_layer`,
the SHA-256 provenance header, and the `--dir`/`--range`/`--summary` plumbing
are all transport-agnostic. What is IAX2-specific — `describe()` and
`hex_line()` — needs an EchoLink counterpart that decodes the 9-byte proxy
header and labels the frame type.

The unit for `--range` and the `[n]` index becomes **the proxy frame**, not the
TCP segment. Frame boundaries do not coincide with segment boundaries, so the
script must reassemble each direction into a byte stream, then walk it
header-by-header. A wrong header size or endianness desynchronises within a few
frames, which is also the correctness check: **the whole stream must decode
with zero leftover bytes in either direction**, and the script should say so
rather than trailing off silently.

**Done when:** the script cuts a fixture from a TCP capture; `--summary` lists
proxy frames with type, length and direction; a stream that does not fully
decode is reported as an error rather than truncated; and `Tests/FIXTURES.md`
documents the TCP mode alongside the UDP one.

**Done, PR #16.** Two things the captures forced that this task did not
anticipate, both now in the script:

- **They are pcapng, not classic libpcap** — `tcpdump`'s default on macOS. The
  reader could not open the files the task exists for, so `read_pcapng` joins
  `read_pcap`.
- **The login exchange is not framed.** It precedes the framing, which is why a
  capture containing the TCP handshake fails to decode from byte 0 while one
  beginning mid-session appears to work — the opposite of the intuition.
  `split_handshake` takes it off the front.

Three guards went in, each against something silent: a stream with no captured
SYN is refused (`echolink-oq9.pcap` emits several plausible frames of pure
misalignment before resynchronising); a stream must decode with zero bytes left
over; and `0x02` frames are refused, checked across the whole selection before
any output so a refusal cannot leave a half-written fixture.

Verified: capture 3 decodes to 279 frames and capture 1 to 432, matching the
hand analysis, and both recorded (nonce, digest) pairs reproduce byte for byte.
The UDP path is unchanged — all six `live-*.hex` fixtures regenerate
identically from the recipes recorded inside them.

---

### EL-2 — Proxy-framing and login fixtures ✅ DONE
**Depends on:** EL-1. **Blocks:** EL-4.
**Files:** `Tests/EchoLinkKitTests/Fixtures/live-proxy-*.hex`,
`Tests/FIXTURES.md`.

Turn the captured proxy framing and login handshake into fixtures **before any
code depends on them**, exactly as IAX-9 did for IAX2. The fixture directory
is created here; the test target that reads it arrives in EL-4.

Three hazards, none of them optional:

- **`echolink-oq9-2.pcap` contains the operator's account password in
  cleartext**, as an ASCII `0x02` frame in the client→proxy direction. Treat it
  like `IAX2_SECRET`. Only the **peer's half** may be checked in — which is
  the standing `Tests/FIXTURES.md` rule, and here it is load-bearing rather
  than tidy.
- **`echolink-oq9-3.pcap` contains the entire EchoLink directory** — 6548
  third-party callsigns and 6261 IP addresses. **No fixture cut from it may
  include a `0x02` frame.** The directory protocol gets its fixtures from a
  deliberately truncated list instead; see EL-11.
- **The source captures must not be named by path in any versioned file.** This
  departs from `Tests/FIXTURES.md`, which names its captures by path, and the
  departure is deliberate: the OQ-9 provenance entry made the same call for the
  same reason. Identify these captures by **SHA-256 only**, and record the
  exception in `Tests/FIXTURES.md` so the next person does not "fix" it.

✅ **Where the captures live is settled** (maintainer, 2026-08-12).
`experiment-data/README.md` used to say that a capture yielding a fixture moves
to the workspace root, where the fixture-bearing captures live and where
`Tests/FIXTURES.md` names them by path. These three cannot follow that rule
without a versioned file pointing at a credential and a directory dump, so the
rule now has an escape hatch: **a capture holding data that is or could be
private stays in `experiment-data/` whether or not a fixture was cut from it,
and is cited by SHA-256 rather than by path.** In doubt it stays. The hatch is
written up at the end of `experiment-data/README.md`, mirrored in the workspace
`CLAUDE.md`, and the repository half is in the TCP section of
`Tests/FIXTURES.md`. Nothing else about the provenance rule changes: the
regeneration command is still recorded, octets are still never edited, and only
the peer's half is checked in unless our own half is under test.

**Done when:** the proxy handshake and a representative frame of each observed
type are fixtures; no fixture contains a credential, a third-party callsign or
an IP address belonging to anyone else; each carries its regeneration command
and its capture's SHA-256; and `Tests/FIXTURES.md` has an EchoLink section
stating the path exception and the `0x02` prohibition.

---

### EL-3 — `StreamTransport`: the TCP seam ✅ DONE
**Depends on:** nothing. **Blocks:** EL-4.
**Files:** `Sources/RadioCore/StreamTransport.swift`,
`Sources/RadioCore/NWStreamTransport.swift`,
`Tests/TestSupport/MockStreamTransport.swift`, `Tests/RadioCoreTests/…`.

Nothing in the tree speaks TCP. `DatagramTransport` is message-oriented and
`NWDatagramTransport` is the only `NWConnection` user, on `NWParameters.udp`.
EchoLink needs a stream seam for both the proxy (TCP 8100) and the direct
directory connection (TCP 5200), and it needs one for the same reason
`DatagramTransport` exists: AU-5, no sockets in unit tests.

Mirror the existing seam rather than inventing a new shape:

```swift
public protocol StreamTransport: Sendable {
    var incoming: AsyncStream<Data> { get }   // arrival order; chunk boundaries meaningless
    func send(_ bytes: Data) async throws
    func close() async
}
```

The one thing that must be explicit in the doc comment: **`incoming` yields
whatever the network hands over, and its chunk boundaries carry no meaning.**
A caller that assumes one yielded `Data` is one protocol frame will work in
testing and fail on a real connection. Reassembly belongs to the caller
(EL-4's frame decoder), not here.

`NWStreamTransport` uses `NWParameters.tcp` per PD-1 — `Network.framework`,
never BSD sockets. `MockStreamTransport` goes in `TestSupport` and must be able
to deliver a frame **split across two chunks** and **two frames in one chunk**,
because those are the cases a decoder gets wrong.

**Done when:** both split and coalesced delivery are covered by tests, `close()`
is idempotent and finishes `incoming`, and no unit test opens a socket.

---

### EL-4 — `EchoLinkKit` target and proxy frame codec ✅ DONE
**Depends on:** EL-2, EL-3. **Blocks:** EL-5.
**Files:** `Package.swift` (**the only EL task that may touch it**),
`Sources/EchoLinkKit/EchoLinkKit.swift`,
`Sources/EchoLinkKit/ProxyFrame.swift`, `Tests/EchoLinkKitTests/…`.

Add the `.library`/`.target`/`.testTarget` triple — `EchoLinkKit` depending on
`RadioCore`, `EchoLinkKitTests` with `.copy("Fixtures")` — and the pure value
types for the proxy framing. No I/O, no actor: parse and serialise only, the
same shape as `M17ReflectorProtocol.swift`.

The header is type(1) + peer IPv4(4, raw octets) + length(4, **little-endian**)
+ payload. Write the endianness out in a comment naming this task; it is the
single most likely thing to be "corrected" later by someone who has just been
reading the IAX2 code.

Parse permissively. An unknown message type is not a parse failure — the
observed six are what four clients happened to send, not the permitted set.

**Done when:** every EL-2 fixture round-trips byte-for-byte, a truncated header
and a truncated payload are distinguishable errors, and an unknown type
survives parsing.

---

### EL-5 — Proxy login and session lifecycle ✅ DONE
**Depends on:** EL-4. **Blocks:** EL-6.
**Files:** `Sources/EchoLinkKit/EchoLinkProxyClient.swift`,
`Sources/EchoLinkKit/EchoLinkAuth.swift`, `Tests/EchoLinkKitTests/…`.

An actor over `StreamTransport` running the observed handshake: proxy sends an
8-byte ASCII hex nonce; client replies with its callsign LF-terminated followed
by 16 raw digest bytes with no length prefix; proxy answers `0x04` status
(`00 00 00 00` = success) and a `0x02` payload from the directory server.

⚠️ **That last clause is wrong, and the code does not follow it** (plan rule 6:
the evidence wins, and the discrepancy is reported rather than obeyed). In the
capture the `0x04 STATUS` answers the `0x01 OPEN` that follows the login, and
the `0x02 "OK"` is the *directory server's* answer to the directory login —
both belong to later steps. **The proxy login itself is never acknowledged.** A
proxy that rejects it simply drops the connection.

So `login()` completes when the digest is written, and a bad password surfaces
as `.streamClosed` from `open(peer:)`. Waiting for an acknowledgement that does
not exist would hang forever.

`EchoLinkAuth` is a pure function and gets its own exhaustive tests:
`MD5(password ‖ nonce-as-8-ASCII-characters)` → 16 raw bytes. Pin both
recorded (nonce, digest) pairs from the captures as test vectors — they come
from two different proxies and two different nonces, which is what rules out
coincidence. Add a test asserting the digest is **not** hex-encoded, naming
OQ-5, so the IAX2 convention cannot leak in later.

⚠️ **Actor reentrancy (plan rule 10).** This is a continuation-parking API:
`login()` awaits a send and then waits for the reply. Use a dedicated in-flight
flag, or park in the same actor-isolated synchronous region as the terminal
check. This exact shape cost a 4%-of-runs hang in M17-3. A test must deliver
the reply from *inside* the awaited send — see
`testConnectReturnsWhenAcknIsProcessedDuringSend`.

**Done when:** login succeeds against `MockStreamTransport` replaying the
fixtures, both digest vectors pass, a `0x04` status other than zero is surfaced
as a typed error, and the reentrancy test exists.

---

### EL-6 — Directory login (FR-3.1, part 1) ✅ DONE
**Depends on:** EL-5.
**Files:** `Sources/EchoLinkKit/EchoLinkDirectory.swift`, `Tests/EchoLinkKitTests/…`.

Log in to the directory server on TCP 5200, tunnelled as `0x02` frames when
proxied. The login line is `'l'` + callsign + two separator bytes + password +
CR, all ASCII, and the server answers `OK`. Both halves are in the captures —
and the request half is exactly the credential EL-2 forbids checking in, so the
fixture is the server's reply, with the request hand-built from the shape.

This is the operator's own account password (FR-3.4), not the proxy's `PUBLIC`.
Two different secrets a few bytes apart on the same stream: the proxy digest of
EL-5 never sees the account password, and this login never sees the proxy's.
Keep them in separate types so neither can be passed where the other belongs.

**Parsing the station list is not in this task — that is EL-11**, which is
gated on a capture that does not exist yet. Nothing on the path to a QSO needs
the list: an operator who knows the node they want can connect without it.

**Done when:** login over 5200 succeeds both proxied and direct against
`MockStreamTransport`, a rejected login is a typed error, and the account
password is never logged, echoed in an error, or written to a fixture.

---

### EL-7 — RTP framing and sequence-keyed playout ✅ DONE
**Depends on:** EL-4.
**Files:** `Sources/EchoLinkKit/EchoLinkRTP.swift`,
`Sources/EchoLinkKit/EchoLinkStreamAudio.swift`, `Tests/EchoLinkKitTests/…`.

Value types for the 12-byte RTP header and the 4 × 33-byte GSM payload, plus
the piece that makes them playable. **Version bits are 3.** Accept 3; do not
"fix" it to 2, and do not reject 2 either.

The real work here is that **`JitterBuffer` keys on timestamps only** — a
32-bit millisecond stream clock — and the EchoLink timestamp is always zero.
The sequence number is the only ordering signal, and it is opaque: origins are
arbitrary (inbound sequences ran 2126..23460 with three discontinuities) and it
wraps at 16 bits. So the kit must synthesise the clock the buffer needs, the
way `IAX2MiniTimestampExpander` and `M17FrameNumberExpander` already do for
their own wire counters — but latching an **arbitrary** origin at first packet
rather than counting from zero.

Each 144-byte packet is 80 ms and splits into four 33-byte GSM frames of 20 ms
each, so it pushes four `TimedFrame`s at `origin + seq × 80 + i × 20`. Handle
the wrap, and re-latch on a discontinuity large enough to be a new talkspurt
rather than reordering — three such gaps appear in the four-peer capture, so
this is the common case, not an edge case.

Do not key on SSRC or assume it is zero: one observed peer sent 1787057786.

**Done when:** header parse/serialise round-trips the fixtures; the expander is
tested across a 16-bit wrap, an arbitrary origin and a mid-stream
discontinuity; and a recorded packet sequence plays out in order through a real
`JitterBuffer`.

---

### EL-8 — GSM 06.10 codec (FR-3.2, LP-4) ✅ DONE
**Depends on:** nothing — pure, can run from the start.
**Files:** `Sources/CGSM/` (vendored `libgsm`), `Sources/EchoLinkKit/GSMVoiceCodec.swift`,
`Tests/EchoLinkKitTests/…`. Manifest changes coordinate with EL-4.

`libgsm` is BSD-style and LP-4 **permits vendoring it** — so unlike Codec2 this
needs no dynamic XCFramework, no build script and no conditional compilation.
That is the whole reason this task is small; do not import the Codec2 pattern.
Bundle the licence text.

Conform to `RadioCore.VoiceCodec`: 33 bytes per frame, 160 samples per frame,
8 kHz mono S16 — which lines up with the existing 20 ms frame size everywhere
else in the stack, so no 20/40 ms accommodation is needed here.

**Done when:** encode→decode round-trips with energy intact, frame sizes are
asserted, the licence ships, and the SPDX header rule is satisfied for the
Swift files (vendored C keeps its own headers).

---

### EL-9 — `EchoLinkClient` (the `NetworkClient` facade) ✅ DONE
**Depends on:** EL-6, EL-7, EL-8.
**Files:** `Sources/EchoLinkKit/EchoLinkClient.swift`, `Tests/EchoLinkKitTests/…`.

The facade the app sees, in the shape `IAX2Client` and `M17Client` already
share: `public actor EchoLinkClient: NetworkClient`, `typealias Destination =
EchoLinkDestination`, a `nonisolated var state` backed by `TransmitStateBox`,
the four required methods, plus the conventional `Configuration`,
`TransportFactory`, `nonisolated let receivedAudio` and `events`, and an
`init<C: Clock>` for deterministic tests.

Wire in `TransmitWatchdog` (SF-1) — the safety requirement lives in the library,
not the app. **Per FR-3.3 the proxy is the default on cellular**; the
configuration must express that, and direct mode must remain reachable.

Nothing in `RadioCore` should need to change. If the app would need an
EchoLink-specific type, that is `NetworkClient` missing a capability — fix it
there, not with a cast.

**Done when:** a full connect → receive → transmit → disconnect cycle runs
against mock transports from fixtures, the watchdog cuts transmission at its
limit, and no test opens a socket.

---

### EL-10 — `hamvoip-cli echolink` and live sign-off (**Milestone M3**) ✅ DONE — M3 PASSED 2026-08-13
**Depends on:** EL-9.
**Files:** `Sources/hamvoip-cli/EchoLinkCommand.swift`, registered in
`HamVoIPCLI.swift`'s `subcommands:` array.

The `M17Command`/`ConnectCommand` template — the same six loops (event,
receive, transmit, audio-signal, status ticker, key) — over `EchoLinkClient`.
Reuse `NodeOptions`, `Terminal`, `LevelMeter`, `AudioFrameBridge`.

`*ECHOTEST*` is the obvious first contact: it echoes audio back, so one
operator alone can confirm the round trip end to end, which is exactly what the
capture work already demonstrated the path can do.

**Done when:** a human completes a live EchoLink QSO from the terminal —
intelligible audio both ways, clean teardown — and records the sign-off on the
PR. That is **Milestone M3**, and like M2 nothing in this repository can settle
it.

**✅ Milestone M3 passed, 2026-08-13.** The maintainer completed a live
EchoLink QSO from the terminal through `*ECHOTEST*`: audio intelligible both
ways, clean teardown. That is the milestone, and like M2 nothing in this
repository could settle it.

Getting there took a run of audio-path work after the session first connected —
the playout faults in EL-9, the stream clock and the pause threshold in EL-7 —
each found by capturing our own audio beside a working client's and diffing,
which is the method this project keeps coming back to. The `--help` and session
banner no longer warn that the client has never spoken to a proxy, because that
is no longer true; they say what was validated and when.

#### The connect sequence, and two corrections it forced

Wiring the directory login in meant re-reading the captures rather than the
plan, and the re-reading found the plan's model of a session was wrong twice.
The sequence a real client performs, and that `EchoLinkClient.connect` now
follows:

    <== nonce (unframed)          proxy login (EL-5)
    ==> callsign + LF + digest
    ==> 0x01 OPEN   peer <directory server>
    <== 0x04 STATUS 00 00 00 00
    ==> 0x02 TCP_DATA  'l' + callsign + separators + password + CR   (EL-6)
    <== 0x02 TCP_DATA  "OK"
    <== 0x03 CLOSE                the directory channel, closed on purpose
    ==> 0x06 RR + SDES   peer <the node>     ← this opens the session
    <== 0x06 RR + SDES                       ← the node answers
    ... audio on 0x05 ...
    ==> 0x06 RR + BYE            teardown

**Correction 1 — there is no `OPEN` for a node.** Checked across all three
captures: `0x01 OPEN` was sent **only** for the directory server, and six
distinct audio peers received `0x05`/`0x06` traffic with no `OPEN` at all. The
`0x01`/`0x02`/`0x03`/`0x04` family is the tunnelled **TCP** connection, and
`OPEN` means "connect a socket to this address". `0x05`/`0x06` are
connectionless, carrying the peer's address in each frame header, so an audio
channel has no setup and no teardown. The first version of EL-9 opened a channel
to the node, which no real client does.

**Correction 2 — the control channel is not optional.** The section below says
`0x06` is "observed but neither is needed for a working QSO". That is wrong, and
it follows directly from correction 1: with no `OPEN` for the node, the
`RR + SDES` compound is the *only* thing that starts a session. Without it a node
never answers. `EchoLinkRTCP.swift` therefore builds and parses `RR`, `SDES` and
`BYE`, against the two `0x06` frames in `live-proxy-rtcp.hex`.

`CLOSE` handling changed with it: a `0x03` closes a tunnelled channel, not the
session, and in a normal session it arrives a few hundred milliseconds after
connecting, when the directory channel shuts down on purpose. Treating it as the
link dropping would have ended every session before any audio.

**What is still not established:** whether a node answers a client that never
logged in to the directory. `--no-directory-login` exists to find out; no
capture shows the attempt, so the flag is an experiment rather than a supported
mode.

#### Live attempts, 2026-08-13 — the session now connects

Run against real public proxies and the real directory server, receive-only
(no microphone, PTT never pressed, so nothing was transmitted).

| Step | Result |
|---|---|
| Proxy login (EL-5) | ✅ **confirmed on air** |
| Directory login (EL-6) | ✅ **confirmed on air** |
| No `OPEN` for the node | ✅ the proxy accepted the session without one |
| Node answers the SDES | ✅ **confirmed on air** (after the fix below) |
| Audio both ways | ✅ **confirmed on air**, 2026-08-13 — Milestone M3 |

The two confirmations are the ones that mattered. A proxy in Chile that this
code had never met opened with `653e0d35` — an 8-byte ASCII hex nonce, exactly
as EL-5 predicted — and accepted `MD5("PUBLIC" ‖ nonce)`. So the digest
construction recovered by offline search against two captures also works
against a third, unrelated proxy. The directory server then accepted the
operator's real account password. Those were the two largest unknowns in
Phase 6.

**A real bug found and fixed by the attempt: SDES padding.** The encoder
followed RFC 3550 §6.5's minimum, on the reasoning that the two observed
senders disagreed about the padding and the region was therefore slack. That
reasoning was wrong — they follow the same rule, and it is not the RFC's:

    pad the chunk to a 32-bit boundary, then append four more null octets

    EchoHam     chunk 75 -> align 76 -> +4 = 80   (observed 80)
    thebridge   chunk 84 -> align 84 -> +4 = 88   (observed 88)

The RFC minimum gives 76 for the first, which no observed sender produced. With
the rule corrected, what we emit is **byte-for-byte identical** to a captured
working client for the same inputs — verified by diff, and pinned by
`testSDESPaddingFollowsBothObservedSendersNotTheRFCMinimum`. The module's own
rule is "parse permissively, emit what was observed", and the earlier version
broke it by preferring a specification to the wire in a place the specification
does not govern.

It did not fix the silence. What did was found by exactly the method this
project keeps reaching for: **capture ours and a working client's side by side,
and diff.** The maintainer captured several of our attempts followed by one
EchoHam session, all in one file.

#### The directory login is three lines, and we were sending one

Our `0x02` login frame against EchoHam's:

|  | EchoHam | ours |
|---|---|---|
| line 1 | `l` + callsign + `AC AC` + password + CR | `l` + callsign + **`0A 0A`** + password + CR |
| line 2 | `ONLINE<version>Y(<HH:MM>)` + CR | **absent** |
| line 3 | `<location>` + CR | **absent** |
| `0x02` peer field | the directory server | **`0.0.0.0`** |

Three separate mistakes, and the middle one is why nothing worked:

- **The separator is `0xAC 0xAC`, not `0x0A 0x0A`.** The OQ-9 write-up said
  "two separator bytes" without saying which, and LF is what "separator"
  suggests to anyone reading prose rather than octets. The server answers `OK`
  either way, which is why the guess survived.
- **The `ONLINE` line is what registers the station as available.**
  *Authentication is not registration.* Without it the server accepts the
  password, answers `OK`, and never lists the station — so no node will accept
  a connection from it, and every step reports success while nothing works.
  That is the whole reason `*ECHOTEST*` sat silent, and it is a good argument
  for distrusting a success that cannot be independently observed.
- **An outbound `0x02` names the directory server in its peer field.** The
  fixture holds only *inbound* frames, which are always `0.0.0.0`, and an
  earlier version read that as telling us what to send.

With all three corrected the session connects, and `*ECHOTEST*` answers by
name:

    Directory login accepted.
    Node answered: *ECHOTEST*
    INFO oNDATACONF Audio test server [9]  <our callsign and name>  This test
         server simply records and plays back transmissions for testing purposes.

**M3 is signed off**, and so is EL-11's `--list` fetch (6389 entries from a
live directory server, same day). `--location` and `--operator-name` set what
the far end displays.

---

### EL-11 — Station list ✅ DONE — parser and fetch, both confirmed on air
**Depends on:** EL-6. **Blocks:** nothing — deliberately off the path to M3.
**Files:** `Sources/EchoLinkKit/EchoLinkStationList.swift`,
`Sources/EchoLinkKit/EchoLinkClient.swift` (`fetchStationList`),
`Sources/hamvoip-cli/EchoLinkCommand.swift` (`--list`),
`Tests/EchoLinkKitTests/EchoLinkStationListTests.swift`.

Split out of EL-6 on 2026-08-12, because the login is evidenced and the list is
not, and bundling them would have held a ready task behind a missing capture.

Parses the station list the directory server returns after login: callsign, node
number, status, location, address. Feeds a browse/search UI in Currawong later;
the CLI has it as a `--list` dump.

#### The gate, and how it was resolved — 2026-08-13

The gate read: the only capture of a full station list carries 6548 other
operators' callsigns and 6261 IP addresses, EL-2 forbids cutting a `0x02`
fixture from it, and hand-typing "representative" entries is the same data with
the provenance filed off. It wanted a capture with a **deliberately truncated**
list, which nobody had.

**Ungated by the maintainer on 2026-08-13, and closed without that capture** —
because the gate was really two requirements wearing one coat, and only one of
them needed a fixture:

- *No third-party data in the repository.* Non-negotiable, and unchanged.
- *The format must be evidenced rather than guessed.* This is what a fixture
  normally provides, and it turns out a fixture is not the only way to provide
  it.

So there is **no station-list fixture, and there is not meant to be one**.
Evidence takes two other forms, both of which keep the data out of the tree:

1. **A measurement over the real list, recorded below.** Every rule in the
   parser is a counted fact about 6444 real entries, not a reading of three.
2. **A conformance test that runs against the real download** —
   `testTheRealListParses`. Skipped unless `HAMVOIP_TEST_STATION_LIST`
   points at a copy, which is not committed and cannot be. CI never runs it;
   anyone holding the capture can, and it asserts the tally below.

The tests that *do* run in CI are built from invented callsigns and RFC 5737
documentation addresses. They are not evidence and the file says so in as many
words — what they test is that the parser implements the measured rules, not
that the rules are right. The conformance test is what tests the rules.

This is the same shape as the OQ-5 and OQ-7 resolutions: the claim lives in
this document with its tally, the capture stays outside the repo, and the
assertion is reproducible by whoever holds it.

#### The grammar, measured

Reference download: **6444 entries, 433 414 bytes, 129 proxy frames**, from
`echolink-oq9-3.pcap` (cited by SHA-256 in `Tests/FIXTURES.md`, not by path).
The request is `f0` CR, three bytes, sent on a **second** tunnelled channel —
the login channel is not reused, and the proxy `CLOSE`s the login channel while
the list is still arriving on the new one.

    @@@                     LF      marker
    <count>:<serial>        LF      6444:64244576
    ─ repeated <count> times ─
      <callsign>            LF
      <location+status>     LF      fixed geometry, see below
      <node number>         LF      may be blank
      <address>             LF      dotted-quad IPv4
    +++                             terminator, not LF-terminated

| Measured | Value |
|---|---|
| Entries | 6444 declared, 6444 present |
| Stations | 6441 |
| Server notices (blank callsign, blank node, `127.0.0.1`) | 3 |
| Status word `ON` / `BUSY` | 6059 / 382 — **and nothing else** |
| Stations with no node number, or no time | 0 / 0 |
| Conference names (leading `*`) | 227 |
| Node-number range | 1005 – 1002775 |
| Status bracket opens at column 27 | 6441 of 6441, no exceptions |
| **Locations that themselves contain a bracket** | **3496** |

**The one subtle field, and the trap in it.** The second line is not free text
with a tag appended; it has fixed geometry, and the status bracket opens at
column 27. Splitting on the *first* `[` is the obvious implementation and it is
wrong for **3496 of 6441 entries — more than half** — because a location
beginning `[Svx] 145.6625` or containing `[0/20]` is entirely ordinary. That
reading reports a status of `Svx` for half the directory. The parser splits at
the column and falls back to the last bracket; on the reference list the two
rules disagree about nothing.

Two smaller findings, both of which would have become bugs:

- **The status word is not `ON`/`BUSY` plus a long tail.** An earlier pass over
  this data said it was, and that was an artefact of the first-bracket bug
  above — `Svx`, `ORP`, `ASL` were locations being misread as statuses. Every
  one of the 6441 stations says `ON` or `BUSY`. It is still carried as text
  rather than an enum: two values, one server, one day, is the sample we have
  and not a closed set. **The conformance test caught this**, against a
  hand-count that had it wrong.
- **The list is not UTF-8.** A location field contains a `0xA0`, so a UTF-8
  decode fails and takes the whole 433 kB download with it. Decoded as
  ISO-8859-1, which cannot fail.

#### What is done, and what is not

Done: the parser, an incremental reader (the download splits records *and*
fields across frames — one 16-byte frame carried `"N 12:42]\n730991\n"`),
`EchoLinkClient.fetchStationList()`, and `hamvoip-cli echolink --list`.

`--list` connects in `.directoryOnly` mode: proxy login, directory login, and
**no node session**. That is not a convenience. The list comes from the
directory server and has nothing to do with any node, so a `--list` that had to
reach one first could fail for a reason that is not about the list — which is
exactly the confound to avoid on the run that first tests it. It therefore
needs no `--peer` and no `--node`.

`fetchStationList` is deliberately **not** called by `connect` — a 433 kB
download has no business on the path M3 just signed off, and a test asserts
`connect` never sends the request.

#### Confirmed on air, 2026-08-13

```
# EchoLink Server v2.6.159
# ECHO1: Sydney, AU
# 6386 station(s), 3 notice(s); the server declared 6389.
Link down: local request
```

First attempt, and everything read off the capture held: the second `OPEN`, the
`f0` CR request, the framing and the grammar. **6386 + 3 = 6389, matching the
server's declared count** — and a count mismatch is a hard error here, so a list
that prints at all is one that arrived whole.

Three things this settles that the capture alone could not:

- **The format does not rest on one download.** This list has 6389 entries
  against the capture's 6444, a day apart and necessarily a different
  population, and the same parser reads both.
- **The notices were modelled correctly.** They were inferred from the capture
  structurally — three trailing rows with a blank callsign, a blank node number
  and `127.0.0.1`, shape-masked during analysis so as not to read other
  operators' data. They came back as `EchoLink Server v2.6.159`, a blank, and
  `ECHO1: Sydney, AU`: a server version banner and a server identification,
  exactly the kind of thing `notices` exists to keep out of `stations` while
  still counting toward the header's total.
- **The request needs no node.** `--list` runs in `.directoryOnly` mode, so this
  ran without any node session at all.

**Done when:** ~~the list parses from a truncated-list fixture~~ — the list
parses, with the format evidenced by measurement and a reproducible conformance
test rather than by a fixture; a malformed or partial list is a typed error
rather than a silent short read (`missingTerminator`, `truncatedRecord`,
`countMismatch`); and no fixture, test or document contains a callsign,
location or address belonging to anyone else. ✅

### Station info and the control channel — ⚠️ superseded 2026-08-13

This section used to read: "`0x06` frames carry RTCP-shaped packets (type 201
with an SDES), and station info arrives on the `0x05` channel as text beginning
`oNDATA`. Both are observed but **neither is needed for a working QSO**, and
neither has been decoded past its outer shape."

**The emphasised claim is false, and EL-10 found out the expensive way.** Since
no `OPEN` is ever sent for an audio peer, the `RR + SDES` compound on `0x06` is
the *only* thing that opens a node session — a client that does not send it is
never answered. `0x06` is now decoded (`EchoLinkRTCP.swift`) and `BYE` is sent
on teardown. See the EL-10 entry for the frame-by-frame sequence.

The `0x05` text channel is decoded only far enough to keep it *out* of the
audio path: `oNDATA` fed to an RTP parser reads as version 1, payload type 78,
and plays as noise. `EchoLinkAudioChannelMessage` classifies before parsing and
surfaces the text verbatim as an event. Its internal structure is still
undecoded, and still deliberately so — nothing needs it.

The general lesson is worth keeping even though the specific claim did not
survive: "not needed for a QSO" was inferred from what the frames *looked* like,
not from tracing what a session actually required. Checking which peers ever
receive an `OPEN` took one pass over the captures and would have caught it.

### EL-12 — Public proxy discovery (`--auto-proxy`) ✅ DONE
**Depends on:** EL-10. **Blocks:** nothing; the app wants it (see below).
**Files:** `Sources/EchoLinkKit/EchoLinkProxyDirectory.swift`,
`Sources/hamvoip-cli/EchoLinkCommand.swift` (`--auto-proxy`),
`Tests/EchoLinkKitTests/EchoLinkProxyDirectoryTests.swift`,
`Tests/EchoLinkKitTests/Fixtures/proxyfind-sample.xml`.

Added 2026-08-13, from the operator's complaint that using EchoLink meant
opening echolink.org and reading a proxy list by hand before every session.

**There is no proxy directory protocol, and this task is not one.** EchoLink
publishes the same list two ways: `proxylist.jsp`, an HTML table for humans, and
`proxyFind.jsp`, which returns XML pre-filtered to the proxies that are both
public and `Ready`, sorted by distance ascending. Fetched in the same second on
2026-08-13 the page had 932 rows of which **282** were `Ready`, and the XML had
**282** entries with no discrepancy either way — so the endpoint is the same
data in a form that needs no HTML parsing, and this is a web fetch, not a wire
protocol. Nothing here touches LP-1/LP-2: the source is the service operator's
own published endpoint.

Three design points, each of which cost a measurement to establish:

1. **`Ready` is not enough, so each candidate is probed.** A public proxy is
   single-user; the status is a poll snapshot; a taken proxy accepts the TCP
   connection and then hangs up without a nonce. The probe connects, reads the
   8-byte greeting, sends **nothing**, and closes. On the first live run,
   VK2BSD #4 in Sydney — 465 km away and listed `Ready` — did not answer, and
   the session went to Chile. A distance-sorted first pick would have failed
   with `proxy: the proxy stream closed`.
2. **Distance orders the candidates; latency chooses between them.** From VK1
   there was nothing under 5000 km on 2026-08-13, so great-circle kilometres
   say very little. The probe timeout is 3 s because the live run measured
   **1363 ms** to greet a Chilean proxy with DNS and handshake included; 2 s
   left no margin, and being too short discards working proxies silently.
3. **`lat`/`lon` are accepted by the endpoint and deliberately not sent.** IP
   geolocation was accurate to ~11 km for a Canberra request, which is noise at
   these distances — so sending real coordinates would mean a location
   permission in the app and the operator's position handed to a third party,
   for nothing measurable.

Etiquette is part of the task rather than an afterthought: `robots.txt` disallows
only `/links.jsp`, probes are one round trip each and capped
(`--proxy-candidates`, default 5, and a 15-candidate ceiling), and every
auto-selected run says on stderr that public proxies are shared and echolink.org
asks for brief use. The answer for sustained use is a **private proxy**
(`EchoLinkProxy.jar` on a host with a public IP), which `--proxy` already
supports.

The library half is deliberately app-ready: `EchoLinkProxySelector`,
`EchoLinkPublicProxySource` (the fetch seam, so no test makes an HTTP request —
AU-5), `EchoLinkProxyProbe` (its transport injected, so no test opens a socket)
and `EchoLinkProxyListParser`. It is **not** on `NetworkClient` and should not
be: it produces the `host`/`port` for an `EchoLinkDestination.Route.proxy`, and
in Currawong that makes it composition-root work.

**Done when:** the parser round-trips a fixture of the real document including
its awkward cases, selection and probing are tested without a socket or an HTTP
request, and `--auto-proxy` picks a proxy on a live run. ✅ All three;
34 tests, and the live run above.

### EL-15 — The private proxy is one setting, not three ✅ DONE
**Depends on:** EL-12 ✅. **Blocks:** nothing. Related: **APP-13**, which gives
the app the same shape.
**Files:** `Sources/hamvoip-cli/EchoLinkProxySettings.swift` (new),
`Sources/hamvoip-cli/EchoLinkCommand.swift`,
`Tests/HamVoIPCLITests/EchoLinkProxySettingsTests.swift`, `docs/CLI.md` §9.

Added 2026-08-20, from a real state a config directory was found in: it held
`ECHOLINK_PROXY_PASSWORD` and nothing else. **A proxy password with no proxy
beside it is not a setting** — nothing could act on it, and no code ever read
it, because `--proxy-password` was the one credential in the CLI that bypassed
`SecretPrompt.resolve` entirely. It looked configured and did nothing.

So host, port and password now resolve **together**, through the ordinary
`ConfigFile` convention (`ECHOLINK_PROXY`, `ECHOLINK_PROXY_PORT`,
`ECHOLINK_PROXY_PASSWORD`; command line → environment → file → default). That is
deliberately the same shape APP-13 gives Currawong — host and port in
`UserDefaults`, password in the Keychain, as one app-wide value — rather than a
second arrangement for the same setting.

**The rule worth the separate type: a configured password is only ever sent to
the proxy it was configured for.** Dial another host, or `--auto-proxy`, and it
falls back to `PUBLIC` with a note on stderr. The proxy login hashes the password
into a digest, so a stranger's proxy handed a private one gets material to attack
offline while we gain nothing — a public proxy accepts `PUBLIC` regardless.
`--proxy-password` other than `PUBLIC` is refused outright with `--auto-proxy`,
where the destination is a stranger by definition: a password typed on purpose
deserves an error, not a silent substitution.

A malformed `ECHOLINK_PROXY_PORT` is an error rather than a silent 8100, on the
same reasoning as OQ-10's method note — a fallback that connects to *something*
teaches the operator nothing.

**Done when:** the three parts resolve from all four tiers, the password is
withheld from any host but its own (including under `--auto-proxy` and when no
host is configured at all), host matching is case-insensitive, and a malformed
port fails loudly. ✅ All of it; 20 tests, none touching the real config
directory.

## Phase 7 — M17Kit

### M17-1 — Codec2 XCFramework spike ⛔ gate (OQ-2) — RESOLVED ✅ DONE
Build script (`scripts/build-codec2-xcframework.sh`) compiling codec2
(LGPL-2.1, from drowe67/codec2 — building it is fine; it is not a protocol
implementation) as a **dynamic** XCFramework for iOS device, iOS simulator,
macOS arm64, with licence text bundled (LP-4). Deliverable: script + a
written result on whether all three slices link. **A human confirms the
gate before M17-3 proceeds.**

### M17-2 — Base-40 callsign codec (FR-2.3) ✅ DONE
**Depends on:** nothing — pure function, can run any time.
Per M17 spec "Address Encoding": charset index 1…39 =
`A–Z`, `0–9`, `-`, `/`, `.` (verify exact order in spec); value =
Σ char_i × 40^i from the rightmost character; 48-bit big-endian field;
`0xFFFFFFFFFFFF` = broadcast. Encode + decode + validation, exhaustive
round-trip tests including 9-char max and rejection of invalid characters.

### M17-3 — Reflector control (FR-2.1) ✅ DONE

Confirmed layouts (this plan's earlier one-line summary grouped them wrongly —
`ACKN`/`NACK` carry **no** address, `PING`/`PONG` **do**, and `DISC` has two
legal lengths):

| Packet | Size | Contents |
|---|---|---|
| `CONN` | 11 | magic(4) + 'From' address(6) + module `A`–`Z`(1) |
| `ACKN` | 4 | magic only |
| `NACK` | 4 | magic only |
| `PING` | 10 | magic(4) + 'From' address(6) |
| `PONG` | 10 | magic(4) + 'From' address(6) |
| `DISC` | 10 or 4 | magic + address, or magic alone (ack of a `DISC`) |

⚠️ **The reflector protocol is not in the PDF at spec.m17project.org.** That
document is Part I (Air Interface) and has no IP networking chapter. The
reflector chapter was published as HTML at a readthedocs host that now returns
"Project not found", so M17-3 worked from an Internet Archive capture,
cross-checked against a 2022 capture to confirm the tables are unchanged. See
`docs/reference/PROVENANCE.md`. **The specification this code implements is
currently offline.** Worth the maintainer deciding whether to keep a local copy
of the archived chapter in the repository, licence permitting — right now the
only record of what we implemented against is a third-party archive.

The spec states **no timer values at all**. The 5 s connect and 30 s keepalive
deadlines are local policy, documented as such and injectable.

### M17-4 — Stream mode RX/TX (FR-2.2) ✅ DONE
**Depends on:** M17-3 ✅, M17-1 ✅ (OQ-2 resolved). Needs a `Package.swift`
change (codec2 C shim target) — one of the few tasks permitted to touch it.

M17-3 already implements `M17StreamPacket` parse/serialize: magic `"M17 "`
(trailing space), SID(2), LICH(28), FN(2) with end-of-stream flag `FN & 0x8000`,
payload(16), CRC16(2) — 54 bytes. LICH decomposes as DST(6) SRC(6) TYPE(2)
META(14), and **no LSF CRC** (OQ-7). Encryption bits in TYPE are parsed and
surfaced **only** as `isEncrypted`/`playability == .encrypted` — there is no
cipher enum, no key parameter and no decrypt path, and M17-4 must not add one
(FR-2.5).

M17-4's job is the Codec2 3200 wiring (2 × 64-bit frames per 16-byte payload,
confirmed by the M17-1 spike) and TX/RX stream sequencing.

✅ **Done, except for live validation.** What landed:

- `M17CRC16`, `M17StreamPacket.isCRCValid`, and a CRC-computing initialiser.
- `Codec2VoiceCodec` — Codec2 3200 as a `RadioCore.VoiceCodec`, bound straight
  to the XCFramework. **No C shim target was needed**: the generated module map
  imports into Swift directly. Dynamic linking only (LP-4).
- `M17StreamPayload` — the 16-byte payload is two 8-byte codec frames, 40 ms.
  Both halves are queued as separate 20 ms slots, so one lost datagram conceals
  as two ordinary gaps and the rest of the stack keeps its 20 ms tick.
- `M17FrameNumberExpander` — FN is 15 bits and wraps every 21.8 minutes.
- `M17StreamTransmitter` / `M17StreamReceiver` — value types, no clock and no
  task, mirroring `IAX2VoiceTransmitter` / `IAX2VoiceReceiver`.

**`Package.swift` is conditional, and this is the part to know about.** The
XCFramework is never committed, but CI builds a bare checkout, and a
`binaryTarget` pointing at a missing path is a hard manifest error. So the
manifest probes for `Codec2.xcframework` and adds the binary target plus a
`CODEC2` condition only when it is there. The sequencing is written against
`VoiceCodec`, so it is tested either way — 597 tests without the framework,
605 with it. Run `swift package reset` after building or deleting the
framework; SwiftPM caches the manifest against its contents, not against the
filesystem the probe reads.

**Since settled on the air, 2026-08-16 — the receive half.** A net on M17-434
was listened to at length through Currawong: intelligible audio throughout and
transmitting stations' callsigns displayed. The decode path, the jitter buffer,
stream receive and the base-40 reading all work against traffic this project
did not generate. **The transmit half followed on 2026-08-17**: confirmed
heard via an independent client. See the live-validation block in the M17-5
entry.

✅ **OQ-7 is settled — 54 bytes, resolved 2026-08-11 against a live reflector**;
see the open questions table for the evidence. The frame size is no longer an
assumption, so stream TX may be built on it.

Two things M17-4 inherits from that:

- **The single CRC is the whole-datagram one.** ✅ **Done** — `M17CRC16` plus
  `M17StreamPacket.computedCRC` / `.isCRCValid`, and a CRC-computing
  initialiser for TX. There is no LSF CRC to verify; it is not transmitted.

  Worth recording, because it came out of doing the work: **the spec pins the
  polynomial (`0x5935`) and the initial value (`0xFFFF`) but not the rest of
  what a CRC needs** — bit order, and whether a final XOR applies. Those were
  settled the same way OQ-7 was, by measuring. Of the eight combinations of
  reflected input, reflected output and final XOR, exactly one closes over the
  first 52 bytes of a captured stream datagram to give its trailing two, and it
  does so in **52 of 52** frames of the OQ-7 capture; the other seven match
  none. The answer is MSB-first, no reflection either way, no final XOR. The
  Swift implementation was then run against those same 52 frames and validates
  all 52. For the conventional `"123456789"` vector this parameterisation gives
  `0x772B`, which `M17CRC16.checkValue` pins — that constant is *not* in the
  spec text we hold, and is recorded because it is the cheapest way to catch a
  mis-transcribed table.

  Parsing deliberately does **not** enforce the CRC: a corrupt datagram is
  still parsed and reported through `isCRCValid`, so a receiver can count or
  conceal it rather than have it vanish into a thrown error.
- **`hamvoip-cli oq7` stays useful** as a re-check against a second reflector,
  and it still measures below the parser: `RecordingTransport` taps the
  `DatagramTransport` seam rather than `M17ReflectorClient.events`, because the
  client correctly discards anything that is not exactly
  `M17StreamPacket.byteCount` bytes. That is what let the experiment contradict
  the code running it, and it is why a reflector sending some third length
  would be reported rather than look like silence.

### M17-5 — `M17Client` public API ✅ DONE
**Depends on:** M17-4. Mirrors IAX-8: conforms to `NetworkClient`,
composes jitter buffer + Codec2 + watchdog + leveller; fixture-driven
end-to-end test; then a CLI-1 subcommand (`hamvoip-cli m17 …`) for live
human validation.

✅ **Code done; the live validation is not, and cannot be done from here.**

- `M17Client` — actor, conforms to `NetworkClient`, composes
  `M17ReflectorClient` + `M17StreamTransmitter`/`Receiver` + `JitterBuffer` +
  Codec2 + `TransmitWatchdog` + `AudioLeveller`. 14 tests on `MockTransport`
  and `ManualTestClock`; no socket (AU-5).
- `M17ReflectorClient.send(_:)` — the link layer's outbound media path, which
  M17-3 did not need and so did not have.
- `hamvoip-cli m17 --host … --module C --callsign …` — the live harness.
- `TransmitStateBox` moved from `IAX2Kit` into `RadioCore`, since both clients
  now need it. It was always a RadioCore concern.

**The 20/40 ms mismatch is handled inside `M17Client`.** Everything else in the
stack works in 20 ms frames; an M17 datagram carries 40 ms. `send(pcm:)` takes
the same 20 ms frame the IAX2 path takes and holds every other one back,
returning `nil` on the odd calls. Callers — including `AudioPipeline` — are
unchanged.

✅ **The receive half is settled on the air — 2026-08-16.** A net on M17-434,
listened to at length through Currawong (which uses this library by version):

1. **Audio was intelligible throughout**, for the length of a net rather than a
   few seconds. Codec2 decode, the jitter buffer and the 40 ms → 20 ms handling
   all hold up against real traffic from stations this project has no control
   over.
2. **Transmitting stations' callsigns were displayed**, which validates the
   base-40 decode and the LSF field offsets against many senders rather than
   the one over OQ-7 measured.
3. **M17-434 appears to be the more active VK1 net.** Worth observing over more
   sessions before drawing conclusions about reliability.

✅ **The transmit half is settled on the air — 2026-08-17.** The maintainer
transmitted from Currawong (this library by version) to M17-434 module B while
monitoring the same reflector through Mseven, an independent M17 client, and
found the audio readable; the reverse direction was re-confirmed in the same
session. What that validates, item by item, is exactly the list that was open:

1. **The encoder.** Codec2 3200 output was intelligible to somebody else's
   decoder, not only to our own round-trip test.
2. **The LSF fields and the SID.** A receiver this project did not write
   accepted and played the stream, so the field offsets and framing we reasoned
   from the specification are what a real implementation expects.
3. **The DST we send** — `BROADCAST`, the module chosen by `CONN` — was
   sufficient for a reflector client to receive us.

Scope of the claim, in the standing style: one reflector, one receiving
implementation, one operator at both ends. A different receiver disagreeing
would be new information rather than a bug. The parrot route M17-6 proposed is
no longer needed for *this* question; the CLI banner's "believed working"
wording should be updated to cite this confirmation.

### M17-6 — A chosen destination ⏳ OPEN (re-scoped 2026-08-17; the parrot half is moot)
**Depends on:** M17-5 ✅. **Raised by:** the maintainer, 2026-08-16, after M17
receive was confirmed on air and transmit was not.

ℹ️ **Re-scoped 2026-08-17: the confirmation half of this task is done without
it.** Transmit was confirmed heard the same day via Mseven against M17-434 B
(see M17-5), so the parrot is no longer the route to anything this plan needs.
What survives is the library change below — DST is still hard-coded
`BROADCAST`, which is a capability the mode has and we do not expose — and the
parrot experiment remains worth a lazy afternoon for its own sake (readings 1–3
below are still undistinguished, and `#ECHO` still does not encode). The
original text stands as the design record:

**The problem this solves.** Confirming our M17 transmit is *readable*
currently needs a second operator with a receiver and the patience to report
back. A parrot removes the second human — it echoes the transmission back, so
one operator can hear what they sound like. It is what `*ECHOTEST*` does for
EchoLink, and it is why EchoLink was the easiest mode to validate.

**What we have been told, and its provenance.** From the M17-Users list
(`https://groups.io/g/M17-Users/topic/would_a_parrot_reflector_be/113083205`),
relayed by the maintainer: *"If you select a destination of #ECHO, that will
cause any hotspot or repeater to parrot your transmission. That would be in
place of a reflector or other station callsign in the destination."* Attributed
to Jeff, **possibly AE5ME — unconfirmed**; build nothing on the name.

**A hypothesis to test on air, not a specification.** Mailing-list prose is the
weakest source class this project admits (the OQ-9 candidate-(d) bar) and this
has not been checked against the M17 spec. It is a *good* hypothesis — it comes
from the mode's own users and costs one transmission to test — but it is not a
citation.

**And it does not encode.** `#` is **not in the M17 alphabet**: Table A.1 has 40
symbols — space, `A`–`Z`, `0`–`9`, `-`, `/`, `.` — and `Base40Callsign.encode`
throws on anything outside them by design (FR-2.3), rather than coercing to
space the way the spec's illustrative C routine does. So `"#ECHO"` cannot be a
base-40 destination as written. Three readings survive, distinguishable by
experiment:

1. **`#` is a user-interface convention** and what goes on the wire is the
   base-40 encoding of `"ECHO"`.
2. **`#ECHO` names a reserved address value** in the extended range above
   `standardRangeMax` (Table A.2 reserves that range "for application use"),
   in which case what matters is the value, not any text.
3. **It is an RF-side convention only**, honoured by hotspot and repeater
   firmware — note the quote says *"any hotspot or repeater"*, not *reflector*
   — in which case it may do nothing for a client that reaches a reflector over
   IP, which is every path this library has.

**Read the specification first.** Appendix A.3 / Table A.2 is a permitted
source and is where a reserved address would be defined; the archived reflector
chapter (OQ-8) mentions neither echo nor parrot. If the PDF names it, this
stops being an experiment. **Do not settle it by reading anybody's firmware** —
LP-1 and LP-2 are unchanged, and a parrot is not worth a clean-room breach.

**The library change underneath is small and worth having regardless.**
`M17Client` hard-codes `BROADCAST` as DST, since the module is chosen by
`CONN`. Making the destination configurable — defaulting to `BROADCAST`,
accepting a callsign or a raw 48-bit address — is a capability the mode has and
we do not expose, and all three readings above need it.

**Done when:** DST is configurable on `M17Client` with `BROADCAST` as the
default; a raw address can be supplied for the case where no text encodes; the
CLI can set it; a test pins each form; and either the specification is cited
for what a parrot destination is, or an on-air experiment records which reading
worked, against which peer, in the same style as the OQ-7 tally. **A parrot
that works also closes the M17 transmit question above** — record that outcome
there, not only here.

### M17-7 — Weebill: Codec 2 3200 in pure Swift (FR-2.4) ✅ DONE (library)
**Depends on:** M17-4 ✅ (the `VoiceCodec` seam `Codec2VoiceCodec` conforms to).
**Raised by:** the maintainer, as a second implementation of the same codec
rather than a replacement — the point is A/B, not migration.

**What landed.** A second `Package.swift` dependency —
`https://github.com/cpmpercussion/weebill`, `from: "0.1.0"`, BSD-2-Clause, pure
Swift, no dependencies of its own — the second this package has ever taken
(rule 8; `swift-argument-parser`/CLI-1 was the first). `WeebillVoiceCodec`
conforms to `RadioCore.VoiceCodec` exactly as `Codec2VoiceCodec` does: 160
samples / 8 bytes, lock-guarded (the audio path is synchronous and real-time,
so no actor), separate encoder and decoder instances, and a `phaseSeed`
pinned by default because Weebill synthesises unvoiced phases stochastically
and an unpinned codec would make every downstream test unreproducible. Twelve
tests in `WeebillVoiceCodecTests`: geometry, the two-frames-per-payload
arithmetic, input validation, decode determinism across instances, `reset()`,
pitch-and-level survival through a round trip, silence, and a 2000-frame
random-bitstream fuzz asserting `nonFiniteSampleCount == 0` — all unconditional,
so they run on a bare checkout and on CI. Three more, gated `#if CODEC2` because
they need the framework on both sides: codec2 decodes what Weebill encoded,
Weebill decodes what codec2 encoded, and both report the same geometry.

**Unlike `Codec2VoiceCodec`, this needed no manifest probe.** The framework is a
binary that may or may not have been built locally, so `Package.swift` has to
guess whether it is there (`codec2IsBuilt`) before it can even reference it.
Weebill is source, so it is simply always a dependency — no `#if`, no
conditional target, no `swift package reset` after building or deleting
anything. `hamvoip-cli m17` follows from that: the whole command used to be
compiled out behind `#if CODEC2` and would refuse to run at all without the
framework (M17-4's note). That gate is gone. The command now runs on any
checkout, defaulting to Weebill, with a new `--codec weebill|codec2` option for
on-air A/B; `--codec codec2` throws a `ValidationError` naming the build script
on a checkout without the framework, rather than silently falling back to
Weebill and reporting a result for a codec that did not run.

**Full suite: 1039 tests, 0 failures, 4 skipped.**

**What this does not do.** It does not remove `Codec2VoiceCodec` — that stays
exactly as M17-4 left it, LGPL XCFramework, `#if CODEC2`, unchanged by this
task. Weebill sits *alongside* it; removing codec2 is a later, separate
decision that has not been taken, and nothing here forces it. It also does not
touch FR-2.4's wording ("Codec2 3200 bps encode/decode via dynamic framework")
— that text no longer describes the *default* path (Weebill is source, not a
framework, and is what a bare checkout now runs), and wants revisiting **when**
codec2 is actually removed, not before; changing a requirement's wording to
match an implementation that has not yet made the old wording untrue would be
getting ahead of the decision. See OQ-6 below for what this does and does not
settle about LGPL relinking.

⚠️ **A measured finding, recorded because it is exactly the trap the next
person will fall into.** On a synthetic 8-harmonic voiced signal, the two
encoders choose the *same* 7-bit pitch quantiser index at 100, 150 and 200 Hz,
and differ by two steps at 125 Hz — index 77 vs 79, about 3%, inaudible. The
two implementations are not bit-identical and are not expected to be: Codec
2's analysis stage is not specified to the bit, so two conforming encoders may
legitimately land on different indices. A first attempt at the cross-decode
test appeared to show the Weebill encoder halving the pitch (62 Hz for a
125 Hz input) — that was a fault in the *test's* autocorrelation, which locked
onto the double period on a perfectly periodic synthetic signal, not a fault in
either codec. The fundamental-estimator now normalises by both windows' energy
and takes the shortest lag within 10% of the best.

**Honestly recorded, not glossed over:** the perceptual claim behind this
task is the maintainer's — they listened to test audio through every
encode/decode combination and could hear no difference. The in-tree tests above
are a regression net under that judgement, not the evidence for it.

✅ **RECEIVE PROVEN ON AIR 2026-08-28.** A net on **M17-842 module H**, decoded
by `WeebillVoiceCodec` in Currawong on macOS (APP-27, library v0.6.0), heard by
the maintainer: other operators' audio, intelligible, with no fault attributable
to the codec — "as fine as multiple-stage-encoded 3200 bps audio is likely to
sound". That is other stations' encoders through our decoder, which is the
direction a listener depends on and the one the OQ-7 differential could only
approximate offline.

✅ **TRANSMIT HEARD BY THE REFERENCE CODEC, SAME DAY.** Weebill encode →
M17-CBR module A → a **second Currawong running `Codec2Codec`**, i.e. the
drowe67 codec2 1.2.0 XCFramework, decoding it: normal Codec 2 quality, no
artefact the maintainer could attribute to the encoder. This is the harder
direction and the one no test here can reach — decoding a reference bitstream
demonstrates the quantiser tables and the unpacking, while *encoding*
demonstrates that our analysis stage picks indices a reference decoder renders
as speech. It now has, over a real network path.

⚠️ **What it is not: an independent station.** Both ends are our own app, by
one author, on one machine, against a reflector we operate. The decode side is
genuinely the reference C implementation rather than Weebill checking its own
work, which is what makes the result worth having — but a third-party client
reporting us readable, in the style of the M17-4 sign-off of 2026-08-17, is
still owed and is what would close this out. **Do not remove codec2 before
then**: it is both the fallback if transmit turns out to be where the two
implementations diverge, and — as this result shows — the instrument that
measures whether they do.

**Measured against real on-air audio, decode side only.** The one piece of
evidence here that is neither synthetic nor a matter of taste: both decoders
were fed the *same* Codec 2 bitstream taken off the air — the 104 frames
(52 datagrams x 2, 2.08 s) carried by `experiment-data/m17-oq7.pcap`, the OQ-7
capture, produced by a third party's encoder on a public reflector. Mean
absolute per-frame RMS difference **0.38 dB**, max **2.27 dB**, Pearson r
between the two RMS envelopes **0.98**, and **zero** non-finite-sample
substitutions from Weebill across the run. Both decodes are written out as WAVs
beside the report in `experiment-data/weebill-m17-7/`.

Three limits on that number, none of them small. It is **decode only** — the
bitstream came from an encoder we do not control, so there is no reference for
what *our* encoder should emit and the encode direction is untested against
anything but codec2 itself. It is **2.08 seconds**, the whole of the only
real-traffic capture we have. And **RMS-in-dB is a loudness measure**: it would
not notice two decoders that agreed on level while disagreeing on timbre. It
is corroboration of the maintainer's listening, not a substitute for it, and
the on-air test is still owed.

⚠️ **The capture stays out of the repo, and so does everything cut from it.**
`m17-oq7.pcap` is passive capture of other operators' traffic and deliberately
has no fixture (CLAUDE.md; `docs/CLI.md` §8). The extracted frames, the WAVs and
the report live in `experiment-data/`, unversioned. Do not promote any of it to
`Tests/`: the differential is reproducible from the capture, and the in-tree
tests are synthetic precisely so they can be committed.

---

## Phase 8 — Silent operating mode (speech to text, text to speech) 🔬 SPIKE FIRST

**Proposed 2026-08-16 by the maintainer.** Work a channel without listening or
talking: received audio transcribed on screen, typed text spoken onto the air.
Two constituencies, and they are not the same:

- **Accessibility.** Deaf and hard-of-hearing operators, for whom a voice mode
  is otherwise closed. This is the one that matters, and it changes what
  "good enough" means — a transcript an operator *relies* on has a higher bar
  than one that merely supplements audio they can hear.
- **Circumstance.** Anyone who cannot use audio right now: a house with
  children in it, a quiet carriage, a sleeping household, a noisy workshop.

**Why it is worth doing.** It fits a phone better than it fits a radio, it uses
hardware every target device already has, and it would make the app better than
a handheld rather than merely equivalent to one. Whether any existing client
for these modes already does it is **unchecked** — worth ten minutes before
committing to the work, and not a claim to make in public copy until somebody
has looked.

**SIL-1 — Design spike ⏳ OPEN. Nothing else in this phase is scheduled, and
deliberately so.** Decide these before writing a task list; several could sink
the feature or change its shape entirely:

1. **What can on-device speech do with this audio?** The crux, and not the
   usual question: received audio is **8 kHz and has already been through a
   vocoder** — G.711 µ-law on AllStarLink (kind), GSM 06.10 on EchoLink (less
   so), Codec2 3200 on M17 (brutal). Recognisers are trained on wideband
   speech. **Measure per codec before designing anything**: known audio through
   each mode's codec, transcribed, scored. A feature that works on AllStarLink
   and produces nonsense on M17 is a different product — and an accessibility
   feature that degrades silently is worse than one that says it cannot hear
   well enough.
2. **Which API, at what deployment floor?** The most capable on-device speech
   APIs are the newest, which collides with the floor that became iOS 16.2
   with APP-3. Availability-gating to recent OSes may well be right; decide it
   with (1)'s numbers in hand. Synthesis is the easier half — the older APIs
   are adequate.
3. **Speaking onto the air is a regulatory act.** Station identification is the
   operator's legal responsibility and must not be left implicit in a text box.
   Work out what the app owes, in VK1 terms first.
4. **The half-duplex trap.** Typing is far slower than speaking, and a net will
   not wait. The interaction design decides whether this is usable — canned
   phrases, compose-then-send, an indication that a station is composing — so
   prototype that before any plumbing.
5. **Where it lives.** Not protocol work: all of it belongs in Currawong, above
   the `NetworkClient` seam. `receivedAudio` already exposes PCM and
   `send(pcm:)` already accepts it. Needing something from the library would be
   a finding worth reporting, not a licence to reach downward.
6. **Does it change the safety story?** SF-1 … SF-4 assume an operator who can
   hear their own transmission — and an operator who cannot is exactly who a
   stuck transmitter hurts most. Most likely to produce a new requirement
   rather than a new task.

**Done when:** a written finding with **measured** per-codec numbers, a
recommendation on the API, and a decision on the interaction model — enough to
decompose the phase or to record why it is not worth building. A prototype
transcribing a recorded M17 over beats any amount of reasoning about it.

⚠️ **Not a reason to delay APP-3.** SF-4 is a safety requirement with a
requirement number; this is a feature idea, however good.

---

## Open questions owned by the maintainer (not agents)

| ID | Question | Blocks |
|---|---|---|
| ~~OQ-1~~ | ~~EchoLink ToS permit third-party clients?~~ **RESOLVED: yes — the terms are not the blocker.** Maintainer's judgement, 2026-08-09. The terms govern *who may use the service* — a validated licensed amateur — not *what software they use to reach it*; they are written about the person and make no mention of the client. FR-3.4 already keeps us on the right side of that distinction: the operator supplies their own validated EchoLink credentials, the app performs no validation of its own, and it grants no access the operator did not already have. Nothing the terms protect is being circumvented. Supporting evidence: third-party clients have coexisted with the service for roughly two decades — SvxLink/EchoLib, thebridge, "Echo" on Android, MicroLink for microcontrollers, and more obscure or dead ones besides — with no visible enforcement against them. That is evidence about posture, not a licence grant. Underlying it is the amateur service's own norm: an operator reaches a band from whatever equipment they choose, and EchoLink has effectively established itself as a new band. **What this does not resolve:** trademark (OQ-1b) and clean-room sourcing (OQ-9). | **Phase 6 is still blocked — on OQ-9, no longer on the terms** |
| **OQ-1b** | **"EchoLink" is a Synergenics trademark; resolving OQ-1 did not license the name.** Nominative use only. The mark may be used descriptively, to say what the app interoperates with — "EchoLink-compatible", a mode label in a picker. It MUST NOT appear in the app's name, icon, launch screen, App Store title or subtitle, or anywhere implying endorsement, affiliation or official status. The requirements table's single "Trademark / ToS" cell conflated this with OQ-1; they are separate questions and only one of them is now settled. | Phase 4 UI copy; App Store metadata for EchoLink support |
| ~~OQ-2~~ | ~~Codec2 XCFramework builds all three slices?~~ **RESOLVED: yes.** All three slices build dynamic and sign cleanly; see `docs/reference/CODEC2-XCFRAMEWORK.md`. | — |
| ~~OQ-3~~ | ~~App name~~ **RESOLVED: "Currawong".** A bird with a distinctive, far-carrying call, and locally notable in VK1. Trademark databases checked: nothing in class 9 (the class that governs software); the hits are food/wine, tourism operators, and "Currawong Engineering" — no app. Derives from no existing product's branding, as OQ-3 required. Library naming is unaffected: the package stays `swift-hamvoip`. **Bundle identifier still open** — see OQ-3b. | — |
| ~~OQ-3b~~ | ~~Bundle identifier~~ **RESOLVED: `au.charlesmartin.currawong`.** Extensions extend it (`…currawong.liveactivity`); the Keychain access group is `$(TeamID).au.charlesmartin.currawong`. | — |
| ~~OQ-4~~ | ~~App in a separate repo?~~ **RESOLVED: yes**, a separate `currawong` repo depending on `swift-hamvoip` via SPM. Keeps the Apache-2.0 protocol libraries reusable, keeps app-only dependencies out of the library repo, and lets the two release independently. | — |
| **OQ-5** | ✅ **RESOLVED 2026-08-09 — hexadecimal. Keep sending lowercase; no code change.** Settled by `hamvoip-cli oq5 --method register --exhaustive` against an ASL3 node (Asterisk + app_rpt in a UTM VM), packet capture retained. Result: **`lowercase-hex` ACCEPTED** (REGACK), **`uppercase-hex` ACCEPTED** (REGACK), **`base64` REFUSED**, **`raw-bytes` REFUSED** — both refusals `CAUSE "Registration Refused"`, `CAUSE CODE 29`, and each of the four probes got its own fresh CHALLENGE on its own UDP association, so these are four independent verifications. Both hex cases being accepted is not a contradiction and does not make the run unreliable: the node is decoding the IE text back to sixteen bytes, or comparing it case-insensitively. The refusals are what carry the weight — a node that accepted anything would have taken base64 too, so the digest is genuinely being checked. Corroborated on the wire: the node answered REGACK immediately but held both REGREJs for ~1.0 s, the pacing of a real credential check that failed rather than a parse error. **Scope of the claim:** this is an observation about one implementation, not a fact about the protocol. Case-insensitivity is that node's business; another peer may well compare byte-for-byte, so `IAX2Auth.TextDigestEncoding.oq5Default` stays lowercase hex. **Original question:** §8.6.15 says the IE carries the UTF-8-encoded MD5 of `challenge ‖ password`, but the RFC never states the text encoding — hex or not, upper or lower case, padded or not. Unresolvable from the specification, and LP-2 forbids reading an implementation to find out. | Confirms IAX-4's shipped assumption. Unblocks the `connect` path and FR-1.3 registered node mode; downgrades the `IAX2Registrar` encoding seam from defect to hygiene |
| **OQ-6** | ⏸ **DEFERRED 2026-08-13 — revisit before submission, not before. Now *avoidable*, as of M17-7 (2026-08-28) — not resolved.** The maintainer's call stands: App Store submission is gated behind substantial UI/UX and testing work in Currawong that has not started, so deciding this now would be deciding it twice. **The question:** **LGPL-2.1 relinking vs App Store code signing.** Shipping Codec2 as a dynamic framework satisfies LP-4's letter, but a signed iOS app cannot have its framework substituted by the user, which is what LGPL §6 relinking is for. **What M17-7 changes:** the question only binds if `Codec2VoiceCodec` (the LGPL XCFramework) is what actually ships, and after M17-7 it no longer has to be — `WeebillVoiceCodec` (BSD-2-Clause, pure Swift) conforms to the same `VoiceCodec` seam and is the CLI's default already. **What it does not change:** codec2 has not been removed, Currawong's switch to Weebill (APP-27) is on a branch awaiting a library release, and nobody has decided to drop codec2 — this is a live option now, not an outcome. Do not overstate it: the licensing judgement below is deferred exactly as before; only what a future decision would need to weigh has changed. | App Store submission of M17 — and nothing before it |
| **OQ-7** | ✅ **RESOLVED 2026-08-11 — 54 bytes. The LSF CRC is not on the wire; `M17StreamPacket` changed to match.** Settled by `hamvoip-cli oq7` against a live reflector on UDP 17000, packet capture retained (`m17-oq7.pcap`, workspace, unversioned). One over of 52 consecutive stream datagrams, one SID, one transmitting station. Three independent readings of those bytes agree and only on this layout: **length** — 54 bytes, 52 of 52, no exceptions; **sequencing** — the two bytes at offset 34 ran 0, 1, 2 … 51, while at offset 36, where the 56-byte reading puts FN, the same bytes do not count at all and set bit 15 in 35 of 52 frames, which a mid-over last-frame flag must never be; **CRC** — the trailing two bytes are the M17 CRC16 (Part I: polynomial `0x5935`, init `0xFFFF`) over the preceding 52 bytes, valid 52 of 52. That third test is what rules out a truncated 56-byte frame — two bytes lost in transit would not leave a CRC closing over what remains — and it fails 0 of 52 for the LSF-CRC-present reading. Field offsets corroborated too: SID constant, DST/SRC decoding as base-40 callsigns at 6-11 and 12-17, TYPE `0x0005` at 18-19, META all zeros, and 16 bytes of Codec 2 differing in every frame at 36-51. **Scope of the claim:** one reflector, one over, one transmitting client — an observation about what M17-over-IP actually carries, not a correction to the specification, which says 240 bits and is what we implemented first. A second reflector disagreeing would be new information rather than a bug; the tally's guidance says so. **Original question:** the spec's Table 27 gives LICH as 240 bits, the full 30-byte LSF *including* its own CRC → 56 bytes; 54 is widely quoted elsewhere, and the difference is exactly whether that CRC is present. Unresolvable from the document, and LP-2 forbids reading an implementation to find out. | Unblocks **M17-4** stream TX/RX |
| **OQ-8** | ✅ **RESOLVED 2026-08-13 — keep a local copy, outside both repos.** The maintainer's call: M17's documentation situation is not going to improve, the project describes the specification as open, and the archived chapter is the best record there is, so use it rather than waiting for a better one. A copy of the Internet Archive capture now sits at `m17-spec-archive/` in the workspace with its retrieval URL, timestamp and SHA-256 (`d3ffacd2…`) recorded beside it. **Not committed**, and that half is a licence judgement rather than a preference: the page carries no licence statement, so redistributing it in an Apache-2.0 repository would assert a right nobody has checked. Holding a reference copy is a different act from republishing one. The citation chain in the repo is unchanged — `M17ReflectorProtocol.swift` and `docs/reference/PROVENANCE.md` still cite the archive URL; the local copy is the belt to that braces. **Original question:** the chapter we implement against was published as HTML at a readthedocs host that now 404s, so the only record of what we implemented against was a third-party archive that may itself disappear. | Nothing today; the maintenance risk is now hedged |
| ~~OQ-9~~ | ✅ **RESOLVED 2026-08-12 — permitted sources named; Phase 6 unblocks. Maintainer's judgement.** The permitted sources for EchoLink protocol knowledge are: **(a)** RFC 3550 for RTP framing and **(b)** the ETSI/ITU GSM 06.10 specification for the codec, as spec anchors *for the parts they actually cover* — with the standing caveat that RFC 3550 does **not** describe this protocol as implemented (observed RTP version bits are 3, not 2; the proxy framing and the directory protocol on TCP 5200 fall outside it entirely), so where wire and RFC disagree the wire wins and the divergence is recorded; **(c) packet captures of the maintainer's own EchoLink sessions** are the **primary** source, under the same LP-1 fixture rule that governs IAX-9. Candidate **(d)**, prose write-ups, is admitted **only** under a provenance bar materially higher than the captures': because no published specification exists, most such prose derives from the very implementations LP-2 forbids (a summary of thebridge's source is the source at one remove, not "behavioural observation"), so a (d) source may be used only when its own provenance is independently established as *not* derived from forbidden implementations, and its use logged per `docs/reference/PROVENANCE.md` before any code depends on it. When (d) cannot clear that bar, the answer is another capture, not the write-up. **Standing procedural rules that come with this resolution:** (1) protocol ambiguities are settled by designing another on-air experiment and cutting another capture — never by reading an implementation; the pressure to peek is highest exactly where captures are thinnest, which is where the clean-room boundary matters most. (2) Capture work spans **multiple peers**: a single-peer capture already produced two confident wrong conclusions (SSRC always zero; sequence numbers start at zero) that a four-peer capture corrected — see the PROVENANCE.md OQ-9 entry. (3) Directory-server captures (TCP 5200) carry other operators' callsigns, locations and IPs; they get the same third-party-traffic hygiene the M17 OQ-7 capture did (`docs/CLI.md` §8), and no such capture's path is named in a versioned file. **Terms rechecked online 2026-08-12** against echolink.org directly (Access Policies, Validation, Download, Support): no anti-reverse-engineering clause, no client-software restriction, and no software EULA is even linked — the access policies govern *who* may connect (licensed amateurs) and what a Sysop node may interconnect *to*, never what client software reaches the service. echolink.org's own Download page lists compatible third-party implementations (EchoHam, EchoIRLP, svxLink/QTel, an Asterisk channel driver) with "we do not support these programs" — the service operator publicly acknowledges independent clients. This closes the narrow terms caveat left open under OQ-1 and does not disturb OQ-1's reasoning. **This resolves the sourcing question only** — OQ-1b (trademark, nominative use only) still governs all EchoLink naming, and LP-1/LP-2 are unchanged: no implementation source, at any level, is ever read. | ~~Phase 6~~ **unblocked** |
| **OQ-10** | ✅ **RESOLVED 2026-08-17 — implement it. The sourcing objection is answered, and the work is far smaller than this row assumed.** The maintainer's call, on evidence gathered the same day. **What changed:** the objection below was that the only description of WT authentication was a forum thread, which under the OQ-9 candidate-(d) rule cannot be depended on. That remains true of every third-party write-up — an AllStarLink administrator states in community thread 20379 that "Tranceive reversed engineered it as did Repeater-phone", so all of them derive from reverse engineering the service and none can clear the bar. The route out is the one OQ-7 and OQ-9 already established: **settle it by observing our own traffic rather than reading anyone's implementation.** Done 2026-08-17 against `https://allstarlink.org/api/v2/auth-wt-legacy` with the maintainer's own portal account; full probe transcript in `experiment-data/wt-oq10-result.txt`. **The observed contract:** `POST`, `Content-Type: application/json`, body `{"username","password"}` — both keys exact (`callsign`, `user`, `login` are all rejected as key names), unknown extra keys tolerated. The value in `username` is the callsign, because allstarlink.org portal logins *are* callsign/password — so a client holds one credential pair and no second identifier. Success is HTTP 200 `{"status":"OK","auth":1,"token":…}` with a **12-character lowercase-hex token (48 bits)** and no `msg` key. Failure is staged and distinguishable — `Invalid JSON payload` (400, unparseable), `Invalid JSON fields` (400, wrong key names), `login failed` (credentials rejected) — which maps to three typed errors rather than one opaque failure, and which is also what let the key names be discovered without transmitting a real credential. **Why the work is small:** a 48-bit hex secret is near-certainly used directly in the ordinary RFC 5456 MD5 challenge-response, which `IAX2Client` already implements for FR-1.2. On that reading the unbuilt half of FR-1.3 is one HTTPS request and a credential substitution — this row's "new protocol work in the library" premise was wrong. **Two caveats that travel with the decision.** (1) ~~This is observed behaviour, not a specification: one account, one host, one day. It is clean-room and strong enough to code against, but an official answer supersedes it — ASL3-Manual issue #229 ("Fully Document /api/v2/auth-wt-legacy", opened by jxmx 2026-04-15) is still Todo, and a forum question has been drafted.~~ **Retired 2026-08-18 — the official answer arrived and the observed contract was right.** The forum question was asked ([community thread 24925](https://community.allstarlink.org/t/documentation-for-the-web-transceiver-authentication-api-api-v2-auth-wt-legacy/24925), and our observations were also posted to #229) and **N8EI, an AllStarLink administrator, replied with the docblock of `/api/v2/auth-wt-legacy.php` itself**. Every field we had established by observation is confirmed verbatim: `POST`, `{"username","password"}` with both key names exact, `{"status","auth","token","msg"}` back, `msg` present only on error. **Three things are new, none findable by observing a successful login:** an optional **`cookie`** request field echoed back in the response (opaque to us, deliberately not sent — nothing here has a browser session to correlate); **non-`POST` methods return HTTP 405**; and the **token changes only when the operator changes their portal password** — stable as observed, now for a stated reason rather than by luck. **A permitted source, and worth saying why**, since this row spent a day establishing that no third-party write-up could be read: LP-1 excludes *implementations of these protocols*, and this is the operator of a web service documenting that service's request and response format in answer to a direct question. Same class as the call parameters IAX-12 read from our own dialplan — what to present at the door — and the most authoritative form of it, because it comes from whoever runs the door. The reverse-engineered write-ups remain unopened. Logged in `docs/reference/PROVENANCE.md`. (2) The endpoint is named `legacy` and #229 sits under a project called **"WebTransceiver Login API Replacement"** — AllStarLink intends to retire it, so put the token fetch behind a seam and make the successor a substitution rather than a rewrite. **Now stated rather than inferred (2026-08-18), and it cuts the other way too:** the replacement "isn't ready even for beta testing yet" — there is no timeline and no description of what it will be. **So there is nothing to prepare for and no more design to do here.** WT has been in service for years and many clients depend on it; building well against its confirmed current behaviour is the correct target, not hedging against a successor that may never ship or may behave nothing like we would guess. `WebTransceiverTokenSource` already makes the swap a substitution rather than a rewrite, which is the whole of the preparation this deserves. AllStarLink do suggest logging in per app launch or connection in case a successor rotates tokens more often — worth knowing, not worth restructuring a caller that stores one today. **Since observed on air, the same day:** the USERNAME is the literal string `allstar-public`, *not* the callsign — a callsign there draws a bare REJECT with no CAUSE IE and no challenge, while `allstar-public` draws a full MD5 exchange; and the IAX2 secret for that account is the **literal string `allstar`** — read from our own node's `iax2 show users`, and the same on every ASL3 node because it ships that way. **This retracts an earlier reading in this row: the token is _not_ the IAX2 secret.** Presenting the token as the secret gives cause 50 "No authority found"; presenting `allstar` gives cause 3 "No such context/extension" — which means authentication **succeeds** and the call reaches the `allstar-public` dialplan context. A wrong secret and an unauthorised account fail at nearly the same place, which is what made the earlier reading look sound. **SETTLED 2026-08-17, confirmed from the node's own Asterisk console.** The Web Transceiver call is: USERNAME the literal `allstar-public`; secret the static string `allstar` (it ships in every ASL3 `iax.conf`, read via `iax2 show users`); CALLED NUMBER `s`, the Asterisk start extension — WT never dials the node number; the **WT token in CALLING NAME** (`0x04`), which `authwebphone.pl` resolves to the callsign, returning `OHYES<callsign>`; and the **destination node number in CALLING NUMBER** (`0x03`), which becomes `NODENUM` and is passed to `Rpt()`. Ordinary RFC 5456 MD5 challenge-response throughout. Verified by a 45-second session that `Rpt("44309,X")` attached to the node's bridge, and **confirmed against a third-party node**: the same recipe reached 61624 (VK-OzHUB), which has no local knowledge of our callsign and no `iax.conf` entry for us, and our callsign appeared in that node's *published* link list as `TVK1CPM`. So the token authenticates centrally against allstarlink.org rather than a node happening to know us — which is what every earlier result, all taken against our own node, could not distinguish. So the token is the identity proof, and the server's token→callsign resolution is why asserting a callsign in CallerID gets nobody in. **Three bugs in our own code were found on the way, all fixed here:** (i) under `--no-audio` the CLI's task group ended on the first completed child and the media loops complete instantly with no devices, so every signalling-only session was torn down the moment it connected — this was the mysterious "10-second session", the 10 seconds being the node's own `Wait(3)` and announcements before it answers; (ii) the duration task's `try?` swallowed its cancellation and announced `--duration elapsed` on every session end, mislabelling every hangup (same bug in `EchoLinkCommand` and `M17Command`); (iii) Asterisk's *"Peer did not understand our iax command '255'"* is our own RFC-correct UNSUPPORT reply (§6.3.1) to a Control frame with subclass `0xff`, and is benign. **Method note, the expensive part:** client-side success was never a usable oracle — three conclusions were drawn and retracted (token as IAX2 secret; identity enforced by CallerID; token not in CallerID), and the counted trials that appeared to settle two of them were confounded by call-number exhaustion caused by the testing itself. What worked was the node's log, one call at a time. `HAMVOIP_TRACE=1` was added for exactly this and is documented in `docs/CLI.md` §10. **Provenance:** a node we operate supplied the **call parameters** — which extension to dial, which credential to present, which IE carries what. That is usage knowledge, of the same class as an API endpoint and its required fields, and it belongs in `docs/CLI.md` §11 where a reader needs it. It contributed nothing to how anything is *built*: every algorithm here still derives from RFC 5456 and our own captures. Logged in `docs/reference/PROVENANCE.md`; no third-party client was consulted at any point. Full detail in `experiment-data/wt-oq10-result.txt`. **Original question:** implement AllStarLink Web Transceiver mode, or scope FR-1.3 down to the half that shipped? FR-1.3 asks for "registered node mode **and Web Transceiver mode**" and only the first exists; IAX-8b delivered registration and was credited to FR-1.3, so the requirement has read as met while half of it was never started. Surfaced 2026-08-16 by the Currawong discovery survey. | **IAX-12** — fetch the token, connect with it. Completes **FR-1.3**. Nothing is blocked waiting |
| ~~—~~ | ~~Packet capture of own AllStar session~~ **Done 2026-08-09** — `connect3.pcap` (voice, DTMF, mini-frame switch) and `oq5-confirm.pcap` (four registration exchanges), both of the maintainer's own traffic against their own ASL3 node, held at the workspace root. Six `live-*.hex` fixtures were cut from them; `wrap.pcap` followed for the two `0x8000` timestamp boundaries. Provenance in `Tests/FIXTURES.md` | IAX-9 ✅ |
| ~~—~~ | ~~Packet capture of own EchoLink session (directory + proxy especially)~~ **Done 2026-08-12** — three captures (multi-peer), held in `experiment-data/`, SHA-256s in `echolink-oq9-result.txt`. Settled OQ-9's evidence question and the proxy framing / login digest; boundary calls logged in `docs/reference/PROVENANCE.md`. Paths deliberately unnamed in versioned files (one holds a live credential, one the full directory). Further Phase 6 captures still the maintainer's to run | OQ-9 ✅ / Phase 6 |
| ~~—~~ | ~~Capture from a live M17 reflector~~ **Done 2026-08-11** — `hamvoip-cli oq7`, `m17-oq7.pcap`. Settled OQ-7. Passive traffic, so no `live-*.hex` fixture was cut from it; see `docs/CLI.md` §8 on that provenance question, which is still the maintainer's | OQ-7 ✅ |
