# swift-hamvoip — Development Plan

**Status:** v1.0 — derived from `DESIGN-REQUIREMENTS.md` (Draft v0.1)
**Audience:** implementation agents executing one task at a time.

This document decomposes the requirements into small, ordered, independently
verifiable tasks. Design decisions have already been made here; do not
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
   CallKit (PD-4), no volume-button PTT (PT-6), no AMBE modes ever (NG-1).
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
11. **Shared test helpers live in `Tests/TestSupport/`** (target `TestSupport`,
   depended on by all three test targets, deliberately not a product). Put
   anything more than one test target needs there — `FixtureLoader` is
   already in place; `MockTransport` joins it in RC-1.

## 2. Current state

**Updated 2026-08-09, at v0.1.** Everything below is checked against the tree,
not remembered; if it disagrees with the repository, the repository is right.

- `Package.swift` defines three library products — `RadioCore`, `IAX2Kit`,
  `M17Kit` — plus the `hamvoip-cli` executable, a test-only `TestSupport`
  target and four test targets. One dependency, `swift-argument-parser`,
  authorised by CLI-1.
- `swift build` and `swift test` are green on `main`: **537 tests, no
  failures.** CI runs the SPDX check on Ubuntu and build + test on macOS 14.
- `RadioCore` and `IAX2Kit` are complete. `M17Kit` has reflector control,
  base-40 callsigns and stream-packet parse/serialise, but **no codec wiring
  and no `M17Client`** — M17-4 and M17-5 are the remaining work there.
- **`IAX2Kit` has been validated against a real node** (ASL3 in a VM,
  2026-08-09): registration, authentication — which settled OQ-5 — and then a
  full two-way audio session. **Milestone M2 has passed** (`docs/CLI.md` §5):
  speech intelligible both ways, DTMF round-tripped, the SF-1 watchdog cut
  transmission at exactly its limit, teardown clean. Two items want a re-run
  before v1 (PTT edges, the signal teardown paths) and one wart is tracked as
  IAX-10. **IAX-9 is done:** those sessions are now six `live-*.hex` fixtures
  replayed by `IAX2ConformanceTests`, so registration, call setup, an inbound
  over and both `0x8000` time-stamp boundaries are regression-tested against
  what a real node put on the wire, not only against our reading of the RFC.

Per-task status is on the task headings themselves — `✅ DONE` where the work
has merged and the code it describes exists.

## 3. Phase map and dependencies

```
Phase 0  Bootstrap        BOOT-1             (blocks everything)
Phase 1  RadioCore        RC-1 … RC-8        (needs BOOT-1)
Phase 2  IAX2Kit          IAX-1 … IAX-9      (needs RC-1..RC-4)
Phase 3  CLI harness      CLI-1              (needs IAX-8)
Phase 4  SwiftUI app      APP-1 … APP-4      (unblocked: OQ-3/3b/4 resolved)
Phase 5  BLE PTT          BLE-1 … BLE-3      (needs APP-2)
Phase 6  EchoLink         —                  (BLOCKED on OQ-9 — do not start;
                                              OQ-1 terms gate is cleared)
Phase 7  M17Kit           M17-1 … M17-5      (M17-1 ✅ done, OQ-2 resolved)
```

Within a phase, tasks are ordered; a task lists its hard dependencies. Tasks
with no unmet dependency may proceed in parallel on separate branches.

**Milestone M1** (end of Phase 2): a full transmit/receive audio path runs
against `MockTransport` from recorded IAX2 fixtures — no radio required.
**Milestone M2** (end of Phase 3): a human completes a live QSO with an
AllStar node using the CLI harness on macOS.

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

### IAX-8b — Registration, registered node mode (FR-1.3) ✅ DONE
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
OQ-5 resolved *to* lowercase hex, so registered node mode (FR-1.3) works as
shipped and this is now a symmetry/hygiene item rather than a defect. Thread
`md5ResultEncoding` through `IAX2Registrar.Configuration` in the same shape
when convenient. See `docs/CLI.md`.

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

### IAX-10 — Pace transmitted frames instead of bursting them ⚠️ NEW
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

## Phase 4 — Currawong, the SwiftUI app ✅ UNBLOCKED

**The app is called Currawong** — a bird with a distinctive, far-carrying
call, locally notable in VK1. Trademark checked clear in class 9.

- **Repository:** a separate `currawong` repo (OQ-4), depending on
  `swift-hamvoip` via SPM. **This repo stays library-only.**
- **Bundle identifier:** `au.charlesmartin.currawong`. Extensions extend it
  (`au.charlesmartin.currawong.liveactivity`). Keychain access group
  `$(TeamID).au.charlesmartin.currawong`.
