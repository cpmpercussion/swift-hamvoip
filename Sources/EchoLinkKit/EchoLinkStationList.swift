// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Errors

/// Why a station list would not parse.
///
/// Every case names what was expected and where, because the failure mode this
/// type exists to prevent is a *silent short read*: a list that stops halfway
/// through and is handed upward as a complete one. A truncated list looks
/// exactly like a small list unless the count is checked.
public enum EchoLinkStationListError: Error, Equatable, CustomStringConvertible {
    /// The first line was not the `@@@` marker.
    case missingMarker(found: String)

    /// The second line was not `<count>:<serial>`.
    case malformedCountLine(found: String)

    /// The body ended part-way through a four-line record.
    case truncatedRecord(afterRecords: Int, danglingLines: Int)

    /// The `+++` terminator never arrived.
    case missingTerminator(afterRecords: Int)

    /// The header's count and the number of records disagree.
    ///
    /// The header is treated as authoritative: it is the server's own statement
    /// of what it was about to send, so a mismatch means bytes were lost, not
    /// that the header was wrong.
    case countMismatch(declared: Int, parsed: Int)

    /// The bytes were not text this parser can read.
    case notText(byteCount: Int)

    public var description: String {
        switch self {
        case .missingMarker(let found):
            return "station list did not begin with \(EchoLinkStationList.marker) (found \(found.debugDescription))"
        case .malformedCountLine(let found):
            return "station list header was not <count>:<serial> (found \(found.debugDescription))"
        case .truncatedRecord(let records, let dangling):
            return "station list ended mid-record after \(records) record(s), with \(dangling) dangling line(s)"
        case .missingTerminator(let records):
            return "station list had no \(EchoLinkStationList.terminator) terminator after \(records) record(s)"
        case .countMismatch(let declared, let parsed):
            return "station list declared \(declared) entries and carried \(parsed)"
        case .notText(let count):
            return "station list was not readable text (\(count) bytes)"
        }
    }
}

// MARK: - A station

/// One entry in the directory.
///
/// `location` and `status` come out of a single fixed-geometry line; see
/// `EchoLinkStationList` for why the split is at column 27 and not at the first
/// bracket.
public struct EchoLinkStation: Equatable, Sendable {
    /// As listed. May be a conference name rather than a callsign — those are
    /// wrapped in asterisks (`*ECHOTEST*`) and may contain underscores, so this
    /// is deliberately not validated against any callsign grammar.
    public let callsign: String

    /// Free text the operator sets: a town, a repeater frequency, a node
    /// description. Trailing padding removed.
    public let location: String

    /// The word inside the trailing bracket. Every station in the reference
    /// list said one of two things: **`ON` 6059 times and `BUSY` 382**, which
    /// is all 6441 of them.
    ///
    /// Carried as text anyway. Two values, from one server, on one day, is not
    /// a closed set — it is the sample we have, and the module's rule is to
    /// parse permissively and let an unexpected value reach the caller intact
    /// rather than fail or flatten it. A caller wanting a boolean should
    /// compare against `ExpectedStatus`.
    ///
    /// `nil` when the entry has no bracket, which no *station* in the reference
    /// list did — only the server's own trailing notices.
    public let status: String?

    /// `HH:MM` from the trailing bracket, verbatim. No time zone is stated
    /// anywhere in the listing, so this is not turned into a `Date` — doing so
    /// would require inventing one.
    public let time: String?

    /// The node number. `nil` when the field is blank, which the server's own
    /// trailing entries have.
    public let nodeNumber: Int?

    /// Dotted-quad IPv4, verbatim. Not parsed into an address type: `0.0.0.0`
    /// and `127.0.0.1` both appear and mean "not reachable", and turning them
    /// into an address would suggest they are dialable.
    public let address: String

    public init(
        callsign: String,
        location: String,
        status: String?,
        time: String?,
        nodeNumber: Int?,
        address: String
    ) {
        self.callsign = callsign
        self.location = location
        self.status = status
        self.time = time
        self.nodeNumber = nodeNumber
        self.address = address
    }

    /// The two status words the reference list actually used. Not an
    /// exhaustive set — see `status`.
    public enum ExpectedStatus {
        public static let online = "ON"
        public static let busy = "BUSY"
    }

    /// Whether the entry looks connectable: it has a node number and its
    /// address is neither unspecified nor loopback.
    public var isConnectable: Bool {
        nodeNumber != nil && address != "0.0.0.0" && address != "127.0.0.1"
    }
}

// MARK: - The list

