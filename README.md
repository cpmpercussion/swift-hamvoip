# QSOKit

Permissively licensed Swift implementations of unencumbered amateur radio VoIP
protocols, for Apple platforms.

## Why

Every existing cross-platform client for these modes is GPL-licensed, which
prevents App Store distribution. There is no permissively licensed Swift
implementation of IAX2, and none of M17 in any form.

QSOKit covers only modes with no patent encumbrance:

- **AllStarLink** — IAX2 (RFC 5456), G.711 µ-law
- **M17** — reflector protocol, Codec2 3200
- **EchoLink** — RTP/GSM 06.10 *(planned, see OQ-1)*

DMR, System Fusion, D-STAR, P25 and NXDN are permanently out of scope. All
require AMBE or AMBE+2, which is patented.

## Status

Pre-alpha. Design requirements are drafted; no protocol code has been written.

See [`docs/DESIGN-REQUIREMENTS.md`](docs/DESIGN-REQUIREMENTS.md).

## Clean-room policy

All protocol code here is written from published specifications and from packet
captures of our own sessions. Contributors must not consult GPL-licensed
implementations (DroidStar, SvxLink/EchoLib, thebridge, iaxclient) at source
level. See §3 of the requirements document. Pull requests that cannot attest to
this will not be merged.

## Licence

Apache-2.0. Chosen over MIT for its express patent grant.
