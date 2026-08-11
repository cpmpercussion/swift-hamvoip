// SPDX-License-Identifier: Apache-2.0

import Foundation
import M17Kit

// MARK: - The two readings

/// The two readings of Table 27 that OQ-7 was asking between.
///
/// They agree on every field up to byte 34. They disagree only about whether
/// bytes 34-35 are the LSF's own CRC — making the LICH field the full 30-byte
/// LSF, and the datagram 56 bytes — or the FN field, making the LICH 28 bytes
/// and the datagram 54.
///
/// OQ-7 is settled: ``lichOmitsLSFCRC`` is what reflectors send, and what
/// `M17StreamPacket` implements. Both readings stay here, because the harness's
/// job is to measure rather than to confirm — it must still be able to report
/// the answer it was not expecting.
enum OQ7Hypothesis: String, CaseIterable, Sendable, CustomStringConvertible {
    /// 56 bytes. LICH is the whole 30-byte LSF, *including* its own CRC, which
    /// is what the specification's stated 240-bit LICH arithmetically requires.
    /// Refuted on the wire, 2026-08-11.
    case lichIncludesLSFCRC

    /// 54 bytes. LICH is 28 bytes, the LSF *without* its CRC. The figure widely
    /// quoted elsewhere for M17-over-IP, and the one a live reflector sends.
    case lichOmitsLSFCRC

    /// Total datagram size this reading predicts.
    var byteCount: Int {
        switch self {
        case .lichIncludesLSFCRC: return 56
        case .lichOmitsLSFCRC: return 54
        }
    }

    /// Byte offset of the FN field under this reading — the discriminator.
    var frameNumberOffset: Int {
        switch self {
        case .lichIncludesLSFCRC: return 36
        case .lichOmitsLSFCRC: return 34
        }
    }

    var description: String {
        switch self {
        case .lichIncludesLSFCRC: return "56-byte frame, 30-byte LICH (LSF CRC present) — the spec as read"
        case .lichOmitsLSFCRC: return "54-byte frame, 28-byte LICH (LSF CRC absent) — as implemented"
        }
    }
}

// MARK: - Frame-number evidence

/// How well the bytes at one candidate FN offset behave like a frame counter.
///
/// Length alone settles OQ-7 — a UDP datagram is as long as it is. This is the
/// corroboration, and it exists because a bare length is thin evidence for a
/// decision that gets built on: it cannot tell a 54-byte frame apart from a
/// 56-byte frame that some middlebox truncated, and it cannot detect a third
/// layout that happens to be 54 or 56 bytes for a different reason.
///
/// The test is that a real FN field increments by one per frame within a stream,
/// so consecutive frames of the same SID differ by exactly one. At the *wrong*
/// offset the same two bytes are either a CRC or Codec 2 payload, and neither
/// counts.
struct OQ7FrameNumberEvidence: Equatable {
    /// Pairs of consecutive frames of the same stream where the value rose by
    /// exactly one.
    private(set) var consecutivePairs = 0

    /// All pairs of consecutive frames of the same stream examined.
    private(set) var totalPairs = 0

    /// Frames whose candidate FN had bit 15 set. Under the right reading this
    /// is the end-of-stream flag, so it should be rare — roughly one per
    /// stream. Under the wrong reading it is about half of them.
    private(set) var highBitSet = 0

    /// Frames examined at this offset.
    private(set) var samples = 0

    private var lastSequence: [UInt16: UInt16] = [:]

    mutating func record(frameNumber: UInt16, streamID: UInt16) {
        samples += 1
        if frameNumber & M17StreamPacket.lastFrameFlag != 0 { highBitSet += 1 }

        let sequence = frameNumber & ~M17StreamPacket.lastFrameFlag
        if let previous = lastSequence[streamID] {
            totalPairs += 1
            if sequence == previous &+ 1 { consecutivePairs += 1 }
        }
        lastSequence[streamID] = sequence
    }

