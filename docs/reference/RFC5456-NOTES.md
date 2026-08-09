# RFC 5456 (IAX2) — Implementation Notes

**What this is.** A working reference for implementing an IAX2 client in
`swift-hamvoip`. Every constant, table, and rule below is transcribed from
**RFC 5456, "IAX: Inter-Asterisk eXchange Version 2"** (Spencer, Capouch, Guy,
Miller, Shumard; February 2010; Independent Submission, Informational). Each
table and rule cites the RFC section it came from.

**Sole source.** This document was written clean-room from RFC 5456 alone. No
Asterisk source, no `iaxclient`, no third-party write-ups were consulted. Where
the RFC is silent, self-contradictory, or underspecified, this document says so
explicitly with the marker **RFC ambiguous:** rather than filling the gap from
an implementation. Do not "fix" those markers by looking at Asterisk — resolve
them by testing against a real peer and recording the observed behaviour
separately, clearly labelled as observation, not specification.

**Authority.** If this document and RFC 5456 ever disagree, **the RFC wins**.
Re-read the cited section before changing code on the strength of a line here.

**Status of the RFC itself.** RFC 5456 is Informational, not Standards Track,
and the IESG note disclaims fitness. It is nevertheless the only normative
written specification of IAX2 and is what we code against.

Well-known UDP port: **4569** (§3, §11). One UDP association carries both
signalling and media (§1.1, §3).

---

## 1. Full frame format (§8.1.1)

> "The standard Full Frame header length is 12 octets." (§8.1.1)

> "Full Frames are sent reliably, so all Full Frames require an immediate
> acknowledgment upon receipt. This acknowledgment can be explicit via an 'ACK'
> message (see Section 8.4) or implicit based upon receipt of an appropriate
> response to the Full Frame issued." (§8.1.1)

Bit layout, from Figure 5 (§8.1.1):

```
                     1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|F|     Source Call Number      |R|   Destination Call Number   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            time-stamp                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    OSeqno     |    ISeqno     |   Frame Type  |C|  Subclass   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
:                             Data                              :
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Field-by-field (§8.1.1):

| Byte offset | Bit offset (from MSB of that byte) | Width | Field | Notes |
|---|---|---|---|---|
| 0 | bit 0 | 1 bit | `F` | 1 = Full Frame, 0 = not a Full Frame |
| 0–1 | bits 1–15 | 15 bits | Source Call Number | call number *this* sender uses for the call |
| 2 | bit 0 | 1 bit | `R` | 1 = this is a retransmission, 0 = first transmission |
| 2–3 | bits 1–15 | 15 bits | Destination Call Number | the remote peer's source call number |
| 4–7 | — | 32 bits | Time-stamp | ms since first transmission of the call |
| 8 | — | 8 bits | OSeqno | outbound sequence number |
| 9 | — | 8 bits | ISeqno | inbound sequence number |
| 10 | — | 8 bits | Frame Type | see §4 below |
| 11 | bit 0 | 1 bit | `C` | subclass encoding selector |
| 11 | bits 1–7 | 7 bits | Subclass | see §6 below |
| 12… | — | var | Data | IEs (for IAX frames) or media payload |

**Byte order.** The RFC uses the standard RFC bit-diagram convention (bit 0 is
the most significant bit of the first octet transmitted), so all multi-octet
fields — the two call-number words, the 32-bit time-stamp, and multi-octet IE
data — are big-endian (network byte order) on the wire.
**RFC ambiguous:** the document never uses the phrases "network byte order" or
"big-endian" anywhere; the only occurrence of the word "endian" in the whole RFC
is the codec name "16-bit linear little-endian" (§8.7). The big-endian reading
is an inference from the diagram convention, and it is contradicted in one place
— the APPARENT ADDR address-family field (§8.6.17, see traps below).

### The `F` bit (§8.1.1)

> "This bit specifies whether or not the frame is a Full Frame. If the 'F' bit
> is set to 1, the frame is a Full Frame. If it is set to 0, it is not a Full
> Frame." (§8.1.1)

### The `R` bit (§8.1.1)

> "This bit specifies whether or not the frame is being retransmitted. If the
> 'R' bit is set to 0, the frame is being transmitted for the first time. If it
> is set to 1, the frame is being retransmitted. IAX does not specify a
> retransmit timeout; this is left to the implementor." (§8.1.1)

The `R` bit occupies the same position in the second 16-bit word that `F`
occupies in the first. It is **not** part of the destination call number.

### Source / destination call numbers (§8.1.1, §4)

> "This 15-bit value specifies the call number the transmitting client uses to
> identify this call. The source call number for an active call MUST NOT be in
> use by another call on the same client. Call numbers MAY be reused once a call
> is no longer active, i.e., either when there is positive acknowledgment that
> the call has been destroyed or when all possible timeouts for the call have
> expired." (§8.1.1)

> "This 15-bit value specifies the call number the transmitting client uses to
> reference the call at the remote peer. This number is the same as the remote
> peer's source call number. The destination call number uniquely identifies a
> call on the remote peer. The source call number uniquely identifies the call
> on the local peer." (§8.1.1)

> "A call leg is marked with two unique integers, one assigned by each peer
> involved in creating the call leg." (§4)

See §15 below for allocation rules.

---

## 2. Mini frame format (§8.1.2)

> "Mini Frames are so named because their header is a minimal 4 octets. Mini
> Frames carry no control or signaling data; their sole purpose is to carry a
> media stream on an already-established IAX call. They are sent unreliably."
> (§8.1.2)

```
                     1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|F|     Source call number      |            time-stamp         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
:                             Data                              :
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| Byte offset | Bit offset | Width | Field | Notes |
|---|---|---|---|---|
| 0 | bit 0 | 1 bit | `F` | MUST be 0 (§8.1.2) |
| 0–1 | bits 1–15 | 15 bits | Source Call Number | transmitting peer's call number |
| 2–3 | — | 16 bits | Time-stamp | low 16 bits of the sender's 32-bit call time-stamp |
| 4… | — | var | Data | media payload, arbitrary length |

There is **no** destination call number, **no** sequence numbers, **no** frame
type, and **no** subclass in a mini frame. Type and subclass are implicit:

> "Mini frames are implicitly defined to be of type 'voice frame' (frametype 2;
> see Section 8.2). The subclass is implicitly defined by the most recent full
> voice frame of a call (i.e. the subclass for a voice frame specifies the CODEC
> used with the stream). The first voice frame of a call SHOULD be sent using
> the CODEC agreed upon in the initial CODEC negotiation. On-the-fly CODEC
> negotiation is permitted by sending a full voice frame specifying the new
> CODEC to use in the subclass field." (§8.1.2)

Mini frames MUST NOT carry IEs:

> "The non-guaranteed messages are referred to as 'Mini-Frames' and 'Meta
> Frames' and these more compact messages only have the originating peer's call
> identifier and MUST NOT have any 'Information Elements'." (§6)

### When a mini frame may be used instead of a full frame (§6.10, §8.1.2, §7)

- Only on an **already-established** call (§8.1.2).
- Only for audio (and, via meta video frames, video) — §6.10.
- Not for the first voice frame of a call: the codec must first be pinned by a
  full voice frame (§8.1.2), and the example flows in §9.6 / §9.7 show a full
  voice frame preceding the mini-frame stream in each direction.
- Periodically a full frame **MUST** be substituted:
  > "Abbreviated 'Mini Frames' are normally used for audio and video; however,
  > each time the time-stamp is a multiple of 32,768 (0x8000 hex), a standard or
  > 'Full Frame' MUST be sent." (§6.10)
- Mini frames are never acknowledged:
  > "Upon receiving any media message, except the abbreviated audio and video
  > Mini Frames, an ACK message MUST be sent." (§6.10)
- Receiving a mini frame before the first full voice frame is an error:
  > "A VNAK is sent when a message is received out of order, particularly when a
  > Mini Frame is received before the first full voice frame on a call." (§6.9.3)

**Errata note:** §8.1.2 says "The F bit, source call number, and 16-bit
time-stamp comprise the entire 4-octet header for a **full frame**." That is a
typo in the RFC; the sentence is in the Mini Frames section and describes the
mini frame header (the full-frame header is 12 octets per §8.1.1).

---

## 3. Meta frames (§8.1.3) — recognise and reject

We do **not** implement trunking. This section exists so the parser can identify
meta frames and discard them without mis-parsing them as full or mini frames.

### Detection rule (§8.1.3.1, §8.1.3.2)

> "The meta indicator is a 15-bit field of all zeroes, used to indicate that the
> frame is a Meta Frame. Meta Frames are identifiable because the first 16 bits
> will always be zero in any Meta Frame, whereas Full or Mini Frames will have
> either the 'F' bit set or some (nonzero) value for the source call number (or
> both)." (§8.1.3.1 and §8.1.3.2, identical wording)

So the demultiplexing order on every received datagram is:

1. If the first 16 bits are all zero → **Meta frame** (trunk or video). Drop.
2. Else if bit 0 of byte 0 is 1 → **Full frame** (12-octet header).
3. Else → **Mini frame** (4-octet header).

This ordering matters: a mini frame with source call number 0 would be
indistinguishable from a meta frame, which is why source call number 0 must
never be allocated (see §15).

### Meta video frame (§8.1.3.1)

```
                     1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|F|         Meta Indicator      |V|      Source Call Number     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|?|          time-stamp         |                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                               |
|                                         Data                  |
```

- `F` = 0; Meta Indicator = 15 zero bits; `V` = 1 for meta **video**.
- Source call number: 15 bits.
- Implicitly frame type 3 (video); codec implied by the last full video frame
  (§8.1.3.1).
- **RFC ambiguous:** the prose says "Meta video frames carry a **16-bit**
  time-stamp", but Figure 7 shows a `?` bit followed by a time-stamp field, i.e.
  1 + 15 bits in the third 16-bit word. The RFC does not say what `?` is. Since
  we reject meta frames, this does not affect us — but do not use Figure 7 as a
  parsing template.

### Meta trunk frame (§8.1.3.2, §7.1)

