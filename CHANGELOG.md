<!-- SPDX-License-Identifier: Apache-2.0 -->
# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html) — while the
major version is 0, the API may change in any release.

## [Unreleased]

### Added

- **`hamvoip-cli echolink` reads its proxy from the config directory (EL-15).**
  `ECHOLINK_PROXY`, `ECHOLINK_PROXY_PORT` and `ECHOLINK_PROXY_PASSWORD` join
  `CALLSIGN` and `ECHOLINK_PASSWORD` under the existing convention — a file
  named for the environment variable it stands in for, resolved command line →
  environment → file → default. With a private proxy configured, `--proxy` and
  its companions become optional. Prompted by a config directory found holding
  the password alone: nothing read it, because `--proxy-password` was the one
  credential in the CLI that bypassed the resolution chain, so it looked
  configured and did nothing.

### Changed

- **The Web Transceiver login contract is confirmed by AllStarLink, not just
  observed by us.** An AllStarLink administrator answered the maintainer's
  question in [community thread
  24925](https://community.allstarlink.org/t/documentation-for-the-web-transceiver-authentication-api-api-v2-auth-wt-legacy/24925)
  with the docblock of `/api/v2/auth-wt-legacy.php` itself, and every field
  `AllStarLinkPortalTokenFetcher` sends and reads is confirmed verbatim. Three
  additions to `docs/CLI.md` §11.1: an optional `cookie` request field echoed
  back in the response (deliberately not sent — nothing here has a browser
  session to correlate), non-`POST` methods return HTTP 405, and the token
  changes only when the operator changes their portal password. Documentation
  only; no code changed. This retires OQ-10 caveat 1, which asked for exactly
  this answer. Caveat 2 is now stated rather than inferred, and settles rather
  than opens a question: the replacement API "isn't ready even for beta testing
  yet", with no timeline and no description of what it will be, so the confirmed
  behaviour of `auth-wt-legacy` is what to build against and
  `WebTransceiverTokenSource` is all the preparation a successor of unknown shape
  can be given. Recorded in `docs/reference/PROVENANCE.md`, including why an answer from the
  service's own operator is a permitted source where a reverse-engineered
  third-party write-up is not.
- **A configured proxy password is only ever sent to its own proxy (EL-15).**
  Dial any other host, or `--auto-proxy`, and it falls back to `PUBLIC` with a
  note on stderr. The proxy login hashes the password into a digest, so a
  stranger's proxy handed a private one gets material to attack offline while we
  gain nothing — a public proxy accepts `PUBLIC` regardless. `--proxy-password`
  other than `PUBLIC` is now **refused** with `--auto-proxy`.
- `--proxy-port` and `--proxy-password` became optional rather than defaulted,
  so "not given" is distinguishable from "given the default". No change for
  anyone passing them: the defaults are still 8100 and `PUBLIC`.
- A malformed `ECHOLINK_PROXY_PORT` is an error rather than a silent fall back
  to 8100.

### Removed — **breaking**

- **`HAMVOIP_SECRET` is now `IAX2_SECRET` (CLI-3), with no fallback.** The old
  environment variable and the old `~/.config/swift-hamvoip/HAMVOIP_SECRET` file
  are no longer read at all. **If you have either, rename it**; otherwise
  `hamvoip-cli iax2` will silently stop finding your secret and start prompting
  (or, with no terminal, place the call unauthenticated).

  ```sh
  mv ~/.config/swift-hamvoip/HAMVOIP_SECRET ~/.config/swift-hamvoip/IAX2_SECRET
  ```

  The name dated from when the CLI had one protocol in it. `echolink` and `m17`
  are equally "hamvoip", so `HAMVOIP_SECRET` said which *project* the file
  belonged to rather than which credential it held — `docs/CLI.md` had to gloss
  it as "the IAX2 node secret" wherever it appeared. Credentials are now named
  for the subcommand that uses them, which is what `ECHOLINK_PASSWORD` and
  `ECHOLINK_PROXY*` already did. Nothing else changes: same precedence
  (`--secret` → environment → config file → prompt), same `--secret` flag, same
  behaviour once found. Currawong is unaffected — it stores its secret in the
  Keychain and never reads this variable.

## [0.5.2] — 2026-08-17

One task, cut as its own release because an app is waiting on it: Currawong's
settings screen (APP-12) has "log in to the portal, get a token" written and
tested behind a seam, and cannot switch it on until a released tag carries the
fetch. No behaviour changes anywhere else — every existing client, destination
and CLI command sends exactly what it sent in `v0.5.1`.

### Added

- **Web Transceiver token fetch (IAX-13).** `WebTransceiverTokenSource` in
  `IAX2Kit`, with `AllStarLinkPortalTokenFetcher` as the one implementation
  against allstarlink.org's `auth-wt-legacy` endpoint: callsign and portal
  password in, a `WebTransceiverToken` out. The three observed failures
  (`login failed`, `Invalid JSON payload`, `Invalid JSON fields`) are separate
  error cases, because retyping a password fixes exactly one of them. It is a
  seam rather than a function because the endpoint is named `legacy` and
  AllStarLink has a replacement project open (OQ-10, caveat 2) — the successor
  should be a second conformance. `WebTransceiverToken.description` is
  redacted: the token resolves to the operator's callsign on any WT-enabled
  node, so it is a credential and must not fall into a log. The endpoint is
  substitutable so the successor can be pointed at — and for that reason it must
  be `https://`: the fetcher refuses anything else before sending, since the
  request carries a portal password.
- **`hamvoip-cli wt-token`** — the first half of `docs/CLI.md` §11 without
  `curl` and a hand-built JSON body. Prints only the token, so
  `TOKEN="$(hamvoip-cli wt-token --callsign VK1CPM)"` composes; takes the
  password from `$ALLSTARLINK_PORTAL_PASSWORD` or a no-echo prompt, on the
  same reasoning as `--secret`.

## [0.5.1] — 2026-08-17

### Changed

- **The CLI is protocol-first: one command per mode.** `connect` is renamed
  `iax2`, alongside `echolink` and `m17` — the top level now names the three
  protocols rather than mixing one verb, two modes and two experiment probes.
  `connect` remains a working alias, so scripts and the session records in
  `docs/CLI.md` stay valid. The probes moved under an `experiment` group
  (`hamvoip-cli experiment oq5` / `oq7`): both questions they settle are
  settled, but a settled answer is a claim about the peers measured so far,
  and `oq7` in particular is the plan's named tool for re-checking the frame
  size against a second reflector. `--version` now reports the package
  version instead of a CLI-1-era `0.1.0`.
- **The README caught up with v0.5.0**: M17 marked proven both ways with its
  scope caveat, the third-party-node Web Transceiver evidence added to the
  IAX2 row, the stale pre-v1 checklist and module table refreshed, and the
  CLI section rewritten for the protocol-first names.

## [0.5.0] — 2026-08-17

Two things earn this release its number: **Web Transceiver** (IAX-12), which
Currawong needs by version to build APP-11, and **a safety fix** — a
reentrancy race that could key the transmitter with the SF-1 watchdog
disarmed, found by a pre-release review and fixed in all three clients. It is
also the first release in which **every mode has both directions confirmed on
air**: M17 transmit, the last unproven claim, was heard readable on M17-434 B
through an independent client on 2026-08-17.

### Added

- **Web Transceiver: the half of FR-1.3 that was never built** (IAX-12, closing
  OQ-10). An operator with an allstarlink.org portal account but no node of
  their own can now reach any node whose owner has enabled it, with no entry in
  anyone's `iax.conf`. `IAX2Destination` gains `callingNumber` (CALLING NUMBER,
  §8.6.3) and `callingName` (CALLING NAME, §8.6.4), surfaced as
  `--calling-number` and `--calling-name`; both default to the previous
  behaviour, so IAX Direct and registered node mode send exactly what they
  always sent. `--calling-name` is sent verbatim, because `--callsign` is
  upper-cased and character-checked and would corrupt a lowercase-hex token.
  The recipe — which extension to dial, which credential to present, and which
  IE carries what — is documented in `docs/CLI.md` §11, along with how to verify
  a connection from a node's *published* link list rather than trusting the
  client. Established by observation against a node we operate and confirmed
  against one we do not.
