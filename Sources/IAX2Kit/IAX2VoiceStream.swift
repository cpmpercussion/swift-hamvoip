// SPDX-License-Identifier: Apache-2.0

import Foundation
import RadioCore

// MARK: - Errors

/// Why a voice frame could not be sent.
public enum IAX2VoiceError: Error, Equatable, CustomStringConvertible {
    /// PCM was offered for a codec this client cannot encode. Only G.711 µ-law
    /// (`0x00000004`, §8.7) is implemented; send pre-encoded bytes with
    /// ``IAX2VoiceStream/send(encoded:timestamp:)`` for anything else.
    case unsupportedFormat(MediaFormat)

    /// The outbound format cannot be written into a 7-bit subclass field.
    /// "Only one CODEC MUST be specified" (§8.6.8), and with the C bit set a
    /// subclass names exactly one power of two (§8.1.1) — a mask with zero or
    /// several bits set has no encoding.
    case formatNotRepresentable(MediaFormat)

    public var description: String {
        switch self {
        case .unsupportedFormat(let format):
            return
                "cannot encode PCM as media format 0x\(String(format: "%08x", format.rawValue)); "
                + "this client implements G.711 µ-law (0x00000004) only (RFC 5456 §8.7)"
        case .formatNotRepresentable(let format):
            return
                "media format 0x\(String(format: "%08x", format.rawValue)) names "
                + "\(format.rawValue.nonzeroBitCount) codecs; a subclass field names exactly one "
                + "(RFC 5456 §8.1.1, §8.6.8)"
        }
    }
}

// MARK: - 16-bit mini-frame time-stamps (RFC 5456 §8.1.2, §6.10; notes §11)

/// The 32 ↔ 16 bit time-stamp conversion that mini frames live and die by.
///
/// > "Mini frames carry a 16-bit time-stamp, which is the lower 16 bits of the
/// > transmitting peer's full 32-bit time-stamp for the call." (§8.1.2)
///
/// Truncation is trivial. **Expansion is not**, and getting it wrong is not a
/// theoretical concern: an expansion that is exactly 65,536 ms too high is the
/// input that used to make `JitterBuffer` emit 65 seconds of stuck repeating
/// audio from one bad packet. The buffer now bounds that (see its
/// `discontinuityMillis`), but that is a backstop, not a licence.
///
/// ## The rule
///
/// A 16-bit field cannot say *which* 65,536 ms epoch it belongs to, so the
/// receiver supplies the missing high half from a reference — the newest
/// reconstructed time-stamp of the same stream. The reconstruction is the
/// unique 32-bit value that (a) has the right low 16 bits and (b) lies within
/// half a wrap of the reference:
///
/// ```
/// delta = Int16(bitPattern: short &- UInt16(truncatingIfNeeded: reference))
/// expanded = reference &+ UInt32(bitPattern: Int32(delta))
/// ```
///
/// The whole correctness argument is in that `Int16(bitPattern:)`. Subtracting
/// the reference's low half in 16-bit modular arithmetic gives the *signed*
/// distance from the reference to the frame, in the range −32,768…+32,767, and
/// adding a signed distance to the reference can only ever land on the nearest
/// candidate. Both wrap directions therefore fall out of one line, with no
/// branch to get backwards:
///
/// - reference `0x0000_FFF0`, mini `0x0005` → delta **+21** → `0x0001_0005`.
///   The stream crossed the boundary; the high half carries.
/// - reference `0x0001_0005`, mini `0xFFF0` → delta **−21** → `0x0000_FFF0`.
///   A frame from just *before* the boundary, arriving just *after* the local
///   reference crossed it — reordered by the network, or simply late. The
///   naive "carry the current high half" reconstruction would put it at
///   `0x0001_FFF0`, **+65,536 ms into the future**, which is precisely the
///   failure this type exists to prevent.
///
/// ## What it cannot do
///
/// A gap of more than 32,768 ms with no full frame to resynchronise against is
/// unrecoverable — the signed distance saturates and the frame is placed in the
/// wrong epoch. That is a property of the wire format, not of this code, and it
/// is exactly why §6.10 requires a full frame at every `0x8000` boundary: the
/// resync interval is chosen so the ambiguity can never be reached. See
/// ``IAX2VoiceTransmitter`` for our side of that bargain.
public enum IAX2MiniTimestamp {
    /// One 16-bit epoch: 65,536 ms (§8.1.2).
    public static let epoch: UInt32 = 0x1_0000

    /// The low 16 bits of a call time-stamp — what goes in a mini frame
    /// (§8.1.2).
    public static func truncate(_ full: UInt32) -> UInt16 {
        UInt16(truncatingIfNeeded: full)
    }

    /// Expands a 16-bit mini-frame time-stamp against a 32-bit reference.
    ///
    /// - Parameters:
    ///   - short: the mini frame's 16-bit field.
    ///   - reference: the newest reconstructed 32-bit time-stamp of the same
    ///     stream (0 at the start of a call — "A time-stamp MUST also be
    ///     assigned for the call, beginning at zero", §6.2.2).
    /// - Returns: the reconstructed 32-bit time-stamp, or `nil` when the
    ///   nearest candidate lies *before* the call's zero origin. That can only
    ///   happen in the opening 32.768 s of a call, where a frame that appears
    ///   to precede the origin is a corrupt or misrouted one; expanding it
    ///   modulo 2³² would place it ≈ 49 days in the future, which is the
    ///   +65,536 ms failure mode with a bigger multiplier.
    ///
    /// Arithmetic is otherwise exactly modulo 2³², matching the width of the
    /// field it reconstructs (§8.1.1). The RFC says nothing about what happens
    /// when a call's own 32-bit millisecond clock overflows after ≈ 49.7 days.
    public static func expand(_ short: UInt16, near reference: UInt32) -> UInt32? {
        // Signed distance from the reference to the frame, −32768…+32767.
        let delta = Int32(Int16(bitPattern: short &- UInt16(truncatingIfNeeded: reference)))
        if delta < 0, UInt32(-delta) > reference { return nil }
        return reference &+ UInt32(bitPattern: delta)
    }
}

