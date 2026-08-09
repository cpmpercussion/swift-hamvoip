// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore
import TestSupport
import XCTest

@testable import IAX2Kit

/// IAX-9: capture-replay conformance.
///
/// Every other test in this target is built from the specification: the bytes
/// were written out field by field from RFC 5456, so what they check is our
/// *reading* of the RFC. This file is the other half of that. The fixtures here
/// are the octets a real Asterisk/app_rpt node put on the wire in reply to us,
/// captured from the maintainer's own sessions against their own node on
/// 2026-08-09 (LP-1, `Tests/FIXTURES.md` rule 2, and the provenance header of
/// each fixture). Replaying them asks a different question: not "did we read
/// the RFC correctly" but "does what we built survive contact with a node that
/// has its own reading, its own extensions, and its own timing".
///
/// The shape of every test here is the same. Only the *node's* datagrams are
/// injected, through `MockTransport`, exactly as captured; our side is whatever
/// the code under test decides to send now. The assertions are on protocol
/// validity — parseable frames, the right call numbers, sequence numbers that
/// advance the way §7 says, ACKs where §6.9.1 requires them — and never on
/// byte-equality with what our client happened to send on the day. A test that
/// pinned our old output would fail the moment we improved it, and would have
/// nothing to say about the node.
///
/// Three things the live node does that no fixture written from the RFC would
/// have contained, each of which is asserted below:
///
///  * it sends a bare ACK *and then* the answer, as two frames, every time;
///  * it uses a control subclass, an information element and a frame type that
///    RFC 5456 does not define;
///  * it crosses the 16-bit mini-frame time-stamp boundary without sending the
///    full frame §6.10 says it MUST send there.
final class IAX2ConformanceTests: XCTestCase {

    // MARK: - Harness

    private func fixture(_ name: String) throws -> [Data] {
        try FixtureLoader.datagrams(name, in: Bundle.module)
    }

    private func frames(_ name: String) throws -> [IAX2Frame] {
        try fixture(name).map { try IAX2Frame.parse($0) }
    }