- **`HAMVOIP_TRACE=1`** writes one line per received full frame, and the reason
  any call leg terminated, to stderr. `docs/CLI.md` §10. It exists because three
  separate client-side signals were misleading at once while IAX-12 was being
  worked out, and tracing what actually arrived is what separated them.

- **`TransmitWatchdog.start` now returns a generation token, and
  `cancel(ifCurrent:)` disarms only the deadline that token armed.** A caller
  that suspends between arming the watchdog and deciding whether to keep it —
  which is what every client's `startTransmit` does — can now clean up after
  itself without tearing down a deadline a concurrent competitor has since
  armed. The unconditional `cancel()` is unchanged and still always wins.
- **`transmitCancelled` on all three client error enums.** Thrown by
  `startTransmit` when a `stopTransmit` (or a competing `startTransmit`)
  superseded it mid-arm — see the SF-1 fix below. Throwing rather than
  returning is deliberate: a silent return is indistinguishable from success
  to the caller, and SF-1 cannot tolerate a caller who believes they are
  keyed when they are not (or the reverse).

### Fixed

- **SF-1 could be bypassed by releasing PTT while key-up was still arming the
  watchdog.** `startTransmit` suspends arming the watchdog before it commits
  `.transmitting`, and an actor is reentrant across an `await` — so a
  `stopTransmit` landing in that gap cancelled the watchdog, concluded from
  `state` that nothing was transmitting, and returned; `startTransmit` then
  resumed and keyed up anyway. Audio flowed, the operator believed they were
  unkeyed, and the watchdog was disarmed — the unbounded open mic SF-1 exists
  to prevent, produced by the exact reentrancy pattern plan rule 10 warns
  about, in the one path it matters most. The same shape existed in all three
  clients and is fixed in all three, with plan-rule-10's dedicated
  generation-counter mechanism and tests that deliver the competing call from
  *inside* the suspension (the plan's own prescription — the sequential
  orderings the existing tests covered can never catch this). A concurrent
  double key-up (screen PTT and a BLE accessory together) is covered too,
  via the watchdog's new token cancel: exactly one call commits, the other
  throws `transmitCancelled`, and the winner's deadline stays armed.
