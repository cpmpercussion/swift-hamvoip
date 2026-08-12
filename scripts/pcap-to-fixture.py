#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# pcap-to-fixture.py — turn a packet capture of one of our own sessions into
# the hex-dump fixture format that `FixtureLoader` reads.
#
# Provenance (LP-1): this only ever runs against captures of the maintainer's
# own traffic against the maintainer's own node. See `Tests/FIXTURES.md`.
#
# It parses libpcap files itself — no third-party dependency, and no reliance
# on a dissector's idea of what a frame is.
#
# Two transports, because the two protocols put their frames on the wire
# differently:
#
#   --transport udp (default)  IAX2. Link-layer, IPv4 and UDP headers are
#                              stripped; the UDP payload is what IAX2 defines a
#                              datagram to be (RFC 5456 §5), and one datagram
#                              is one fixture line.
#
#   --transport tcp            EchoLink over a proxy (EL-1). There are no
#                              datagrams to strip: each direction is a byte
#                              stream that has to be reassembled and then walked
#                              header by header. The unit of `--range` and of
#                              the `[n]` index is therefore the *proxy frame*,
#                              not the TCP segment — frame boundaries and
#                              segment boundaries do not coincide.
#
# Usage:
#   pcap-to-fixture.py CAPTURE.pcap --port 4569 [--stream N] [--dir in|out|both]
#                      [--range FIRST:LAST] [--summary]
#   pcap-to-fixture.py CAPTURE.pcap --transport tcp [--port 8100] [--summary]
#
# `--summary` prints one annotated line per frame instead of the fixture, which
# is how you find the range you want before you cut it.

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
    """Yield (timestamp_seconds, linktype, link_layer_bytes) for every record.

    Both container formats, chosen by magic: classic libpcap, and pcapng —
    which is what `tcpdump` on macOS writes by default, and therefore what all
    three EchoLink captures are (EL-1).
    """
    with open(path, "rb") as handle:
        if handle.read(4) == b"\x0a\x0d\x0d\x0a":
            handle.seek(0)
            yield from read_pcapng(handle, path)
            return
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


def read_pcapng(handle, path):
    """Yield (stamp, linktype, frame) from a pcapng file.

    Only the three block types a capture actually needs: the section header for
    the byte order, the interface description for the link type and time-stamp
    resolution, and the enhanced packet block for the packets themselves.
    Everything else — name resolution, statistics, options — is skipped by
    length, which is what the format's block framing is for.
    """
    endian = "<"
    interfaces = []  # (linktype, ticks_per_second) in interface-id order
    while True:
        header = handle.read(8)
        if len(header) < 8:
            return
        block_type = struct.unpack(endian + "I", header[:4])[0]
        if header[:4] == b"\x0a\x0d\x0d\x0a":
            # Section header: the byte-order magic decides the endianness of
            # this section, including its own length field.
            body = handle.read(4)
            if len(body) < 4:
                return
            endian = "<" if body == b"\x4d\x3c\x2b\x1a" else ">"
            block_length = struct.unpack(endian + "I", header[4:8])[0]
            handle.read(max(0, block_length - 12))  # 8 header + 4 magic already read
            interfaces = []
            continue
        block_length = struct.unpack(endian + "I", header[4:8])[0]
        if block_length < 12:
            raise SystemExit(f"{path}: malformed pcapng block (length {block_length})")
        body = handle.read(block_length - 12)
        handle.read(4)  # trailing block length

        if block_type == 0x00000001:  # interface description
            linktype = struct.unpack(endian + "H", body[:2])[0]
            resolution = 6  # if_tsresol defaults to 10^-6
            offset = 8
            while offset + 4 <= len(body):
                code, length = struct.unpack(endian + "HH", body[offset:offset + 4])
                value = body[offset + 4:offset + 4 + length]
                if code == 0:
                    break
                if code == 9 and length >= 1:  # if_tsresol
                    resolution = value[0]
                offset += 4 + length + (-length % 4)
            if resolution & 0x80:
                ticks = float(2 ** (resolution & 0x7F))
            else:
                ticks = float(10 ** resolution)
            interfaces.append((linktype, ticks))
        elif block_type == 0x00000006:  # enhanced packet
            interface_id, stamp_high, stamp_low, captured, _original = struct.unpack(
                endian + "IIIII", body[:20])
            if interface_id >= len(interfaces):
                continue
            linktype, ticks = interfaces[interface_id]
            stamp = ((stamp_high << 32) | stamp_low) / ticks
            yield stamp, linktype, body[20:20 + captured]
        elif block_type == 0x00000003:  # simple packet — no timestamp of its own
            if not interfaces:
                continue
            linktype, _ticks = interfaces[0]
            yield 0.0, linktype, body[4:]


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


