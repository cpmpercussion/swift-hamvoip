// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import EchoLinkKit

/// EL-11 — the directory station list.
///
/// ## Why there is no fixture here, and what stands in for one
///
/// Every other EchoLink test in this target replays captured octets. This one
/// cannot, and the reason is the whole of EL-11's gate: the only capture of a
/// full station list carries **6548 other operators' callsigns, their locations
/// and 6261 IPv4 addresses**. `Tests/FIXTURES.md` forbids cutting a `0x02`
/// fixture from it, and hand-copying "representative" entries out of it would
/// be the same data with the provenance filed off — the workaround the plan
/// explicitly names as the wrong one.
///
/// So the format claims are evidenced in two places, neither of which is a
/// fixture:
///
/// 1. **A measurement, recorded in the EL-11 entry of
///    `docs/DEVELOPMENT-PLAN.md`** — every rule in `EchoLinkStationList` was
///    derived by counting over the real 433 414-byte list and is stated there
///    with its tally.
/// 2. **`testTheRealListParses`, below** — the conformance test proper. It runs
///    the parser over that same real list and asserts the tally. It is skipped
///    unless `HAMVOIP_ECHOLINK_STATION_LIST` points at a copy, because the copy
///    may not be committed. Anyone holding the capture can re-run it; CI never
///    does.
///
/// The lists built in this file are **invented**. Callsigns are the
/// maintainer's own or obviously fictional, and addresses come from RFC 5737's
/// documentation ranges. They are not evidence and are not presented as any:
/// what they test is that the parser implements the measured rules, not that
/// the rules are right.
final class EchoLinkStationListTests: XCTestCase {

    // MARK: - Building an invented list

    /// One record: four LF-terminated lines.
    ///
    /// `location` is padded to the measured column so the status bracket lands
    /// where a real server puts it.
    private func record(
        callsign: String,
        location: String,
        tag: String?,
        node: String,
        address: String
    ) -> String {
        var second = location
        if let tag {
            second = location.padding(
                toLength: max(EchoLinkStationList.statusColumn, location.count),
                withPad: " ",
                startingAt: 0) + "[\(tag)]"
        }
        return "\(callsign)\n\(second)\n\(node)\n\(address)\n"
    }

    private func list(_ records: [String], declared: Int? = nil, serial: String = "64244576",
                      terminated: Bool = true) -> String {
        let count = declared ?? records.count
        return "@@@\n\(count):\(serial)\n" + records.joined() + (terminated ? "+++" : "")
    }

    /// Three invented stations covering the ordinary shape.
    private var threeStations: [String] {
        [
            record(callsign: "N0CALL", location: "Nowhere", tag: "ON 19:43",
                   node: "100001", address: "192.0.2.11"),
            record(callsign: "*ECHOTEST*", location: "Audio test server", tag: "ON 09:12",
                   node: "9999", address: "198.51.100.7"),
            record(callsign: "VK1XXX-R", location: "Fictional Hill", tag: "BUSY 06:05",
                   node: "12345", address: "203.0.113.42"),
        ]
    }

    // MARK: - The ordinary case

    func testParsesTheOrdinaryShape() throws {
        let parsed = try EchoLinkStationList.parse(text: list(threeStations))

        XCTAssertEqual(parsed.declaredCount, 3)
        XCTAssertEqual(parsed.serial, "64244576")
        XCTAssertEqual(parsed.stations.count, 3)
        XCTAssertTrue(parsed.notices.isEmpty)

        XCTAssertEqual(parsed.stations[0], EchoLinkStation(
            callsign: "N0CALL", location: "Nowhere", status: "ON", time: "19:43",
            nodeNumber: 100_001, address: "192.0.2.11"))
        XCTAssertEqual(parsed.stations[1].callsign, "*ECHOTEST*")
        XCTAssertEqual(parsed.stations[2].status, "BUSY")
        XCTAssertEqual(parsed.stations[2].time, "06:05")
    }

