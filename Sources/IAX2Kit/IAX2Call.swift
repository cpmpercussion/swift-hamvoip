// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Call number allocation (RFC 5456 §8.1.1, §4, §6.2.2; notes §15)

/// Why a source call number could not be allocated.
public enum IAX2CallNumberError: Error, Equatable, CustomStringConvertible {
    /// Every value in 1…32767 is already in use by an active call.
    case exhausted(inUse: Int)

    /// A call number outside the allocatable range was offered for release or
    /// reservation. 0 is excluded deliberately — see
    /// ``IAX2CallNumberAllocator``.
    case outOfRange(UInt16)

    public var description: String {
        switch self {
        case .exhausted(let inUse):
            return
                "no free IAX2 source call number: all \(inUse) values in "
                + "1…32767 are in use (RFC 5456 §8.1.1)"
        case .outOfRange(let value):
            return
                "\(value) is not a usable IAX2 source call number; the range is "
                + "1…32767 (RFC 5456 §8.1.1, §8.1.3; notes §15)"
        }
    }
}

/// Hands out the 15-bit source call numbers that identify a call leg
/// (RFC 5456 §8.1.1, notes §15).
///
/// ## The range, and why 0 is missing
///
/// Both call-number fields are 15 bits, so the representable range is
/// 0…32767. **0 is not usable as a source call number.** Meta Frames are
/// identified by their first 16 bits being all zero (§8.1.3.1, §8.1.3.2), so a
/// Mini Frame with source call number 0 would be indistinguishable from a
/// trunk header. Allocation therefore runs 1…32767.
///
/// *RFC ambiguous:* the RFC never states an allocation range. The exclusion of
/// 0 is forced by the Meta Frame detection rule rather than written down
/// anywhere (notes §15, trap 17).
///
/// ## Uniqueness and reuse
///
/// > "The source call number for an active call MUST NOT be in use by another
/// > call on the same client." (§8.1.1)
///
/// > "Call numbers MAY be reused once a call is no longer active, i.e., either
/// > when there is positive acknowledgment that the call has been destroyed or
/// > when all possible timeouts for the call have expired." (§8.1.1)
///
/// One allocator instance is the uniqueness domain — share one across every
/// call that shares a transport (or, more conservatively, across the whole
/// client) and no two live calls can collide. ``IAX2Call`` returns its number
/// on ``IAX2Call/close()``, not merely when the call dies, because that is the
/// point at which the caller has stated it is finished with the leg.
///
/// Allocation walks a rotating cursor rather than always taking the lowest
/// free value, so a number is not handed straight back out to a new call while
/// stray retransmissions of the old one may still be in flight. The cursor is
/// deterministic, which is what makes fixture-driven tests possible.
public actor IAX2CallNumberAllocator {
    /// The lowest allocatable source call number. 0 is excluded — see the type
    /// documentation.
    public static let minimum: UInt16 = 1

    /// The highest allocatable source call number: a 15-bit field (§8.1.1).
    public static let maximum: UInt16 = IAX2FullFrame.maximumCallNumber

    /// The full allocatable range, 1…32767.
    public static let range: ClosedRange<UInt16> = minimum...maximum

    private var inUse: Set<UInt16> = []
    private var cursor: UInt16 = IAX2CallNumberAllocator.minimum

    public init() {}

    /// How many call numbers are currently held.
    public var allocatedCount: Int { inUse.count }

    /// Whether a particular number is currently held.
    public func isAllocated(_ number: UInt16) -> Bool { inUse.contains(number) }

    /// Reserves and returns a free source call number in 1…32767.
    ///
    /// - Throws: ``IAX2CallNumberError/exhausted(inUse:)`` when every value is
    ///   held. Exhaustion is a thrown error rather than a trap precisely
    ///   because the value flows into `IAX2FullFrame`, whose range check is a
    ///   `precondition`.
    public func allocate() throws -> UInt16 {
        let span = Int(Self.maximum - Self.minimum) + 1
        for _ in 0..<span {
            let candidate = cursor
            cursor = candidate == Self.maximum ? Self.minimum : candidate + 1
            if !inUse.contains(candidate) {
                inUse.insert(candidate)
                return candidate
            }
        }
        throw IAX2CallNumberError.exhausted(inUse: inUse.count)
    }

    /// Reserves one specific number, for a caller that must pin it (a replayed
    /// capture, say).
    public func reserve(_ number: UInt16) throws {
        guard Self.range.contains(number) else {
            throw IAX2CallNumberError.outOfRange(number)
        }
        guard !inUse.contains(number) else {
            throw IAX2CallNumberError.exhausted(inUse: inUse.count)
        }
        inUse.insert(number)
    }

    /// Returns a number to the pool. Releasing a number that is not held, or
    /// one outside the range, is a no-op — teardown paths run more than once.
    public func release(_ number: UInt16) {
        inUse.remove(number)
    }
}

// MARK: - Call state (RFC 5456 §6.2, §6.3)

/// Where an outbound call leg is in the RFC 5456 §6.2 setup sequence.
///
/// ```
/// idle → newSent → [authRequested → authReplied] → accepted → answered → up
///                                    ↓ REJECT
///                                 rejected → dead
/// up → hangupSent | receivedHangup → dead
/// ```
///
/// `answered`, `rejected`, `hangupSent` and `receivedHangup` are traversed
/// rather than rested in: each is entered and then immediately left for `up`
/// or `dead`. They are still distinct states, and each is reported on
/// ``IAX2Call/events``, because they are the only record of *why* the call
/// moved — a consumer that sees `.stateChanged(from: .accepted, to: .answered)`
/// knows the peer answered, which `.up` alone does not tell it.
public enum IAX2CallState: String, Sendable, Equatable, CaseIterable, CustomStringConvertible {
    /// Nothing sent yet; no call leg exists.
    case idle
    /// NEW sent, awaiting ACCEPT, AUTHREQ, REJECT or HANGUP (§6.2.2).
    case newSent
    /// AUTHREQ received; the challenge is being answered (§6.2.7).
    case authRequested
    /// AUTHREP sent, awaiting ACCEPT or REJECT (§6.2.6).
    case authReplied
    /// ACCEPT received and ACKed (§6.2.3). Control frames are legal from here
    /// on ("These messages MUST only be sent after an IAX call leg has been
    /// ACCEPTed", §6.3.1), and media may arrive.
    case accepted
    /// Control ANSWER received (§6.3.4).
    case answered
    /// The call is established; media may flow in both directions.
    case up
    /// REJECT received and ACKed (§6.2.4).
    case rejected
    /// We sent HANGUP; the leg is destroyed without waiting for the ACK
    /// (§6.2.5).
    case hangupSent
    /// The peer sent HANGUP; we ACKed and destroyed the leg (§6.2.5).
    case receivedHangup
    /// The call leg no longer exists. Anything further referencing it is
    /// answered with INVAL (§6.2.5).
    case dead

    public var description: String { rawValue }

