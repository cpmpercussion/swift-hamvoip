// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - A listed public proxy

/// One entry from EchoLink's public proxy list.
///
/// A public proxy is somebody else's machine, offered to any EchoLink user, and
/// **single-user**: it carries one client at a time. That is the fact that
/// shapes everything in this file. `status` is a snapshot from whenever the
/// directory last polled the proxy, so a `Ready` entry is a *candidate* rather
/// than a promise — see ``EchoLinkProxySelector`` for why we probe instead of
/// trusting it.
public struct EchoLinkPublicProxy: Sendable, Equatable, Hashable {
    /// The operator's name for the proxy, e.g. `"VK2BSD PROXY #1"`. From the
    /// `name` attribute, and free text — do not parse a callsign out of it.
    public let name: String

    /// The operator's own description, e.g. `"Public Proxy #1 (Sydney,
    /// Australia)"`. Free text, arrives as CDATA, and may be empty.
    public let comment: String

    /// Host name or literal address. Unlike almost everything else in EchoLink
    /// this **may be a name** rather than a dotted quad — most listed proxies
    /// are named hosts — so it is resolved normally rather than passed as four
    /// raw octets the way a node's address is.
    public let address: String

    /// The proxy's TCP port. Almost always 8100, and deliberately not assumed;
    /// see ``EchoLinkProxyListParser``.
    public let port: UInt16

    /// Great-circle distance in kilometres from wherever the directory thinks
    /// the request came from, or `nil` if the server did not say.
    ///
    /// A *prior*, not a measurement: it orders candidates plausibly, and
    /// ``EchoLinkProxySelector`` then measures the round trip for real. Worth
    /// knowing that for VK1 the nearest listed proxy on 2026-08-13 was in Chile
    /// at ~10 900 km, so the ordering is a much weaker signal here than it
    /// would be in Europe.
    public let distanceKilometres: Double?

    /// The proxy software's version string, e.g. `"1.2.5c"`. Recorded because it
    /// is the only hint available about which behaviours a given proxy has, and
    /// unused otherwise.
    public let version: String

    /// The directory's status word, verbatim — `"Ready"` or `"Busy"`.
    ///
    /// Kept as the server's own string rather than parsed into an enum: the
    /// full set of values it can take is not established, and inventing an
    /// `.unknown` case for a word we simply have not seen would imply we know
    /// the vocabulary is closed.
    public let status: String

    /// Whether the proxy's operator advertised it for public use.
    public let isPublic: Bool

    public init(
        name: String,
        comment: String = "",
        address: String,
        port: UInt16 = 8100,
        distanceKilometres: Double? = nil,
        version: String = "",
        status: String = "Ready",
        isPublic: Bool = true
    ) {
        self.name = name
        self.comment = comment
        self.address = address
        self.port = port
        self.distanceKilometres = distanceKilometres
        self.version = version
        self.status = status
        self.isPublic = isPublic
    }

    /// Whether the directory last saw this proxy free. Case-insensitive,
    /// because nothing establishes the server's capitalisation is stable.
    public var isReady: Bool {
        status.caseInsensitiveCompare("Ready") == .orderedSame
    }
}

// MARK: - Errors

/// Why proxy discovery failed.
public enum EchoLinkProxyDirectoryError: Error, Equatable, CustomStringConvertible {
    /// The document was not the XML we expect. Payload is for logging.
    case malformedDocument(String)

    /// The request failed, or the server answered with an HTTP error.
    case requestFailed(String)

    /// The list parsed, but held no proxy that was both public and `Ready`.
    ///
    /// Not a fault: public proxies are single-user and contended, and every one
    /// of them being busy at once is an ordinary Saturday.
    case noProxyAvailable

    /// Candidates were probed and none answered with a proxy greeting.
    case noProxyAnswered(probed: Int)

    public var description: String {
        switch self {
        case .malformedDocument(let detail):
            return "the proxy list was not the expected XML: \(detail)"
        case .requestFailed(let detail):
            return "could not fetch the proxy list: \(detail)"
        case .noProxyAvailable:
            return
                "no public proxy is listed as ready — they are single-user and heavily "
                + "contended, so this happens; try again shortly"
        case .noProxyAnswered(let probed):
            return
                "probed \(probed) proxy/proxies listed as ready and none answered — a "
                + "listed proxy is often taken by the time anyone connects"
        }
    }
}

// MARK: - Parsing the list