# ------------------------------------------------------------- TCP reassembly
# EL-1. A TCP capture is not a sequence of messages, so nothing here can work
# the way `udp_datagrams` does. Each direction is reassembled into one byte
# stream, and the stream is then walked frame by frame by the caller.


def tcp_segments(path, port):
    """Yield (stamp, src_ip, src_port, dst_ip, dst_port, seq, syn, payload)."""
    for stamp, linktype, frame in read_pcap(path):
        packet = strip_link_layer(linktype, frame)
        if packet is None or len(packet) < 20:
            continue
        version_ihl = packet[0]
        if version_ihl >> 4 != 4:
            continue
        header_length = (version_ihl & 0x0F) * 4
        if packet[9] != 6 or len(packet) < header_length + 20:  # protocol 6 = TCP
            continue
        total_length = struct.unpack("!H", packet[2:4])[0]
        # Trust the IP total-length field over the captured length: a short
        # snaplen or ethernet padding would otherwise invent payload bytes.
        if 20 <= total_length <= len(packet):
            packet = packet[:total_length]
        source_ip = ".".join(str(byte) for byte in packet[12:16])
        destination_ip = ".".join(str(byte) for byte in packet[16:20])
        tcp = packet[header_length:]
        source_port, destination_port = struct.unpack("!HH", tcp[:4])
        if port not in (source_port, destination_port):
            continue
        sequence = struct.unpack("!I", tcp[4:8])[0]
        data_offset = (tcp[12] >> 4) * 4
        flags = tcp[13]
        payload = tcp[data_offset:] if data_offset <= len(tcp) else b""
        yield (stamp, source_ip, source_port, destination_ip, destination_port,
               sequence, bool(flags & 0x02), payload)


def reassemble(segments):
    """Turn one direction's segments into (bytes, [(offset, stamp)], saw_syn).

    Retransmissions and overlaps are dropped — the first copy of a byte wins,
    which is what the receiver saw. A *gap* is fatal rather than papered over:
    a missing segment desynchronises every frame after it, and a fixture cut
    from a desynchronised stream would be silently wrong.
    """
    initial = None
    saw_syn = False
    for _stamp, sequence, syn, payload in segments:
        if syn:
            initial = (sequence + 1) & 0xFFFFFFFF
            saw_syn = True
            break
    if initial is None:
        # No SYN in the capture — it began mid-connection. The first data
        # segment defines the origin, so offsets stay relative and honest, but
        # byte 0 is then some arbitrary point inside a frame rather than the
        # start of one. The caller must not walk such a stream blindly.
        data = [entry for entry in segments if entry[3]]
        if not data:
            return b"", [], False
        initial = min(entry[1] for entry in data)

    placed = []
    for stamp, sequence, _syn, payload in segments:
        if not payload:
            continue
        offset = (sequence - initial) & 0xFFFFFFFF
        placed.append((offset, stamp, payload))
    placed.sort(key=lambda entry: entry[0])

    stream = bytearray()
    stamps = []
    for offset, stamp, payload in placed:
        end = offset + len(payload)
        if end <= len(stream):
            continue  # pure retransmission of bytes we already have
        if offset > len(stream):
            raise SystemExit(
                f"gap in the TCP stream: {offset - len(stream)} byte(s) missing at "
                f"offset {len(stream)}. The capture is incomplete, and every frame "
                f"after the gap would decode wrongly. Re-cut from a complete capture."
            )
        stamps.append((len(stream), stamp))
        stream.extend(payload[len(stream) - offset:])
    return bytes(stream), stamps, saw_syn