    /// States in which the leg exists and media/DTMF may be sent.
    ///
    /// `accepted` counts: the §9.6 flow has the callee sending a full voice
    /// frame immediately after ACCEPT, before any RINGING or ANSWER.
    public var isEstablished: Bool {
        self == .accepted || self == .answered || self == .up
    }

    /// States in which a call leg exists at the peer, so a HANGUP would mean
    /// something.
    public var isLive: Bool {
        switch self {
        case .idle, .rejected, .hangupSent, .receivedHangup, .dead: return false
        case .newSent, .authRequested, .authReplied, .accepted, .answered, .up: return true
        }
    }
}

// MARK: - Termination

/// Why a call leg stopped existing. Delivered once, as the final
/// ``IAX2CallEvent/ended(_:)`` event, immediately before ``IAX2Call/events``
/// finishes.
public enum IAX2CallTermination: Sendable, Equatable, CustomStringConvertible {
    /// We sent HANGUP (§6.2.5).
    case localHangup(cause: String?, causeCode: UInt8?)
    /// The peer sent HANGUP; we ACKed it and destroyed the leg (§6.2.5).
    case remoteHangup(cause: String?, causeCode: UInt8?)
    /// The peer sent REJECT; we ACKed it and destroyed the leg (§6.2.4).
    case rejected(cause: String?, causeCode: UInt8?)
    /// The peer sent INVAL: "Upon receipt of an INVAL, a peer MUST destroy its
    /// side of a call." (§6.9.2)
    case invalidated
    /// The peer never brought the call up within the local connect deadline.
    /// **No HANGUP is sent** — see ``IAX2Call/Configuration/connectTimeout``.
    case connectTimedOut(Duration)
    /// The reliable transport gave up (retries exhausted, or a transport
    /// write failed). Torn down silently, without a HANGUP (§7, §6.6).
    case channelFailed(ReliableChannelError)
    /// The peer did something the FSM forbids — a Control frame before the
    /// call was ACCEPTed, say (§6.3.1).
    case protocolError(IAX2CallError)
    /// ``IAX2Call/close()`` was called on a live call.
    case closed

    public var description: String {
        switch self {
        case .localHangup(let cause, let code):
            return "local HANGUP (\(Self.causeText(cause, code)))"
        case .remoteHangup(let cause, let code):
            return "remote HANGUP (\(Self.causeText(cause, code)))"
        case .rejected(let cause, let code):
            return "REJECT (\(Self.causeText(cause, code)))"
        case .invalidated:
            return "INVAL received; call destroyed (RFC 5456 §6.9.2)"
        case .connectTimedOut(let timeout):
            return "the peer did not answer within \(timeout)"
        case .channelFailed(let error):
            return "reliable transport failed: \(error)"
        case .protocolError(let error):
            return "protocol error: \(error)"
        case .closed:
            return "closed locally"
        }
    }

    private static func causeText(_ cause: String?, _ code: UInt8?) -> String {
        switch (cause, code) {
        case (let cause?, let code?): return "\(cause), cause code \(code)"
        case (let cause?, nil): return cause
        case (nil, let code?): return "cause code \(code)"
        case (nil, nil): return "no cause given"
        }
    }
}

/// Thrown by ``IAX2Call/waitUntilUp()`` when the call ended instead of coming
/// up. A separate type from ``IAX2CallError`` so the two can refer to each
/// other without an `indirect` enum.
public struct IAX2CallEnded: Error, Equatable, CustomStringConvertible {
    public let reason: IAX2CallTermination

    public init(reason: IAX2CallTermination) {
        self.reason = reason
    }

    public var description: String { "the call ended: \(reason)" }
}

// MARK: - Errors

/// A call-level failure: an FSM rule broken, or a message this client cannot
/// answer.
public enum IAX2CallError: Error, Equatable, CustomStringConvertible {
    /// A transition the FSM does not allow, from either side. Thrown, never
    /// silently ignored — a Control ANSWER before the call was ACCEPTed
    /// violates §6.3.1 and the peer needs to be treated as broken, not
    /// humoured.
    case illegalTransition(from: IAX2CallState, attempted: String)

    /// A send that requires an established leg was attempted before one
    /// existed (or after it was gone).
    case notEstablished(state: IAX2CallState)

    /// AUTHREQ arrived offering no method this client implements. There is no
    /// plaintext path (§8.6.13, §10), and RSA (`0x0004`) is out of scope for
    /// v1.
    case unsupportedAuthentication(offered: IAX2Auth.AuthMethods)

    /// AUTHREQ arrived without the CHALLENGE IE the RFC requires (§8.6.14).
    case missingChallenge

    /// AUTHREQ arrived but no shared secret was configured for this call, so
    /// no MD5 RESULT can be computed (§8.6.15).
    case missingSecret

    /// A full frame's IE block would not parse (§8.6).
    case malformedInformationElements(String)

    /// The datagram transport refused a write.
    case transportFailed(String)

    public var description: String {
        switch self {
        case .illegalTransition(let from, let attempted):
            return "illegal call transition: \(attempted) is not valid in state '\(from)'"
        case .notEstablished(let state):
            return "the call leg is not established (state '\(state)')"
        case .unsupportedAuthentication(let offered):
            let hex = String(format: "0x%04x", offered.rawValue)
            return
                "AUTHREQ offered AUTHMETHODS \(hex); this client implements MD5 (0x0002) only. "
                + "RSA (0x0004) is out of scope for v1 and plaintext (0x0001) was withdrawn "
                + "by RFC 5456 §10 — there is no plaintext path to fall back to."
        case .missingChallenge:
            return "AUTHREQ carried no CHALLENGE information element (RFC 5456 §8.6.14)"
        case .missingSecret:
            return "AUTHREQ received but no shared secret is configured for this call"
        case .malformedInformationElements(let detail):
            return "malformed information element block: \(detail)"
        case .transportFailed(let detail):
            return "transport failed: \(detail)"
        }
    }
}

// MARK: - Events

/// Everything a call tells the layers above it. Delivered on
/// ``IAX2Call/events``, buffered without limit, finished after
/// ``ended(_:)``.
///
/// This is the seam IAX-6 (voice), IAX-7 (DTMF) and IAX-8 (`IAX2Client`) build
/// on. It carries no audio and no DTMF decoding of its own — ``media(_:)``
/// hands over the frames untouched and ``other(_:)`` hands over everything
/// else the FSM had no use for.
public enum IAX2CallEvent: Sendable, Equatable {
    /// Every FSM transition, in order.
    case stateChanged(from: IAX2CallState, to: IAX2CallState)

    /// AUTHREQ arrived (§6.2.7). Reported before the AUTHREP is computed, so
    /// a failure to authenticate is still visible in the event history.
    case challenged(challenge: String, methods: IAX2Auth.AuthMethods)

    /// ACCEPT arrived and was ACKed (§6.2.3). `format` is the FORMAT IE the
    /// peer chose — "The ACCEPT message MUST include the 'format' IE" (§6.2.3)
    /// — or `nil` if a nonconforming peer omitted it.
    case accepted(format: MediaFormat?)

