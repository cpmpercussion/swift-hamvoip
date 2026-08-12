# Test fixture provenance

Fixtures live in `Tests/<TargetName>Tests/Fixtures/` and are loaded with
`FixtureLoader` from the `TestSupport` target.

## Where fixtures may come from (LP-1)

1. **Hand-built from the specification.** Write the bytes out field by field
   with a comment naming the spec section that fixes each field. This is the
   preferred source — it makes the test a check on the spec reading, not a
   check on someone else's implementation.
2. **Packet captures of our own sessions**, against nodes and reflectors we
   are licensed to use.

## Where they may NOT come from

Test vectors, capture files, or byte arrays lifted from another
implementation — DroidStar, SvxLink/EchoLib, thebridge, iaxclient, Asterisk,
or anything else. A fixture copied from a GPL project carries that project's
provenance into this repository just as surely as copied source does.

## Format

One datagram per line, hex bytes, whitespace within a line ignored, `#`
begins a comment:

    # RFC 5456 §8.1 full frame header: NEW, source call 1, no destination
    8001 0000 00000000 00 00 06 01

## Capture-derived fixtures (`live-*.hex`)

The fixtures named `live-*.hex` come from source 2 above: packet captures of
the maintainer's own sessions against the maintainer's own node. They are cut
from the capture by `scripts/pcap-to-fixture.py`, which strips the link-layer,
IP and UDP headers and writes out the UDP payload — the octets RFC 5456 §5
calls a frame — one per line, annotated.

Three rules keep them honest:

- **The capture files themselves are not in the repository.** They are large,
  and they are personal traffic. Each generated fixture carries the command
  that regenerates it and the SHA-256 of the capture it came from, so a
  fixture can always be traced back to, and re-cut from, one specific file.
- **Octets are never edited.** A fixture may contain a *subset* of a capture's
  datagrams — that is what the `[n]` index in each comment is for, so a gap is
  visible — but no line is ever hand-adjusted to make a test pass. Where a
  replay needs different call numbers, the *test* is built around the
  capture's numbers, not the other way round.
- **Only the peer's half is checked in**, unless our own half is what is under
  test. A capture of an authenticated exchange contains our MD5 RESULT, which
  is a digest of a live credential; there is no reason to keep one in the
  repository when the replay does not need it.

Regenerate one with, for example:

    scripts/pcap-to-fixture.py wrap.pcap --stream 0 --dir in --range 6500:6545

and pass `--summary` first to find the range worth cutting.

## TCP captures (`--transport tcp`)

IAX2 and M17 are datagram protocols, so a capture of one is already a sequence
of frames. EchoLink over a proxy is not: it is TCP 8100, and a byte stream has
no frame boundaries of its own. `--transport tcp` reassembles each direction
and walks it with the 9-byte proxy header — type(1), peer IPv4(4), length(4,
**little-endian**). The unit of `--range` and of the `[n]` index is therefore
the **proxy frame**, not the TCP segment, and the two do not line up.

    scripts/pcap-to-fixture.py <capture> --transport tcp --summary
    scripts/pcap-to-fixture.py <capture> --transport tcp --range 0:3

Four things differ from the UDP mode, each because getting it wrong is silent
rather than loud:

- **The capture must contain the TCP handshake.** Without a SYN the stream
  begins at an arbitrary point inside a frame, and walking it emits a handful
  of plausible-looking frames of pure misalignment before it happens to
  resynchronise. The script refuses; `--assume-aligned` overrides it, and
  should not be needed.
- **The login exchange is not framed.** It precedes the framing: an 8-byte
  ASCII hex nonce from the proxy, then the callsign LF-terminated and 16 raw
  digest bytes from the client. It is split off and emitted as its own line.
- **A stream must decode with zero bytes left over.** That is the check that
  the framing is being read correctly — a wrong header size or endianness
  desynchronises within a few frames. A capture stopped mid-frame is the one
  legitimate exception, and needs `--allow-trailing`.
- **Type `0x02` frames are refused.** In the EchoLink captures those carry the
  operator's account password one way and the station directory — thousands of
  other operators' callsigns and addresses — the other. `--allow-tcp-data`
  overrides it for a frame that has been checked to hold neither.

### The source captures are cited by digest, not by path

For `live-*.hex` above, the fixture names its capture. The EchoLink captures
are the deliberate exception: one holds a live credential and another the whole
directory, and nothing committed here should help locate either. Their
regeneration recipes therefore read `<capture>` and identify the file by its
**SHA-256 only**, which is why `--name-capture` has no effect in TCP mode. The
digests are recorded alongside the captures themselves, outside both repos.

This is not an oversight to be tidied up later. It is the same call the OQ-9
entry in `docs/reference/PROVENANCE.md` made, for the same reason.
