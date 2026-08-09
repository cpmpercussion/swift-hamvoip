# swift-hamvoip

Permissively licensed Swift implementations of unencumbered amateur radio VoIP
protocols. Apple platforms are the primary target; the protocol code itself is
portable Swift with the transport behind an adapter.

## Why

Every existing cross-platform client for these modes is GPL-licensed, which
prevents App Store distribution. There is no permissively licensed Swift
implementation of IAX2, and none of M17 in any form.

swift-hamvoip covers only modes with no patent encumbrance:

- **AllStarLink** — IAX2 (RFC 5456), G.711 µ-law
- **M17** — reflector protocol, Codec2 3200
- **EchoLink** — RTP/GSM 06.10 *(planned, see OQ-9)*

DMR, System Fusion, D-STAR, P25 and NXDN are permanently out of scope. All
require AMBE or AMBE+2, which is patented.

## Status

**v0.1 — the IAX2 stack is complete and tested, and has never been on the air.**

Both halves of that sentence matter. There are 520 tests and the AllStarLink
path is implemented end to end: frames, information elements, sequencing and
retransmission, MD5 authentication, the call state machine, voice, DTMF,
registration, and a client that composes them. All of it is driven from
recorded fixtures and a mock transport, exactly as AU-5 requires.

The **registration and authentication paths have now been run against a real
node** — an ASL3 node in a VM, on 2026-08-09 — which settled the one thing
that had been an **unverified assumption**. RFC 5456 §8.6.15 does not state
how `MD5_RESULT` is textually encoded, and the clean-room policy forbids
reading an implementation to find out, so the library shipped lowercase
32-character hex on the strength of an argument rather than an observation.
`hamvoip-cli oq5` asked the node, and the answer was hexadecimal: nothing
changed, and the assumption is now a measurement. See
[`docs/CLI.md`](docs/CLI.md) §4 for the evidence and its limits.

The **call and voice paths have still not been validated against a real
node** — no audio has crossed a real link, and the M2 sign-off checklist in
[`docs/CLI.md`](docs/CLI.md) §5 is untouched.

| Module | State |
|---|---|
| `RadioCore` | Complete. Transport abstraction, µ-law, adaptive jitter buffer, transmit watchdog, audio pipeline, received-audio leveller, real-time-safe capture. |
| `IAX2Kit` | Complete, unvalidated on air. See above. |
| `M17Kit` | **Partial.** Reflector control and base-40 callsigns only. There is no audio path: stream mode is blocked on OQ-7, and no `M17Client` exists yet. |

EchoLink is not implemented and is not scheduled — see OQ-9 in
[`docs/DEVELOPMENT-PLAN.md`](docs/DEVELOPMENT-PLAN.md).

This is a 0.x release. The API will change.

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

`hamvoip-cli` is a macOS harness for validating the stack against a real node
before any GUI is involved — connect, monitor levels, key up, send DTMF, and
settle OQ-5, which it has now done. See [`docs/CLI.md`](docs/CLI.md).

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

## Documentation

- [`docs/DESIGN-REQUIREMENTS.md`](docs/DESIGN-REQUIREMENTS.md) — what is being
  built and why, including the licensing rules and the explicit non-goals.
- [`docs/DEVELOPMENT-PLAN.md`](docs/DEVELOPMENT-PLAN.md) — the task list and
  the open questions, including the ones that need a decision rather than code.
- [`docs/CLI.md`](docs/CLI.md) — the command-line harness.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — clean-room attestation and PR rules.

## Licence

Apache-2.0. Chosen over MIT for its express patent grant.