```
                     1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|F|         Meta Indicator      |V|Meta Command | Cmd Data      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            time-stamp                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- `F` = 0; Meta Indicator = 15 zero bits; `V` = **0** for trunk (§8.1.3.2).
- Meta Command: 7 bits. "A value of '1' indicates that the frame is a meta trunk
  frame. All other values are reserved for future use." (§8.1.3.2)
- Cmd Data: 8 bits of flags. "The least significant bit of the field is the
  'trunk time-stamps' flag. A value of 0 indicates that the calls in the trunk
  do not include their individual time-stamps. A value of 1 indicates that the
  calls do each include their own time-stamp." (§8.1.3.2)
- Time-stamp: 32 bits, the transmission time of the *trunk* frame (§8.1.3.2).
- Then, per §8.1.3.2:
  - flag 0: repeated `{R+15-bit source call number, 16-bit data length, data}`
  - flag 1: repeated `{16-bit data length, complete Mini Frame (call number +
    16-bit time-stamp), data}`

**Our behaviour:** drop meta frames silently. The RFC defines no message for
rejecting a meta frame (INVAL and UNSUPPORT are defined for other situations —
§6.9.2, §6.9.5 — and neither is specified as a response to a meta frame).
The safe course is to never advertise or initiate trunking and to ignore any
meta frame received.

---

## 4. Frame type table (§8.2, table at end of §8.2.10)

Verified twice against §8.2 of the RFC.

| Value | Name | Subclass meaning | Data | RFC section |
|---|---|---|---|---|
| `0x01` | DTMF | the DTMF digit itself: `0-9, A-D, *, #` | Undefined | §8.2.1 |
| `0x02` | Voice | audio compression format (§8.7) | media data | §8.2.2 |
| `0x03` | Video | video compression format (§8.7) | media data | §8.2.3 |
| `0x04` | Control | Control frame subclass (§8.3) | varies with subclass | §8.2.4 |
| `0x05` | Null | Undefined | Undefined | §8.2.5 |
| `0x06` | IAX Control ("IAX") | IAX subclass (§8.4) | Information Elements | §8.2.6 |
| `0x07` | Text | always 0 | raw UTF-8 text | §8.2.7 |
| `0x08` | Image | image compression format (§8.7) | raw image | §8.2.8 |
| `0x09` | HTML | HTML command subclass (§8.5) | message specific | §8.2.9 |
| `0x0A` | Comfort Noise | level in −dBov | none | §8.2.10 |

> "Frames with the Null value MUST NOT be transmitted." (§8.2.5)

> "The frame carries a text message in UTF-8 [RFC3629] format." (§6.10.4);
> "All text frames have a subclass of 0." (§8.2.7)

> "This message carries a single image. The image MUST fit in one message in
> this version of the protocol." (§6.10.5)