- **`--no-audio` sessions ended the instant they connected.** The session's task
  group ended on the first completed child, and the media loops complete
  immediately when there are no audio devices — so `--duration` never applied,
  and a node-side hangup could never be observed. Signalling-only sessions now
  run for as long as they are asked to. *Amended before release:* the first
  fix reached only `connect`; the review for this release found `m17` and
  `echolink` still had the bug, and they now share `connect`'s gated
  task-group shape — including degrading to receive-only when audio capture
  fails, rather than ending the session.
- **`EchoLinkClient.connect` could report success on a torn-down session.**
  The frame pump delivers directory data on a forked task, so the pump could
  reach end-of-stream — releasing the session and emitting `.disconnected` —
  while the directory login it was mid-way through still returned `OK`.
  `connect` then emitted `.connected` *after* `.disconnected` and wedged the
  client until `disconnect()`. It now re-checks the session phase in the same
  synchronous region that commits it, the pattern `M17Client.connect` already
  had.
- **An EchoLink proxy `OPEN` timeout wedged the proxy state machine.** The
  deadline failed the waiting continuation but left `state == .opening`, so
  every retry threw `invalidTransition` instead of trying again. The timeout
  now restores `.loggedIn` — logged in, no channel open, which is what is
  actually true — and a `STATUS` arriving late for the timed-out attempt is
  forwarded harmlessly instead of touching state.
- **Every session end was reported as `--duration elapsed`.** The duration task
  used `try? await Task.sleep(...)`, which swallows the cancellation raised when
  another task ends the session, and then announced the timer regardless. A
  remote hangup no longer claims to be a timer expiry. The same bug was present
  in `connect`, `echolink` and `m17`.

### Changed

- **A rejected call no longer blames the secret, or points at OQ-5.** The hint
  said a REJECT "usually means the username or the secret is wrong" and
  suggested running `hamvoip-cli oq5` to test MD5 encodings. Both were
  misleading, and IAX-12 spent hours being misled by exactly this. A REJECT
  carrying **no CAUSE** says nothing about the secret, because a node that
  refuses the NEW outright never asks for one — now confirmed by capture: three
  datagrams, NEW / REJECT / ACK, no AUTHREQ. The hint now says so, points at
  `HAMVOIP_TRACE=1` to check for an AUTHREQ, and names the usual cause: a
  username the node does not know. **Cause 50** gets its own hint, because it
  is the authority check failing after successful authentication — a different
  failure wanting a different fix, where changing the secret cannot help.