def stamp_for(offset, stamps):
    """The arrival time of the segment carrying the byte at `offset`."""
    chosen = stamps[0][1] if stamps else 0.0
    for start, stamp in stamps:
        if start > offset:
            break
        chosen = stamp
    return chosen


# --------------------------------------------------------- EchoLink proxy (EL-1)
# The 9-byte header derived from the OQ-9 captures, in
# `experiment-data/echolink-oq9-result.txt`. Enough to label a line; the Swift
# parser (EL-4) is the authority.

PROXY_TYPES = {
    0x01: "OPEN", 0x02: "TCP DATA", 0x03: "CLOSE",
    0x04: "STATUS", 0x05: "UDP DATA", 0x06: "UDP CONTROL",
}

PROXY_HEADER_LENGTH = 9


def proxy_frames(stream, stamps):
    """Walk a reassembled stream. Returns (frames, leftover_byte_count).

    Each frame is (offset, stamp, type, peer, payload).

    The length field is LITTLE-ENDIAN. This is the one length field in the tree
    that is — RFC 5456 and M17 are both big-endian — and reading it the other
    way desynchronises within a few frames rather than failing outright. That
    is also the correctness check: a stream that decodes with zero bytes left
    over was almost certainly decoded correctly.
    """
    frames = []
    offset = 0
    while offset + PROXY_HEADER_LENGTH <= len(stream):
        message_type = stream[offset]
        peer = ".".join(str(byte) for byte in stream[offset + 1:offset + 5])
        length = struct.unpack("<I", stream[offset + 5:offset + 9])[0]
        end = offset + PROXY_HEADER_LENGTH + length
        if end > len(stream):
            break  # trailing partial frame; the caller decides whether that is fatal
        frames.append((offset, stamp_for(offset, stamps), message_type, peer,
                       stream[offset + PROXY_HEADER_LENGTH:end]))
        offset = end
    return frames, len(stream) - offset


HANDSHAKE = -1  # a pseudo-type for the login exchange, which is not framed


def split_handshake(stream, inbound):
    """Split the un-framed login preamble off the front of a stream.

    The proxy login happens *before* the 9-byte framing starts, and is not
    itself framed — which is why a capture that includes the TCP handshake
    fails to decode from byte 0 while one that begins mid-session appears to
    work. Proxy->client the preamble is an 8-byte ASCII hex nonce;
    client->proxy it is the callsign, LF-terminated, then 16 raw digest bytes
    with no length prefix.

    Returns (preamble, rest).
    """
    if inbound:
        if len(stream) >= 8 and all(chr(byte) in "0123456789abcdefABCDEF" for byte in stream[:8]):
            return stream[:8], stream[8:]
        return b"", stream
    end_of_callsign = stream.find(b"\n")
    if 0 < end_of_callsign <= 16:  # a callsign, not a coincidental byte
        preamble_end = end_of_callsign + 1 + 16
        if preamble_end <= len(stream):
            return stream[:preamble_end], stream[preamble_end:]
    return b"", stream


def describe_handshake(preamble, inbound):
    if inbound:
        return f"LOGIN        nonce {preamble.decode('ascii', 'replace')}   {len(preamble):4d}B"
    callsign, _, digest = preamble.partition(b"\n")
    return (f"LOGIN        {callsign.decode('ascii', 'replace')} + "
            f"{len(digest)}B raw digest   {len(preamble):4d}B")


def hex_line_handshake(preamble, inbound):
    if inbound:
        return preamble.hex()
    callsign, _, digest = preamble.partition(b"\n")
    return " ".join(part for part in [callsign.hex(), "0a", digest.hex()] if part)


