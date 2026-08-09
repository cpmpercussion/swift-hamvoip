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