- **`connect --help` documents Web Transceiver and `HAMVOIP_TRACE`.** Neither
  was discoverable from the CLI: an operator with only a portal account had no
  way to learn the mode existed, and the five call parameters are not
  guessable. The top-level overview now says `connect` reaches a node three
  ways rather than implying one.

- **The M17 warnings are narrower, because half of what they warned about has
  happened.** `hamvoip-cli m17`'s banner, its help text and the top-level
  subcommand list said M17 had never been run against a real reflector and its
  audio had never been listened to. Both are now false: a net on **M17-434**
  was listened to at length on **2026-08-16**, intelligible throughout, with
  transmitting stations' callsigns displayed — through Currawong, on this
  library. What remains true is the transmit half, and only that: transmissions
  to **M17-432** and others were accepted, and **no operator has confirmed
  hearing one**, so the encoder, the LSF fields and the SID are still unproven
  at the far end. The banner now says exactly that instead of overstating it.
- **The EchoLink subcommand no longer says it has never spoken to a proxy.**
  That stopped being true when Milestone M3 passed on 2026-08-13, and it has
  since run from the app as well.
- **The README caught up with three releases.** It described `M17Kit` as
  partial with no codec, no audio path and no `M17Client`, said M17 audio was
  blocked on OQ-7, and listed EchoLink as unimplemented and unscheduled — all
  true at v0.1 and none of it true since v0.3.0. It now carries a module table
  for what is actually here, and separates what has been proven on the air from
  what has only passed tests.

No behaviour changed: this corrects claims, not conduct.

## [0.4.0] — 2026-08-13

One feature, cut as its own release so Currawong can pin it: **an operator no
longer has to read a web page before using EchoLink.**

The app is the reason this is a release rather than a CLI convenience. FR-3.3
makes the proxy the default on cellular, so every EchoLink session Currawong
opens needs a proxy host — and up to now the only way to get one was for a human
to open echolink.org, read a table of 932 rows, and type one in. The library half
of `--auto-proxy` (`EchoLinkProxySelector` and friends) is what the app's
composition root will call instead.

### Added

- **EL-12: public proxy discovery.** `hamvoip-cli echolink --auto-proxy` finds a
  proxy instead of making the operator read echolink.org's list by hand: it
  fetches the XML that `proxyFind.jsp` serves, probes the nearest few candidates
  by reading their 8-byte greeting, and uses the quickest that answers. On the
  first live run a Sydney proxy 465 km away and listed `Ready` did not answer
  and a Chilean one did — which is the whole argument for probing rather than
  believing the list, since a public proxy carries one client at a time and the
  status is only a poll snapshot.

  New in `EchoLinkKit`, and usable from an app as well as the CLI:
  `EchoLinkProxySelector`, `EchoLinkProxyProbe`, `EchoLinkProxyListParser`,
  `EchoLinkPublicProxy`, and `EchoLinkPublicProxySource` — the fetch seam that
  keeps HTTP out of the unit tests, as `StreamTransport` keeps sockets out
  (AU-5). It sits below `NetworkClient` rather than on it: what it produces is
  the host and port for an `EchoLinkDestination.Route.proxy`.

### Changed

- `hamvoip-cli echolink --proxy` is no longer required on its own — either it or
  `--auto-proxy` must be given, and passing both is an error. Existing command
  lines that name a proxy are unaffected.

## [0.3.0] — 2026-08-13

EchoLink. `EchoLinkKit` goes from nothing to a complete client — proxy
transport, directory login, RTP, GSM 06.10 and a station list — and unlike the
M17 path at 0.2.0, **it has been used for a live QSO**. Phase 6 is complete and
nothing in it is unproven on air.

Also **`NetworkClient` becomes a seam an application can actually be written
against** (RC-10). It gains an event stream, received audio and a transmit seam,
which is what Phase 4 needs before it can show an operator why a link dropped.
That carries **one breaking rename** — see "Changed".

### Milestone

- **M3 passed on 2026-08-13 — a human held a two-way EchoLink QSO through this
  stack.** Through `*ECHOTEST*` via a public proxy, from `hamvoip-cli echolink`,
  audio intelligible in both directions and teardown clean. Two checklist rows
  are left unticked rather than assumed: the talkspurt boundary (chased and
  fixed under EL-7, but "the QSO sounded good" is not that measurement) and the
  SF-1 watchdog, because no over ran to three minutes. Sign-off table in
  `docs/CLI.md`.
