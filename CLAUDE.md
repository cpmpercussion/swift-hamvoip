# swift-hamvoip — agent instructions

Swift implementations of amateur radio VoIP protocols (AllStarLink/IAX2,
M17, later EchoLink). Apache-2.0, clean-room.

**Start here:** `docs/DEVELOPMENT-PLAN.md` is the task list. Pick the lowest
unblocked task, read its full entry plus §1 "How to work", and do exactly
that task. Requirements background: `docs/DESIGN-REQUIREMENTS.md`.

## Hard rules (violations get the PR closed)

- **Clean-room:** never fetch/read/search source code of DroidStar, SvxLink,
  EchoLib, thebridge, iaxclient, Asterisk, or any other implementation of
  these protocols. Allowed sources: RFC 5456, the M17 spec, ITU-T G.711,
  and fixtures already in this repo.
- Line 1 of every Swift file: `// SPDX-License-Identifier: Apache-2.0`.
- No sockets in unit tests; network access only behind `DatagramTransport`.
- No third-party dependencies unless the plan task names one.
- One task per branch (`task/<id>`) per PR; `swift build && swift test`
  green before opening it.
