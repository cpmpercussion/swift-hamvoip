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
swift run hamvoip-cli iax2 --help
swift run hamvoip-cli experiment oq5 --help
```

Since v0.5.0 the CLI is organised one command per protocol — `iax2`,
`echolink`, `m17` — with the probes that answer an open question gathered
under `experiment` rather than sitting at the top level next to the protocols
they interrogate. `connect` remains as a working alias for `iax2`, so nothing
that already invokes it — including the session records later in this
document, which are quoted as they were run — breaks or needs rewriting.

For repeated use, build once and run the binary directly — `swift run`
re-checks the build graph every time, which adds a second of latency to
something you will start and stop a lot:

```sh
swift build -c release
.build/release/hamvoip-cli iax2 --host node.example.org --node 55553 \
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
your terminal is allowed. `--no-audio` skips the microphone entirely and sends
silence instead, so an unattended session can still key up (CLI-2).

---

## 2. `iax2`

```
hamvoip-cli iax2 --host <h> [--port 4569] --node <n> --username <u>
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
| `--no-audio` | Do not open the microphone or speaker. PTT still transmits — `SilentCaptureSource` feeds the transmit path 20 ms of silence at a time — so an unattended run puts a real, properly framed stream on air without any hardware. Until CLI-2 this flag claimed to send silence and sent nothing at all. |
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

### The closing summary

```
Summary:
  frames captured      2431  (microphone runs continuously)
  frames transmitted   860  (PTT on)
  frames dropped       0
  DTMF sent/received   4/0
  watchdog expiries    0
```

**Captured and transmitted are different numbers, and the gap is the point.**
Capture runs for the whole session so that PTT edges are crisp, and the gate
is in `IAX2Client.send(pcm:)`; `frames captured` therefore counts everything
the microphone produced, keyed or not, while `frames transmitted` counts only
what the gate let through. Captured greatly exceeding transmitted is the
normal, correct shape of a session where you listened more than you talked.

**`frames transmitted` non-zero while you never pressed SPACE would be a
serious defect** — the client keying up on its own — so it is worth a glance
every run. These two were reported as one number labelled "transmitted
frames" until a live session made the ambiguity obvious.

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

## 3. Per-operator defaults: `~/.config/swift-hamvoip/`

The values that never change between runs live in a config directory, so they
do not have to be typed or exported every time:

```
~/.config/swift-hamvoip/CALLSIGN                     every command
~/.config/swift-hamvoip/IAX2_SECRET                  iax2      node secret
~/.config/swift-hamvoip/ALLSTARLINK_PORTAL_PASSWORD  wt-token  portal password
~/.config/swift-hamvoip/ECHOLINK_PASSWORD            echolink  account password
~/.config/swift-hamvoip/ECHOLINK_PROXY               echolink  proxy host
~/.config/swift-hamvoip/ECHOLINK_PROXY_PORT          echolink  proxy port
~/.config/swift-hamvoip/ECHOLINK_PROXY_PASSWORD      echolink  proxy password
```

**A credential is named for the subcommand that uses it**, so the file name
tells you what it is for without a gloss. `IAX2_SECRET` was `HAMVOIP_SECRET`
until 0.6.0, from when the CLI had only one protocol in it — `echolink` and
`m17` are equally "hamvoip", so that name said which *project* the file belonged
to rather than which credential it held. The old name no longer works; see the
CHANGELOG.

`$XDG_CONFIG_HOME` is honoured if it is set.

The layout is deliberately dull: **one file per value, named for the setting,
containing nothing but the value.** No format, no parser, no escaping rules,
nothing to get wrong — `cat` shows you a setting and `echo >` sets one. Each
file's name is the environment variable it stands in for, which is the whole
convention: if you know the variable, you know the file. A trailing newline is
trimmed, so `echo VK1XYZ > CALLSIGN` does what it looks like.

```sh
mkdir -p ~/.config/swift-hamvoip
echo 'VK1XYZ' > ~/.config/swift-hamvoip/CALLSIGN
printf '%s' 'the-password' > ~/.config/swift-hamvoip/ECHOLINK_PASSWORD
chmod 600 ~/.config/swift-hamvoip/ECHOLINK_PASSWORD
```

**Precedence: command line → environment → config file → interactive prompt.**
The file sits below the environment so a one-off override never needs an edit,
and above the prompt so the common case is silent. It is the order `git` and
`ssh` use for their own per-user configuration.

With a `CALLSIGN` file in place, `--callsign` becomes optional everywhere it
was required. Omitting it *and* having no file is an error that names both
places, because "callsign is required" is no help to somebody who thought they
had set it.

The commands say where a credential came from, so a stale file is findable:

```
Callsign VK1XYZ; account password from /Users/you/.config/swift-hamvoip/ECHOLINK_PASSWORD.
```

`chmod 600` the password files. If one is readable by other users on the
machine the CLI says so once, on stderr, and carries on — a permission bit is
the operator's call about their own machine, and refusing to run would be a
worse failure than the risk it prevents.

## 4. The secret

**Never pass a password as a plain command-line argument if you can avoid it.**
`argv` is readable by every process on the machine through `ps`, and your shell
writes the whole command line to its history file.

In order of preference:

```sh
# 1. Interactive prompt. Echo is disabled; nothing is stored anywhere.
hamvoip-cli iax2 --host … --node … --username vk1xyz --callsign VK1XYZ

# 2. Environment variable, for repeated use in one shell session.
read -rs IAX2_SECRET && export IAX2_SECRET
hamvoip-cli iax2 --host … --node … --username vk1xyz --callsign VK1XYZ

# 2a. One-shot, from a file or the Keychain. Nothing persists, nothing
#     reaches argv, and only the path reaches your shell history.
IAX2_SECRET="$(cat ~/.config/hamvoip/secret)" hamvoip-cli iax2 …
IAX2_SECRET="$(security find-generic-password -a hamvoip -s <account> -w)" \
    hamvoip-cli iax2 …

