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
10. **Shared test helpers live in `Tests/TestSupport/`** (target `TestSupport`,
   depended on by all three test targets, deliberately not a product). Put
   anything more than one test target needs there — `FixtureLoader` is
   already in place; `MockTransport` joins it in RC-1.

## 2. Current state (as of this plan)

- `Package.swift` defines `RadioCore`, `IAX2Kit`, `M17Kit` + two test targets.
- `Sources/RadioCore/` has three stub files: `NetworkClient.swift` (protocol,
  done enough for now), `JitterBuffer.swift` (empty shell), `VoiceCodec.swift`
  (protocol, done enough for now).
- **`swift build` currently FAILS on `main`**: `IAX2Kit`, `M17Kit` and both
  test targets are declared but have no source directories
  (`error: target 'IAX2Kit' referenced in product 'IAX2Kit' is empty`).
  BOOT-1 fixes this and must land before anything else.
- CI: SPDX check + `swift build` + `swift test` on macOS 14 (currently red
  for the same reason).

## 3. Phase map and dependencies

```
Phase 0  Bootstrap        BOOT-1             (blocks everything)
Phase 1  RadioCore        RC-1 … RC-8        (needs BOOT-1)
Phase 2  IAX2Kit          IAX-1 … IAX-9      (needs RC-1..RC-4)
Phase 3  CLI harness      CLI-1              (needs IAX-8)
Phase 4  SwiftUI app      APP-1 … APP-4      (BLOCKED on OQ-3, OQ-4 — human)
Phase 5  BLE PTT          BLE-1 … BLE-3      (needs APP-2)
Phase 6  EchoLink         —                  (BLOCKED on OQ-1 — do not start)
Phase 7  M17Kit           M17-1 … M17-5      (M17-1 blocked on OQ-2 spike result)
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

### RC-1 — `DatagramTransport` abstraction + mock
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

### RC-2 — G.711 µ-law codec
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

### RC-3 — Jitter buffer, fixed depth
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

### RC-4 — Jitter buffer, adaptive depth (AU-3)
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

### RC-5 — Transmit watchdog (SF-1)
**Depends on:** nothing.
**Files:** `Sources/RadioCore/TransmitWatchdog.swift` + tests.

`actor TransmitWatchdog`: `start(timeout: Duration, onExpiry: @Sendable () async -> Void)`,
`cancel()`. Default timeout 180 s. Inject the clock
(`any Clock<Duration>`) so tests drive expiry without waiting.

**Done when:** tests prove expiry fires exactly once, cancel prevents it,
and restart resets the deadline.

### RC-6 — Received-audio leveller (AU-4)
**Depends on:** nothing.
**Files:** `Sources/RadioCore/AudioLeveller.swift` + tests.

`struct AudioLeveller`: `mutating func process(_ pcm: inout [Int16])`.
Slow AGC toward a target RMS (default −18 dBFS), attack ≈ 50 ms, release
≈ 500 ms, hard gain ceiling +18 dB, never amplifies frames below a noise
floor (default −55 dBFS RMS). Pure DSP on buffers — no AVFoundation.

**Done when:** tests: a −30 dBFS sine converges near target within 2 s of
synthetic frames; a −60 dBFS noise frame is not boosted; a 0 dBFS input is
attenuated without wrap-around clipping artifacts (output clamped).

### RC-7 — Audio pipeline (AU-1, AU-2)
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

Read RFC 5456 §8 (frame formats), §6 (state machines), §8.6 (IEs) before
each task. Constants below must be re-checked against the RFC (rule 6).

### IAX-1 — Frame model: parse + serialize
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

### IAX-2 — Information elements
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

### IAX-3 — Sequence/retransmission engine
**Depends on:** IAX-1.
**Files:** `Sources/IAX2Kit/ReliableChannel.swift` + tests.

Actor owning OSeqno/ISeqno bookkeeping per RFC 5456 §7: full frames (except
ACK, INVAL, and mini frames) increment OSeqno and require acknowledgement;
retransmit with backoff (initial 500 ms, ×2, max 4 attempts, then declare
the call dead); inbound full frames update ISeqno and trigger ACK where the
RFC requires it. Inject the clock. Transport is `DatagramTransport`.

**Done when:** tests with MockTransport + manual clock cover: ACK stops
retransmission; missing ACK retransmits with R bit set and correct backoff;
exhausted retries surface an error; inbound frame ordering updates ISeqno
correctly.

### IAX-4 — MD5 challenge authentication
**Depends on:** IAX-2.
**Files:** `Sources/IAX2Kit/IAX2Auth.swift` + tests.

AUTHREQ → AUTHREP flow (§6.2, §8.6.15): MD5_RESULT =
hex(md5(challenge + password)). Use `Insecure.MD5` from CryptoKit (import
`Crypto` no — CryptoKit is Apple-only and fine here; guard with
`#if canImport(CryptoKit)`). Pure function:
`md5Response(challenge: String, secret: String) -> String`.