/// The station list the directory server returns after login (EL-11).
///
/// ## The grammar
///
///     @@@                     LF      marker
///     <count>:<serial>        LF      count of entries, then an opaque serial
///     ─ repeated <count> times ─
///       <callsign>            LF
///       <location+status>     LF      fixed geometry; see below
///       <node number>         LF      may be blank
///       <address>             LF      dotted-quad IPv4
///     +++                             terminator, not LF-terminated
///
/// The request that provokes it is `stationListRequest` — `f0` and a CR.
///
/// ## The one subtle field
///
/// The second line of a record is **not** free text with a tag appended; it has
/// fixed geometry. The status bracket opens at **column 27** — in all 6441
/// stations of the reference list, without exception — and the location
/// occupies the columns before it, space-padded.
///
/// Splitting on the *first* `[` is the obvious implementation and it is wrong
/// for **3496 of those 6441 entries**, more than half, because a location
/// beginning `[Svx] 145.6625 …` or containing `[0/20]` is entirely ordinary.
/// That reading would report a status of `Svx` and lose the real one. The
/// last-bracket rule gets every observed entry right too; this parser uses the
/// column and falls back to the last bracket, and on the reference list the two
/// rules disagree about nothing.
///
/// An entry may have no bracket at all, in which case the whole line is
/// location and `status` is `nil`. No station did that — only the server's own
/// trailing notices, below.
///
/// ## Provenance, and why there is no fixture
///
/// Every rule above was measured against a real directory download: **6444
/// entries, 433 414 bytes across 129 proxy frames**, captured 2026-08-12 (the
/// capture is identified in `Tests/FIXTURES.md` by SHA-256 and lives outside
/// both repos).
///
/// It was then confirmed against a **second, live** download on 2026-08-13 —
/// 6389 entries, count matching — so no rule here rests on a single list.
///
/// **That capture cannot become a fixture, and neither can any part of it.** It
/// carries 6548 other operators' callsigns, their locations and 6261 IPv4
/// addresses. So the tests for this file build their own list from invented
/// callsigns and RFC 5737 documentation addresses, and the real list is checked
/// only by a conformance test that is skipped unless the operator points an
/// environment variable at their own copy. See `EchoLinkStationListTests`.
///
/// The synthetic list is not evidence, and is not dressed up as any. What makes
/// the *format* claims above evidenced is the measurement recorded in the
/// EL-11 entry of `docs/DEVELOPMENT-PLAN.md`, together with the conformance
/// test anyone holding the capture can re-run.
public struct EchoLinkStationList: Equatable, Sendable {
    /// The list's opening line.
    public static let marker = "@@@"

    /// The list's closing line.
    public static let terminator = "+++"

    /// The column the status bracket opens at.
    public static let statusColumn = 27

    /// The payload that asks for the full list: `f0` and a carriage return.
    ///
    /// Measured off the wire, and the whole of the request — there is no
    /// callsign or session token in it, because the connection is already
    /// authenticated by the time it is sent.
    public static var stationListRequest: Data { Data([0x66, 0x30, 0x0D]) }

    /// How many entries the header said there would be.
    public let declaredCount: Int

    /// The header's second field. Opaque: it is stable across a session and
    /// changes between them, which is consistent with a list serial or
    /// generation number, but nothing observed establishes what it means, so it
    /// is carried as text rather than interpreted.
    public let serial: String

    /// Entries with a callsign.
    public let stations: [EchoLinkStation]

    /// The server's own trailing entries — a blank callsign, a blank node
    /// number and `127.0.0.1`, carrying a line of text in the location field.
    ///
    /// Three of these close the reference list. They are not stations and
    /// putting them in `stations` would mean every caller filtering them out,
    /// but they *do* count toward the header's total, which is why they are
    /// kept rather than dropped.
    public let notices: [String]

    public init(declaredCount: Int, serial: String, stations: [EchoLinkStation], notices: [String]) {
        self.declaredCount = declaredCount
        self.serial = serial
        self.stations = stations
        self.notices = notices
    }

    /// Entries plus notices — what the header counts.
    public var entryCount: Int { stations.count + notices.count }

    // MARK: Parsing