# 3. --secret. Scripting only, and it costs you the hazard above.
hamvoip-cli iax2 … --secret "$(cat ~/.config/hamvoip/secret)"
```

**If it prompts when you expected it not to, the variable was not in the
process environment** — the tool checks `IAX2_SECRET` and treats an empty
value as absent, so a prompt means nothing was there to find. An `export`
lives only in the shell that ran it: a new tab, a new terminal, a `sudo`, or a
runner that starts a fresh shell per command all lose it. Confirm with
`printenv IAX2_SECRET | wc -c` in the *same* shell you are about to run
from, or sidestep the question entirely with the one-shot form above. Note
also that `read` takes its input from stdin — paste a whole multi-line block
at once and `read` will silently swallow the next line of the block as the
secret.

To put a secret in the Keychain rather than a plaintext file:

```sh
security add-generic-password -a hamvoip -s <account> -w
```

Precedence is `--secret` → `$IAX2_SECRET` → the config file → prompt. The banner names the
source it used, and prints an explicit warning when the source was `--secret`,
so a mistake is visible while you can still rotate the password. If there is no
terminal to prompt on and no secret supplied, the call proceeds unauthenticated
rather than blocking forever on a pipe that will never answer.

The secret itself is never transmitted. It is hashed with the node's CHALLENGE
and only the digest goes on the wire (§8.6.15) — which is precisely what OQ-5
is about.

---

## 5. The OQ-5 experiment

§7 does the same thing for OQ-7, against an M17 reflector instead of a node.

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
export IAX2_SECRET=…            # or let it prompt
hamvoip-cli experiment oq5 --host node.example.org --node 55553 \
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

**A text encoding, on the `iax2` path — configuration only.**
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
win, IAX2Kit needs a byte-valued MD5 RESULT path before either `iax2` or
registration can authenticate.

Do **not** change the digest computation in `md5Response` in any of these
cases: OQ-5 is a question about rendering only, and the concatenation rule is
settled by §8.6.15.

---

## 6. Milestone M2 sign-off checklist

### Result — 2026-08-09, ASL3 node in a UTM VM ✅ PASSED

Run against `Echo()` in a plain dialplan context, so nothing was keyed. Packet
captures retained (`connect3.pcap`, two sessions of 36.7 s and 15.7 s).

| # | Item | Result |
|---|---|---|
| 1 | Call comes up | ✅ `CONNECTED  codec G.711 µ-law`, authenticated |
| 2 | Inbound intelligible | ✅ words understood; no pitch or rate problem |
| 3 | Outbound intelligible | ✅ own words understood coming back |
| 4 | Levels sane | ⚠️ rx −18 dBFS, tx −29 dBFS — usable, tx a little below the −20…−12 target |
| 5 | PTT edges crisp | ⚠️ not cleanly assessable: `Echo()` is full duplex with ~0.5 s round trip, so there is no unkey-then-hear boundary to judge. No clipping reported |
| 6 | **Watchdog fires** | ✅ `--transmit-timeout 10`: banner, `TX OFF`, `watchdog expiries 1`, and **exactly 500 frames transmitted** — 500 × 20 ms = 10.000 s, so it cut on the limit and not a frame later |
| 7 | DTMF reaches the node | ✅ `DTMF '3'` sent, ACKed, echoed back |
| 8 | Teardown clean | ✅ `q` path verified on the wire (HANGUP + cause IEs, ACKed). `Ctrl-C` and `kill` paths not re-confirmed this session |
| 9 | Nothing dropped | ✅ `frames dropped 0` on every run |

Also validated live, beyond the checklist: PING/PONG and LAGRQ/LAGRP
(the node polled at 10, 20, 21 and 30 s and every one was answered), the
full-frame-then-mini transmit ordering of §8.1.2, and 1135 mini frames each
way all exactly 160 octets.

**Open wart:** on one session the node sent `VNAK` ×3 at our first voice
frame; retransmission recovered it and the call was unaffected. It correlates
with the client emitting a burst of frames in a single millisecond rather than
pacing them at 20 ms. Tracked as IAX-10.

Re-run items 5 and 8 before v1: item 5 needs a half-duplex target rather than
`Echo()`, and item 8's signal paths need one pass each.

---

Run against a real node, by a licensed operator, on hardware. Record the result
on the CLI-1 pull request.

**Before you start:** you need a licence to transmit, and connecting to a node
may key a repeater. Announce yourself before testing on a busy node, and prefer
a private or test node for the level-setting parts.

### Doing it without keying anything

Most of this list can be done alone, against your own node, with no RF at all
— which is worth doing first, because a defect found here costs nobody any
airtime. Point the account's `context=` in `iax.conf` at a plain Asterisk
dialplan context rather than at an app_rpt node. Ordinary dialplan
applications never enter the repeater or link path, so nothing is keyed and
nothing reaches the network even from a node that is connected to it:

```ini
[hamvoip-test]
exten => 100,1,Answer()          ; echo — hear yourself back
 same => n,Wait(1)
 same => n,Echo()
 same => n,Hangup()
exten => 101,1,Answer()          ; known speech — judge playback rate
 same => n,Playback(demo-congrats)
 same => n,Hangup()
exten => 102,1,Answer()          ; 1004 Hz at 0 dBm0 — a level reference
 same => n,Milliwatt()
 same => n,Hangup()
exten => 103,1,Answer()          ; DTMF in, digits read back
 same => n,Read(digits,,4)
 same => n,SayDigits(${digits})
 same => n,Hangup()
