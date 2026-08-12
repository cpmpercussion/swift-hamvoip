// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Errors

public enum EchoLinkRTCPError: Error, Equatable, CustomStringConvertible {
    case truncated(available: Int)
    /// A packet's declared length runs past the end of the datagram.
    case lengthOverrun(declared: Int, available: Int)

    public var description: String {
        switch self {
        case .truncated(let available):
            return "truncated RTCP: \(available) bytes"
        case .lengthOverrun(let declared, let available):
            return "RTCP packet declares \(declared) bytes, \(available) available"
        }
    }
}

// MARK: - SDES items

/// The SDES item types EchoLink uses (RFC 3550 §6.5 numbering).
public struct EchoLinkSDESItemType: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let cname = Self(rawValue: 1)
    public static let name = Self(rawValue: 2)
    public static let email = Self(rawValue: 3)
    public static let phone = Self(rawValue: 4)
    public static let tool = Self(rawValue: 6)
}

/// One SDES item: a type and its ASCII text.
public struct EchoLinkSDESItem: Equatable, Sendable {
    public var type: EchoLinkSDESItemType
    public var text: String

    public init(_ type: EchoLinkSDESItemType, _ text: String) {
        self.type = type
        self.text = text
    }
}

// MARK: - Packets

/// One packet within an RTCP compound.
///
/// Only the three EchoLink actually sends are modelled; anything else is kept
/// verbatim as `.other` rather than dropped, for the same reason an unknown
/// proxy message type parses — it is a client we have not met.
public enum EchoLinkRTCPPacket: Equatable, Sendable {
    /// Receiver report. Every observed compound begins with one, with a zero
    /// report count, so it carries nothing but the sender's SSRC.
    case receiverReport(ssrc: UInt32)

    /// Source description — who we are. This is the packet that opens a
    /// session.
    case sourceDescription(ssrc: UInt32, items: [EchoLinkSDESItem])

    /// Goodbye. Ends a session.
    case goodbye(ssrc: UInt32, reason: String)

    /// Anything else, kept whole.
    case other(payloadType: UInt8, body: Data)

    static let receiverReportType: UInt8 = 201
    static let sourceDescriptionType: UInt8 = 202
    static let goodbyeType: UInt8 = 203
}

/// A compound RTCP packet — the payload of a `0x06` proxy frame.
///
/// ## What this is for
///
/// It is not diagnostics. **This is how an EchoLink session is opened and
/// closed**, and without it a node never answers:
///
/// - To connect, send `RR + SDES`. The captures show the client sending it
///   twice, ~0.8 s apart, before the node replied ~1.5 s in — so it
///   retransmits until answered.
/// - To disconnect, send `RR + BYE`.
///
/// The plan deferred the control channel as "observed but neither is needed for
/// a working QSO". That turned out to be wrong in the direction that matters:
/// `0x01 OPEN` is only ever sent for the tunnelled *directory* connection, never
/// for an audio peer, so the SDES exchange is the **only** thing that starts a
/// node session. See the EL-10 notes.
///
/// ## The version bits are 3 here too
///
/// Same as the RTP header, and same reasoning: accept what is sent, emit what
/// was observed.
public struct EchoLinkRTCPCompound: Equatable, Sendable {
    public var packets: [EchoLinkRTCPPacket]

    public init(_ packets: [EchoLinkRTCPPacket]) {
        self.packets = packets
    }

    /// What EchoLink puts in the version bits.
    public static let observedVersion: UInt8 = 3

    /// The reason string observed on every `BYE`.
    ///
    /// An EchoLink convention rather than anything meaningful — it is emitted
    /// verbatim because a receiver may match on it, and there is no evidence
    /// either way.
    public static let goodbyeReason = "jan2002"

    /// The literal string both observed implementations put in `CNAME` and
    /// `EMAIL`.
    ///
    /// Not a placeholder we invented and not a redaction: EchoHam and thebridge
    /// both send the eight characters `CALLSIGN`, so it is a protocol
    /// convention carrying no identity. The real identity is in `NAME`.
    public static let cnamePlaceholder = "CALLSIGN"

    /// Width of the callsign field in the `NAME` item, left-justified and
    /// space-padded, as observed.
    static let callsignFieldWidth = 15

    // MARK: Composing the two that matter

    /// `RR + SDES` — the packet that opens a session.
    ///
    /// - Parameters:
    ///   - callsign: ours, left-justified in a 15-character field.
    ///   - operatorName: shown alongside it by the far end.
    ///   - localTime: `HH:MM`, which is what the observed clients send in
    ///     `PHONE`. Passed in rather than read from a clock so this stays a
    ///     pure value type.
    ///   - tool: our client identification.
    public static func sessionOpening(
        callsign: String,
        operatorName: String,
        localTime: String,
        tool: String,
        ssrc: UInt32 = 0
    ) -> EchoLinkRTCPCompound {
        let padded = callsign.padding(
            toLength: max(callsignFieldWidth, callsign.count),
            withPad: " ",
            startingAt: 0
        )
        return EchoLinkRTCPCompound([
            .receiverReport(ssrc: ssrc),
            .sourceDescription(
                ssrc: ssrc,
                items: [
                    EchoLinkSDESItem(.cname, cnamePlaceholder),
                    EchoLinkSDESItem(.name, padded + operatorName),
                    EchoLinkSDESItem(.email, cnamePlaceholder),
                    EchoLinkSDESItem(.phone, localTime),
                    EchoLinkSDESItem(.tool, tool),
                ]
            ),
        ])
    }

    /// `RR + BYE` — the packet that ends a session.
    public static func sessionClosing(ssrc: UInt32 = 0) -> EchoLinkRTCPCompound {
        EchoLinkRTCPCompound([
            .receiverReport(ssrc: ssrc),
            .goodbye(ssrc: ssrc, reason: goodbyeReason),
        ])
    }

