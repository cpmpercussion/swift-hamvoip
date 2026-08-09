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