```

The account also needs `disallow=all` / `allow=ulaw`: the client advertises
G.711 µ-law as its entire CAPABILITY and FORMAT (`IAX2Client.swift`), so a node
offering nothing else in common will refuse the call. It needs
`requirecalltoken=no` as well — call token is an Asterisk extension, not part
of RFC 5456, and IAX2Kit does not implement it.

Not every Asterisk build loads every application. If the console says
`No application 'Echo'`, the call is *accepted* and then dropped the moment the
dialplan reaches that line, which looks like a client fault and is not one:

```sh
sudo asterisk -rx "module show like echo"
sudo asterisk -rx "module load app_echo.so"
```

Keep `asterisk -rvvvv` open throughout. It is the difference between "the node
hung up" and knowing why.

1. **The call comes up.** ✅ *Observed 2026-08-09 against ASL3:*
   `CONNECTED  codec G.711 µ-law`, reached with authentication, which confirms
   OQ-5 for the `iax2` path as well as the registration path.
   `hamvoip-cli iax2 …` reaches `CONNECTED` and names a codec. Note whether
   it needed auth; if it did, OQ-5 has just been confirmed for the `iax2`
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

## 7. What is tested, and what a node has to test

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
* **The OQ-7 tally** — both readings of Table 27 synthesised field by field and
  told apart; that silence, mixed lengths, an unexpected length and a
  length-versus-sequencing contradiction all refuse to become a verdict; that a
  run reporting the refuted 56-byte reading is reported as disagreeing with the
  settled answer rather than as confirmation of anything; and, through the whole
  stack against `MockTransport`, both that the settled 54-byte reality is parsed
  and tallied, and that a reality `M17ReflectorClient` discards entirely still
  reaches a verdict.

Only a live node can test: whether audio is intelligible, whether levels are
right, whether PTT edges sound clean, whether the node accepts our
authentication, and whether DTMF reaches its command processor. That is what
§5 is for.

---

## 8. The OQ-7 experiment

> **Settled 2026-08-11: the frame is 54 bytes.** The evidence is in
> "What the answer was", below, and in the OQ-7 row of `DEVELOPMENT-PLAN.md`.
> `M17StreamPacket` implements 54. The subcommand remains, because one over on
> one reflector is one observation, and re-checking it against a second
> reflector is a five-minute job for whoever is next on air.

### The question

Is an M17 IP stream frame 56 bytes or 54?

Table 27 of the reflector chapter gives LICH as 240 bits. That is the whole
30-byte LSF of Part I Table 3.1 — DST 48, SRC 48, TYPE 16, META 112, CRC 16 —
and the arithmetic follows: 4 + 2 + 30 + 2 + 16 + 2 = **56**. The figure quoted
widely elsewhere is 54, which is the same layout with a 28-byte LICH, i.e. the
LSF *without* its own CRC. Both readings are consistent with the text, so the
document cannot settle it, and LP-2 forbids reading an implementation to find
out. `M17StreamPacket` implemented 56 and said so in its doc comment, naming
`byteCount` as the single place to change.

M17-4 must not build stream transmit on an unverified frame size. So the
question went to a reflector, which answers it every time somebody keys up.

### Why it cannot listen to `M17ReflectorClient.events`

Because `M17ReflectorClient` drops datagrams it cannot parse, and
`M17StreamPacket.parse` requires exactly `byteCount` bytes. Any reality other
than the one the parser already implements is therefore discarded before it
reaches `events`, and a harness built on `events` reports a reflector that sent
no audio at all — the wrong answer, arrived at with confidence, from code that
is behaving correctly.

This is not hindsight: it is what happened. The parser said 56, the wire said
54, and only because the tap sits below the parser did the experiment come back
with an answer that contradicted the code running it instead of with silence.
The same reasoning now points the other way — a reflector sending 56 would be
invisible to `events` today — which is why the tap stays.

`RecordingTransport` therefore taps the `DatagramTransport` seam and measures
every datagram *below* the parser. `RecordingTransportTests` pins this down so
the harness cannot later be "simplified" into uselessness.

### Running it

Receive-only. It sends CONN, answers PING with PONG, and sends DISC on the way
out; it never sends a stream packet, and there is no transmit path in `M17Kit`
for it to use even if it wanted one. Your callsign does go out in CONN, so you
will appear on the reflector's dashboard as a connected station — which is
normal, and is also how you confirm the link from the other side.

```sh
# Listen for five minutes on a busy module.
swift run hamvoip-cli experiment oq7 --reflector <host> --module C --callsign VK1XYZ

# Until Ctrl-C, stopping early once 40 frames have arrived, with a report file.
swift run hamvoip-cli experiment oq7 --reflector <host> --module C --callsign VK1XYZ \
    --duration 0 --min-frames 40 --report ../experiment-data/oq7-result.txt
```

**Write the report outside the repository.** A report names the callsigns it
heard, so it carries other operators' traffic. The workspace keeps
`experiment-data/` for exactly this — see the workspace `CLAUDE.md`. The paths
above assume you are running from the `swift-hamvoip` checkout with that
directory alongside it.

`.gitignore` also covers `*.pcap` and `*-result.txt`, but treat that as a
backstop for a mistake rather than permission to leave either in the tree: an
ignored file is still sitting in a working directory that gets `git clean`ed.

Ctrl-C ends the run *with* a verdict rather than killing it before the report
prints. If the reflector answers NACK, try a module it actually offers and
`--source-module`, which appends a module letter to your own address the way the
specification's `"A1BCD D"` example does.

To keep a capture of the run — worth doing, and what the 2026-08-11 verdict was
independently checked against — run `tcpdump` alongside. Read the provenance note
at the end of this section before cutting a fixture from it:

```sh
sudo tcpdump -i any -w ../experiment-data/m17-oq7.pcap 'udp port 17000'

# tcpdump under sudo writes a root-owned file; hand it back afterwards.
sudo chown "$(id -un):staff" ../experiment-data/m17-oq7.pcap
```

### What it needs

Somebody talking. A silent module answers nothing, and the verdict will say so
rather than guess. Twenty or thirty frames of a single over is plenty — under
two seconds of speech.

### Reading the output

Datagram length is the primary evidence: a UDP datagram is as long as it is.
The corroboration is whether the two bytes at each reading's FN offset behave
like a frame counter — a real FN increments by one per frame within a stream,
while at the wrong offset the same bytes are an LSF CRC or Codec 2 payload and
count for nothing. That second test is what distinguishes a genuine 54-byte
frame from a 56-byte frame that something truncated.

| Verdict | Meaning |
|---|---|
| `SETTLED` | One consistent length, and FN counts at that reading's offset. 54 agrees with what M17Kit implements; anything else disagrees with a settled question, so read "What this does not claim" below before changing a constant. |
| `LENGTH ONLY` | One consistent length, too little traffic to check FN. Answers the question as asked; run longer to corroborate. |
| `CONTRADICTORY` | Length says one reading, sequencing the other. **Do not act on it** — keep the capture and read it by hand. |
| `MIXED` | Stream datagrams arrived in more than one length. Worth knowing whether they sort by transmitting client. |
| `UNEXPECTED` | A consistent length that is neither 54 nor 56. Read the datagram by hand before touching any constant. |
| `INCONCLUSIVE` | The link worked; nobody talked. |

### What the answer was

Run 2026-08-11 against a live reflector on UDP 17000, five minutes, one over of
52 frames from one station, alongside `tcpdump`. Verdict:

```
VERDICT: SETTLED — the stream frame is 54 bytes: 54-byte frame, 28-byte LICH
                   (LSF CRC absent)
