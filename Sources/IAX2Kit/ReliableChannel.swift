// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Errors

/// Why a reliable channel stopped working.
///
/// A channel that reports any of these is **dead**: RFC 5456 §7 says the call
/// leg "MUST be torn down without any further interaction on this call leg",
/// and §6.6 repeats it — "the call leg MUST be torn down without any other
/// indications over the errant IAX call leg". So a dead channel sends nothing
/// further, **not even a HANGUP**, and refuses new sends.
public enum ReliableChannelError: Error, Equatable, CustomStringConvertible {
    /// A frame went unacknowledged through every retry (default 4, §7).
    /// Carries the identity of the frame that was never acknowledged — its
    /// OSeqno and its time-stamp, which together are how an ACK names a frame
    /// (§6.9.1).
    case retriesExhausted(oSeqno: UInt8, timestamp: UInt32, attempts: Int)

    /// The underlying `DatagramTransport` refused a write. Payload is a
    /// human-readable description, for logging only.
    case transportFailed(String)

    /// A send was attempted on a channel that has already been torn down.
    case channelDead

    public var description: String {
        switch self {
        case .retriesExhausted(let oSeqno, let timestamp, let attempts):
            return
                "no acknowledgement for OSeqno \(oSeqno) (time-stamp \(timestamp)) after \(attempts) "
                + "retries; call leg torn down (RFC 5456 §7)"
        case .transportFailed(let detail):
            return "transport failed: \(detail)"
        case .channelDead:
            return "reliable channel is dead; the call leg has been torn down"
        }
    }
}

// MARK: - ReliableChannel

