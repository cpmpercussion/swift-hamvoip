# swift-hamvoip

Permissively licensed Swift implementations of unencumbered amateur radio VoIP
protocols. Apple platforms are the primary target; the protocol code itself is
portable Swift with the transport behind an adapter.

## Why

Every existing cross-platform client for these modes is GPL-licensed, which
prevents App Store distribution. There is no permissively licensed Swift
implementation of IAX2, and none of M17 in any form.

swift-hamvoip covers only modes with no patent encumbrance. DMR, System Fusion,
D-STAR, P25 and NXDN are permanently out of scope: all require AMBE or AMBE+2,
which is patented.

## Status

**v0.1.** 537 tests, green on `main`. This is a 0.x release — the API will
change.

| Module | State |
|---|---|
| `RadioCore` | Complete. Transport abstraction, G.711 µ-law, adaptive jitter buffer, transmit watchdog, received-audio leveller, `AVAudioEngine` pipeline with 48 kHz ↔ 8 kHz conversion and a real-time-safe capture path. |
| `IAX2Kit` | Complete. AllStarLink over IAX2 (RFC 5456): frames and mini-frames, information elements, sequencing and retransmission, MD5 authentication, call state machine, voice, DTMF, registration, and `IAX2Client` composing them. |
| `M17Kit` | **Partial.** Reflector control, base-40 callsigns, stream-packet parse and serialise. No codec wiring, no audio path, no `M17Client`. |
| `hamvoip-cli` | macOS harness: connect, level metering, keying, DTMF. |

`IAX2Kit` has been validated against a real node — an ASL3 node (Asterisk +
app_rpt) in a VM, on 2026-08-09. Registration, authentication and a full
two-way audio session all ran on the wire; that is milestone M2, and the
result table is in [`docs/CLI.md`](docs/CLI.md) §5. Six fixtures cut from those
captures are replayed by `IAX2ConformanceTests`, so registration, call setup,
an inbound over and both 16-bit time-stamp boundaries are pinned against what
a real node actually sent rather than only against our reading of the RFC.
Everything else in the suite runs on hand-built fixtures and a mock transport.

M17 has been validated against nothing. It has never been run against a
reflector.

## What is not here yet

- **M17 audio.** Stream mode and `M17Client` (M17-4, M17-5) are blocked on
  OQ-7 — whether the IP stream frame is 56 bytes or 54, which cannot be
  settled from the specification and needs a capture from a live reflector.
- **Transmit pacing.** Each over opens by sending the buffered capture frames
  as fast as the socket accepts them instead of pacing at 20 ms. One node
  answered with `VNAK`; the retransmission engine recovered and audio was
  intelligible throughout. Tracked as IAX-10.
- **Two on-air checks worth re-running before v1**: PTT edge timing, which a
  full-duplex `Echo()` target cannot show, and the `Ctrl-C` / `kill` teardown
  paths.
- **EchoLink**, which is not implemented and not scheduled. The service's
  terms are not the obstacle; the absence of any published protocol
  specification is, and the clean-room policy rules out the implementations
  that document it (OQ-9).
- **Codec2 under LGPL-2.1 for App Store distribution** is an open licensing
  question (OQ-6), and it gates shipping M17 in a signed iOS app rather than
  the code here.

The open questions are tracked in
[`docs/DEVELOPMENT-PLAN.md`](docs/DEVELOPMENT-PLAN.md).

## Requirements

Swift 5.9 or later; iOS 16 or later; macOS 13 or later.

## Installation

```swift
.package(url: "https://github.com/cpmpercussion/swift-hamvoip.git", from: "0.1.0")
```

Then depend on the products you need:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "IAX2Kit", package: "swift-hamvoip"),
    .product(name: "RadioCore", package: "swift-hamvoip"),
])
```

## Quick start

`IAX2Client` is an actor. It owns the socket, the timers and the jitter buffer;
you give it a destination and PCM, and read audio and events back as streams.
Both streams are `nonisolated`, so reading them does not hop onto the actor.

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
_ = try await client.send(pcm: capturedFrame)   // 8 kHz mono Int16
await client.stopTransmit()

try await client.send(dtmfSequence: "*3")
await client.disconnect()
```

Every timer in the stack is driven by an injected `Clock`, so a test can run a
whole session with no real-time waits:

```swift
let client = IAX2Client(clock: manualClock, transportFactory: { _ in mock })
```

## The command-line harness

`hamvoip-cli` is a macOS harness for exercising the stack against a real node
without a GUI — connect, monitor levels, key up, send DTMF. See
[`docs/CLI.md`](docs/CLI.md).

```sh
swift run hamvoip-cli --help
```

## Safety

A stuck open microphone into a repeater is the failure mode this library is
built to avoid. `IAX2Client` enforces a hard transmit watchdog (SF-1, 180 s by
default) and stops transmitting when it fires. Anything embedding this library
is responsible for the rest: dropping transmit on audio interruption and route
change, and on loss of whatever keyed it.

The M17 specification's encryption features are deliberately not implemented.
Encryption is not permitted in the amateur service in most jurisdictions,
including Australia. Encrypted streams are surfaced only as unplayable.

## Clean-room policy

All protocol code here is written from published specifications and from packet
captures of our own sessions. Contributors must not consult GPL-licensed
implementations (DroidStar, SvxLink/EchoLib, thebridge, iaxclient) at source
level. See §3 of the requirements document. Pull requests that cannot attest to
this will not be merged.

Test fixtures follow the same rule; where they come from and what may not go
into one is recorded in [`Tests/FIXTURES.md`](Tests/FIXTURES.md).

## Documentation

- [`docs/DESIGN-REQUIREMENTS.md`](docs/DESIGN-REQUIREMENTS.md) — what is being
  built and why, including the licensing rules and the explicit non-goals.
- [`docs/DEVELOPMENT-PLAN.md`](docs/DEVELOPMENT-PLAN.md) — the task list and
  the open questions, including the ones that need a decision rather than code.
- [`docs/CLI.md`](docs/CLI.md) — the command-line harness.
- [`Tests/FIXTURES.md`](Tests/FIXTURES.md) — fixture provenance rules.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — clean-room attestation and PR rules.

## Licence

Apache-2.0. Chosen over MIT for its express patent grant.