- **The station list ran against a live directory server** the same day, in
  `.directoryOnly` mode with no node session: 6386 stations plus 3 notices
  against a declared 6389, and a count mismatch is a hard error here, so a list
  that prints at all is one that arrived whole. This was the last thing in
  Phase 6 resting on a single capture.

### Added

**`EchoLinkKit`** — EchoLink (EL-1 … EL-11, FR-3.1 … FR-3.4).

- `ProxyFrame` — the 9-byte proxy header and its codec, including the
  fragmentation the tunnel imposes: a TCP read may carry part of a frame, or
  several, so the decoder accumulates rather than assuming datagram boundaries.
- `EchoLinkProxyClient`, `EchoLinkAuth` — proxy login on TCP 8100. The 8-byte
  ASCII hex nonce and `MD5("PUBLIC" || nonce)` were recovered offline from two
  captures and then confirmed against a third, unrelated proxy in Chile that
  this code had never met.
- `EchoLinkDirectory` — directory login on TCP 5200 (FR-3.1). Three lines, and
  the middle one matters: **the `ONLINE` line is what registers the station as
  available.** Authentication is not registration — without it the server takes
  the password, answers `OK`, and never lists the station, so no node will
  accept a connection and every step reports success while nothing works. The
  field separator is `0xAC 0xAC`, not `0x0A 0x0A`; the server accepts either,
  which is why the wrong guess survived four failed sessions.
- `EchoLinkRTP`, `EchoLinkRTCP`, `EchoLinkStreamAudio` — audio on UDP 5198 and
  signalling on 5199 (FR-3.2), with SDES for the opening handshake and a
  synthesised playout clock (see "Changed" and "Known limitations").
- `GSMVoiceCodec` — GSM 06.10 as a `RadioCore.VoiceCodec` (EL-8), over a
  vendored `CGSM` C target rather than a dependency (LP-4). 80 ms per packet,
  four 20 ms slots.
- `EchoLinkClient` — an actor conforming to `NetworkClient`, composing the
  proxy link, codec, jitter buffer, watchdog (SF-1) and leveller (AU-4). Like
  `M17Client` it is written against `VoiceCodec` and never names GSM.
  `connect(to:mode:)` adds `.directoryOnly` — proxy login, directory login,
  stop — so a directory query cannot fail because a node was unreachable.
- `EchoLinkStationList`, `EchoLinkStationListReader` — the directory listing.
  **The record's second line has fixed geometry, bracket at column 27**;
  splitting on the first `[` is the obvious implementation and it is wrong for
  3496 of 6441 entries, because locations beginning `[Svx] 145.6625` or
  containing `[0/20]` are ordinary. The list is not UTF-8 (a location carries
  `0xA0`), so it decodes as ISO-8859-1, which cannot fail.

**`RadioCore`** — the mode-agnostic client seam (RC-10).

- `RadioEvent`, `RadioDisconnectReason`, `RadioAudioIssue` — one coarse
  vocabulary every mode translates onto: connection lifecycle, transmit
  transitions, watchdog expiry (SF-1), DTMF, remote station activity, station
  info, and audio that arrived but cannot be played. Cases carry `String?`
  details rather than mode-specific types, so adding a mode does not change the
  enum's shape.
- `NetworkClient` gains `radioEvents`, `receivedAudio` and `send(pcm:)`, and a
  documented single-session lifecycle contract: `disconnect()` is terminal and
  idempotent, it finishes both streams, and reconnecting means building a new
  client. A session that ends *remotely* reports `disconnected` and leaves the
  streams open, so the app can hear about it.
- Each client keeps its own detailed `events` stream and yields the translated
  event from inside its single `emit`, so the two streams cannot disagree about
  what happened or in what order. `IAX2ClientEvent` translates totally;
  `EchoLinkClientEvent` deliberately drops `directoryLoggedIn` and
  `nodeAnswered`, which happen inside a `connect(to:)` that has not returned yet.
- `EchoLinkDisconnectReason` replaces a `String` reason on
  `EchoLinkClientEvent.disconnected`, so the mapping can tell a local hang-up
  from a node saying goodbye without matching on prose. The rendered text is
  unchanged.

**`RadioCore`** — EchoLink's transport needs.

- `StreamTransport`, the TCP seam (EL-3), with `NWStreamTransport` over
  `Network.framework` (PD-1) and `MockStreamTransport` in `TestSupport`. EchoLink
  needs TCP for the proxy and the directory; `DatagramTransport` remains the UDP
  seam and neither test target opens a socket (AU-5).