- **Project generation:** **xcodegen** (`project.yml`), no checked-in
  `.xcodeproj`, per the repo's Apple development procedures.
- The app talks to `IAX2Client` **only through the `NetworkClient`
  protocol** — it must know nothing about IAX2, M17 or EchoLink specifics.
  If the app needs a protocol-specific type, that is a signal `NetworkClient`
  is missing something; fix it there rather than leaking the detail upward.

- **APP-1** — xcodegen scaffold: iOS 16+ app depending on swift-hamvoip via
  SPM; background modes `audio` + `bluetooth-central` (PD-2); CI via
  `xcodebuild test -destination 'platform=iOS Simulator,…'` from the CLI.
- **APP-2** — Connect screen + on-screen momentary PTT (PT-1): press-and-hold
  button → `startTransmit`/`stopTransmit`; TX state banner; interruption
  handling — `AVAudioSession.interruptionNotification` and route change
  force `stopTransmit` (SF-3). ViewModel logic unit-tested against a fake
  `NetworkClient`.
- **APP-3** — TX visibility without unlock (SF-4): Live Activity showing
  TX/RX state, plus `MPRemoteCommandCenter` toggle-PTT fallback (PT-4).
- **APP-4** — Settings: node list CRUD, watchdog timeout, stored in
  `UserDefaults`; secrets in Keychain.

## Phase 5 — BLE PTT (after APP-2)

- **BLE-1** — `BLEPTTManager` (CoreBluetooth, `bluetooth-central`
  background mode): scan, connect, auto-reconnect; connection loss while
  transmitting forces `stopTransmit` (SF-2). Wrap CoreBluetooth behind a
  protocol so the state logic is unit-testable with a fake central.
- **BLE-2** — **Learn mode (PT-3):** subscribe to all notifying
  characteristics of a chosen accessory; record which
  (service, characteristic, payload) pairs fire on press vs release; persist
  as a mapping. No device whitelist anywhere.
- **BLE-3** — Runtime: apply learned mapping → press/release edges drive
  PTT; UI indicator for accessory link state.

## Phase 6 — EchoLink ⛔ BLOCKED (OQ-9)

**The terms-of-service gate is cleared (OQ-1, resolved 2026-08-09).** The
remaining block is a clean-room sourcing problem, and it is a harder one:
EchoLink has no published protocol specification, and LP-2 forbids exactly the
implementations that document it. Do not write EchoLink code or design its API
until the maintainer settles OQ-9 — where the protocol knowledge comes from.

Two things an agent must not do here, even though the phase is closer than it
was. **Do not read SvxLink, EchoLib, thebridge, MicroLink or any other EchoLink
implementation**, including any linked from the discussion that resolved OQ-1;
those citations are evidence about the service's posture, not permitted
sources (LP-1, LP-2). **Do not use "EchoLink" as a product name** — nominative,
descriptive use only, per OQ-1b.

Capturing the maintainer's *own* EchoLink traffic is a legitimate fixture source
under LP-1 and is candidate (c) in OQ-9, but it is the maintainer's action to
run, not an agent's.

When unblocked, this phase gets its own task breakdown (directory TCP 5200,
RTP/GSM UDP 5198/5199, proxy transport default-on-cellular per FR-3.3,
vendored BSD-licensed `libgsm` per LP-4).

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

### M17-4 — Stream mode RX/TX (FR-2.2)
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

✅ **OQ-7 is settled — 54 bytes, resolved 2026-08-11 against a live reflector**;
see the open questions table for the evidence. The frame size is no longer an
assumption, so stream TX may be built on it.

Two things M17-4 inherits from that:

- **The single CRC is the whole-datagram one, and nothing verifies it yet.**
  `M17StreamPacket.crc` is carried through verbatim. The polynomial is
  confirmed against the capture: M17 CRC16, polynomial `0x5935`, initial value
  `0xFFFF`, computed over the preceding 52 bytes, valid in 52 of 52 observed
  frames. M17-4 owns implementing and verifying it. There is no LSF CRC to
  verify — it is not transmitted.
- **`hamvoip-cli oq7` stays useful** as a re-check against a second reflector,
  and it still measures below the parser: `RecordingTransport` taps the
  `DatagramTransport` seam rather than `M17ReflectorClient.events`, because the
  client correctly discards anything that is not exactly
  `M17StreamPacket.byteCount` bytes. That is what let the experiment contradict
  the code running it, and it is why a reflector sending some third length
  would be reported rather than look like silence.