/// Carries the high 16 bits of a peer's call clock forward across mini frames.
///
/// The reference advances only *forwards*, so it always tracks the newest
/// time-stamp seen on the stream. A late or reordered frame is expanded against
/// that newest reference — which is the correct anchor, since "nearest to the
/// newest" is what makes a frame from just before a wrap boundary resolve
/// backwards instead of jumping an epoch — but does not drag the reference
/// back, where it would then mis-expand the frames that follow it.
///
/// ``resynchronise(to:)`` replaces the reference outright. It is driven by full
/// Voice frames, which carry an authoritative 32-bit time-stamp (§8.1.1) and
/// which §6.10 requires the peer to send at every `0x8000` boundary — "Receiver
/// side: reconstruct the peer's 32-bit time-stamp by carrying the high 16 bits
/// forward and detecting wraps in the low 16 bits, resynchronising the high
/// half whenever a full frame arrives" (notes §11).
///
/// **Not every full frame is a resync source**, which is a trap worth naming.
/// An ACK "MUST return the same time-stamp it received" (§6.9.1), and PONG and
/// LAGRP echo likewise (§6.7.3, §6.7.5) — those frames carry *our* clock as
/// copied back by the peer, not the peer's own. Only media frames stamped by
/// the sender's own clock may resynchronise this reference.
public struct IAX2MiniTimestampExpander: Sendable, Equatable {
    /// The newest reconstructed 32-bit time-stamp of the stream.
    public private(set) var reference: UInt32

    /// - Parameter reference: 0 for a fresh call — the peer's clock begins at
    ///   zero (§6.2.2).
    public init(reference: UInt32 = 0) {
        self.reference = reference
    }

    /// Expands one mini-frame time-stamp and advances the reference if the
    /// frame is newer than everything seen so far.
    ///
    /// - Returns: `nil` when the frame expands to before the call's origin; see
    ///   ``IAX2MiniTimestamp/expand(_:near:)``.
    public mutating func expand(_ short: UInt16) -> UInt32? {
        guard let expanded = IAX2MiniTimestamp.expand(short, near: reference) else { return nil }
        // Forward-only, in modulo-2³² serial-number space rather than by plain
        // comparison, so the reference keeps advancing across a 32-bit wrap.
        if Int32(bitPattern: expanded &- reference) > 0 { reference = expanded }
        return expanded
    }

    /// Adopts an authoritative 32-bit time-stamp from a full media frame.
    public mutating func resynchronise(to full: UInt32) {
        reference = full
    }

    /// Back to the start of a call.
    public mutating func reset() {
        reference = 0
    }
}

// MARK: - Outbound (RFC 5456 §8.1.2, §6.10)

/// What ``IAX2VoiceTransmitter`` decided to put on the wire for one 20 ms of
/// audio.
public enum IAX2VoiceFrame: Sendable, Equatable {
    /// A full Voice frame (type `0x02`), which pins the codec for the mini
    /// frames that follow it (§8.1.2) and is sent reliably (§7).
    case full(subclass: IAX2Subclass, timestamp: UInt32, payload: [UInt8])

    /// A Mini Frame (§8.1.2): 4-octet header, 16-bit time-stamp, unreliable.
    case mini(timestamp: UInt16, payload: [UInt8])

    /// The encoded media payload, whichever form was chosen.
    public var payload: [UInt8] {
        switch self {
        case .full(_, _, let payload), .mini(_, let payload): return payload
        }
    }

    /// `true` for the full-frame form.
    public var isFull: Bool {
        if case .full = self { return true }
        return false
    }
}

