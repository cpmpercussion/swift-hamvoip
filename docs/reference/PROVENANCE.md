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
