# Provenance log

A running record of clean-room boundary calls (LP-1, LP-2). The point of this
file is that if provenance is ever questioned, the answer is written down at
the time the decision was made rather than reconstructed years later.

Add an entry whenever a source is consulted that is not plainly and obviously
"a published specification we wrote code from".

---

## 2026-08-09 — M17 spec appendix contains C source (M17-2)

**Task:** M17-2, base-40 callsign encoding.

**Source consulted:** M17 Protocol Specification, Part I — Air Interface,
v2.0.4, `https://spec.m17project.org/files/M17_spec.pdf`, Appendix A.
Sections A.1 (Table A.1, the alphabet), A.2 (encoding rules), A.3 (Table A.2,
reserved address ranges), and **A.4/A.5, which are illustrative C encoder and
decoder listings printed inside the specification document itself**.

**The call:** A.4/A.5 were read, and used to cross-check the direction of the
base-40 digit ordering against the prose and the worked example in A.2.

**Why this is inside LP-1:** LP-1 permits "published specifications". The C
listings are part of the published specification document, not a separate
implementation project — they sit on the page between the prose and the
worked example, and serve the same purpose. This is materially different from
reading a codebase that happens to implement the spec.

**What was NOT consulted:** no implementation repository was opened —
not M17-Project/libm17, not DroidStar, not mvoice. The encoding was
independently verified against the spec's own worked example
(`AB1CD` → `0x9FDD51`), which is reproduced as a hand-computed test.

**Residual risk:** low. The encoding is a base-40 positional number over a
39-symbol alphabet; there is essentially one way to write it, and the
implementation is verified against a spec-published test vector rather than
against any implementation's behaviour.

**Note for future M17 tasks:** the same appendix convention likely applies to
other parts of the M17 spec. Reading C **printed in the specification PDF** is
acceptable. Reading C **from a project repository** is not, even when that
project is the M17 Project's own. Keep the distinction sharp.

**Spec facts established here** (reused by M17-3, M17-4, M17-5):

- Alphabet, index → character: `0` = space (and any invalid character),
  `1–26` = `A–Z`, `27–36` = `0–9`, `37` = `-`, `38` = `/`, `39` = `.`
- Maximum callsign length: 9 characters (40⁹ − 1 < 2⁴⁸ − 1)
- Wire byte order: big-endian, stated explicitly in A.2
- Encoding direction: first character is the least significant base-40 digit
- Reserved addresses (Table A.2): `0x000000000000` reserved;
  `0x000000000001`–`0xEE6B27FFFFFF` standard callsigns;
  `0xEE6B28000000`–`0xFFFFFFFFFFFE` extended/application use, not decodable
  as text; `0xFFFFFFFFFFFF` = BROADCAST, valid only as a destination
- Table A.1's ASCII-hex column misprints `/` and `.` as `0x3F`/`0x3E`
  (actually `?`/`>`). A document error; it does not affect the encoding,
  which depends only on the character ordering.

---

## 2026-08-09 — The reflector protocol is not in the published PDF (M17-3)

**Task:** M17-3, reflector control protocol and connection FSM.

**The problem:** the specification hosted at `https://spec.m17project.org/` —
"M17 Protocol Specification, Part I - Air Interface", v2.0.4, 21 January 2026,
the document M17-2 worked from — contains **no IP networking chapter at all**.
Searching its text for `CONN`, `ACKN`, `reflector`, `UDP`, `17000` and
`Internet` returns nothing; the document ends at the application layer, and
`https://spec.m17project.org/files/` lists `M17_spec.pdf` as its only file.
There is no "Part II" PDF at that host, and the M17 Project's specification
page links only to a GitHub repository.

**Source consulted:** the M17 Protocol Specification's chapter "M17 Internet
Protocol (IP) Networking", published at

    https://m17-protocol-specification.readthedocs.io/en/latest/ip_encapsulation.html

That host now returns "Project not found", so the text was read from the last
Internet Archive capture of the published page:

    https://web.archive.org/web/20251008220102/https://m17-protocol-specification.readthedocs.io/en/latest/ip_encapsulation.html
    (2025-10-08, Sphinx build revision fa272742)

**The call:** an archived rendering of the project's own published
specification is a published specification. It was cross-checked against the
2022-12-28 capture of the same page; the "Standard IP Framing" and "Control
Packets" tables are identical in both, so the layouts have been stable for at
least three years and the archived copy is not a stale draft.