/// Decides, for each outbound audio frame, whether it goes out as a full Voice
/// frame or a Mini Frame.
///
/// Pure state — no clock, no transport, no I/O. The caller supplies the call
/// time-stamp, which is what makes the resync boundary testable at any point in
/// a 32-bit clock without waiting 32.768 s for one.
///
/// ## The three rules
///
/// 1. **The first frame of a stream is full.** "The first voice frame of a call
///    SHOULD be sent using the CODEC agreed upon in the initial CODEC
///    negotiation" (§8.1.2), and a mini frame before it is a protocol error at
///    the receiver: "A VNAK is sent when a message is received out of order,
///    particularly when a Mini Frame is received before the first full voice
///    frame on a call." (§6.9.3)
/// 2. **A codec change is full.** "On-the-fly CODEC negotiation is permitted by
///    sending a full voice frame specifying the new CODEC to use in the
///    subclass field." (§8.1.2) — ``setFormat(_:)``.
/// 3. **Resynchronisation is full**, at every `0x8000` boundary — see below.
///
/// ## The resync contradiction, and how this resolves it
///
/// RFC 5456 gives two incompatible rules for how often a full frame must
/// interrupt the mini-frame stream:
///
/// > "Abbreviated 'Mini Frames' are normally used for audio and video; however,
/// > each time the time-stamp is a multiple of 32,768 (0x8000 hex), a standard
/// > or 'Full Frame' MUST be sent." (**§6.10** — 32,768 ms, MUST)
///
/// > "The 16-bit time-stamp wraps after 65.536 seconds, at which point a full
/// > frame SHOULD be sent to notify the remote peer that its time-stamp has
/// > been reset." (**§8.1.2** — 65,536 ms, SHOULD; the §9.6/§9.7 diagram notes
/// > agree with this one, "(every 65536 ms)")
///
/// This is one of the four self-contradictions catalogued in the Phase 2
/// preamble, and the conservative reading satisfies **both**: send a full frame
/// whenever the running 32-bit time-stamp crosses a multiple of `0x8000`. Every
/// `0x10000` boundary is also a multiple of `0x8000`, so obeying the stricter
/// §6.10 MUST necessarily obeys the §8.1.2 SHOULD as well. Doing more than the
/// minimum costs one ACKed voice frame every 32.768 s and nothing else.
///
/// Note the implementation tests for *crossing* a multiple rather than *landing
/// on* one. A 20 ms frame grid steps 0x7FF0 → 0x8004 and never lands on
/// `0x8000` at all, so the literal §6.10 test would fire only for senders whose
/// framing happens to divide 32,768 — which would leave the receiver's
/// expansion reference unrefreshed forever. Crossing is what §6.10 must mean
/// for the rule to do its job.
public struct IAX2VoiceTransmitter: Sendable, Equatable {
    /// The resync period, in milliseconds of call clock: `0x8000` (§6.10).
    public static let resyncInterval: UInt32 = 0x8000

    /// The codec named in the subclass of every full Voice frame this sends.
    public private(set) var format: MediaFormat

    /// Time-stamp of the most recent frame handed to ``next(timestamp:payload:)``.
    public private(set) var lastTimestamp: UInt32?

    /// Which `0x8000` epoch ``lastTimestamp`` fell in.
    private var lastEpoch: UInt32?

    /// Set by construction, ``setFormat(_:)`` and ``reset()``: the next frame
    /// must be full whatever the clock says.
    private var mustSendFull = true

    /// - Parameter format: the negotiated codec. G.711 µ-law by default —
    ///   `0x00000004` = `1 << 2`, subclass octet `0x82` (§8.7, §8.1.1).
    public init(format: MediaFormat = .g711MuLaw) {
        self.format = format
    }

    /// Changes codec mid-call. The next frame goes out full, carrying the new
    /// subclass, per §8.1.2's on-the-fly negotiation. A no-op if the format is
    /// unchanged, so this is safe to call on every ACCEPT.
    public mutating func setFormat(_ format: MediaFormat) {
        guard format != self.format else { return }
        self.format = format
        mustSendFull = true
    }

    /// Forgets the stream position: the next frame is full again. Call between
    /// calls, or after any interruption where the peer may have lost the codec
    /// pin.
    public mutating func reset() {
        lastTimestamp = nil
        lastEpoch = nil
        mustSendFull = true
    }

    /// Whether the next call to ``next(timestamp:payload:)`` will produce a
    /// full frame regardless of its time-stamp.
    public var willSendFull: Bool { mustSendFull }

    /// Chooses the wire form for one encoded audio frame.
    ///
    /// - Parameters:
    ///   - timestamp: the call's 32-bit clock for this frame (§8.1.1). Must be
    ///     non-decreasing — "time-stamps MAY be approximate, but, MUST be in
    ///     order" (§7).
    ///   - payload: encoded media, already in the codec named by ``format``.
    /// - Throws: ``IAX2VoiceError/formatNotRepresentable(_:)`` if ``format`` is
    ///   not exactly one §8.7 bit.
    public mutating func next(timestamp: UInt32, payload: [UInt8]) throws -> IAX2VoiceFrame {
        guard let subclass = IAX2Subclass(mediaFormat: format.rawValue) else {
            throw IAX2VoiceError.formatNotRepresentable(format)
        }

        let epoch = timestamp / Self.resyncInterval
        // §6.10 (MUST, every 32,768 ms) and §8.1.2 (SHOULD, every 65,536 ms):
        // resyncing on every 0x8000 crossing satisfies both, because every
        // 16-bit wrap is also a 0x8000 multiple. See the type documentation.
        let crossedBoundary = lastEpoch.map { $0 != epoch } ?? true
        let full = mustSendFull || crossedBoundary

        lastTimestamp = timestamp
        lastEpoch = epoch
        mustSendFull = false

        if full {
            return .full(subclass: subclass, timestamp: timestamp, payload: payload)
        }
        return .mini(timestamp: IAX2MiniTimestamp.truncate(timestamp), payload: payload)
    }
}

// MARK: - Playout