```

Three readings of those bytes agree, and only on that layout:

| Evidence | 54-byte reading | 56-byte reading |
|---|---|---|
| Datagram length | 54 bytes, 52 of 52 | never seen |
| FN counts at the reading's offset | offset 34: 0, 1, 2 … 51 | offset 36: 0 of 51 pairs, and bit 15 set in 35 of 52 frames |
| Trailing CRC16 closes over the frame | bytes 0-51, valid 52 of 52 | LSF CRC at 32-33: 0 of 52 |

The CRC is the one that rules out a truncated 56-byte frame: two bytes lost in
transit would not leave a CRC that closes over what remains. It is the M17 CRC16
of Part I — polynomial `0x5935`, initial value `0xFFFF` — and confirming the
polynomial on real traffic is a side benefit M17-4 inherits. The field offsets
corroborate as well: SID constant across the over, DST and SRC decoding as
base-40 callsigns at bytes 6-11 and 12-17, TYPE `0x0005` (stream mode, voice,
unencrypted) at 18-19, META all zeros, and 16 bytes at 36-51 differing in every
frame, as Codec 2 must.

So `M17StreamPacket.byteCount` is 54, `lichByteCount` is 28, the `lsfCRC`
property is gone — there is no such field on the wire — and the hand-built spec
fixtures were rebuilt at 54 bytes with the divergence from Table 27 recorded in
their headers. The change is driven by an observation, not by the document, and
the doc comment on `M17StreamPacket` says which.

**What this does not claim.** One reflector, one over, one transmitting client.
If a later run reports 56, that is new information rather than a bug to fix by
reverting: the tally's guidance says to keep the capture and work out whether
the difference sorts by reflector or by transmitting software before touching
the constant, because two populations of transmitters disagreeing would mean the
parser has to tolerate both.

### A provenance question the maintainer owns

The frames this measures are other operators' traffic on a public reflector.
`FIXTURES.md` allows fixtures from "packet captures of our own sessions", which
is not quite what a passive listen produces, so **do not check a capture-derived
`live-*.hex` fixture in from this run without deciding that question first.**
Nothing forces the issue: OQ-7 needs only the length, the verdict lives in the
requirements and this document, and once the number is known the fixture can be
hand-built from the specification — `FIXTURES.md` source 1, the preferred one
anyway.

**In the event, that is what happened.** No `live-*.hex` was cut from the
2026-08-11 run. `reflector-stream.hex` and `reflector-stream-encrypted.hex` are
hand-built from the specification with only the LICH width taken from the
observation, so no third party's traffic is in the repository and the provenance
question is still open rather than answered by default. The capture itself sits
in the workspace with the AllStar ones, unversioned. Its provenance is recorded
in the OQ-7 row of `DEVELOPMENT-PLAN.md`, which is what a fixture header would
otherwise have carried.

---

## 9. `echolink` — EchoLink through a proxy (EL-10, Milestone M3)

The live-validation harness for EchoLink, and the counterpart to `iax2` for
IAX2 and `m17` for M17. Everything below the CLI is `EchoLinkClient`.

**✅ Milestone M3 passed, 2026-08-13**: a live QSO through `*ECHOTEST*`, audio
intelligible both ways, clean teardown. The protocol was recovered from captures
of a *third-party* client's sessions (OQ-9) rather than from a specification, so
expect rough edges — but our reading of it has now met a real proxy, a real
directory server and a real node.

`--list` (§9.1) was validated on air the same day.

```sh
swift run hamvoip-cli echolink \
    --proxy <proxy host> \
    --directory-server <directory server IPv4> \
    --peer 13.57.14.183 \
    --node '*ECHOTEST*'
```

With `CALLSIGN` and `ECHOLINK_PASSWORD` in `~/.config/swift-hamvoip/` (§3),
neither `--callsign` nor a password prompt is needed. Add `--callsign` to
override for one run, or `--no-directory-login` to skip the account login
entirely.

`*ECHOTEST*` is the obvious first contact: it echoes audio back, so one operator
alone can confirm the round trip end to end — which is exactly what the capture
work already demonstrated the path can do.

Keys are the same as the other two commands: SPACE toggles PTT, `q` quits, `?`
lists them.

### `--auto-proxy` — let it find a proxy (EL-12)

`--proxy` and `--auto-proxy` are alternatives, and one of the two is required.

```sh
swift run hamvoip-cli echolink --auto-proxy \
    --directory-server <directory server IPv4> \
    --peer 13.57.14.183 --node '*ECHOTEST*'
```

It fetches `https://www.echolink.org/proxyFind.jsp`, probes the nearest few
candidates, and uses the quickest that answers:

```
Fetching the public proxy list from echolink.org…
266 public proxies listed as ready.
Probing 5: VK2BSD PROXY #4, CE5RPY 097, CE5RPY 091, CE5RPY 076, CE5RPY 075
Using CE5RPY 076 — proxy77.redchile.org:8100 (10915 km, 1363 ms to greeting)
```

All of that goes to **stderr**, so `--list`'s output stays pipeable.

#### Why it probes instead of believing the list

`proxyFind.jsp` returns only the proxies that are public *and* `Ready` — 282
entries on 2026-08-13, exactly matching the `Ready` rows of the human-readable
`proxylist.jsp` when both were fetched in the same second, which is why nothing
here parses HTML. But `Ready` is a **poll snapshot**, and a public proxy carries
one client at a time. A proxy that was free when the directory last asked is
often taken by the time anyone acts on it, and a taken one accepts the TCP
connection and then hangs up without sending its nonce — which is exactly the
confusing `proxy: the proxy stream closed` this section used to tell you to
expect.

So each candidate is probed by connecting and reading its 8-byte greeting.
Nothing is sent: no login, not a byte. A proxy that greets us is there and free;
one that does not is skipped, whatever the list said.

The run above is the case in miniature. **VK2BSD #4 in Sydney, 465 km away and
listed `Ready`, did not answer** — and the session went to Chile instead. Trust
the list and that run is a failed connect with a misleading error.

#### Distance is a prior, not a measurement

The endpoint sorts by great-circle distance, and the official iOS client's
"Public Proxy" mode picks the geographically closest. That is a weak signal from
VK1: on 2026-08-13 there was **nothing under 5000 km** — nearest was Chile at
~10 900 km — so candidates are ordered by distance and then chosen by measured
round trip. `--proxy-candidates` (default 5) sets how many are probed at once;
raise it when everything listed is busy, remembering that each probe lands on
somebody else's machine.

The probe timeout is 3 s, and that number is measured rather than picked: the
live run above took **1363 ms** to get a nonce out of a Chilean proxy, DNS and
TCP handshake included. A shorter timeout silently discards working proxies.

#### Etiquette, and what is deliberately not sent

`robots.txt` disallows only `/links.jsp`, and the endpoint answers with
`Access-Control-Allow-Origin: *` and `Pragma: no-cache` — it is meant to be
called by clients. It also accepts `lat` and `lon` (those exact spellings), and
**we send neither**: IP geolocation put a Canberra request within ~11 km of the
truth, which is noise against these distances, so supplying real coordinates
would mean handing a third party the operator's position for nothing measurable.

Public proxies are a shared resource and echolink.org asks that they be used
briefly, which the command says on every auto-selected run. For sustained use —
which is what an app on cellular is — run a **private proxy**: echolink.org
distributes `EchoLinkProxy.jar`, and `--proxy` is how you point at it.

### A private proxy is one setting, not three (EL-15)

Host, port and password are one setting with three parts, and they resolve
together (`EchoLinkProxySettings`). The config directory takes all three, under
the usual convention that a file is named for the environment variable it stands
in for:

```sh
echo 'proxy.example.org'  > ~/.config/swift-hamvoip/ECHOLINK_PROXY
echo '8100'               > ~/.config/swift-hamvoip/ECHOLINK_PROXY_PORT
printf '%s' 'the password' > ~/.config/swift-hamvoip/ECHOLINK_PROXY_PASSWORD
chmod 600 ~/.config/swift-hamvoip/ECHOLINK_PROXY_PASSWORD
```

after which `--proxy` and its companions are optional:

```sh
swift run hamvoip-cli echolink --directory-server <IPv4> --peer <IPv4> --node '*ECHOTEST*'
```