/// Parses the XML that EchoLink's proxy-finder endpoint returns. No I/O.
///
/// ## Why XML and not the web page
///
/// There are two published forms of the same data. `proxylist.jsp` is an HTML
/// table meant for a human — 932 rows and 366 KB on 2026-08-13. `proxyFind.jsp`
/// returns this XML, pre-filtered to the entries that are both public and
/// `Ready`, sorted by distance ascending, with `Access-Control-Allow-Origin: *`
/// and `Pragma: no-cache`. Fetched within the same second on 2026-08-13, the
/// HTML page held **282** `Ready` rows and the XML held **282** entries, with no
/// discrepancy in either direction. So the endpoint is the same data in a form
/// that does not require parsing presentational markup, and scraping the page
/// would be choosing the harder source of the two.
///
/// ## What is deliberately not sent
///
/// The endpoint accepts `lat` and `lon` (those exact spellings; `latitude` and
/// `longitude` are ignored) and otherwise geolocates the requesting address.
/// We send neither. On 2026-08-13 the IP-derived location put a Canberra
/// request within ~11 km of the truth, which is noise against distances of ten
/// thousand kilometres — so supplying real coordinates would mean prompting for
/// location permission and handing a third party the operator's position in
/// exchange for nothing measurable.
///
/// ## Shape
///
/// ```xml
/// <proxylist>
/// <proxy name="CE5RPY 091">
/// <desc><![CDATA[Gentileza REDCHILE.org]]></desc>
/// <distance>10914.669502093946</distance>
/// <status>Ready</status>
/// <address>proxy92.redchile.org</address>
/// <port>8100</port>
/// <version>1.2.5c</version>
/// <public>true</public>
/// </proxy>
/// </proxylist>
/// ```
public enum EchoLinkProxyListParser {
    /// The port a proxy runs on when its entry does not say.
    ///
    /// Every one of the 282 entries seen on 2026-08-13 said 8100, and
    /// `proxylist.jsp` states it as the default "unless otherwise stated" —
    /// which is exactly why the value is read from each entry rather than
    /// assumed. This constant covers only an entry with no `<port>` at all.
    public static let assumedPort: UInt16 = 8100

    /// Parses a `proxyFind.jsp` document.
    ///
    /// Entries are returned in document order, which the server sorts by
    /// distance ascending. An entry with no usable address is skipped rather
    /// than failing the parse: one unusable row out of hundreds should not cost
    /// the operator the whole list. An entry whose `<port>` is present but
    /// unreadable is also skipped — a proxy on a port we had to guess is worse
    /// than one fewer candidate.
    ///
    /// - Throws: ``EchoLinkProxyDirectoryError/malformedDocument(_:)`` if the
    ///   document is not well-formed XML or has no `<proxylist>` root.
    public static func parse(_ data: Data) throws -> [EchoLinkPublicProxy] {
        let delegate = ProxyListDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            let detail = parser.parserError.map { String(describing: $0) } ?? "unknown parse error"
            throw EchoLinkProxyDirectoryError.malformedDocument(detail)
        }
        guard delegate.sawRoot else {
            throw EchoLinkProxyDirectoryError.malformedDocument("no <proxylist> element")
        }
        return delegate.proxies
    }
}

/// `XMLParser`'s delegate is a class with mutable state, which is why this is
/// not a `struct`. It never escapes ``EchoLinkProxyListParser/parse(_:)``.
private final class ProxyListDelegate: NSObject, XMLParserDelegate {
    private(set) var proxies: [EchoLinkPublicProxy] = []
    private(set) var sawRoot = false

    /// Fields of the `<proxy>` currently open, or `nil` between entries.
    private var current: (name: String, fields: [String: String])?
    /// The element whose character data we are collecting.
    private var openElement: String?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "proxylist":
            sawRoot = true
        case "proxy":
            current = (name: attributes["name"] ?? "", fields: [:])
        default:
            openElement = elementName
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard openElement != nil else { return }
        text += string
    }

    /// `<desc>` arrives as CDATA, which `foundCharacters` is never called for.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard openElement != nil else { return }
        text += String(data: CDATABlock, encoding: .utf8)
            ?? String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "proxy" {
            if let entry = current.flatMap(Self.makeProxy) { proxies.append(entry) }
            current = nil
            openElement = nil
            return
        }
        if let openElement, openElement == elementName, current != nil {
            current?.fields[openElement] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        openElement = nil
        text = ""
    }

    /// Turns collected fields into an entry, or `nil` if it cannot be trusted.
    private static func makeProxy(
        _ entry: (name: String, fields: [String: String])
    ) -> EchoLinkPublicProxy? {
        let fields = entry.fields
        guard let address = fields["address"], !address.isEmpty else { return nil }

        let port: UInt16
        if let raw = fields["port"], !raw.isEmpty {
            guard let parsed = UInt16(raw), parsed != 0 else { return nil }
            port = parsed
        } else {
            port = EchoLinkProxyListParser.assumedPort
        }

        return EchoLinkPublicProxy(
            name: entry.name,
            comment: fields["desc"] ?? "",
            address: address,
            port: port,
            distanceKilometres: fields["distance"].flatMap(Double.init),
            version: fields["version"] ?? "",
            status: fields["status"] ?? "",
            // Absent means we were not told it is public. The endpoint only
            // lists advertised proxies, so this is belt-and-braces rather than
            // load-bearing — but defaulting the other way would mean inferring
            // consent to use somebody's machine from a missing field.
            isPublic: (fields["public"] ?? "").caseInsensitiveCompare("true") == .orderedSame
        )
    }
}