    /// Every datagram the code under test wrote, parsed. A parse failure here
    /// is itself the assertion: whatever we put on the wire must be a frame.
    private func sentFrames(
        _ transport: MockTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [IAX2FullFrame] {
        try transport.sent.enumerated().map { index, datagram in
            let frame = try IAX2Frame.parse(datagram)
            return try XCTUnwrap(
                frame.fullFrame,
                "sent datagram \(index) is a mini frame; this session sends none",
                file: file, line: line)
        }
    }

    private func waitForSent(
        _ count: Int,
        _ transport: MockTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100_000 {
            if transport.sentCount >= count { return }
            await Task.yield()
        }
        XCTFail(
            "expected \(count) sent datagram(s), saw \(transport.sentCount)",
            file: file, line: line)
    }

    private func settle(_ iterations: Int = 500) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    /// The §7 sequence-number rules, checked over a whole outbound stream at
    /// once. These hold for every session in this file, so they are asserted
    /// once as a unit rather than restated per frame.
    ///
    ///  * OSeqno starts at 0 and rises by exactly one per frame, *except* that
    ///    the messages in `IAX2FullFrame.sequenceNumberExempt` — ACK above all
    ///    — "do not change the message count" (§7) and so repeat the number the
    ///    next real frame will use.
    ///  * ISeqno never goes backwards; it is "the next expected" inbound
    ///    OSeqno, so it rises only as inbound frames are consumed.
    ///  * Every frame carries our source call number, and every frame after the
    ///    peer has identified itself carries the peer's as its destination.
    private func assertSequenceDiscipline(
        _ frames: [IAX2FullFrame],
        sourceCallNumber: UInt16,
        peerCallNumber: UInt16,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var expectedOSeqno: UInt8 = 0
        var previousISeqno: UInt8 = 0
        var peerIdentified = false

        for (index, frame) in frames.enumerated() {
            let label = "sent frame \(index) (\(frame.type) subclass \(frame.subclass))"

            XCTAssertEqual(
                frame.sourceCallNumber, sourceCallNumber,
                "\(label): every frame we send carries our own call number (§8.1.1)",
                file: file, line: line)

            if peerIdentified {
                XCTAssertEqual(
                    frame.destinationCallNumber, peerCallNumber,
                    "\(label): once the peer has identified itself, every frame we send "
                        + "must address it — a call leg is a *pair* of identifiers (§6.2.1)",
                    file: file, line: line)
            } else if frame.destinationCallNumber != 0 {
                XCTAssertEqual(
                    frame.destinationCallNumber, peerCallNumber,
                    "\(label): the only destination call number that may appear is the peer's",
                    file: file, line: line)
                peerIdentified = true
            }

            XCTAssertEqual(
                frame.oSeqno, expectedOSeqno,
                "\(label): OSeqno counts the frames that consume a sequence number (§7)",
                file: file, line: line)

            let exempt = frame.iaxMessage.map { IAX2Message.sequenceNumberExempt.contains($0) }
            if frame.type == .iax, exempt == true {
                // "the ACK … does not change the message count" (§7).
            } else {
                expectedOSeqno &+= 1
            }

            XCTAssertGreaterThanOrEqual(
                frame.iSeqno, previousISeqno,
                "\(label): ISeqno is the next expected inbound OSeqno and never rewinds (§7)",
                file: file, line: line)
            previousISeqno = frame.iSeqno
        }

        // Without this the destination-call-number rule above would pass
        // vacuously on a client that never learned the peer's number at all —
        // which is precisely the failure it is there to catch.
        XCTAssertTrue(
            peerIdentified,
            "by the end of the exchange we must have learned and used the peer's call number",
            file: file, line: line)
    }

    // MARK: - Registration (§6.1) — `oq5-confirm.pcap`

    /// The node's half of a successful registration, replayed into a fresh
    /// `IAX2Registrar`.
    ///
    /// This is the exchange that resolved OQ-5. What it proves is not that we
    /// compute the same digest the probe did — we do not have the maintainer's
    /// node password and do not want it in the repository — but that the
    /// registrar walks the §6.1 flow correctly when the *node's* timing and
    /// framing are the real ones.
    func testLiveRegistrationReplayWalksTheSection61Flow() async throws {
        // The capture's own call numbers, so the fixture replays verbatim.
        let ours: UInt16 = 15158
        let theirs: UInt16 = 4305

        let transport = MockTransport()
        let clock = ManualTestClock()
        let registrar = IAX2Registrar(
            sourceCallNumber: ours,
            request: IAX2RegistrationRequest(username: "oq5test", secret: "hunter2", refresh: 60),
            transport: transport,
            clock: clock)

        let log = EventLog<IAX2RegistrationEvent>()
        let logTask = Task { for await event in registrar.events { await log.append(event) } }

        try await registrar.register()
        await waitForSent(1, transport)
        transport.inject(try fixture("live-reg-session.hex"))

        await waitForSent(4, transport)
        await settle()

        let state = await registrar.state
        XCTAssertEqual(state, .registered, "the REGACK registers us (§6.1.4)")

        // --- What we put on the wire ------------------------------------
        let sent = try sentFrames(transport)
        XCTAssertEqual(sent.count, 4, "REGREQ, ACK of the REGAUTH, REGREQ+MD5, ACK of the REGACK")
        assertSequenceDiscipline(sent, sourceCallNumber: ours, peerCallNumber: theirs)

        XCTAssertEqual(
            sent.map(\.iaxMessage), [.regreq, .ack, .regreq, .ack],
            "the §6.1 flow: REGREQ, then an ACK for each of the node's two answers, "
                + "with the authenticated REGREQ between them")

        // "An ACK … MUST return the same time-stamp it received" (§6.9.1). The
        // node's REGAUTH was stamped 0x15 and its REGACK 0x18; those are its
        // clock, not ours, and they come back untouched.
        XCTAssertEqual(sent[1].timestamp, 0x15, "ACK of the REGAUTH echoes its time-stamp")
        XCTAssertEqual(sent[3].timestamp, 0x18, "ACK of the REGACK echoes its time-stamp")

        // The peer's number is learned from its first reply and used from the
        // very next frame we send — including the ACK, which is emitted while
        // the REGAUTH is still being processed.
        XCTAssertEqual(
            sent[1].destinationCallNumber, theirs,
            "the ACK of the REGAUTH already addresses the node (§6.2.1, §8.1.1)")

        // The authenticated REGREQ carries USERNAME, MD5 RESULT and REFRESH,
        // and no plaintext password (§6.1.2, §8.6.15, §10).
        let authenticated = try InformationElement.parseList(sent[2].payload)
        let digest = try XCTUnwrap(
            authenticated.compactMap { element -> String? in
                if case .md5Result(let value) = element { return value }
                return nil
            }.first,
            "the second REGREQ MUST carry an MD5 RESULT (§6.1.2)")
        XCTAssertEqual(
            digest, IAX2Auth.md5Response(challenge: "458371471", secret: "hunter2"),
            "computed over the challenge this node actually sent")
        XCTAssertEqual(digest.count, 32, "lowercase hex text, 32 characters — OQ-5")
        XCTAssertEqual(
            digest, digest.lowercased(),
            "this node rejects the uppercase spelling; that is what OQ-5 settled")
        XCTAssertFalse(
            authenticated.contains { if case .password = $0 { return true } else { return false } },
            "no plaintext password path exists (§8.6.13, §10)")

        // --- What we made of the node's half ----------------------------
        await registrar.close()
        transport.finish()
        await logTask.value
        let events = await log.events

        XCTAssertTrue(
            events.contains(.challenged(challenge: "458371471", methods: .md5)),
            "the node's CHALLENGE and AUTHMETHODS are surfaced (§6.1.3)")

        let registration = try XCTUnwrap(
            events.compactMap { event -> IAX2RegistrationInfo? in
                if case .registered(let info) = event { return info }
                return nil
            }.first,
            "the REGACK is reported as a registration")
        XCTAssertEqual(registration.username, "oq5test")
        XCTAssertEqual(
            registration.refreshSeconds, 60,
            "the node echoed our REFRESH of 60 seconds back (§8.6.19)")
        // APPARENT ADDRESS: the address the node saw us arrive from (§8.6.17).
        // 192.168.65.1 is this machine on the VM's network; the port is the
        // ephemeral one the probe bound.
        let apparent = try XCTUnwrap(registration.apparentAddress, "§6.1.4 requires it")
        XCTAssertEqual(apparent.addressBytes, [192, 168, 65, 1])
        XCTAssertEqual(
            apparent.familyAsLittleEndian, ApparentAddress.addressFamilyINET,
            "this node writes the sockaddr family little-endian, which is the reading "
                + "the RFC's own §8.6.17 worked example uses — and the opposite of the "
                + "byte order every other field in the protocol uses (notes trap 24)")
        XCTAssertNotNil(
            registration.dateTime,
            "the node's DATETIME is decoded rather than discarded (§8.6.28)")
    }

    /// The node's half of a *rejected* registration — and the second of the two
    /// reasons this capture is worth having: the node sat on the bad credential
    /// for a full second before answering.
    func testLiveRegistrationRejectionIsAckedAndSurfaced() async throws {
        let ours: UInt16 = 16558
        let theirs: UInt16 = 15199

        let transport = MockTransport()
        let clock = ManualTestClock()
        let registrar = IAX2Registrar(
            sourceCallNumber: ours,
            request: IAX2RegistrationRequest(username: "oq5test", secret: "wrong", refresh: 60),
            transport: transport,
            clock: clock,
            configuration: IAX2Registrar.Configuration(retry: .none))

        let log = EventLog<IAX2RegistrationEvent>()
        let logTask = Task { for await event in registrar.events { await log.append(event) } }

        try await registrar.register()
        await waitForSent(1, transport)
        transport.inject(try fixture("live-reg-reject.hex"))

        await waitForSent(4, transport)
        await settle()

        let state = await registrar.state
        XCTAssertNotEqual(state, .registered, "a REGREJ does not register us (§6.1.5)")

        let sent = try sentFrames(transport)
        XCTAssertEqual(sent.map(\.iaxMessage), [.regreq, .ack, .regreq, .ack])
        assertSequenceDiscipline(sent, sourceCallNumber: ours, peerCallNumber: theirs)
        XCTAssertEqual(
            sent[3].iaxMessage, .ack,
            "\"the registration MUST be ACKed\" holds for a rejection too (§6.1.5)")

        // The node answered at its time-stamp 1012 against the REGAUTH's 12 —
        // a full second of deliberate delay. Nothing in our retransmission
        // ladder may fire into that gap and turn one rejection into a storm:
        // the clock here never advanced, and exactly four datagrams left.
        XCTAssertEqual(
            sent[3].timestamp, 1012,
            "the ACK echoes the REGREJ's time-stamp, a second after the challenge (§6.9.1)")
        XCTAssertEqual(transport.sentCount, 4, "no retransmission was provoked by the delay")

        await registrar.close()
        transport.finish()
        await logTask.value
        let events = await log.events

        let failure = try XCTUnwrap(
            events.compactMap { event -> IAX2RegistrationError? in
                if case .failed(let error) = event { return error }
                return nil
            }.first,
            "the REGREJ is surfaced as a failure (§6.1.5)")
        guard case .rejected(let cause, let causeCode) = failure else {
            return XCTFail("expected a rejection carrying the node's CAUSE, got \(failure)")
        }
        XCTAssertNotNil(cause ?? causeCode.map(String.init), "§8.6.21 / §8.6.33")
    }

    // MARK: - A call, signalling (§6.2, §6.3) — `connect3.pcap`

    /// The whole signalling half of a live 36-second call, replayed into a
    /// fresh `IAX2Call`: NEW → AUTHREQ → AUTHREP → ACCEPT → ANSWER, then the
    /// node's mid-call traffic, ending at the ACK of our HANGUP.
    func testLiveCallSignallingReplayIsProtocolValid() async throws {
        let ours: UInt16 = 1
        let theirs: UInt16 = 0x3add  // 15069

        let transport = MockTransport()
        let clock = ManualTestClock()
        let allocator = IAX2CallNumberAllocator()
        let call = try await IAX2Call.outbound(
            allocator: allocator,
            request: IAX2CallRequest(
                calledNumber: "55553", username: "oq5test", secret: "hunter2"),
            transport: transport,
            clock: clock)
        XCTAssertEqual(
            call.sourceCallNumber, ours,
            "the allocator hands out 1 first, which is the number this capture answers to")

        let log = EventLog<IAX2CallEvent>()
        let logTask = Task { for await event in call.events { await log.append(event) } }

        let inbound = try frames("live-call-signalling.hex")
        XCTAssertEqual(inbound.count, 22, "every full frame the node sent, and nothing else")

        try await call.start()
        await waitForSent(1, transport)
        for frame in inbound {
            try await call.deliver(frame)
        }
        await settle()

        let state = await call.state
        XCTAssertEqual(state, .up, "ACCEPT then Control ANSWER brings the call up (§6.2.3, §6.3.4)")
        let peer = await call.destinationCallNumber
        XCTAssertEqual(peer, theirs, "learned from the node's first reply")
        let format = await call.negotiatedFormat
        XCTAssertEqual(
            format, .g711MuLaw,
            "the ACCEPT's FORMAT IE is 0x00000004 — µ-law (§6.2.3, §8.7)")

        // --- Everything we sent is a valid frame, in a valid stream ------
        let sent = try sentFrames(transport)
        assertSequenceDiscipline(sent, sourceCallNumber: ours, peerCallNumber: theirs)

        // --- ACK discipline (§6.9.1) ------------------------------------
        // Every full frame the node sent that is not itself sequence-exempt
        // must draw exactly one ACK carrying its time-stamp back.
        let ackable: [IAX2FullFrame] = inbound.compactMap(\.fullFrame).filter { frame in
            guard frame.type == .iax, let message = frame.iaxMessage else { return true }
            return !IAX2Message.sequenceNumberExempt.contains(message)
        }
        let ackedTimestamps = sent.filter { $0.iaxMessage == .ack }.map(\.timestamp)
        XCTAssertEqual(
            ackedTimestamps, ackable.map(\.timestamp),
            "one ACK per ackable inbound frame, in order, each echoing its time-stamp")

        // --- The node's non-RFC traffic ---------------------------------
        // A Control frame whose subclass octet is 0xff, which §8.3 does not
        // define. "Sent … if a command is not understood" (§6.5.5).
        let unsupported = sent.filter { $0.iaxMessage == .unsupport }
        XCTAssertEqual(
            unsupported.count, 1,
            "the node's undefined Control subclass draws exactly one UNSUPPORT (§6.5.5)")

        // A frame type 0x0c, which §8.2 does not define either. It must be
        // ACKed like anything else and must not disturb the numbering — which
        // `assertSequenceDiscipline` has already checked over the whole stream.
        let unknownType = inbound.compactMap(\.fullFrame).filter {
            $0.type == IAX2FrameType(rawValue: 0x0c)
        }
        XCTAssertEqual(unknownType.count, 1, "the capture contains one, at time-stamp 0x483b")
        XCTAssertTrue(
            ackedTimestamps.contains(0x483b),
            "an unassigned frame type is still acknowledged (§8.2 defers to IANA)")

        // PING and LAGRQ each draw an ACK *and* their own reply (§6.7).
        XCTAssertEqual(sent.filter { $0.iaxMessage == .pong }.count, 1, "§6.7.2")
        XCTAssertEqual(sent.filter { $0.iaxMessage == .lagrp }.count, 3, "§6.7.5")

        // --- What reached the caller ------------------------------------
        await call.close()
        transport.finish()
        await logTask.value
        let events = await log.events

        let states = events.compactMap { event -> IAX2CallState? in
            guard case .stateChanged(_, let to) = event else { return nil }
            return to
        }
        XCTAssertEqual(
            Array(states.prefix(6)),
            [.newSent, .authRequested, .authReplied, .accepted, .answered, .up],
            "the §6.2 path, walked against a live node")

        XCTAssertTrue(
            events.contains(.challenged(challenge: "186138128", methods: .md5)),
            "the node's own CHALLENGE, surfaced (§6.2.6)")
        XCTAssertTrue(events.contains(.control(.answer)), "§6.3.4")

        // The DTMF digit the node echoed back to us mid-call (§8.2.1).
        let dtmf = events.compactMap { event -> IAX2FullFrame? in
            guard case .other(let full) = event, full.type == .dtmf else { return nil }
            return full
        }
        XCTAssertEqual(
            dtmf.map { Character(UnicodeScalar($0.subclass.rawByte)) }, ["3"],
            "the node echoed the '3' we sent it, as a DTMF frame whose subclass is the digit")

        // The node's one full Voice frame reached the media path untouched.
        let media = events.compactMap { event -> IAX2Frame? in
            guard case .media(let frame) = event else { return nil }
            return frame
        }
        XCTAssertEqual(media.count, 1, "one full Voice frame in the signalling-only fixture")
        XCTAssertEqual(
            media.first?.fullFrame?.subclass.rawByte, 0x04,
            "the node writes the media format *literally*, where we write 2^2 = 0x82 (§8.1.1)")
        XCTAssertEqual(
            media.first?.fullFrame?.mediaFormat, MediaFormat.g711MuLaw.rawValue,
            "both spellings mean the same codec (§8.7)")
    }

    /// The node's first over: the full Voice frame that pins the codec, then
    /// the mini frames that carry only 16 bits of time-stamp and no codec at
    /// all (§8.1.2).
    func testLiveInboundOverPinsTheCodecThenPlaysMiniFrames() throws {
        let inbound = try frames("live-call-voice.hex")
        XCTAssertEqual(inbound.count, 13, "one full Voice frame and twelve mini frames")

        var receiver = IAX2VoiceReceiver()
        XCTAssertNil(receiver.format, "nothing has pinned a codec yet")

        var queued: [UInt32] = []
        for (index, frame) in inbound.enumerated() {
            guard case .queued(let timestamp) = receiver.receive(frame) else {
                return XCTFail("frame \(index) of a live over should be playable audio")
            }
            queued.append(timestamp)
        }

        XCTAssertEqual(
            receiver.format, .g711MuLaw,
            "pinned by the full Voice frame's subclass, which this node writes as a "
                + "literal 0x04 rather than as 2^2 (§8.1.2, §8.7)")
        XCTAssertEqual(
            queued, Array(stride(from: UInt32(2980), through: 3220, by: 20)),
            "2980 ms from the full frame, then one mini frame per 20 ms, expanded "
                + "against it — an unbroken 20 ms grid")

        // Every frame is 160 octets: 20 ms of 8 kHz µ-law (§8.7, RC-2).
        for (index, frame) in inbound.enumerated() {
            XCTAssertEqual(frame.payload.count, 160, "frame \(index)")
        }

        // And it plays out as audio, in time-stamp order, without concealment.
        for index in 0..<inbound.count {
            let playout = receiver.pop()
            XCTAssertEqual(playout.kind, .audio, "slot \(index) is real audio, not a gap filler")
            XCTAssertEqual(playout.pcm.count, receiver.samplesPerFrame)
        }
    }

    // MARK: - The 16-bit time-stamp boundary (§8.1.2, §6.10) — `wrap.pcap`

    /// The inbound wrap, with no full frame at the boundary to help.
    ///
    /// This is the regression test `IAX2MiniTimestampExpander` exists for. The
    /// node's mini time-stamps step 65500 → 65520 → 4 and it sends nothing to
    /// say an epoch ended, so the expansion is inferred from the low 16 bits
    /// alone. Get it wrong in the obvious way — treat the field as the whole
    /// time-stamp — and the stream jumps 65 seconds backwards at the boundary.
    func testLiveInboundWrapExpandsWithoutAnAnchor() throws {
        let inbound = try frames("live-wrap-inbound.hex")

        // The window opens 65.26 s into the call, where the live receiver's
        // reference already stood. It is the one piece of session state the
        // fixture cannot carry.
        var expander = IAX2MiniTimestampExpander(reference: 65_260)

        var expanded: [UInt32] = []
        var skippedFullFrames = 0
        for (index, frame) in inbound.enumerated() {
            switch frame {
            case .mini(let mini):
                guard let timestamp = expander.expand(mini.timestamp) else {
                    return XCTFail("mini frame \(index) was rejected at the boundary")
                }
                expanded.append(timestamp)
            case .full(let full):
                // The node's ACK of our own re-anchoring Voice frame. §6.9.1
                // makes an ACK echo the time-stamp it received, so its 65541 is
                // *our* clock coming back, not the node's — and a receiver that
                // anchored on it would silently adopt the wrong clock. The
                // production rule lives in `IAX2VoiceReceiver`, asserted below;
                // here it is simply not offered to the expander.
                XCTAssertEqual(full.iaxMessage, .ack)
                skippedFullFrames += 1
            }
        }
        XCTAssertEqual(skippedFullFrames, 1)

        // 65280 … 65520 in the old epoch, then straight on into the new one.
        // The point of the assertion is the step across the middle: 65520 is
        // followed by 65540, twenty milliseconds later, and not by 4.
        XCTAssertEqual(
            expanded,
            Array(stride(from: UInt32(65_280), through: 65_520, by: 20))
                + Array(stride(from: UInt32(65_540), through: 65_700, by: 20)),
            "an unbroken 20 ms grid straight through the 16-bit boundary")
        XCTAssertEqual(
            expanded.sorted(), expanded,
            "and it is monotonic — nothing lands in the wrong epoch")

        // The production rule that keeps the ACK out of it: a full frame that
        // is not media may not re-anchor anything.
        var receiver = IAX2VoiceReceiver()
        receiver.pinFormat(.g711MuLaw)
        let ack = try XCTUnwrap(inbound.compactMap(\.fullFrame).first)
        guard case .rejected = receiver.receive(.full(ack)) else {
            return XCTFail("an ACK is not media and must not reach the jitter buffer")
        }
        XCTAssertEqual(
            receiver.expandedTimestamp, 0,
            "and it must not move the expansion reference either (§6.9.1, notes §11)")
    }

    /// Our own side of the same boundary: the §6.10 re-anchoring, at both of
    /// the 0x8000 crossings the live call went through.
    ///
    /// The transmitter is driven with the 32-bit time-stamps read back out of
    /// the captured datagrams, and must choose full or mini exactly where the
    /// live client did. If that decision ever stopped firing, a peer's
    /// expansion reference would drift with nothing on the wire to correct it —
    /// and nothing else in the protocol would complain.
    func testLiveOutboundResyncsAtEveryResyncBoundary() throws {
        let outbound = try frames("live-wrap-outbound.hex")

        // Reconstruct our own 32-bit clock from the capture the same way a peer
        // would have to: full frames carry it, mini frames are expanded.
        var expander = IAX2MiniTimestampExpander()
        var timeline: [(timestamp: UInt32, wasFull: Bool)] = []
        for (index, frame) in outbound.enumerated() {
            switch frame {
            case .full(let full):
                XCTAssertEqual(full.type, .voice, "the only full frames in this window are Voice")
                expander.resynchronise(to: full.timestamp)
                timeline.append((full.timestamp, true))
            case .mini(let mini):
                guard let timestamp = expander.expand(mini.timestamp) else {
                    return XCTFail("outbound frame \(index) failed to expand")
                }
                timeline.append((timestamp, false))
            }
        }

        XCTAssertEqual(
            timeline.filter(\.wasFull).map(\.timestamp), [32_781, 65_541],
            "the live client re-anchored at both 0x8000 crossings — the second is "
                + "also the 16-bit wrap (§6.10, §8.1.2)")

        // Now make the decision again, today. The first frame is unconstrained:
        // a freshly built transmitter always opens with a full frame, and this
        // window starts mid-call.
        var transmitter = IAX2VoiceTransmitter(format: .g711MuLaw)
        let silence = [UInt8](repeating: 0xFF, count: 160)
        var decisions: [Bool] = []
        for (index, entry) in timeline.enumerated() {
            let frame = try transmitter.next(timestamp: entry.timestamp, payload: silence)
            if index == 0 {
                XCTAssertTrue(frame.isFull, "a fresh transmitter always opens full")
                continue
            }
            decisions.append(frame.isFull)
        }

        XCTAssertEqual(
            decisions, timeline.dropFirst().map(\.wasFull),
            "full where the live client sent full, mini where it sent mini, frame for frame")

        // Said once more as a property rather than a replay, so a change to the
        // fixture cannot quietly make the assertion vacuous.
        let fullTimestamps = timeline.dropFirst().filter(\.wasFull).map(\.timestamp)
        XCTAssertEqual(fullTimestamps.count, 2)
        for timestamp in fullTimestamps {
            let previous = try XCTUnwrap(
                timeline.last { $0.timestamp < timestamp }?.timestamp)
            XCTAssertNotEqual(
                previous / IAX2VoiceTransmitter.resyncInterval,
                timestamp / IAX2VoiceTransmitter.resyncInterval,
                "each full frame sits on the far side of a 0x8000 boundary from its "
                    + "predecessor — that crossing is the whole reason it is full")
        }
    }

    // MARK: - Event log

    private actor EventLog<Event: Sendable> {
        private(set) var events: [Event] = []
        func append(_ event: Event) { events.append(event) }
    }
}
