# swift-hamvoip

Permissively licensed Swift implementations of unencumbered amateur radio VoIP
protocols. Apple platforms are the primary target; the protocol code itself is
portable Swift with the transport behind an adapter.

## Why

Every existing cross-platform client for these modes is GPL-licensed, which
prevents App Store distribution. There is no permissively licensed Swift
implementation of IAX2 or EchoLink, and none of M17 in any form.

swift-hamvoip covers only modes with no patent encumbrance. DMR, System Fusion,
D-STAR, P25 and NXDN are permanently out of scope: all require AMBE or AMBE+2,
which is patented.

## Status

**v0.4.0.** 945 tests, green on `main` — a few more with the Codec2 framework
present, and one that skips unless it is given a station-list download. This is
a 0.x release — the API will change.

| Module | State |
|---|---|
| `RadioCore` | Complete. Transport abstractions for datagram and stream, G.711 µ-law, adaptive jitter buffer, transmit watchdog, received-audio leveller, `AVAudioEngine` pipeline with 48 kHz ↔ 8 kHz conversion and a real-time-safe capture path, and the `NetworkClient` seam an app is written against — state, events, received audio and a transmit path, with no protocol type in sight. |
| `IAX2Kit` | Complete. AllStarLink over IAX2 (RFC 5456): frames and mini-frames, information elements, sequencing and retransmission, MD5 authentication, call state machine, voice, DTMF, registration, and `IAX2Client` composing them. |
| `M17Kit` | **Code complete; transmit unconfirmed on air.** Reflector control, base-40 callsigns, stream mode both ways, Codec2 3200 (FR-2.4), and `M17Client`. Receive has been confirmed against a live reflector; transmit has not — see below. |
| `EchoLinkKit` | Complete. Proxy transport, directory login, RTP/RTCP audio, GSM 06.10 over a vendored C target, the station directory, public proxy discovery, and `EchoLinkClient`. Proxied routes only — see below. |
| `hamvoip-cli` | macOS harness: `connect` (IAX2), `echolink`, `m17`, and the `oq5` / `oq7` experiment subcommands. |

**What has been proven on the air, and what has not.** This distinction is kept
carefully, because a green test suite says nothing about a radio:

- **IAX2 — proven both ways.** An ASL3 node (Asterisk + app_rpt) in a VM, on
  2026-08-09: registration, authentication and a full two-way audio session on
  the wire. That is Milestone M2; the result table is in
  [`docs/CLI.md`](docs/CLI.md) §6. A second, different node corroborated the
  `connect` path the next day.
- **EchoLink — proven both ways.** A two-way QSO through `*ECHOTEST*` via a
  public proxy on 2026-08-13, from `hamvoip-cli echolink`, with clean teardown
  — Milestone M3, sign-off table in [`docs/CLI.md`](docs/CLI.md) §9. The
  station directory was confirmed the same day against a live directory
  server, and EchoLink has since run from the iOS app as well, including a
  link to a UHF repeater heard live off-air.
- **M17 receive — proven.** A net on M17-434 listened to at length on
  2026-08-16: intelligible audio throughout, transmitting stations' callsigns
  displayed. That exercises Codec2 decode, the jitter buffer, stream receive
  and the base-40 reading, against traffic nobody here generated. An earlier
  receive run on 2026-08-11 settled the stream frame size (OQ-7).
- **M17 transmit — sent, not confirmed.** Transmissions to M17-432 and other
  reflectors have been accepted, but **no operator has yet reported hearing
  them**. The encoder, the LSF fields and the SID remain unvalidated at the far
  end. Treat "it transmitted" and "it was readable" as different claims.

Fixtures cut from those sessions are replayed by the conformance tests, so
registration, call setup, an inbound over, both 16-bit time-stamp boundaries
and the EchoLink proxy framing and login are pinned against what a real peer
actually sent rather than only against our reading of a specification.
Everything else in the suite runs on hand-built fixtures and a mock transport;
no test opens a socket.