Values above `0x0A` are not defined by the RFC ("Refer to the IANA Registry for
additional IAX Frame Type values", §8.2).

---

## 5. Subclass tables

### 5.1 IAX frame subclasses — frame type `0x06` (§8.4)

Verified twice against §8.4.

| Value | Dec | Name | Description |
|---|---|---|---|
| `0x01` | 1 | NEW | Initiate a new call |
| `0x02` | 2 | PING | Ping request |
| `0x03` | 3 | PONG | Ping or poke reply |
| `0x04` | 4 | ACK | Explicit acknowledgment |
| `0x05` | 5 | HANGUP | Initiate call tear-down |
| `0x06` | 6 | REJECT | Reject a call |
| `0x07` | 7 | ACCEPT | Accept a call |
| `0x08` | 8 | AUTHREQ | Authentication request |
| `0x09` | 9 | AUTHREP | Authentication reply |
| `0x0a` | 10 | INVAL | Invalid message |
| `0x0b` | 11 | LAGRQ | Lag request |
| `0x0c` | 12 | LAGRP | Lag reply |
| `0x0d` | 13 | REGREQ | Registration request |
| `0x0e` | 14 | REGAUTH | Registration authentication |
| `0x0f` | 15 | REGACK | Registration acknowledgement |
| `0x10` | 16 | REGREJ | Registration reject |
| `0x11` | 17 | REGREL | Registration release |
| `0x12` | 18 | VNAK | Video/Voice retransmit request |
| `0x13` | 19 | DPREQ | Dialplan request |
| `0x14` | 20 | DPREP | Dialplan reply |
| `0x15` | 21 | DIAL | Dial |
| `0x16` | 22 | TXREQ | Transfer request |
| `0x17` | 23 | TXCNT | Transfer connect |
| `0x18` | 24 | TXACC | Transfer accept |
| `0x19` | 25 | TXREADY | Transfer ready |
| `0x1a` | 26 | TXREL | Transfer release |
| `0x1b` | 27 | TXREJ | Transfer reject |
| `0x1c` | 28 | QUELCH | Halt audio/video [media] transmission |
| `0x1d` | 29 | UNQUELCH | Resume audio/video [media] transmission |
| `0x1e` | 30 | POKE | Poke request |
| `0x1f` | 31 | *Reserved* | Reserved for future use |
| `0x20` | 32 | MWI | Message waiting indication |
| `0x21` | 33 | UNSUPPORT | Unsupported message |
| `0x22` | 34 | TRANSFER | Remote transfer request |
| `0x23`–`0x25` | 35–37 | *Reserved* | Reserved for future use |

Note there is **no** `TXMEDIA` value in the §8.4 table even though §6.5.6
describes a "TXMEDIA Transfer Media Message" and Figure 4 uses it.
**RFC ambiguous:** TXMEDIA has no assigned subclass number in RFC 5456. (Also
note §6.5.6's body text erroneously begins "The TXREL message indicates that the
MEDIA transfer process has successfully completed" — apparently a copy-paste
slip from §6.5.5.) We do not implement path optimisation, so this does not
affect us.

Unrecognised IAX subclass → respond `UNSUPPORT` (`0x21`) carrying the
`IAX UNKNOWN` IE (`0x17`), which is a 1-octet copy of the offending subclass
(§6.9.5, §8.6.22). Note §6.3.1 phrases the same rule for *control* messages:
"An IAX peer that receives a control message that is not understood MUST respond
with the UNSUPPORT message."

### 5.2 Control frame subclasses — frame type `0x04` (§8.3)

Verified twice against §8.3.

| Value | Dec | Name | Description |
|---|---|---|---|
| `0x01` | 1 | Hangup | The call has been hungup at the remote end |
| `0x02` | 2 | *Reserved* | Reserved for future use |
| `0x03` | 3 | Ringing | Remote end is ringing (ring-back) |
| `0x04` | 4 | Answer | Remote end has answered |
| `0x05` | 5 | Busy | Remote end is busy |
| `0x06` | 6 | *Reserved* | Reserved for future use |
| `0x07` | 7 | *Reserved* | Reserved for future use |
| `0x08` | 8 | Congestion | The call is congested |
| `0x09` | 9 | Flash Hook | Flash hook |
| `0x0a` | 10 | *Reserved* | Reserved for future use |
| `0x0b` | 11 | Option | Device-specific options are being transmitted |
| `0x0c` | 12 | Key Radio | Key Radio |
| `0x0d` | 13 | Unkey Radio | Unkey Radio |
| `0x0e` | 14 | Call Progress | Call is in progress |
| `0x0f` | 15 | Call Proceeding | Call is proceeding |
| `0x10` | 16 | Hold | Call is placed on hold |
| `0x11` | 17 | Unhold | Call is taken off hold |

Semantics of the ones we care about:

- **Ringing** (`0x03`) — "sent from a terminating party to indicate that the
  called party's service has processed the call request and is being alerted to
  the call." Requires no IEs. (§6.3.3)
- **Answer** (`0x04`) — "sent from the called party to indicate that the party
  has accepted the call request… any ring-back or other progress tones MUST be
  terminated and the communications channel MUST be opened." Requires no IEs.
  (§6.3.4)
- **Busy** (`0x05`) — a "BUSY" indication in the call-control sequence (§6.3.1).
- **Call Proceeding** (`0x0f`) — "SHOULD be sent to a calling party when their
  call request is being processed by a further network element but has not yet
  reached the called party." Requires no IEs. (§6.3.2)
- **Hangup** (`0x01`) is a *Control* subclass distinct from the *IAX* HANGUP
  message (IAX subclass `0x05`, §6.2.5). Do not conflate them.
- **Key Radio** / **Unkey Radio** (`0x0c` / `0x0d`) exist because of the ham
  radio use case: §6.3.1 notes "One such extension is an application that
  controls ham radio transceivers."

> "These messages MUST only be sent after an IAX call leg has been ACCEPTed."
> (§6.3.1)

### 5.3 HTML command subclasses — frame type `0x09` (§8.5)

| Value | Description |
|---|---|
| `0x01` | Sending a URL |
| `0x02` | Data frame |
| `0x04` | Beginning frame |
| `0x08` | End frame |
| `0x10` | Load is complete |
| `0x11` | Peer does not support HTML |
| `0x12` | Link URL |
| `0x13` | Unlink URL |
| `0x14` | Reject Link URL |

> "If a peer receives an HTML message for a channel that does not support HTML,
> it MUST respond with an HTML message that has the HTML NOT SUPPORTED
> indication." (§6.10.6) — i.e. subclass `0x11`.

Note the first five values are powers of two and the last four are not; when
encoding these into the 7-bit subclass field the C-bit rule below still applies
mechanically (`0x11`, `0x12`, `0x13`, `0x14` are ≤ 127 so they go with C = 0).

### 5.4 Other subclass meanings

- **DTMF** (`0x01`): subclass is the digit itself (§8.2.1) — see §14.
- **Voice** (`0x02`), **Video** (`0x03`), **Image** (`0x08`): subclass is a
  media format value from §8.7 — see §8 below.
- **Text** (`0x07`): subclass always 0 (§8.2.7).
- **Comfort Noise** (`0x0A`): "The subclass is the level of comfort noise in
  −dBov." (§8.2.10)

---

## 6. The `C` bit and subclass encoding (§8.1.1)

This is the single easiest thing to get wrong. The exact normative sentence:

> "This bit determines how the remaining 7 bits of the Subclass field are coded.
> If the 'C' bit is set to 1, the Subclass value is interpreted as a power of 2.
> If it is not set, the Subclass value is interpreted as a simple 7-bit unsigned
> integer." (§8.1.1)

So byte 11 of a full frame is:

```
 bit 0    bits 1..7
+-----+---------------+
|  C  |  subclass[7]  |
+-----+---------------+
```

**Decoding**

```
raw   = frame[11]
C     = (raw & 0x80) != 0
field = raw & 0x7F
value = C ? (1 << field) : field
```

**Encoding**

```
if value <= 0x7F   ->  C = 0, field = value            (byte = value)
else if value is an exact power of two
                   ->  C = 1, field = log2(value)      (byte = 0x80 | log2(value))
else               ->  not representable
```

**Worked examples**

| Meaning | Value | Encoding | Subclass byte |
|---|---|---|---|
| IAX NEW (§8.4) | 1 | C = 0, field = 1 | `0x01` |
| IAX POKE (§8.4) | 0x1E = 30 | C = 0, field = 30 | `0x1E` |
| IAX TRANSFER (§8.4) | 0x22 = 34 | C = 0, field = 34 | `0x22` |
| Control Answer (§8.3) | 4 | C = 0, field = 4 | `0x04` |
| Voice, G.711 µ-law (§8.7) | `0x00000004` = 2² | C = 1, field = 2 | `0x82` |
| Voice, GSM (§8.7) | `0x00000002` = 2¹ | C = 1, field = 1 | `0x81` |
| Voice, G.729 (§8.7) | `0x00000100` = 2⁸ | C = 1, field = 8 | `0x88` |
| Video, H.264 (§8.7) | `0x00200000` = 2²¹ | C = 1, field = 21 | `0x95` |

**RFC ambiguous — overlap.** For values that are both ≤ 127 *and* an exact power
of two (1, 2, 4, 8, 16, 32, 64), two encodings decode to the same number:
`C = 0, field = v` and `C = 1, field = log2(v)`. Example: µ-law (4) could be
sent as `0x04` or as `0x82`. The RFC does not say which a sender MUST use.
**Therefore: a decoder MUST accept both forms.** For encoding, apply the rule
consistently — media format subclasses are bitmask values from §8.7 and are
naturally powers of two, so encode them with C = 1; IAX/Control/HTML subclasses
are ordinal numbers ≤ 127, so encode them with C = 0. Never assume the peer
picked the same convention.

**Consequence for media formats.** With C = 1 the subclass field can only encode
2⁰ … 2¹²⁶ — a *single* codec, never a combination. That matches §8.6.8 FORMAT
("Only one CODEC MUST be specified"). Multi-codec sets travel in the CAPABILITY
IE as a full 4-octet bitmask (§8.6.7), never in a subclass field.

---

## 7. Information Element table (§8.6)

IE wire format (§8.6):

```
                     1
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|      IE       |  Data Length  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                               |
:             DATA              :
|                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

> "The first octet of any information element consists of the 'IE' field… The
> second octet of any information element is the 'data length' field. It
> specifies the length in octets of the information element's data field." (§8.6)

So: 1-octet id, 1-octet length, `length` octets of data. Maximum data length per
IE is therefore **255 octets**. Zero-length IEs are legal (AUTOANSWER, §8.6.24).

> "Elements that carry UTF-8 MUST prepare strings as per [RFC3454] and
> [RFC3491], so that illegal characters, case folding, and other characters
> properties are handled and compared properly." (§8.6)

IEs appear only in full frames: "IAX messages sent as Full Frames MAY carry
information elements" (§8.6); mini/meta frames "MUST NOT have any 'Information
Elements'" (§6).

### Full IE table (Table 1, §8.6) — verified twice

| Id | Name | Data format | Carried by | Detail §|
|---|---|---|---|---|
| `0x01` | CALLED NUMBER | UTF-8 string | NEW, DPREQ, DPREP, DIAL, TRANSFER | 8.6.1 |
| `0x02` | CALLING NUMBER | UTF-8 string | NEW (usually); REGACK (optional) | 8.6.2 |
| `0x03` | CALLING ANI | UTF-8 string | NEW (optional) | 8.6.3 |
| `0x04` | CALLING NAME | UTF-8 string | NEW (usually); REGACK (optional) | 8.6.4 |
| `0x05` | CALLED CONTEXT | UTF-8 string | NEW, TRANSFER (optional) | 8.6.5 |
| `0x06` | USERNAME | UTF-8 string | NEW, AUTHREQ, REGREQ, REGAUTH, REGACK | 8.6.6 |
| `0x07` | PASSWORD | **undefined** — see note | — | *none* |
| `0x08` | CAPABILITY | 4-octet codec bitmask (§8.7), OR-able | NEW | 8.6.7 |
| `0x09` | FORMAT | 4-octet codec bitmask (§8.7), exactly one bit | NEW, ACCEPT | 8.6.8 |
| `0x0a` | LANGUAGE | UTF-8 string (RFC 5646 / RFC 4647 tags) | NEW (optional) | 8.6.9 |
| `0x0b` | VERSION | 2 octets, value `0x0002` | NEW (**MUST**, and MUST be first IE) | 8.6.10 |
| `0x0c` | ADSICPE | 2 octets | NEW (optional) | 8.6.11 |
| `0x0d` | DNID | UTF-8 string | NEW (optional) | 8.6.12 |
| `0x0e` | AUTHMETHODS | 2-octet bitmask (see §13) | AUTHREQ, REGAUTH (**MUST**) | 8.6.13 |
| `0x0f` | CHALLENGE | UTF-8 challenge string | AUTHREQ, REGAUTH (**MUST**) | 8.6.14 |
| `0x10` | MD5 RESULT | UTF-8 string (digest, see §13) | AUTHREP, REGREQ, REGREL (conditional) | 8.6.15 |
| `0x11` | RSA RESULT | UTF-8 string (signature, see §13) | AUTHREP, REGREQ, REGREL (conditional) | 8.6.16 |
| `0x12` | APPARENT ADDR | POSIX `sockaddr` struct; 16 octets IPv4, 28 octets IPv6 | TXREQ, REGACK (**MUST**) | 8.6.17 |
| `0x13` | REFRESH | 2 octets, seconds | REGREQ, REGACK, DPREP | 8.6.18 |
| `0x14` | DPSTATUS | 2-octet bitmask | DPREP (**MUST**) | 8.6.19 |
| `0x15` | CALLNO | 2 octets, a call number as in a frame header | TXREQ, TXREADY, TXREL (**MUST**) | 8.6.20 |
| `0x16` | CAUSE | UTF-8 string | HANGUP, REJECT, REGREJ, TXREJ (SHOULD) | 8.6.21 |
| `0x17` | IAX UNKNOWN | 1 octet: the unrecognised subclass | UNSUPPORT (**MUST**) | 8.6.22 |
| `0x18` | MSGCOUNT | 2 octets: high 8 = old msgs, low 8 = new msgs; all-1s = "at least one" | REGACK, MWI (optional) | 8.6.23 |
| `0x19` | AUTOANSWER | **zero-length** — presence is the signal | NEW (optional) | 8.6.24 |
| `0x1a` | MUSICONHOLD | optional UTF-8 MOH class name; may be zero-length | QUELCH (optional) | 8.6.25 |
| `0x1b` | TRANSFERID | 4 octets | TXREQ, TXCNT (SHOULD); also TXACC, TXREADY per §6.5.3–6.5.4 | 8.6.26 |
| `0x1c` | RDNIS | UTF-8 string | not stated by the RFC | 8.6.27 |
| `0x1d` | *Reserved* | — | — | — |
| `0x1e` | *Reserved* | — | — | — |
| `0x1f` | DATETIME | 4 octets, packed (see below) | NEW, REGACK (SHOULD; informational) | 8.6.28 |
| `0x20`–`0x25` | *Reserved* | — | — | — |
| `0x26` | CALLINGPRES | 1 octet, value from §8.6.29 table | NEW (**MUST**) | 8.6.29 |
| `0x27` | CALLINGTON | 1 octet, Q.931 type-of-number | NEW (**MUST**) | 8.6.30 |
| `0x28` | CALLINGTNS | 2 octets (see §8.6.31) | NEW (**MUST**) | 8.6.31 |
| `0x29` | SAMPLINGRATE | 2 octets, Hz; default 8000 if absent | not stated by the RFC | 8.6.32 |
| `0x2a` | CAUSECODE | 1 octet, Q.931-derived code | HANGUP, REJECT, REGREJ, TXREJ (SHOULD) | 8.6.33 |
| `0x2b` | ENCRYPTION | bitmask; `0x0001` = AES-128 (length: see trap) | NEW, AUTHREQ (optional) | 8.6.34 |
| `0x2c` | ENCKEY | *Reserved for future use* | — | *none* |
| `0x2d` | CODEC PREFS | UTF-8 list of codecs in preference order | NEW | 8.6.35 |
| `0x2e` | RR JITTER | 4 octets, measured jitter | PONG (optional) | 8.6.36 |
| `0x2f` | RR LOSS | 4 octets: 1 octet loss percent + 3 octets loss count | PONG (optional) | 8.6.37 |
| `0x30` | RR PKTS | 4 octets, frames received | PONG (optional) | 8.6.38 |
| `0x31` | RR DELAY | 2 octets, max playout delay in ms | PONG (optional) | 8.6.39 |
| `0x32` | RR DROPPED | 4 octets, frames dropped | PONG (optional) | 8.6.40 |
| `0x33` | RR OOO | 4 octets, frames received out of order | PONG (optional) | 8.6.41 |
| `0x34` | OSPTOKEN | 1 octet block index (from 0) + token block | NEW **only** | 8.6.42 |

**PASSWORD (`0x07`) note.** It appears in Table 1 with the description "Password
for authentication" but **has no defining subsection** in §8.6 — the subsections
run §8.6.6 USERNAME (`0x06`) straight to §8.6.7 CAPABILITY (`0x08`). Combined
with AUTHMETHODS `0x0001` being "Reserved (was Plaintext)" (§8.6.13) and
"Previous protocol versions supported cleartext passwords; this feature has been
eliminated" (§10), the RFC's position is that plaintext auth is gone.
**RFC ambiguous:** the RFC neither defines the PASSWORD IE's data format nor
formally deprecates the id. **Do not send it.**

**Beware the 8.6.x numbering offset.** Because PASSWORD has no subsection, the
subsection index equals the IE id only up to `0x06`; from `0x08` on, IE id =
subsection index + 1 (e.g. §8.6.15 is IE `0x10` MD5 RESULT). Do not derive ids
from section numbers.

### IE sub-tables

**AUTHMETHODS (`0x0e`) — 2-octet bitmask (§8.6.13)**

| Value | Method |
|---|---|
| `0x0001` | *Reserved* (was Plaintext) |
| `0x0002` | MD5 |
| `0x0004` | RSA |

**DPSTATUS (`0x14`) — 2-octet bitmask (§8.6.19)**

| Flag | Meaning |
|---|---|
| `0x0001` | Exists |
| `0x0002` | Can exist |
| `0x0004` | Non-existent |
| `0x4000` | Retain dialtone (ignorepat) |
| `0x8000` | More digits may match number |

"Exactly one of the low 3 bits MUST be set, and zero, 1, or 2 of the high 2 bits
MAY be set." (§8.6.19)

**ENCRYPTION (`0x2b`) (§8.6.34)**

| Value | Method |
|---|---|
| `0x0001` | AES-128 |

**CALLINGPRES (`0x26`) — 1 octet (§8.6.29)**

| Value | Presentation |
|---|---|
| `0x00` | Allowed user/number not screened |
| `0x01` | Allowed user/number passed screen |
| `0x02` | Allowed user/number failed screen |
| `0x03` | Allowed network number |
| `0x20` | Prohibited user/number not screened |
| `0x21` | Prohibited user/number passed screen |
| `0x22` | Prohibited user/number failed screen |
| `0x23` | Prohibited network number |
| `0x43` | Number not available |

**CALLINGTON (`0x27`) — 1 octet, Q.931 (§8.6.30)**

| Value | Description |
|---|---|
| `0x00` | Unknown |
| `0x10` | International Number |
| `0x20` | National Number |
| `0x30` | Network Specific Number |
| `0x40` | Subscriber Number |
| `0x60` | Abbreviated Number |
| `0x70` | Reserved for extension |

**CALLINGTNS (`0x28`) — 2 octets (§8.6.31)**

First octet: network identification plan in the low 4 bits, type of network in
the next 3 bits. Second octet: the network identification as UTF-8.

Plan values: `0000` Unknown, `0001` Caller Identification Code, `0011` Data
Network Identification Code.
Type-of-network values: `000` User Specified, `010` National Network
Identification, `011` International Network Identification.

**RFC ambiguous:** a 2-octet total with a UTF-8 network identification in "the
second octet" makes no sense for identifications longer than one character, and
Figure in §8.6.31 shows `| |TON|Plan| UTF-8 Net ID |`. Treat as
underspecified; we send `0x00 0x00` (Unknown / User Specified) as the NEW
message requires the IE.

**APPARENT ADDR (`0x12`) — IPv4 layout (§8.6.17)**

Data length `0x10` (16 octets):

| Offset in data | Width | Field | Value in RFC example |
|---|---|---|---|
| 0–1 | 2 | address family (INET) | `0x0200` |
| 2–3 | 2 | port | `0x11d9` (= 4569) |
| 4–7 | 4 | 32-bit IPv4 address | — |
| 8–15 | 8 | padding, all zero bits | — |

IPv6 (§8.6.17): data length `0x1C` (28 octets) — family `0x0A00`, port
`0x11d9`, 32-bit flow information, 128-bit address, 32-bit scope id.

See the traps section for the `0x0200` / `0x11d9` byte-order inconsistency and
for the "18 octets" statement.

**DATETIME (`0x1f`) — 4 octets (§8.6.28)**

> "the 5 least significant bits are seconds, the next 6 least significant bits
> are minutes, the next least significant 5 bits are hours, the next least
> significant 5 bits are the day of the month, the next least significant 4 bits
> are the month, and the most significant 7 bits are the year. The year is
> offset from 2000, and the month is a 1-based index… The timezone of the clock
> MUST be UTC." (§8.6.28)

As a 32-bit big-endian word: `year(7) | month(4) | day(5) | hour(5) | minute(6)
| second(5)`, most significant field first. Strictly informational.

**CAUSECODE (`0x2a`) — 1 octet, Q.931-derived (§8.6.33)**

Full table from §8.6.33 (decimal):

| # | Cause | # | Cause |
|---|---|---|---|
| 1 | Unassigned/unallocated number | 63 | Service or option not available (Q.931 only) |
| 2 | No route to specified transit network | 65 | Bearer capability not implemented |
| 3 | No route to destination | 66 | Channel type not implemented |
| 6 | Channel unacceptable | 69 | Facility not implemented |
| 7 | Call awarded and delivered | 70 | Only restricted digital information bearer capability is available (Q.931 only) |
| 16 | Normal call clearing | 79 | Service or option not available (Q.931 only) |
| 17 | User busy | 81 | Invalid call reference |
| 18 | No user response | 82 | Identified channel does not exist (Q.931 only) |
| 19 | No answer | 83 | A suspended call exists, but this call identity does not (Q.931 only) |
| 21 | Call rejected | 84 | Call identity in use (Q.931 only) |
| 22 | Number changed | 85 | No call suspended (Q.931 only) |
| 27 | Destination out of order | 86 | Call has been cleared (Q.931 only) |
| 28 | Invalid number format/incomplete number | 88 | Incompatible destination |
| 29 | Facility rejected | 91 | Invalid transit network selection (Q.931 only) |
| 30 | Response to status enquiry | 95 | Invalid message, unspecified |
| 31 | Normal, unspecified | 96 | Mandatory information element missing (Q.931 only) |
| 34 | No circuit/channel available | 97 | Message type nonexistent/not implemented |
| 38 | Network out of order | 98 | Message not compatible with call state |
| 41 | Temporary failure | 99 | Information element nonexistent |
| 42 | Switch congestion | 100 | Invalid information element contents |
| 43 | Access information discarded | 101 | Message not compatible with call state |
| 44 | Requested channel not available | 102 | Recovery on timer expiration |
| 45 | Preempted (causes.h only) | 103 | Mandatory information element length error (causes.h only) |
| 47 | Resource unavailable, unspecified (Q.931 only) | 111 | Protocol error, unspecified |
| 50 | Facility not subscribed (causes.h only) | 127 | Internetworking, unspecified |
| 52 | Outgoing call barred (causes.h only) | | |
| 54 | Incoming call barred (causes.h only) | | |
| 57 | Bearer capability not authorized | | |
| 58 | Bearer capability not available | | |

For a normal user-initiated hangup, use **16 — Normal call clearing**.

---

## 8. Media format bitmask values (§8.7)

Verified twice against §8.7. These 32-bit values are used in the CAPABILITY IE
(`0x08`, OR-ed together), the FORMAT IE (`0x09`, exactly one bit), and — via the
C-bit power-of-two encoding — in the subclass of Voice, Video, and Image frames.

| Bitmask | Bit | Description | Length calculation (from §8.7) |
|---|---|---|---|
| `0x00000001` | 1<<0 | G.723.1 | 4-, 20-, and 24-byte frames of 240 samples |
| `0x00000002` | 1<<1 | GSM Full Rate | 33-byte chunks of 160 samples or 65-byte chunks of 320 samples |
| **`0x00000004`** | **1<<2** | **G.711 mu-law (µ-law)** | **1 byte per sample** |
| `0x00000008` | 1<<3 | G.711 a-law | 1 byte per sample |
| `0x00000010` | 1<<4 | G.726 | — |
| `0x00000020` | 1<<5 | IMA ADPCM | 1 byte per 2 samples |
| `0x00000040` | 1<<6 | 16-bit linear little-endian | 2 bytes per sample |
| `0x00000080` | 1<<7 | LPC10 | Variable size frame of 172 samples |
| `0x00000100` | 1<<8 | G.729 | 20-byte chunks of 172 samples |
| `0x00000200` | 1<<9 | Speex | Variable |
| `0x00000400` | 1<<10 | ILBC | 50 bytes per 240 samples |
| `0x00000800` | 1<<11 | G.726 AAL2 | — |
| `0x00001000` | 1<<12 | G.722 | 16 kHz ADPCM |
| `0x00002000` | 1<<13 | AMR | Variable |
| `0x00010000` | 1<<16 | JPEG | — |
| `0x00020000` | 1<<17 | PNG | — |
| `0x00040000` | 1<<18 | H.261 | — |
| `0x00080000` | 1<<19 | H.263 | — |
| `0x00100000` | 1<<20 | H.263p | — |
| `0x00200000` | 1<<21 | H.264 | — |

**G.711 µ-law is `0x00000004`, i.e. `1 << 2`.** In a Voice frame subclass byte
that is `C = 1, field = 2` → subclass octet `0x82`. Default sampling rate is
8 kHz if no SAMPLINGRATE IE is present (§8.6.32), giving 8000 bytes/s, i.e. 160
bytes per 20 ms frame.

Note the gaps: bits 14 and 15 (`0x4000`, `0x8000`) are **not assigned** by RFC
5456 — the table jumps from AMR `0x2000` to JPEG `0x10000`. Nothing above
`0x00200000` is defined. "Refer to the IANA Registry for any additional IAX
Media Format values." (§8.7)

**RFC ambiguous:** the RFC does not partition the mask into audio/video/image
ranges normatively; it merely gives per-frame-type pointers ("Predefined voice
formats can be found in Section 8.7", §8.2.2, etc.). In practice bits 0–13 are
audio, 16–17 image, 18–21 video, but the RFC never states that as a rule.

---

## 9. Sequence numbers (§7, §8.1.1)

**Definitions (§8.1.1)**

> "The 8-bit OSeqno field is the outbound stream sequence number. Upon
> initialization of a call, its value is 0. It increases incrementally as Full
> Frames are sent. When the counter overflows, it silently resets to 0."

> "The 8-bit ISeqno field is the inbound stream sequence number. Upon
> initialization of a call, its value is 0. It increases incrementally as Full
> Frames are received. At any time, the ISeqno of a call represents the next
> expected inbound stream sequence number. When the counter overflows, it
> silently resets to 0."

**Initialisation (§7, §6.2.2)**

> "When starting a call, the outgoing and incoming message sequence numbers MUST
> both be set to zero." (§7)

> "Sequence numbers for a NEW message, described in the transport section,
> (Section 7) are both set to 0." (§6.2.2)

So the very first NEW carries `OSeqno = 0, ISeqno = 0`, and the sender's OSeqno
becomes 1 for its next reliable frame.

**Which frames increment, which are exempt (§7)**

> "Each reliable message that is sent increments the message count by one except
> the ACK, INVAL, TXCNT, TXACC, and VNAK messages, which do not change the
> message count." (§7)

Exempt from incrementing OSeqno: **ACK, INVAL, TXCNT, TXACC, VNAK.**
Everything else sent as a full frame increments OSeqno by one *after* being
sent. Mini and meta frames carry no sequence numbers at all and never affect the
counters.

**What an ACK carries (§6.9.1)**

> "An ACK MUST have both a source call number and destination call number. It
> MUST also not change the sequence number counters, and MUST return the same
> time-stamp it received. This time-stamp allows the originating peer to
> determine to which message the ACK is responding. Receipt of an ACK requires
> no action." (§6.9.1)

An ACK therefore carries: the current (unchanged) OSeqno, the current ISeqno,
and the *echoed* time-stamp of the frame being acknowledged. Because OSeqno does
not advance for an ACK, two ACKs in a row carry the same OSeqno — this is
correct, not a bug.

**Cumulative acknowledgement (§7)**

> "If the message is a reliable message, the incoming message counter MUST be
> used to acknowledge all the messages up to that sequence number that have been
> sent." (§7)

ISeqno is cumulative: receiving a frame whose ISeqno is *N* clears every
outstanding frame you sent with OSeqno < *N* (or ≤ *N*, see the ambiguity below).

**Wraparound.** Both counters are 8-bit and "silently reset to 0" on overflow
(§8.1.1) — i.e. modulo-256 arithmetic. All comparisons ("higher sequence number
than…", §6.9.3) must be done in modulo-256 serial-number space, not as plain
integer comparisons, or a call will break after 256 full frames.

**RFC ambiguous — the off-by-one.** §8.1.1 says ISeqno "represents the **next
expected** inbound stream sequence number", while §7 says a message "includes
the outgoing message count and the **highest numbered incoming message that has
been received**". Those differ by exactly one. Reading them together, the §8.1.1
formulation ("next expected", i.e. last-received + 1) is the more specific and
is the one to implement, but a peer that follows §7 literally will appear to be
one behind. Be tolerant on receive: treat an inbound ISeqno of *N* as
acknowledging everything you sent with OSeqno < *N*, and do not tear a call down
solely because an ISeqno looks one low.

**Out-of-order detection (§6.9.3, §7)**

> "A message is considered out of sequence if the received iseqno is different
> than the expected iseqno." (§6.9.3)

> "When any message is received, the time-stamps MUST be checked to make sure
> that they are in order. If a message is received out of order, it MUST be
> ignored and a VNAK message sent to resynchronize the peers." (§7)

Note §7 phrases the out-of-order test in terms of **time-stamps** while §6.9.3
phrases it in terms of **iseqno**. **RFC ambiguous:** the two tests are not the
same. Implement the sequence-number test (§6.9.3) as primary; time-stamps "MAY
be approximate, but, MUST be in order" (§7).

---

## 10. Reliability and retransmission (§7, §7.2.1, §8.1.1, §6.9.1, §6.9.3)

**What is reliable**

> "Messages are divided into two categories: reliable and non-guaranteed. The
> reliable messages are referred to as 'Full Frames'." (§6)

> "All messages except certain voice and video messages are reliable." (§7)

> "Full Frames are sent reliably, so all Full Frames require an immediate
> acknowledgment upon receipt. This acknowledgment can be explicit via an 'ACK'
> message… or implicit based upon receipt of an appropriate response to the Full
> Frame issued." (§8.1.1)

**Which frames must be ACKed explicitly (§6.9.1)**

> "An ACK is sent upon receipt of a Full Frame that does not have any other
> protocol-defined response." (§6.9.1)

> "When the following messages are received, an ACK MUST be sent in return: NEW,
> HANGUP, REJECT, ACCEPT, PONG, AUTHREP, REGREL, REGACK, REGREJ, TXREL. ACKs
> SHOULD not be expected by any peer and their purpose is purely to force the
> transport layer to be up to date." (§6.9.1)

Also, from elsewhere:

- "Upon receiving any media message, except the abbreviated audio and video Mini
  Frames, an ACK message MUST be sent." (§6.10) — so full Voice/Video/Text/
  Image/HTML/DTMF/Comfort-Noise frames get an ACK.
- "Upon receipt of an ACCEPT, an ACK MUST be sent" (§6.2.3).
- "Upon receipt of a HANGUP message, an IAX peer MUST immediately respond with
  an ACK" (§6.2.5).
- "(Note: REJECT messages require an explicit ACK.)" (§6.2.4)
- "Receipt of a REGACK message requires an ACK in response." (§6.1.4)
- "Receipt of a PONG requires an ACK." (§6.7.3)
- The example flows in §9.6 also ACK **RINGING** and **ANSWER** (Control
  frames), which are not in the §6.9.1 list. **RFC ambiguous:** §8.1.1's blanket
  "all Full Frames require an immediate acknowledgment" is broader than
  §6.9.1's enumeration. Follow §8.1.1 and the §9.6 flow: ACK every full frame
  for which you are not sending a defined response.

Implicit acknowledgement examples (a defined response replaces the ACK): NEW is
answered by ACCEPT / REJECT / AUTHREQ (§6.2.2); AUTHREQ by AUTHREP (§6.2.7);
PING by PONG (§6.7.2); POKE by PONG (§6.7.1); LAGRQ by LAGRP (§6.7.4); REGREQ by
REGAUTH / REGACK / REGREJ (§6.1.2). §6.9.1 also permits an ACK *in addition to*
a later defined response, deliberately, to slow brute-force password attacks:

> "An ACK MAY also be sent as an initial acknowledgment of an IAX message that
> requires some other protocol-defined message acknowledgment, as long as the
> required message is also sent within some peer-defined amount of time."
> (§6.9.1)

**Retransmission timing (§7.2.1)**

> "On each call, there is a timer for how long to wait for an acknowledgment of
> a message. This timer starts at twice the measured Round-Trip Time from the
> last PING/PONG command. If a retransmission is needed, it is exponentially
> increased until it meets a boundary value. The maximum retry time period
> boundary is 10 seconds." (§7.2.1)

So: initial timeout = 2 × RTT (from the most recent PING/PONG), exponential
backoff, capped at 10 s.
**RFC ambiguous:** §8.1.1 flatly contradicts this — "IAX does not specify a
retransmit timeout; this is left to the implementor." Implement §7.2.1 (the more
specific rule, in the timers section) and treat §8.1.1's sentence as licence to
pick a sensible initial value before any PING/PONG has completed. The RFC gives
no initial value for the "no RTT measured yet" case.

**Retry limit and teardown (§7)**

> "If no acknowledgment is received after a locally configured number of retries
> (default 4), the call leg SHOULD be considered unusable and the call MUST be
> torn down without any further interaction on this call leg." (§7)

Also §6.6: "if the reliable transport procedures determine that messaging cannot
be maintained, the call leg MUST be torn down without any other indications over
the errant IAX call leg." — i.e. do **not** send HANGUP when a call dies from
retransmission exhaustion.

**The R bit on retransmission (§8.1.1).** Set `R = 1` on every retransmitted
copy; the first transmission has `R = 0`. Everything else in the frame —
including OSeqno and the time-stamp — is retransmitted unchanged (the RFC gives
no rule permitting either to be updated on a retransmission). The R bit is
purely informational for the receiver; it is not part of the call number.

**VNAK semantics (§6.9.3)**

> "A VNAK is sent when a message is received out of order, particularly when a
> Mini Frame is received before the first full voice frame on a call. It is a
> request for retransmission of dropped messages. A message is considered out of
> sequence if the received iseqno is different than the expected iseqno. On
> receipt of a VNAK, a peer MUST retransmit all frames with a higher sequence
> number than the VNAK message's iseqno." (§6.9.3)

VNAK does not increment OSeqno (§7). "Higher sequence number" must be evaluated
in modulo-256 space. VNAK carries no IEs.

**INVAL (§6.9.2, §6.2.5)**

> "An INVAL is sent as a response to a received message that is not valid. This
> occurs when an IAX peer sends a message on a call after the remote peer has
> hung up its end. Upon receipt of an INVAL, a peer MUST destroy its side of a
> call." (§6.9.2)

INVAL does not increment OSeqno (§7).

---

## 11. Timestamps (§8.1.1, §8.1.2, §6.10, §6.2.2, §7)

**Full frame time-stamp (§8.1.1)**

> "The time-stamp field contains a 32-bit time-stamp maintained by an IAX peer
> for a given call. The time-stamp is an incrementally increasing representation
> of the number of milliseconds since the first transmission of the call."
> (§8.1.1)

Origin and units are set at call creation:

> "A time-stamp MUST also be assigned for the call, beginning at zero and
> incrementing by one each millisecond." (§6.2.2)

Each peer keeps **its own** 32-bit clock for the call; the two are independent
("Each side has its own 32-bit time-stamp so each side needs to sync at 16-bit
overflow", note 3 of §9.6). Time-stamps "MAY be approximate, but, MUST be in
order" (§7).

**Echoing time-stamps.** ACK "MUST return the same time-stamp it received"
(§6.9.1). PONG uses the time-stamp of the PING/POKE (§6.7.3, §9.1). LAGRP "MUST
send the same time-stamp it received in the LAGRQ after passing the received
frame through any jitter buffer" (§6.7.5), and the LAGRQ sender computes lag from
the difference (§6.7.4).

**Mini frame time-stamp (§8.1.2)**

> "Mini frames carry a 16-bit time-stamp, which is the lower 16 bits of the
> transmitting peer's full 32-bit time-stamp for the call. The time-stamp allows
> synchronization of incoming frames so that they MAY be processed in
> chronological order instead of the (possibly different) order in which they
> are received. The 16-bit time-stamp wraps after 65.536 seconds, at which point
> a full frame SHOULD be sent to notify the remote peer that its time-stamp has
> been reset. A call MUST continue to send mini frames starting with time-stamp
> 0 even if acknowledgment of the resynchronization is not received." (§8.1.2)

**When a full frame must be sent instead of a mini frame.** Two rules, and they
do **not** agree:

- §6.10 (MUST, every 32.768 s): "each time the time-stamp is a multiple of
  32,768 (0x8000 hex), a standard or 'Full Frame' MUST be sent."
- §8.1.2 (SHOULD, every 65.536 s): "The 16-bit time-stamp wraps after 65.536
  seconds, at which point a full frame SHOULD be sent."
- §9.6/§9.7 diagram notes side with the second: "(every 65536 ms)" and "Full
  frames resync the 32-bit time-stamp when the 16-bit time-stamp overflows."

**RFC ambiguous:** 32,768 ms vs 65,536 ms, MUST vs SHOULD. The conservative
implementation satisfies both: send a full voice frame whenever the running
32-bit time-stamp crosses a multiple of `0x8000` (every 32.768 s), which
necessarily also covers every 16-bit wrap at `0x10000` boundaries. Doing more
than the minimum here is harmless — a full voice frame is just an ACKed voice
frame.

Receiver side: reconstruct the peer's 32-bit time-stamp by carrying the high 16
bits forward and detecting wraps in the low 16 bits, resynchronising the high
half whenever a full frame arrives.

---

## 12. Call setup and teardown flows

`===` = full frame (reliable); `---` = mini frame (unreliable). Notation from §9.

### (a) NEW → ACCEPT → ANSWER, no authentication (§6.2, §6.3, §9.6)

```
   Caller A                                       Callee B
      |  ===NEW=================================>  |   OSeq=0 ISeq=0; VERSION IE first
      |  <=============================ACCEPT====   |   carries FORMAT IE
      |  ===ACK=================================>   |   MUST (§6.2.3); echoes ACCEPT's ts
      |                                             |
      |  <====Voice (Full Frame)=================   |   pins codec; ACKed
      |  ====ACK================================>   |
      |  <-----Voice Mini Frames-----------------   |
      |                                             |
      |  <============================RINGING====   |   Control 0x03 (optional)
      |  ===ACK=================================>   |
      |  <=============================ANSWER====   |   Control 0x04
      |  ===ACK=================================>   |
      |                                             |
      |  <-----------Voice Mini Frames--------->    |   media both ways
```

ACKed at each step: **ACCEPT** (MUST, §6.2.3/§6.9.1), **RINGING** and **ANSWER**
(per §8.1.1 and the §9.6 flow), and every **full voice frame** (§6.10). NEW
itself is acknowledged *implicitly* by ACCEPT (or REJECT / AUTHREQ) — §6.9.1
lists NEW as requiring an ACK, and §6.9.1 also permits that ACK to be sent in
addition to the defined response.

Upon receipt of a NEW the callee MUST do exactly one of: send REJECT, challenge
with AUTHREQ, ACCEPT, or (less preferred) HANGUP (§6.2.2). After accepting, it
MUST progress the call with one of PROCEEDING, RINGING, BUSY, or ANSWER
(§6.2.2).

### (b) NEW → AUTHREQ → AUTHREP → ACCEPT → ANSWER (§6.2, §9.6)

```
   Caller A                                       Callee B
      |  ====NEW================================>   |   OSeq=0 ISeq=0
      |  <===========================AUTHREQ====     |   USERNAME + AUTHMETHODS + CHALLENGE
      |  ====AUTHREP===========================>     |   MD5 RESULT (or RSA RESULT)
      |  <============================ACCEPT====     |   FORMAT IE
      |  ====ACK===============================>     |   MUST
      |  <============================RINGING===     |
      |  ====ACK===============================>     |
      |  <=============================ANSWER===     |
      |  ====ACK===============================>     |
```

AUTHREQ is answered by AUTHREP (or HANGUP) — "Upon receiving an AUTHREQ message,
the receiver MUST respond with an AUTHREP or HANGUP message" (§6.2.7). AUTHREP
is on the §6.9.1 MUST-ACK list, and "An AUTHREP requires a response of either an
ACCEPT or a REJECT" (§6.2.6) — the ACCEPT/REJECT serves as the response; a
separate ACK may also be sent (§6.9.1).

### (c) NEW → REJECT (§6.2.4)

```
   Caller A                                       Callee B
      |  ====NEW================================>   |
      |  <=============================REJECT===     |   CAUSE + CAUSECODE IEs (optional)
      |  ====ACK===============================>     |   REQUIRED — explicit ACK
```

> "Upon receipt of a REJECT message, the call leg is destroyed and no further
> action is required. (Note: REJECT messages require an explicit ACK.)" (§6.2.4)

Destroy the call leg after sending the ACK.

### (d) HANGUP from each side (§6.2.5, §6.9.2, §9.6)

Local hangup:

```
   Us                                              Peer
      |  ====HANGUP============================>    |   CAUSE + CAUSECODE (optional)
      |  <================================ACK===    |
   (destroy call leg immediately after sending HANGUP;
    answer anything further for this call with INVAL)
```

Remote hangup:

```
   Us                                              Peer
      |  <===========================HANGUP=====     |
      |  ====ACK==============================>      |   MUST, immediately
   (destroy call leg; anything further for this call -> INVAL)
```

> "Upon receipt of a HANGUP message, an IAX peer MUST immediately respond with
> an ACK, and then destroy the call leg at its end. After a HANGUP message has
> been received for a call leg, any messages received that reference that call
> leg (i.e., have the same source/destination call identifiers) MUST be answered
> with an INVAL message." (§6.2.5)

> "After sending a HANGUP message, the sender MUST destroy the call and respond
> to subsequent messages regarding this call with an INVAL message." (§6.2.5)

Either side may hang up at any time ("Either can hangup", §9.6). The terminal
messages for a call are HANGUP, REJECT, TRANSFER, and TXREADY (§6.6).

### (e) Registration: REGREQ → REGAUTH → REGREQ → REGACK (§6.1, §9.3)

```
   Registrant A                                   Registrar B
      |  ===REGREQ============================>     |   USERNAME (+ REFRESH)
      |  <=========================REGAUTH====       |   USERNAME + AUTHMETHODS + CHALLENGE
      |  ===REGREQ============================>     |   USERNAME + MD5 RESULT (+ REFRESH)
      |  <==========================REGACK====       |   USERNAME + DATETIME + APPARENT ADDR (+ REFRESH)
      |  ===ACK===============================>     |   REQUIRED (§6.1.4)
```

Failure branch, at any point: `<===REGREJ===` carrying **required** CAUSE and
CAUSECODE IEs (§6.1.5), then `===ACK===>` (REGREJ is on the §6.9.1 MUST-ACK
list). "Upon receipt of a REGREJ message, the registrant MUST consider
registration process unsuccessful and no further interaction is required."
(§6.1.5)

Registration release (§6.1.6, §9.4) — same shape, REGREL instead of REGREQ:

```
   Registrant A                                   Registrar B
      |  ===REGREL============================>     |   USERNAME
      |  <=========================REGAUTH====       |   challenge
      |  ===REGREL============================>     |   USERNAME + MD5 RESULT
      |  <==========================REGACK====       |
      |  ===ACK===============================>     |
```

REGREL is itself on the MUST-ACK list (§6.9.1); in the §9.4 flow the REGAUTH /
REGACK responses serve as the protocol-defined responses, and the final ACK
closes the exchange.

**Registration lifetime rules (§6.1.1, §6.1.4, §7.2.2, §8.6.18)**

- The REGACK "MUST indicate the 'apparent address' and SHOULD indicate the
  'refresh'/expire time" (§6.1.1).
- "If no 'refresh' is sent, a default registration expiration of 60 seconds MUST
  be assumed by both peers." (§6.1.1, restated §6.1.4, §8.6.18)
- The validity period "begins when the registrar sends a REGACK message"
  (§6.1.1).
- "It is the client's responsibility to renew this registration before the time
  period expires. The registrations SHOULD be renewed at random intervals to
  prevent network congestion." (§7.2.2)

### Network monitoring flows (§9.1, §9.2, §6.7)

```
   PING  ===PING===>  <===PONG===  ===ACK===>        (PONG and ACK echo the PING time-stamp)
   POKE  ===POKE===>  <===PONG===  ===ACK===>        (POKE MUST have destination call number 0)
   LAG   ===LAGRQ==>  <===LAGRP==  ===ACK===>        (LAGRP echoes the LAGRQ time-stamp)
```

- PING: "Transmission of a PING MAY occur when a peer-defined number of seconds
  have passed without receiving an incoming media frame on a call, or by default
  every 20 seconds. Receipt of a PING requires an acknowledging PONG be sent."
  (§6.7.2)
- POKE: "It is similar to a PING message, except that it MUST be sent when there
  is no existing call to the remote endpoint… A POKE MUST have 0 as its
  destination call number." (§6.7.1) "Upon receiving a POKE message, the peer
  MUST respond with a PONG message." (§6.7.1)
- PONG requires an ACK (§6.7.3, §6.9.1).

---

## 13. Authentication (§6.1.1, §6.2.6, §6.2.7, §8.6.13–8.6.16, §10)

### Methods (§8.6.13)

The AUTHMETHODS IE (`0x0e`) is a 2-octet bitmask:

| Value | Method | Status |
|---|---|---|
| `0x0001` | *Reserved (was Plaintext)* | withdrawn — do not use |
| `0x0002` | MD5 | supported |
| `0x0004` | RSA | supported |

> "Previous protocol versions supported cleartext passwords; this feature has
> been eliminated. The MD5 and RSA alternatives offer much higher security."
> (§10)

The RFC therefore defines **two** usable methods: MD5 and RSA. A server may also
skip authentication entirely — "the IAX protocol does permit servers to forego
the challenge process described above. This open approach is inherently insecure
and does nothing to prevent unauthorized usage." (§10)

### MD5 challenge construction (§8.6.15)

The normative sentence, in full:

> "The purpose of the MD5 RESULT information element is to offer an MD5 response
> to an authentication CHALLENGE. It carries the UTF-8-encoded challenge result.
> The MD5 Result value is computed by taking the MD5 [RFC1321] digest of the
> challenge string and the password string." (§8.6.15)

**What is concatenated, in what order:**

```
MD5_RESULT = MD5( challenge_string || password_string )
```

i.e. the CHALLENGE IE's data (as received, UTF-8 bytes, **no** null terminator
and **no** separator specified) first, then the shared secret. The order is
challenge-then-password; the RFC states it in that order and nowhere else.

**How it is represented on the wire:** the MD5 RESULT IE (`0x10`) "carries the
UTF-8-encoded challenge result" (§8.6.15) — a *text* representation of the
digest, not the 16 raw bytes.

**RFC ambiguous:** the RFC does not state the text encoding of the digest —
whether hexadecimal, upper or lower case, or zero-padded to 32 characters. It
says only "UTF-8-encoded challenge result". A 32-character lowercase hex string
is the only representation consistent with both "UTF-8-encoded" and the
128-bit digest size, but the RFC does not say so. Record what a live peer
accepts as an observation; do not treat it as spec.

**Also ambiguous:** whether any separator sits between challenge and password
(none is specified, so use none), and whether the CHALLENGE bytes are used
verbatim or after stringprep (§8.6 requires UTF-8 IEs to be prepared per RFC
3454 / RFC 3491, which would in principle apply to CHALLENGE too).

**Constraints on use (§8.6.15):**

> "The MD5 RESULT information element MAY be sent with IAX AUTHREP and REGREQ
> messages if an AUTHREQ or REGAUTH and appropriate CHALLENGE has been received.
> This information element MUST NOT be sent except in response to a CHALLENGE."

Per §6.1.6 it is also carried on a re-sent REGREL.

### RSA (§8.6.16)

> "The result is computed as follows: first, compute the SHA1 digest [RFC3174]
> of the challenge string and second, RSA sign the SHA1 digest using the private
> RSA key as specified in PKCS #1 v2.0 [PKCS]. The RSA keys are stored locally."
> (§8.6.16)

> "Upon receiving an RSA RESULT information element, its value must be verified
> with the sender's public key to match the SHA1 digest [RFC3174] of the
> challenge string." (§8.6.16)

Carried in RSA RESULT (`0x11`), "UTF-8-encoded challenge result", with the same
MUST-NOT-except-in-response-to-CHALLENGE rule. Private keys "SHOULD always be
Triple Data Encryption Standard (3DES) encrypted" (§6.1.1). The RFC does not
specify the wire text encoding of the signature either — same ambiguity as MD5.

### Plaintext

Not available. AUTHMETHODS `0x0001` is "Reserved (was Plaintext)" (§8.6.13); the
PASSWORD IE `0x07` has no defining section (§8.6, Table 1); §10 and §12 both
say cleartext authentication "is not secure and should not be used" (§12). If a
peer offers only `0x0001`, we cannot authenticate under RFC 5456 and should
abandon the exchange.

### Encryption key derivation (§7.4) — related but distinct

> "The key to use in encrypting the messages is computed by taking the CHALLENGE
> IE Section 8.6.14 from the AUTHREQ and concatenating any one of the shared
> passwords then computing the 128-bit MD5 digest of this combination." (§7.4)

Same concatenation order (challenge, then password) but the **raw 128-bit
digest** is used as the AES-128 key, not a text form. Encryption negotiation:
plaintext NEW carrying the ENCRYPTION IE, answered by a plaintext AUTHREQ that
also carries ENCRYPTION; "All subsequent messages in the call MUST be
encrypted." If the AUTHREQ lacks the ENCRYPTION IE, "the calling host MUST
either HANGUP the request or continue with the unencrypted call." (§7.4)

Encrypted framing (§8.1.4): the first 4 bytes of a full frame (2 for a mini
frame) — the call-number words — stay in the clear; the rest is prefixed with
between 16 and 32 bytes of random padding (a padding-length field in the low
4 bits of the 4th byte of that block) and encrypted with AES, each block XORed
with the previous.

---

## 14. DTMF (§6.10.1, §8.2.1, §8.2 table)

DTMF digits travel as a **full frame of frame type `0x01`**, one digit per
frame:

> "The message carries a single digit of DTMF (Dual Tone Multi-Frequency).
> Useful background information about DTMF can be found in [RFC4733] and
> [RFC4734], but, note that IAX does not use the RTP protocol." (§6.10.1)

> "For DTMF frames, the subclass is the actual DTMF digit carried by the frame."
> (§8.2.1)

The §8.2 table gives the subclass domain as `0-9, A-D, *, #` and the data field
as "Undefined" — a DTMF frame carries **no payload**, only the header with the
digit in the subclass.

Because a DTMF frame is a full frame carrying media, it requires an ACK
("Upon receiving any media message, except the abbreviated audio and video Mini
Frames, an ACK message MUST be sent", §6.10) and it increments OSeqno (§7).

**Begin/end semantics: none.** RFC 5456 specifies **no** DTMF BEGIN or END
frames, no duration field, no volume field, and no separate "digit start" /
"digit stop" frame types or control subclasses. One frame carries one complete
digit. This is explicitly unlike RFC 4733, which the RFC cites only as
background while noting "IAX does not use the RTP protocol" (§6.10.1).

**RFC ambiguous:** the RFC never states the numeric encoding of the digit in the
subclass field — it says only "the actual DTMF digit". The 16 named symbols
(`0`–`9`, `A`–`D`, `*`, `#`) all have ASCII codes ≤ 0x7F, so they fit the 7-bit
subclass field with `C = 0` if ASCII is intended, but the RFC does not say
"ASCII". It also does not say how digit duration is conveyed, or what a receiver
should do about repeated identical digits.

---

## 15. Call number allocation (§8.1.1, §4, §6.2.2, §6.7.1, §8.1.3)

- Both source and destination call numbers are **15-bit** fields (§8.1.1). The
  representable range is therefore 0 … 32767.
- **0 is not usable as a source call number.** Meta frames are identified by the
  first 16 bits being all zero (§8.1.3.1, §8.1.3.2); a mini frame (F = 0) with
  source call number 0 would be indistinguishable from a meta frame. So allocate
  source call numbers from **1 … 32767**.
  **RFC ambiguous:** the RFC never states the allocation range as such. The
  1…32767 restriction is forced by the meta-frame detection rule, not written
  down anywhere as a range.
- **0 as a destination call number means "none yet"**: a NEW has no destination
  call number because "the remote peer's source call identifier is not created
  until after receipt of this frame" (§6.2.2), and "A POKE MUST have 0 as its
  destination call number" (§6.7.1).
- Uniqueness: "The source call number for an active call MUST NOT be in use by
  another call on the same client." (§8.1.1)
- Reuse: "Call numbers MAY be reused once a call is no longer active, i.e.,
  either when there is positive acknowledgment that the call has been destroyed
  or when all possible timeouts for the call have expired." (§8.1.1)
- Assignment: "Before sending a NEW message, the local IAX peer MUST assign a
  source call identifier that is not currently being used for another call."
  (§6.2.2)

**How a call is identified.** By the *pair* of numbers, one chosen by each peer:

> "A call leg is marked with two unique integers, one assigned by each peer
> involved in creating the call leg." (§4)

> "Call legs are labeled with a pair of identifiers. Each end of the call leg
> assigns the source or destination identifier during the call leg creation
> process." (§6.2.1)

On receive, demultiplex on the frame's **destination** call number (that is
*our* number for the call) — plus the peer's address, since call numbers are
only unique per peer. On send, put our number in **source** and the peer's in
**destination**. The pair swaps meaning with direction; §6.2.5 refers to "the
same source/destination call identifiers" as the identity of a call leg.

The CALLNO IE (`0x15`, §8.6.20) carries a call number "in the same manner as a
source call number or destination call number is specified in a frame header",
2 octets, for transfers only.

---

## 16. Other requirements relevant to a minimal client

Collected MUSTs that are easy to miss.

**Frame construction**
- Null frames (type `0x05`) "MUST NOT be transmitted." (§8.2.5)
- On NEW: "A NEW message MUST include the 'version' IE, and it MUST be the first
  IE; the order of other IEs is unspecified." (§6.2.2, §8.6.10) VERSION data is
  2 octets, value `0x0002` (§8.6.10).
- §6.2.2's NEW IE table additionally marks **Codecs Prefs** (`0x2d`), **Calling
  Presentation** (`0x26`), **Calling TON** (`0x27`), **Calling TNS** (`0x28`),
  **Format** (`0x09`), and **Called Number** (`0x01`) as *Required*.
  **RFC ambiguous:** §8.6.35 says CODEC PREFS "MAY be sent with IAX NEW
  messages" and that "If the CODEC PREFS information element is absent, CODEC
  negotiation takes place via the CAPABILITY and FORMAT information elements" —
  directly contradicting "Required" in §6.2.2's table. Send CAPABILITY + FORMAT
  as the negotiation mechanism; include the Q.931 caller-ID IEs since §8.6.29–31
  each say "MUST be sent with IAX NEW messages".
- ACCEPT "MUST include the 'format' IE… The CODEC format MUST be one of the
  formats sent in the associated NEW command." (§6.2.3)
- "If a subsequent ACCEPT message is received for a call that has already
  started, or has not sent a NEW message, the message MUST be ignored."
  (§6.2.3)

**Mandatory message handling**
- Unknown/unsupported subclass → UNSUPPORT with the IAX UNKNOWN IE (§6.9.5,
  §6.3.1, §8.6.22).
- INVAL received → destroy our side of the call (§6.9.2).
- HANGUP received → immediate ACK, destroy, INVAL anything further (§6.2.5).
- PING → PONG; POKE → PONG; PONG → ACK (§6.7.1–6.7.3).
- LAGRQ → LAGRP echoing the time-stamp (§6.7.4, §6.7.5).
- HTML frame on a channel that does not support HTML → HTML frame with subclass
  `0x11` (§6.10.6).
- Control messages "MUST only be sent after an IAX call leg has been ACCEPTed."
  (§6.3.1)
- RINGING received → "the peer MUST pass this indication to the calling party,
  unless the calling party has already received such indication." (§6.3.3)
- ANSWER received → "any ring-back or other progress tones MUST be terminated
  and the communications channel MUST be opened." (§6.3.4)
- Mid-call messages we may safely ignore if unsupported: FLASH ("if it is not
  expected, it SHOULD be ignored", §6.4.1), HOLD/UNHOLD (§6.4.2, §6.4.3),
  QUELCH/UNQUELCH ("If the remote system cannot perform this request, it SHOULD
  be ignored", §6.4.4, §6.4.5).

**Registration role obligations (§6.1)**
- REGREQ: "Registrants MUST implement this message and registrars MUST be able
  to process it." (§6.1.2)
- REGAUTH: "Registrars MUST implement this message and registrants MUST be able
  to process it." (§6.1.3)
- REGACK: "Registrars MUST be able to send this message and registrants MUST be
  able to process it." (§6.1.4)
- REGREJ: "Both registrants and registrars MUST be capable of sending and
  processing this message." (§6.1.5)
- REGREL: "Registrants SHOULD be capable of sending this message and registrars
  MUST be able to process it." (§6.1.6)
- REGAUTH received → "the registrant MUST resend the REGREQ or REGREL message
  with one of the requested credentials, if it has the specified credentials."
  (§6.1.3)

**Optional subsystems we are not obliged to implement**
- Registration is OPTIONAL (§6, §6.1.1) — though a client that wants to receive
  calls needs it.
- Call path optimisation / transfers (TXREQ…TXREJ) is OPTIONAL (§6, §6.5).
- Digit dialling (DPREQ/DPREP/DIAL) is OPTIONAL: "The dialing portion of the IAX
  protocol MAY be implemented for the client/phone-side, server-side or not all."
  (§6.8)
- Trunking (§7.1) — we do not implement it; see §3 above.

**Defaults worth hard-coding**
| Default | Value | Section |
|---|---|---|
| UDP port | 4569 | §3, §11 |
| Protocol version | 2 (`0x0002`) | §8.6.10 |
| Retry limit before teardown | 4 | §7 |
| Max retransmission interval | 10 s | §7.2.1 |
| Initial retransmission interval | 2 × last measured PING/PONG RTT | §7.2.1 |
| PING interval | 20 s (default) | §6.7.2 |
| Registration refresh if REFRESH absent | 60 s | §6.1.1, §6.1.4, §8.6.18 |
| DPREP cache lifetime if REFRESH absent | 10 minutes | §6.8.2, §8.6.18 |
| Sampling rate if SAMPLINGRATE absent | 8 kHz | §8.6.32 |
| Called context if CALLED CONTEXT absent | "Default" | §6.2.2 |
| Full-frame resync of mini time-stamp | every `0x8000` ms (see §11) | §6.10, §8.1.2 |

**URI form (§5.1)** — `iax:[username@]host[:port][/number[?context]]`; port
defaults to 4569; all components except the username compare case-insensitively
and must be normalised to lower case before comparison (§5.2).

---

## 17. Traps

Things an implementer of this protocol is likely to get wrong. Each cites the
section that governs it.

1. **The R bit is not part of the destination call number.** Byte 2 bit 0 is the
   retransmit flag; the destination call number is the remaining 15 bits. Mask
   with `0x7FFF`, not `0xFFFF`. The same trap in reverse applies to the F bit
   and the source call number in bytes 0–1. (§8.1.1)

2. **The subclass field is 7 bits, not 8, and the C bit changes its meaning
   entirely.** `C = 1` means the value is `1 << field`, not `field`. Reading
   byte 11 as a plain `UInt8` gives 0x82 for µ-law where the intended value is
   4. And a decoder must accept *both* encodings for small powers of two —
   nothing in the RFC forbids `0x82` or `0x04` for µ-law. (§8.1.1)

3. **µ-law is `0x00000004`, which is `1 << 2`, which is subclass field 2.**
   Three different numbers for the same codec depending on where you are
   looking. Confusing "the codec is 2" (the bit index / subclass field) with
   "the codec is 4" (the bitmask value that goes in FORMAT and CAPABILITY IEs)
   will produce a call that negotiates a-law or GSM. (§8.7, §8.1.1, §8.6.8)

4. **OSeqno does not increment for ACK, INVAL, TXCNT, TXACC, VNAK.** Incrementing
   on ACK is the classic mistake and desynchronises the peer within the first
   few frames of a call, because a NEW/ACCEPT/ACK setup already involves two
   ACKs. (§7)

5. **ISeqno: "next expected" vs "highest received" — the RFC says both.** §8.1.1
   says next-expected; §7 says highest-received. Pick next-expected on send, be
   tolerant of one-off values on receive, and never fail a call over it. (§8.1.1
   vs §7)

6. **Sequence numbers are 8-bit and wrap silently.** Every comparison ("higher
   sequence number than the VNAK's iseqno", "acknowledge all messages up to that
   sequence number") must be modulo-256 serial arithmetic. Naive `>` breaks at
   frame 256 — which in a signalling-light call is minutes in, long after the
   tests passed. (§8.1.1, §6.9.3, §7)

7. **Two contradictory rules for when a full frame must interrupt the mini-frame
   stream: every 32,768 ms (MUST, §6.10) and every 65,536 ms (SHOULD, §8.1.2,
   backed by the §9.6 note "every 65536 ms").** Satisfy both by resyncing at
   every `0x8000` boundary. Getting this wrong means the peer's reconstructed
   32-bit clock drifts a whole 16-bit epoch and audio is dropped or reordered by
   its jitter buffer. (§6.10 vs §8.1.2)

8. **Time-stamps are milliseconds from the *first transmission of the call*, per
   peer, not wall clock and not shared.** DATETIME (IE `0x1f`) is the wall-clock
   value and is a completely different quantity. Each peer's 32-bit clock is
   independent, so both sides resync separately. (§8.1.1, §6.2.2, §8.6.28, §9.6
   note 3)

9. **ACK echoes the received time-stamp — it does not carry the current one.**
   That echoed value is how the peer matches the ACK to the frame it
   acknowledges, so generating a fresh time-stamp silently breaks
   retransmission matching. Same rule for PONG (echoes the PING/POKE) and LAGRP
   (echoes the LAGRQ). (§6.9.1, §6.7.3, §6.7.5)

10. **The MD5 result is challenge-then-password, and it goes on the wire as
    text, not as 16 raw bytes.** Reversing the concatenation order, or writing
    the raw digest into the IE, both produce an auth failure that looks like a
    wrong password. And the RFC never states the text form (hex? case?) — this
    is a genuine gap, not something to guess silently. (§8.6.15)

11. **Plaintext authentication does not exist in RFC 5456.** AUTHMETHODS
    `0x0001` is "Reserved (was Plaintext)" and the PASSWORD IE `0x07` appears in
    Table 1 with no defining subsection at all. Code that treats `0x0001` as a
    live plaintext method is implementing a withdrawn feature. (§8.6.13, §8.6,
    §10, §12)

12. **IE ids are not IE section numbers.** Because PASSWORD `0x07` has no
    subsection, §8.6.15 is IE `0x10`, §8.6.20 is IE `0x15`, and so on — the
    offset appears at `0x08` and persists. Deriving one from the other yields
    off-by-one IE ids across most of the table. (§8.6)

13. **APPARENT ADDR's address-family field is byte-swapped relative to
    everything else.** The RFC's IPv4 example shows family `0x0200` (AF_INET = 2
    written little-endian) but port `0x11d9` (4569 written big-endian) in the
    same structure. It is a verbatim memory image of a Linux `sockaddr_in`, not
    a network-order structure. Don't "fix" the family field. (§8.6.17)

14. **APPARENT ADDR: 16 or 18 octets?** The IPv4 diagram shows Data Length
    `0x10` = 16, while the prose says "the total length of the APPARENT ADDR
    information element is 18 octets". Both are right: 16 octets of *data*, 18
    octets *including* the 2-octet IE id + length header. The data-length field
    must say 16. (§8.6.17)

15. **ENCRYPTION IE: prose says 2-octet bitmask, diagram shows data length
    `0x01`.** The methods table lists `0x0001` (AES-128), a 16-bit value. The
    diagram is almost certainly wrong, but the RFC does not resolve it. We do
    not implement encryption, so prefer not to send the IE at all rather than
    guess a length. (§8.6.34)

16. **The IE length field is bytes of *data*, excluding the 2-byte IE header.**
    A parser that advances by `length` instead of `2 + length` walks off into
    the middle of the next IE, and one that advances by `2 + length` from the
    wrong base overruns the frame. Maximum data per IE is 255 bytes. (§8.6)

17. **Meta frames must be tested for *before* the F bit.** The test order is:
    first-16-bits-zero → meta; else F → full; else mini. Testing F first
    classifies every meta frame as a mini frame and feeds trunk headers to the
    audio decoder. This is also why source call number 0 must never be
    allocated. (§8.1.3.1, §8.1.3.2)

18. **Control HANGUP (subclass `0x01` of frame type `0x04`) is not IAX HANGUP
    (subclass `0x05` of frame type `0x06`).** Two different frames, both called
    "hangup", with adjacent-looking numbers. Only the IAX one tears down the
    call leg under §6.2.5. (§8.3 vs §8.4)

19. **A NEW with no destination call number is normal, and so is a POKE with
    destination 0.** Rejecting frames with destination call number 0 as
    malformed breaks both. (§6.2.2, §6.7.1)

20. **Mini frames have no frame type or subclass — the codec is whatever the
    last full voice frame said.** A receiver that decodes mini frames using the
    codec from the ACCEPT's FORMAT IE, rather than tracking the most recent full
    voice frame subclass, breaks under on-the-fly codec renegotiation. (§8.1.2)

21. **When retransmission exhausts, tear down silently — do not send HANGUP.**
    "the call MUST be torn down without any further interaction on this call
    leg" (§7); "without any other indications over the errant IAX call leg"
    (§6.6). Sending a farewell HANGUP to a peer that has already stopped
    answering is both useless and contrary to the text.

22. **§6.9.1's ACK list is not exhaustive.** It omits RINGING and ANSWER, which
    the §9.6 example flow does ACK, and §8.1.1 requires an acknowledgment for
    *all* full frames. Implementing only the §6.9.1 list leaves the peer
    retransmitting RINGING until it gives up on the call. (§6.9.1 vs §8.1.1 and
    §9.6)

23. **TXMEDIA has no subclass value.** §6.5.6 describes the message and Figure 4
    uses it, but the §8.4 table has no entry for it (and §6.5.6's body text
    mistakenly begins "The TXREL message…"). Anyone implementing transfers from
    §6.5 alone will find there is no number to send. (§6.5.6 vs §8.4)

24. **Big-endian is an inference, not a statement.** The RFC never says "network
    byte order". It is the only reading consistent with the bit diagrams — and
    with the `0x11d9` port constant — but the `0x0200` address family in the
    same structure shows the authors were not being rigorous about it. Assume
    big-endian everywhere *except* inside the APPARENT ADDR sockaddr image.
    (§8.1.1 diagrams, §8.6.17)