def describe_proxy(message_type, peer, payload):
    """A one-line human label for a proxy frame."""
    name = PROXY_TYPES.get(message_type, f"type 0x{message_type:02x}")
    detail = ""
    if message_type == 0x04 and len(payload) == 4:
        code = struct.unpack("<I", payload)[0]
        detail = "  success" if code == 0 else f"  status {code}"
    elif message_type == 0x05 and len(payload) >= 12:
        version = payload[0] >> 6
        payload_type = payload[1] & 0x7F
        sequence, timestamp, ssrc = struct.unpack("!HII", payload[2:12])
        frames = (len(payload) - 12) / 33
        detail = (f"  RTP v{version} pt{payload_type} seq {sequence:5d} "
                  f"ts {timestamp} ssrc {ssrc}  {frames:g} GSM")
    elif message_type == 0x06 and len(payload) >= 2:
        detail = f"  RTCP pt{payload[1]}"
    peer_note = "" if peer == "0.0.0.0" else f" peer {peer}"
    return f"{name:<11}{peer_note}  {len(payload):4d}B{detail}"


def hex_line_proxy(message_type, peer_bytes, length_bytes, payload):
    """Hex, grouped so the 9-byte header's fields are visible: 1 4 4."""
    groups = [f"{message_type:02x}", peer_bytes.hex(), length_bytes.hex()]
    if message_type == 0x05 and len(payload) >= 12:
        # RTP: the 12-byte header, then one group per 33-byte GSM frame.
        groups.append(payload[:12].hex())
        body = payload[12:]
        groups.extend(body[at:at + 33].hex() for at in range(0, len(body), 33))
    elif payload:
        groups.append(payload.hex())
    return " ".join(group for group in groups if group)


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


def collect_udp(arguments):
    """Normalise a UDP capture to [(stamp, inbound, label, hex)] + stream count."""
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
        raise SystemExit(f"capture holds {len(order)} streams; "
                         f"--stream {arguments.stream} is out of range")

    records = []
    for stamp, _source_ip, source_port, _dst_ip, _dst_port, payload in streams[order[arguments.stream]]:
        records.append((stamp, source_port == arguments.port,
                        describe(payload), hex_line(payload), bool(payload[0] & 0x80)))
    return records, len(order)