Precedence is the usual command line → environment → config file → default, so a
one-off against a different proxy needs no edit. A malformed
`ECHOLINK_PROXY_PORT` is an error rather than a silent fall back to 8100: the
fallback would connect to *something*, and the operator would never learn the
file was wrong.

**They resolve together because resolving them apart is what went wrong.** A
config directory can end up holding `ECHOLINK_PROXY_PASSWORD` and nothing else —
a password with no proxy beside it, which no code can act on, and which reads
like a working setting because it is named like one.

#### The password only ever reaches its own proxy

A configured proxy password is used **only when the proxy being dialled is the
configured one**. Dial anything else — `--proxy someone-else`, or `--auto-proxy`,
where the host comes off a public list — and it falls back to `PUBLIC`, with a
note on stderr saying so.

This is a safety rule, not tidiness. The proxy login hashes the password into a
digest, so a stranger's proxy handed a private one gets material to attack
offline, and we gain nothing by sending it: a public proxy accepts `PUBLIC`
regardless. `--proxy-password` with a value other than `PUBLIC` is refused
outright alongside `--auto-proxy`, because there the destination is a stranger by
definition, and a password typed on purpose deserves an error rather than a
silent substitution.

An explicit `--proxy-password` otherwise wins: naming a host and a password
together is a deliberate act.

### Two passwords, and only one of them is secret

A proxied EchoLink session carries two different secrets a few bytes apart on
the same TCP connection, and confusing them is the easiest mistake here:

| | What it is | Secret? |
|---|---|---|
| **Proxy password** | `--proxy-password`, `$ECHOLINK_PROXY_PASSWORD`, or the config file. `PUBLIC` on a public proxy — the literal string, the public-proxy password *by definition*, and the only value ever observed in the wild. Hashed into the login digest, never sent in clear. | Only on a private proxy — see EL-15 above |
| **Account password** | Your own EchoLink account password. Relayed *in cleartext* to the directory server. | **Yes** |

They are separate Swift types (`EchoLinkProxyPassword`,
`EchoLinkAccountPassword`) so neither can be passed where the other belongs, and
both redact themselves in `description` so an interpolation cannot put one in a
log. There is deliberately no option for the account password: a password on the
command line lands in shell history.

### What connecting actually does

```
proxy login          nonce -> callsign + digest
OPEN                 to the DIRECTORY SERVER — the only OPEN a client sends
account login        tunnelled as 0x02, answered "OK"
CLOSE                the directory channel, closed on purpose. Not the session.
RR + SDES            to the node, on 0x06 — this is what opens the session
                     retransmitted until the node answers
audio                on 0x05
RR + BYE             on teardown
```

Two things here are worth knowing before debugging a failed session, because
both contradict what the plan originally assumed:

- **No `OPEN` is sent for the node.** `OPEN`/`CLOSE`/`STATUS`/`TCP_DATA` are the
  tunnelled TCP connection to the directory server. The audio and control
  channels are connectionless — the peer's address rides in each frame header —
  so they need no setup at all.
- **The `RR + SDES` on the control channel is what opens a session.** Without
  it, nothing answers. `--help`'s "expect to be the first" applies most
  sharply here.

`--directory-server` needs the directory server's IPv4 address. There is
deliberately no default: the proxy's `OPEN` carries a raw address, nothing here
resolves DNS, and baking one operator's choice of a third party's server into
the tool would be a guess about infrastructure rather than about the protocol.

`--no-directory-login` skips straight to the node. Whether a node answers a
client that never logged in is **not established** — no capture shows the
attempt — so that flag is an experiment, not a supported mode.

### What a live run has to settle

The unit tests cover everything that is a decision rather than an I/O call, all
of it against fixtures cut from real traffic. What they cannot cover is whether
our *reading* of the protocol is right — a fixture replays what happened, and
agrees with us by construction. A live run tests:

- that a real proxy accepts our login digest (both recorded vectors reproduce
  offline, but only against captures of a client that was not us);
- that a real node answers the `RR + SDES` that opens a session, and does so
  for a client that identifies itself as `swift-hamvoip` rather than as one of
  the two clients the captures contain;
- that GSM 06.10 audio we *encode* is intelligible at the far end. Decoding is
  already evidenced: `GSMVoiceCodecTests` decodes the captured frames a real
  peer sent, and finds them audible rather than noise. The encode direction has
  never been heard by anyone;
- that the synthesised playout clock (EL-7) sounds like speech rather than like
  a stutter, across a real talkspurt boundary;
- that the SF-1 watchdog cuts transmission at its limit, as it did for M2.

### Live status, 2026-08-13 — M3 passed

**The session connects and carries audio.** Proxy login, directory login, the
node handshake and speech in both directions all work on air: `*ECHOTEST*`
answers by name, its station info arrives, and it echoes back what it is told.
That is Milestone M3.

Getting there turned up a three-part bug in the directory login, the important
part being that the `ONLINE` line is what registers a station as *available*.
Authentication is not registration: without it the server answers `OK` and
never lists you, so every step reports success and no node will ever answer.
The EL-10 entry in `DEVELOPMENT-PLAN.md` has the full comparison.

Two practical notes from that attempt:

- **Public proxies are single-user and heavily contended.** A proxy listed
  `Ready` is often busy by the time you connect, and a busy one accepts the TCP
  connection and then hangs up before sending its nonce — which the client
  reports as `proxy: the proxy stream closed`. That is not a fault. The list is
  at `http://www.echolink.org/proxylist.jsp`; probing a candidate by reading
  its 8-byte greeting takes a second and saves a confusing failure.
- **`--node-answer-timeout`** controls how long the opening SDES is resent
  while waiting. Raise it when capturing an attempt for analysis.

### If the audio grinds

Three things caused that on the first live audio test, all in this client and
all now fixed. If it comes back, they are the places to look:

- **A drifting playout grid.** `tick(); sleep(20ms)` costs 20 ms *plus* the
  tick *plus* scheduler slop, so frames go out every 22–25 ms into a device
  consuming them every 20 ms. The speaker starves several times a second. The
  loop now sleeps until an absolute deadline, as `M17Client` always did.
- **Holes in the output stream.** Yielding nothing on a concealed or starved
  tick leaves a gap the device underruns on. Every tick now yields exactly one
  frame — a faded repeat of the last real one for a short run, then zeros.
- **A jitter buffer far smaller than the arrival pattern needs.** This one took
  a capture to size honestly. On a live 65-second session the proxied path
  delivered **zero lost packets in either direction** — and arrivals with a
  median gap of 0 ms, a p90 of 184 ms and a worst-case shortfall of **265 ms**
  against a steady 20 ms grid. That signature is bursts: several packets land
  together, then nothing for a sixth of a second. Nothing is missing; it is all
  late, together, because the proxy tunnels UDP inside TCP and TCP bunches it.

  A buffer that holds one 80 ms packet cannot absorb a 265 ms burst, so
  `EchoLinkClient.defaultJitterBuffer` targets 280 ms with a 160 ms floor and a
  500 ms ceiling, and adapts within that range.

