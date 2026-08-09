# swift-hamvoip — Draft Design Requirements

**Status:** Draft v0.1
**Scope:** Swift protocol libraries for unencumbered amateur radio VoIP modes, and a
SwiftUI client built on them. Library and app ship as separate repositories.

---

## 1. Purpose

Provide amateur radio operators on Apple platforms with a native client for
internet-linked voice modes, and provide the wider community with permissively
licensed Swift implementations of the underlying protocols.

Existing clients on Apple platforms are either single-mode, unmaintained, or
GPL-licensed in ways that prevent App Store distribution. No permissively
licensed Swift implementation of IAX2 or M17 exists at all.

## 2. Scope and non-goals

### In scope

| Mode | Transport | Codec | Encumbrance |
|---|---|---|---|
| AllStarLink | IAX2 (RFC 5456), UDP 4569 | G.711 µ-law | None |
| M17 | Reflector protocol, UDP 17000 | Codec2 3200 | None |
| EchoLink | RTP UDP 5198/5199, TCP 5200, proxy TCP | GSM 06.10 | Trademark / ToS — see OQ-1 |

### Explicit non-goals

- **NG-1.** DMR, System Fusion (YSF), D-STAR, P25 and NXDN are out of scope.
  All require AMBE or AMBE+2, which is patent-encumbered. This is a permanent
  exclusion, not a deferral.
- **NG-2.** No MMDVM or USB hardware modem support. iOS cannot host USB serial
  devices without MFi, and the modes requiring it are excluded by NG-1 anyway.
- **NG-3.** No MFi accessory protocol support. Requires Apple MFi programme
  membership and per-vendor cooperation.
- **NG-4.** No RF layer. M17's 4FSK modulation, FEC and interleaving are not
  implemented; only the IP/reflector side is in scope.

## 3. Licensing and code provenance

These are hard requirements, not guidance. Violating them is expensive to unwind
after distribution has begun.

- **LP-1.** All protocol implementations in this repository MUST be clean-room.
  Permitted sources: published specifications (RFC 5456, the M17 specification,
  the EchoLink proxy protocol document), and packet captures of the author's own
  sessions.
- **LP-2.** GPL-licensed implementations (DroidStar, SvxLink/EchoLib, thebridge,
  iaxclient) MUST NOT be consulted at source level by anyone contributing code.
  They may be referenced for behavioural observation only.
- **LP-3.** This repository is licensed Apache-2.0. Chosen over MIT for the
  express patent grant in §3, which has real value in a domain where adjacent
  protocols are patent-encumbered.
- **LP-4.** Third-party C dependencies MUST be permissively licensed or linked
  dynamically. `libgsm` is BSD-style (may be vendored). Codec2 is LGPL-2.1 and
  MUST be shipped as a dynamic XCFramework with licence text included.
- **LP-5.** Every source file carries an SPDX identifier. CI enforces this.

## 4. Functional requirements

### 4.1 AllStarLink / IAX2 — priority 1

- **FR-1.1.** Implement the IAX2 client subset: NEW, ACCEPT, ANSWER, VOICE,
  ACK, PING/PONG, LAGRQ/LAGRP, HANGUP, plus mini-frames for audio.
- **FR-1.2.** Support IAX Direct — connection to a specific node using
  credentials issued by that node's operator.
- **FR-1.3.** Support registered node mode and Web Transceiver mode.
- **FR-1.4.** G.711 µ-law encode/decode. No other codec required for v1.
- **FR-1.5.** DTMF transmission for node control commands.

### 4.2 M17 — priority 3

- **FR-2.1.** Implement reflector control: CONN, ACKN, NACK, PING, PONG, DISC,
  and module selection.
- **FR-2.2.** Stream mode only for v1; packet mode deferred.
- **FR-2.3.** Base-40 callsign encoding into the 48-bit address field.
- **FR-2.4.** Codec2 3200 bps encode/decode via dynamic framework.
- **FR-2.5.** Encryption features in the M17 specification MUST NOT be exposed
  in the UI. Encryption is not permitted in the amateur service in most
  jurisdictions including Australia.

### 4.3 EchoLink — priority 2, gated on OQ-1

- **FR-3.1.** Directory login and station list over TCP 5200.
- **FR-3.2.** Audio as GSM 06.10 in RTP on UDP 5198; station info and
  signalling on UDP 5199.