/// One frame tick of audio for the caller's output device.
///
/// **The contract, in one sentence: `pop()` always returns exactly
/// `samplesPerFrame` samples, so the caller can feed its audio device
/// unconditionally and never has to decide what silence sounds like.** `kind`
/// says what the samples are, for callers that want to drive a UI indicator or
/// count loss; callers that do not care can ignore it and just play `pcm`.
public struct IAX2VoicePlayout: Sendable, Equatable {
    /// What produced this tick's samples.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// Real decoded audio from a received frame.
        case audio
        /// The frame for this slot never arrived. See
        /// ``IAX2VoiceReceiver/pop()`` for exactly what is played instead.
        case concealment
        /// Nothing is playing: the buffer is priming, starving, or the stream
        /// has stopped. Digital silence.
        case silence
    }

    public let kind: Kind
    /// Signed 16-bit mono PCM at 8 kHz, always `samplesPerFrame` long.
    public let pcm: [Int16]

    public init(kind: Kind, pcm: [Int16]) {
        self.kind = kind
        self.pcm = pcm
    }
}

// MARK: - Inbound

/// Turns received IAX2 media frames into a steady stream of PCM.
///
/// Pure state, driven entirely by the caller: **no clock, no timer, no task,
/// no `Task.sleep`.** Frames go in with ``receive(_:arrivedAt:)`` as they
/// arrive off the network; PCM comes out of ``pop()``, which the caller calls
/// once per frame tick. That is what lets a recorded frame sequence be replayed
/// through it deterministically (AU-5).
///
/// The chain is: expand the 16-bit mini-frame time-stamp against the peer's
/// reconstructed 32-bit clock (``IAX2MiniTimestampExpander``) → push into
/// `JitterBuffer`, which reorders, drops duplicates and late frames, and decides
/// per tick between a frame, a concealment and silence → decode the popped
/// payload with `G711MuLawCodec`.
public struct IAX2VoiceReceiver: Sendable {

    // MARK: Results

    /// Why a frame produced no audio.
    public enum Rejection: Sendable, Equatable, CustomStringConvertible {
        /// Not something this decoder plays: a Video frame, a Comfort Noise
        /// frame (which carries a level in −dBov and no payload at all,
        /// §8.2.10), or any non-media frame that reached here by mistake.
        case notAudio

        /// A Mini Frame arrived before anything pinned the codec.
        ///
        /// > "The subclass is implicitly defined by the most recent full voice
        /// > frame of a call." (§8.1.2)
        ///
        /// With no full voice frame *and* no FORMAT from the ACCEPT (§6.2.3),
        /// the payload's codec is genuinely unknown and decoding it would be
        /// guessing. **Deviation to note:** §6.9.3 says "A VNAK is sent when a
        /// message is received out of order, particularly when a Mini Frame is
        /// received before the first full voice frame on a call" — this layer
        /// drops the frame but does not send that VNAK, because VNAK is a
        /// sequenced full frame and only `ReliableChannel` may emit one.
        case codecNotPinned

        /// The stream's codec is not one this client decodes. Only G.711 µ-law
        /// (`0x00000004`, §8.7) is implemented. The associated value is the
        /// decoded subclass, or `nil` if the subclass named no 32-bit format.
        case unsupportedFormat(UInt32?)

        /// The payload carried no octets at all, so there is no audio in it to
        /// play. Short and over-long payloads are **not** rejected — see
        /// ``IAX2VoiceReceiver`` on partial frames.
        case emptyPayload

        /// The payload is not one frame of the negotiated codec.
        ///
        /// **No longer raised for G.711**, and kept only so that a future
        /// block codec — one where a partial frame really is undecodable — has
        /// somewhere to report it. µ-law is sample-wise, so it has no such
        /// failure mode. See ``IAX2VoiceReceiver`` for what happens instead.
        case wrongPayloadLength(expected: Int, got: Int)

        /// The mini frame's 16-bit time-stamp expands to before the call's zero
        /// origin (§6.2.2). See ``IAX2MiniTimestamp/expand(_:near:)``.
        case timestampPrecedesCallOrigin(UInt16)

        public var description: String {
            switch self {
            case .notAudio:
                return "not an audio frame this decoder can play"
            case .codecNotPinned:
                return
                    "Mini Frame received before the codec was pinned by a full Voice frame or an "
                    + "ACCEPT FORMAT (RFC 5456 §8.1.2, §6.9.3)"
            case .unsupportedFormat(let value):
                let text = value.map { "0x\(String(format: "%08x", $0))" } ?? "an unusable subclass"
                return "media format \(text) is not decodable; G.711 µ-law only (RFC 5456 §8.7)"
            case .emptyPayload:
                return "media frame carried no payload octets"
            case .wrongPayloadLength(let expected, let got):
                return "media payload is \(got) octets; one frame of this codec is \(expected)"
            case .timestampPrecedesCallOrigin(let short):
                return
                    "mini-frame time-stamp 0x\(String(format: "%04x", short)) expands to before "
                    + "the call's zero origin (RFC 5456 §6.2.2)"
            }
        }
    }

    /// What ``receive(_:arrivedAt:)`` did with a frame.
    public enum Reception: Sendable, Equatable {
        /// Queued for playout at this reconstructed 32-bit time-stamp.
        case queued(timestamp: UInt32)
        /// Dropped, for this reason.
        case rejected(Rejection)
    }

    // MARK: Stored state

    /// The decoder. µ-law is the only codec in scope for IAX2 here (FR-1.1).
    public let codec = G711MuLawCodec()

    /// The codec the inbound stream is using, once anything has pinned it —
    /// the FORMAT IE of the ACCEPT (§6.2.3) or a full Voice frame (§8.1.2).
    public private(set) var format: MediaFormat?

    private var buffer: JitterBuffer
    private var expander = IAX2MiniTimestampExpander()