    func testParsesFromDataAsWellAsText() throws {
        let data = Data(list(threeStations).utf8)
        XCTAssertEqual(try EchoLinkStationList.parse(data).stations.count, 3)
    }

    // MARK: - The subtle field

    /// The location may itself contain brackets, and usually does: `[Svx]`,
    /// `[0/20]` and similar prefixes appear in **3496 of the reference list's
    /// 6441 entries**. Splitting on the *first* `[` — the obvious
    /// implementation — would report a status of "Svx" for more than half the
    /// directory and lose the real one.
    func testALocationContainingBracketsDoesNotStealTheStatus() throws {
        let entry = record(callsign: "VK1XXX-L", location: "[Svx] 145.6625 [0/20]",
                           tag: "ON 05:12", node: "756230", address: "192.0.2.99")
        let parsed = try EchoLinkStationList.parse(text: list([entry]))

        XCTAssertEqual(parsed.stations[0].status, "ON")
        XCTAssertEqual(parsed.stations[0].time, "05:12")
        XCTAssertEqual(parsed.stations[0].location, "[Svx] 145.6625 [0/20]")
    }

    /// Every station in the reference list said `ON` (6059) or `BUSY` (382),
    /// and nothing else. The parser still carries the word rather than mapping
    /// it onto an enum: two values from one server on one day is the sample we
    /// have, not a closed set, and this module's standing rule is to hand an
    /// unexpected value to the caller intact rather than fail or flatten it.
    func testAnUnexpectedStatusWordIsCarriedRatherThanRejected() throws {
        for word in ["ON", "BUSY", "Svx", "ORP", "ASL", "CONF"] {
            let entry = record(callsign: "VK1XXX", location: "Somewhere", tag: "\(word) 11:12",
                               node: "1000", address: "192.0.2.1")
            let parsed = try EchoLinkStationList.parse(text: list([entry]))
            XCTAssertEqual(parsed.stations[0].status, word)
        }
    }

    /// Eight of the reference entries carry `H:MM` rather than `HH:MM`, which
    /// makes the record line 36 characters instead of 37. Nothing may depend on
    /// the line's total length.
    func testASingleDigitHourStillParses() throws {
        let entry = record(callsign: "VK1XXX", location: "Somewhere", tag: "ON 5:12",
                           node: "1000", address: "192.0.2.1")
        let parsed = try EchoLinkStationList.parse(text: list([entry]))
        XCTAssertEqual(parsed.stations[0].time, "5:12")
    }

    /// No station in the reference list omitted the bracket, but the server's
    /// own trailing notices do, and a location is free text an operator sets.
    func testAnEntryWithNoStatusBracketIsAllLocation() throws {
        let entry = record(callsign: "VK1XXX", location: "No bracket here", tag: nil,
                           node: "1000", address: "192.0.2.1")
        let parsed = try EchoLinkStationList.parse(text: list([entry]))

        XCTAssertEqual(parsed.stations[0].location, "No bracket here")
        XCTAssertNil(parsed.stations[0].status)
        XCTAssertNil(parsed.stations[0].time)
    }

    // MARK: - The server's own trailing entries

    /// The reference list ends with three entries that have a blank callsign, a
    /// blank node number and `127.0.0.1`. They are not stations, but they *do*
    /// count toward the header's total, so dropping them would turn a correct
    /// list into a count mismatch.
    func testBlankCallsignEntriesBecomeNoticesAndStillCount() throws {
        let notice = record(callsign: " ", location: "SomeServer v1.2.345", tag: nil,
                            node: "    ", address: "127.0.0.1")
        let parsed = try EchoLinkStationList.parse(text: list(threeStations + [notice]))

        XCTAssertEqual(parsed.stations.count, 3)
        XCTAssertEqual(parsed.notices, ["SomeServer v1.2.345"])
        XCTAssertEqual(parsed.entryCount, 4)
        XCTAssertEqual(parsed.declaredCount, 4)
    }