// MARK: - Fetching the list

/// Where a list of public proxies comes from.
///
/// A protocol for the usual reason (AU-5): the real implementation makes an
/// HTTPS request, and no unit test may touch the network. Tests substitute a
/// source that returns a parsed fixture.
public protocol EchoLinkPublicProxySource: Sendable {
    /// Every public proxy the directory currently lists as ready.
    func publicProxies() async throws -> [EchoLinkPublicProxy]
}

/// Fetches the list from EchoLink's own proxy-finder endpoint.
///
/// The one place in `EchoLinkKit` that speaks HTTP rather than a radio
/// protocol. It is here rather than in the CLI because the app needs it too,
/// and it is the service operator's own published endpoint: `robots.txt`
/// disallows only `/links.jsp`, and the response carries
/// `Access-Control-Allow-Origin: *` and `Pragma: no-cache`, which is what an
/// endpoint meant to be called by clients looks like.
public struct EchoLinkProxyFinder: EchoLinkPublicProxySource {
    /// EchoLink's proxy-finder endpoint.
    public static let endpoint = URL(string: "https://www.echolink.org/proxyFind.jsp")!

    private let url: URL
    private let timeout: TimeInterval
    private let session: URLSession

    public init(
        url: URL = EchoLinkProxyFinder.endpoint,
        timeout: TimeInterval = 15,
        session: URLSession = .shared
    ) {
        self.url = url
        self.timeout = timeout
        self.session = session
    }

    public func publicProxies() async throws -> [EchoLinkPublicProxy] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // The server sends Pragma: no-cache, but a stale list is worse than a
        // slow one and the intermediate caches are not the server's to promise.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EchoLinkProxyDirectoryError.requestFailed(
                (error as? URLError)?.localizedDescription ?? String(describing: error))
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw EchoLinkProxyDirectoryError.requestFailed("HTTP \(http.statusCode)")
        }
        return try EchoLinkProxyListParser.parse(data)
    }
}

// MARK: - Probing a candidate

/// Result of a successful probe: a proxy, and how long its greeting took.
public struct EchoLinkProxyProbeResult: Sendable, Equatable {
    public let proxy: EchoLinkPublicProxy
    /// Time from starting the connection to the eighth byte of the nonce.
    /// Includes the TCP handshake, which is the point — it is what connecting
    /// will actually cost.
    public let latency: Duration

    public init(proxy: EchoLinkPublicProxy, latency: Duration) {
        self.proxy = proxy
        self.latency = latency
    }
}

/// Connects to a candidate proxy and waits for its greeting.
///
/// ## Why probe at all
///
/// Three reasons, and the first two are why `Ready` cannot simply be trusted:
///
/// 1. `status` is a poll snapshot. A proxy that was free when the directory
///    last asked is often taken by the time anyone acts on it.
/// 2. A busy proxy **accepts the TCP connection and then hangs up** without
///    sending a nonce, which surfaces from `EchoLinkProxyClient` as
///    `.streamClosed` — a confusing way to learn a shared resource is in use.
///    A probe turns that into "try the next one".
/// 3. It measures what `<distance>` only guesses at. Great-circle kilometres
///    are not milliseconds, and for VK1 every listed proxy is far enough away
///    that the ordering says little about which is quickest.
///
/// The probe deliberately stops at the nonce. It sends nothing, does not log
/// in, and holds the connection for about as long as one round trip — the
/// lightest touch that still proves a proxy is there and free.
public struct EchoLinkProxyProbe<C: Clock>: Sendable where C.Duration == Duration {
    /// How a probe opens a TCP connection. Injected so tests can substitute
    /// `MockStreamTransport` (AU-5).
    public typealias TransportFactory =
        @Sendable (_ host: String, _ port: UInt16) throws -> any StreamTransport