    /// The last frame actually decoded, and how many concealed slots have been
    /// emitted since. Together they are the concealment generator.
    private var lastDecoded: [Int16]?
    private var concealmentRun = 0

    // MARK: Init

    /// - Parameter buffer: the jitter buffer to play out of. The default is
    ///   `JitterBuffer()`'s own defaults: 20 ms frames, 60 ms initial depth,
    ///   adaptive within 60…200 ms (AU-3).
    public init(buffer: JitterBuffer = JitterBuffer()) {
        self.buffer = buffer
    }

    // MARK: Introspection

    /// The peer's newest reconstructed 32-bit call time-stamp.
    public var expandedTimestamp: UInt32 { expander.reference }
    /// Frames waiting in the jitter buffer.
    public var queuedFrameCount: Int { buffer.queuedFrameCount }
    /// Whether the jitter buffer has primed.
    public var isPrimed: Bool { buffer.isPrimed }
    /// The jitter buffer's current target depth (AU-3).
    public var currentTargetDepth: Duration { buffer.currentTargetDepth }
    /// Samples in every ``IAX2VoicePlayout``.
    public var samplesPerFrame: Int { codec.samplesPerFrame }

    // MARK: Control

    /// Pins the codec from the ACCEPT's FORMAT IE (§6.2.3, §8.6.8).
    ///
    /// "The first voice frame of a call SHOULD be sent using the CODEC agreed
    /// upon in the initial CODEC negotiation" (§8.1.2), so the negotiated
    /// format is a legitimate pin — and a peer that opens with mini frames
    /// straight after the ACCEPT is then decodable instead of being dropped as
    /// ``Rejection/codecNotPinned``.
    public mutating func pinFormat(_ format: MediaFormat) {
        self.format = format
    }

    /// Back to a just-constructed state, for a new call on a reused receiver.
    public mutating func reset() {
        buffer.reset()
        expander.reset()
        format = nil
        lastDecoded = nil
        concealmentRun = 0
    }

    // MARK: Receive

    /// Accepts one inbound media frame — a Mini Frame, or a full Voice or
    /// Comfort Noise frame — exactly as ``IAX2CallEvent/media(_:)`` delivers it.
    ///
    /// - Parameter arrivedAt: a monotonic arrival offset, from any origin the
    ///   caller likes; only differences matter. Supplying it drives the jitter
    ///   buffer's adaptive depth estimator (AU-3). Omitting it leaves the depth
    ///   where it is, which is what a fixture replay wants.
    public mutating func receive(
        _ frame: IAX2Frame,
        arrivedAt: Duration? = nil
    ) -> Reception {
        switch frame {
        case .full(let full):
            return receive(full: full, arrivedAt: arrivedAt)
        case .mini(let mini):
            return receive(mini: mini, arrivedAt: arrivedAt)
        }
    }

    private mutating func receive(full: IAX2FullFrame, arrivedAt: Duration?) -> Reception {
        switch full.type {
        case .voice:
            // A full Voice frame is authoritative twice over: its subclass pins
            // the codec for the mini frames that follow (§8.1.2), and its
            // 32-bit time-stamp re-anchors the expansion reference (§8.1.1,
            // §6.10, notes §11).
            expander.resynchronise(to: full.timestamp)
            guard let value = full.subclass.value else {
                return .rejected(.unsupportedFormat(nil))
            }
            format = MediaFormat(rawValue: value)
            guard value == MediaFormat.g711MuLaw.rawValue else {
                return .rejected(.unsupportedFormat(value))
            }
            return queue(payload: full.payload, timestamp: full.timestamp, arrivedAt: arrivedAt)

        case .comfortNoise:
            // "The subclass is the level of comfort noise in -dBov" (§8.2.10)
            // and the frame carries no data, so there is nothing to decode. It
            // is still the peer's own media clock, so it may re-anchor the
            // reference — unlike an ACK, PONG or LAGRP, which echo *our*
            // time-stamp back at us (§6.9.1, §6.7.3, §6.7.5) and must never be
            // used here.
            expander.resynchronise(to: full.timestamp)
            return .rejected(.notAudio)

        default:
            return .rejected(.notAudio)
        }
    }

    private mutating func receive(mini: IAX2MiniFrame, arrivedAt: Duration?) -> Reception {
        // "Mini frames are implicitly defined to be of type 'voice frame'…
        // The subclass is implicitly defined by the most recent full voice
        // frame of a call." (§8.1.2)
        guard let format else { return .rejected(.codecNotPinned) }
        guard format == .g711MuLaw else { return .rejected(.unsupportedFormat(format.rawValue)) }
        guard let timestamp = expander.expand(mini.timestamp) else {
            return .rejected(.timestampPrecedesCallOrigin(mini.timestamp))
        }
        return queue(payload: mini.payload, timestamp: timestamp, arrivedAt: arrivedAt)
    }

    /// µ-law's negative zero. Both `0xFF` and `0x7F` decode to zero
    /// (`G711MuLawCodec`); `0xFF` is what `encodeSample(0)` produces, so
    /// padding with it is indistinguishable from encoded silence.
    private static let silenceOctet: UInt8 = G711MuLawCodec.encodeSample(0)