**Done when:** test vectors computed by hand (e.g. via `md5` CLI, noted in
a comment) pass; empty challenge/secret handled.

### IAX-5 — Call state machine
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

### IAX-6 — Voice path
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

### IAX-7 — DTMF (FR-1.5)
**Depends on:** IAX-5.

`send(dtmf: Character)` on the call actor: full frame, type DTMF, subclass =
ASCII digit (verify §8.3 for begin/end semantics — implement what the RFC
requires, RFC-level only). Validate character set `0-9*#A-D`.

**Done when:** encoded frames match hand-built fixtures; invalid characters
throw.

### IAX-8 — `IAX2Client`: public API
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

**Done when:** end-to-end test: scripted fixture session connects,
transmits 1 s of synthetic tone (asserting emitted datagram shapes),
receives fixture voice datagrams and yields decoded PCM; watchdog expiry
forces stopTransmit. **This is Milestone M1.**

### IAX-9 — Capture-replay conformance test
**Depends on:** IAX-8. **Blocked on human:** requires a packet capture of
the maintainer's own AllStar session (LP-1). Ask the maintainer to run
`tcpdump -w allstar.pcap udp port 4569` during a short QSO and convert to
hex fixtures. Then: replay server-side datagrams through MockTransport and
assert the client's responses are protocol-valid (parseable, correct call
numbers, sequence numbers, ACK discipline).

---

## Phase 3 — CLI harness

### CLI-1 — `hamvoip-cli` (macOS)
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

## Phase 4 — SwiftUI app ⛔ partially blocked

**Human decisions needed first:** OQ-3 (app name / bundle id) and OQ-4
(separate repo — recommended and assumed here). Do not start APP tasks
until the maintainer answers; then create the app repo with **xcodegen**
(`project.yml`, no checked-in `.xcodeproj`) per the repo's Apple
development procedures.

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

## Phase 6 — EchoLink ⛔ BLOCKED (OQ-1)

Do not write EchoLink code, capture EchoLink traffic, or design its API
until the maintainer confirms Synergenics' terms permit third-party
clients. When unblocked, this phase gets its own task breakdown (directory
TCP 5200, RTP/GSM UDP 5198/5199, proxy transport default-on-cellular per
FR-3.3, vendored BSD-licensed `libgsm` per LP-4).

## Phase 7 — M17Kit

### M17-1 — Codec2 XCFramework spike ⛔ gate (OQ-2)
Build script (`scripts/build-codec2-xcframework.sh`) compiling codec2
(LGPL-2.1, from drowe67/codec2 — building it is fine; it is not a protocol
implementation) as a **dynamic** XCFramework for iOS device, iOS simulator,
macOS arm64, with licence text bundled (LP-4). Deliverable: script + a
written result on whether all three slices link. **A human confirms the
gate before M17-3 proceeds.**

### M17-2 — Base-40 callsign codec (FR-2.3)
**Depends on:** nothing — pure function, can run any time.
Per M17 spec "Address Encoding": charset index 1…39 =
`A–Z`, `0–9`, `-`, `/`, `.` (verify exact order in spec); value =
Σ char_i × 40^i from the rightmost character; 48-bit big-endian field;
`0xFFFFFFFFFFFF` = broadcast. Encode + decode + validation, exhaustive
round-trip tests including 9-char max and rejection of invalid characters.

### M17-3 — Reflector control (FR-2.1)
**Depends on:** M17-2, RC-1. UDP 17000. Packets are magic-prefixed:
`CONN` (+ encoded callsign + module letter), `ACKN`, `NACK`, `PING`/`PONG`,
`DISC` — verify layouts against the M17 spec's reflector section. Actor
FSM: connect → linked (keepalive PONG↔PING) → disconnected; NACK surfaces
an error. Fixture-driven tests as in IAX-5.

### M17-4 — Stream mode RX/TX (FR-2.2)
**Depends on:** M17-3, M17-1 gate. `M17 ` stream frames: LICH/LSF fields
(dst, src, type, meta — **type bits for encryption are never set; if a
received stream is flagged encrypted, mark it unplayable, per FR-2.5**),
16-bit frame number with end-of-stream flag, 2×Codec2-3200 frames
(16 bytes payload per packet). Wrap codec2 via a thin C shim target.

### M17-5 — `M17Client` public API
**Depends on:** M17-4. Mirrors IAX-8: conforms to `NetworkClient`,
composes jitter buffer + Codec2 + watchdog + leveller; fixture-driven
end-to-end test; then a CLI-1 subcommand (`hamvoip-cli m17 …`) for live
human validation.

---

## Open questions owned by the maintainer (not agents)

| ID | Question | Blocks |
|---|---|---|
| OQ-1 | EchoLink ToS permit third-party clients? | Phase 6 |
| OQ-2 | Codec2 XCFramework builds all three slices? | M17-3+ (spike M17-1 informs it) |
| OQ-3 | App name + bundle id | Phase 4 |
| OQ-4 | App in separate repo? (plan assumes yes) | Phase 4 |
| — | Packet capture of own AllStar session | IAX-9 |