## What is not here yet

- **Confirmation that M17 transmit is readable** — see above. The cheapest
  route is a parrot rather than a second operator, which is task M17-6.
- **Direct (non-proxied) EchoLink.** `Route.direct` exists in the type so that
  adding it later is not a breaking change, and it throws. No capture of a
  direct session exists, and building the port assignment and socket setup from
  the plausible reading is what the clean-room policy forbids. The proxy is
  required on cellular anyway (FR-3.3), so nothing on mobile data is blocked.
- **Transmit pacing.** Each over opens by sending the buffered capture frames
  as fast as the socket accepts them instead of pacing at 20 ms. One node
  answered with `VNAK`; the retransmission engine recovered and audio was
  intelligible throughout. Tracked as IAX-10.
- **A readable error when a node answers from another address.** A node with
  two interfaces may answer from an address other than the one dialled, which
  the connected UDP socket in `NWDatagramTransport` cannot accept; it surfaces
  as `Socket is not connected`, which points at the socket rather than at the
  node's routing. Observed on a live LAN node. Decided and unimplemented;
  IAX-11.
- **Audio-session policy without an engine.** Reaching it currently means
  owning an `AVAudioEngine`, which callers must not build first. RC-11.
- **Two on-air checks worth re-running before v1**: PTT edge timing, which a
  full-duplex `Echo()` target cannot show, and the `Ctrl-C` / `kill` teardown
  paths.
- **AllStarLink Web Transceiver** — the half of FR-1.3 that was never built, and
  a question about sourcing before it is (OQ-10).
- **Codec2 under LGPL-2.1 for App Store distribution** is an open licensing
  question (OQ-6), deliberately deferred until submission is actually in view.
  It gates shipping M17 in a signed iOS app rather than the code here.

The open questions are tracked in
[`docs/DEVELOPMENT-PLAN.md`](docs/DEVELOPMENT-PLAN.md).

## Requirements

Swift 5.9 or later; iOS 16 or later; macOS 13 or later.

## Installation

```swift
.package(url: "https://github.com/cpmpercussion/swift-hamvoip.git", from: "0.4.0")
```

Then depend on the products you need:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "IAX2Kit", package: "swift-hamvoip"),
    .product(name: "EchoLinkKit", package: "swift-hamvoip"),
    .product(name: "RadioCore", package: "swift-hamvoip"),
])
```

`M17Kit` additionally wants a `Codec2.xcframework`, which is not committed —
the manifest probes for it and builds the codec conformance only when it is
present, so a bare checkout builds and tests without it. Run
`scripts/build-codec2-xcframework.sh`, then `swift package reset`, because
SwiftPM caches the evaluated manifest against its contents rather than against
the filesystem the probe reads. Everything except the codec conformance itself
is tested either way.

## Quick start

`IAX2Client` is an actor. It owns the socket, the timers and the jitter buffer;
you give it a destination and PCM, and read audio and events back as streams.
Both streams are `nonisolated`, so reading them does not hop onto the actor.
`EchoLinkClient` and `M17Client` have the same shape.

```swift
import IAX2Kit

let client = IAX2Client()

let destination = IAX2Destination(
    host: "node.example.org", port: 4569,
    callsign: "VK1XYZ", username: "vk1xyz",
    secret: secretFromKeychain, node: "12345")

Task {
    for await event in client.events {
        print(event)          // connected, disconnected, media rejected, …
    }
}

Task {
    for await frame in client.receivedAudio {
        play(frame)           // [Int16], 8 kHz mono
    }
}

try await client.connect(to: destination)

try await client.startTransmit()
try await client.send(pcm: capturedFrame)       // 8 kHz mono Int16
await client.stopTransmit()