    /// Fraction of examined pairs that incremented by one.
    var incrementRatio: Double {
        totalPairs == 0 ? 0 : Double(consecutivePairs) / Double(totalPairs)
    }

    /// Whether this offset behaves like a frame counter.
    ///
    /// The thresholds are deliberately conservative: a handful of pairs proves
    /// nothing, and a UDP path may reorder or lose a frame, so a real FN field
    /// is allowed to miss some of its increments. Random bytes clear neither
    /// bar.
    var corroborates: Bool {
        totalPairs >= 8 && incrementRatio >= 0.75
    }
}

// MARK: - Verdict

/// What the observed traffic says about OQ-7.
enum OQ7Verdict: Equatable {
    /// The link came up but no `M17 ` datagram ever arrived. Says nothing about
    /// OQ-7 — nobody was talking.
    case noStreamDatagrams(inboundDatagrams: Int)

    /// Every stream datagram was the same length, and the FN field at that
    /// reading's offset behaves like a counter. This is an answer.
    case settled(byteCount: Int, hypothesis: OQ7Hypothesis)

    /// One consistent length, but too few frames to check FN sequencing. The
    /// length is still the answer to the question as asked; run longer for
    /// corroboration.
    case lengthConsistentOnly(byteCount: Int)

    /// The length says one reading and the FN sequencing says the other. Do not
    /// build on this — something is going on that neither reading covers.
    case contradictory(byteCount: Int, corroborated: OQ7Hypothesis)

    /// Stream datagrams arrived in more than one length. Neither reading
    /// explains that on its own.
    case mixedLengths([Int: Int])

    /// A single consistent length that is neither 54 nor 56.
    case unexpectedLength(byteCount: Int)

    /// One line, for the summary.
    var headline: String {
        switch self {
        case .noStreamDatagrams(let inbound):
            return "INCONCLUSIVE — no stream datagrams (\(inbound) inbound datagrams, all control)"
        case .settled(let byteCount, let hypothesis):
            return "SETTLED — the stream frame is \(byteCount) bytes: \(hypothesis)"
        case .lengthConsistentOnly(let byteCount):
            return "LENGTH ONLY — every stream datagram was \(byteCount) bytes, sequencing unconfirmed"
        case .contradictory(let byteCount, let corroborated):
            return "CONTRADICTORY — datagrams are \(byteCount) bytes but FN sequences at the "
                + "\(corroborated.byteCount)-byte offset"
        case .mixedLengths(let histogram):
            let described = histogram.keys.sorted().map { "\($0)×\(histogram[$0]!)" }.joined(separator: ", ")
            return "MIXED — stream datagrams arrived in several lengths (\(described))"
        case .unexpectedLength(let byteCount):
            return "UNEXPECTED — every stream datagram was \(byteCount) bytes, which is neither reading"
        }
    }

    /// What to do next.
    var guidance: String {
        switch self {
        case .noStreamDatagrams:
            return """
                The link worked — control traffic arrived — but nobody transmitted, so the \
                question is untouched. Run again on a busy module, or during the M17 net, and \
                give it long enough for somebody to talk.
                """
        case .settled(let byteCount, _):
            if byteCount == M17StreamPacket.byteCount {
                return """
                    Agrees with the settled answer: OQ-7 was settled at 54 bytes on 2026-08-11, \
                    and M17StreamPacket.byteCount is 54. Nothing to change. A second reflector \
                    reaching the same verdict is worth noting in the OQ-7 row all the same — the \
                    original evidence is one capture of one over.
                    """
            }
            return """
                This reflector disagrees with the settled answer: OQ-7 was settled at 54 bytes on \
                2026-08-11 and M17StreamPacket.byteCount is \(M17StreamPacket.byteCount). That is \
                new information, not a correction to apply on sight — keep the capture, and work \
                out whether the difference sorts by reflector or by transmitting client before \
                touching the constant. Two populations of transmitters disagreeing would mean the \
                parser has to tolerate both, which is a bigger change than a number.
                """
        case .lengthConsistentOnly:
            return """
                Good enough to answer the question, thin as corroboration. Another run that \
                catches a longer transmission would confirm the FN field is where this length \
                implies it is.
                """
        case .contradictory:
            return """
                Do not settle OQ-7 on this. Keep the capture and look at it by hand — a \
                truncating middlebox, a padded datagram, or a layout neither reading covers \
                would all look like this.
                """
        case .mixedLengths:
            return """
                Keep the capture. Worth knowing whether the lengths sort by source client — \
                different transmitting software disagreeing about this is itself the answer to \
                a question worth having asked.
                """
        case .unexpectedLength:
            return """
                Keep the capture and read the datagram by hand before changing any constant. \
                Neither reading of Table 27 predicts this length.
                """
        }
    }
}

