#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# pcap-to-fixture.py — turn a packet capture of one of our own IAX2 sessions
# into the hex-dump fixture format that `FixtureLoader` reads.
#
# Provenance (LP-1): this only ever runs against captures of the maintainer's
# own traffic against the maintainer's own node. See `Tests/FIXTURES.md`.
#
# It parses libpcap files itself — no third-party dependency, and no reliance
# on a dissector's idea of what an IAX2 frame is. Link-layer, IPv4 and UDP
# headers are stripped; the UDP payload is what IAX2 defines a datagram to be
# (RFC 5456 §5), and that is what goes in the fixture.
#
# Usage:
#   pcap-to-fixture.py CAPTURE.pcap --port 4569 [--stream N] [--dir in|out|both]
#                      [--range FIRST:LAST] [--summary]
#
# `--summary` prints one annotated line per datagram instead of the fixture,
# which is how you find the range you want before you cut it.

import argparse
import hashlib
import os
import struct
import sys

# ---------------------------------------------------------------- pcap reader

LINKTYPE_NULL = 0
LINKTYPE_ETHERNET = 1
LINKTYPE_RAW = 101
LINKTYPE_LOOP = 108  # OpenBSD loopback
LINKTYPE_LINUX_SLL = 113  # Linux cooked capture
LINKTYPE_LINUX_SLL2 = 276  # Linux cooked capture v2 — what the VM tap emits


def read_pcap(path):
    """Yield (timestamp_seconds, link_layer_bytes) for every record."""
    with open(path, "rb") as handle:
        header = handle.read(24)
        if len(header) < 24:
            raise SystemExit(f"{path}: too short to be a pcap")
        magic = header[:4]
        if magic == b"\xd4\xc3\xb2\xa1":
            endian, nano = "<", False
        elif magic == b"\xa1\xb2\xc3\xd4":
            endian, nano = ">", False
        elif magic == b"\x4d\x3c\xb2\xa1":
            endian, nano = "<", True
        elif magic == b"\xa1\xb2\x3c\x4d":
            endian, nano = ">", True
        else:
            raise SystemExit(f"{path}: not a libpcap file (magic {magic.hex()})")
        linktype = struct.unpack(endian + "I", header[20:24])[0]
        while True:
            record = handle.read(16)
            if len(record) < 16:
                return
            seconds, fraction, captured, _original = struct.unpack(endian + "IIII", record)
            payload = handle.read(captured)
            if len(payload) < captured:
                return
            stamp = seconds + fraction / (1e9 if nano else 1e6)
            yield stamp, linktype, payload


def strip_link_layer(linktype, frame):
    """Return the IPv4 packet inside a link-layer frame, or None."""
    if linktype == LINKTYPE_ETHERNET:
        if len(frame) < 14:
            return None
        ethertype = struct.unpack("!H", frame[12:14])[0]
        return frame[14:] if ethertype == 0x0800 else None
    if linktype in (LINKTYPE_NULL, LINKTYPE_LOOP):
        if len(frame) < 4:
            return None
        return frame[4:]
    if linktype == LINKTYPE_LINUX_SLL:
        if len(frame) < 16:
            return None
        ethertype = struct.unpack("!H", frame[14:16])[0]
        return frame[16:] if ethertype == 0x0800 else None
    if linktype == LINKTYPE_LINUX_SLL2:
        # 2 protocol, 2 reserved, 4 ifindex, 2 ARPHRD, 1 packet type,
        # 1 address length, 8 address.
        if len(frame) < 20:
            return None
        ethertype = struct.unpack("!H", frame[0:2])[0]
        return frame[20:] if ethertype == 0x0800 else None
    if linktype == LINKTYPE_RAW:
        return frame
    raise SystemExit(f"unsupported link type {linktype}")


def udp_datagrams(path, port):
    """Yield (stamp, src_ip, src_port, dst_ip, dst_port, payload) on `port`."""
    for stamp, linktype, frame in read_pcap(path):
        packet = strip_link_layer(linktype, frame)
        if packet is None or len(packet) < 20:
            continue
        version_ihl = packet[0]
        if version_ihl >> 4 != 4:
            continue
        header_length = (version_ihl & 0x0F) * 4
        if packet[9] != 17 or len(packet) < header_length + 8:  # protocol 17 = UDP
            continue
        source_ip = ".".join(str(byte) for byte in packet[12:16])
        destination_ip = ".".join(str(byte) for byte in packet[16:20])
        udp = packet[header_length:]
        source_port, destination_port, length, _checksum = struct.unpack("!HHHH", udp[:8])
        if port not in (source_port, destination_port):
            continue
        payload = udp[8:length] if 8 <= length <= len(udp) else udp[8:]
        if payload:
            yield stamp, source_ip, source_port, destination_ip, destination_port, payload