def collect_tcp(arguments):
    """Normalise a TCP capture to [(stamp, inbound, label, hex)] + stream count.

    Both directions are reassembled separately, walked into proxy frames, and
    then merged back into one arrival-ordered list — so `[n]` still counts
    frames as they appeared on the wire, the way it does for UDP.
    """
    connections = {}
    order = []
    for segment in tcp_segments(arguments.capture, arguments.port):
        stamp, source_ip, source_port, destination_ip, destination_port, sequence, syn, payload = segment
        if source_port == arguments.port:
            key = (destination_ip, destination_port)
            inbound = True
        else:
            key = (source_ip, source_port)
            inbound = False
        if key not in connections:
            connections[key] = {True: [], False: []}
            order.append(key)
        connections[key][inbound].append((stamp, sequence, syn, payload))

    if not order:
        raise SystemExit(f"no TCP traffic on port {arguments.port} found")
    if arguments.stream >= len(order):
        raise SystemExit(f"capture holds {len(order)} connection(s); "
                         f"--stream {arguments.stream} is out of range")

    records = []
    for inbound in (True, False):
        stream, stamps, saw_syn = reassemble(connections[order[arguments.stream]][inbound])
        if not stream:
            continue
        direction = "peer->client" if inbound else "client->peer"
        if not saw_syn and not arguments.assume_aligned:
            raise SystemExit(
                f"{direction}: the capture has no SYN for this connection, so it began "
                f"mid-session and byte 0 is somewhere inside a frame rather than at the "
                f"start of one. Walking it would emit a few plausible-looking frames of "
                f"pure misalignment before resynchronising. Use a capture that includes "
                f"the TCP handshake, or pass --assume-aligned if you have established "
                f"the alignment some other way."
            )
        base_offset = 0
        if saw_syn:
            preamble, stream = split_handshake(stream, inbound)
            if preamble:
                records.append((stamp_for(0, stamps), inbound,
                                describe_handshake(preamble, inbound),
                                hex_line_handshake(preamble, inbound), HANDSHAKE))
                base_offset = len(preamble)
                stamps = [(max(0, at - base_offset), stamp) for at, stamp in stamps]
        frames, leftover = proxy_frames(stream, stamps)
        if leftover and not arguments.allow_trailing:
            raise SystemExit(
                f"{direction}: {leftover} byte(s) left over after {len(frames)} frame(s). "
                f"A clean decode consumes the whole stream, so this means either the "
                f"capture stopped mid-frame (pass --allow-trailing) or the framing is "
                f"being read wrongly — check the length field is little-endian."
            )
        if leftover:
            print(f"# {direction}: {leftover} trailing byte(s) ignored (--allow-trailing)",
                  file=sys.stderr)
        for offset, stamp, message_type, peer, payload in frames:
            header = stream[offset:offset + PROXY_HEADER_LENGTH]
            records.append((stamp, inbound,
                            describe_proxy(message_type, peer, payload),
                            hex_line_proxy(message_type, header[1:5], header[5:9], payload),
                            message_type))
    if not records:
        # A connection that carried no payload at all — a refused or abandoned
        # proxy, which the captures do contain. Say which streams do have data
        # rather than failing with an index error further down.
        populated = []
        for index, key in enumerate(order):
            total = sum(len(payload) for direction in connections[key].values()
                        for *_head, payload in direction)
            if total:
                populated.append(f"--stream {index} ({key[0]}:{key[1]}, {total} bytes)")
        hint = "; ".join(populated) if populated else "none"
        raise SystemExit(f"stream {arguments.stream} carried no data. Streams with data: {hint}")
    records.sort(key=lambda record: record[0])
    return records, len(order)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture")
    parser.add_argument("--transport", choices=("udp", "tcp"), default="udp",
                        help="'udp' = IAX2 datagrams (default); 'tcp' = reassemble a "
                             "byte stream and walk it as EchoLink proxy frames (EL-1)")
    parser.add_argument("--port", type=int, default=None,
                        help="the peer's port; the peer holding it is 'the node'. "
                             "Default 4569 for udp, 8100 for tcp")
    parser.add_argument("--stream", type=int, default=0,
                        help="which conversation — UDP flow or TCP connection — in "
                             "first-seen order (default 0)")
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
    parser.add_argument("--allow-tcp-data", action="store_true",
                        help="permit type 0x02 frames in the output. Refused by default: "
                             "in the EchoLink captures those carry the account password "
                             "one way and the whole station directory the other (EL-2)")
    parser.add_argument("--assume-aligned", action="store_true",
                        help="walk a TCP stream that has no captured SYN, accepting that "
                             "its first frames may be misaligned garbage")
    parser.add_argument("--allow-trailing", action="store_true",
                        help="tolerate a partial frame at the end of a TCP stream, "
                             "which a capture stopped mid-frame will have")
    parser.add_argument("--name-capture", action="store_true",
                        help="put the capture's filename in the regeneration recipe. "
                             "Default for udp; refused for tcp, where the EchoLink "
                             "captures are cited by digest only (EL-2)")
    arguments = parser.parse_args()

    if arguments.port is None:
        arguments.port = 4569 if arguments.transport == "udp" else 8100
    if arguments.transport == "tcp" and arguments.full_frames_only:
        raise SystemExit("--full-frames-only is an IAX2 notion; it has no meaning for --transport tcp")

    if arguments.transport == "udp":
        records, stream_count = collect_udp(arguments)
    else:
        records, stream_count = collect_tcp(arguments)
    base = records[0][0]

    spans = [(0, len(records) - 1)]
    if arguments.range:
        spans = []
        for span in arguments.range.split(","):
            text_first, _, text_last = span.partition(":")
            spans.append((int(text_first) if text_first else 0,
                          int(text_last) if text_last else len(records) - 1))

    def wanted(index, inbound):
        if arguments.dir == "in" and not inbound:
            return False
        if arguments.dir == "out" and inbound:
            return False
        return any(first <= index <= last for first, last in spans)

    # EL-2. Check the whole selection *before* writing anything: a refusal
    # halfway through would leave a half-written fixture on disk, which is
    # exactly the sort of file that gets committed by accident.
    if arguments.transport == "tcp" and not arguments.summary and not arguments.allow_tcp_data:
        for index, (_stamp, inbound, _label, _hex, kind) in enumerate(records):
            if kind == 0x02 and wanted(index, inbound):
                raise SystemExit(
                    f"frame [{index}] is a type 0x02 (TCP DATA) frame, which in these "
                    f"captures carries either the operator's password or the station "
                    f"directory. Refusing to write it into a fixture. Narrow --range or "
                    f"--dir, or pass --allow-tcp-data if you have checked this specific "
                    f"frame holds neither (EL-2)."
                )

    if not arguments.summary:
        if arguments.preamble:
            with open(arguments.preamble, encoding="utf-8") as handle:
                sys.stdout.write(handle.read())
        # A regeneration recipe, so the fixture can always be re-cut from the
        # capture it came from, and a digest so it is obvious if that capture
        # is ever not the same file (LP-1: `Tests/FIXTURES.md`).
        with open(arguments.capture, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        # EL-2: the EchoLink captures are cited by digest and never by path —
        # one holds a live credential, another the whole directory, and nothing
        # committed should help locate either.
        named = arguments.name_capture and arguments.transport == "udp"
        recipe = " ".join(["scripts/pcap-to-fixture.py",
                           os.path.basename(arguments.capture) if named else "<capture>"]
                          + ([f"--transport {arguments.transport}"]
                             if arguments.transport != "udp" else [])
                          + [f"--stream {arguments.stream}", f"--dir {arguments.dir}"]
                          + ([f"--range {arguments.range}"] if arguments.range else [])
                          + (["--full-frames-only"] if arguments.full_frames_only else []))
        print("# Machine-generated. The captures themselves are not in the repository —")
        print("# they are the maintainer's own, and large. Regenerate with:")
        print(f"#   {recipe}")
        print(f"# Capture SHA-256: {digest}")
        print("#")
        if arguments.transport == "udp":
            print("# Each datagram is the UDP payload verbatim — the octets RFC 5456 §5")
            print("# defines as an IAX2 frame. `[n]` is the datagram's index in the capture")
            print("# stream, so a gap in the indices is a datagram deliberately left out.")
        else:
            print("# Each line is one EchoLink proxy frame verbatim, reassembled from the")
            print("# TCP stream: the 9-byte header — type(1), peer IPv4(4), length(4,")
            print("# LITTLE-endian) — and its payload. `[n]` is the frame's index in")
            print("# arrival order across both directions, so a gap in the indices is a")
            print("# frame deliberately left out.")
        print()

    for index, (stamp, inbound, label, hex_text, kind) in enumerate(records):
        if not wanted(index, inbound):
            continue
        if arguments.transport == "udp" and arguments.full_frames_only and not kind:
            continue
        arrow = "<==" if inbound else "==>"
        if arguments.summary:
            print(f"{index:5d} {stamp - base:8.3f} {arrow} {label}")
        else:
            print(f"# [{index}] {stamp - base:.3f}s {arrow} {label}")
            print(hex_text)

    unit = "datagrams" if arguments.transport == "udp" else "proxy frames"
    print(f"# {stream_count} stream(s); stream {arguments.stream} holds "
          f"{len(records)} {unit}", file=sys.stderr)


if __name__ == "__main__":
    main()
