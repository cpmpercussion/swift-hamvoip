<!-- SPDX-License-Identifier: Apache-2.0 -->

# `hamvoip-cli` — the macOS harness

**Task:** CLI-1. **Milestone it unlocks:** M2 — a human completes a live QSO
with an AllStarLink node.

Everything under `Sources/` has unit tests against recorded fixtures, and not
one of them can tell you whether a person can hold a conversation. That is what
this tool is for. It is also the embodiment of the design requirements' Apple
development procedure — *wherever possible set up testing via CLI so nobody has
to open Xcode* — which is why every check below is a terminal command.

macOS only, in practice: it wants a terminal and a Mac's audio devices. The
package still builds for iOS; an iOS app depends on the library products and
never on this executable.

---

## 1. Build and run

```sh
swift build                       # builds the libraries and the executable
swift run hamvoip-cli --help
swift run hamvoip-cli connect --help
swift run hamvoip-cli oq5 --help
```

For repeated use, build once and run the binary directly — `swift run`
re-checks the build graph every time, which adds a second of latency to
something you will start and stop a lot:

```sh
swift build -c release
.build/release/hamvoip-cli connect --host node.example.org --node 55553 \
    --username vk1xyz --callsign VK1XYZ
```

The only third-party dependency is
[`apple/swift-argument-parser`](https://github.com/apple/swift-argument-parser)
(Apache-2.0), authorised by CLI-1 in the development plan. Nothing else in this
package may take a dependency without a task that says so.

### macOS microphone permission

The first run that opens the microphone triggers a TCC prompt attributed to
your **terminal application**, not to `hamvoip-cli` — a command-line binary
inherits its parent's TCC identity. If you never see a prompt and capture is
silent, check System Settings → Privacy & Security → Microphone and confirm
your terminal is allowed. `--no-audio` skips the microphone entirely.

---

## 2. `connect`

```
hamvoip-cli connect --host <h> [--port 4569] --node <n> --username <u>
                    --callsign <c> [--secret <s>]
                    [--transmit-timeout 180] [--no-audio]
                    [--dtmf <digits>] [--duration <seconds>]
```

| Flag | Meaning |
|---|---|
| `--host` | Hostname or address of the node. |
| `--port` | UDP port; 4569 unless the node says otherwise. |
| `--node` | The node or extension being called — the CALLED NUMBER IE (§8.6.1). |
| `--username` | The account the node authenticates you as — USERNAME (§8.6.6). |
| `--callsign` | Sent as CALLING NAME (§8.6.4). Upper-cased; `/P`, `-1` and similar suffixes are fine. |
| `--secret` | **See §3 before using this.** |
| `--transmit-timeout` | SF-1 watchdog, 5–3600 s, default 180. There is deliberately no way to disable it. |
| `--no-audio` | Do not open the microphone or speaker. Signalling, auth and DTMF only. |
| `--dtmf` | Send this sequence once the call is up, then carry on normally. |
| `--duration` | Hang up automatically after this many seconds. |

### Key bindings

Printed on start, and again whenever you press `?`.

| Key | Action |
|---|---|
| `SPACE` | Toggle PTT. |
| `0`–`9`, `*`, `#`, `A`–`D` | Send that DTMF digit immediately (FR-1.5). |
| `d` | Type a DTMF sequence; `RETURN` sends it, `ESC` cancels. |
| `?` or `h` | Reprint the bindings. |
| `q`, `Ctrl-C`, `Ctrl-D` | Quit: unkey, hang up, disconnect, restore the terminal. |

PTT is a **toggle**, not press-and-hold. A terminal cannot see key *release* —
it receives a byte on press and nothing on lift — so press-and-hold cannot be
implemented here at all. The iOS app's momentary button (PT-1, task APP-2) is
where press-and-hold lives. The consequence is that the SF-1 watchdog matters
more in this tool than it will in the app: a toggle is exactly the control that
can be left on.

### What is on screen

Event lines scroll; a status line stays on the bottom row:

```
[TX 12s/180s]  rx ####........  -22.4 dBFS  tx ######......  -14.1 dBFS CLIP
```

* `[RX]` / `[TX <elapsed>/<limit>]` — transmit state and how close the SF-1
  watchdog is.
* `rx` — level of decoded audio arriving from the node. This is the RX
  indicator: a bar that moves is the node talking.
* `tx` — level of what is actually being transmitted. It sits at the floor while
  unkeyed, because frames captured while unkeyed are dropped by
  `IAX2Client.send(pcm:)` rather than sent.
* `CLIP` appears when the held peak comes within 3 dB of full scale.
* `drop N` appears if captured frames were discarded because the sender could
  not keep up. Anything other than absent is a finding worth reporting.

The watchdog gets a bell and a banner of its own when it fires:

```
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!! TRANSMIT WATCHDOG EXPIRED after 180.0 seconds — transmission was stopped for you (SF-1)
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
```

### The terminal is always given back

Raw mode is entered only after the call is up, and it is undone by every exit
path there is: the normal quit, `atexit`, `SIGTERM`/`SIGHUP`/`SIGQUIT`/`SIGINT`,
and the crash signals (`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGABRT`,
`SIGTRAP`), which restore and then re-raise so a crash still crashes and still
produces a report. A terminal left without echo, without line editing and
without a working `Ctrl-C` is a hostile thing to hand someone, so this is
tested directly against a pseudo-terminal in `RawTerminalTests`.

`Ctrl-C` is handled as a *keystroke*, not as a signal: raw mode turns `ISIG`
off, so `0x03` reaches the key loop and takes the same graceful path as `q` —
unkey, HANGUP, disconnect. The signal handlers are the safety net for what
cannot be turned into a keystroke.

If standard input is not a terminal (a pipe, CI, `< /dev/null`), there is no
key handling; the session runs until the node hangs up or `--duration` elapses.

---

## 3. The secret

**Never pass a password as a plain command-line argument if you can avoid it.**
`argv` is readable by every process on the machine through `ps`, and your shell
writes the whole command line to its history file.

In order of preference:

```sh
# 1. Interactive prompt. Echo is disabled; nothing is stored anywhere.
hamvoip-cli connect --host … --node … --username vk1xyz --callsign VK1XYZ

# 2. Environment variable, for repeated use in one shell session.
read -rs HAMVOIP_SECRET && export HAMVOIP_SECRET
hamvoip-cli connect --host … --node … --username vk1xyz --callsign VK1XYZ

# 2a. One-shot, from a file or the Keychain. Nothing persists, nothing
#     reaches argv, and only the path reaches your shell history.
HAMVOIP_SECRET="$(cat ~/.config/hamvoip/secret)" hamvoip-cli connect …
HAMVOIP_SECRET="$(security find-generic-password -a hamvoip -s <account> -w)" \
    hamvoip-cli connect …

# 3. --secret. Scripting only, and it costs you the hazard above.
hamvoip-cli connect … --secret "$(cat ~/.config/hamvoip/secret)"
```

**If it prompts when you expected it not to, the variable was not in the
process environment** — the tool checks `HAMVOIP_SECRET` and treats an empty
value as absent, so a prompt means nothing was there to find. An `export`
lives only in the shell that ran it: a new tab, a new terminal, a `sudo`, or a
runner that starts a fresh shell per command all lose it. Confirm with
`printenv HAMVOIP_SECRET | wc -c` in the *same* shell you are about to run
from, or sidestep the question entirely with the one-shot form above. Note
also that `read` takes its input from stdin — paste a whole multi-line block
at once and `read` will silently swallow the next line of the block as the
secret.

To put a secret in the Keychain rather than a plaintext file:

```sh
security add-generic-password -a hamvoip -s <account> -w
```

Precedence is `--secret` → `$HAMVOIP_SECRET` → prompt. The banner names the
source it used, and prints an explicit warning when the source was `--secret`,
so a mistake is visible while you can still rotate the password. If there is no
terminal to prompt on and no secret supplied, the call proceeds unauthenticated
rather than blocking forever on a pipe that will never answer.

The secret itself is never transmitted. It is hashed with the node's CHALLENGE
and only the digest goes on the wire (§8.6.15) — which is precisely what OQ-5
is about.

---

## 4. The OQ-5 experiment

### The question

RFC 5456 §8.6.15 says the MD5 RESULT information element (`0x10`) "carries the
UTF-8-encoded challenge result" and computes it as `MD5(challenge ‖ password)`.
It never says what that text *looks like*: hexadecimal or something else, upper
or lower case, padded to 32 characters or not. `docs/reference/RFC5456-NOTES.md`
§13 records the gap. LP-2 forbids settling it by reading Asterisk or iaxclient,
and that prohibition matters unusually much here because reading one is the
tempting shortcut.

IAX-4 shipped **lowercase 32-character hex** as a documented assumption. This
subcommand turns the assumption into an observation by asking a real node.

### The answer, 2026-08-09

**Hexadecimal. Keep sending lowercase.** Asked of an ASL3 node (Asterisk +
app_rpt, in a UTM VM) with `--method register --exhaustive`:

| Candidate | Node's answer |
|---|---|
| `lowercase-hex` | **REGACK** — accepted |
| `uppercase-hex` | **REGACK** — accepted |
| `base64` | REGREJ, `CAUSE "Registration Refused"`, `CAUSE CODE 29` |
| `raw-bytes` | REGREJ, `CAUSE "Registration Refused"`, `CAUSE CODE 29` |

Two acceptances, and the run is still sound. Each probe ran on its own UDP
association and drew its own fresh CHALLENGE, so these are four independent
verifications rather than one result echoed. A node that decodes the IE text
back to sixteen bytes before comparing — or that compares case-insensitively —
accepts both hex renderings by construction. The refusals are what make the
reading safe: a node that waved everything through would have taken base64
too, so this one is genuinely checking the digest. The capture corroborates
it — REGACK came back immediately, while both REGREJs were held for about a
second, which is the pacing of a credential check that failed rather than of a
parse error.

**What this does not license.** It is an observation about one implementation.
Case-insensitivity is that node's business, not the protocol's; the RFC still
does not say. Another peer may compare byte-for-byte, so
`IAX2Auth.TextDigestEncoding.oq5Default` stays lowercase hex and no call site
changes.

### Running it

```sh
export HAMVOIP_SECRET=…            # or let it prompt
hamvoip-cli oq5 --host node.example.org --node 55553 \
    --username vk1xyz --callsign VK1XYZ
```

That tests all four candidates in order and stops at the first one accepted.
Options:

| Flag | Meaning |
|---|---|
| `--method register` | **Default.** REGREQ → REGAUTH → REGREQ+MD5 → REGACK/REGREJ (§6.1). A registration exchange — no call is placed, nothing rings, no repeater is keyed, no audio flows. |
| `--method call` | NEW → AUTHREQ → AUTHREP → ACCEPT/REJECT (§6.2), hanging up the instant an ACCEPT arrives. **This briefly places a real call**, which on a linked node can key a transmitter. Your own node only, and only if you are licensed. |
| `--encoding <name>` | Test one candidate. Repeat the flag for several. Omit for all four. |
| `--timeout <seconds>` | How long to wait per probe (default 8). |
| `--exhaustive` | Keep going after one is accepted — useful to prove exactly one works. |

`--node` and `--callsign` are only used by `--method call`; the register method
ignores them.

### The candidates

| Name | What goes in IE `0x10` |
|---|---|
| `lowercase-hex` | 32 characters, `0`–`9`/`a`–`f`. **What IAX2Kit ships today.** |
| `uppercase-hex` | 32 characters, `0`–`9`/`A`–`F`. |
| `base64` | 24 characters of standard base64 of the 16 digest bytes. |
| `raw-bytes` | The 16 raw digest bytes, with no text encoding at all. |

`raw-bytes` is there because "UTF-8-encoded" may be describing the IE's general
string-ness rather than the digest's rendering. It is the one candidate that
cannot be expressed through `IAX2Auth.md5Response` — that function returns a
`String` — so it is built as a raw IE.

### Reading the output

```
OQ-5 experiment — how does node.example.org want MD5 RESULT encoded?
  method    register
  username  vk1xyz
  candidates
    lowercase-hex    32 lowercase hex characters — the assumption IAX2Kit ships (oq5Default)
    …

→ lowercase-hex … ACCEPTED
    challenge  283719493
    sent       931e06eee10cf8038c95d442cfac0ffb

CONCLUSION: this node accepts MD5 RESULT as lowercase-hex …
```

| Result | What it means |
|---|---|
| Exactly one accepted | **That is the answer to OQ-5.** Record it in the open-questions table in `docs/DEVELOPMENT-PLAN.md`, with the node and the date — it is now an observation about one implementation, not a fact about the protocol. |
| Both hex cases accepted, a non-hex candidate refused | **Also an answer, and the one a real node gave.** The node decodes the IE back to sixteen bytes, or compares the text case-insensitively; either way it is checking the digest, which the non-hex refusal is what proves. The answer is "hex", and case is that node's business rather than the protocol's. Keep sending lowercase — the next implementation may well compare byte-for-byte. |
| Both hex cases accepted, nothing refused | Not enough to conclude anything: a node that accepts whatever it is sent looks exactly like this. Re-run without `--encoding` so base64 and raw bytes are tested too. |
| Some other combination accepted | Impossible for a node that checks the digest. Treat the run as unreliable and repeat it. |
| All four rejected | Almost certainly a wrong username or secret, not an exotic encoding. Check those first. |
| Accepted with no challenge | The node does not authenticate this account, so it cannot answer the question. Configure a secret for the account on the node and try again. |
| Nothing answered | Reachability, not encoding. No candidate was actually tested. |

### If the answer is not `lowercase-hex`

How much work this is depends on which candidate won. There are three cases,
and only the first is free.

**A text encoding, on the `connect` path — configuration only.**
`IAX2Call.Configuration.md5ResultEncoding` carries the encoding and
`IAX2Call` uses it when it answers an AUTHREQ, so nothing needs recompiling
but your own call site:

```swift
var call = IAX2Call.Configuration()
call.md5ResultEncoding = IAX2Auth.TextDigestEncoding { bytes in
    bytes.map { String(format: "%02X", $0) }.joined()   // e.g. uppercase hex
}

var configuration = IAX2Client.Configuration()
configuration.call = call

let client = IAX2Client(configuration: configuration)
```

To change it for every caller rather than per client, edit the closure in
`IAX2Auth.TextDigestEncoding.oq5Default` instead.

**ℹ️ The registration path is not configurable — which turned out not to matter.**
`IAX2Registrar` calls `IAX2Auth.md5Response(challenge:secret:)` with the
default encoding (`Sources/IAX2Kit/IAX2Registration.swift:927`) and carries no
override. Had the answer been anything other than lowercase hex, registered
node mode (FR-1.3) would have stayed broken until `md5ResultEncoding` was
threaded through `IAX2Registrar.Configuration` the same way it was threaded
through `IAX2Call.Configuration`. The 2026-08-09 run resolved OQ-5 to
lowercase hex, so FR-1.3 works as shipped and threading the override through
is now a symmetry item rather than a defect.

**⚠️ `raw-bytes` cannot be expressed at all.**
`TextDigestEncoding` renders to a `String`, and `InformationElement.md5Result`
takes a `String`, so a digest sent as sixteen raw bytes is not reachable
through either configuration point — which is exactly why the `oq5` probe
builds `.unknown(id: 0x10, …)` by hand for that candidate. Should raw bytes
win, IAX2Kit needs a byte-valued MD5 RESULT path before either `connect` or
registration can authenticate.

Do **not** change the digest computation in `md5Response` in any of these
cases: OQ-5 is a question about rendering only, and the concatenation rule is
settled by §8.6.15.

---

## 5. Milestone M2 sign-off checklist

Run against a real node, by a licensed operator, on hardware. Record the result
on the CLI-1 pull request.

**Before you start:** you need a licence to transmit, and connecting to a node
may key a repeater. Announce yourself before testing on a busy node, and prefer
a private or test node for the level-setting parts.

1. **The call comes up.**
   `hamvoip-cli connect …` reaches `CONNECTED` and names a codec. Note whether
   it needed auth; if it did, OQ-5 has just been confirmed for the `connect`
   path too.

2. **Audio is intelligible inbound.** Listen to somebody else on the node, or
   to the node's own announcement. Speech should be understandable, not just
   present. Listen for pitch: audio that plays slightly slow or flat means the
   playback rate is wrong (the class of defect `PlaybackChain` was built to
   prevent) and is a hard fail.

3. **Audio is intelligible outbound.** Transmit and have somebody confirm — or
   use a node feature that plays your audio back. "I could hear something" is
   not a pass; "I understood the words" is.

4. **Levels are sane.** Speaking normally should put the `tx` meter somewhere
   around −20 to −12 dBFS with occasional peaks higher. Pinned at the floor
   means the microphone is not reaching the pipeline; permanently showing
   `CLIP` means input gain is far too high. Check `rx` the same way while the
   other station talks.

5. **PTT edges are crisp.** Press space, count "one, two", release, and have
   the other station report whether the first syllable was clipped and whether
   dead air followed. Capture runs continuously and the gate is in
   `IAX2Client.send(pcm:)`, so the edge should be immediate; audible clipping
   of the first word points at the capture path, not the network.

6. **The watchdog fires.** `--transmit-timeout 10`, key up, wait. The banner and
   the bell must appear, transmission must stop on its own, and the status line
   must return to `[RX]`. **This is SF-1 being seen to work**, and it is the
   single most important item here: a toggle-PTT client without a working
   watchdog can hold a repeater open.

7. **DTMF reaches the node.** Send a command the node acknowledges audibly —
   on AllStar, `*70` (say the node number) is a common one; use whatever your
   node answers. Confirm both the single-key path (press `3`) and the sequence
   path (`d`, type, `RETURN`).

8. **Teardown is clean.** Press `q`. The node should not report a dangling
   call, the summary should print, and the shell prompt that comes back should
   echo, edit lines and respond to `Ctrl-C` normally. Then do it again and
   interrupt with `Ctrl-C` instead, and once more with `kill <pid>` from
   another window — all three must leave the terminal usable.

9. **Nothing was dropped.** The summary's `frames dropped` should be `0`. A
   non-zero count is worth reporting even if the audio sounded fine: it is
   RC-9's failure mode showing up early.

---

## 6. What is tested, and what a node has to test

Unit-tested (`Tests/HamVoIPCLITests/`, no hardware, no network):

* **Argument validation** — ports, callsigns, DTMF character sets, the SF-1
  timeout bounds, and the destination assembly, including that a NEW never
  carries the secret.
* **The level meter** — RMS and dBFS against hand-computed signals, bar
  rendering at every level, fixed-width formatting, peak hold and decay.
* **The capture hand-off** — order preservation, bounded depth, drop-oldest
  behaviour, drop accounting, and concurrent submission losing nothing
  uncounted.
* **The OQ-5 candidates** — each renders what its name claims, all are
  renderings of the same digest, that digest matches an independently computed
  MD5 vector and agrees with `IAX2Auth`, and each serialises to a well-formed
  IE `0x10`.
* **Secret precedence** — command line over environment over prompt, empty
  environment variables treated as absent, no blocking without a terminal.
* **Raw mode** — against a real `posix_openpt` pseudo-terminal: the flags raw
  mode sets, and that leaving restores every flag and control character
  exactly, idempotently, and repeatedly.

Only a live node can test: whether audio is intelligible, whether levels are
right, whether PTT edges sound clean, whether the node accepts our
authentication, and whether DTMF reaches its command processor. That is what
§5 is for.