# ------------------------------------------------------------ IAX2 decoration
# Only enough of RFC 5456 §8 to label a line in a comment. The Swift parser is
# the authority; this is a reading aid.

FRAME_TYPES = {
    0x01: "DTMF", 0x02: "VOICE", 0x03: "VIDEO", 0x04: "CONTROL",
    0x05: "NULL", 0x06: "IAX", 0x07: "TEXT", 0x08: "IMAGE", 0x09: "HTML",
    0x0A: "COMFORT NOISE",
}

IAX_SUBCLASSES = {
    0x01: "NEW", 0x02: "PING", 0x03: "PONG", 0x04: "ACK", 0x05: "HANGUP",
    0x06: "REJECT", 0x07: "ACCEPT", 0x08: "AUTHREQ", 0x09: "AUTHREP",
    0x0A: "INVAL", 0x0B: "LAGRQ", 0x0C: "LAGRP", 0x0D: "REGREQ",
    0x0E: "REGAUTH", 0x0F: "REGACK", 0x10: "REGREJ", 0x11: "REGREL",
    0x12: "VNAK", 0x13: "DPREQ", 0x14: "DPREP", 0x15: "DIAL",
    0x16: "TXREQ", 0x17: "TXCNT", 0x18: "TXACC", 0x19: "TXREADY",
    0x1A: "TXREL", 0x1B: "TXREJ", 0x1C: "QUELCH", 0x1D: "UNQUELCH",
    0x1E: "POKE", 0x20: "MWI", 0x21: "UNSUPPORT", 0x22: "TRANSFER",
}

CONTROL_SUBCLASSES = {
    0x01: "HANGUP", 0x03: "RINGING", 0x04: "ANSWER", 0x05: "BUSY",
    0x08: "CONGESTION", 0x0E: "PROGRESS", 0x0F: "PROCEEDING", 0x10: "HOLD",
    0x11: "UNHOLD",
}


def describe(payload):
    """A one-line human label for an IAX2 datagram."""
    if len(payload) < 4:
        return "runt"
    first = struct.unpack("!H", payload[:2])[0]
    if first & 0x8000 == 0:
        # §8.1.2 mini frame: 16-bit source call number, 16-bit time-stamp.
        stamp = struct.unpack("!H", payload[2:4])[0]
        return f"mini  call {first:5d}  ts {stamp:5d}  {len(payload) - 4:3d}B audio"
    if len(payload) < 12:
        return "runt full frame"
    source = first & 0x7FFF
    destination_word = struct.unpack("!H", payload[2:4])[0]
    retransmit = "R" if destination_word & 0x8000 else " "
    destination = destination_word & 0x7FFF
    stamp = struct.unpack("!I", payload[4:8])[0]
    outbound, inbound, frame_type = payload[8], payload[9], payload[10]
    subclass_byte = payload[11]
    if subclass_byte & 0x80:
        subclass = f"2^{subclass_byte & 0x7F}"
    else:
        subclass = str(subclass_byte)
    if frame_type == 0x06:
        name = IAX_SUBCLASSES.get(subclass_byte, f"IAX {subclass}")
    elif frame_type == 0x04:
        name = "CONTROL " + CONTROL_SUBCLASSES.get(subclass_byte, subclass)
    elif frame_type == 0x02:
        name = f"VOICE fmt {subclass}"
    elif frame_type == 0x01:
        name = f"DTMF '{chr(subclass_byte)}'"
    else:
        name = f"{FRAME_TYPES.get(frame_type, frame_type)} {subclass}"
    return (f"full{retransmit} {source:5d}->{destination:<5d} ts {stamp:10d} "
            f"O{outbound:3d} I{inbound:3d}  {name}  {len(payload) - 12:3d}B")


# ------------------------------------------------------------------- fixture

def split_information_elements(payload):
    """Split an IAX frame payload into §8.6 TLVs, or return None if it is not
    a clean sequence of them. Purely cosmetic — it decides where to put spaces."""
    groups = []
    offset = 0
    while offset < len(payload):
        if offset + 2 > len(payload):
            return None
        length = payload[offset + 1]
        end = offset + 2 + length
        if end > len(payload):
            return None
        groups.append(payload[offset:end].hex())
        offset = end
    return groups