    /// Files a payload of **any** length onto the 20 ms playout grid.
    ///
    /// ## Why not simply require 160 octets
    ///
    /// It used to, and a live ASL3 node broke it on the first call:
    ///
    /// ```
    /// RX media dropped: media payload is 44 octets; one frame of this codec is 160
    /// ```
    ///
    /// Nothing in RFC 5456 promises that a media frame is exactly one 20 ms
    /// frame's worth. §8.7 gives µ-law as "1 byte per sample" and stops there;
    /// the 160-octet figure is a consequence of 20 ms at 8 kHz, not a rule
    /// about what a peer may send. Asterisk emits a short frame at the tail of
    /// a playback — whatever is left when the file ends — and 44 octets is
    /// 5.5 ms of perfectly good audio. Dropping it discards real speech to
    /// protect a grid that G.711 does not have: it is sample-wise, so a
    /// partial frame is not a corrupt frame, just a shorter one.
    ///
    /// So: short payloads are padded to the slot with encoded silence, and
    /// over-long ones are split across consecutive slots, the last padded if
    /// it needs it. Only a genuinely empty payload is rejected, because there
    /// is no audio in it. A block codec added later would need the old strict
    /// behaviour — hence ``Rejection/wrongPayloadLength`` still exists.
    private mutating func queue(
        payload: [UInt8],
        timestamp: UInt32,
        arrivedAt: Duration?
    ) -> Reception {
        guard !payload.isEmpty else { return .rejected(.emptyPayload) }

        let octetsPerSlot = codec.bytesPerFrame
        // µ-law is one octet per sample at 8 kHz (§8.6.32, §8.7), so a slot's
        // worth of octets is a slot's worth of milliseconds ÷ 8.
        let millisecondsPerSlot = UInt32(codec.samplesPerFrame / 8)

        var offset = 0
        var slot = timestamp
        while offset < payload.count {
            let end = min(offset + octetsPerSlot, payload.count)
            var chunk = Array(payload[offset..<end])
            if chunk.count < octetsPerSlot {
                chunk.append(
                    contentsOf: repeatElement(
                        Self.silenceOctet, count: octetsPerSlot - chunk.count))
            }
            let timed = TimedFrame(timestamp: slot, payload: chunk)
            if let arrivedAt {
                buffer.push(timed, arrivedAt: arrivedAt)
            } else {
                buffer.push(timed)
            }
            offset = end
            slot &+= millisecondsPerSlot
        }
        return .queued(timestamp: timestamp)
    }

    // MARK: Play out

    /// Produces one frame tick of PCM. Call exactly once per 20 ms of playout.
    ///
    /// ## The concealment and silence contract
    ///
    /// `JitterBuffer` answers each tick with `.frame`, `.concealment` or
    /// `.silence`; this is what each becomes, and every one of the three
    /// returns exactly `samplesPerFrame` samples:
    ///
    /// - `.frame` → ``IAX2VoicePlayout/Kind/audio``: the payload decoded
    ///   through `G711MuLawCodec`.
    /// - `.concealment` → ``IAX2VoicePlayout/Kind/concealment``: **the last
    ///   decoded frame repeated, halved in amplitude once per successive
    ///   concealed slot.** The first concealed slot repeats at full gain
    ///   (which is what makes a single lost packet inaudible), the second at
    ///   −6 dB, the third at −12 dB, and so on, so a run fades to nothing in
    ///   about five slots — 100 ms — instead of buzzing. Halving is an
    ///   arithmetic right shift, so the output is exactly reproducible with no
    ///   floating point anywhere. `JitterBuffer` independently caps how long a
    ///   run can last (200 ms) before it re-anchors, so the fade never has to
    ///   be the only defence. With nothing decoded yet, the concealed slot is
    ///   silence.
    /// - `.silence` → ``IAX2VoicePlayout/Kind/silence``: digital silence, all
    ///   zeros. It also clears the concealment memory, so the next talk spurt
    ///   starts from real audio rather than fading in from a frame that belongs
    ///   to the last one.
    ///
    /// A payload that will not decode — which cannot happen, since
    /// ``receive(_:arrivedAt:)`` checks the length before queueing — degrades
    /// to silence rather than throwing out of the playout path.
    public mutating func pop() -> IAX2VoicePlayout {
        switch buffer.pop() {
        case .frame(let payload):
            guard let pcm = try? codec.decode(payload) else {
                return IAX2VoicePlayout(kind: .silence, pcm: silentFrame())
            }
            lastDecoded = pcm
            concealmentRun = 0
            return IAX2VoicePlayout(kind: .audio, pcm: pcm)

        case .concealment:
            let pcm = concealedFrame()
            concealmentRun += 1
            return IAX2VoicePlayout(kind: .concealment, pcm: pcm)

        case .silence:
            concealmentRun = 0
            lastDecoded = nil
            return IAX2VoicePlayout(kind: .silence, pcm: silentFrame())
        }
    }

    private func silentFrame() -> [Int16] {
        [Int16](repeating: 0, count: codec.samplesPerFrame)
    }

    private func concealedFrame() -> [Int16] {
        guard let lastDecoded else { return silentFrame() }
        // −6 dB per successive concealed slot; 15 shifts is already zero for
        // every representable sample, so the shift is clamped there.
        let shift = min(concealmentRun, 15)
        guard shift > 0 else { return lastDecoded }
        return lastDecoded.map { Int16(truncatingIfNeeded: Int($0) >> shift) }
    }
}

// MARK: - IAX2VoiceStream

