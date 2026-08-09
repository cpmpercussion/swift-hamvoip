// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import TestSupport
import XCTest

@testable import IAX2Kit

/// IAX-8b: registration and registered-node mode (RFC 5456 §6.1, §9.3, §9.4;
/// FR-1.3).
///
/// Every test runs on `MockTransport` and `ManualTestClock`: no socket is
/// opened and **no test waits on real time** (AU-5). The two synchronisation
/// primitives are cooperative yielding (``waitFor(_:state:)`` and friends,
/// which spin the scheduler, never the wall clock) and
/// `ManualTestClock.waitUntilSleeping(count:)`, which is what makes the refresh
/// and backoff tests deterministic rather than racy.
final class IAX2RegistrationTests: XCTestCase {

    /// The registrar's 15-bit source call number in every fixture in this file.
    private let peerCallNumber: UInt16 = 0x0042

    /// Ours. `IAX2CallNumberAllocator` hands out 1 first, deterministically,
    /// which is what lets the fixtures address us by number.
    private let localCallNumber: UInt16 = 1

    /// The shared secret behind every MD5 RESULT in the fixtures. The digests
    /// were computed with the `md5` CLI and are recorded in the fixture
    /// comments:
    ///   MD5("1234567890" ‖ "s3cret") = f636d28296db47233db6b0bdeb2442a7
    ///   MD5("9876543210" ‖ "s3cret") = 796b2c115326d823e2a7f903a8af1726
    private let secret = "s3cret"

    // MARK: - Harness

    private struct Harness {
        let registrar: IAX2Registrar
        let transport: MockTransport
        let clock: ManualTestClock
        let allocator: IAX2CallNumberAllocator
    }

    private func makeHarness(
        request: IAX2RegistrationRequest? = nil,
        configuration: IAX2Registrar.Configuration = IAX2Registrar.Configuration()
    ) async throws -> Harness {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let allocator = IAX2CallNumberAllocator()
        let registrar = try await IAX2Registrar.outbound(
            allocator: allocator,
            request: request ?? IAX2RegistrationRequest(username: "n0call", secret: secret),
            transport: transport,
            clock: clock,
            configuration: configuration,
            // Deterministic renewal: §7.2.2 asks for random renewal intervals,
            // and the randomness is injected precisely so a test can pin it.
            randomUnitInterval: { 0 })
        XCTAssertEqual(
            registrar.sourceCallNumber, localCallNumber,
            "the fixtures address us by this number")
        return Harness(
            registrar: registrar, transport: transport, clock: clock, allocator: allocator)
    }

    private func tearDown(_ harness: Harness) async {
        await harness.registrar.close()
        // One tick past everything, so any retransmission timer still asleep on
        // a channel that has since been closed wakes, sees a dead channel and
        // exits — rather than being torn down mid-`sleep` and logging a leaked
        // continuation. Virtual time only; nothing waits.
        harness.clock.advance(by: .seconds(1))
        for _ in 0..<50 { await Task.yield() }
        harness.transport.finish()
    }

    // MARK: - Synchronisation helpers (scheduler-bound, never real time)

    @discardableResult
    private func waitFor(
        _ registrar: IAX2Registrar,
        state expected: IAX2RegistrationState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100_000 {
            if await registrar.state == expected { return true }
            await Task.yield()
        }
        let actual = await registrar.state
        XCTFail(
            "registration never reached state '\(expected)'; it is in '\(actual)'",
            file: file, line: line)
        return false
    }

    @discardableResult
    private func waitForSent(
        _ transport: MockTransport,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0..<100_000 {
            if transport.sentCount >= count { return true }
            await Task.yield()
        }
        XCTFail(
            "expected at least \(count) datagram(s) on the wire; saw \(transport.sentCount)",
            file: file, line: line)
        return false
    }

    /// Spins the scheduler a fixed number of times and asserts nothing more was
    /// written. Used to prove the *absence* of traffic — that a backoff really
    /// is holding.
    private func assertNoFurtherSends(
        _ transport: MockTransport,
        beyond count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 { await Task.yield() }
        XCTAssertEqual(
            transport.sentCount, count,
            "nothing further should have gone on the wire", file: file, line: line)
    }

    /// Spins until a caller is genuinely parked inside `waitUntilRegistered()`.
    /// Without this, a test that means to deliver an outcome *to a parked
    /// waiter* may deliver it before the waiter ever parks — which is the
    /// ordering the wait is supposed to survive, tested by accident and only
    /// sometimes.
    private func waitForParkedWaiter(
        _ registrar: IAX2Registrar,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100_000 {
            if await registrar.parkedWaiterCount > 0 { return }
            await Task.yield()
        }
        XCTFail("no caller ever parked in waitUntilRegistered()", file: file, line: line)
    }