    func testABlankNodeNumberIsNilRatherThanZero() throws {
        let entry = record(callsign: "VK1XXX", location: "Somewhere", tag: "ON 11:12",
                           node: "    ", address: "127.0.0.1")
        let parsed = try EchoLinkStationList.parse(text: list([entry]))

        XCTAssertNil(parsed.stations[0].nodeNumber)
        XCTAssertFalse(parsed.stations[0].isConnectable)
    }

    func testConnectabilityRejectsLoopbackAndUnspecified() throws {
        let entries = [
            record(callsign: "A", location: "x", tag: "ON 1:00", node: "1", address: "192.0.2.1"),
            record(callsign: "B", location: "x", tag: "ON 1:00", node: "2", address: "127.0.0.1"),
            record(callsign: "C", location: "x", tag: "ON 1:00", node: "3", address: "0.0.0.0"),
        ]
        let parsed = try EchoLinkStationList.parse(text: list(entries))
        XCTAssertEqual(parsed.stations.map(\.isConnectable), [true, false, false])
    }

    // MARK: - Malformed and partial lists are typed errors

    func testAMissingMarkerIsAnError() {
        let text = "6444:1\n+++"
        XCTAssertThrowsError(try EchoLinkStationList.parse(text: text)) { error in
            guard case EchoLinkStationListError.missingMarker = error else {
                return XCTFail("expected .missingMarker, got \(error)")
            }
        }
    }

    func testAMalformedCountLineIsAnError() {
        for header in ["not-a-count", "abc:def", ""] {
            let text = "@@@\n\(header)\n+++"
            XCTAssertThrowsError(try EchoLinkStationList.parse(text: text)) { error in
                guard case EchoLinkStationListError.malformedCountLine = error else {
                    return XCTFail("expected .malformedCountLine for \(header.debugDescription), got \(error)")
                }
            }
        }
    }

    /// The failure this type exists to prevent: a download that stops part-way
    /// must not read as a short but complete list.
    func testATruncatedListIsAnErrorRatherThanAShortRead() {
        let full = list(threeStations)
        let cut = String(full.prefix(full.count - 40))

        XCTAssertThrowsError(try EchoLinkStationList.parse(text: cut)) { error in
            guard case EchoLinkStationListError.missingTerminator = error else {
                return XCTFail("expected .missingTerminator, got \(error)")
            }
        }
    }

    func testARecordCutMidWayIsATruncatedRecord() {
        // Terminator present, but the last record is one line short.
        let text = "@@@\n2:1\n" + threeStations[0] + "VK1XXX\nSomewhere\n1000\n" + "+++"
        XCTAssertThrowsError(try EchoLinkStationList.parse(text: text)) { error in
            guard case EchoLinkStationListError.truncatedRecord(let after, let dangling) = error else {
                return XCTFail("expected .truncatedRecord, got \(error)")
            }
            XCTAssertEqual(after, 1)
            XCTAssertEqual(dangling, 3)
        }
    }

    /// The header is the server's own statement of what it was about to send,
    /// so a disagreement means bytes were lost.
    func testAHeaderCountThatDisagreesIsAnError() {
        let text = list(threeStations, declared: 4)
        XCTAssertThrowsError(try EchoLinkStationList.parse(text: text)) { error in
            guard case EchoLinkStationListError.countMismatch(let declared, let parsed) = error else {
                return XCTFail("expected .countMismatch, got \(error)")
            }
            XCTAssertEqual(declared, 4)
            XCTAssertEqual(parsed, 3)
        }
    }

    func testAnEmptyListIsValid() throws {
        let parsed = try EchoLinkStationList.parse(text: list([], declared: 0))
        XCTAssertEqual(parsed.declaredCount, 0)
        XCTAssertTrue(parsed.stations.isEmpty)
    }

    // MARK: - The request

    func testTheRequestIsTheThreeMeasuredBytes() {
        XCTAssertEqual(Array(EchoLinkStationList.stationListRequest), [0x66, 0x30, 0x0D])
    }