- **A stream clock that ignored real time.** The subtlest of the four, and the
  one that made the others look unfixable. EchoLink's RTP timestamp is always
  zero, so the sequence number is the only ordering signal — but **the sender
  does not skip sequence numbers across a pause.** It stops, then resumes with
  `seq + 1`. The same live session shows 339 packets spanning eleven silences
  of half a second or more with exactly *one* sequence discontinuity.

  A sequence-only clock therefore advances 80 ms across a four-second silence,
  while `JitterBuffer`'s playout grid advances in real time. After the first
  pause the two have diverged for good, every arriving frame looks like it
  belongs in the distant past, and the buffer degenerates into a pass-through
  with no jitter protection at all — which is why making it deeper stopped
  helping. `EchoLinkSequenceExpander.expand` now takes the arrival time and
  treats a wall-clock pause as a talkspurt boundary.

- **A pause threshold set inside the normal rhythm.** Having added the arrival
  clock, the question became what counts as a pause — and the first answer,
  two packets' worth, was wrong. A tunnelled path delivers a *clump* of two or
  three packets every ~200 ms, so gaps of that size are the rhythm, not a
  silence. Measured across two sessions, the two populations are sharply
  separated with nothing in between:

      bunching   max 218 ms and 375 ms
      silences   min 806 ms and 582 ms

  At 240 ms the threshold sat inside the bunching range and re-latched on
  ordinary delivery — three spurious re-latches in a 60-second session, each
  un-priming the buffer and costing a re-prime, audible as a short drop in
  otherwise clean audio. It is now 480 ms, in the empty valley. The buffer
  floor moved to 240 ms for the same reason: adaptation can drive the target
  down to the floor, and a floor below the arrival rhythm starves on every
  clump.

Depths are tuning values, not protocol facts, and they buy latency to pay for
continuity. `--jitter-ms` sets the target for one run: raise it if the audio
still drops out, lower it if the delay is annoying. A direct (non-proxied) path
would not need anything like this much — an argument for direct mode, not
against the default.

### The M3 sign-off checklist — ✅ signed off 2026-08-13

Same shape as the M2 checklist in §5.

- [x] Proxy login accepted.
- [x] Directory login accepted.
- [x] `*ECHOTEST*` answered the opening SDES.
- [x] **Audio transmitted, and heard back intelligibly in the echo** — the
      milestone. It took several rounds of tuning to get there; §"If the audio
      grinds" above is what those rounds found.
- [x] Clean teardown.

Two rows the sign-off did not report on separately, left open rather than
ticked on the strength of the session having gone well:

- [ ] Inbound talkspurts reported, with no stutter across a boundary. The
      stutter *was* chased and fixed (EL-7's arrival clock and pause
      threshold), so this is very likely fine — but "the QSO sounded good" is
      not the same observation.
- [ ] SF-1 watchdog cut transmission at its limit. Not exercised: it fires
      after three minutes and no over ran that long. The same check passed for
      M2 against IAX2, and the watchdog lives in `RadioCore` rather than in
      either protocol kit, so this is a re-confirmation rather than an
      untested path.

### 9.1 `--list` — the station directory (EL-11)

Downloads the directory's station list, prints it, and exits without starting a
QSO. Needs the account login, so it cannot be combined with
`--no-directory-login`.

```sh
swift run hamvoip-cli echolink \
    --proxy <proxy host> \
    --directory-server <directory server IPv4> \
    --list | less
```

**No `--peer` and no `--node`.** `--list` stops after the directory login and
never opens a node session, so it does not need a node to reach — which matters
for the first live run: if it had to reach one, a station-list query could fail
for a reason that is not about the station list.

One station a line, tab-separated: callsign, node number, status, address,
location. Around 6500 lines, so pipe it. Lines beginning `#` are the server's
own trailing notices and the summary count.

### Validated on air, 2026-08-13

```
# EchoLink Server v2.6.159
# ECHO1: Sydney, AU
# 6386 station(s), 3 notice(s); the server declared 6389.
Link down: local request
```

Everything read off the capture held against a live server: the second `OPEN`,
the `f0` CR request, the framing, and the grammar. **6386 + 3 = 6389, matching
the server's own declared count** — and since the parser treats a count
mismatch as an error, a list that prints at all is one that arrived whole.

This is a **different** list from the captured one (6389 entries against 6444,
a day apart), so the format is no longer evidenced by a single download. The
three notice rows came back in the same shape the capture showed
structurally — a server version banner, a blank, and a server identification —
which is what `notices` was built for.

The list is deliberately **not** fetched during a normal `connect`: it is 433 kB
and nothing on the path to a QSO needs it.

## 10. `HAMVOIP_TRACE` — frame tracing

Set `HAMVOIP_TRACE=1` and `IAX2Call` writes one line per received full frame to
**stderr**, plus the reason any call leg terminates:

```sh
HAMVOIP_TRACE=1 hamvoip-cli iax2 --host … --node … --username … --no-audio
```

```
RX type=IAX subclass=0x8 payload=31B      AUTHREQ
RX type=IAX subclass=0x7 payload=17B      ACCEPT
RX type=Control subclass=0x3 payload=0B   RINGING
RX type=IAX subclass=0xb payload=0B       LAGRQ
RX type=Control subclass=0x4 payload=0B   ANSWER
TERMINATE remote HANGUP (Normal call clearing, cause code 16)
```

It is deliberately crude — no decoding, no IEs, stderr only, so it composes with
`grep` and cannot disturb the TUI on stdout. For anything needing the octets,
cut a capture and use `scripts/pcap-to-fixture.py --summary`, which decodes
properly and leaves a provenance record.

**Why it exists.** IAX-12 spent an afternoon chasing a Web Transceiver session
that ended the instant it connected. Every client-side message was misleading:
the session reported `--duration elapsed` (a `try?` swallowing the timer task's
cancellation), the node's `Max retries exceeded` pointed at LAGRQ, and an
Asterisk `Peer did not understand our iax command '255'` NOTICE looked like a
protocol gap. All three were red herrings — the real cause was the CLI's own
task group ending on the first completed loop, which under `--no-audio` is
immediate. Tracing what actually arrived, and why the call ended, is what
separated them. Reach for it before theorising.

## 11. Web Transceiver — connecting to a node that has never heard of you

Web Transceiver (WT) is the AllStarLink route for an operator with a portal
account but no node of their own. The node owner enables it per node; you need
no entry in anyone's `iax.conf`. This is the second half of FR-1.3 (IAX-12).

It is two steps: get a token from the portal, then place an ordinary IAX2 call
presenting it.