    private func fixture(_ name: String) throws -> [Data] {
        try FixtureLoader.datagrams(name, in: Bundle.module)
    }

    /// Compares the transport's outbound record with a fixture, datagram by
    /// datagram, with a hex diff when they disagree.
    private func assertSent(
        _ transport: MockTransport,
        matches fixtureName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = try fixture(fixtureName)
        let actual = transport.sent
        XCTAssertEqual(
            actual.count, expected.count,
            "datagram count differs from \(fixtureName)", file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(
                Self.hex(pair.0), Self.hex(pair.1),
                "datagram \(index + 1) differs from \(fixtureName)", file: file, line: line)
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Runs a complete REGREQ → REGAUTH → REGREQ+MD5 → REGACK exchange against
    /// the session fixtures and leaves the registration in force.
    private func completeRegistration(
        _ harness: Harness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let inbound = try fixture("reg-inbound-session.hex")
        try await harness.registrar.register()
        await waitForSent(harness.transport, count: 1, file: file, line: line)
        harness.transport.inject(inbound[0])
        await waitForSent(harness.transport, count: 3, file: file, line: line)
        harness.transport.inject(inbound[1])
        await waitFor(harness.registrar, state: .registered, file: file, line: line)
    }

    // MARK: - The full registration exchange (§6.1.2 → §6.1.4)

    /// REGREQ → REGAUTH → REGREQ+MD5 → REGACK, with every emitted datagram
    /// asserted byte-for-byte against a hand-built fixture.
    func testFullRegistrationMatchesFixturesByteForByte() async throws {
        let harness = try await makeHarness()
        try await completeRegistration(harness)

        // Four datagrams: REGREQ, the ACK of the REGAUTH, the credentialed
        // REGREQ, and the ACK of the REGACK ("Receipt of a REGACK message
        // requires an ACK in response", §6.1.4).
        await waitForSent(harness.transport, count: 4)
        try assertSent(harness.transport, matches: "reg-outbound-session.hex")

        let info = try await harness.registrar.waitUntilRegistered()
        XCTAssertEqual(info.username, "n0call", "the REGACK echoes the USERNAME (§8.6.6)")
        XCTAssertEqual(info.refreshSeconds, 60, "REFRESH IE as received (§8.6.18)")
        XCTAssertEqual(info.validity, .seconds(60))
        XCTAssertEqual(
            info.dateTime,
            PackedDateTime(
                yearOffsetFrom2000: 26, month: 8, day: 9, hour: 12, minute: 34, second: 20),
            "DATETIME unpacks as 2026-08-09 12:34:20Z (§8.6.28)")

        await tearDown(harness)
    }

    /// A registrar may skip the challenge entirely — "the IAX protocol does
    /// permit servers to forego the challenge process" (§10) — and may omit
    /// REFRESH, in which case 60 s "MUST be assumed by both peers" (§6.1.1).
    func testUnchallengedRegistrationAssumesTheSixtySecondDefault() async throws {
        let harness = try await makeHarness()
        let regack = try fixture("reg-inbound-unchallenged.hex")[0]

        try await harness.registrar.register()
        await waitForSent(harness.transport, count: 1)
        harness.transport.inject(regack)
        await waitFor(harness.registrar, state: .registered)

        let info = try await harness.registrar.waitUntilRegistered()
        XCTAssertNil(info.refreshSeconds, "the REGACK carried no REFRESH IE")
        XCTAssertEqual(
            info.validity, .seconds(60),
            "60 s MUST be assumed when no REFRESH is sent (RFC 5456 §6.1.1, §6.1.4, §8.6.18)")

        // Two datagrams only: the REGREQ and the ACK the REGACK requires. No
        // MD5 RESULT was ever sent — "This information element MUST NOT be sent
        // except in response to a CHALLENGE." (§8.6.15)
        await waitForSent(harness.transport, count: 2)
        XCTAssertEqual(harness.transport.sentCount, 2)
        let elements = try Self.informationElements(of: harness.transport.sent[0])
        XCTAssertFalse(
            elements.contains { $0.id == 0x10 },
            "an unchallenged REGREQ must carry no MD5 RESULT (§8.6.15)")

        await tearDown(harness)
    }

    // MARK: - APPARENT ADDR (§8.6.17)

    /// The REGACK tells us how the node sees us, which is what makes
    /// registration useful behind NAT. Its address-family byte order is
    /// genuinely ambiguous, and both readings must remain available.
    func testApparentAddressIsSurfacedWithBothByteOrderReadings() async throws {
        let harness = try await makeHarness()
        try await completeRegistration(harness)

        let reported = await harness.registrar.apparentAddress
        let address = try XCTUnwrap(reported)
        XCTAssertEqual(
            address.port, 4569,
            "the port is unambiguously big-endian: only that reading makes the RFC's own "
                + "0x11d9 equal 4569 (§8.6.17)")
        XCTAssertEqual(address.addressBytes, [203, 0, 113, 9])
        XCTAssertEqual(address.ipv4TrailingPadding, Array(repeating: 0, count: 8))
        XCTAssertFalse(address.isIPv6Layout)

        // Trap 13: the RFC's own IPv4 example shows family 0x0200 beside port
        // 0x11d9 in the *same* structure. Read big-endian the family is 512;
        // read little-endian it is AF_INET = 2. RFC 5456 does not resolve it,
        // so neither does this code — both readings stay available and the
        // caller decides.
        XCTAssertEqual(address.familyBytes, [0x02, 0x00], "preserved exactly as it arrived")
        XCTAssertEqual(address.familyAsBigEndian, 512, "the big-endian reading — nonsense as AF_INET")
        XCTAssertEqual(
            address.familyAsLittleEndian, ApparentAddress.addressFamilyINET,
            "the little-endian reading — AF_INET, and the one the RFC's example implies")

        await tearDown(harness)
    }

    // MARK: - REGREJ (§6.1.5)

    /// "Upon receipt of a REGREJ message, the registrant MUST consider
    /// registration process unsuccessful." The CAUSE and CAUSECODE IEs §6.1.5
    /// requires are the only thing separating a wrong password from an unknown
    /// user, so they must reach the caller intact.
    func testRejectionSurfacesTheCause() async throws {
        let harness = try await makeHarness()
        let regrej = try fixture("reg-inbound-reject.hex")[0]

        try await harness.registrar.register()
        await waitForSent(harness.transport, count: 1)

        // Park the waiter *first*, and prove it is parked before delivering the
        // REGREJ — otherwise this would silently be testing the other ordering.
        let waiting = Task { try await harness.registrar.waitUntilRegistered() }
        await waitForParkedWaiter(harness.registrar)
        harness.transport.inject(regrej)

        do {
            _ = try await waiting.value
            XCTFail("waitUntilRegistered must not succeed after a REGREJ")
        } catch let error as IAX2RegistrationError {
            XCTAssertEqual(
                error,
                .rejected(cause: "Registration Refused", causeCode: 21),
                "the CAUSE (§8.6.21) and CAUSECODE (§8.6.33) travel out verbatim")
        }

        await waitFor(harness.registrar, state: .rejected)
        let failure = await harness.registrar.lastFailure
        XCTAssertEqual(failure, .rejected(cause: "Registration Refused", causeCode: 21))
        let registered = await harness.registrar.isRegistered
        XCTAssertFalse(registered)

        // The REGREJ is on the §6.9.1 MUST-ACK list, so the exchange ends with
        // our ACK and nothing else.
        await waitForSent(harness.transport, count: 2)
        try assertSent(harness.transport, matches: "reg-outbound-reject.hex")

        await tearDown(harness)
    }

    /// The other ordering, and the one that used to hang: the REGREJ is fully
    /// processed **before** anybody asks to wait. Nothing will ever resume a
    /// continuation parked now, so `waitUntilRegistered()` must not park one —
    /// it must report the failure that already happened.
    ///
    /// This reproduced in roughly half of whole-suite runs and never once when
    /// this class ran alone, which is precisely the signature plan rule 10
    /// describes.
    func testWaitUntilRegisteredDoesNotParkAfterTheAttemptHasAlreadyFailed() async throws {
        let harness = try await makeHarness()

        try await harness.registrar.register()
        await waitForSent(harness.transport, count: 1)
        harness.transport.inject(try fixture("reg-inbound-reject.hex")[0])
        await waitFor(harness.registrar, state: .rejected)

        let parked = await harness.registrar.parkedWaiterCount
        XCTAssertEqual(parked, 0, "precondition: nothing is waiting yet")

        do {
            _ = try await harness.registrar.waitUntilRegistered()
            XCTFail("there is no outcome coming; this must not have succeeded")
        } catch let error as IAX2RegistrationError {
            XCTAssertEqual(error, .rejected(cause: "Registration Refused", causeCode: 21))
        }

        await tearDown(harness)
    }

    // MARK: - Refresh (§6.1.1, §7.2.2)

    /// "It is the client's responsibility to renew this registration before the
    /// time period expires." (§7.2.2) The renewal must therefore fire strictly
    /// inside the validity period, on the injected clock.
    func testRefreshFiresBeforeExpiryAndReRegisters() async throws {
        let harness = try await makeHarness()
        try await completeRegistration(harness)
        await waitForSent(harness.transport, count: 4)

        // Three timers have slept in total: the retransmission ladder of each
        // of the two REGREQs (§7.2.1), and the refresh. Waiting on the
        // cumulative count guarantees the refresh timer has captured its
        // deadline against the *current* virtual time before we advance it.
        let armed3 = await harness.clock.waitUntilSleeping(count: 3)
        XCTAssertTrue(armed3, "the refresh timer captured its deadline before we advance time")

        // 0.8 × 60 s, with the injected jitter source pinned to 0. Just short
        // of that, nothing has happened.
        harness.clock.advance(by: .seconds(47))
        await assertNoFurtherSends(harness.transport, beyond: 4)

        harness.clock.advance(by: .seconds(1))
        await waitForSent(harness.transport, count: 5)

        let refreshed = try XCTUnwrap(IAX2Frame.parse(harness.transport.sent[4]).fullFrame)
        XCTAssertEqual(refreshed.iaxMessage, .regreq, "the refresh is a fresh REGREQ (§6.1.2)")
        XCTAssertEqual(refreshed.sourceCallNumber, localCallNumber)
        XCTAssertEqual(
            refreshed.destinationCallNumber, 0,
            "a refresh is its own exchange, so the registrar's call number is not yet known")
        XCTAssertEqual(refreshed.oSeqno, 0, "and its sequence numbers restart (§8.1.1)")
        XCTAssertEqual(refreshed.timestamp, 0, "as does its time-stamp origin (§8.1.1)")
        XCTAssertEqual(
            Self.hex(harness.transport.sent[4]), Self.hex(try fixture("reg-outbound-session.hex")[0]),
            "byte-for-byte the same REGREQ as the first registration")

        // 48 s is strictly inside the 60 s the registrar granted, which is the
        // whole point: the renewal must land before expiry, not on it.
        XCTAssertLessThan(Duration.seconds(48), Duration.seconds(60))

        // And it really re-registers.
        let inbound = try fixture("reg-inbound-session.hex")
        harness.transport.inject(inbound[0])
        await waitForSent(harness.transport, count: 7)
        harness.transport.inject(inbound[1])
        await waitFor(harness.registrar, state: .registered)

        await tearDown(harness)
    }

    /// The renewal delay is a fraction of the validity period minus a random
    /// slice (§7.2.2, "renewed at random intervals"), so it is always earlier
    /// than the plain fraction and always before expiry.
    func testRenewalJitterAlwaysLandsBeforeThePlainFraction() async throws {
        var configuration = IAX2Registrar.Configuration()
        configuration.renewalJitterFraction = 0.1
        let transport = MockTransport()
        let clock = ManualTestClock()
        let registrar = IAX2Registrar(
            sourceCallNumber: 1,
            request: IAX2RegistrationRequest(username: "n0call", secret: secret),
            transport: transport,
            clock: clock,
            configuration: configuration,
            // The top of the range: the largest jitter, i.e. the earliest
            // renewal. Anything larger than 0 must pull the delay in.
            randomUnitInterval: { 0.999 })

        // The task returns the value rather than writing to a captured `var`:
        // mutating one from inside a concurrently-executing closure is
        // rejected by older toolchains than this was written on, and nothing
        // here wanted shared state in the first place.
        let collector = Task { () -> Duration? in
            for await event in registrar.events {
                if case .refreshScheduled(let after, _) = event {
                    return after
                }
            }
            return nil
        }

        try await registrar.register()
        for _ in 0..<100_000 where transport.sentCount < 1 { await Task.yield() }
        transport.inject(try fixture("reg-inbound-unchallenged.hex")[0])
        _ = try await registrar.waitUntilRegistered()

        let scheduled = await collector.value
        let delay = try XCTUnwrap(scheduled)
        XCTAssertGreaterThan(delay, .seconds(41), "0.7 × 60 s is the floor with jitter 0.1")
        XCTAssertLessThan(delay, .seconds(48), "strictly earlier than the un-jittered 0.8 × 60 s")

        await registrar.close()
        clock.advance(by: .seconds(1))
        for _ in 0..<50 { await Task.yield() }
        transport.finish()
    }

    // MARK: - REGREL (§6.1.6, §9.4)

    /// Release is the registration exchange with REGREL in its place, challenge
    /// and all.
    func testReleaseUnregisters() async throws {
        let harness = try await makeHarness()
        try await completeRegistration(harness)
        await waitForSent(harness.transport, count: 4)
        harness.transport.clearSent()

        let inbound = try fixture("reg-inbound-release.hex")
        try await harness.registrar.unregister()
        await waitForSent(harness.transport, count: 1)
        harness.transport.inject(inbound[0])
        await waitForSent(harness.transport, count: 3)
        harness.transport.inject(inbound[1])
        await waitFor(harness.registrar, state: .unregistered)

        await waitForSent(harness.transport, count: 4)
        try assertSent(harness.transport, matches: "reg-outbound-release.hex")

        let registered = await harness.registrar.isRegistered
        XCTAssertFalse(registered)
        let info = await harness.registrar.registration
        XCTAssertNil(info, "the registration this released is gone")

        await tearDown(harness)
    }

    /// A waiter parked across a release must be woken by the release, not left
    /// on a registration that no longer exists — the same "nothing will ever
    /// resume this" hazard as the REGREJ case.
    func testAWaiterParkedAcrossAReleaseIsWoken() async throws {
        let harness = try await makeHarness()
        try await completeRegistration(harness)
        await waitForSent(harness.transport, count: 4)

        let inbound = try fixture("reg-inbound-release.hex")
        try await harness.registrar.unregister()
        await waitForSent(harness.transport, count: 5)

        let waiting = Task { try await harness.registrar.waitUntilRegistered() }
        await waitForParkedWaiter(harness.registrar)

        harness.transport.inject(inbound[0])
        await waitForSent(harness.transport, count: 7)
        harness.transport.inject(inbound[1])

        do {
            _ = try await waiting.value
            XCTFail("the registration was released; there is nothing to hand back")
        } catch let error as IAX2RegistrationError {
            XCTAssertEqual(
                error, .illegalState(.unregistered, attempted: "waitUntilRegistered"))
        }

        await tearDown(harness)
    }

    /// There is nothing to release before a REGACK has granted anything.
    func testUnregisterWithoutARegistrationThrows() async throws {
        let harness = try await makeHarness()
        do {
            try await harness.registrar.unregister()
            XCTFail("unregister must not send a REGREL for a registration we never had")
        } catch let error as IAX2RegistrationError {
            XCTAssertEqual(error, .illegalState(.unregistered, attempted: "unregister"))
        }
        XCTAssertEqual(harness.transport.sentCount, 0)
        await tearDown(harness)
    }

    // MARK: - Backoff (§6.1.5 plus local policy)

    /// A node that is refusing us must be backed away from, not hammered. The
    /// ladder is local policy — §6.1.5 settles only that the *current* exchange
    /// stops — and it must double.
    func testRetryBacksOffRatherThanHammering() async throws {
        var configuration = IAX2Registrar.Configuration()
        configuration.retry = IAX2Registrar.RetryPolicy(
            initialInterval: .seconds(5), maximumInterval: .seconds(300))
        let harness = try await makeHarness(configuration: configuration)
        let regrej = try fixture("reg-inbound-reject.hex")[0]

        try await harness.registrar.register()
        await waitForSent(harness.transport, count: 1)
        harness.transport.inject(regrej)
        await waitFor(harness.registrar, state: .rejected)
        await waitForSent(harness.transport, count: 2)

        // One retransmission timer (the REGREQ's) and the retry timer.
        let armed2 = await harness.clock.waitUntilSleeping(count: 2)
        XCTAssertTrue(armed2, "the backoff timer captured its deadline before we advance time")

        // Four seconds into a five-second backoff: still nothing on the wire.
        harness.clock.advance(by: .seconds(4))
        await assertNoFurtherSends(harness.transport, beyond: 2)

        harness.clock.advance(by: .seconds(1))
        await waitForSent(harness.transport, count: 3)
        let retry = try XCTUnwrap(IAX2Frame.parse(harness.transport.sent[2]).fullFrame)
        XCTAssertEqual(retry.iaxMessage, .regreq)

        // Second failure: the interval must double, not repeat.
        harness.transport.inject(regrej)
        await waitForSent(harness.transport, count: 4)
        let armed4 = await harness.clock.waitUntilSleeping(count: 4)
        XCTAssertTrue(armed4, "the second backoff timer is armed")
        harness.clock.advance(by: .seconds(9))
        await assertNoFurtherSends(harness.transport, beyond: 4)
        harness.clock.advance(by: .seconds(1))
        await waitForSent(harness.transport, count: 5)

        let failures = await harness.registrar.consecutiveFailures
        XCTAssertEqual(failures, 2, "two rejections, two rungs of the ladder")

        await tearDown(harness)
    }

    /// With retrying disabled, one REGREJ is the end of it — the §6.1.5
    /// reading taken literally, for a caller that wants to decide for itself.
    func testRetryCanBeDisabledEntirely() async throws {
        var configuration = IAX2Registrar.Configuration()
        configuration.retry = .none
        let harness = try await makeHarness(configuration: configuration)

        let collector = Task { () -> IAX2RegistrationError? in
            for await event in harness.registrar.events {
                if case .gaveUp(let error) = event {
                    return error
                }
            }
            return nil
        }

        try await harness.registrar.register()
        await waitForSent(harness.transport, count: 1)
        harness.transport.inject(try fixture("reg-inbound-reject.hex")[0])
        await waitFor(harness.registrar, state: .rejected)
        let gaveUp = await collector.value

        XCTAssertEqual(gaveUp, .rejected(cause: "Registration Refused", causeCode: 21))
        harness.clock.advance(by: .seconds(3600))
        await assertNoFurtherSends(harness.transport, beyond: 2)

        await tearDown(harness)
    }

    /// A REGAUTH offering only RSA cannot be answered: there is no plaintext
    /// path (§8.6.13, §10) and RSA is out of scope for v1.
    func testRegauthOfferingOnlyRSAFails() async throws {
        let harness = try await makeHarness()
        let regauth = Self.fullFrame(
            source: peerCallNumber, destination: localCallNumber, timestamp: 50,
            oSeqno: 0, iSeqno: 1, message: .regauth,
            elements: [
                .username("n0call"),
                // 0x0004 = RSA only (§8.6.13).
                .authMethods(IEAuthMethods(rawValue: 0x0004)),
                .challenge("1234567890"),
            ])

        try await harness.registrar.register()
        await waitForSent(harness.transport, count: 1)
        harness.transport.inject(regauth)
        await waitFor(harness.registrar, state: .rejected)

        let failure = await harness.registrar.lastFailure
        XCTAssertEqual(
            failure, .unsupportedAuthentication(offered: IAX2Auth.AuthMethods(rawValue: 0x0004)))

        await tearDown(harness)
    }

    /// A REGAUTH without the CHALLENGE IE §6.1.3 requires cannot be answered
    /// either, and must fail visibly rather than producing a digest of nothing.
    func testRegauthWithoutAChallengeFails() async throws {
        let harness = try await makeHarness()
        let regauth = Self.fullFrame(
            source: peerCallNumber, destination: localCallNumber, timestamp: 50,
            oSeqno: 0, iSeqno: 1, message: .regauth,
            elements: [.username("n0call"), .authMethods(.md5)])

        try await harness.registrar.register()
        await waitForSent(harness.transport, count: 1)
        harness.transport.inject(regauth)
        await waitFor(harness.registrar, state: .rejected)

        let failure = await harness.registrar.lastFailure
        XCTAssertEqual(failure, .missingChallenge)

        await tearDown(harness)
    }

    /// A REGAUTH with no secret configured is a configuration error, not a
    /// wire error, and is reported as such.
    func testRegauthWithoutAConfiguredSecretFails() async throws {
        let harness = try await makeHarness(
            request: IAX2RegistrationRequest(username: "n0call", secret: nil))
        try await harness.registrar.register()
        await waitForSent(harness.transport, count: 1)
        harness.transport.inject(try fixture("reg-inbound-session.hex")[0])
        await waitFor(harness.registrar, state: .rejected)

        let failure = await harness.registrar.lastFailure
        XCTAssertEqual(failure, .missingSecret)

        await tearDown(harness)
    }

    // MARK: - The multiplexing seam (for IAX2Client)

    /// `deliver(datagram:)` returns `false` for anything not addressed to the
    /// registration's call-number pair, so a client can offer each datagram to
    /// the registrar and fall through to the call leg. It must never answer a
    /// frame it does not own — an INVAL there would tear down somebody else's
    /// call (§6.9.2).
    func testDeliverDeclinesDatagramsAddressedElsewhere() async throws {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let registrar = IAX2Registrar(
            sourceCallNumber: 1,
            request: IAX2RegistrationRequest(username: "n0call", secret: secret),
            transport: transport,
            clock: clock,
            // The IAX2Client wiring: the client owns the single-consumer read
            // loop and drives the registrar through `deliver`.
            readsTransport: false,
            randomUnitInterval: { 0 })

        try await registrar.register()
        XCTAssertEqual(transport.sentCount, 1, "the REGREQ went out without a read loop")

        // Addressed to call number 9, not ours.
        let foreign = Self.fullFrame(
            source: peerCallNumber, destination: 9, timestamp: 50,
            oSeqno: 0, iSeqno: 1, message: .regauth, elements: [.challenge("x")])
        let consumedForeign = await registrar.deliver(datagram: foreign)
        XCTAssertFalse(consumedForeign, "not ours: the client must try the call leg next")
        XCTAssertEqual(transport.sentCount, 1, "and nothing was sent in reply")

        // A mini frame can never belong to a registration: registration has no
        // media, and a mini frame carries no destination call number (§8.1.2).
        let mini = IAX2Frame.mini(
            IAX2MiniFrame(sourceCallNumber: peerCallNumber, timestamp: 0, payload: [0xFF]))
        let consumedMini = await registrar.deliver(datagram: mini.encoded())
        XCTAssertFalse(consumedMini)

        // Ours: consumed, and driven to completion through `deliver` alone.
        let inbound = try fixture("reg-inbound-session.hex")
        let consumedRegauth = await registrar.deliver(datagram: inbound[0])
        XCTAssertTrue(consumedRegauth)
        await waitForSent(transport, count: 3)
        let consumedRegack = await registrar.deliver(datagram: inbound[1])
        XCTAssertTrue(consumedRegack)
        await waitFor(registrar, state: .registered)
        try assertSent(transport, matches: "reg-outbound-session.hex")

        await registrar.close()
        clock.advance(by: .seconds(1))
        for _ in 0..<50 { await Task.yield() }
        transport.finish()
    }

    /// `close()` finishes the event stream and gives the call number back, so a
    /// client that registers and unregisters repeatedly does not exhaust the
    /// 1…32767 space (§8.1.1).
    func testCloseFinishesEventsAndReleasesTheCallNumber() async throws {
        let harness = try await makeHarness()
        try await completeRegistration(harness)

        let drained = Task {
            var count = 0
            for await _ in harness.registrar.events { count += 1 }
            return count
        }

        await harness.registrar.close()
        let events = await drained.value
        XCTAssertGreaterThan(events, 0, "the stream finished rather than hanging")

        let allocated = await harness.allocator.allocatedCount
        XCTAssertEqual(allocated, 0, "the source call number went back to the pool")

        do {
            try await harness.registrar.register()
            XCTFail("a closed registrar must not be reusable")
        } catch let error as IAX2RegistrationError {
            XCTAssertEqual(error, .closed)
        }

        harness.clock.advance(by: .seconds(1))
        for _ in 0..<50 { await Task.yield() }
        harness.transport.finish()
    }

    // MARK: - Plan rule 10

    /// **The reentrancy test.** The REGAUTH is delivered from *inside* the
    /// REGREQ's own `transport.send`, which is the ordering a fast node on a
    /// local network genuinely produces and which a test that only exercises
    /// the common ordering will never find.
    ///
    /// Two things have to hold:
    ///
    /// 1. The exchange still completes — the reply must not arrive at a state
    ///    that rejects it, and `waitUntilRegistered()` must not park a
    ///    continuation *after* the outcome it was waiting for has been
    ///    delivered. (That is the M17-3 hang, verbatim, in a new place.)
    /// 2. The credentialed REGREQ must still carry OSeqno 1. A
    ///    `ReliableChannel` assigns the sequence number before awaiting the
    ///    write and advances it after, so answering the REGAUTH from inside the
    ///    write would have produced a second frame with OSeqno 0. The
    ///    registrar defers the re-send until the write completes precisely to
    ///    prevent that.
    ///
    /// The ACK of the REGAUTH is deliberately *not* asserted byte-for-byte
    /// here: it is generated inside `ReliableChannel.receive` while our REGREQ
    /// is still mid-write, so it carries the pre-increment OSeqno. That is the
    /// channel's business, not the registrar's, and it is harmless — an ACK "is
    /// one of the five messages that do not change the message count" (§7) and
    /// is matched by its echoed time-stamp, not its sequence number (§6.9.1).
    func testRegistrationCompletesWhenRegauthArrivesDuringTheRegreqSend() async throws {
        let inbound = try fixture("reg-inbound-session.hex")
        let expected = try fixture("reg-outbound-session.hex")
        let transport = ReplyDuringSendTransport(replies: [1: [inbound[0]]])
        let clock = ManualTestClock()
        let allocator = IAX2CallNumberAllocator()
        let registrar = try await IAX2Registrar.outbound(
            allocator: allocator,
            request: IAX2RegistrationRequest(username: "n0call", secret: secret),
            transport: transport,
            clock: clock,
            randomUnitInterval: { 0 })

        try await registrar.register()

        // The REGREQ, the ACK of the REGAUTH, and the credentialed REGREQ have
        // all gone out before `register()` returned — the whole exchange up to
        // the REGACK happened inside one `transport.send`.
        for _ in 0..<100_000 where transport.sentCount < 3 { await Task.yield() }
        XCTAssertEqual(transport.sentCount, 3)

        let credentialed = try XCTUnwrap(IAX2Frame.parse(transport.sent[2]).fullFrame)
        XCTAssertEqual(credentialed.iaxMessage, .regreq)
        XCTAssertEqual(
            credentialed.oSeqno, 1,
            "the credentialed REGREQ waited for the first REGREQ's write to finish, so the "
                + "channel had already advanced OSeqno (plan rule 10)")
        XCTAssertEqual(
            Self.hex(transport.sent[2]), Self.hex(expected[2]),
            "and it is byte-for-byte the frame the ordinary ordering produces")

        // Now the REGACK, and the wait that must not hang.
        transport.inject(inbound[1])
        let info = try await registrar.waitUntilRegistered()
        XCTAssertEqual(info.username, "n0call")
        let state = await registrar.state
        XCTAssertEqual(state, .registered)
        let failure = await registrar.lastFailure
        XCTAssertNil(failure, "the reply arriving early is not a protocol error")

        await registrar.close()
        clock.advance(by: .seconds(1))
        for _ in 0..<50 { await Task.yield() }
        await transport.close()
    }

    /// The same hazard from the other side: the REGACK delivered from inside
    /// the *credentialed* REGREQ's send, with `waitUntilRegistered()` already
    /// parked. The continuation must be resumed by the completion that arrives
    /// during the awaited call, not left waiting forever.
    func testWaitUntilRegisteredReturnsWhenRegackArrivesDuringTheCredentialedSend() async throws {
        let inbound = try fixture("reg-inbound-session.hex")
        // Reply on send #1 with the REGAUTH and on send #3 (the credentialed
        // REGREQ; send #2 is the ACK of the REGAUTH) with the REGACK.
        let transport = ReplyDuringSendTransport(replies: [1: [inbound[0]], 3: [inbound[1]]])
        let clock = ManualTestClock()
        let registrar = IAX2Registrar(
            sourceCallNumber: 1,
            request: IAX2RegistrationRequest(username: "n0call", secret: secret),
            transport: transport,
            clock: clock,
            randomUnitInterval: { 0 })

        try await registrar.register()
        let info = try await registrar.waitUntilRegistered()
        XCTAssertEqual(info.validity, .seconds(60))
        let state = await registrar.state
        XCTAssertEqual(state, .registered)

        await registrar.close()
        clock.advance(by: .seconds(1))
        for _ in 0..<50 { await Task.yield() }
        await transport.close()
    }

    // MARK: - Frame-building helpers

    /// Builds an inbound full frame for the cases where a hand-written fixture
    /// would say less than the code that builds it — a REGAUTH offering only
    /// RSA, say, which exists to exercise one IE value.
    private static func fullFrame(
        source: UInt16,
        destination: UInt16,
        timestamp: UInt32,
        oSeqno: UInt8,
        iSeqno: UInt8,
        message: IAX2Message,
        elements: [InformationElement]
    ) -> Data {
        let payload = (try? InformationElement.serialize(elements)) ?? []
        return IAX2Frame.full(
            IAX2FullFrame(
                sourceCallNumber: source,
                destinationCallNumber: destination,
                timestamp: timestamp,
                oSeqno: oSeqno,
                iSeqno: iSeqno,
                type: .iax,
                subclass: IAX2Subclass(message),
                payload: payload)
        ).encoded()
    }

    private static func informationElements(of datagram: Data) throws -> [InformationElement] {
        let frame = try XCTUnwrap(IAX2Frame.parse(datagram).fullFrame)
        return try InformationElement.parseList(frame.payload)
    }
}

// MARK: - Rule-10 transport

/// Delivers canned datagrams to `incoming` from *inside* `send`, keyed by the
/// 1-based index of the send they should accompany, then yields so the receive
/// loop processes them before `send` returns. See plan rule 10 and
/// `IAX2CallTests.CallReplyDuringSendTransport`, of which this is the
/// registration-shaped sibling.
private final class ReplyDuringSendTransport: DatagramTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let replies: [Int: [Data]]
    private let lock = NSLock()
    private var sentDatagrams: [Data] = []

    var sent: [Data] { lock.withLock { sentDatagrams } }
    var sentCount: Int { lock.withLock { sentDatagrams.count } }

    init(replies: [Int: [Data]]) {
        self.replies = replies
        var escaped: AsyncStream<Data>.Continuation!
        incoming = AsyncStream<Data>(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
    }

    func inject(_ datagram: Data) {
        continuation.yield(datagram)
    }

    func send(_ datagram: Data) async throws {
        let index: Int = lock.withLock {
            sentDatagrams.append(datagram)
            return sentDatagrams.count
        }
        guard let reply = replies[index] else { return }
        for datagram in reply { continuation.yield(datagram) }
        for _ in 0..<500 { await Task.yield() }
    }

    func close() async {
        continuation.finish()
    }
}