    /// Parse a complete list.
    ///
    /// - Throws: `EchoLinkStationListError` for anything short, mis-framed or
    ///   inconsistent with its own header.
    public static func parse(_ data: Data) throws -> EchoLinkStationList {
        // ISO-8859-1 rather than UTF-8: the reference list contains a
        // non-breaking space (0xA0) in a location field, which is not valid
        // UTF-8 and would take the whole 433 kB download down with it. Every
        // byte maps to a character here, so this decode cannot fail — but the
        // throwing case is kept for the day a caller passes something else.
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw EchoLinkStationListError.notText(byteCount: data.count)
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> EchoLinkStationList {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let first = lines.first, first == marker else {
            throw EchoLinkStationListError.missingMarker(found: String(lines.first?.prefix(32) ?? ""))
        }
        lines.removeFirst()

        guard let header = lines.first else {
            throw EchoLinkStationListError.malformedCountLine(found: "")
        }
        lines.removeFirst()

        let headerParts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard headerParts.count == 2, let declared = Int(headerParts[0]), declared >= 0 else {
            throw EchoLinkStationListError.malformedCountLine(found: String(header.prefix(32)))
        }
        let serial = String(headerParts[1])

        // The terminator is not LF-terminated, so it is the last element of the
        // split rather than a line of its own. Anything after it is not ours.
        guard let terminatorIndex = lines.lastIndex(of: terminator) else {
            throw EchoLinkStationListError.missingTerminator(afterRecords: max(0, lines.count / 4))
        }
        let body = Array(lines[..<terminatorIndex])

        guard body.count % 4 == 0 else {
            throw EchoLinkStationListError.truncatedRecord(
                afterRecords: body.count / 4,
                danglingLines: body.count % 4)
        }

        var stations: [EchoLinkStation] = []
        var notices: [String] = []
        stations.reserveCapacity(body.count / 4)

        for start in stride(from: 0, to: body.count, by: 4) {
            let callsign = body[start].trimmingCharacters(in: .whitespaces)
            let (location, status, time) = splitLocationAndStatus(body[start + 1])
            let nodeText = body[start + 2].trimmingCharacters(in: .whitespaces)
            let address = body[start + 3].trimmingCharacters(in: .whitespaces)

            if callsign.isEmpty {
                notices.append(location)
                continue
            }
            stations.append(EchoLinkStation(
                callsign: callsign,
                location: location,
                status: status,
                time: time,
                nodeNumber: nodeText.isEmpty ? nil : Int(nodeText),
                address: address))
        }

        let list = EchoLinkStationList(
            declaredCount: declared, serial: serial, stations: stations, notices: notices)
        guard list.entryCount == declared else {
            throw EchoLinkStationListError.countMismatch(declared: declared, parsed: list.entryCount)
        }
        return list
    }

    /// Split a record's second line into location, status word and time.
    ///
    /// Column-first, last-bracket as the fallback. See the type's documentation
    /// for why the *first* bracket is the wrong answer.
    static func splitLocationAndStatus(_ line: String) -> (location: String, status: String?, time: String?) {
        let characters = Array(line)
        var bracket: Int?
        if characters.count > statusColumn, characters[statusColumn] == "[" {
            bracket = statusColumn
        } else if let last = characters.lastIndex(of: "[") {
            bracket = last
        }

        guard let open = bracket, let close = characters[open...].lastIndex(of: "]") else {
            return (line.trimmingCharacters(in: .whitespaces), nil, nil)
        }

        let location = String(characters[..<open]).trimmingCharacters(in: .whitespaces)
        let tag = String(characters[(open + 1)..<close])

        // `<word> <HH:MM>`. Split from the right: the word may contain a space
        // in principle, and the time never does.
        guard let space = tag.lastIndex(of: " ") else {
            let word = tag.trimmingCharacters(in: .whitespaces)
            return (location, word.isEmpty ? nil : word, nil)
        }
        let word = String(tag[..<space]).trimmingCharacters(in: .whitespaces)
        let time = String(tag[tag.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        return (location, word.isEmpty ? nil : word, time.isEmpty ? nil : time)
    }
}

// MARK: - Reading it off a stream

/// Accumulates a station list arriving in arbitrary TCP chunks.
///
/// The reference download crossed **129 proxy frames**, splitting records — and
/// individual fields — at every imaginable boundary: one 16-byte frame carried
/// `"N 12:42]\n730991\n"`, the tail of one entry's status and the whole of the
/// next field, with the callsign it belonged to three frames back. So no
/// caller may parse a frame on its own, and this type exists so that none has
/// to try.
///
/// The terminator is what says the list is complete. A list that never
/// terminates is a stalled download, not a short list, and `finish()` says so.
public struct EchoLinkStationListReader {
    private var buffer = Data()

    public init() {}

    /// How much has arrived.
    public var bufferedByteCount: Int { buffer.count }

    /// Feed a chunk. Returns the list once the terminator has arrived, `nil`
    /// while it is still coming.
    ///
    /// - Throws: `EchoLinkStationListError` if the completed list will not parse.
    public mutating func append(_ bytes: Data) throws -> EchoLinkStationList? {
        buffer.append(bytes)
        guard buffer.count >= EchoLinkStationList.terminator.utf8.count else { return nil }

        // Cheap check before the expensive one: the terminator is the last
        // thing on the wire, so only look at the tail.
        let tail = buffer.suffix(EchoLinkStationList.terminator.utf8.count)
        guard Array(tail) == Array(EchoLinkStationList.terminator.utf8) else { return nil }

        return try EchoLinkStationList.parse(buffer)
    }

    /// The stream ended. Either the list is complete, or this says how far it got.
    ///
    /// - Throws: `EchoLinkStationListError.missingTerminator` when the download
    ///   stopped early — the case the whole type exists to make loud.
    public func finish() throws -> EchoLinkStationList {
        try EchoLinkStationList.parse(buffer)
    }
}