/// What ``IAX2VoiceStream/handle(_:)`` made of a call event.
public enum IAX2VoiceStreamEvent: Sendable, Equatable {
    /// The ACCEPT named a codec (§6.2.3, §8.6.8); both directions adopted it.
    case formatNegotiated(MediaFormat)
    /// An inbound media frame was queued for playout at this reconstructed
    /// 32-bit time-stamp.
    case audioQueued(timestamp: UInt32)
    /// An inbound media frame produced no audio.
    case audioRejected(IAX2VoiceReceiver.Rejection)
    /// An inbound DTMF digit (§6.10.1, §8.2.1). One frame, one whole digit —
    /// RFC 5456 has no begin/end semantics (notes §14).
    case dtmf(IAX2DTMFDigit)
}

/// The voice and DTMF path of one call: PCM in, PCM out, digits both ways.
///
/// This is IAX-6 and IAX-7 sitting on the seam `IAX2Call` left for them. It
/// composes three things and adds no wire behaviour of its own beyond the
/// full-versus-mini decision:
///
/// - ``IAX2VoiceTransmitter`` — chooses the outbound frame form and owns the
///   `0x8000` resync rule (§6.10, §8.1.2);
/// - ``IAX2VoiceReceiver`` — expands mini time-stamps, buffers, decodes;
/// - ``IAX2DTMFDigit`` — validates and codes a digit (§8.2.1).
///
/// ## It is driven, not driving
///
/// There is **no clock, no timer, no task and no `Task.sleep`** here. Inbound
/// frames are handed in by whoever owns the call's event stream, via
/// ``handle(_:)``; playout happens when the caller calls ``pop()``; outbound
/// audio goes when the caller calls ``send(pcm:timestamp:)``. IAX-8 supplies
/// the 20 ms tick and the event pump; a test supplies a recorded frame
/// sequence, and gets the same answers every time (AU-5).
///
/// ## Time-stamps
///
/// Outbound frames are stamped from the call's own clock
/// (``IAX2Call/timestampMilliseconds``, "the number of milliseconds since the
/// first transmission of the call", §8.1.1) unless the caller passes its own —
/// which a caller pacing its own capture grid should, since a stamp taken per
/// frame from a wall clock jitters and "time-stamps… MUST be in order" (§7).
public actor IAX2VoiceStream {

    /// The call this stream sends on. Not owned: closing it is the client's
    /// business.
    private let call: IAX2Call

    private var transmitter: IAX2VoiceTransmitter
    private var receiver: IAX2VoiceReceiver
    private let encoder = G711MuLawCodec()

    /// - Parameters:
    ///   - call: an `IAX2Call`. Media requires an established leg, so sends
    ///     throw until the peer has ACCEPTed (full frames) or the call is `up`
    ///     (mini frames) — `IAX2Call` enforces both.
    ///   - format: the codec to open with. Replaced by the ACCEPT's FORMAT IE
    ///     when ``handle(_:)`` sees one.
    ///   - buffer: the inbound jitter buffer (AU-3).
    public init(
        call: IAX2Call,
        format: MediaFormat = .g711MuLaw,
        buffer: JitterBuffer = JitterBuffer()
    ) {
        self.call = call
        self.transmitter = IAX2VoiceTransmitter(format: format)
        self.receiver = IAX2VoiceReceiver(buffer: buffer)
    }

    // MARK: Introspection

    /// The codec named in outbound full Voice frames.
    public var outboundFormat: MediaFormat { transmitter.format }
    /// The codec the inbound stream is using, once pinned.
    public var inboundFormat: MediaFormat? { receiver.format }
    /// The peer's newest reconstructed 32-bit call time-stamp.
    public var expandedInboundTimestamp: UInt32 { receiver.expandedTimestamp }
    /// Frames waiting in the inbound jitter buffer.
    public var queuedFrameCount: Int { receiver.queuedFrameCount }
    /// Whether the next outbound frame will be a full frame.
    public var willSendFullFrame: Bool { transmitter.willSendFull }
    /// Samples in every ``IAX2VoicePlayout``, and required in every
    /// ``send(pcm:timestamp:)``.
    public nonisolated var samplesPerFrame: Int { 160 }

    // MARK: Outbound audio

    /// Encodes 20 ms of PCM and sends it as a full Voice frame or a Mini Frame,
    /// whichever the RFC requires for this time-stamp.
    ///
    /// - Parameters:
    ///   - pcm: exactly `samplesPerFrame` (160) samples of 8 kHz signed 16-bit
    ///     mono.
    ///   - timestamp: the call time-stamp for this frame; the call's own clock
    ///     if omitted.
    /// - Returns: what went on the wire, for callers that want to assert or
    ///   log it.
    /// - Throws: `G711Error.wrongFrameLength` for the wrong number of samples,
    ///   ``IAX2VoiceError/unsupportedFormat(_:)`` if the negotiated codec is
    ///   not µ-law, or `IAX2CallError.notEstablished` if the leg is not ready.
    @discardableResult
    public func send(pcm: [Int16], timestamp: UInt32? = nil) async throws -> IAX2VoiceFrame {
        guard transmitter.format == .g711MuLaw else {
            throw IAX2VoiceError.unsupportedFormat(transmitter.format)
        }
        let encoded = try encoder.encode(pcm)
        return try await send(encoded: encoded, timestamp: timestamp)
    }

    /// Sends an already-encoded media payload. The codec-agnostic form of
    /// ``send(pcm:timestamp:)``.
    @discardableResult
    public func send(encoded payload: [UInt8], timestamp: UInt32? = nil) async throws
        -> IAX2VoiceFrame
    {
        let stamp: UInt32
        if let timestamp {
            stamp = timestamp
        } else {
            stamp = await call.timestampMilliseconds
        }
        // The transmitter is a value, so a failed write can be undone exactly:
        // otherwise a mini frame refused because the leg was not yet `up` would
        // consume the epoch that owed the peer a full frame, and the codec pin
        // would never be sent.
        let saved = transmitter
        let frame = try transmitter.next(timestamp: stamp, payload: payload)
        do {
            switch frame {
            case .full(let subclass, let stamp, let payload):
                _ = try await call.send(
                    type: .voice, subclass: subclass, timestamp: stamp, payload: payload)
            case .mini(let short, let payload):
                try await call.sendMini(timestamp: short, payload: payload)
            }
        } catch {
            transmitter = saved
            throw error
        }
        return frame
    }

    /// Changes the outbound codec. The next frame goes out full, carrying the
    /// new subclass (§8.1.2).
    public func setOutboundFormat(_ format: MediaFormat) {
        transmitter.setFormat(format)
    }

    // MARK: Outbound DTMF (IAX-7)

    /// Sends one DTMF digit (§6.10.1, §8.2.1).
    ///
    /// One full frame of type `0x01` with the digit in the subclass and no
    /// payload — that is the entire protocol. RFC 5456 defines **no** begin or
    /// end frame, no duration and no volume, so nothing else is sent and
    /// nothing is scheduled (notes §14). The frame is reliable: `ReliableChannel`
    /// numbers it, the peer MUST ACK it (§6.10), and it is retransmitted until
    /// acknowledged (§7).
    ///
    /// - Parameter timestamp: the call time-stamp for the frame; the call's own
    ///   clock if omitted.
    /// - Throws: ``IAX2DTMFError/invalidDigit(_:)`` for anything outside
    ///   `0-9`, `A-D`, `*`, `#`; `IAX2CallError.notEstablished` before the leg
    ///   is ACCEPTed.
    @discardableResult
    public func send(dtmf character: Character, timestamp: UInt32? = nil) async throws
        -> IAX2FullFrame
    {
        try await send(dtmf: try IAX2DTMFDigit(character), timestamp: timestamp)
    }

    /// Sends one already-validated DTMF digit.
    @discardableResult
    public func send(dtmf digit: IAX2DTMFDigit, timestamp: UInt32? = nil) async throws
        -> IAX2FullFrame
    {
        try await call.send(
            type: IAX2DTMFDigit.frameType,
            subclass: digit.subclass,
            timestamp: timestamp,
            payload: [])
    }

    /// Sends a string of DTMF digits, one frame each, in order.
    ///
    /// Validates the whole string first, so an invalid character part-way
    /// through does not leave half a sequence on the wire. Named differently
    /// from ``send(dtmf:)`` on purpose: a bare `"5"` literal is both a
    /// `Character` and a `String`, and an ambiguous overload set would make
    /// every call site say which.
    @discardableResult
    public func send(dtmfSequence digits: String) async throws -> [IAX2FullFrame] {
        let validated = try digits.map { try IAX2DTMFDigit($0) }
        var frames: [IAX2FullFrame] = []
        for digit in validated {
            frames.append(try await send(dtmf: digit))
        }
        return frames
    }

    // MARK: Inbound

    /// Feeds one call event in. Everything this stream cares about arrives this
    /// way; anything else answers `nil`.
    ///
    /// - ``IAX2CallEvent/accepted(format:)`` pins the codec in both directions
    ///   (§6.2.3, §8.1.2).
    /// - ``IAX2CallEvent/media(_:)`` is a Mini Frame or a full Voice/Comfort
    ///   Noise frame, handed to the receiver untouched.
    /// - ``IAX2CallEvent/other(_:)`` is where inbound DTMF arrives (§8.2.1).
    @discardableResult
    public func handle(_ event: IAX2CallEvent) -> IAX2VoiceStreamEvent? {
        switch event {
        case .accepted(let format):
            guard let format else { return nil }
            receiver.pinFormat(format)
            transmitter.setFormat(format)
            return .formatNegotiated(format)

        case .media(let frame):
            switch receiver.receive(frame) {
            case .queued(let timestamp): return .audioQueued(timestamp: timestamp)
            case .rejected(let rejection): return .audioRejected(rejection)
            }

        case .other(let full):
            guard let digit = IAX2DTMFDigit(frame: full) else { return nil }
            return .dtmf(digit)

        default:
            return nil
        }
    }

    /// Feeds one media frame straight in, with an optional arrival time for the
    /// adaptive-depth estimator (AU-3). ``handle(_:)`` is the usual path; this
    /// is for a caller that has its own arrival timing.
    @discardableResult
    public func receive(
        _ frame: IAX2Frame,
        arrivedAt: Duration? = nil
    ) -> IAX2VoiceReceiver.Reception {
        receiver.receive(frame, arrivedAt: arrivedAt)
    }

    /// One frame tick of PCM for the output device. See
    /// ``IAX2VoiceReceiver/pop()`` for the concealment and silence contract.
    public func pop() -> IAX2VoicePlayout {
        receiver.pop()
    }

    /// Returns both directions to their opening state, for a new call on a
    /// reused stream.
    public func reset() {
        transmitter.reset()
        receiver.reset()
    }
}