try await client.send(dtmfSequence: "*3")
await client.disconnect()
```

A session is single-use: `disconnect()` is terminal and idempotent, it finishes
both streams, and reconnecting means building a new client. A session that ends
*remotely* reports `disconnected` and leaves the streams open, so an app can
tell the operator why the link dropped.

To write against the modes rather than against one of them, use
`RadioCore.NetworkClient` — `state`, the four verbs, `radioEvents`,
`receivedAudio` and `send(pcm:)`, with every mode's event vocabulary translated
onto one `RadioEvent`. `send(pcm:)` returns `Void` because the protocol may not
hand out an `IAX2VoiceFrame` or an `M17StreamPacket`; the frame-returning
version is `transmit(pcm:)` on the concrete clients, for callers that need to
know what reached the wire.

Every timer in the stack is driven by an injected `Clock`, so a test can run a
whole session with no real-time waits:

```swift
let client = IAX2Client(clock: manualClock, transportFactory: { _ in mock })
```

## The command-line harness

`hamvoip-cli` is a macOS harness for exercising the stack against a real node
without a GUI — connect, monitor levels, key up, send DTMF. `connect` is the
IAX2 path, `echolink` the EchoLink one (`--auto-proxy` finds and probes a public
proxy rather than making you read echolink.org's list, and `--list` dumps the
station directory without needing a node), `m17` links a reflector, and `oq5` / `oq7`
are the two on-air experiments that settled the digest encoding and the M17
frame size. See [`docs/CLI.md`](docs/CLI.md).

```sh
swift run hamvoip-cli --help
```

## Safety

A stuck open microphone into a repeater is the failure mode this library is
built to avoid. Every client enforces a hard transmit watchdog (SF-1, 180 s by
default) and stops transmitting when it fires. Anything embedding this library
is responsible for the rest: dropping transmit on audio interruption and route
change, and on loss of whatever keyed it.

The M17 specification's encryption features are deliberately not implemented.
Encryption is not permitted in the amateur service in most jurisdictions,
including Australia. Encrypted streams are surfaced only as unplayable.

## Clean-room policy

All protocol code here is written from published specifications — RFC 5456, the
M17 specification, ITU-T G.711, RFC 3550, GSM 06.10 — and from packet captures
of our own sessions. Contributors must not consult GPL-licensed implementations
(DroidStar, SvxLink/EchoLib, thebridge, iaxclient, Asterisk) at source level.
See §3 of the requirements document. Pull requests that cannot attest to this
will not be merged.

EchoLink has no published specification at all, so captures are the primary
source there and ambiguities are settled by cutting another one, never by
reading an implementation. Where the wire and a specification disagree the wire
wins — the observed RTP version bits are 3, not 2 — and each such divergence is
recorded in [`docs/reference/PROVENANCE.md`](docs/reference/PROVENANCE.md).

Test fixtures follow the same rule; where they come from and what may not go
into one is recorded in [`Tests/FIXTURES.md`](Tests/FIXTURES.md).

## Documentation

- [`docs/DESIGN-REQUIREMENTS.md`](docs/DESIGN-REQUIREMENTS.md) — what is being
  built and why, including the licensing rules and the explicit non-goals.
- [`docs/DEVELOPMENT-PLAN.md`](docs/DEVELOPMENT-PLAN.md) — the task list and
  the open questions, including the ones that need a decision rather than code.
- [`docs/CLI.md`](docs/CLI.md) — the command-line harness, and the on-air
  sign-off tables for M2 and M3.
- [`docs/reference/PROVENANCE.md`](docs/reference/PROVENANCE.md) — where each
  protocol fact came from, and every place the wire disagrees with a document.
- [`Tests/FIXTURES.md`](Tests/FIXTURES.md) — fixture provenance rules.
- [`CHANGELOG.md`](CHANGELOG.md) — releases, including the breaking changes.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — clean-room attestation and PR rules.

## Licence

Apache-2.0. Chosen over MIT for its express patent grant.