def hex_line(payload):
    """Hex, grouped so the header fields line up with §8.1.1's diagram."""
    body = payload.hex()
    if payload[0] & 0x80:  # full frame: 2 2 4 1 1 1 1, then the payload
        groups = [body[0:4], body[4:8], body[8:16], body[16:18],
                  body[18:20], body[20:22], body[22:24]]
        rest = payload[12:]
        # An IAX-type frame carries information elements (§8.6); spacing them
        # apart makes the fixture readable next to the hand-built ones.
        if rest and payload[10] == 0x06:
            groups.extend(split_information_elements(rest) or [rest.hex()])
        elif rest:
            groups.append(rest.hex())
        return " ".join(group for group in groups if group)
    # Mini frame: 2 2, then the audio (§8.1.2).
    groups = [body[0:4], body[4:8], body[8:]]
    return " ".join(group for group in groups if group)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture")
    parser.add_argument("--port", type=int, default=4569,
                        help="IAX2 port; the peer holding it is 'the node' (default 4569)")
    parser.add_argument("--stream", type=int, default=0,
                        help="which UDP conversation, in first-seen order (default 0)")
    parser.add_argument("--dir", choices=("in", "out", "both"), default="both",
                        help="'in' = node->client only, 'out' = client->node only")
    parser.add_argument("--range", default=None, metavar="FIRST:LAST[,FIRST:LAST…]",
                        help="inclusive 0-based index ranges within the chosen stream")
    parser.add_argument("--full-frames-only", action="store_true",
                        help="drop mini frames (§8.1.2) — they carry no sequence numbers, "
                             "so dropping them leaves the reliable stream intact")
    parser.add_argument("--summary", action="store_true",
                        help="print an annotated index instead of a fixture")
    parser.add_argument("--preamble", default=None, metavar="PATH",
                        help="file of comment lines to copy above the generated fixture")
    arguments = parser.parse_args()

    streams = {}
    order = []
    for record in udp_datagrams(arguments.capture, arguments.port):
        _stamp, source_ip, source_port, destination_ip, destination_port, _payload = record
        if source_port == arguments.port:
            key = (destination_ip, destination_port)
        else:
            key = (source_ip, source_port)
        if key not in streams:
            streams[key] = []
            order.append(key)
        streams[key].append(record)

    if not order:
        raise SystemExit("no IAX2 datagrams found")
    if arguments.stream >= len(order):
        raise SystemExit(f"capture holds {len(order)} streams; --stream {arguments.stream} is out of range")

    records = streams[order[arguments.stream]]
    base = records[0][0]

    if not arguments.summary:
        if arguments.preamble:
            with open(arguments.preamble, encoding="utf-8") as handle:
                sys.stdout.write(handle.read())
        # A regeneration recipe, so the fixture can always be re-cut from the
        # capture it came from, and a digest so it is obvious if that capture
        # is ever not the same file (LP-1: `Tests/FIXTURES.md`).
        with open(arguments.capture, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        recipe = " ".join(["scripts/pcap-to-fixture.py", os.path.basename(arguments.capture),
                           f"--stream {arguments.stream}", f"--dir {arguments.dir}"]
                          + ([f"--range {arguments.range}"] if arguments.range else [])
                          + (["--full-frames-only"] if arguments.full_frames_only else []))
        print("# Machine-generated. The captures themselves are not in the repository —")
        print("# they are the maintainer's own, and large. Regenerate with:")
        print(f"#   {recipe}")
        print(f"# Capture SHA-256: {digest}")
        print("#")
        print("# Each datagram is the UDP payload verbatim — the octets RFC 5456 §5")
        print("# defines as an IAX2 frame. `[n]` is the datagram's index in the capture")
        print("# stream, so a gap in the indices is a datagram deliberately left out.")
        print()

    spans = [(0, len(records) - 1)]
    if arguments.range:
        spans = []
        for span in arguments.range.split(","):
            text_first, _, text_last = span.partition(":")
            spans.append((int(text_first) if text_first else 0,
                          int(text_last) if text_last else len(records) - 1))

    for index, record in enumerate(records):
        stamp, source_ip, source_port, _destination_ip, _destination_port, payload = record
        inbound = source_port == arguments.port
        if arguments.dir == "in" and not inbound:
            continue
        if arguments.dir == "out" and inbound:
            continue
        if not any(first <= index <= last for first, last in spans):
            continue
        if arguments.full_frames_only and not payload[0] & 0x80:
            continue
        arrow = "<==" if inbound else "==>"
        if arguments.summary:
            print(f"{index:5d} {stamp - base:8.3f} {arrow} {describe(payload)}")
        else:
            print(f"# [{index}] {stamp - base:.3f}s {arrow} {describe(payload)}")
            print(hex_line(payload))

    print(f"# {len(order)} stream(s); stream {arguments.stream} holds {len(records)} datagrams",
          file=sys.stderr)


if __name__ == "__main__":
    main()