**Why this is inside LP-1:** LP-1 permits "published specifications". This is
the same specification document as the PDF — a different chapter of it, from
the period when it was published as HTML rather than as a PDF. It is prose and
field tables, not anyone's implementation.

**What was NOT consulted:** no implementation was opened. Specifically not
`M17-Project/libm17`, not `M17-Project/pyM17`, not mrefd, not DroidStar, not
mvoice, not `M17Gateway`, not `go-m17-relay`, not `jancona/m17` — several of
which appeared in the search results that located the specification page, and
all of which were left unopened. The rule from the M17-2 entry was applied
unchanged: C in the specification document is fine, C in a project repository
is not. Here the question was slightly different — a *specification* in a
project repository — and even that was avoided, because the archived published
rendering made it unnecessary.

**Spec facts established here** (for M17-4 and M17-5):

- UDP port 17000, "recommended but not required". Big endian throughout.
- Control packet layouts (Tables 28-33). Byte offsets, total sizes:
  - `CONN` 11 = magic(4) + 'From' address(6) + module ASCII `A`-`Z`(1)
  - `ACKN` 4 = magic only. **No address field.**
  - `NACK` 4 = magic only. **No address field.**
  - `PING` 10 = magic(4) + 'From' address(6)
  - `PONG` 10 = magic(4) + 'From' address(6)
  - `DISC` 10 = magic(4) + 'From' address(6), *or* 4 = magic only, the latter
    being the acknowledgement of a `DISC`
- Stream packet (Table 27): magic `"M17 "` (`0x4D313720`, trailing space),
  SID(2), LICH(30), FN(2), payload(16), CRC16(2). **The LICH width is the one
  place where this document has been overruled by observation** — see judgement
  call 1.

**Judgement call 1 — the stream packet is 56 bytes, not 54. → OVERTURNED
2026-08-11 by a live reflector: it is 54.** Table 27 gives LICH as **240 bits**
and names its contents as "dst, src, streamtype, META field, CRC16", which is
exactly the 30-byte Link Setup Frame of Part I Table 3.1 *including* its own
CRC. 4 + 2 + 30 + 2 + 16 + 2 = 56. A 54-byte frame is sometimes quoted for
M17-over-IP, and the difference is precisely whether the LSF's own 2-byte CRC is
present. The specification's stated 240 bits was followed, and flagged for
M17-4 to settle against a capture.

It was settled (OQ-7): 52 consecutive stream datagrams from a live reflector
were **54 bytes**, with FN counting at offset 34 and the trailing CRC16
(polynomial `0x5935`, init `0xFFFF`) valid over the preceding 52 bytes in every
one. The LSF CRC is not transmitted. `M17StreamPacket` now implements 54 with a
28-byte LICH. Evidence: the OQ-7 row of `DEVELOPMENT-PLAN.md` and `docs/CLI.md`
§7.

**A second, smaller gap in the same area, found while implementing the CRC
(M17-4).** The specification states the CRC's polynomial and initial value and
stops there. A CRC is not determined by those two numbers alone: bit order and
the presence of a final XOR also have to be fixed, and the text we hold fixes
neither. This was resolved the same way — by measuring. Exactly one of the
eight combinations of reflected input, reflected output and final XOR validates
the captured frames, and it validates all 52 of them; the other seven validate
none. `M17CRC16` therefore documents MSB-first, no reflection, no final XOR as
an **observation**, not as a quotation from the document.

Same failure mode as the LICH width, and the same argument for OQ-8: the
specification is written as a companion to implementations that already agree
on these details, so it under-specifies exactly where an independent
implementer needs it most.

**What this says about the source, which is the point of this file:** the
archived chapter is accurate about field *order*, field *meanings* and every
control packet — all verified — and wrong, or at least misleading, about one
width. That is the expected failure mode of a specification whose reference
implementations are the real authority, and it is an argument for the OQ-8
question (keeping a local copy) rather than against it: the divergence is only
citable because the text we implemented from is pinned. It is also the reason
the two remaining judgement calls below stay flagged rather than being quietly
promoted to fact.