- **FR-3.3.** Proxy transport MUST be implemented and MUST be the default on
  cellular. Behind CGNAT the device cannot accept inbound UDP, so direct mode
  is unusable on mobile data.
- **FR-3.4.** Credentials are the operator's own validated EchoLink account.
  The app performs no validation of its own.

## 5. Audio pipeline

- **AU-1.** `AVAudioEngine` with `AVAudioConverter` for 48 kHz ↔ 8 kHz.
- **AU-2.** `AVAudioSession` category `.playAndRecord`, mode `.voiceChat`.
- **AU-3.** Adaptive jitter buffer, target depth 60–200 ms, adjusting to
  measured arrival variance.
- **AU-4.** Automatic received-audio levelling across modes; different networks
  arrive at markedly different levels.
- **AU-5.** The jitter buffer and codec layer MUST be testable without a
  network connection, driven from recorded frame sequences.

## 6. PTT and hardware control

- **PT-1.** On-screen momentary PTT is the baseline and MUST always work.
- **PT-2.** BLE GATT accessory support via CoreBluetooth with the
  `bluetooth-central` background mode. Provides true press/release edges and
  survives backgrounding.
- **PT-3.** A **learn mode** MUST be provided: connect to an accessory,
  subscribe to all notifying characteristics, record which characteristic and
  payload correspond to press and release. This removes the need for a
  maintained device whitelist.
- **PT-4.** `MPRemoteCommandCenter` fallback for HID and headset buttons.
  This yields toggle behaviour, not momentary — acknowledged and acceptable.
- **PT-5.** `GCKeyboard` MUST NOT be relied upon; it is foreground-only.
- **PT-6.** Volume-button interception MUST NOT be used. It fails App Store
  review and conflicts with system volume.

## 7. Safety

- **SF-1.** Hard transmit watchdog. Transmission terminates automatically after
  a configurable timeout, default 180 seconds.
- **SF-2.** Transmission MUST drop immediately if the BLE accessory link is
  lost mid-transmission.
- **SF-3.** Transmission MUST drop on audio session interruption (incoming
  call, route change).
- **SF-4.** Transmit state MUST be visible without unlocking the device.

A stuck open microphone into a reflector or repeater is the dominant on-air
failure mode for software clients. These requirements are not negotiable.

## 8. Platform and distribution

- **PD-1.** Networking via `Network.framework` (`NWConnection`), not BSD
  sockets. Required for IPv6/NAT64 and cellular handoff behaviour.
- **PD-2.** Background modes: `audio`, `bluetooth-central`. Neither requires
  Apple approval.
- **PD-3.** `com.apple.developer.networking.multicast` is NOT required for
  reflector modes. If local hotspot discovery is ever added, the request must
  begin early — Apple approval takes weeks.
- **PD-4.** CallKit MUST NOT be used. Wrong semantics, and regionally
  restricted.
- **PD-5.** Distribution: TestFlight for iOS, Developer ID plus notarisation
  for macOS. App Store submission deferred until the protocol layer is stable.
- **PD-6.** TestFlight builds expire at 90 days; a quarterly rebuild cadence is
  assumed.

## 9. Open questions

- **OQ-1.** Do Synergenics' current terms permit third-party EchoLink clients?
  This gates all of §4.3 and must be resolved before reverse-engineering effort
  is invested.
- **OQ-2.** Codec2 as a dynamic XCFramework — confirm the build works for
  iOS device, iOS simulator and macOS arm64 slices before committing to M17.
- **OQ-3.** Application name and bundle identifier. Library naming is settled
  (plain, descriptive, ecosystem-conventional); the app name is still open and
  should not derive from any existing product's branding.
- **OQ-4.** Whether the SwiftUI app lives in a second repository (recommended)
  or as an additional target here.

## 10. Delivery sequence

1. `RadioCore` — transport, codec protocol, jitter buffer, audio graph.
2. `IAX2Kit` — validates the whole pipeline against a mode with no codec
   dependency. µ-law is trivial, so any audio fault found here is a pipeline
   fault, not a codec fault.
3. Minimal SwiftUI shell — on-screen PTT only.
4. BLE PTT with learn mode.
5. EchoLink, subject to OQ-1.
6. `M17Kit`.

The ordering is deliberate. Building M17 first would mean debugging Codec2 and
the jitter buffer simultaneously.
