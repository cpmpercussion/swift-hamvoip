// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - The clock EchoLink does not send

/// Synthesises the millisecond stream clock `JitterBuffer` needs, from the
/// only ordering signal EchoLink provides.
///
/// ## Why this type has to exist
///
/// `JitterBuffer` keys entirely on `TimedFrame.timestamp`, a 32-bit
/// millisecond stream clock. The IAX2 and M17 paths both have a wire counter to
/// derive one from, and `IAX2MiniTimestampExpander` and
/// `M17FrameNumberExpander` do exactly that.
///
/// EchoLink has no such counter. **Its RTP timestamp is always zero** — across
/// four independent peers, both directions, every packet. So the sequence
/// number is the only ordering signal there is, and it is opaque in two ways
/// that a counter usually is not:
///
/// - **Its origin is arbitrary.** Ours starts at 0; observed inbound sequences
///   began at 2126 and at 4013. There is no "start" to count from, so the
///   origin is *latched* at the first packet rather than assumed.
/// - **It wraps at 16 bits**, and a wrap must not look like a 87-minute jump
///   backwards.
///
/// ## Wraps and talkspurts are different things
///
/// Both are big jumps in the raw sequence, and telling them apart is the whole
/// design:
///
/// - A **wrap** is 65535 → 0. Under signed 16-bit nearest-interpretation that
///   is a delta of +1, an ordinary step, and needs no special case at all —
///   which is why there is none here.
/// - A **talkspurt boundary** is a jump the nearest interpretation still reads
///   as large: 151 → 0 is −151, and nothing reorders 151 packets. It means a
///   new transmission, whose sequence origin is unrelated to the last one's.
///
/// Three such boundaries appear in a single four-peer capture, and the
/// `live-proxy-audio-in.hex` fixture is cut to span one. **This is the common
/// case, not an edge case** — every over on a conference is a new talkspurt.
/// On one, the expander re-latches and continues the playout clock just after
/// whatever it last emitted, so the buffer sees a continuing stream rather than
/// a jump backwards in time.
public struct EchoLinkSequenceExpander: Sendable, Equatable {
    /// One past the largest sequence number.
    static let modulus = 0x1_0000

    /// The playout advance of one packet, in milliseconds. Four 20 ms GSM
    /// frames.
    public static let packetMilliseconds: UInt32 = 80

    /// How far backwards an arrival may be and still be treated as reordering
    /// rather than a new talkspurt.
    ///
    /// 16 packets is 1.28 s of audio. Generous for genuine network reordering,
    /// and far below the 151-packet backwards jump the capture's talkspurt
    /// boundary shows, which is the gap this has to sit inside.
    public static let maximumReorder = 16

    /// How far forwards a jump may be and still be treated as loss within one
    /// talkspurt.
    ///
    /// 250 packets is 20 s. Beyond that, calling it "loss" would insert 20 s of
    /// silence into the playout clock and stall the buffer; treating it as a
    /// new talkspurt just continues.
    public static let maximumForwardGap = 250

    /// Headroom, in packets, left below the first packet's stream time.
    ///
    /// The origin is arbitrary, so the first packet seen is not necessarily the
    /// earliest one sent — a reordered predecessor may arrive next. Starting at
    /// stream time 0 would leave it nowhere to go but a clamp, and two frames
    /// with the same timestamp are worse than one late one. Starting a
    /// reorder-window above zero gives it room.
    private static let originHeadroom = UInt32(maximumReorder)

    /// What `expand` decided.
    public struct Expansion: Equatable, Sendable {
        /// The synthesised stream time of this packet's first codec frame, in
        /// milliseconds.
        public let streamTime: UInt32

        /// Whether this packet began a new talkspurt — the first packet, or one
        /// whose sequence had no plausible relationship to the last.
        public let isNewTalkspurt: Bool
    }