### 11.1 Get a token

```sh
export ALLSTARLINK_PORTAL_PASSWORD='…'     # or omit it and type it at the prompt
TOKEN="$(hamvoip-cli wt-token --callsign "$CALLSIGN")"
```

Only the token reaches stdout, so it substitutes straight into step 11.2;
everything else — the prompt, where the password came from, any complaint —
goes to stderr. The password is your **allstarlink.org portal** password, not a
node secret and not the static `allstar` secret the call itself presents.

The token is 12 lowercase hex characters and is **stable across calls** — it
changes only when you change your portal password (AllStarLink, [community
thread 24925](https://community.allstarlink.org/t/documentation-for-the-web-transceiver-authentication-api-api-v2-auth-wt-legacy/24925)).
So it is a credential with a real lifetime, not a nonce — store it, and fetch
another when the operator changes that password. (AllStarLink suggest logging in
at app launch or per connection regardless, on the grounds that a future
replacement API may rotate tokens more often. Cheap advice to take if you are
already asking for a password; not a reason to hold one you would otherwise
discard.)

<details>
<summary>The request underneath, for reference (IAX-13)</summary>

```sh
curl -s -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$CALLSIGN" --arg p "$PORTAL_PASSWORD" \
          '{username:$u,password:$p}')" \
    https://allstarlink.org/api/v2/auth-wt-legacy
```

```json
{"status":"OK","auth":1,"token":"1b59df18107e"}
```

`username` is your callsign — allstarlink.org portal logins are
callsign/password, and both key names are exact. On failure `status` is `ERR`
and `msg` distinguishes `Invalid JSON payload`, `Invalid JSON fields` and
`login failed`; the three arrive as separate `WebTransceiverTokenError` cases,
because a wrong password is fixed by retyping it and a changed endpoint is not.

The rest of the contract, as AllStarLink document it in thread 24925 — this was
confirmed against what we had observed, and it added three things observation of
a successful login could not have found:

| | |
|---|---|
| Path | `/api/v2/auth-wt-legacy.php`. The extensionless form used above works and is what the library sends. |
| Request | `username`, `password`, and an optional **`cookie`** — an opaque value echoed back in the response. Currawong and this CLI send no cookie; nothing here needs to correlate a login with a browser session. |
| Response | `status` (`OK`/`ERR`), `auth` (`1`/`0`), `token`, `cookie` if one was sent, and `msg` only when `status` is `ERR`. |
| Other methods | HTTP 405. |
| Token lifetime | Changes only when the operator changes their portal password. |

The fetch lives in `IAX2Kit` behind `WebTransceiverTokenSource`
(`AllStarLinkPortalTokenFetcher` is the one implementation) so the app can
reach it too, and so the expected replacement for this `legacy` endpoint —
ASL3-Manual #229, and OQ-10 caveat 2 — can arrive as a second conformance.
`--endpoint` points the command at a successor without a rebuild — it must be
`https://`, and both the command and the library refuse anything else before the
password is sent.

</details>

⚠️ The endpoint is named `legacy`, and AllStarLink's ASL3-Manual issue #229 sits
under a project called "WebTransceiver Login API Replacement". As of 2026-08-18
an AllStarLink administrator states the replacement "isn't ready even for beta
testing yet" (thread 24925) — no timeline, and no description of what it will
be. So this is the route, and what is documented above is what to build against.
The token fetch sits behind its own seam anyway, which is all the preparation a
replacement of unknown shape can usefully be given.

### 11.2 Place the call

```sh
hamvoip-cli iax2 \
    --host "$(dig +short "$NODE.nodes.allstarlink.org")" --port 4569 \
    --node s \
    --username allstar-public \
    --calling-name "$TOKEN" \
    --calling-number "$NODE" \
    --callsign "$CALLSIGN"
# IAX2_SECRET=allstar
```

Four of those are not what you would guess, and each was established by
observation against a live node:

| What | Value | Why |
|---|---|---|
| `--node` | `s` | WT never dials the node number. It calls the Asterisk start extension and the node answers, like a phone call in. Dialling the node number gives *No such context/extension*. |
| `--username` | `allstar-public` | A shared account, not your callsign. A callsign here draws a bare REJECT with no CAUSE and no challenge. |
| secret | `allstar` | Static, and the same on every ASL3 node — it ships in `iax.conf`. It is not your token and not your portal password. |
| `--calling-name` | the **token** | The node passes CALLING NAME to allstarlink.org, which resolves it to your callsign. This is the identity proof. |
| `--calling-number` | the **node number** | Becomes `NODENUM` on the node and selects which node you attach to. |

`--calling-name` exists precisely for this: `--callsign` is upper-cased and
character-checked, which is right for a callsign and would corrupt a
lowercase-hex token.

The node answers after roughly ten seconds — it plays "connected to node" and
speaks the node number before attaching you. That delay is normal and is not a
stall.

### 11.3 Checking it worked

A WT client appears in the target node's link list **by callsign**, so the
connection is verifiable from outside without access to the node:

```sh
curl -s "https://stats.allstarlink.org/api/stats/$NODE" \
    | jq -r '.stats.data.nodes' | tr ',' '\n' | grep "$CALLSIGN"
```

```
TVK1CPM
```

That is the check to trust. A client-side "CONNECTED" is **not** sufficient: the
node answers on its failure path too, before hanging up, so an unauthorised call
still reports as connected for a second or so. If a call drops after about a
second, the authority check failed; if it holds, you are attached.

## 12. `experiment capture-swap` — pulling the microphone out mid-over (RC-14)

**What it is for.** Everything else in the capture path is settled by unit
tests that drive the tap body through its pointer entry point with no hardware
at all (AU-5). One claim cannot be: *the capture chain is rebuilt when the input
device changes underneath it.* That is a claim about what `AVAudioEngine` does
on a real machine, so it is measured on one — the same way `oq5` and `oq7`
measure things a document cannot answer.

Local, not on air. Nothing is transmitted and no node is dialled. It opens the
microphone (§1 covers the macOS permission) and changes the **system's default
input device**, which it restores on the way out, including on `^C`.

```sh
hamvoip-cli experiment capture-swap --list          # what it can see
hamvoip-cli experiment capture-swap --swaps 8       # capture, then swap 8 times
hamvoip-cli experiment capture-swap --target "MacBook Air"
```

### What it is measuring

Before RC-14, `startCapture` snapshotted the input device's format once — the
converter's source rate and the tap's channel stride came from it — and nothing
rebuilt them. `AVAudioEngineConfigurationChange`, which is exactly what changing
the default input device produces, left a live tap resampling from a rate the
device no longer ran at and striding by a channel count the buffers no longer
had. A stride of 2 held over a de-interleaved mono buffer reads past the end of
channel 0's allocation: an out-of-bounds read on the real-time audio thread.

Worth running under AddressSanitizer, which catches such a read at the instant
it happens rather than leaving it to be inferred from a crash somewhere else
later — that is `BU-23`'s question:

```sh
swift build -Xswiftc -sanitize=address
ASAN_OPTIONS=detect_leaks=0 .build/debug/hamvoip-cli experiment capture-swap --swaps 8
```

### Reading the result

| Line | What it means |
|---|---|
| `rebuilds` | swaps that moved the input rate or the channel stride. **Zero is a legitimate result** — see below |
| `failures` | rebuilds where CoreAudio would not build a converter for the new device. Each ended capture; any non-zero value wants explaining |
| `+n frames` | must be non-zero after every swap. A zero is capture that stopped and did not come back — the probe fails on it |
| `dropped` | ring overruns. Should be zero, and it accumulates across rebuilds on purpose, so a device swap cannot quietly reset it |

### Result — melchior, 2026-08-28, macOS 26.5.1 ✅

Recorded in `experiment-data/rc14-capture-swap.txt`. Three runs, all under ASan:
two of eight swaps between a Logitech StreamCam and the built-in microphone, and
a third of four against a Bluetooth headset that turned up later in the evening
and is the one that explains the other two.

**1. As shipped: 550 frames delivered, 0 rebuilds, 0 failures, 0 dropped, ASan
silent.** Zero rebuilds is the finding, not the probe failing to fire — and a
third run, below, is what explains it.

**3. A Bluetooth headset joined the machine between runs**, which is what
established the actual rule. A **fresh** engine on the AirPods reports
**24000 Hz mono**, where the StreamCam gives 44100 Hz stereo and the built-in
44100 Hz mono — so the input node's rate plainly *does* differ between devices,
which run 1 alone would have suggested it did not. But swapping to those same
AirPods **under a running capture** reports `44100 Hz, 1 ch`: the engine's rate,
the new device's channel count.

So the rule on macOS 26.5 is:

> `AVAudioEngine` fixes its input rate when the input audio unit is
> instantiated, and a device change afterwards does not move it — CoreAudio
> resamples into the rate the engine already chose. Only the **channel count**
> follows the device.

Which settles what can go stale under a running capture here: not the rate, and
not the stride either, since every device is de-interleaved and de-interleaved
buffers stride by 1 whatever the channel count. **So the sharp end of RC-14 —
the out-of-bounds read — is not reachable on this platform**, and the rebuild
correctly never fires. It is reachable where the graph is rebuilt under the
caller rather than resampled into, which on iOS is what this notification
accompanies. That is evidence worth carrying into `BU-23`, where the same
reasoning is written out.

This is also why the app rebuilds its whole pipeline rather than reusing one
across a session (`Currawong`'s `AudioPipelineIO`): a rate is a decision an
engine makes once.

**2. With `CaptureChain.matches()` temporarily forced to `false`**, so that every
swap takes the rebuild path on real hardware: **530 frames, 8 rebuilds, 0
failures, 0 dropped, ASan silent.** The tap comes down and goes back up, the
caller's `onFrame` keeps being called across it, and the cost is about 25 ms of
audio per rebuild — the ~20 frames' difference between the two runs. The patch
was reverted immediately; it is not in the branch.

### One thing the probe itself taught

`AVAudioEngine().inputNode.outputFormat(forBus: 0)`, written as a single
expression, **segfaults** in `AVAudioIONodeImpl::GetOutputFormat`: an
`AVAudioNode` does not keep its engine alive, so the temporary is released
before the format is read. The crash is a bad pointer dereference with garbage
high bits, which macOS reports as a *possible pointer authentication failure* —
the same crash shape as `BU-23`, from nothing more exotic than a use-after-free.
The engine is held in a local for the duration of the call, and must be.

## 13. `experiment input-warm-up` — the silence a cold device delivers (BU-22)

**What it is for.** Currawong's `BU-22`: the first over after the input device
spins up is silent, and *frames arrive the whole time* — they are simply all
zero — so nothing above the device can tell it from an operator saying nothing.
This measures the gap between the first frame and the first frame that carries
audio, before and after a warm-up.

Local, not on air. It opens the microphone (§1 covers the macOS permission) and
reports counts and timings only; no audio is written anywhere.

```sh
hamvoip-cli experiment input-warm-up                       # warm-up, gap, then an over
hamvoip-cli experiment input-warm-up --no-warm-up          # the fault on its own
hamvoip-cli experiment input-warm-up --warm-up 0.5         # a warm-up shorter than the silence
```

### It needs a cold device, and that is the hard part

A permanently powered input shows nothing at all. On melchior, 2026-08-28, the
Logitech StreamCam delivered room noise **in its first buffer at 283 ms** while
a Bluetooth headset on the same machine, minutes later, delivered **1574 ms of
exact zeros**. Make the headset the default input and leave the machine alone
for twenty minutes or so; anything that opens the microphone in the meantime —
including a previous run of this command — warms the device and spends the
measurement.

### Result — melchior, 2026-08-28 ✅

Recorded in `experiment-data/bu22-input-warmup.txt`.

```
warm-up (0.8 s):               35 frames,  0 with audio, first frame 198 ms, first audio NEVER
over, 0.8 s after the warm-up: 75 frames, 67 with audio, first frame 134 ms, first audio 233 ms
```

**The warm-up never saw audio itself** — 35 frames, every one of them zero, for
its whole 800 ms — and the over that followed carried audio 98 ms after its
first frame, against roughly 1400 ms cold. So **it is the opening that wakes the
device**, not holding it open until audio appears, which is the premise
Currawong's warm-up hold was chosen on and had until now only an argument for.

**The second device, 2026-08-29: a TIDRADIO Q2L, which does not have the fault
at all.** Audio in the *first frame* from every starting state tried — 20 minutes
idle as the default input (278 ms / 279 ms), 10 minutes idle with the default
moved away so macOS released the audio profile (268 / 268), and a genuine power
cycle measured within a second of the device reappearing (265 / 265).

So **the fault is not "Bluetooth"** — it is inputs that power their microphone
down between uses, and a speaker-mic built for PTT keeps its ready. This one
sits with the USB webcam. Two things follow for anyone running this probe:

- **A device that shows no fault has not confirmed anything.** It cannot
  exercise a hold chosen to fix one, so Currawong's number remains settled by the
  single AirPods measurement. Only an AirPods-class input tests it.
- **Getting a genuinely cold device is the hard part, and idling may not do it.**
  Twenty minutes idle as the default input left the Q2L wide awake, as did ten
  with the default moved elsewhere. Where the device will not go cold on its own,
  power-cycling it is the reliable way, and the measurement has to happen before
  anything else opens the input. `kAudioDevicePropertyDeviceIsRunningSomewhere`
  tells you nothing is holding it; the nominal sample rate does not — a Bluetooth
  input reports its HFP rate even while idle.