// MARK: - Tally

/// Accumulates what a reflector link put on the wire and reduces it to a
/// verdict on OQ-7.
///
/// Pure: no I/O, no clock, no socket. Every decision the experiment makes is
/// therefore unit-tested against synthesised datagrams, which matters more than
/// usual here — a harness that reaches the wrong conclusion about its own
/// evidence is worse than no harness, because the conclusion gets written into
/// the requirements.
struct OQ7Tally {

    /// Every inbound datagram, stream or not.
    private(set) var inboundDatagramCount = 0

    /// Datagrams opening with the `M17 ` magic, whatever their length.
    private(set) var streamDatagramCount = 0

    /// Stream datagram length → how many arrived at that length.
    private(set) var lengthHistogram: [Int: Int] = [:]

    /// Non-stream datagrams, keyed by how their first four bytes render.
    private(set) var nonStreamHistogram: [String: Int] = [:]

    /// Decoded SRC callsign → frames seen from it. Reads at bytes 12-17, which
    /// both readings agree on, so it is valid evidence either way. Its job is
    /// to show a human that these are real transmissions from real stations and
    /// not a misparse of something else.
    private(set) var sourceCallsigns: [String: Int] = [:]

    /// Distinct stream IDs — roughly, distinct transmissions.
    private(set) var streamIDs: Set<UInt16> = []

    /// The FN-offset evidence, per reading.
    private(set) var evidence: [OQ7Hypothesis: OQ7FrameNumberEvidence] = [:]

    init() {
        for hypothesis in OQ7Hypothesis.allCases {
            evidence[hypothesis] = OQ7FrameNumberEvidence()
        }
    }

    /// Folds one received datagram into the tally.
    mutating func record(_ datagram: Data) {
        inboundDatagramCount += 1
        let bytes = [UInt8](datagram)

        guard bytes.count >= M17PacketMagic.byteCount else {
            nonStreamHistogram["<\(bytes.count) bytes, shorter than a magic>", default: 0] += 1
            return
        }

        guard M17PacketMagic(leading: bytes) == .stream else {
            nonStreamHistogram[Self.renderMagic(Array(bytes.prefix(M17PacketMagic.byteCount))), default: 0] += 1
            return
        }

        streamDatagramCount += 1
        lengthHistogram[bytes.count, default: 0] += 1

        // SID at 4-5 and SRC at 12-17 are common to both readings.
        guard bytes.count >= 18 else { return }
        let streamID = Self.uint16(bytes, at: 4)
        streamIDs.insert(streamID)

        if let source = try? M17Address(bytes: bytes[12..<18]).callsign {
            sourceCallsigns[source, default: 0] += 1
        }

        for hypothesis in OQ7Hypothesis.allCases {
            let offset = hypothesis.frameNumberOffset
            guard bytes.count >= offset + 2 else { continue }
            evidence[hypothesis]?.record(
                frameNumber: Self.uint16(bytes, at: offset), streamID: streamID)
        }
    }

    /// The readings whose FN offset behaves like a frame counter.
    var corroboratedHypotheses: [OQ7Hypothesis] {
        OQ7Hypothesis.allCases.filter { evidence[$0]?.corroborates == true }
    }