    /// Raw sequence of the newest packet accepted so far.
    private var newestRawSequence: UInt16?
    /// Stream time of that packet.
    private var newestStreamTime: UInt32 = 0
    /// The largest stream time emitted, which re-latching continues from.
    private var highestStreamTime: UInt32 = 0

    public init() {}

    /// The stream time for `sequence`.
    ///
    /// Late packets expand to where they *belong*, below the reference, rather
    /// than being dragged forward — which is what lets `JitterBuffer` recognise
    /// them as the reordered arrivals they are and place them correctly.
    public mutating func expand(_ sequence: UInt16) -> Expansion {
        guard let reference = newestRawSequence else {
            newestRawSequence = sequence
            newestStreamTime = Self.originHeadroom * Self.packetMilliseconds
            highestStreamTime = newestStreamTime
            return Expansion(streamTime: newestStreamTime, isNewTalkspurt: true)
        }

        let delta = Self.signedDelta(from: reference, to: sequence)

        guard delta >= -Self.maximumReorder, delta <= Self.maximumForwardGap else {
            // A new talkspurt. Its sequence origin has nothing to do with the
            // last one's, so continue the playout clock from the highest time
            // already emitted rather than trying to relate the two.
            let streamTime = highestStreamTime &+ Self.packetMilliseconds
            newestRawSequence = sequence
            newestStreamTime = streamTime
            highestStreamTime = streamTime
            return Expansion(streamTime: streamTime, isNewTalkspurt: true)
        }

        let offset = Int64(delta) * Int64(Self.packetMilliseconds)
        let streamTime = UInt32(
            clamping: Int64(newestStreamTime) + offset
        )

        // Only genuinely newer packets move the reference. A late arrival that
        // dragged it backwards would make the next in-order packet look like a
        // forward jump — the bug `M17FrameNumberExpander` documents, in the
        // form it takes here.
        if delta > 0 {
            newestRawSequence = sequence
            newestStreamTime = streamTime
        }
        if streamTime > highestStreamTime { highestStreamTime = streamTime }

        return Expansion(streamTime: streamTime, isNewTalkspurt: false)
    }

    /// Back to a just-constructed state, for a new session.
    public mutating func reset() {
        newestRawSequence = nil
        newestStreamTime = 0
        highestStreamTime = 0
    }

    /// The nearest-interpretation signed distance between two 16-bit sequence
    /// numbers, in `-32768 ... 32767`.
    ///
    /// This one function is what makes a wrap a non-event: 65535 → 0 comes back
    /// as +1, not −65535.
    public static func signedDelta(from reference: UInt16, to sequence: UInt16) -> Int {
        let raw = (Int(sequence) - Int(reference) + modulus) % modulus
        return raw >= modulus / 2 ? raw - modulus : raw
    }
}

// MARK: - Packets to playable frames

/// Turns received audio packets into the `TimedFrame`s `JitterBuffer` consumes.
///
/// One 144-byte packet is 80 ms in four 20 ms units, so it produces four frames
/// at `streamTime + i × 20`. Splitting here rather than at playout is what lets
/// the buffer conceal the loss of *part* of a packet, and it matches the 20 ms
/// frame size the rest of the stack already uses everywhere.
public struct EchoLinkStreamAudio: Sendable {
    private var expander = EchoLinkSequenceExpander()

    public init() {}

    /// What `receive` produced.
    public struct Reception: Equatable, Sendable {
        /// The frames to push into a `JitterBuffer`, in order.
        public let frames: [TimedFrame]
        /// Whether this packet began a new talkspurt. A caller may want to
        /// reset the buffer on one; this type does not decide that.
        public let isNewTalkspurt: Bool
    }

    /// Expand one audio packet into timed codec frames.
    public mutating func receive(_ packet: EchoLinkRTPPacket) -> Reception {
        let expansion = expander.expand(packet.header.sequenceNumber)
        let step = UInt32(EchoLinkRTPPacket.frameDuration.milliseconds)

        var frames: [TimedFrame] = []
        frames.reserveCapacity(packet.codecFrames.count)
        for (index, codecFrame) in packet.codecFrames.enumerated() {
            frames.append(
                TimedFrame(
                    timestamp: expansion.streamTime &+ UInt32(index) &* step,
                    payload: codecFrame
                )
            )
        }
        return Reception(frames: frames, isNewTalkspurt: expansion.isNewTalkspurt)
    }