    // MARK: Introspection

    /// The `NAME` item of the first SDES, if any — how the far end identifies
    /// itself.
    public var sourceName: String? {
        for packet in packets {
            if case .sourceDescription(_, let items) = packet {
                return items.first { $0.type == .name }?.text
            }
        }
        return nil
    }

    /// Whether this compound says the far end is leaving.
    public var isGoodbye: Bool {
        packets.contains { if case .goodbye = $0 { return true } else { return false } }
    }

    // MARK: Wire format

    public var encoded: Data {
        var out = Data()
        for packet in packets {
            out.append(Self.encode(packet))
        }
        return out
    }

    private static func encode(_ packet: EchoLinkRTCPPacket) -> Data {
        var body = Data()
        let payloadType: UInt8
        let count: UInt8

        switch packet {
        case .receiverReport(let ssrc):
            payloadType = EchoLinkRTCPPacket.receiverReportType
            count = 0
            body.append(bigEndian: ssrc)

        case .sourceDescription(let ssrc, let items):
            payloadType = EchoLinkRTCPPacket.sourceDescriptionType
            count = 1
            body.append(bigEndian: ssrc)
            for item in items {
                let text = Array(item.text.utf8.prefix(255))
                body.append(item.type.rawValue)
                body.append(UInt8(text.count))
                body.append(contentsOf: text)
            }
            // RFC 3550 §6.5: the item list is terminated by at least one null
            // octet, then padded to the next 32-bit boundary.
            //
            // The observed senders both pad four bytes further than that
            // minimum, and thebridge leaves a stray 0x02 in the padding — which
            // is itself the evidence that this region is slack, since two
            // implementations that interoperate disagree about it. So the rule
            // below is the RFC's rather than either sender's: it is the only
            // one that can be stated, and the padding sits inside the declared
            // length where a length-driven parser never looks.
            body.append(0)
            while (body.count + 4) % 4 != 0 { body.append(0) }

        case .goodbye(let ssrc, let reason):
            payloadType = EchoLinkRTCPPacket.goodbyeType
            count = 1
            body.append(bigEndian: ssrc)
            let text = Array(reason.utf8.prefix(255))
            body.append(UInt8(text.count))
            body.append(contentsOf: text)
            while (body.count + 4) % 4 != 0 { body.append(0) }

        case .other(let type, let raw):
            payloadType = type
            count = 0
            body = raw
        }

        var out = Data()
        out.append((observedVersion << 6) | (count & 0x1F))
        out.append(payloadType)
        // Length counts 32-bit words *excluding* the first — RFC 3550 §6.4.1.
        let words = UInt16((body.count + 4) / 4 - 1)
        out.append(UInt8(truncatingIfNeeded: words >> 8))
        out.append(UInt8(truncatingIfNeeded: words))
        out.append(body)
        return out
    }

    /// Parse a whole `0x06` payload.
    ///
    /// Permissive by design: an unrecognised payload type is kept as `.other`,
    /// and a compound that ends with fewer than four spare bytes simply ends.
    public static func parse(_ bytes: Data) throws -> EchoLinkRTCPCompound {
        guard bytes.count >= 4 else {
            throw EchoLinkRTCPError.truncated(available: bytes.count)
        }

        var packets: [EchoLinkRTCPPacket] = []
        var offset = bytes.startIndex

        while offset + 4 <= bytes.endIndex {
            let count = bytes[offset] & 0x1F
            let payloadType = bytes[offset + 1]
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let total = (words + 1) * 4

            guard offset + total <= bytes.endIndex else {
                throw EchoLinkRTCPError.lengthOverrun(
                    declared: total,
                    available: bytes.endIndex - offset
                )
            }

            let body = bytes[(offset + 4) ..< (offset + total)]
            packets.append(decode(payloadType: payloadType, count: count, body: Data(body)))
            offset += total
        }

        return EchoLinkRTCPCompound(packets)
    }

    private static func decode(payloadType: UInt8, count: UInt8, body: Data) -> EchoLinkRTCPPacket {
        func ssrc(_ data: Data) -> UInt32? {
            guard data.count >= 4 else { return nil }
            let base = data.startIndex
            return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
                | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
        }

        switch payloadType {
        case EchoLinkRTCPPacket.receiverReportType:
            guard let id = ssrc(body) else { break }
            return .receiverReport(ssrc: id)

        case EchoLinkRTCPPacket.sourceDescriptionType:
            guard let id = ssrc(body) else { break }
            var items: [EchoLinkSDESItem] = []
            var index = body.startIndex + 4
            while index < body.endIndex, body[index] != 0 {
                let type = body[index]
                guard index + 1 < body.endIndex else { break }
                let length = Int(body[index + 1])
                let start = index + 2
                guard start + length <= body.endIndex else { break }
                items.append(
                    EchoLinkSDESItem(
                        EchoLinkSDESItemType(rawValue: type),
                        String(decoding: body[start ..< start + length], as: UTF8.self)
                    )
                )
                index = start + length
            }
            return .sourceDescription(ssrc: id, items: items)

        case EchoLinkRTCPPacket.goodbyeType:
            guard let id = ssrc(body), body.count > 4 else { break }
            let length = Int(body[body.startIndex + 4])
            let start = body.startIndex + 5
            let end = min(start + length, body.endIndex)
            return .goodbye(
                ssrc: id,
                reason: String(decoding: body[start ..< end], as: UTF8.self)
            )

        default:
            break
        }
        return .other(payloadType: payloadType, body: body)
    }
}

extension Data {
    fileprivate mutating func append(bigEndian value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