    /// A Control frame arrived and was ACKed (§8.3): RINGING, ANSWER,
    /// PROCEEDING, BUSY, Control HANGUP, and so on.
    ///
    /// Note ``IAX2Control/hangup`` here is Control subclass `0x01`, which is
    /// **not** the IAX HANGUP that tears a leg down (notes trap 18). It is
    /// reported and nothing more.
    case control(IAX2Control)

    /// An inbound media frame — a Mini Frame, or a full Voice/Video/Comfort
    /// Noise frame — passed through untouched. IAX-6 owns what happens next.
    case media(IAX2Frame)

    /// An in-sequence full frame the FSM itself had no use for: DTMF (IAX-7),
    /// Text, Image, HTML, and IAX messages outside the call-setup set. Already
    /// ACKed by the reliable channel.
    case other(IAX2FullFrame)

    /// The call leg is gone. The last event; the stream finishes after it.
    case ended(IAX2CallTermination)
}

// MARK: - Call request

/// What to put in the NEW message (RFC 5456 §6.2.2, §8.6).
///
/// IAX-8's `IAX2Destination` maps onto this; keeping them separate keeps the
/// address of a node (host, port) out of a type that only describes a call.
public struct IAX2CallRequest: Sendable, Equatable {
    /// CALLED NUMBER (`0x01`) — the node or extension being called (§8.6.1).
    /// §6.2.2 marks it Required on NEW.
    public var calledNumber: String

    /// USERNAME (`0x06`) — the account the peer should authenticate us as
    /// (§8.6.6). Omitted from the NEW when `nil`.
    public var username: String?

    /// The shared secret answering an MD5 CHALLENGE (§8.6.15). Never sent:
    /// it is hashed with the challenge and only the digest goes on the wire.
    /// There is no plaintext PASSWORD path (§8.6.13, §10).
    public var secret: String?

    /// CALLING NUMBER (`0x02`) — our number, if we have one (§8.6.2).
    public var callingNumber: String?

    /// CALLING NAME (`0x04`) — a display name, e.g. a callsign (§8.6.4).
    public var callingName: String?

    /// CALLED CONTEXT (`0x05`) — optional; "Default" is assumed by the peer if
    /// absent (§6.2.2, notes §16).
    public var calledContext: String?

    /// LANGUAGE (`0x0a`) — optional (§8.6.9).
    public var language: String?

    /// CAPABILITY (`0x08`) — every codec we can accept, OR-ed (§8.6.7).
    public var capability: MediaFormat

    /// FORMAT (`0x09`) — the codec we prefer. "Only one CODEC MUST be
    /// specified." (§8.6.8)
    public var format: MediaFormat

    public init(
        calledNumber: String,
        username: String? = nil,
        secret: String? = nil,
        callingNumber: String? = nil,
        callingName: String? = nil,
        calledContext: String? = nil,
        language: String? = nil,
        capability: MediaFormat = .g711MuLaw,
        format: MediaFormat = .g711MuLaw
    ) {
        self.calledNumber = calledNumber
        self.username = username
        self.secret = secret
        self.callingNumber = callingNumber
        self.callingName = callingName
        self.calledContext = calledContext
        self.language = language
        self.capability = capability
        self.format = format
    }

    /// The IE block of the NEW message, in wire order.
    ///
    /// VERSION is first and is not optional: "A NEW message MUST include the
    /// 'version' IE, and it MUST be the first IE; the order of other IEs is
    /// unspecified." (§6.2.2, §8.6.10) The Q.931 caller-ID trio —
    /// CALLINGPRES (`0x26`), CALLINGTON (`0x27`), CALLINGTNS (`0x28`) — is
    /// included because §8.6.29–§8.6.31 each say the IE "MUST be sent with IAX
    /// NEW messages".
    ///
    /// CODEC PREFS (`0x2d`) is deliberately **not** sent: §6.2.2's table marks
    /// it Required while §8.6.35 says it "MAY be sent" and that "If the CODEC
    /// PREFS information element is absent, CODEC negotiation takes place via
    /// the CAPABILITY and FORMAT information elements". Those contradict; we
    /// negotiate with CAPABILITY + FORMAT, as the notes direct (§16).
    public func newInformationElements() -> [InformationElement] {
        var elements: [InformationElement] = [
            // "The 'version' information element is used to indicate the
            // protocol version… the value 2." (§8.6.10)
            .version(IAX2Call.protocolVersion),
            .calledNumber(calledNumber),
        ]
        if let calledContext { elements.append(.calledContext(calledContext)) }
        if let username { elements.append(.username(username)) }
        if let callingNumber { elements.append(.callingNumber(callingNumber)) }
        if let callingName { elements.append(.callingName(callingName)) }
        if let language { elements.append(.language(language)) }
        elements.append(.capability(capability))
        elements.append(.format(format))
        // §8.6.29: 0x00 = "Allowed user/number not screened".
        elements.append(.callingPres(0x00))
        // §8.6.30: 0x00 = "Unknown" type of number.
        elements.append(.callingTON(0x00))
        // §8.6.31: Unknown plan / User Specified network — the value the notes
        // settle on for an IE whose documented layout cannot hold anything
        // longer (notes §7, CALLINGTNS).
        elements.append(.callingTNS(.unknown))
        return elements
    }
}

// MARK: - IAX2Call