/// The per-call sequence-number and retransmission engine (RFC 5456 §7, §8.1.1,
/// §6.9).
///
/// One instance owns one call leg's two 8-bit counters, the table of frames it
/// is still waiting to have acknowledged, and the backoff timers that retransmit
/// them. It sits directly on a `DatagramTransport` and knows nothing about call
/// state — IAX-5's `IAX2Call` owns the FSM, reads the transport, demultiplexes
/// datagrams by call number, and hands each frame for *this* call to
/// ``receive(_:)-(IAX2Frame)``.
///
/// ## What this actor decides, and on what authority
///
/// - **OSeqno advances on every full frame sent except five.** "Each reliable
///   message that is sent increments the message count by one except the ACK,
///   INVAL, TXCNT, TXACC, and VNAK messages, which do not change the message
///   count." (§7) The set lives in `IAX2Message.sequenceNumberExempt`. Mini
///   frames carry no sequence numbers at all and never touch either counter
///   (§8.1.2).
/// - **Both counters are modulo 256.** "When the counter overflows, it silently
///   resets to 0." (§8.1.1) Every comparison here is serial-number arithmetic
///   (see ``isBefore(_:_:)``), never plain integer comparison, or a call would
///   break after 256 full frames.
/// - **An ACK is matched to an outstanding frame by the time-stamp it echoes.**
///   "It MUST also not change the sequence number counters, and MUST return the
///   same time-stamp it received. This time-stamp allows the originating peer to
///   determine to which message the ACK is responding." (§6.9.1) Because an ACK
///   does not advance the peer's OSeqno, several ACKs in a row carry the same
///   OSeqno; the sequence number alone therefore cannot identify which frame is
///   being acknowledged. The outstanding table is keyed on
///   ``AcknowledgementKey`` = (OSeqno, time-stamp) and ACKs are matched on the
///   time-stamp component.
/// - **Retransmission** is exponential backoff from 500 ms, doubling, at most
///   `Configuration.maximumRetries` (default 4) retransmissions, each with the
///   `R` bit set and OSeqno and time-stamp unchanged (§8.1.1) via
///   `IAX2FullFrame.retransmitted()`.
///
/// ## RFC contradictions resolved here
///
/// 1. **ISeqno's definition.** §8.1.1 calls it "the next expected inbound stream
///    sequence number"; §7 calls it "the highest numbered incoming message that
///    has been received". Those differ by one. We *send* the §8.1.1 value
///    (last received + 1) and are tolerant on *receive*: an inbound ISeqno of
///    *N* acknowledges everything we sent with OSeqno strictly **before** *N*,
///    so a peer that follows §7 literally merely looks one behind and keeps its
///    newest frame outstanding for one extra round trip. A low-looking ISeqno
///    never tears a call down. (notes §9, "the off-by-one")
/// 2. **Which frames get an ACK.** §6.9.1 enumerates NEW, HANGUP, REJECT,
///    ACCEPT, PONG, AUTHREP, REGREL, REGACK, REGREJ, TXREL — a list that omits
///    the RINGING and ANSWER control frames that the §9.6 example flow does ACK.
///    §8.1.1 is broader still: "all Full Frames require an immediate
///    acknowledgment". We follow §8.1.1 and the §9.6 flow: **every** in-sequence
///    inbound full frame is ACKed, except the five exempt messages (ACKing an
///    ACK would never terminate, and "Receipt of an ACK requires no action",
///    §6.9.1). This is explicitly permitted even where a protocol-defined
///    response is also coming: "An ACK MAY also be sent as an initial
///    acknowledgment of an IAX message that requires some other protocol-defined
///    message acknowledgment, as long as the required message is also sent
///    within some peer-defined amount of time." (§6.9.1)
/// 3. **Retransmit timing.** §7.2.1 specifies 2 × the last measured PING/PONG
///    RTT, doubling, bounded at 10 s; §8.1.1 says "IAX does not specify a
///    retransmit timeout; this is left to the implementor". We implement
///    §7.2.1's *shape* — exponential backoff with a 10 s ceiling — and take
///    §8.1.1 as licence to choose the initial value, since the RFC gives none
///    for the "no RTT measured yet" case, which is every case before the first
///    PING/PONG completes. That initial value is 500 ms
///    (`Configuration.initialRetryInterval`); a caller that has measured an RTT
///    may set it to 2 × RTT.
/// 4. **VNAK's boundary.** "On receipt of a VNAK, a peer MUST retransmit all
///    frames with a higher sequence number than the VNAK message's iseqno."
///    (§6.9.3) Under §8.1.1's "next expected" reading of ISeqno, the first frame
///    the peer is missing is the one numbered exactly *iseqno*, not the one
///    after it. We retransmit everything **at or after** the VNAK's ISeqno,
///    which satisfies both readings; the extra frame, if any, is a duplicate the
///    peer will simply re-ACK.
///
/// ## Concurrency
///
/// The clock is injected exactly as `TransmitWatchdog` does it, so tests drive
/// every backoff deadline deterministically and no unit test ever waits in real
/// time.
public actor ReliableChannel {

    // MARK: Configuration

    /// Retransmission policy (RFC 5456 §7, §7.2.1).
    public struct Configuration: Sendable, Equatable {
        /// The first backoff interval, used before any PING/PONG RTT is known.
        /// Default 500 ms — see contradiction 3 in the type documentation.
        public var initialRetryInterval: Duration

        /// The ceiling the doubling backoff is clamped to: "The maximum retry
        /// time period boundary is 10 seconds." (§7.2.1)
        public var maximumRetryInterval: Duration

        /// How many retransmissions a frame gets before the call leg is
        /// declared unusable: "If no acknowledgment is received after a locally
        /// configured number of retries (default 4), the call leg SHOULD be
        /// considered unusable and the call MUST be torn down without any
        /// further interaction on this call leg." (§7)
        public var maximumRetries: Int

        public init(
            initialRetryInterval: Duration = .milliseconds(500),
            maximumRetryInterval: Duration = .seconds(10),
            maximumRetries: Int = 4
        ) {
            self.initialRetryInterval = initialRetryInterval
            self.maximumRetryInterval = maximumRetryInterval
            self.maximumRetries = maximumRetries
        }
    }

    // MARK: Inbound disposition

    /// What ``receive(_:)-(IAX2Frame)`` did with a frame, and what the call
    /// layer above should do next.
    public enum Inbound: Sendable, Equatable {
        /// An in-sequence full frame (or one of the sequence-exempt messages
        /// INVAL, TXCNT, TXACC). Already ACKed where the RFC requires it; the
        /// call layer should act on it.
        case deliver(IAX2FullFrame)

        /// A mini frame. Unsequenced, unacknowledged, unreliable (§8.1.2,
        /// §6.10) — it passed through this actor without touching any state.
        case media(IAX2MiniFrame)

        /// An ACK or a VNAK: consumed entirely by this actor (outstanding
        /// frames retired, or retransmissions issued). "Receipt of an ACK
        /// requires no action." (§6.9.1)
        case consumed(IAX2FullFrame)

        /// A full frame whose OSeqno we have already seen — the peer
        /// retransmitted because our ACK was lost. Re-ACKed, not delivered
        /// twice.
        case duplicate(IAX2FullFrame)

        /// A full frame from beyond the expected OSeqno, i.e. one or more
        /// frames were lost. "If a message is received out of order, it MUST be
        /// ignored and a VNAK message sent to resynchronize the peers." (§7,
        /// §6.9.3) A VNAK has been sent; the frame was not delivered.
        case outOfSequence(IAX2FullFrame)

        /// The channel is dead; the frame was dropped without any reply.
        case ignored
    }

    // MARK: Events

    /// Out-of-band notifications for the call layer. Delivered on ``events``.
    public enum Event: Sendable, Equatable {
        /// A frame was retransmitted with the `R` bit set. `attempt` counts
        /// from 1.
        case retransmitted(IAX2FullFrame, attempt: Int)

        /// An outstanding frame was retired, either by a matching ACK or
        /// cumulatively by an inbound ISeqno.
        case acknowledged(oSeqno: UInt8, timestamp: UInt32)

        /// The call leg is dead. Nothing further will be sent on it — in
        /// particular **no HANGUP** (§7, §6.6). The stream finishes after this.
        case failed(ReliableChannelError)
    }

    /// Channel events, buffered without limit so nothing is missed by a
    /// consumer that starts iterating late. Finishes when the channel dies or
    /// ``close()`` is called.
    public nonisolated let events: AsyncStream<Event>

    // MARK: Stored state

    /// The identity of an outstanding frame: its OSeqno **and** the time-stamp
    /// an ACK will echo back (§6.9.1). OSeqno alone is not enough — the five
    /// exempt messages reuse the current OSeqno without advancing it, and after
    /// a modulo-256 wrap the same OSeqno recurs.
    public struct AcknowledgementKey: Hashable, Sendable {
        public let oSeqno: UInt8
        public let timestamp: UInt32

        public init(oSeqno: UInt8, timestamp: UInt32) {
            self.oSeqno = oSeqno
            self.timestamp = timestamp
        }
    }

    private struct Outstanding {
        let frame: IAX2FullFrame
        var attempts: Int
        var timer: Task<Void, Never>?
    }

    private let transport: any DatagramTransport
    private let clock: any Clock<Duration>
    private let configuration: Configuration
    private nonisolated let continuation: AsyncStream<Event>.Continuation

    /// 15-bit call number this peer uses for the call (§8.1.1). Fixed for the
    /// life of the channel.
    public let sourceCallNumber: UInt16

    /// The peer's source call number, echoed back in everything we send. 0
    /// until the peer's first reply reveals it — a NEW has no destination call
    /// number (§6.2.2), and "A POKE MUST have 0 as its destination call number"
    /// (§6.7.1), so 0 is normal rather than malformed.
    public private(set) var destinationCallNumber: UInt16

    /// The next OSeqno that will go out on a non-exempt full frame. "Upon
    /// initialization of a call, its value is 0." (§8.1.1, §7, §6.2.2)
    public private(set) var outboundSequenceNumber: UInt8 = 0

    /// ISeqno as §8.1.1 defines it: "the next expected inbound stream sequence
    /// number". This is the value written into the ISeqno field of everything
    /// we send. See contradiction 1 in the type documentation for why it is not
    /// §7's "highest numbered incoming message that has been received".
    public private(set) var expectedInboundSequenceNumber: UInt8 = 0

    /// Whether the call leg has been torn down (retries exhausted, transport
    /// failure, or ``close()``).
    public private(set) var isDead = false

    /// Why the channel died, if it did.
    public private(set) var failure: ReliableChannelError?

    private var outstanding: [AcknowledgementKey: Outstanding] = [:]

    // MARK: Init

    /// - Parameters:
    ///   - sourceCallNumber: our 15-bit call number for this call (§8.1.1).
    ///     Allocation is IAX-5's job; 1…32767, never 0 (notes §15).
    ///   - destinationCallNumber: the peer's call number, or 0 until known.
    ///   - transport: the datagram seam (AU-5). Never closed by this actor —
    ///     one transport may carry several calls, so shutting it down is the
    ///     client's decision, not the channel's.
    ///   - clock: `ContinuousClock()` in production; a manual clock under test.
    ///   - configuration: retransmission policy.
    public init<C: Clock>(
        sourceCallNumber: UInt16,
        destinationCallNumber: UInt16 = 0,
        transport: any DatagramTransport,
        clock: C,
        configuration: Configuration = Configuration()
    ) where C.Duration == Duration {
        precondition(
            sourceCallNumber <= IAX2FullFrame.maximumCallNumber,
            "source call number is a 15-bit field (RFC 5456 §8.1.1)")
        self.sourceCallNumber = sourceCallNumber
        self.destinationCallNumber = destinationCallNumber
        self.transport = transport
        self.clock = clock
        self.configuration = configuration

        var escapedContinuation: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { continuation in
            escapedContinuation = continuation
        }
        self.events = stream
        self.continuation = escapedContinuation
    }

    // MARK: Introspection

    /// How many frames are still waiting to be acknowledged.
    public var outstandingFrameCount: Int { outstanding.count }

    /// The frames still waiting to be acknowledged, oldest first in
    /// modulo-256 serial order.
    public var outstandingFrames: [IAX2FullFrame] {
        sortedOutstanding(from: oldestOutstandingSeqno() ?? 0).map(\.frame)
    }

    /// How many times a given outstanding frame has been retransmitted, or
    /// `nil` if it is not outstanding.
    public func retransmissionCount(for key: AcknowledgementKey) -> Int? {
        outstanding[key]?.attempts
    }

    /// Learn the peer's call number from its first reply.
    public func setDestinationCallNumber(_ value: UInt16) {
        precondition(
            value <= IAX2FullFrame.maximumCallNumber,
            "destination call number is a 15-bit field (RFC 5456 §8.1.1)")
        destinationCallNumber = value
    }

    // MARK: Sending

    /// Sends one full frame, assigning it the current sequence numbers and — if
    /// it is not one of the five exempt messages — advancing OSeqno and arming
    /// its retransmission timer.
    ///
    /// - Parameter timestamp: milliseconds since the first transmission of the
    ///   call (§8.1.1, §6.2.2). The call clock belongs to the layer above:
    ///   time-stamps "MAY be approximate, but, MUST be in order" (§7), and only
    ///   the call knows its own origin, so this actor never invents one — except
    ///   for the ACKs and VNAKs it generates, which echo the frame they answer.
    /// - Returns: the frame exactly as it went on the wire, including the
    ///   sequence numbers this actor assigned.
    /// - Throws: `ReliableChannelError.channelDead` on a torn-down channel, or
    ///   whatever the transport throws.
    @discardableResult
    public func send(
        type: IAX2FrameType,
        subclass: IAX2Subclass,
        timestamp: UInt32,
        payload: [UInt8] = []
    ) async throws -> IAX2FullFrame {
        guard !isDead else { throw ReliableChannelError.channelDead }

        let frame = IAX2FullFrame(
            sourceCallNumber: sourceCallNumber,
            destinationCallNumber: destinationCallNumber,
            isRetransmission: false,
            timestamp: timestamp,
            oSeqno: outboundSequenceNumber,
            iSeqno: expectedInboundSequenceNumber,
            type: type,
            subclass: subclass,
            payload: payload)

        let wire = IAX2Frame.full(frame)
        try wire.validateForTransmission()
        try await transport.send(wire.encoded())

        // §7: ACK, INVAL, TXCNT, TXACC and VNAK "do not change the message
        // count". They are also never themselves acknowledged — an ACK for an
        // ACK could not terminate — so they get no retransmission timer.
        if !frame.isSequenceNumberExempt {
            outboundSequenceNumber &+= 1
            track(frame)
        }
        return frame
    }

    /// Sends an IAX control message (frame type `0x06`, §8.2.6). All §8.4
    /// subclasses are ≤ 127, so C = 0.
    @discardableResult
    public func send(
        _ message: IAX2Message,
        timestamp: UInt32,
        payload: [UInt8] = []
    ) async throws -> IAX2FullFrame {
        try await send(
            type: .iax, subclass: IAX2Subclass(message), timestamp: timestamp, payload: payload)
    }

    /// Sends a Control frame (frame type `0x04`, §8.3). "These messages MUST
    /// only be sent after an IAX call leg has been ACCEPTed." (§6.3.1)
    @discardableResult
    public func send(
        control: IAX2Control,
        timestamp: UInt32,
        payload: [UInt8] = []
    ) async throws -> IAX2FullFrame {
        try await send(
            type: .control, subclass: IAX2Subclass(control), timestamp: timestamp, payload: payload)
    }

    /// Sends a mini frame (§8.1.2).
    ///
    /// Mini frames are outside the reliability machinery entirely: no sequence
    /// numbers, no acknowledgement, no retransmission. "Mini Frames carry no
    /// control or signaling data… They are sent unreliably." (§8.1.2) Neither
    /// counter moves.
    public func sendMini(timestamp: UInt16, payload: [UInt8]) async throws {
        guard !isDead else { throw ReliableChannelError.channelDead }
        let wire = IAX2Frame.mini(
            IAX2MiniFrame(
                sourceCallNumber: sourceCallNumber, timestamp: timestamp, payload: payload))
        try wire.validateForTransmission()
        try await transport.send(wire.encoded())
    }

    // MARK: Receiving

    /// Feeds one received datagram through the channel.
    ///
    /// - Throws: `IAX2FrameError` if the datagram is not a Full or Mini Frame —
    ///   including `.metaFrame`, which the caller should simply drop (§8.1.3).
    @discardableResult
    public func receive(datagram: Data) async throws -> Inbound {
        await receive(try IAX2Frame.parse(datagram))
    }

    /// Feeds one parsed frame through the channel: retires acknowledged
    /// outbound frames, advances ISeqno, and emits ACKs and VNAKs where the RFC
    /// requires them.
    ///
    /// The caller is responsible for demultiplexing — this actor does not check
    /// call numbers, because deciding which call a datagram belongs to (and
    /// answering unknown ones with INVAL, §6.9.2) is the client's job.
    @discardableResult
    public func receive(_ frame: IAX2Frame) async -> Inbound {
        guard !isDead else { return .ignored }
        switch frame {
        case .mini(let mini):
            // §8.1.2: no sequence numbers, and §6.10 explicitly excludes mini
            // frames from the "MUST be ACKed" rule. Nothing to do.
            return .media(mini)
        case .full(let full):
            return await receiveFull(full)
        }
    }

    private func receiveFull(_ frame: IAX2FullFrame) async -> Inbound {
        // --- 1. Acknowledgement processing -------------------------------
        if frame.iaxMessage == .ack {
            // §6.9.1: an ACK "MUST return the same time-stamp it received. This
            // time-stamp allows the originating peer to determine to which
            // message the ACK is responding." Matching is therefore on the
            // echoed time-stamp, never on OSeqno alone — an ACK's own OSeqno is
            // just the peer's current counter, unchanged, and its ISeqno is
            // shared by every frame in flight.
            retireAcknowledged(byEchoedTimestamp: frame.timestamp)
            return .consumed(frame)
        }

        // Every other full frame carries an ISeqno that acknowledges our
        // stream cumulatively: "the incoming message counter MUST be used to
        // acknowledge all the messages up to that sequence number that have
        // been sent." (§7) Strictly-before, per the §8.1.1/§7 off-by-one
        // resolution in the type documentation.
        retireAcknowledged(before: frame.iSeqno)

        // --- 2. VNAK: a retransmission request, not a delivery -----------
        if frame.iaxMessage == .vnak {
            await retransmitAfterVNAK(iSeqno: frame.iSeqno)
            return .consumed(frame)
        }

        // --- 3. Sequence-exempt inbound messages -------------------------
        // The §7 exemption is symmetric: a peer's ACK, INVAL, TXCNT, TXACC or
        // VNAK did not advance *its* OSeqno, so it must not advance our
        // expected inbound counter either — otherwise the peer's next real
        // frame would look like a duplicate. They are not ACKed either
        // ("Receipt of an ACK requires no action", §6.9.1; an INVAL means the
        // call is already gone, §6.9.2).
        if frame.isSequenceNumberExempt {
            return .deliver(frame)
        }

        // --- 4. Sequencing (§6.9.3, §8.1.1) ------------------------------
        if frame.oSeqno == expectedInboundSequenceNumber {
            expectedInboundSequenceNumber &+= 1
            await acknowledge(frame)
            return .deliver(frame)
        }

        if Self.isBefore(frame.oSeqno, expectedInboundSequenceNumber) {
            // Already seen: the peer retransmitted because our ACK went
            // missing. Re-ACK so its timer stops, but do not deliver twice and
            // do not move the counter backwards.
            await acknowledge(frame)
            return .duplicate(frame)
        }

        // A gap. "A message is considered out of sequence if the received
        // iseqno is different than the expected iseqno." (§6.9.3) "If a message
        // is received out of order, it MUST be ignored and a VNAK message sent
        // to resynchronize the peers." (§7)
        await sendVNAK(echoing: frame)
        return .outOfSequence(frame)
    }

    // MARK: Acknowledgement bookkeeping

    /// Retires the outstanding frame an ACK names by echoing its time-stamp,
    /// plus everything sent before it (acknowledgement is cumulative, §7).
    ///
    /// An ACK whose time-stamp matches nothing outstanding is ignored: it is
    /// either a duplicate ACK for a frame already retired, or it does not
    /// belong to any frame we sent. Deliberately no fallback to OSeqno-only
    /// matching — that would let a stray ACK retire the wrong frame.
    private func retireAcknowledged(byEchoedTimestamp timestamp: UInt32) {
        // If two in-flight frames share a time-stamp (the call clock advances
        // by whole milliseconds, so two frames sent inside the same millisecond
        // can), the ACK is for the oldest of them; the peer will ACK the other
        // separately.
        guard
            let oldest = sortedOutstanding(from: oldestOutstandingSeqno() ?? 0)
                .first(where: { $0.frame.timestamp == timestamp })
        else { return }
        retire(upToAndIncluding: oldest.frame.oSeqno)
    }

    /// Retires everything sent with an OSeqno strictly before `iSeqno`.
    ///
    /// Strictly-before is the tolerant reading: a peer following §8.1.1 sends
    /// "next expected", so `iSeqno` names the first frame it has *not* seen; a
    /// peer following §7 sends "highest received", so it looks one low and its
    /// newest acknowledgement simply arrives one frame later. Neither is an
    /// error, and neither tears the call down.
    private func retireAcknowledged(before iSeqno: UInt8) {
        for (key, entry) in outstanding where Self.isBefore(key.oSeqno, iSeqno) {
            entry.timer?.cancel()
            outstanding.removeValue(forKey: key)
            continuation.yield(.acknowledged(oSeqno: key.oSeqno, timestamp: key.timestamp))
        }
    }

    /// Retires `oSeqno` and everything before it.
    private func retire(upToAndIncluding oSeqno: UInt8) {
        for (key, entry) in outstanding
        where key.oSeqno == oSeqno || Self.isBefore(key.oSeqno, oSeqno) {
            entry.timer?.cancel()
            outstanding.removeValue(forKey: key)
            continuation.yield(.acknowledged(oSeqno: key.oSeqno, timestamp: key.timestamp))
        }
    }

    // MARK: Channel-generated replies

    /// Sends the ACK an inbound full frame requires, echoing its time-stamp
    /// (§6.9.1). ACK does not advance OSeqno and is not itself tracked.
    private func acknowledge(_ frame: IAX2FullFrame) async {
        await sendUnreliably(.ack, timestamp: frame.timestamp)
    }

    /// Sends a VNAK in response to an out-of-sequence frame (§6.9.3, §7).
    ///
    /// RFC 5456 assigns no time-stamp rule to VNAK. We echo the offending
    /// frame's time-stamp, for the same reason an ACK does: it tells the peer
    /// unambiguously which arrival triggered the resynchronisation request. The
    /// VNAK's *ISeqno* is what carries the protocol meaning — it is our
    /// unchanged "next expected" counter, i.e. the first frame we are missing.
    private func sendVNAK(echoing frame: IAX2FullFrame) async {
        await sendUnreliably(.vnak, timestamp: frame.timestamp)
    }

    /// Sends one of the sequence-exempt messages, swallowing transport failure
    /// into a channel teardown rather than throwing into the receive path.
    private func sendUnreliably(_ message: IAX2Message, timestamp: UInt32) async {
        assert(
            IAX2Message.sequenceNumberExempt.contains(message),
            "only the §7 exempt messages may be sent outside the reliability machinery")
        do {
            try await send(message, timestamp: timestamp)
        } catch {
            fail(.transportFailed(String(describing: error)))
        }
    }

    /// "On receipt of a VNAK, a peer MUST retransmit all frames with a higher
    /// sequence number than the VNAK message's iseqno." (§6.9.3)
    ///
    /// "At or after", not "strictly after" — see contradiction 4 in the type
    /// documentation. Retransmitting one extra frame is harmless; failing to
    /// retransmit the frame the peer is actually missing would deadlock the
    /// stream. The backoff timers are left alone: this is an out-of-band
    /// retransmission on the peer's demand, not a retry.
    private func retransmitAfterVNAK(iSeqno: UInt8) async {
        let due = sortedOutstanding(from: iSeqno).filter { !Self.isBefore($0.frame.oSeqno, iSeqno) }
        for entry in due {
            let copy = entry.frame.retransmitted()
            do {
                try await transport.send(IAX2Frame.full(copy).encoded())
            } catch {
                fail(.transportFailed(String(describing: error)))
                return
            }
            continuation.yield(.retransmitted(copy, attempt: entry.attempts))
        }
    }

    // MARK: Retransmission

    /// Adds a frame to the outstanding table and arms its backoff timer.
    private func track(_ frame: IAX2FullFrame) {
        let key = AcknowledgementKey(oSeqno: frame.oSeqno, timestamp: frame.timestamp)
        outstanding[key] = Outstanding(frame: frame, attempts: 0, timer: nil)

        let clock = self.clock
        let configuration = self.configuration
        let timer = Task { [weak self] in
            var interval = configuration.initialRetryInterval
            while true {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return  // Retired, or the channel was torn down.
                }
                guard let self else { return }
                guard await self.retryTimerFired(key: key) else { return }
                interval = min(interval * 2, configuration.maximumRetryInterval)
            }
        }
        outstanding[key]?.timer = timer
    }

    /// One backoff deadline elapsed without an acknowledgement.
    ///
    /// The frame gets `maximumRetries` retransmissions, at 500 ms, 1 s, 2 s and
    /// 4 s after the original by default. The deadline *after* the last
    /// retransmission is what declares the call dead — "If no acknowledgment is
    /// received after a locally configured number of retries (default 4)"
    /// (§7) — so the fourth retry is given the same chance to be answered as the
    /// three before it.
    ///
    /// - Returns: `true` if the timer should re-arm.
    private func retryTimerFired(key: AcknowledgementKey) async -> Bool {
        guard !isDead, var entry = outstanding[key] else { return false }

        guard entry.attempts < configuration.maximumRetries else {
            fail(
                .retriesExhausted(
                    oSeqno: key.oSeqno, timestamp: key.timestamp, attempts: entry.attempts))
            return false
        }

        entry.attempts += 1
        outstanding[key] = entry

        // §8.1.1: the retransmitted copy differs from the original in the R bit
        // and nothing else — OSeqno and time-stamp included, because those are
        // what the peer matches on.
        let copy = entry.frame.retransmitted()
        do {
            try await transport.send(IAX2Frame.full(copy).encoded())
        } catch {
            fail(.transportFailed(String(describing: error)))
            return false
        }
        // An ACK may have arrived across that suspension point.
        guard outstanding[key] != nil else { return false }
        continuation.yield(.retransmitted(copy, attempt: entry.attempts))
        return true
    }

    // MARK: Teardown

    /// Tears the call leg down.
    ///
    /// Deliberately silent. §7: "the call leg SHOULD be considered unusable and
    /// the call MUST be torn down without any further interaction on this call
    /// leg." §6.6: "if the reliable transport procedures determine that
    /// messaging cannot be maintained, the call leg MUST be torn down without
    /// any other indications over the errant IAX call leg." **No HANGUP is
    /// sent** — the peer has stopped answering, and a HANGUP to a peer that is
    /// not listening is exactly the "other indication" §6.6 forbids.
    ///
    /// The transport is left open: it may carry other calls, and it is the
    /// client's to close.
    private func fail(_ error: ReliableChannelError) {
        guard !isDead else { return }
        isDead = true
        failure = error
        cancelAllTimers()
        continuation.yield(.failed(error))
        continuation.finish()
    }

    /// Stops every timer and finishes ``events``. Idempotent. The transport is
    /// not closed — see ``fail(_:)``.
    public func close() {
        guard !isDead else { return }
        isDead = true
        cancelAllTimers()
        continuation.finish()
    }

    private func cancelAllTimers() {
        for entry in outstanding.values { entry.timer?.cancel() }
        outstanding.removeAll()
    }

    // MARK: Serial-number arithmetic (§8.1.1, notes §9)

    /// Is `a` strictly before `b` in modulo-256 sequence space?
    ///
    /// Both counters "silently reset to 0" on overflow (§8.1.1), so every
    /// comparison must be made in serial-number space: `a` is before `b` when
    /// the unsigned distance from `a` to `b` is non-zero and less than half the
    /// space. Plain integer comparison would break a call the moment OSeqno
    /// wrapped past 255.
    static func isBefore(_ a: UInt8, _ b: UInt8) -> Bool {
        let distance = b &- a
        return distance != 0 && distance < 128
    }

    /// The outstanding frames in serial order, starting from `reference`.
    private func sortedOutstanding(from reference: UInt8) -> [Outstanding] {
        outstanding.values.sorted { ($0.frame.oSeqno &- reference) < ($1.frame.oSeqno &- reference) }
    }

    /// The oldest outstanding OSeqno in serial order, if any.
    private func oldestOutstandingSeqno() -> UInt8? {
        let seqnos = outstanding.keys.map(\.oSeqno)
        guard let candidate = seqnos.first else { return nil }
        return seqnos.reduce(candidate) { Self.isBefore($1, $0) ? $1 : $0 }
    }
}

// MARK: - Frame helpers

extension IAX2FullFrame {
    /// Whether this frame is one of the five messages that "do not change the
    /// message count" (RFC 5456 §7): ACK, INVAL, TXCNT, TXACC, VNAK. The set is
    /// `IAX2Message.sequenceNumberExempt`, defined alongside the subclass table
    /// in `IAX2Frame.swift`.
    ///
    /// Only frames of type `.iax` can be exempt — a Control, Voice or DTMF
    /// frame always advances the counter.
    var isSequenceNumberExempt: Bool {
        guard let message = iaxMessage else { return false }
        return IAX2Message.sequenceNumberExempt.contains(message)
    }
}