### M17-5 — `M17Client` public API
**Depends on:** M17-4. Mirrors IAX-8: conforms to `NetworkClient`,
composes jitter buffer + Codec2 + watchdog + leveller; fixture-driven
end-to-end test; then a CLI-1 subcommand (`hamvoip-cli m17 …`) for live
human validation.

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
| **OQ-6** | **LGPL-2.1 relinking vs App Store code signing.** Shipping Codec2 as a dynamic framework satisfies LP-4's letter, but a signed iOS app cannot have its framework substituted by the user, which is what LGPL §6 relinking is for. A licensing judgement, not a technical blocker, and unchanged by the M17-1 spike — but it wants a conscious decision before App Store submission, not after. | App Store submission of M17 |
| **OQ-7** | ✅ **RESOLVED 2026-08-11 — 54 bytes. The LSF CRC is not on the wire; `M17StreamPacket` changed to match.** Settled by `hamvoip-cli oq7` against a live reflector on UDP 17000, packet capture retained (`m17-oq7.pcap`, workspace, unversioned). One over of 52 consecutive stream datagrams, one SID, one transmitting station. Three independent readings of those bytes agree and only on this layout: **length** — 54 bytes, 52 of 52, no exceptions; **sequencing** — the two bytes at offset 34 ran 0, 1, 2 … 51, while at offset 36, where the 56-byte reading puts FN, the same bytes do not count at all and set bit 15 in 35 of 52 frames, which a mid-over last-frame flag must never be; **CRC** — the trailing two bytes are the M17 CRC16 (Part I: polynomial `0x5935`, init `0xFFFF`) over the preceding 52 bytes, valid 52 of 52. That third test is what rules out a truncated 56-byte frame — two bytes lost in transit would not leave a CRC closing over what remains — and it fails 0 of 52 for the LSF-CRC-present reading. Field offsets corroborated too: SID constant, DST/SRC decoding as base-40 callsigns at 6-11 and 12-17, TYPE `0x0005` at 18-19, META all zeros, and 16 bytes of Codec 2 differing in every frame at 36-51. **Scope of the claim:** one reflector, one over, one transmitting client — an observation about what M17-over-IP actually carries, not a correction to the specification, which says 240 bits and is what we implemented first. A second reflector disagreeing would be new information rather than a bug; the tally's guidance says so. **Original question:** the spec's Table 27 gives LICH as 240 bits, the full 30-byte LSF *including* its own CRC → 56 bytes; 54 is widely quoted elsewhere, and the difference is exactly whether that CRC is present. Unresolvable from the document, and LP-2 forbids reading an implementation to find out. | Unblocks **M17-4** stream TX/RX |
| **OQ-8** | **The M17 reflector specification is offline.** The chapter we implement against was published as HTML at a readthedocs host that now 404s; M17-3 worked from an Internet Archive capture. Should the repository keep a local copy of that archived chapter, licence permitting? Right now the only record of what we implemented against is a third-party archive that may itself disappear. | Nothing today; a maintenance risk |
| **OQ-9** | ⛔ **Where does EchoLink protocol knowledge legitimately come from? This, not the terms, is what blocks Phase 6.** IAX2 has RFC 5456; M17 had a published spec (offline, but it existed — OQ-8). EchoLink has **no published protocol specification at all**, and LP-2 names SvxLink/EchoLib and thebridge — the projects that do document it, in code — as forbidden sources. Resolving OQ-1 therefore *moved* the block here rather than removing it, and the citations that support OQ-1 are precisely the sources an agent must not read. Candidate legitimate sources, for the maintainer to confirm before any Phase 6 task opens: (a) RFC 3550 for RTP framing; (b) the ETSI/ITU GSM 06.10 specification for the codec; (c) **packet captures of the maintainer's own EchoLink sessions**, under the same LP-1 fixture rule that governs IAX-9; (d) prose protocol write-ups that are documentation rather than source code, with provenance recorded per `docs/reference/PROVENANCE.md`. The directory protocol on TCP 5200 and the proxy transport are the parts least likely to fall out of (a)–(b) and most likely to need (c). | **Phase 6 — all of it** |
| — | Packet capture of own AllStar session | IAX-9 |
| — | Packet capture of own EchoLink session (directory + proxy especially) | OQ-9 / Phase 6 |
| ~~—~~ | ~~Capture from a live M17 reflector~~ **Done 2026-08-11** — `hamvoip-cli oq7`, `m17-oq7.pcap`. Settled OQ-7. Passive traffic, so no `live-*.hex` fixture was cut from it; see `docs/CLI.md` §7 on that provenance question, which is still the maintainer's | OQ-7 ✅ |