**`hamvoip-cli`**

- `echolink` subcommand — the live harness M3 was signed off with. `--list`
  dumps the station list and needs neither `--peer` nor `--node`;
  `--jitter-ms` sets the playout target for one run.
- Per-operator defaults in `~/.config/swift-hamvoip/`, so a callsign, location
  and proxy need not be retyped.

**Tests and tooling**

- EchoLink proxy fixtures cut from captures of the maintainer's own sessions —
  framing, login, audio and RTCP — replayed through `MockStreamTransport`.
  `scripts/pcap-to-fixture.py` learned to read TCP streams (EL-1).
- Captures holding a live account password are cited by SHA-256 rather than by
  path, and live outside both repos. `Tests/FIXTURES.md` records the rule; it
  is what the three `echolink-oq9*` captures established.

### Changed

- ⚠️ **Breaking: the frame-returning `send(pcm:)` is now `transmit(pcm:)`** on
  `IAX2Client`, `M17Client` and `EchoLinkClient`. `send(pcm:)` still exists and
  still transmits, but returns `Void` and is the `NetworkClient` requirement.
  A Swift witness may not return a value its requirement does not — and the
  requirement must not, since an `IAX2VoiceFrame` or `M17StreamPacket` is exactly
  the protocol detail the seam exists to keep out of an application. Anything
  that needs to know what reached the wire (`hamvoip-cli` counts frames that did)
  calls `transmit(pcm:)`; anything that just wants the audio sent keeps calling
  `send(pcm:)` and can now do it through the protocol.
- **The playout path, three faults deep.** All three were things `IAX2Kit` and
  `M17Kit` already did correctly, and all three were invisible to a
  fixture-driven test that only asks whether the right bytes came out.
  1. The loop was `tick(); sleep(interval)`, so 20 ms frames left every 22–25 ms
     into a device consuming them every 20 ms. It now sleeps to an absolute
     deadline and re-anchors when it falls too far behind.
  2. A concealed or starved tick yielded nothing, leaving a hole the device
     underran on. Every tick now yields exactly one frame — a faded repeat for
     up to three frames, then zeros.
  3. `JitterBuffer`'s 60 ms default target is smaller than EchoLink's 80 ms
     packet, so it drained to empty between packets.
- **The stream clock takes arrival time, not sequence alone.** EchoLink's RTP
  time-stamp is always zero, so sequence is the only ordering signal — but the
  sender does not skip sequence numbers when it stops talking: one capture shows
  339 packets across eleven silences over 500 ms with a single discontinuity. A
  sequence-only clock therefore advances 80 ms across a four-second silence
  while the playout grid advances in real time, and after one pause the buffer
  is a pass-through with no jitter protection. `expand()` now takes `arrivedAt`
  and treats a wall-clock gap past the threshold as a talkspurt boundary.
  **Fixtures have no arrival times**, which is exactly why the suite hid this.
- **The jitter buffer is sized from the arrival pattern, not the packet size**:
  280 ms target, 240 ms floor, 500 ms ceiling. A proxied path tunnels UDP inside
  TCP, so packets arrive in clumps — median gap 0 ms, p90 184 ms, max 375 ms,
  worst shortfall against a 20 ms grid 265 ms, with zero loss. The talkspurt
  threshold is 480 ms, chosen to sit in the empty valley between the two
  populations: 105 ms above the largest bunching gap observed and 102 ms below
  the smallest real silence. At 240 ms it sat inside the bunching population and
  cost three spurious re-latches a minute. Both numbers are pinned by tests
  naming the measured values.
- **`noDelay` is now actually set.** `NWStreamTransport` reached for
  `NWProtocolTCP.Options` through `parameters.defaultProtocolStack.internetProtocol`
  and cast — that is the IP layer, the cast always failed, the `if let` swallowed
  it, and every signalling connection ran with Nagle on while the comment above
  said the opposite. The options are now built directly and the test asserts the
  IP layer is *not* where they live, because a test that only checked "some layer
  has noDelay" would have passed the broken version too.
- `SecretPrompt.Source.commandLine` carries the flag it came from, now that more
  than one secret flows through it.

### Resolved