**Judgement call 2 — the module appears twice in `CONN`.** Tables 28/31/32/33
describe the 6-byte address field as the "'From' callsign including module in
last character (e.g. \"A1BCD D\")", while `CONN` byte 10 separately carries the
"module to connect to". The specification does not say whether a plain client's
'From' module should be set, or to what. Rather than guess, `M17Address` takes
an optional module and encodes the text as `"<callsign> <module>"` exactly as
the example shows, and `M17ReflectorClient` leaves it unset by default. Both
behaviours are covered by tests, so whichever a live reflector turns out to
want is a one-argument change.

**Judgement call 3 — no timer values exist.** The specification names `PING`
as the keepalive but states no interval, and no timeout for `CONN`. The 5 s
connect and 30 s keepalive deadlines in `M17ReflectorClient` are local policy,
documented as such at their definitions, and injectable.

**Residual risk:** low for the control packets — six fixed-layout packets with
no options, each verified byte for byte against a hand-built fixture. Low for
the stream frame size, which was the moderate risk here until a live reflector
settled it at 54 bytes; what remains is that the observation is one over from
one transmitting client, so a second reflector disagreeing would reopen it.

---

## 2026-08-12 — EchoLink protocol knowledge from captures of a third-party client (OQ-9)

**Task:** None open. OQ-9 is unresolved and Phase 6 is blocked; this entry
records a boundary call made while *gathering* the evidence OQ-9 asks for, not
while writing code. It is logged now, ahead of any Phase 6 task, because this
file's stated purpose is to record decisions at the time they were made rather
than reconstruct them later.

**Source consulted:** three packet captures of the maintainer's own EchoLink
sessions, 2026-08-12, taken with `tcpdump` on macOS while operating the
maintainer's own station through EchoHam 2.31, a third-party macOS client that
is not ours and whose source was not read. The captures are
held outside both repositories, in the workspace's `experiment-data/`, and
their SHA-256s are recorded in `echolink-oq9-result.txt` alongside them. Peers
observed include `*ECHOTEST*`, which identifies itself on the wire as
"thebridge V 0.81".

**The call:** the protocol facts — proxy framing, the login challenge-response,
the RTP and GSM-06.10 packing — were derived from these captures alone, by
decoding the bytes. This is candidate (c) of OQ-9. Two aspects need justifying:

1. The captures record a **third-party client's** behaviour, not our own. That
   is unavoidable rather than convenient: candidate (c) necessarily means
   someone else's client for as long as no first-party client exists, which is
   precisely the situation Phase 6 is meant to end.
2. One observed peer **is thebridge**, which LP-2 names as forbidden.

**Why this is inside LP-1 and LP-2:** LP-2's own text permits the named
implementations to "be referenced for behavioural observation only". Observing
what thebridge and EchoHam put on the wire is exactly that, and is categorically
different from reading their source — the same distinction the M17-2 entry above
draws between C printed inside a specification and C in a project repository.
LP-1 independently permits "packet captures of the author's own sessions".

**What was NOT consulted:** no implementation source, at any level — not
SvxLink, EchoLib, thebridge, MicroLink, DroidStar, or any other. No prose
protocol write-ups either. Notably, **the EchoLink proxy protocol document that
LP-1 expressly permits was also not read**: the 9-byte framing was derived from
the captures alone, and corroborated by the fact that both handshake-bearing
captures decode under it with zero leftover bytes in either direction. The
derivation is therefore independent of any document, permitted or otherwise.

**On the digest test:** the login construction —
`MD5(password ‖ nonce-as-8-ASCII-characters)`, emitted as raw 16 bytes — was
settled by offline arithmetic over data already present in the captures: 198
candidate combinations hashed and compared against two recorded (nonce, digest)
pairs from two different proxies. Exactly one combination reproduces both. No
live server was probed and nothing was guessed at against a real proxy. The
password proved to be the literal string `PUBLIC`, a published public-proxy
convention rather than a secret recovered from anywhere.

Worth recording because three of the four obvious assumptions were wrong: the
order is password-first, not nonce-first; the nonce is hashed as its eight ASCII
characters rather than the four bytes they spell; and the digest goes on the
wire as raw binary, which is the **opposite** of what OQ-5 settled for IAX2's
`MD5_RESULT` (lowercase 32-character hex). The two protocols demonstrably do not
agree here, and an implementer assuming they do would find the failure silent.

**Residual risk: moderate — higher than the M17-2 entry's.** Three reasons,
recorded so they are not rediscovered as surprises:

- **RFC 3550 does not describe this protocol as implemented.** The observed RTP
  version bits are 3, not 2. Code written faithfully from the RFC would not
  interoperate. The captures are the primary source here and the RFC is
  background reading — materially weaker footing than IAX2 has with RFC 5456,
  and the easiest thing to overstate when writing Phase 6.
- **Captures record what happened, never what is permitted.** Four independent
  peers all sent four GSM frames per packet; that is strong evidence about
  practice and silent about the legal range.
- **Single-peer captures cannot separate protocol properties from one client's
  habits.** The first capture, against one peer, yielded two confident and wrong
  conclusions — that SSRC is always zero and that sequence numbers start at zero.
  A later capture spanning four peers corrected both: one peer sent a non-zero
  SSRC, and inbound sequences ran from arbitrary origins. Any future EchoLink
  capture work should span multiple peers for this reason.

**Not resolved by this entry:** OQ-9 itself. Which of candidates (a)–(d) count
as permitted sources remains the maintainer's decision. Candidate (d), prose
write-ups, carries a laundering risk this entry takes no position on: with no
published specification, most such prose derives from the very implementations
LP-2 forbids, and whether a third party's summary of thebridge's source counts
as "behavioural observation" or as the source at one remove is a reading of LP-2
that only the maintainer can make.

**A note on what this entry omits:** it names no capture filenames or paths,
pointing at `echolink-oq9-result.txt` for the SHA-256s instead. This departs
from `Tests/FIXTURES.md`, which names its source captures by path. The reason is
that one of these captures contains a live account credential in cleartext and
another contains the full EchoLink directory — 6548 third-party callsigns and
6261 IP addresses. Nothing committed to this repository should help locate them.

---

## 2026-08-12 — Fixture-bearing captures that cannot be named (EL-1/EL-2)

**Task:** EL-1, and the rule EL-2 will work under. Logged now rather than when
EL-2 cuts its fixtures, because the decision was made now.

**The problem.** `Tests/FIXTURES.md` identifies a `live-*.hex` fixture's source
capture by path, and the workspace's `experiment-data/README.md` said a capture
that yields a fixture moves to the workspace root where such captures live.
Both rules assume the capture's name is safe to write down. For the three
EchoLink captures it is not: one holds a live account credential in cleartext
and another the entire EchoLink directory, 6548 third-party callsigns and 6261
IP addresses. A path in a committed file is a signpost to the data.

**The call (maintainer, 2026-08-12).** The filing rule gains an escape hatch: a
capture holding data that is or could be private — a credential of ours, or
third-party traffic — **stays in `experiment-data/` whether or not a fixture
was cut from it, and is cited by SHA-256 rather than by path.** In doubt it
stays. The cost of the hatch is one inconsistent convention; the cost of the
other mistake is somebody else's data on GitHub.

This extends the call the OQ-9 entry above already made for prose, to captures
that bear fixtures. It is the same reasoning, not a new one.

**What did not change, and is worth being explicit about**, because "cited by
digest" could be misread as a weaker audit trail: the fixture still records the
command that regenerates it, octets are still never edited, the `[n]` index
still makes an omitted frame visible, and only the peer's half is checked in
unless our own half is under test. A digest identifies the source capture
*more* precisely than a filename does — it detects a substituted file, which a
path cannot. What is lost is only the convenience of knowing where the file
sits, which is exactly the property that was dangerous here.

**Mechanised, not left to discipline.** `pcap-to-fixture.py --transport tcp`
writes `<capture>` and the digest into the recipe, and `--name-capture` has no
effect in that mode, so a TCP fixture cannot accidentally carry a path. The
same script refuses to emit type `0x02` frames without an explicit override —
those are the frames carrying the password one way and the directory the other.
Both were added in EL-1 (PR #16); neither depends on anyone remembering.

**Residual risk: low, and it is human rather than technical.** The guards cover
the EchoLink proxy path specifically. A future capture of some other protocol
carrying third-party traffic gets no automatic protection, and the hatch will
only be applied if whoever files it reads the rule. That is why the rule is
stated in three places — `experiment-data/README.md`, the workspace `CLAUDE.md`
and `Tests/FIXTURES.md` — rather than only where it was first needed.