/// One outbound IAX2 call leg: the RFC 5456 §6.2 state machine, the read loop
/// that feeds it, and the PING/LAGRQ responders it owes the peer.
///
/// ```
/// idle → newSent → [authRequested → authReplied] → accepted → answered → up
///                                    ↓ REJECT
///                                 rejected → dead
/// up → hangupSent | receivedHangup → dead
/// ```
///
/// This actor composes the four layers below it and adds nothing to the wire
/// that they do not already model:
///
/// - `IAX2Frame` parses and serialises;
/// - `InformationElement` codes the IE block of every signalling message;
/// - `ReliableChannel` owns OSeqno/ISeqno, ACKs inbound full frames, and
///   retransmits ours;
/// - `IAX2Auth` computes the MD5 response to a CHALLENGE.
///
/// It deliberately does **not** implement the voice path (IAX-6) or DTMF
/// (IAX-7). Inbound media arrives as ``IAX2CallEvent/media(_:)``; outbound
/// frames go through ``send(type:subclass:timestamp:payload:)`` and
/// ``sendMini(timestamp:payload:)``, which are codec-agnostic.
///
/// ## Demultiplexing, and why it lives here
///
/// `ReliableChannel` never reads the transport, because one UDP association
/// may carry several calls (§1.1, §3) and a channel knows about exactly one.
/// So this actor runs the read loop and the demux:
///
/// 1. parse the datagram — a Meta Frame or a truncated datagram is dropped
///    (§8.1.3; the RFC defines no message for refusing a Meta Frame);
/// 2. a **full frame** belongs to this call when its *destination* call number
///    is ours and its *source* is the peer's — "Call legs are labeled with a
///    pair of identifiers" (§6.2.1, §4, notes §15). Until the peer's first
///    reply reveals its number, any source is accepted and the number learned
///    from it;
/// 3. a **mini frame** carries no destination call number at all (§8.1.2), so
///    it is matched on the peer's source call number alone;
/// 4. anything else is answered with INVAL (§6.9.2), as is anything at all
///    once this leg is dead (§6.2.5).
///
/// A client that fans one transport out to several calls (IAX-8) should build
/// the calls with `readsTransport: false` and drive them with
/// ``deliver(datagram:)`` instead; the demux rule above is then the
/// multiplexer's to apply, and this actor's ``sourceCallNumber`` is the key.
///
/// ## The connect deadline
///
/// RFC 5456 specifies no call-setup timeout. This one is local policy, and it
/// exists because the layer below cannot supply it: `NWConnection` treats an
/// unreachable peer as a recoverable `.waiting` condition and retries
/// internally, so a dead node makes `send` hang rather than fail and the
/// transport never surfaces anything. The deadline runs on the injected clock
/// from the NEW until the peer creates its side of the leg — that is, until
/// the ACCEPT; when it expires the leg is torn down **silently — no HANGUP**,
/// on the same reasoning as §6.6 and §7 give for retransmission exhaustion: a
/// peer that has not created a leg is not owed a farewell it will not hear.
///
/// It deliberately does **not** bound ringing. Once the call is ACCEPTed the
/// peer has proved it is there, and "the called party's service… is being
/// alerted to the call" (§6.3.3) may legitimately take far longer than any
/// reachability deadline; from that point a peer that dies is detected by the
/// reliable channel's retransmission ladder instead (§7). A caller that wants
/// to give up on an unanswered ring imposes that policy itself.
public actor IAX2Call {

    /// VERSION IE (`0x0b`) payload: "the value 2" (§8.6.10).
    public static let protocolVersion: UInt16 = 0x0002

    /// CAUSECODE 16, "Normal call clearing" — the Q.931 code for a
    /// user-initiated hangup (§8.6.33, notes §7).
    public static let normalClearingCauseCode: UInt8 = 16

    // MARK: Configuration

    public struct Configuration: Sendable, Equatable {
        /// How long the peer has, from the NEW, to accept the call leg.
        ///
        /// Local policy: RFC 5456 gives no call-setup timeout anywhere. The
        /// default is 10 s, comfortably longer than the reliable channel's own
        /// 500 ms → 4 s retransmission ladder (§7, §7.2.1) so that a silent
        /// peer normally surfaces as retransmission exhaustion, and this
        /// deadline only catches the case where signalling *is* flowing but the
        /// leg is never created. Cancelled by the ACCEPT — it does not bound
        /// ringing. See the type documentation.
        public var connectTimeout: Duration

        /// Retransmission policy handed to the call's `ReliableChannel`.
        public var channel: ReliableChannel.Configuration

        public init(
            connectTimeout: Duration = .seconds(10),
            channel: ReliableChannel.Configuration = ReliableChannel.Configuration()
        ) {
            self.connectTimeout = connectTimeout
            self.channel = channel
        }
    }

    // MARK: Stored state

    /// Our 15-bit source call number for this leg (§8.1.1). Fixed for the life
    /// of the call.
    public nonisolated let sourceCallNumber: UInt16

    /// What this call asked for in its NEW.
    public nonisolated let request: IAX2CallRequest

    /// Call events, buffered without limit so nothing is missed by a consumer
    /// that starts iterating late. Finishes after ``IAX2CallEvent/ended(_:)``.
    public nonisolated let events: AsyncStream<IAX2CallEvent>

    /// The FSM's current state.
    public private(set) var state: IAX2CallState = .idle

    /// The peer's source call number, learned from its first reply. 0 until
    /// then — a NEW has no destination call number, because "the remote peer's
    /// source call identifier is not created until after receipt of this
    /// frame" (§6.2.2).
    public private(set) var destinationCallNumber: UInt16 = 0

    /// The FORMAT IE from the ACCEPT (§6.2.3) — the codec the peer chose.
    public private(set) var negotiatedFormat: MediaFormat?

    /// Why the call ended, once it has.
    public private(set) var termination: IAX2CallTermination?

    private let transport: any DatagramTransport
    private let clock: any Clock<Duration>
    private let configuration: Configuration
    private let channel: ReliableChannel
    private let allocator: IAX2CallNumberAllocator?
    private let readsTransport: Bool
    private nonisolated let continuation: AsyncStream<IAX2CallEvent>.Continuation

    /// Milliseconds elapsed since this actor was created, on the injected
    /// clock. The call's own time-stamp origin is a fixed offset from it.
    private let elapsedMillisecondsSinceInit: @Sendable () -> UInt32

    /// The value of ``elapsedMillisecondsSinceInit`` at "the first
    /// transmission of the call" (§8.1.1, §6.2.2) — i.e. when the NEW went
    /// out, which is where the call's 32-bit millisecond clock reads zero.
    private var timestampOrigin: UInt32 = 0

    private var readTask: Task<Void, Never>?
    private var channelEventTask: Task<Void, Never>?
    private var connectDeadlineTask: Task<Void, Never>?
    private var upWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var didReleaseCallNumber = false

    // MARK: Init

    /// - Parameters:
    ///   - sourceCallNumber: our 15-bit call number. **Must be in 1…32767**
    ///     (§8.1.1, notes §15) — the frame layer enforces the 15-bit bound
    ///     with a `precondition`, so obtain this from
    ///     ``IAX2CallNumberAllocator`` (or ``outbound(allocator:request:transport:clock:configuration:readsTransport:)``)
    ///     rather than inventing one.
    ///   - request: what goes in the NEW (§6.2.2).
    ///   - transport: the datagram seam (AU-5). Never closed by this actor —
    ///     one transport may carry several calls, so closing it is the
    ///     client's decision.
    ///   - clock: `ContinuousClock()` in production, a manual clock under
    ///     test. Drives both the connect deadline and the call's time-stamps.
    ///   - configuration: connect deadline and retransmission policy.
    ///   - allocator: if given, ``sourceCallNumber`` is returned to it by
    ///     ``close()``.
    ///   - readsTransport: `true` (default) to run the read loop and demux
    ///     here; `false` when a client multiplexes several calls onto one
    ///     transport and will call ``deliver(datagram:)`` itself.
    public init<C: Clock>(
        sourceCallNumber: UInt16,
        request: IAX2CallRequest,
        transport: any DatagramTransport,
        clock: C,
        configuration: Configuration = Configuration(),
        allocator: IAX2CallNumberAllocator? = nil,
        readsTransport: Bool = true
    ) where C.Duration == Duration {
        precondition(
            IAX2CallNumberAllocator.range.contains(sourceCallNumber),
            "an IAX2 source call number is a 15-bit field and MUST NOT be 0 "
                + "(RFC 5456 §8.1.1, §8.1.3; notes §15)")
        self.sourceCallNumber = sourceCallNumber
        self.request = request
        self.transport = transport
        self.clock = clock
        self.configuration = configuration
        self.allocator = allocator
        self.readsTransport = readsTransport
        self.channel = ReliableChannel(
            sourceCallNumber: sourceCallNumber,
            transport: transport,
            clock: clock,
            configuration: configuration.channel)

        let origin = clock.now
        self.elapsedMillisecondsSinceInit = {
            let elapsed = origin.duration(to: clock.now)
            let (seconds, attoseconds) = elapsed.components
            guard seconds > 0 || attoseconds > 0 else { return 0 }
            // 1 ms = 1e15 attoseconds (§8.1.1: "the number of milliseconds
            // since the first transmission of the call").
            let milliseconds = seconds &* 1000 &+ attoseconds / 1_000_000_000_000_000
            return UInt32(truncatingIfNeeded: milliseconds)
        }

        var escapedContinuation: AsyncStream<IAX2CallEvent>.Continuation!
        let stream = AsyncStream<IAX2CallEvent>(bufferingPolicy: .unbounded) { continuation in
            escapedContinuation = continuation
        }
        self.events = stream
        self.continuation = escapedContinuation
    }

    /// Allocates a source call number and builds a call around it. The
    /// recommended constructor: it is the path on which a call number can
    /// never be out of range and exhaustion is a thrown error rather than a
    /// trap.
    public static func outbound<C: Clock>(
        allocator: IAX2CallNumberAllocator,
        request: IAX2CallRequest,
        transport: any DatagramTransport,
        clock: C,
        configuration: Configuration = Configuration(),
        readsTransport: Bool = true
    ) async throws -> IAX2Call where C.Duration == Duration {
        let number = try await allocator.allocate()
        return IAX2Call(
            sourceCallNumber: number,
            request: request,
            transport: transport,
            clock: clock,
            configuration: configuration,
            allocator: allocator,
            readsTransport: readsTransport)
    }

    // MARK: Introspection

    /// Milliseconds since the first transmission of the call — the value that
    /// goes in a full frame's time-stamp field (§8.1.1, §6.2.2). Reads 0 until
    /// ``start()`` fixes the origin.
    public var timestampMilliseconds: UInt32 {
        elapsedMillisecondsSinceInit() &- timestampOrigin
    }

    /// The next OSeqno this call will put on a non-exempt full frame (§8.1.1).
    /// Exposed for tests and diagnostics; the counters belong to the channel.
    public func outboundSequenceNumber() async -> UInt8 {
        await channel.outboundSequenceNumber
    }

    /// The ISeqno this call will put on everything it sends: §8.1.1's "next
    /// expected inbound stream sequence number".
    public func expectedInboundSequenceNumber() async -> UInt8 {
        await channel.expectedInboundSequenceNumber
    }

    // MARK: Placing the call (§6.2.2)

    /// Sends the NEW, starts the read loop, and arms the connect deadline.
    ///
    /// > "Before sending a NEW message, the local IAX peer MUST assign a source
    /// > call identifier that is not currently being used for another call."
    /// > (§6.2.2) — that is ``sourceCallNumber``, already fixed.
    ///
    /// The NEW carries OSeqno = 0 and ISeqno = 0 (§7, §6.2.2) and time-stamp 0,
    /// since it *is* the first transmission of the call.
    ///
    /// - Throws: ``IAX2CallError/illegalTransition(from:attempted:)`` unless
    ///   the call is `idle`, or a transport error.
    public func start() async throws {
        guard state == .idle else {
            throw IAX2CallError.illegalTransition(from: state, attempted: "start")
        }
        startLoops()
        timestampOrigin = elapsedMillisecondsSinceInit()

        let payload: [UInt8]
        do {
            payload = try InformationElement.serialize(request.newInformationElements())
        } catch {
            throw IAX2CallError.malformedInformationElements(String(describing: error))
        }

        do {
            try await channel.send(.new, timestamp: 0, payload: payload)
        } catch {
            await terminate(.channelFailed(Self.channelError(error)))
            throw error
        }
        transition(to: .newSent)
        armConnectDeadline()
    }

    /// Suspends until the call reaches `up`.
    ///
    /// - Throws: ``IAX2CallEnded`` carrying the termination reason if the call
    ///   ends first — including ``IAX2CallTermination/connectTimedOut(_:)``.
    public func waitUntilUp() async throws {
        if state == .up { return }
        if let termination { throw IAX2CallEnded(reason: termination) }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            upWaiters[id] = continuation
        }
    }

    /// Tears the call down from this end (§6.2.5).
    ///
    /// > "After sending a HANGUP message, the sender MUST destroy the call and
    /// > respond to subsequent messages regarding this call with an INVAL
    /// > message." (§6.2.5)
    ///
    /// So the leg is destroyed as soon as the HANGUP is written — this does
    /// not wait for the peer's ACK, and everything that arrives afterwards is
    /// answered with INVAL.
    ///
    /// - Throws: ``IAX2CallError/illegalTransition(from:attempted:)`` when
    ///   there is no leg to hang up (`idle`, or already gone).
    public func hangup(
        cause: String? = "Normal call clearing",
        causeCode: UInt8? = IAX2Call.normalClearingCauseCode
    ) async throws {
        guard state.isLive else {
            throw IAX2CallError.illegalTransition(from: state, attempted: "hangup")
        }
        var elements: [InformationElement] = []
        // "SHOULD" on HANGUP and REJECT (§8.6.21, §8.6.33).
        if let cause { elements.append(.cause(cause)) }
        if let causeCode { elements.append(.causeCode(causeCode)) }

        let payload: [UInt8]
        do {
            payload = try InformationElement.serialize(elements)
        } catch {
            throw IAX2CallError.malformedInformationElements(String(describing: error))
        }

        do {
            try await channel.send(.hangup, timestamp: timestampMilliseconds, payload: payload)
        } catch {
            await terminate(.channelFailed(Self.channelError(error)))
            throw error
        }
        transition(to: .hangupSent)
        await terminate(.localHangup(cause: cause, causeCode: causeCode))
    }

    /// Stops every task, closes the reliable channel, and returns the source
    /// call number to the allocator.
    ///
    /// The transport is **not** closed: it may carry other calls, and it is the
    /// client's to close. Idempotent.
    ///
    /// A live call is terminated with ``IAX2CallTermination/closed`` — no
    /// HANGUP; call ``hangup(cause:causeCode:)`` first if the peer should be
    /// told.
    public func close() async {
        if state != .dead {
            await terminate(.closed)
        }
        readTask?.cancel()
        readTask = nil
        channelEventTask?.cancel()
        channelEventTask = nil
        await channel.close()
        if !didReleaseCallNumber, let allocator {
            didReleaseCallNumber = true
            await allocator.release(sourceCallNumber)
        }
    }

    // MARK: Sending on an established call (the IAX-6 / IAX-7 seam)

    /// Sends one full frame on the call's reliable channel, stamped with the
    /// call's own clock.
    ///
    /// The generic path IAX-6 uses for a full Voice frame (which pins the codec
    /// for the mini frames that follow, §8.1.2) and IAX-7 for a DTMF frame
    /// (type `0x01`, the digit in the subclass, §8.2.1). This actor takes no
    /// view on the payload.
    ///
    /// - Parameter timestamp: override the call clock, for a caller pacing its
    ///   own media stream. Time-stamps "MAY be approximate, but, MUST be in
    ///   order" (§7).
    /// - Throws: ``IAX2CallError/notEstablished(state:)`` before the call is
    ///   ACCEPTed — media and Control frames both require an accepted leg
    ///   (§6.3.1, §9.6).
    @discardableResult
    public func send(
        type: IAX2FrameType,
        subclass: IAX2Subclass,
        timestamp: UInt32? = nil,
        payload: [UInt8] = []
    ) async throws -> IAX2FullFrame {
        guard state.isEstablished else {
            throw IAX2CallError.notEstablished(state: state)
        }
        return try await channel.send(
            type: type,
            subclass: subclass,
            timestamp: timestamp ?? timestampMilliseconds,
            payload: payload)
    }

    /// Sends one Mini Frame (§8.1.2): no sequence numbers, no acknowledgement,
    /// no retransmission.
    ///
    /// - Parameter timestamp: the low 16 bits of the call clock by default.
    ///   IAX-6 owns the resync rule that a full frame MUST be substituted at
    ///   every `0x8000` boundary (§6.10, §8.1.2, notes §11).
    /// - Throws: ``IAX2CallError/notEstablished(state:)`` unless the call is
    ///   `up` — "Mini Frames… carry a media stream on an already-established
    ///   IAX call" (§8.1.2).
    public func sendMini(timestamp: UInt16? = nil, payload: [UInt8]) async throws {
        guard state == .up else {
            throw IAX2CallError.notEstablished(state: state)
        }
        try await channel.sendMini(
            timestamp: timestamp ?? UInt16(truncatingIfNeeded: timestampMilliseconds),
            payload: payload)
    }

    // MARK: Receiving

    /// Feeds one received datagram to this call: parse, demux, sequence, then
    /// drive the FSM.
    ///
    /// Public because a client that multiplexes several calls onto one
    /// transport (IAX-8) owns the read loop itself and drives each call
    /// through here. When this call runs its own read loop, this is what the
    /// loop calls.
    ///
    /// - Returns: the parsed frame, or `nil` if the datagram was dropped — a
    ///   Meta Frame (§8.1.3, trunking is not implemented) or one too short to
    ///   parse. Neither is answerable: the RFC defines no message for refusing
    ///   a Meta Frame, and a truncated datagram names no call.
    /// - Throws: ``IAX2CallError`` when the peer breaks an FSM rule. The read
    ///   loop turns that into a silent teardown; a caller driving the call by
    ///   hand sees it directly.
    @discardableResult
    public func deliver(datagram: Data) async throws -> IAX2Frame? {
        guard let frame = try? IAX2Frame.parse(datagram) else { return nil }
        try await deliver(frame)
        return frame
    }

    /// Feeds one already-parsed frame to this call. See
    /// ``deliver(datagram:)``.
    public func deliver(_ frame: IAX2Frame) async throws {
        switch frame {
        case .mini(let mini):
            // A Mini Frame has no destination call number (§8.1.2), so the
            // only identity available is the peer's source call number. One
            // that does not match this call's peer (or arrives before the peer
            // has been identified) is dropped rather than answered: an INVAL
            // needs a call-number pair to address, and there is none here.
            guard mini.sourceCallNumber == destinationCallNumber, destinationCallNumber != 0 else {
                return
            }
            guard state != .dead else { return }
            continuation.yield(.media(frame))

        case .full(let full):
            guard isForThisCall(full) else {
                await sendInvalid(answering: full, forThisCall: false)
                return
            }
            guard state != .dead else {
                // "After a HANGUP message has been received for a call leg, any
                // messages received that reference that call leg… MUST be
                // answered with an INVAL message." (§6.2.5)
                await sendInvalid(answering: full, forThisCall: true)
                return
            }
            if destinationCallNumber == 0, full.sourceCallNumber != 0 {
                // Before the channel sees the frame: the ACK it is about to
                // send has to carry the peer's number as its destination.
                await learnPeerCallNumber(full.sourceCallNumber)
            }
            // The channel ACKs where the RFC requires it, retires our
            // outstanding frames, and hands back only what the FSM should act
            // on (§6.9.1, §7).
            switch await channel.receive(frame) {
            case .deliver(let delivered):
                try await handle(delivered)
            case .media, .consumed, .duplicate, .outOfSequence, .ignored:
                break
            }
        }
    }

    // MARK: Demultiplexing (§4, §6.2.1, notes §15)

    /// Is this full frame addressed to this call leg?
    ///
    /// "Call legs are labeled with a pair of identifiers." (§6.2.1) On receive
    /// the frame's *destination* call number is ours and its *source* is the
    /// peer's. Before the peer's first reply we do not know its number, so any
    /// source is accepted and the number is learned from it.
    private func isForThisCall(_ frame: IAX2FullFrame) -> Bool {
        guard frame.destinationCallNumber == sourceCallNumber else { return false }
        guard destinationCallNumber != 0 else { return true }
        return frame.sourceCallNumber == destinationCallNumber
    }

    private func learnPeerCallNumber(_ number: UInt16) async {
        destinationCallNumber = number
        await channel.setDestinationCallNumber(number)
    }

    /// Answers a frame that belongs to no live call here (§6.9.2, §6.2.5).
    ///
    /// > "An INVAL is sent as a response to a received message that is not
    /// > valid. This occurs when an IAX peer sends a message on a call after
    /// > the remote peer has hung up its end." (§6.9.2)
    ///
    /// This is written straight to the transport rather than through the
    /// reliable channel, because in the unknown-call case there is no channel,
    /// and in the dead-call case the channel has been closed and refuses
    /// sends. That is correct either way: INVAL is one of the five messages
    /// that "do not change the message count" (§7) and is never itself
    /// acknowledged.
    ///
    /// *RFC ambiguous:* the RFC does not say what call numbers or sequence
    /// numbers an INVAL for an unknown call should carry. We mirror the
    /// offending frame — source = the number the peer addressed (so the peer
    /// can match it to its own leg and destroy it), destination = the peer's
    /// source — and echo its time-stamp, the same correlation trick §6.9.1
    /// specifies for ACK. Sequence numbers are this call's current counters
    /// when the frame was for us, and 0/0 when it named a call we have never
    /// had.
    private func sendInvalid(answering frame: IAX2FullFrame, forThisCall: Bool) async {
        let source =
            frame.destinationCallNumber != 0 ? frame.destinationCallNumber : sourceCallNumber
        let oSeqno = forThisCall ? await channel.outboundSequenceNumber : 0
        let iSeqno = forThisCall ? await channel.expectedInboundSequenceNumber : 0
        let reply = IAX2FullFrame(
            sourceCallNumber: source,
            destinationCallNumber: frame.sourceCallNumber,
            timestamp: frame.timestamp,
            oSeqno: oSeqno,
            iSeqno: iSeqno,
            type: .iax,
            subclass: IAX2Subclass(.inval))
        try? await transport.send(IAX2Frame.full(reply).encoded())
    }

    // MARK: The state machine (§6.2, §6.3, §6.7, §6.9)

    private func handle(_ frame: IAX2FullFrame) async throws {
        switch frame.type {
        case .iax:
            guard let message = frame.iaxMessage else {
                // "Unrecognised IAX subclass → respond UNSUPPORT carrying the
                // IAX UNKNOWN IE" (§6.9.5, §8.6.22).
                try await sendUnsupported(subclass: frame.subclass.rawByte)
                return
            }
            try await handle(message, frame)

        case .control:
            guard let control = frame.control else {
                // "An IAX peer that receives a control message that is not
                // understood MUST respond with the UNSUPPORT message." (§6.3.1)
                try await sendUnsupported(subclass: frame.subclass.rawByte)
                return
            }
            try await handle(control, frame)

        case .voice, .video, .comfortNoise:
            // Already ACKed: "Upon receiving any media message, except the
            // abbreviated audio and video Mini Frames, an ACK message MUST be
            // sent." (§6.10) IAX-6 owns what happens to it.
            continuation.yield(.media(.full(frame)))

        default:
            // DTMF (IAX-7), Text, Image, HTML, Null: handed over untouched.
            continuation.yield(.other(frame))
        }
    }

    private func handle(_ message: IAX2Message, _ frame: IAX2FullFrame) async throws {
        switch message {
        case .accept:
            try await handleAccept(frame)
        case .reject:
            try await handleReject(frame)
        case .authreq:
            try await handleAuthenticationRequest(frame)
        case .hangup:
            try await handleRemoteHangup(frame)
        case .inval:
            // "Upon receipt of an INVAL, a peer MUST destroy its side of a
            // call." (§6.9.2)
            await terminate(.invalidated)
        case .ping:
            // "Receipt of a PING requires an acknowledging PONG be sent."
            // (§6.7.2) PONG echoes the PING's time-stamp (§6.7.3, §9.1).
            try await reply(.pong, echoing: frame)
        case .lagrq:
            // LAGRP "MUST send the same time-stamp it received in the LAGRQ
            // after passing the received frame through any jitter buffer"
            // (§6.7.5); the requester derives the round trip from it (§6.7.4).
            try await reply(.lagrp, echoing: frame)
        case .pong, .lagrp, .ack, .vnak:
            // ACK and VNAK never reach here (the channel consumes them).
            // "Receipt of an ACK requires no action." (§6.9.1) A PONG or LAGRP
            // answering something we sent needs only the ACK the channel has
            // already sent.
            break
        default:
            // Registration, dialplan, transfer, QUELCH/UNQUELCH and the rest:
            // out of scope for a call leg. Already ACKed; "If the remote
            // system cannot perform this request, it SHOULD be ignored"
            // (§6.4.4).
            continuation.yield(.other(frame))
        }
    }

    private func handle(_ control: IAX2Control, _ frame: IAX2FullFrame) async throws {
        // "These messages MUST only be sent after an IAX call leg has been
        // ACCEPTed." (§6.3.1) A Control frame before the ACCEPT — a bare
        // ANSWER answering a NEW, say — is a protocol violation, not something
        // to be humoured into an out-of-order state change.
        guard state.isEstablished else {
            throw IAX2CallError.illegalTransition(
                from: state, attempted: "Control \(control) (RFC 5456 §6.3.1)")
        }
        continuation.yield(.control(control))

        switch control {
        case .answer:
            // "sent from the called party to indicate that the party has
            // accepted the call request… the communications channel MUST be
            // opened." (§6.3.4) A repeat ANSWER on a call that is already up
            // changes nothing.
            guard state == .accepted else { return }
            transition(to: .answered)
            transition(to: .up)
            cancelConnectDeadline()
            resumeUpWaiters(with: nil)

        case .hangup:
            // Control HANGUP (frame type 0x04, subclass 0x01) is **not** IAX
            // HANGUP (type 0x06, subclass 0x05, §6.2.5). Only the latter
            // destroys a call leg; §8.3 gives this one no teardown semantics
            // beyond "The call has been hungup at the remote end", and §6.2.5
            // — the only text that destroys a leg — names the IAX message.
            // It has been reported as an event; the leg stays up until an IAX
            // HANGUP, a REJECT, or a local hangup ends it (notes trap 18).
            break

        default:
            // RINGING (§6.3.3), PROCEEDING (§6.3.2), PROGRESS, BUSY,
            // CONGESTION, HOLD/UNHOLD, KEY/UNKEY RADIO: reported, ACKed, and
            // otherwise the layer above's business.
            break
        }
    }

    /// ACCEPT (§6.2.3). The ACK the RFC requires has already gone out — the
    /// channel ACKs every in-sequence full frame.
    private func handleAccept(_ frame: IAX2FullFrame) async throws {
        switch state {
        case .newSent, .authReplied:
            break
        case .accepted, .answered, .up:
            // "If a subsequent ACCEPT message is received for a call that has
            // already started, or has not sent a NEW message, the message MUST
            // be ignored." (§6.2.3) The RFC says ignore, so we ignore — this is
            // the one inbound transition that is explicitly *not* an error.
            return
        default:
            throw IAX2CallError.illegalTransition(from: state, attempted: "ACCEPT")
        }

        let elements = try parseElements(frame)
        var format: MediaFormat?
        for element in elements {
            if case .format(let value) = element {
                format = value
                break
            }
        }
        negotiatedFormat = format
        transition(to: .accepted)
        // The peer has created its side of the leg, so the reachability
        // deadline has done its job; ringing is not bounded here.
        cancelConnectDeadline()
        continuation.yield(.accepted(format: format))
    }

    /// REJECT (§6.2.4). "Upon receipt of a REJECT message, the call leg is
    /// destroyed and no further action is required. (Note: REJECT messages
    /// require an explicit ACK.)" The ACK is the channel's; the destruction is
    /// ours, and the CAUSE travels out in the termination.
    private func handleReject(_ frame: IAX2FullFrame) async throws {
        let (cause, causeCode) = causeInformation(frame)
        transition(to: .rejected)
        await terminate(.rejected(cause: cause, causeCode: causeCode))
    }

    /// IAX HANGUP (§6.2.5) — frame type `0x06`, subclass `0x05`. "Upon receipt
    /// of a HANGUP message, an IAX peer MUST immediately respond with an ACK,
    /// and then destroy the call leg at its end." The ACK is the channel's.
    private func handleRemoteHangup(_ frame: IAX2FullFrame) async throws {
        let (cause, causeCode) = causeInformation(frame)
        transition(to: .receivedHangup)
        await terminate(.remoteHangup(cause: cause, causeCode: causeCode))
    }

    /// AUTHREQ (§6.2.7, §8.6.13–§8.6.15).
    ///
    /// > "Upon receiving an AUTHREQ message, the receiver MUST respond with an
    /// > AUTHREP or HANGUP message." (§6.2.7)
    ///
    /// MD5 only. There is no plaintext path to fall back to: AUTHMETHODS
    /// `0x0001` is "Reserved (was Plaintext)" (§8.6.13), the PASSWORD IE has no
    /// defining subsection, and §10 says cleartext "has been eliminated". An
    /// RSA-only peer therefore fails here, loudly, rather than silently
    /// producing an AUTHREP the peer will reject.
    private func handleAuthenticationRequest(_ frame: IAX2FullFrame) async throws {
        guard state == .newSent else {
            throw IAX2CallError.illegalTransition(from: state, attempted: "AUTHREQ")
        }
        let elements = try parseElements(frame)

        var challenge: String?
        var offered = IAX2Auth.AuthMethods([])
        for element in elements {
            switch element {
            case .challenge(let value):
                challenge = value
            case .authMethods(let value):
                // The IE parser and IAX2Auth model the same §8.6.13 bitmask in
                // two types; the raw value is the shared truth.
                offered = IAX2Auth.AuthMethods(rawValue: value.rawValue)
            default:
                break
            }
        }

        transition(to: .authRequested)

        guard let challenge else { throw IAX2CallError.missingChallenge }
        continuation.yield(.challenged(challenge: challenge, methods: offered))

        do {
            _ = try IAX2Auth.selectAuthMethod(offered: offered)
        } catch {
            throw IAX2CallError.unsupportedAuthentication(offered: offered)
        }
        guard let secret = request.secret else { throw IAX2CallError.missingSecret }

        // §8.6.15: MD5( challenge ‖ password ), challenge first, no separator,
        // carried as text. The text encoding is OQ-5 and lives in IAX2Auth.
        let response = IAX2Auth.md5Response(challenge: challenge, secret: secret)
        try await channel.send(
            .authrep,
            timestamp: timestampMilliseconds,
            payload: try InformationElement.serialize([.md5Result(response)]))
        transition(to: .authReplied)
    }

    // MARK: Replies this call owes the peer

    /// Sends a reply that echoes the time-stamp of the frame it answers — the
    /// rule PONG and LAGRP share with ACK (§6.7.3, §6.7.5, §6.9.1, trap 9).
    private func reply(_ message: IAX2Message, echoing frame: IAX2FullFrame) async throws {
        try await channel.send(message, timestamp: frame.timestamp)
    }

    /// UNSUPPORT (`0x21`) carrying IAX UNKNOWN (`0x17`), "a 1-octet copy of the
    /// offending subclass" (§6.9.5, §8.6.22, §6.3.1).
    private func sendUnsupported(subclass: UInt8) async throws {
        try await channel.send(
            .unsupport,
            timestamp: timestampMilliseconds,
            payload: try InformationElement.serialize([.iaxUnknown(subclass)]))
    }

    // MARK: Loops

    private func startLoops() {
        if readsTransport, readTask == nil {
            let transport = self.transport
            readTask = Task { [weak self] in
                for await datagram in transport.incoming {
                    guard let self else { return }
                    await self.deliverFromReadLoop(datagram)
                }
            }
        }
        if channelEventTask == nil {
            let channel = self.channel
            channelEventTask = Task { [weak self] in
                for await event in channel.events {
                    guard case .failed(let error) = event else { continue }
                    guard let self else { return }
                    // §7 and §6.6: torn down "without any further interaction
                    // on this call leg" — no HANGUP.
                    await self.terminate(.channelFailed(error))
                }
            }
        }
    }

    /// The read loop's error policy: an FSM violation by the peer, or a write
    /// that failed, ends the call. Silently — the peer has either stopped
    /// listening or is not speaking the protocol, and §6.6 forbids "other
    /// indications over the errant IAX call leg".
    private func deliverFromReadLoop(_ datagram: Data) async {
        do {
            _ = try await deliver(datagram: datagram)
        } catch let error as IAX2CallError {
            await terminate(.protocolError(error))
        } catch {
            await terminate(.channelFailed(Self.channelError(error)))
        }
    }

    // MARK: The connect deadline

    private func armConnectDeadline() {
        let clock = self.clock
        let timeout = configuration.connectTimeout
        connectDeadlineTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return  // Cancelled: the call came up, or ended some other way.
            }
            await self?.connectDeadlineExpired()
        }
    }

    private func cancelConnectDeadline() {
        connectDeadlineTask?.cancel()
        connectDeadlineTask = nil
    }

    private func connectDeadlineExpired() async {
        guard !state.isEstablished, state != .dead else { return }
        // Deliberately no HANGUP. The peer has not brought the call up; §6.6's
        // rule against "other indications over the errant IAX call leg" and
        // §7's silent teardown are the closest the RFC comes to governing this
        // case, and both say to send nothing further.
        await terminate(.connectTimedOut(configuration.connectTimeout))
    }

    // MARK: Transitions and teardown

    private func transition(to next: IAX2CallState) {
        guard state != next else { return }
        let previous = state
        state = next
        continuation.yield(.stateChanged(from: previous, to: next))
    }

    /// Destroys the call leg. Idempotent; the first reason wins.
    ///
    /// The read loop is deliberately left running: "any messages received that
    /// reference that call leg… MUST be answered with an INVAL message"
    /// (§6.2.5), which a stopped reader could not do. ``close()`` is what stops
    /// it for good.
    private func terminate(_ reason: IAX2CallTermination) async {
        guard state != .dead else { return }
        cancelConnectDeadline()
        termination = reason
        transition(to: .dead)
        continuation.yield(.ended(reason))
        continuation.finish()
        await channel.close()
        resumeUpWaiters(with: IAX2CallEnded(reason: reason))
    }

    private func resumeUpWaiters(with error: Error?) {
        let waiters = upWaiters
        upWaiters.removeAll()
        for continuation in waiters.values {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    // MARK: Small helpers

    private func parseElements(_ frame: IAX2FullFrame) throws -> [InformationElement] {
        do {
            return try InformationElement.parseList(frame.payload)
        } catch {
            throw IAX2CallError.malformedInformationElements(String(describing: error))
        }
    }

    /// CAUSE (`0x16`) and CAUSECODE (`0x2a`) out of a HANGUP, REJECT or
    /// REGREJ — both "SHOULD" rather than "MUST", so both are optional here
    /// (§8.6.21, §8.6.33). A payload that will not parse yields no cause
    /// rather than losing the teardown.
    private func causeInformation(_ frame: IAX2FullFrame) -> (String?, UInt8?) {
        guard let elements = try? InformationElement.parseList(frame.payload) else {
            return (nil, nil)
        }
        var cause: String?
        var causeCode: UInt8?
        for element in elements {
            switch element {
            case .cause(let value): cause = value
            case .causeCode(let value): causeCode = value
            default: break
            }
        }
        return (cause, causeCode)
    }

    private static func channelError(_ error: Error) -> ReliableChannelError {
        (error as? ReliableChannelError) ?? .transportFailed(String(describing: error))
    }
}