    /// How long to wait for a greeting.
    ///
    /// Three seconds, and it is measured rather than guessed. A live probe from
    /// VK1 on 2026-08-13 took **1.36 s** to get a nonce out of a Chilean proxy —
    /// a name that had to be resolved first, then a TCP handshake, then the
    /// greeting, all of it across the Pacific. Two seconds left almost no
    /// margin over that, and the cost of being wrong is asymmetric: too short
    /// discards working proxies and there is nothing in the output to say so,
    /// while too long only makes a dead batch slower.
    public static var defaultTimeout: Duration { .seconds(3) }

    private let timeout: Duration
    private let clock: C
    private let makeTransport: TransportFactory

    /// Generic over the clock rather than storing `any Clock<Duration>`: this
    /// type has to do instant *arithmetic* to time the greeting, and
    /// `Instant.duration(to:)` is not available through an existential.
    public init(
        timeout: Duration = EchoLinkProxyProbe.defaultTimeout,
        clock: C,
        transportFactory: @escaping TransportFactory
    ) {
        self.timeout = timeout
        self.clock = clock
        self.makeTransport = transportFactory
    }

    /// Probes one proxy.
    ///
    /// - Returns: how long the greeting took, or `nil` if the proxy did not
    ///   greet us — refused, hung up, timed out, or answered with something
    ///   that was not a nonce. Every one of those means "not this proxy", and
    ///   the caller has nothing different to do about any of them, so they are
    ///   deliberately not distinguished.
    public func probe(_ proxy: EchoLinkPublicProxy) async -> Duration? {
        let transport: any StreamTransport
        do {
            transport = try makeTransport(proxy.address, proxy.port)
        } catch {
            return nil
        }

        let start = clock.now
        let greeted = await withTaskGroup(of: Bool?.self, returning: Bool?.self) { group in
            group.addTask { await Self.awaitNonce(on: transport) }
            group.addTask { [clock, timeout] in
                try? await clock.sleep(for: timeout)
                return nil  // the timeout losing the race is the good case
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let elapsed = start.duration(to: clock.now)

        // Closed on every path, and before returning rather than in a detached
        // task: a probe that leaves connections to be reaped is a probe that
        // holds single-user proxies it decided against.
        await transport.close()

        return greeted == true ? elapsed : nil
    }

    /// Reads until eight bytes have arrived, then says whether they look like a
    /// nonce.
    ///
    /// Reassembles rather than trusting chunk boundaries, per the
    /// `StreamTransport` contract: a proxy's eight bytes may well arrive as
    /// two chunks of four, and a probe that assumed otherwise would report a
    /// perfectly good proxy as dead.
    private static func awaitNonce(on transport: any StreamTransport) async -> Bool {
        var buffer = Data()
        for await chunk in transport.incoming {
            buffer.append(chunk)
            if buffer.count >= EchoLinkAuth.nonceLength {
                return EchoLinkAuth.isPlausibleNonce(buffer.prefix(EchoLinkAuth.nonceLength))
            }
        }
        return false  // the stream finished: refused, or hung up on us
    }
}

// MARK: - Choosing one

/// Picks a public proxy: fetch the list, probe the nearest few, take the
/// quickest that answers.
///
/// This is the whole of what the official iOS client's "Public Proxy" mode
/// appears to do from the outside — its FAQ says it "automatically selects a
/// Public Proxy from the current list" and "attempts to connect to the proxy
/// that is geographically closest" — with the distance prior replaced by a
/// measured round trip, which is the same intent by a more direct route.
public struct EchoLinkProxySelector: Sendable {
    /// How a candidate is tested. Injected so the selection logic can be
    /// tested without a network or a clock.
    public typealias Prober = @Sendable (EchoLinkPublicProxy) async -> Duration?

    /// How many candidates to probe at once.
    ///
    /// Five is a compromise between two costs that pull opposite ways: probing
    /// more finds a free proxy sooner when many are busy, and probing more also
    /// means touching more strangers' machines for every connection. Five
    /// concurrent one-round-trip probes is a light enough footprint to be
    /// defensible on a shared resource.
    public static let defaultBatchSize = 5

    /// The most candidates to probe before giving up, across all batches.
    public static let defaultCandidateLimit = 15

    private let source: any EchoLinkPublicProxySource
    private let prober: Prober
    private let batchSize: Int
    private let candidateLimit: Int

    public init(
        source: any EchoLinkPublicProxySource,
        prober: @escaping Prober,
        batchSize: Int = EchoLinkProxySelector.defaultBatchSize,
        candidateLimit: Int = EchoLinkProxySelector.defaultCandidateLimit
    ) {
        self.source = source
        self.prober = prober
        self.batchSize = max(1, batchSize)
        self.candidateLimit = max(1, candidateLimit)
    }

    /// The real thing: EchoLink's endpoint, and a `Network.framework` probe
    /// (PD-1) on a `ContinuousClock`.
    public init(
        probeTimeout: Duration = EchoLinkProxyProbe<ContinuousClock>.defaultTimeout,
        batchSize: Int = EchoLinkProxySelector.defaultBatchSize,
        candidateLimit: Int = EchoLinkProxySelector.defaultCandidateLimit
    ) {
        let probe = EchoLinkProxyProbe(
            timeout: probeTimeout,
            clock: ContinuousClock(),
            transportFactory: { host, port in try NWStreamTransport(host: host, port: port) })
        self.init(
            source: EchoLinkProxyFinder(),
            prober: { await probe.probe($0) },
            batchSize: batchSize,
            candidateLimit: candidateLimit)
    }

    /// Every listed candidate worth probing, nearest first.
    ///
    /// Sorted here rather than relying on the server's ordering: the endpoint
    /// does sort by distance ascending, but that is an observation about one
    /// day's responses and not a documented contract. Entries with no distance
    /// sort last — unknown is not the same as near.
    public func candidates() async throws -> [EchoLinkPublicProxy] {
        let listed = try await source.publicProxies()
        let usable = listed.filter { $0.isPublic && $0.isReady }
        guard !usable.isEmpty else { throw EchoLinkProxyDirectoryError.noProxyAvailable }
        return usable.sorted {
            ($0.distanceKilometres ?? .greatestFiniteMagnitude)
                < ($1.distanceKilometres ?? .greatestFiniteMagnitude)
        }
    }

    /// Fetches, probes and returns the quickest proxy that answered.
    ///
    /// - Parameter onProgress: called once per batch with the candidates about
    ///   to be probed, so a caller can say what it is doing during the second
    ///   or two this takes. Called on an arbitrary task.
    /// - Throws: ``EchoLinkProxyDirectoryError`` — `.noProxyAvailable` if
    ///   nothing was listed as ready, `.noProxyAnswered(probed:)` if candidates
    ///   were probed and all were dead or taken.
    public func selectFastest(
        onProgress: (@Sendable ([EchoLinkPublicProxy]) -> Void)? = nil
    ) async throws -> EchoLinkProxyProbeResult {
        try await selectFastest(among: try await candidates(), onProgress: onProgress)
    }

    /// Probes an already-fetched candidate list.
    ///
    /// The overload that exists so a caller can fetch once, say something about
    /// what it found, and then probe — rather than calling ``candidates()`` for
    /// the count and having ``selectFastest(onProgress:)`` fetch the same list
    /// a second time.
    ///
    /// - Parameter candidates: nearest first, as ``candidates()`` returns them.
    ///   Filtering is the caller's if it takes this route; nothing here checks
    ///   `isReady` again.
    public func selectFastest(
        among candidates: [EchoLinkPublicProxy],
        onProgress: (@Sendable ([EchoLinkPublicProxy]) -> Void)? = nil
    ) async throws -> EchoLinkProxyProbeResult {
        guard !candidates.isEmpty else { throw EchoLinkProxyDirectoryError.noProxyAvailable }
        var remaining = candidates.prefix(candidateLimit)[...]
        var probed = 0

        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(batchSize))
            remaining = remaining.dropFirst(batch.count)
            probed += batch.count
            onProgress?(batch)

            let results = await withTaskGroup(
                of: EchoLinkProxyProbeResult?.self,
                returning: [EchoLinkProxyProbeResult].self
            ) { group in
                for candidate in batch {
                    group.addTask { [prober] in
                        guard let latency = await prober(candidate) else { return nil }
                        return EchoLinkProxyProbeResult(proxy: candidate, latency: latency)
                    }
                }
                var collected: [EchoLinkProxyProbeResult] = []
                for await result in group {
                    if let result { collected.append(result) }
                }
                return collected
            }

            // Quickest in the batch, not first to answer: the whole batch runs
            // concurrently and finishes within the probe timeout anyway, so
            // waiting for all of them costs nothing and buys the better pick.
            if let best = results.min(by: { $0.latency < $1.latency }) { return best }
        }

        throw EchoLinkProxyDirectoryError.noProxyAnswered(probed: probed)
    }
}