    /// Classify then expand a raw `0x05` payload.
    ///
    /// Returns `nil` for anything that is not audio — station info most
    /// commonly — so a caller cannot accidentally play text as speech.
    public mutating func receive(payload: Data) -> Reception? {
        guard case .audio(let packet) = EchoLinkAudioChannelMessage.classify(payload) else {
            return nil
        }
        return receive(packet)
    }

    /// Back to a just-constructed state.
    public mutating func reset() {
        expander.reset()
    }
}

// MARK: - Outbound

/// Produces the audio packets of one over.
///
/// Pure state, no clock and no codec: hand it codec frames, get a packet with
/// the next sequence number. Mirrors `M17StreamTransmitter` and
/// `IAX2VoiceTransmitter`.
///
/// It emits what was observed — four frames per packet, timestamp zero, SSRC
/// zero, version 3 — because emitting what four independent implementations all
/// accept is the conservative choice. Parsing stays permissive; only
/// transmission commits.
public struct EchoLinkStreamTransmitter: Sendable {
    /// Frames per packet. Configurable, but changing it is a wire-visible
    /// choice with no evidence behind it — see `EchoLinkRTPPacket`.
    public let framesPerPacket: Int

    private var sequenceNumber: UInt16
    private let synchronisationSource: UInt32
    private var pending: [[UInt8]] = []

    /// - Parameters:
    ///   - initialSequenceNumber: Where to start. Zero is what this client has
    ///     always sent; any origin is legal, since receivers latch it.
    ///   - synchronisationSource: Zero is what this client sends. Receivers
    ///     must not key on it, so it carries no meaning here.
    public init(
        initialSequenceNumber: UInt16 = 0,
        synchronisationSource: UInt32 = 0,
        framesPerPacket: Int = EchoLinkRTPPacket.observedFramesPerPacket
    ) {
        self.sequenceNumber = initialSequenceNumber
        self.synchronisationSource = synchronisationSource
        self.framesPerPacket = max(1, framesPerPacket)
    }

    /// The next sequence number this transmitter will use.
    public var nextSequenceNumber: UInt16 { sequenceNumber }

    /// How many codec frames are held back waiting for a full packet.
    public var pendingFrameCount: Int { pending.count }

    /// Accept one 20 ms codec frame, returning a packet once enough have
    /// accumulated.
    public mutating func push(_ codecFrame: [UInt8]) -> EchoLinkRTPPacket? {
        pending.append(codecFrame)
        guard pending.count >= framesPerPacket else { return nil }
        let batch = Array(pending.prefix(framesPerPacket))
        pending.removeFirst(framesPerPacket)
        return packet(with: batch)
    }

    /// Emit whatever is held back, even if it is a short packet.
    ///
    /// For the end of an over: holding three frames until a fourth that never
    /// comes would clip the last 60 ms of every transmission.
    public mutating func flush() -> EchoLinkRTPPacket? {
        guard !pending.isEmpty else { return nil }
        let batch = pending
        pending.removeAll()
        return packet(with: batch)
    }

    /// Start a new over.
    public mutating func reset() {
        pending.removeAll()
    }

    private mutating func packet(with frames: [[UInt8]]) -> EchoLinkRTPPacket {
        let header = EchoLinkRTPHeader(
            sequenceNumber: sequenceNumber,
            timestamp: 0,
            synchronisationSource: synchronisationSource
        )
        sequenceNumber &+= 1
        return EchoLinkRTPPacket(header: header, codecFrames: frames)
    }
}

// MARK: - Duration helper

extension Duration {
    /// Whole milliseconds, for the millisecond stream clock `TimedFrame` uses.
    fileprivate var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
