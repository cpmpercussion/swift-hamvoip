# swift-hamvoip — agent instructions

Swift implementations of amateur radio VoIP protocols (AllStarLink/IAX2,
M17, later EchoLink). Apache-2.0, clean-room.

**Start here:** `docs/DEVELOPMENT-PLAN.md` is the task list. Pick the lowest
unblocked task, read its full entry plus §1 "How to work", and do exactly
that task. Requirements background: `docs/DESIGN-REQUIREMENTS.md`, which is
authoritative for **both** repos' requirement IDs.

**The app's task list is not here.** `APP-*` and `BLE-*` moved to
`currawong/docs/DEVELOPMENT-PLAN.md` on 2026-08-21; §1 and the requirements
still govern them. An app task that needs a library change gets a library task
here, on its own branch and PR, cited from the app's plan by ID.

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
