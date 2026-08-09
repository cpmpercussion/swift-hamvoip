# Contributing

## Clean-room attestation

By opening a pull request you attest that the code you are contributing was
written without reference to the source of any GPL-licensed implementation of
these protocols. Permitted sources are published specifications and your own
packet captures.

This is not pedantry. GPL-derived code cannot be distributed through the App
Store, and unpicking provenance after the fact is far more expensive than
getting it right up front.

## Requirements

Every source file carries an SPDX identifier:

    // SPDX-License-Identifier: Apache-2.0

Protocol code must be testable without a network connection. Frame parsers take
bytes and return values; anything touching a socket lives behind a protocol.