    /// What the tally concludes.
    var verdict: OQ7Verdict {
        guard streamDatagramCount > 0 else {
            return .noStreamDatagrams(inboundDatagrams: inboundDatagramCount)
        }
        guard lengthHistogram.count == 1, let byteCount = lengthHistogram.keys.first else {
            return .mixedLengths(lengthHistogram)
        }

        let corroborated = corroboratedHypotheses
        guard let reading = OQ7Hypothesis.allCases.first(where: { $0.byteCount == byteCount }) else {
            return .unexpectedLength(byteCount: byteCount)
        }

        // Both offsets counting is not a real possibility on real traffic; if it
        // ever happens the evidence is not discriminating and must not be
        // reported as settled.
        if corroborated.count == 1, corroborated[0] != reading {
            return .contradictory(byteCount: byteCount, corroborated: corroborated[0])
        }
        if corroborated.contains(reading), corroborated.count == 1 {
            return .settled(byteCount: byteCount, hypothesis: reading)
        }
        return .lengthConsistentOnly(byteCount: byteCount)
    }

    // MARK: Rendering

    /// The full report: evidence first, verdict last, so it can be pasted into
    /// a PR or the plan's OQ-7 row as it stands.
    func report() -> String {
        var lines: [String] = []
        lines.append("OQ-7 — is the M17 IP stream frame 56 bytes or 54?")
        lines.append("")
        lines.append("Inbound datagrams        \(inboundDatagramCount)")
        lines.append("Stream datagrams (M17 )  \(streamDatagramCount)")
        lines.append("Distinct stream IDs      \(streamIDs.count)")

        if !lengthHistogram.isEmpty {
            lines.append("")
            lines.append("Stream datagram lengths")
            for length in lengthHistogram.keys.sorted() {
                let note: String
                if let reading = OQ7Hypothesis.allCases.first(where: { $0.byteCount == length }) {
                    note = "  ← \(reading)"
                } else {
                    note = "  ← neither reading"
                }
                lines.append("  \(length) bytes  ×\(lengthHistogram[length]!)\(note)")
            }
        }

        if !nonStreamHistogram.isEmpty {
            lines.append("")
            lines.append("Non-stream datagrams")
            for magic in nonStreamHistogram.keys.sorted() {
                lines.append("  \(magic)  ×\(nonStreamHistogram[magic]!)")
            }
        }

        if !sourceCallsigns.isEmpty {
            lines.append("")
            lines.append("Transmitting stations (LSF SRC, bytes 12-17 — common to both readings)")
            for callsign in sourceCallsigns.keys.sorted() {
                lines.append("  \(callsign)  \(sourceCallsigns[callsign]!) frames")
            }
        }

        lines.append("")
        lines.append("Frame-number corroboration — do the bytes at each candidate FN offset count?")
        for hypothesis in OQ7Hypothesis.allCases {
            guard let found = evidence[hypothesis] else { continue }
            let ratio = found.totalPairs == 0
                ? "n/a"
                : String(format: "%.0f%%", found.incrementRatio * 100)
            lines.append("  offset \(hypothesis.frameNumberOffset)  "
                + "(\(hypothesis.byteCount)-byte reading)  "
                + "\(found.consecutivePairs)/\(found.totalPairs) pairs +1  \(ratio)  "
                + "bit-15 set in \(found.highBitSet)/\(found.samples)  "
                + (found.corroborates ? "COUNTS" : "does not count"))
        }

        lines.append("")
        lines.append("VERDICT: \(verdict.headline)")
        lines.append("")
        lines.append(verdict.guidance)
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    /// Four bytes as their ASCII, when they are printable, and as hex when they
    /// are not — so an unrecognised datagram is legible either way.
    private static func renderMagic(_ bytes: [UInt8]) -> String {
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "\"\(String(decoding: bytes, as: UTF8.self))\""
        }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