- **OQ-9 — the permitted sources for EchoLink are named, and Phase 6
  unblocks.** RFC 3550 for RTP framing and GSM 06.10 for the codec as anchors
  *for the parts they cover*; **captures of the maintainer's own sessions are
  the primary source**; prose write-ups only under a provenance bar high enough
  to establish they are not derived from the implementations LP-2 forbids, which
  in practice almost nothing clears. Ambiguities are settled by cutting another
  capture, never by reading an implementation. Capture work spans multiple peers:
  a single-peer capture had already produced two confident wrong conclusions
  (SSRC always zero, sequence numbers start at zero) that a four-peer capture
  corrected.
- **OQ-8 — keep a local copy of the archived M17 chapter, outside both repos.**
  The page carries no licence statement, so redistributing it in an
  Apache-2.0 repository would assert a right nobody has checked; holding a
  reference copy is a different act from republishing one.
- **OQ-1's terms question is closed.** echolink.org was rechecked directly:
  no anti-reverse-engineering clause, no client-software restriction, no linked
  EULA, and the Download page lists third-party clients. OQ-1b still governs the
  name — nominative use only.
- **OQ-6 is deferred, not resolved**, until App Store submission is actually in
  view. It sits behind UI/UX work that has not started, nothing in the library
  changes either way, and deciding now would mean deciding twice.

### Known limitations

Everything under 0.2.0 still applies except the EchoLink entry. Added:

- **Direct (non-proxied) EchoLink is declared but not implemented.**
  `Route.direct` exists in the type so that adding it later is not a breaking
  change, and it throws `.directModeUnavailable`. This is deliberate: no capture
  of a direct session exists. The *framing* is known — proxy frames carry UDP
  payloads verbatim, so strip the 9-byte header and what remains is what direct
  mode would put on the wire — but the port assignment and socket setup are
  unobserved, and building those from the plausible reading is what this
  module's clean-room position forbids. FR-3.3 requires the proxy and makes it
  the default on cellular, so this blocks nothing on mobile data.
- **RFC 3550 does not describe this protocol as implemented.** The observed RTP
  version bits are 3, not 2; the proxy framing and the directory protocol fall
  outside it entirely. Where wire and RFC disagree the wire wins, and each
  divergence is recorded in `docs/reference/PROVENANCE.md`. Code written
  faithfully from the RFC would not interoperate.
- **The jitter and talkspurt values are tuning, not protocol facts.** They are
  measured from proxied sessions on one path, and they buy latency to pay for
  continuity. `--jitter-ms` overrides the target; a direct path would need far
  less.
- **The station list format is evidenced by measurement, not by a fixture, and
  deliberately so.** The rules are a tally over a real 6444-entry, 433 414-byte
  download; `testTheRealListParses` re-runs that tally but **skips unless
  `HAMVOIP_ECHOLINK_STATION_LIST` names a copy**, which is not committed and
  cannot be, because it is other operators' data. CI never runs it. The tests CI
  does run use invented callsigns and RFC 5737 addresses and say plainly that
  they are not evidence.
- **`ON` and `BUSY` are a sample, not a closed set.** Every one of 6441 stations
  said one or the other, but that is one server on one day, so status is carried
  as text.
- **On-air validation is one proxy, one directory server, one node.** M3 went
  through `*ECHOTEST*`, which returns only what you send it.
- **`RadioEvent` reports remote station activity unevenly, because the modes
  do.** M17 carries a callsign per stream, so `remoteTransmitStarted` names who
  is talking; EchoLink signals a talkspurt with no per-over identity, so the
  station is `nil`; IAX2 emits neither event, because an AllStar node sends a
  continuous stream and marks no talkspurt boundaries in it. An app showing "who
  is talking" gets it on one mode of three, and that is a property of the
  protocols rather than of this translation.
- **A node may answer from an address other than the one dialled** (IAX-11).
  `NWDatagramTransport` opens a connected `NWConnection`, and a multi-homed node
  answering from its other interface produces `ENOTCONN` on the second send with
  nothing delivered upward. Confirmed on the wire only as far as the unexpected
  source address; the maintainer's decision is to **diagnose** this rather than
  receive from any source, so the connected socket stays and the error message
  is what changes. Affects IAX2, not EchoLink.

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
  `docs/CLI.md` §6.
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

[Unreleased]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/cpmpercussion/swift-hamvoip/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/cpmpercussion/swift-hamvoip/releases/tag/v0.1.0
