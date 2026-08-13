// SPDX-License-Identifier: Apache-2.0

import XCTest
import EchoLinkKit
import RadioCore
import TestSupport

/// EL-12 — public proxy discovery: parsing the list, probing candidates, and
/// choosing one.
///
/// No socket and no HTTP request (AU-5). The list comes from a fixture, the
/// fetch sits behind `EchoLinkPublicProxySource`, and probes run over
/// `MockStreamTransport`.
final class EchoLinkProxyDirectoryTests: XCTestCase {

    // MARK: Helpers

    private func sampleData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "proxyfind-sample", withExtension: "xml", subdirectory: "Fixtures")
        else {
            XCTFail("proxyfind-sample.xml missing from the test bundle")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    private func parseSample() throws -> [EchoLinkPublicProxy] {
        try EchoLinkProxyListParser.parse(try sampleData())
    }

    private func proxy(
        _ name: String,
        distance: Double? = nil,
        status: String = "Ready",
        isPublic: Bool = true,
        port: UInt16 = 8100
    ) -> EchoLinkPublicProxy {
        EchoLinkPublicProxy(
            name: name,
            address: "\(name.lowercased()).example.invalid",
            port: port,
            distanceKilometres: distance,
            status: status,
            isPublic: isPublic)
    }

    /// A source that hands back a canned list.
    private struct StubSource: EchoLinkPublicProxySource {
        let proxies: [EchoLinkPublicProxy]
        let error: (any Error)?

        init(_ proxies: [EchoLinkPublicProxy], error: (any Error)? = nil) {
            self.proxies = proxies
            self.error = error
        }

        func publicProxies() async throws -> [EchoLinkPublicProxy] {
            if let error { throw error }
            return proxies
        }
    }

    /// Records which proxies were probed, and answers from a table.
    private final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        private let latencies: [String: Duration]

        init(latencies: [String: Duration]) {
            self.latencies = latencies
        }

        var probed: [String] {
            lock.withLock { names }
        }

        func probe(_ proxy: EchoLinkPublicProxy) -> Duration? {
            lock.withLock { names.append(proxy.name) }
            return latencies[proxy.name]
        }
    }

    // MARK: - Parsing

    func testParsesAnObservedEntryFieldByField() throws {
        let parsed = try parseSample()
        guard let first = parsed.first else { return XCTFail("no entries parsed") }

        XCTAssertEqual(first.name, "CE5RPY 091")
        // The description arrives as CDATA, which `foundCharacters` is never
        // called for — this is the assertion that catches losing that callback.
        XCTAssertEqual(first.comment, "Gentileza REDCHILE.org")
        XCTAssertEqual(first.address, "proxy92.redchile.org")
        XCTAssertEqual(first.port, 8100)
        XCTAssertEqual(first.distanceKilometres, 10914.669502093946)
        XCTAssertEqual(first.version, "1.2.5c")
        XCTAssertEqual(first.status, "Ready")
        XCTAssertTrue(first.isPublic)
        XCTAssertTrue(first.isReady)
    }

    func testEntriesArriveInDocumentOrder() throws {
        let parsed = try parseSample()
        XCTAssertEqual(
            parsed.prefix(3).map(\.name), ["CE5RPY 091", "CE5RPY 085", "NEAR PROXY"])
    }

    func testEntryWithoutAPortAssumesTheDefault() throws {
        let entry = try XCTUnwrap(try parseSample().first { $0.name == "NO PORT" })
        XCTAssertEqual(entry.port, EchoLinkProxyListParser.assumedPort)
        XCTAssertEqual(entry.port, 8100)
    }

    /// A port we would have to guess at is worse than one fewer candidate.
    func testEntryWithAnUnreadablePortIsSkipped() throws {
        XCTAssertNil(try parseSample().first { $0.name == "BAD PORT" })
    }

    func testEntryWithoutAnAddressIsSkipped() throws {
        XCTAssertNil(try parseSample().first { $0.name == "NO ADDRESS" })
    }

    /// One unusable row must not cost the operator the other 281.
    func testSkippedEntriesDoNotFailTheWholeDocument() throws {
        XCTAssertEqual(try parseSample().count, 7)
    }

    func testStatusIsCarriedVerbatimRatherThanParsed() throws {
        let busy = try XCTUnwrap(try parseSample().first { $0.name == "BUSY PROXY" })
        XCTAssertEqual(busy.status, "Busy")
        XCTAssertFalse(busy.isReady)
    }

    func testReadinessComparisonIsCaseInsensitive() {
        XCTAssertTrue(
            EchoLinkPublicProxy(name: "x", address: "h", status: "READY").isReady)
        XCTAssertTrue(
            EchoLinkPublicProxy(name: "x", address: "h", status: "ready").isReady)
    }

    func testPrivateEntryIsCarried() throws {
        let entry = try XCTUnwrap(try parseSample().first { $0.name == "PRIVATE PROXY" })
        XCTAssertFalse(entry.isPublic)
    }

    /// Nothing establishes that `<public>` is always present, and inferring
    /// consent to use somebody's machine from a missing field would be wrong.
    func testMissingPublicFieldIsNotTreatedAsPublic() throws {
        let xml = """
            <?xml version="1.0"?>
            <proxylist><proxy name="X"><status>Ready</status>\
            <address>x.example.invalid</address><port>8100</port></proxy></proxylist>
            """
        let parsed = try EchoLinkProxyListParser.parse(Data(xml.utf8))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertFalse(parsed[0].isPublic)
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(
            try EchoLinkProxyListParser.parse(Data("<proxylist><proxy".utf8))
        ) { error in
            guard case EchoLinkProxyDirectoryError.malformedDocument = error else {
                return XCTFail("expected .malformedDocument, got \(error)")
            }
        }
    }

    /// Well-formed XML that is not this document at all — an error page, say.
    func testDocumentWithoutTheExpectedRootThrows() {
        XCTAssertThrowsError(
            try EchoLinkProxyListParser.parse(Data("<html><body>nope</body></html>".utf8))
        ) { error in
            guard case EchoLinkProxyDirectoryError.malformedDocument = error else {
                return XCTFail("expected .malformedDocument, got \(error)")
            }
        }
    }

    func testEmptyListParsesToNoEntries() throws {
        let parsed = try EchoLinkProxyListParser.parse(Data("<proxylist></proxylist>".utf8))
        XCTAssertTrue(parsed.isEmpty)
    }

    // MARK: - Candidate selection

    func testCandidatesExcludeBusyAndPrivateProxies() async throws {
        let selector = EchoLinkProxySelector(
            source: StubSource(try parseSample()), prober: { _ in nil })
        let names = try await selector.candidates().map(\.name)

        XCTAssertFalse(names.contains("BUSY PROXY"))
        XCTAssertFalse(names.contains("PRIVATE PROXY"))
        XCTAssertEqual(names.count, 5)
    }

    /// The endpoint does sort by distance, but that is an observation about one
    /// day's responses rather than a documented contract.
    func testCandidatesAreSortedNearestFirstWithUnknownDistanceLast() async throws {
        let listed = [
            proxy("FAR", distance: 900),
            proxy("UNKNOWN", distance: nil),
            proxy("NEAR", distance: 10),
            proxy("MIDDLE", distance: 100),
        ]
        let selector = EchoLinkProxySelector(
            source: StubSource(listed), prober: { _ in nil })

        let names = try await selector.candidates().map(\.name)
        XCTAssertEqual(names, ["NEAR", "MIDDLE", "FAR", "UNKNOWN"])
    }

    func testNothingReadyThrowsNoProxyAvailable() async {
        let selector = EchoLinkProxySelector(
            source: StubSource([proxy("BUSY", status: "Busy")]), prober: { _ in nil })

        do {
            _ = try await selector.selectFastest()
            XCTFail("expected .noProxyAvailable")
        } catch EchoLinkProxyDirectoryError.noProxyAvailable {
            // Expected: every public proxy being taken at once is an ordinary
            // Saturday, not a fault.
        } catch {
            XCTFail("expected .noProxyAvailable, got \(error)")
        }
    }

    func testFetchFailurePropagates() async {
        let selector = EchoLinkProxySelector(
            source: StubSource([], error: EchoLinkProxyDirectoryError.requestFailed("HTTP 503")),
            prober: { _ in nil })

        do {
            _ = try await selector.selectFastest()
            XCTFail("expected .requestFailed")
        } catch EchoLinkProxyDirectoryError.requestFailed {
            // Expected.
        } catch {
            XCTFail("expected .requestFailed, got \(error)")
        }
    }

    /// The point of probing: the quickest to answer wins, not the nearest.
    func testFastestInTheBatchWinsRatherThanTheNearest() async throws {
        let listed = [
            proxy("NEAREST", distance: 10),
            proxy("MIDDLE", distance: 100),
            proxy("FURTHEST", distance: 1000),
        ]
        let log = ProbeLog(latencies: [
            "NEAREST": .milliseconds(400),
            "MIDDLE": .milliseconds(90),
            "FURTHEST": .milliseconds(250),
        ])
        let selector = EchoLinkProxySelector(
            source: StubSource(listed), prober: { log.probe($0) }, batchSize: 3)

        let chosen = try await selector.selectFastest()
        XCTAssertEqual(chosen.proxy.name, "MIDDLE")
        XCTAssertEqual(chosen.latency, .milliseconds(90))
    }

    func testDeadCandidatesAreSkippedForALiveOne() async throws {
        let listed = [proxy("DEAD1", distance: 1), proxy("DEAD2", distance: 2),
                      proxy("ALIVE", distance: 3)]
        let log = ProbeLog(latencies: ["ALIVE": .milliseconds(300)])
        let selector = EchoLinkProxySelector(
            source: StubSource(listed), prober: { log.probe($0) }, batchSize: 3)

        let chosen = try await selector.selectFastest()
        XCTAssertEqual(chosen.proxy.name, "ALIVE")
    }

    /// A batch of dead candidates must not end the search while candidates
    /// remain — "listed Ready but taken" is the common case, not the edge case.
    func testSearchContinuesIntoTheNextBatch() async throws {
        let listed = (1 ... 6).map { proxy("P\($0)", distance: Double($0)) }
        let log = ProbeLog(latencies: ["P5": .milliseconds(120)])
        let selector = EchoLinkProxySelector(
            source: StubSource(listed), prober: { log.probe($0) }, batchSize: 2)

        let chosen = try await selector.selectFastest()
        XCTAssertEqual(chosen.proxy.name, "P5")
        // Batches of two, in distance order, stopping once one answers.
        XCTAssertEqual(log.probed.sorted(), ["P1", "P2", "P3", "P4", "P5", "P6"].sorted())
    }

    func testCandidateLimitCapsHowManyStrangersMachinesAreTouched() async {
        let listed = (1 ... 20).map { proxy("P\($0)", distance: Double($0)) }
        let log = ProbeLog(latencies: [:])
        let selector = EchoLinkProxySelector(
            source: StubSource(listed), prober: { log.probe($0) },
            batchSize: 2, candidateLimit: 6)

        do {
            _ = try await selector.selectFastest()
            XCTFail("expected .noProxyAnswered")
        } catch EchoLinkProxyDirectoryError.noProxyAnswered(let probed) {
            XCTAssertEqual(probed, 6)
            XCTAssertEqual(log.probed.count, 6)
        } catch {
            XCTFail("expected .noProxyAnswered, got \(error)")
        }
    }

    func testProgressIsReportedOncePerBatch() async throws {
        let listed = (1 ... 4).map { proxy("P\($0)", distance: Double($0)) }
        let log = ProbeLog(latencies: ["P4": .milliseconds(10)])
        let batches = BatchLog()
        let selector = EchoLinkProxySelector(
            source: StubSource(listed), prober: { log.probe($0) }, batchSize: 2)

        _ = try await selector.selectFastest { batches.record($0) }
        XCTAssertEqual(batches.recorded, [["P1", "P2"], ["P3", "P4"]])
    }

    private final class BatchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[String]] = []

        var recorded: [[String]] {
            lock.withLock { batches }
        }

        func record(_ batch: [EchoLinkPublicProxy]) {
            lock.withLock { batches.append(batch.map(\.name)) }
        }
    }

    /// The overload exists so the CLI can fetch once, say what it found, and
    /// then probe — rather than fetching the same list twice.
    func testProbingAPreFetchedListDoesNotFetchAgain() async throws {
        let counting = CountingSource(proxies: [proxy("ONLY", distance: 1)])
        let selector = EchoLinkProxySelector(
            source: counting, prober: { _ in .milliseconds(50) })

        let candidates = try await selector.candidates()
        _ = try await selector.selectFastest(among: candidates)
        XCTAssertEqual(counting.fetches, 1)
    }

    private final class CountingSource: EchoLinkPublicProxySource, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let proxies: [EchoLinkPublicProxy]

        init(proxies: [EchoLinkPublicProxy]) {
            self.proxies = proxies
        }

        var fetches: Int {
            lock.withLock { count }
        }

        func publicProxies() async throws -> [EchoLinkPublicProxy] {
            lock.withLock { count += 1 }
            return proxies
        }
    }

    // MARK: - Probing

    private func makeProbe(
        timeout: Duration = .seconds(5),
        factory: @escaping EchoLinkProxyProbe<ContinuousClock>.TransportFactory
    ) -> EchoLinkProxyProbe<ContinuousClock> {
        EchoLinkProxyProbe(
            timeout: timeout, clock: ContinuousClock(), transportFactory: factory)
    }

    func testProbeAcceptsANonce() async {
        let transport = MockStreamTransport()
        transport.inject(Data("6fc8b7e3".utf8))
        let probe = makeProbe { _, _ in transport }

        let latency = await probe.probe(proxy("P"))
        XCTAssertNotNil(latency)
    }

    /// The `StreamTransport` contract says chunk boundaries carry no meaning,
    /// and eight bytes is small enough to arrive split. A probe that assumed
    /// one chunk would report a perfectly good proxy as dead.
    func testProbeAcceptsANonceSplitAcrossChunks() async {
        let transport = MockStreamTransport()
        transport.injectByteByByte(Data("6fc8b7e3".utf8))
        let probe = makeProbe { _, _ in transport }

        let latency = await probe.probe(proxy("P"))
        XCTAssertNotNil(latency)
    }

    func testProbeRejectsAGreetingThatIsNotHex() async {
        let transport = MockStreamTransport()
        transport.inject(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]))
        let probe = makeProbe { _, _ in transport }

        let latency = await probe.probe(proxy("P"))
        XCTAssertNil(latency)
    }

    /// How a busy proxy actually presents: the TCP connection is accepted and
    /// then dropped without a nonce.
    func testProbeRejectsAProxyThatHangsUpWithoutGreeting() async {
        let transport = MockStreamTransport()
        transport.finish()
        let probe = makeProbe { _, _ in transport }

        let latency = await probe.probe(proxy("P"))
        XCTAssertNil(latency)
    }

    func testProbeRejectsAShortGreeting() async {
        let transport = MockStreamTransport()
        transport.inject(Data("6fc8".utf8))
        transport.finish()
        let probe = makeProbe { _, _ in transport }

        let latency = await probe.probe(proxy("P"))
        XCTAssertNil(latency)
    }

    func testProbeReturnsNilWhenTheConnectionCannotBeMade() async {
        struct Refused: Error {}
        let probe = makeProbe { _, _ in throw Refused() }

        let latency = await probe.probe(proxy("P"))
        XCTAssertNil(latency)
    }

    func testProbeGivesUpAtItsTimeout() async {
        // A transport that connects and then says nothing at all — neither a
        // greeting nor a close. Real timeout, kept short; no socket (AU-5).
        let transport = MockStreamTransport()
        let probe = makeProbe(timeout: .milliseconds(50)) { _, _ in transport }

        let latency = await probe.probe(proxy("P"))
        XCTAssertNil(latency)
    }

    /// A probe that leaves connections open is a probe that holds single-user
    /// proxies it decided against.
    func testProbeClosesTheConnectionItOpened() async {
        let transport = MockStreamTransport()
        transport.inject(Data("6fc8b7e3".utf8))
        let probe = makeProbe { _, _ in transport }

        _ = await probe.probe(proxy("P"))
        XCTAssertTrue(transport.isClosed)
    }

    func testProbeClosesTheConnectionAfterATimeoutToo() async {
        let transport = MockStreamTransport()
        let probe = makeProbe(timeout: .milliseconds(50)) { _, _ in transport }

        _ = await probe.probe(proxy("P"))
        XCTAssertTrue(transport.isClosed)
    }

    func testProbeConnectsToTheAddressAndPortFromTheListing() async {
        let transport = MockStreamTransport()
        transport.inject(Data("6fc8b7e3".utf8))
        let seen = EndpointLog()
        let probe = makeProbe { host, port in
            seen.record(host: host, port: port)
            return transport
        }

        _ = await probe.probe(
            EchoLinkPublicProxy(name: "P", address: "proxy1.example.invalid", port: 8123))
        XCTAssertEqual(seen.host, "proxy1.example.invalid")
        XCTAssertEqual(seen.port, 8123)
    }

    private final class EndpointLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: (host: String, port: UInt16)?

        var host: String? {
            lock.withLock { storage?.host }
        }
        var port: UInt16? {
            lock.withLock { storage?.port }
        }

        func record(host: String, port: UInt16) {
            lock.withLock { storage = (host, port) }
        }
    }

    /// The probe sends nothing: no login, no frame, not a byte. It is the
    /// lightest touch that still proves a proxy is there and free.
    func testProbeSendsNothing() async {
        let transport = MockStreamTransport()
        transport.inject(Data("6fc8b7e3".utf8))
        let probe = makeProbe { _, _ in transport }

        _ = await probe.probe(proxy("P"))
        XCTAssertEqual(transport.sentCount, 0)
    }
}
