// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import TestSupport
import XCTest

@testable import IAX2Kit

// MARK: - Manual clock

/// A manually-driven `Clock`, so retransmission backoff is exercised without a
/// single real-time wait. Same pattern as `TransmitWatchdogTests`: `advance(by:)`
/// moves virtual time forward and resumes any sleeper whose deadline has been
/// reached.
///
/// The synchronisation primitive is `waitUntilSleepers(_:)`, which waits for a
/// given number of timers to be *registered* — i.e. to have entered `sleep` and
/// captured a deadline against the current `now`. Advancing time before that
/// point would compute the deadline against an already-advanced clock and the
/// timer would never fire, which is exactly the flakiness this avoids. It counts
/// live waiters rather than `sleep` calls because a channel that has retired
/// hundreds of frames has hundreds of cancelled timer tasks behind it, and a
/// call *count* would never settle.
///
/// Because `ReliableChannel` hands the retransmitted copy to the transport
/// *before* re-arming its timer, "the timer is armed again" is also the
/// deterministic signal that the retransmission has already been sent.
private final class ManualTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        fileprivate var offset: Swift.Duration

        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        static func == (lhs: Instant, rhs: Instant) -> Bool { lhs.offset == rhs.offset }

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }
    }

    typealias Duration = Swift.Duration

    private struct Waiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum Registration {
        case due
        case cancelled
        case registered
    }

    private let lock = NSLock()
    private var offset: Swift.Duration = .zero
    private var waiters: [UUID: Waiter] = [:]

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var now: Instant { Instant(offset: withLock { offset }) }

    var minimumResolution: Swift.Duration { .zero }

    /// Timers currently asleep on a live deadline.
    var sleeperCount: Int { withLock { waiters.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        if Task.isCancelled { throw CancellationError() }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                // The cancellation check happens under the same lock as
                // registration so a waiter can never be registered after its
                // cancellation handler has already run — that would leave a
                // sleeper nothing will ever resume.
                let registration: Registration = withLock {
                    if Task.isCancelled { return .cancelled }
                    if offset >= deadline.offset { return .due }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return .registered
                }
                switch registration {
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .registered: break
                }
            }
        } onCancel: {
            let waiter = withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Advances virtual time and resumes every sleeper now due.
    func advance(by duration: Swift.Duration) {
        let ready: [Waiter] = withLock {
            offset += duration
            let due = waiters.filter { $0.value.deadline.offset <= offset }
            for key in due.keys { waiters.removeValue(forKey: key) }
            return Array(due.values)
        }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Polls — by cooperative yielding, never real time — until exactly `count`
    /// timers are asleep on a live deadline. Returns `false` if that never
    /// happens within a purely scheduling-bound number of attempts, which would
    /// indicate a real bug rather than slowness.
    func waitUntilSleepers(_ count: Int, maxAttempts: Int = 100_000) async -> Bool {
        for _ in 0..<maxAttempts {
            if sleeperCount == count { return true }
            await Task.yield()
        }
        return false
    }
}

// MARK: - Tests

final class ReliableChannelTests: XCTestCase {

    /// Our 15-bit source call number; the peer's is `peerCallNumber` (§8.1.1).
    private let localCallNumber: UInt16 = 0x0123
    private let peerCallNumber: UInt16 = 0x0456

    // MARK: Helpers

    private struct Harness {
        let channel: ReliableChannel
        let transport: MockTransport
        let clock: ManualTestClock
    }

    private func makeHarness(
        configuration: ReliableChannel.Configuration = ReliableChannel.Configuration()
    ) -> Harness {
        let transport = MockTransport()
        let clock = ManualTestClock()
        let channel = ReliableChannel(
            sourceCallNumber: localCallNumber,
            destinationCallNumber: peerCallNumber,
            transport: transport,
            clock: clock,
            configuration: configuration)
        return Harness(channel: channel, transport: transport, clock: clock)
    }

    /// A full frame as if sent by the peer.
    private func peerFrame(
        _ message: IAX2Message,
        timestamp: UInt32,
        oSeqno: UInt8,
        iSeqno: UInt8
    ) -> IAX2FullFrame {
        IAX2FullFrame(
            sourceCallNumber: peerCallNumber,
            destinationCallNumber: localCallNumber,
            timestamp: timestamp,
            oSeqno: oSeqno,
            iSeqno: iSeqno,
            type: .iax,
            subclass: IAX2Subclass(message))
    }

    /// Parses one datagram `MockTransport` captured back into a full frame.
    private func sentFullFrame(
        _ transport: MockTransport,
        _ index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IAX2FullFrame {
        let datagrams = transport.sent
        let datagram = try XCTUnwrap(
            datagrams.indices.contains(index) ? datagrams[index] : nil,
            "no datagram at index \(index); \(datagrams.count) were sent",
            file: file, line: line)
        return try XCTUnwrap(IAX2Frame.parse(datagram).fullFrame, file: file, line: line)
    }

    /// Gives any *incorrect* extra work a fair chance to happen before a
    /// negative assertion, without touching the wall clock.
    private func settle(_ iterations: Int = 50) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    /// Waits for exactly `count` retransmission timers to be armed against the
    /// clock's current `now`, then asserts it happened. Every `advance(by:)` in
    /// this file is preceded by one of these, which is what makes the timing
    /// assertions deterministic instead of racy.
    private func expectSleepers(
        _ count: Int,
        _ clock: ManualTestClock,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let armed = await clock.waitUntilSleepers(count)
        XCTAssertTrue(
            armed,
            "expected \(count) armed timer(s), found \(clock.sleeperCount)"
                + (message.isEmpty ? "" : " — \(message)"),
            file: file, line: line)
    }

    private func expectDead(
        _ channel: ReliableChannel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var isDead = false
        for _ in 0..<100_000 {
            if await channel.isDead {
                isDead = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(isDead, "the channel never tore the call leg down", file: file, line: line)
    }

    private func collectEvents(_ channel: ReliableChannel) async -> [ReliableChannel.Event] {
        var events: [ReliableChannel.Event] = []
        for await event in channel.events { events.append(event) }
        return events
    }

    // MARK: Initial state (§7, §6.2.2)

    func testCountersStartAtZero() async throws {
        let harness = makeHarness()
        var oSeqno = await harness.channel.outboundSequenceNumber
        var iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(oSeqno, 0, "\"the outgoing and incoming message sequence numbers MUST both be set to zero\" (§7)")
        XCTAssertEqual(iSeqno, 0)

        // The very first frame carries OSeqno = 0, ISeqno = 0; OSeqno becomes 1
        // for the next reliable frame (§6.2.2, notes §9).
        let frame = try await harness.channel.send(.new, timestamp: 0)
        XCTAssertEqual(frame.oSeqno, 0)
        XCTAssertEqual(frame.iSeqno, 0)
        XCTAssertFalse(frame.isRetransmission)

        oSeqno = await harness.channel.outboundSequenceNumber
        iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(oSeqno, 1)
        XCTAssertEqual(iSeqno, 0)

        let wire = try sentFullFrame(harness.transport, 0)
        XCTAssertEqual(wire, frame, "the wire copy must be exactly what send() reported")
        await harness.channel.close()
    }

    // MARK: OSeqno increments and the five exemptions (§7)

    func testNormalFramesIncrementOSeqno() async throws {
        let harness = makeHarness()
        for expected in UInt8(0)...UInt8(4) {
            let frame = try await harness.channel.send(.ping, timestamp: UInt32(expected) * 20)
            XCTAssertEqual(frame.oSeqno, expected)
        }
        let oSeqno = await harness.channel.outboundSequenceNumber
        XCTAssertEqual(oSeqno, 5)
        await harness.channel.close()
    }

    /// "Each reliable message that is sent increments the message count by one
    /// except the ACK, INVAL, TXCNT, TXACC, and VNAK messages, which do not
    /// change the message count." (§7)
    func testTheFiveExemptMessagesDoNotIncrementOSeqno() async throws {
        XCTAssertEqual(
            IAX2Message.sequenceNumberExempt, [.ack, .inval, .txcnt, .txacc, .vnak],
            "the §7 exemption set must not drift")

        for message in [IAX2Message.ack, .inval, .txcnt, .txacc, .vnak] {
            let harness = makeHarness()

            // One normal frame first, so a counter that wrongly advanced would
            // be visible rather than hidden at zero.
            _ = try await harness.channel.send(.new, timestamp: 10)
            var oSeqno = await harness.channel.outboundSequenceNumber
            XCTAssertEqual(oSeqno, 1, "\(message) case setup")

            let exempt = try await harness.channel.send(message, timestamp: 20)
            XCTAssertEqual(exempt.oSeqno, 1, "\(message) must carry the unchanged OSeqno")
            oSeqno = await harness.channel.outboundSequenceNumber
            XCTAssertEqual(oSeqno, 1, "\(message) must not advance OSeqno (§7)")

            // Nor is it retransmitted: an ACK for an ACK could never terminate,
            // and an exempt message consumes no sequence number to match on.
            let outstandingCount = await harness.channel.outstandingFrameCount
            XCTAssertEqual(outstandingCount, 1, "\(message) must not be tracked for retransmission")

            // The next normal frame reuses the sequence number the exempt
            // message borrowed.
            let next = try await harness.channel.send(.ping, timestamp: 30)
            XCTAssertEqual(next.oSeqno, 1, "\(message) must not have consumed a sequence number")

            await harness.channel.close()
        }
    }

    // MARK: ACK retires an outstanding frame (§6.9.1)

    func testAckRetiresOutstandingFrameAndStopsRetransmission() async throws {
        let harness = makeHarness()
        let frame = try await harness.channel.send(.new, timestamp: 1234)
        await expectSleepers(1, harness.clock, "timer never armed")

        var outstandingCount = await harness.channel.outstandingFrameCount
        XCTAssertEqual(outstandingCount, 1)

        // An ACK echoes the acknowledged frame's time-stamp (§6.9.1) and does
        // not change its own sequence counters.
        let ack = peerFrame(.ack, timestamp: 1234, oSeqno: 0, iSeqno: frame.oSeqno &+ 1)
        let disposition = await harness.channel.receive(.full(ack))
        XCTAssertEqual(disposition, .consumed(ack))

        outstandingCount = await harness.channel.outstandingFrameCount
        XCTAssertEqual(outstandingCount, 0)

        // Far past every backoff deadline: nothing more may go out. Receiving
        // an ACK also requires no reply ("Receipt of an ACK requires no
        // action", §6.9.1), so the datagram count stays at the original send.
        harness.clock.advance(by: .seconds(60))
        await settle()
        XCTAssertEqual(harness.transport.sentCount, 1)

        let isDead = await harness.channel.isDead
        XCTAssertFalse(isDead)

        // close() finishes the event stream, so this iteration terminates.
        await harness.channel.close()
        let events = await collectEvents(harness.channel)
        XCTAssertEqual(events, [.acknowledged(oSeqno: frame.oSeqno, timestamp: 1234)])
    }

    /// An inbound ACK does not advance our expected inbound counter — the peer's
    /// OSeqno did not advance when it sent it (§7), so treating it as consuming
    /// a sequence number would make the peer's next real frame look duplicate.
    func testInboundAckDoesNotAdvanceISeqnoAndIsNotItselfAcked() async throws {
        let harness = makeHarness()
        _ = try await harness.channel.send(.new, timestamp: 500)
        harness.transport.clearSent()

        let ack = peerFrame(.ack, timestamp: 500, oSeqno: 0, iSeqno: 1)
        _ = await harness.channel.receive(.full(ack))

        let iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(iSeqno, 0, "an inbound ACK must not advance ISeqno (§7)")
        XCTAssertEqual(harness.transport.sentCount, 0, "ACKing an ACK would never terminate")
        await harness.channel.close()
    }

    // MARK: Retransmission backoff (§7, §7.2.1, §8.1.1)

    func testMissingAckRetransmitsWithRBitAtFiveHundredMillisecondsDoubling() async throws {
        let harness = makeHarness()
        let original = try await harness.channel.send(.new, timestamp: 4242)
        XCTAssertEqual(harness.transport.sentCount, 1)
        await expectSleepers(1, harness.clock)

        let backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4)]
        for (index, interval) in backoff.enumerated() {
            // One millisecond short of the deadline: still silent.
            harness.clock.advance(by: interval - .milliseconds(1))
            await settle()
            XCTAssertEqual(
                harness.transport.sentCount, index + 1,
                "retransmission \(index + 1) fired before its deadline")

            harness.clock.advance(by: .milliseconds(1))
            await expectSleepers(1, harness.clock, "retransmission \(index + 1) never happened")
            XCTAssertEqual(harness.transport.sentCount, index + 2)

            // "Everything else in the frame — including OSeqno and the
            // time-stamp — is retransmitted unchanged" (§8.1.1, notes §10).
            let copy = try sentFullFrame(harness.transport, index + 1)
            XCTAssertTrue(copy.isRetransmission, "the R bit must be set on a retransmission")
            XCTAssertEqual(copy.oSeqno, original.oSeqno)
            XCTAssertEqual(copy.iSeqno, original.iSeqno)
            XCTAssertEqual(copy.timestamp, original.timestamp)
            XCTAssertEqual(copy.type, original.type)
            XCTAssertEqual(copy.subclass, original.subclass)
            XCTAssertEqual(copy.payload, original.payload)

            let attempts = await harness.channel.retransmissionCount(
                for: ReliableChannel.AcknowledgementKey(
                    oSeqno: original.oSeqno, timestamp: original.timestamp))
            XCTAssertEqual(attempts, index + 1)
        }

        // The default retry limit is 4, so no fifth retransmission exists — the
        // next deadline tears the call down instead.
        let isDeadYet = await harness.channel.isDead
        XCTAssertFalse(isDeadYet, "the call must survive until the retry limit is exceeded")
        harness.clock.advance(by: .seconds(8))
        await expectDead(harness.channel)
        XCTAssertEqual(harness.transport.sentCount, 5, "4 retries plus the original, and no more")
    }

    /// Exhausting the retries must surface an error and, per §7 and §6.6, must
    /// **not** send a HANGUP to a peer that has stopped answering.
    func testRetryExhaustionSurfacesErrorAndSendsNoHangup() async throws {
        let harness = makeHarness()
        let original = try await harness.channel.send(.new, timestamp: 77)
        await expectSleepers(1, harness.clock)

        // 500 ms, 1 s, 2 s, 4 s, then an 8 s deadline that no retry answers.
        let deadlines: [Duration] = [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
        ]
        for (index, interval) in deadlines.enumerated() {
            harness.clock.advance(by: interval)
            if index < 4 {
                await expectSleepers(1, harness.clock)
            }
        }
        await expectDead(harness.channel)

        let failure = await harness.channel.failure
        XCTAssertEqual(
            failure,
            .retriesExhausted(oSeqno: original.oSeqno, timestamp: original.timestamp, attempts: 4))

        // The exact datagrams: the original, then four retransmissions of the
        // same frame, and nothing else. In particular no HANGUP (§6.6).
        let datagrams = harness.transport.sent
        XCTAssertEqual(datagrams.count, 5)
        for index in 0..<5 {
            let frame = try sentFullFrame(harness.transport, index)
            XCTAssertEqual(frame.iaxMessage, .new)
            XCTAssertEqual(frame.oSeqno, original.oSeqno)
            XCTAssertEqual(frame.timestamp, original.timestamp)
            XCTAssertEqual(frame.isRetransmission, index > 0)
            XCTAssertNotEqual(frame.iaxMessage, .hangup)
        }

        // The events stream finishes on teardown, so this iteration terminates.
        let events = await collectEvents(harness.channel)
        let retransmissions = events.filter {
            if case .retransmitted = $0 { return true }
            return false
        }
        XCTAssertEqual(retransmissions.count, 4)
        XCTAssertEqual(
            events.last,
            .failed(
                .retriesExhausted(
                    oSeqno: original.oSeqno, timestamp: original.timestamp, attempts: 4)))

        // A dead channel refuses further sends and stays silent.
        do {
            _ = try await harness.channel.send(.hangup, timestamp: 99)
            XCTFail("a dead channel must refuse to send")
        } catch let error as ReliableChannelError {
            XCTAssertEqual(error, .channelDead)
        }
        XCTAssertEqual(harness.transport.sentCount, 5)
    }

    func testRetryLimitIsConfigurable() async throws {
        let harness = makeHarness(
            configuration: ReliableChannel.Configuration(
                initialRetryInterval: .milliseconds(100), maximumRetries: 1))
        _ = try await harness.channel.send(.ping, timestamp: 1)
        await expectSleepers(1, harness.clock)

        harness.clock.advance(by: .milliseconds(100))
        await expectSleepers(1, harness.clock)
        XCTAssertEqual(harness.transport.sentCount, 2)

        harness.clock.advance(by: .milliseconds(200))
        await expectDead(harness.channel)
        XCTAssertEqual(harness.transport.sentCount, 2)
    }

    // MARK: ACK matching is by echoed time-stamp (§6.9.1)

    func testAckWithMismatchedTimestampDoesNotRetireTheFrame() async throws {
        let harness = makeHarness()
        let frame = try await harness.channel.send(.new, timestamp: 1000)
        await expectSleepers(1, harness.clock)

        // Right sequence numbers, wrong echoed time-stamp. §6.9.1 makes the
        // time-stamp the identifier, so this ACK names no frame we sent.
        let stray = peerFrame(.ack, timestamp: 9999, oSeqno: 0, iSeqno: frame.oSeqno &+ 1)
        _ = await harness.channel.receive(.full(stray))

        let outstandingCount = await harness.channel.outstandingFrameCount
        XCTAssertEqual(outstandingCount, 1, "a mismatched time-stamp must not retire a frame")

        // Proof it is still armed: the 500 ms deadline still retransmits.
        harness.clock.advance(by: .milliseconds(500))
        await expectSleepers(1, harness.clock)
        XCTAssertEqual(harness.transport.sentCount, 2)
        let copy = try sentFullFrame(harness.transport, 1)
        XCTAssertTrue(copy.isRetransmission)
        await harness.channel.close()
    }

    func testAckRetiresOnlyTheFrameWhoseTimestampItEchoes() async throws {
        let harness = makeHarness()
        let first = try await harness.channel.send(.new, timestamp: 100)
        let second = try await harness.channel.send(.ping, timestamp: 200)
        await expectSleepers(2, harness.clock)

        // ACK the *older* frame. Acknowledgement is cumulative (§7), so this
        // retires the first and leaves the second in flight — an ACK naming an
        // older frame must never retire a newer one.
        let ack = peerFrame(.ack, timestamp: 100, oSeqno: 0, iSeqno: first.oSeqno &+ 1)
        _ = await harness.channel.receive(.full(ack))

        let remaining = await harness.channel.outstandingFrames
        XCTAssertEqual(remaining.map(\.oSeqno), [second.oSeqno])
        XCTAssertEqual(remaining.map(\.timestamp), [200])

        // The survivor is still on its own timer.
        harness.clock.advance(by: .milliseconds(500))
        await expectSleepers(1, harness.clock)
        let copy = try sentFullFrame(harness.transport, 2)
        XCTAssertTrue(copy.isRetransmission)
        XCTAssertEqual(copy.oSeqno, second.oSeqno)
        XCTAssertEqual(copy.timestamp, 200)
        await harness.channel.close()
    }

    /// Any non-ACK inbound full frame acknowledges cumulatively through its
    /// ISeqno (§7) — "the incoming message counter MUST be used to acknowledge
    /// all the messages up to that sequence number that have been sent."
    func testInboundISeqnoAcknowledgesCumulatively() async throws {
        let harness = makeHarness()
        _ = try await harness.channel.send(.new, timestamp: 100)  // OSeqno 0
        _ = try await harness.channel.send(.ping, timestamp: 200)  // OSeqno 1
        let third = try await harness.channel.send(.ping, timestamp: 300)  // OSeqno 2
        await expectSleepers(3, harness.clock)

        // ACCEPT with ISeqno 2: the peer has seen our OSeqno 0 and 1.
        let accept = peerFrame(.accept, timestamp: 400, oSeqno: 0, iSeqno: 2)
        let disposition = await harness.channel.receive(.full(accept))
        XCTAssertEqual(disposition, .deliver(accept))

        let remaining = await harness.channel.outstandingFrames
        XCTAssertEqual(remaining.map(\.oSeqno), [third.oSeqno])
        await harness.channel.close()
    }

    /// §8.1.1 defines ISeqno as "next expected"; §7 defines it as "highest
    /// received", one lower. We implement §8.1.1 and stay tolerant on receive:
    /// a peer that follows §7 merely looks one behind, and that alone must
    /// never tear the call down.
    func testAnISeqnoThatLooksOneLowIsToleratedNotFatal() async throws {
        let harness = makeHarness()
        _ = try await harness.channel.send(.new, timestamp: 100)  // OSeqno 0
        await expectSleepers(1, harness.clock)

        // A §7-literal peer that has received our OSeqno 0 reports ISeqno 0.
        let reply = peerFrame(.accept, timestamp: 150, oSeqno: 0, iSeqno: 0)
        _ = await harness.channel.receive(.full(reply))

        let outstandingCount = await harness.channel.outstandingFrameCount
        XCTAssertEqual(outstandingCount, 1, "strictly-before retirement keeps the newest frame")
        let isDead = await harness.channel.isDead
        XCTAssertFalse(isDead, "a low-looking ISeqno must never tear the call down")
        await harness.channel.close()
    }

    // MARK: Inbound sequencing (§6.9.3, §8.1.1)

    func testInboundFrameAdvancesISeqnoAndIsAcked() async throws {
        let harness = makeHarness()

        let first = peerFrame(.new, timestamp: 10, oSeqno: 0, iSeqno: 0)
        var disposition = await harness.channel.receive(.full(first))
        XCTAssertEqual(disposition, .deliver(first))
        var iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(iSeqno, 1, "ISeqno is the *next expected* inbound OSeqno (§8.1.1)")

        // "an ACK… MUST return the same time-stamp it received" (§6.9.1)
        let ack = try sentFullFrame(harness.transport, 0)
        XCTAssertEqual(ack.iaxMessage, .ack)
        XCTAssertEqual(ack.timestamp, 10)
        XCTAssertEqual(ack.oSeqno, 0, "an ACK carries the unchanged OSeqno (§7)")
        XCTAssertEqual(ack.iSeqno, 1)
        XCTAssertEqual(ack.destinationCallNumber, peerCallNumber)
        XCTAssertEqual(ack.sourceCallNumber, localCallNumber)

        let second = peerFrame(.ping, timestamp: 20, oSeqno: 1, iSeqno: 0)
        disposition = await harness.channel.receive(.full(second))
        XCTAssertEqual(disposition, .deliver(second))
        iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(iSeqno, 2)
        XCTAssertEqual(harness.transport.sentCount, 2)

        // Control frames are ACKed too: §6.9.1's enumeration omits RINGING and
        // ANSWER, but §8.1.1 ("all Full Frames require an immediate
        // acknowledgment") and the §9.6 flow both ACK them.
        let ringing = IAX2FullFrame(
            sourceCallNumber: peerCallNumber, destinationCallNumber: localCallNumber,
            timestamp: 30, oSeqno: 2, iSeqno: 0, type: .control,
            subclass: IAX2Subclass(IAX2Control.ringing))
        disposition = await harness.channel.receive(.full(ringing))
        XCTAssertEqual(disposition, .deliver(ringing))
        let ringingAck = try sentFullFrame(harness.transport, 2)
        XCTAssertEqual(ringingAck.iaxMessage, .ack)
        XCTAssertEqual(ringingAck.timestamp, 30)

        await harness.channel.close()
    }

    func testDuplicateInboundFrameIsReAckedButNotDeliveredTwice() async throws {
        let harness = makeHarness()
        let frame = peerFrame(.new, timestamp: 10, oSeqno: 0, iSeqno: 0)
        _ = await harness.channel.receive(.full(frame))

        // The peer's own retransmission: same OSeqno, R bit set.
        let disposition = await harness.channel.receive(.full(frame.retransmitted()))
        XCTAssertEqual(disposition, .duplicate(frame.retransmitted()))

        let iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(iSeqno, 1, "a duplicate must not advance ISeqno")

        // Re-ACKed, because the peer only retransmits when our first ACK was
        // lost (§8.1.1).
        XCTAssertEqual(harness.transport.sentCount, 2)
        let secondAck = try sentFullFrame(harness.transport, 1)
        XCTAssertEqual(secondAck.iaxMessage, .ack)
        XCTAssertEqual(secondAck.timestamp, 10)
        XCTAssertEqual(secondAck.iSeqno, 1)
        await harness.channel.close()
    }

    func testOutOfOrderInboundFrameIsIgnoredAndAnsweredWithVNAK() async throws {
        let harness = makeHarness()

        // Expecting OSeqno 0; OSeqno 3 arrives, so 0-2 were lost.
        let gap = peerFrame(.ping, timestamp: 55, oSeqno: 3, iSeqno: 0)
        let disposition = await harness.channel.receive(.full(gap))
        XCTAssertEqual(disposition, .outOfSequence(gap))

        let iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(iSeqno, 0, "an out-of-order frame MUST be ignored (§7)")

        XCTAssertEqual(harness.transport.sentCount, 1)
        let vnak = try sentFullFrame(harness.transport, 0)
        XCTAssertEqual(vnak.iaxMessage, .vnak)
        XCTAssertEqual(vnak.iSeqno, 0, "the VNAK's ISeqno names the first frame we are missing")
        XCTAssertEqual(vnak.oSeqno, 0, "a VNAK does not change the message count (§7)")
        let oSeqno = await harness.channel.outboundSequenceNumber
        XCTAssertEqual(oSeqno, 0)

        // The missing frame then arrives and is accepted normally.
        let recovered = peerFrame(.ping, timestamp: 56, oSeqno: 0, iSeqno: 0)
        let recoveredDisposition = await harness.channel.receive(.full(recovered))
        XCTAssertEqual(recoveredDisposition, .deliver(recovered))
        let recoveredISeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(recoveredISeqno, 1)
        await harness.channel.close()
    }

    /// INVAL, TXCNT and TXACC are delivered to the call layer but, like ACK and
    /// VNAK, consume no sequence number in either direction (§7) and are not
    /// ACKed.
    func testInboundExemptMessagesAreDeliveredWithoutSequencing() async throws {
        for message in [IAX2Message.inval, .txcnt, .txacc] {
            let harness = makeHarness()
            // Establish a non-zero expectation first.
            _ = await harness.channel.receive(.full(peerFrame(.new, timestamp: 1, oSeqno: 0, iSeqno: 0)))
            harness.transport.clearSent()

            // Deliberately a sequence number that would look out of order.
            let frame = peerFrame(message, timestamp: 2, oSeqno: 200, iSeqno: 0)
            let disposition = await harness.channel.receive(.full(frame))
            XCTAssertEqual(disposition, .deliver(frame), "\(message) must reach the call layer")

            let iSeqno = await harness.channel.expectedInboundSequenceNumber
            XCTAssertEqual(iSeqno, 1, "\(message) must not advance ISeqno (§7)")
            XCTAssertEqual(harness.transport.sentCount, 0, "\(message) must not be ACKed")
            await harness.channel.close()
        }
    }

    // MARK: VNAK (§6.9.3)

    func testVNAKRetransmitsEveryFrameFromItsISeqnoOnwards() async throws {
        let harness = makeHarness()
        _ = try await harness.channel.send(.new, timestamp: 100)  // OSeqno 0
        let second = try await harness.channel.send(.ping, timestamp: 200)  // OSeqno 1
        let third = try await harness.channel.send(.ping, timestamp: 300)  // OSeqno 2
        await expectSleepers(3, harness.clock)
        XCTAssertEqual(harness.transport.sentCount, 3)

        // "On receipt of a VNAK, a peer MUST retransmit all frames with a
        // higher sequence number than the VNAK message's iseqno." (§6.9.3) We
        // retransmit *at or after* it, which satisfies both readings of ISeqno.
        let vnak = peerFrame(.vnak, timestamp: 350, oSeqno: 0, iSeqno: 1)
        let disposition = await harness.channel.receive(.full(vnak))
        XCTAssertEqual(disposition, .consumed(vnak))

        // Its ISeqno also acknowledges cumulatively: OSeqno 0 is retired.
        let remaining = await harness.channel.outstandingFrames
        XCTAssertEqual(remaining.map(\.oSeqno), [second.oSeqno, third.oSeqno])

        XCTAssertEqual(harness.transport.sentCount, 5)
        let firstCopy = try sentFullFrame(harness.transport, 3)
        let secondCopy = try sentFullFrame(harness.transport, 4)
        XCTAssertEqual(firstCopy.oSeqno, second.oSeqno)
        XCTAssertEqual(firstCopy.timestamp, 200)
        XCTAssertTrue(firstCopy.isRetransmission)
        XCTAssertEqual(secondCopy.oSeqno, third.oSeqno)
        XCTAssertEqual(secondCopy.timestamp, 300)
        XCTAssertTrue(secondCopy.isRetransmission)

        // A VNAK is not itself ACKed and does not advance ISeqno (§7).
        let iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(iSeqno, 0)
        await harness.channel.close()
    }

    func testVNAKForAlreadyAcknowledgedFramesRetransmitsNothing() async throws {
        let harness = makeHarness()
        let only = try await harness.channel.send(.new, timestamp: 100)
        await expectSleepers(1, harness.clock)

        let vnak = peerFrame(.vnak, timestamp: 120, oSeqno: 0, iSeqno: only.oSeqno &+ 1)
        _ = await harness.channel.receive(.full(vnak))

        let outstandingCount = await harness.channel.outstandingFrameCount
        XCTAssertEqual(outstandingCount, 0, "the VNAK's ISeqno acknowledged the frame")
        XCTAssertEqual(harness.transport.sentCount, 1)
        await harness.channel.close()
    }

    // MARK: Modulo-256 wraparound (§8.1.1)

    func testOSeqnoWrapsSilentlyPastTwoHundredFiftyFive() async throws {
        let harness = makeHarness()

        // Well past one full lap of the 8-bit counter, ACKing as we go so the
        // ACK/outstanding matching is exercised across the wrap too.
        for index in 0..<300 {
            let timestamp = UInt32(index) * 20 + 1
            let frame = try await harness.channel.send(.ping, timestamp: timestamp)
            XCTAssertEqual(
                frame.oSeqno, UInt8(truncatingIfNeeded: index),
                "OSeqno must wrap modulo 256 at frame \(index)")

            let ack = peerFrame(
                .ack, timestamp: timestamp, oSeqno: 0, iSeqno: frame.oSeqno &+ 1)
            _ = await harness.channel.receive(.full(ack))
            let outstandingCount = await harness.channel.outstandingFrameCount
            XCTAssertEqual(outstandingCount, 0, "frame \(index) was not retired by its ACK")
        }

        let oSeqno = await harness.channel.outboundSequenceNumber
        XCTAssertEqual(oSeqno, UInt8(truncatingIfNeeded: 300))

        // And retransmission still works on the far side of the wrap.
        let afterWrap = try await harness.channel.send(.ping, timestamp: 99_999)
        XCTAssertEqual(afterWrap.oSeqno, 44)
        await expectSleepers(1, harness.clock)
        harness.clock.advance(by: .milliseconds(500))
        await expectSleepers(1, harness.clock)
        let copy = try sentFullFrame(harness.transport, harness.transport.sentCount - 1)
        XCTAssertTrue(copy.isRetransmission)
        XCTAssertEqual(copy.oSeqno, 44)
        XCTAssertEqual(copy.timestamp, 99_999)
        await harness.channel.close()
    }

    func testISeqnoWrapsSilentlyPastTwoHundredFiftyFive() async throws {
        let harness = makeHarness()

        for index in 0..<300 {
            let timestamp = UInt32(index) + 1
            let frame = peerFrame(
                .ping, timestamp: timestamp, oSeqno: UInt8(truncatingIfNeeded: index), iSeqno: 0)
            let disposition = await harness.channel.receive(.full(frame))
            XCTAssertEqual(disposition, .deliver(frame), "inbound frame \(index) rejected")

            let ack = try sentFullFrame(harness.transport, index)
            XCTAssertEqual(ack.iaxMessage, .ack)
            XCTAssertEqual(ack.timestamp, timestamp)
            XCTAssertEqual(ack.iSeqno, UInt8(truncatingIfNeeded: index &+ 1))
        }

        let iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(iSeqno, UInt8(truncatingIfNeeded: 300))

        // A frame from before the wrap is still recognised as a duplicate
        // rather than a gap — the comparison is serial, not integer.
        let stale = peerFrame(.ping, timestamp: 5, oSeqno: 250, iSeqno: 0)
        let staleDisposition = await harness.channel.receive(.full(stale))
        XCTAssertEqual(staleDisposition, .duplicate(stale))
        let wrappedISeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(wrappedISeqno, 44)
        await harness.channel.close()
    }

    // MARK: Mini frames (§8.1.2, §6.10)

    func testOutboundMiniFramesBypassSequencingAndReliability() async throws {
        let harness = makeHarness()
        _ = try await harness.channel.send(.new, timestamp: 0)
        harness.transport.clearSent()

        let payload: [UInt8] = Array(repeating: 0xFF, count: 160)
        try await harness.channel.sendMini(timestamp: 0x1234, payload: payload)

        XCTAssertEqual(harness.transport.sentCount, 1)
        let frame = try XCTUnwrap(IAX2Frame.parse(harness.transport.sent[0]).miniFrame)
        XCTAssertEqual(frame.sourceCallNumber, localCallNumber)
        XCTAssertEqual(frame.timestamp, 0x1234)
        XCTAssertEqual(frame.payload, payload)

        let oSeqno = await harness.channel.outboundSequenceNumber
        XCTAssertEqual(oSeqno, 1, "a mini frame must not touch OSeqno (§8.1.2)")
        let outstandingCount = await harness.channel.outstandingFrameCount
        XCTAssertEqual(outstandingCount, 1, "a mini frame is never retransmitted (§8.1.2)")

        // Nothing new goes out at any mini-frame "deadline" — there is none.
        harness.clock.advance(by: .milliseconds(499))
        await settle()
        XCTAssertEqual(harness.transport.sentCount, 1)
        await harness.channel.close()
    }

    func testInboundMiniFramesBypassSequencingAndAreNeverAcked() async throws {
        let harness = makeHarness()
        let mini = IAX2MiniFrame(
            sourceCallNumber: peerCallNumber, timestamp: 0x8000, payload: [1, 2, 3])
        let disposition = await harness.channel.receive(.mini(mini))
        XCTAssertEqual(disposition, .media(mini))

        let iSeqno = await harness.channel.expectedInboundSequenceNumber
        XCTAssertEqual(iSeqno, 0, "a mini frame carries no sequence number (§8.1.2)")
        XCTAssertEqual(
            harness.transport.sentCount, 0,
            "\"Upon receiving any media message, except the abbreviated audio and video Mini "
                + "Frames, an ACK message MUST be sent.\" (§6.10)")
        await harness.channel.close()
    }

    func testReceiveParsesDatagramsAndRejectsMetaFrames() async throws {
        let harness = makeHarness()
        let frame = peerFrame(.new, timestamp: 7, oSeqno: 0, iSeqno: 0)
        let disposition = try await harness.channel.receive(
            datagram: IAX2Frame.full(frame).encoded())
        XCTAssertEqual(disposition, .deliver(frame))

        // A meta frame (first 16 bits zero, §8.1.3) is not ours to interpret.
        do {
            _ = try await harness.channel.receive(datagram: Data([0, 0, 0, 1, 2, 3]))
            XCTFail("a meta frame must be rejected, not mis-parsed")
        } catch let error as IAX2FrameError {
            XCTAssertEqual(error, .metaFrame)
        }
        await harness.channel.close()
    }

    // MARK: Teardown

    func testCloseStopsRetransmissionWithoutSendingAnything() async throws {
        let harness = makeHarness()
        _ = try await harness.channel.send(.new, timestamp: 1)
        await expectSleepers(1, harness.clock)

        await harness.channel.close()
        harness.clock.advance(by: .seconds(60))
        await settle()

        XCTAssertEqual(harness.transport.sentCount, 1, "a closed channel sends nothing further")
        let disposition = await harness.channel.receive(
            .full(peerFrame(.ack, timestamp: 1, oSeqno: 0, iSeqno: 1)))
        XCTAssertEqual(disposition, .ignored)
    }
}