    // MARK: - Reading it off a stream

    /// The real download crossed 214 proxy frames and split records — and
    /// fields — at arbitrary points, so a reader that assumed frame boundaries
    /// meant anything would fail on the real thing and pass every test built
    /// from whole records. Feed it one byte at a time, which is the worst case.
    func testTheReaderReassemblesAcrossArbitraryChunking() throws {
        let text = list(threeStations)
        var reader = EchoLinkStationListReader()
        var result: EchoLinkStationList?

        for byte in Array(text.utf8) {
            XCTAssertNil(result, "the reader returned a list before the terminator arrived")
            result = try reader.append(Data([byte]))
        }

        XCTAssertEqual(result?.stations.count, 3)
    }

    func testTheReaderReturnsNilUntilTheTerminatorArrives() throws {
        var reader = EchoLinkStationListReader()
        let text = list(threeStations, terminated: false)
        XCTAssertNil(try reader.append(Data(text.utf8)))
        XCTAssertEqual(reader.bufferedByteCount, text.utf8.count)

        let finished = try reader.append(Data("+++".utf8))
        XCTAssertEqual(finished?.stations.count, 3)
    }

    /// A stalled download is not a short list.
    func testFinishingAnUnterminatedListThrows() {
        var reader = EchoLinkStationListReader()
        XCTAssertNil(try? reader.append(Data(list(threeStations, terminated: false).utf8)))
        XCTAssertThrowsError(try reader.finish()) { error in
            guard case EchoLinkStationListError.missingTerminator = error else {
                return XCTFail("expected .missingTerminator, got \(error)")
            }
        }
    }

    // MARK: - Conformance against the real list (opt-in)

    /// Parse the real 6444-entry download and assert its tally.
    ///
    /// **This is the evidence.** Everything above tests the parser against
    /// rules; this tests the rules against the wire. It is skipped unless
    /// `HAMVOIP_ECHOLINK_STATION_LIST` names a file holding the concatenated
    /// `0x02` payloads of a directory list download, because that file contains
    /// thousands of other operators' details and cannot be committed.
    ///
    /// The expected numbers are the measurement recorded in the EL-11 entry of
    /// `docs/DEVELOPMENT-PLAN.md`. A different capture will have different
    /// totals, so those are only asserted for the reference file's exact size.
    func testTheRealListParses() throws {
        let variable = "HAMVOIP_ECHOLINK_STATION_LIST"
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("""
                set \(variable) to a directory-list download to run the conformance test. \
                The reference file is not committed: it holds thousands of other operators' \
                callsigns and addresses. See the EL-11 entry in docs/DEVELOPMENT-PLAN.md.
                """)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try EchoLinkStationList.parse(data)

        XCTAssertEqual(parsed.entryCount, parsed.declaredCount)
        XCTAssertFalse(parsed.stations.isEmpty)

        // Deliberately no assertion naming any station: this test's output must
        // stay safe to paste into a pull request.
        if data.count == 433_414 {
            XCTAssertEqual(parsed.declaredCount, 6444)
            XCTAssertEqual(parsed.stations.count, 6441)
            XCTAssertEqual(parsed.notices.count, 3)
            XCTAssertEqual(parsed.serial, "64244576")
            XCTAssertEqual(parsed.stations.filter { $0.status == "ON" }.count, 6059)
            XCTAssertEqual(parsed.stations.filter { $0.status == "BUSY" }.count, 382)
            // ON + BUSY is every station: no third status word occurs.
            XCTAssertEqual(parsed.stations.filter {
                $0.status != "ON" && $0.status != "BUSY"
            }.count, 0)
            XCTAssertEqual(parsed.stations.filter { $0.nodeNumber == nil }.count, 0)
            XCTAssertEqual(parsed.stations.filter { $0.time == nil }.count, 0)
            XCTAssertEqual(parsed.stations.filter { $0.callsign.hasPrefix("*") }.count, 227)
        }
    }
}
