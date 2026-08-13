// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Disconnect reason

/// Why a link ended, in terms every mode shares.
///
/// Each mode has a richer story — `IAX2CallTermination` names the RFC 5456
/// message that ended the leg, `M17DisconnectReason` names the reflector
/// packet, `EchoLinkDisconnectReason` names the step of the proxied session —
/// and all three stay available on the concrete client's own event stream. This
/// is the part an application can actually act on: whether to offer a reconnect
/// button, whether to blame the user's credentials, whether to say "the node
/// hung up" or "the network went away".
public enum RadioDisconnectReason: Sendable, Equatable, CustomStringConvertible {
    /// We ended it: ``NetworkClient/disconnect()``, or a local hang-up.
    case localRequest

    /// The peer ended it — an IAX2 HANGUP, an M17 `DISC`, an EchoLink node
    /// saying goodbye. `detail` is whatever reason it gave, if any.
    case remoteRequest(detail: String? = nil)

    /// The peer refused the session — an IAX2 REJECT, an M17 `NACK`. Distinct
    /// from ``remoteRequest(detail:)`` because it means the session never
    /// existed, which is usually a credentials or node-name problem the
    /// operator can fix.
    case rejected(detail: String? = nil)

    /// The peer never completed setup within the local connect deadline.
    /// `nil` when the mode does not report the deadline it used.
    case connectTimedOut(Duration? = nil)

    /// An established link went quiet for longer than the mode allows —
    /// IAX2's retransmission ladder exhausting, M17's `PING` keepalive
    /// stopping. The peer is gone; it just never said so.
    case linkTimedOut(Duration? = nil)

    /// The transport closed or failed underneath the session. `nil` detail
    /// means it simply went away.
    case transportFailure(detail: String? = nil)

    /// The peer broke a rule of the protocol and the session was destroyed.
    case protocolFailure(detail: String? = nil)

    public var description: String {
        switch self {
        case .localRequest:
            return "disconnected locally"
        case .remoteRequest(let detail):
            return detail.map { "the other end disconnected: \($0)" } ?? "the other end disconnected"
        case .rejected(let detail):
            return detail.map { "the connection was refused: \($0)" } ?? "the connection was refused"
        case .connectTimedOut(let timeout):
            return timeout.map { "the other end did not answer within \($0)" }
                ?? "the other end did not answer"
        case .linkTimedOut(let timeout):
            return timeout.map { "the link went quiet for \($0)" } ?? "the link went quiet"
        case .transportFailure(let detail):
            return detail.map { "the network connection failed: \($0)" }
                ?? "the network connection failed"
        case .protocolFailure(let detail):
            return detail.map { "protocol error: \($0)" } ?? "protocol error"
        }
    }
}

// MARK: - Audio issue

/// Why inbound audio is being dropped rather than played.
///
/// Modes report this when the reason *changes*, not once per frame: a stream
/// that cannot be decoded produces fifty of these a second, and the second one
/// tells the operator nothing the first did not.
public enum RadioAudioIssue: Sendable, Equatable, CustomStringConvertible {
    /// The stream's codec is not one this build decodes.
    case unsupportedFormat(detail: String? = nil)

    /// The stream is encrypted and there is no decrypt path — deliberately, per
    /// FR-2.5. Worth showing: the audio is not missing, it is unlistenable.
    case encrypted

    /// The audio arrived but could not be turned into samples: malformed,
    /// wrong length, corrupt, or before anything established what codec it was
    /// in.
    case undecodable(detail: String? = nil)

    public var description: String {
        switch self {
        case .unsupportedFormat(let detail):
            return detail.map { "unsupported audio format: \($0)" } ?? "unsupported audio format"
        case .encrypted:
            return "the incoming stream is encrypted and cannot be played"
        case .undecodable(let detail):
            return detail.map { "incoming audio dropped: \($0)" } ?? "incoming audio dropped"
        }
    }
}

// MARK: - RadioEvent

/// What a ``NetworkClient`` tells its owner, beyond ``NetworkClient/state``.
///
/// `state` is enough to drive a PTT button. This is what an application needs
/// to *explain* things: a node that hung up, a watchdog that fired, a DTMF
/// digit that arrived, audio that is arriving but cannot be played, another
/// station taking the channel.
///
/// ## Why one enum rather than an `associatedtype Event`
///
/// An associated event type would let each mode publish its own vocabulary,
/// but every consumer would then have to be generic over it — a view model, a
/// Live Activity, a log formatter — and none of them would gain anything,
/// because they can only act on what all modes have in common. The mode-
/// specific vocabulary is not lost: each client keeps its own detailed stream
/// (`IAX2Client.events` of `IAX2ClientEvent`, and the same on `M17Client` and
/// `EchoLinkClient`) for callers that want it, and translates onto this one for
/// callers that do not. Cases are deliberately coarse and carry `String?`
/// details rather than mode-specific types, so that adding a mode does not
/// change this enum's shape.
///
/// ## Coverage, and what translation drops
///
/// Each mode provides `radioEvent`, an `Optional<RadioEvent>`: `nil` means the
/// event has no mode-agnostic meaning worth reporting, not that it was
/// forgotten. Every such case is named in that mode's translation. Three
/// examples of the shape of what is dropped, all deliberate:
///
/// - **IAX2** translates totally; nothing is dropped. The negotiated
///   `MediaFormat` is the only detail lost, and `IAX2Client.negotiatedFormat`
///   still answers for it.
/// - **M17** drops the stream ID, which identifies an over on the wire and
///   means nothing above the protocol.
/// - **EchoLink** drops the two intermediate steps of its connect sequence
///   (`directoryLoggedIn`, `nodeAnswered`) because they happen *inside*
///   `connect(to:)`, which has not returned yet — an application awaiting it
///   cannot act on them, and the ``connected`` that follows is what it wants.
public enum RadioEvent: Sendable, Equatable, CustomStringConvertible {
    /// A connection attempt is under way. Optional: a mode whose `connect(to:)`
    /// does not return until the link is up need never emit it, and IAX2 does
    /// not.
    case connecting

    /// The link is up and media may flow.
    case connected

    /// The link ended. **Not** the same as ``NetworkClient/disconnect()``
    /// having been called — see that method's note on which paths emit this.
    case disconnected(RadioDisconnectReason)

    /// Transmission started.
    case transmitting

    /// Transmission stopped, for any reason.
    case receiving

    /// **SF-1.** The transmit watchdog reached its deadline and stopped
    /// transmission on the operator's behalf, after the carried timeout.
    ///
    /// SF-1 requires this to be visible to the operator, which is the whole
    /// reason this stream exists on the protocol rather than only on the
    /// concrete clients: it means a PTT was held — or stuck — for the entire
    /// timeout, and the app cannot show what it cannot see.
    case transmitWatchdogExpired(Duration)

    /// An inbound DTMF digit (FR-1.5). `0`–`9`, `A`–`D`, `*` or `#`.
    case dtmfReceived(Character)

    /// Inbound audio is being dropped, for this reason.
    case incomingAudioDropped(RadioAudioIssue)

    /// Another station started transmitting to us — an M17 stream opening, an
    /// EchoLink talkspurt beginning.
    ///
    /// A different axis from ``receiving``, which is about *our* PTT: this says
    /// somebody else has the channel, which is what a "who is talking" label
    /// needs. `station` is their callsign where the mode carries one, and `nil`
    /// where it does not — EchoLink's audio channel identifies the session, not
    /// each talkspurt.
    ///
    /// IAX2 emits neither this nor ``remoteTransmitEnded(station:displaced:)``:
    /// an AllStar node sends a continuous stream and marks no talkspurt
    /// boundaries in it.
    case remoteTransmitStarted(station: String? = nil)

    /// The station that was transmitting stopped.
    ///
    /// `displaced` is `true` when another station cut in and took the channel
    /// rather than the over ending normally — somebody being talked over, which
    /// is worth showing rather than silently replacing in the UI. EchoLink does
    /// not report talkspurt ends, so it never emits this.
    case remoteTransmitEnded(station: String? = nil, displaced: Bool = false)

    /// Human-readable information the far end sent about itself, for display —
    /// EchoLink's `oNDATA` text, which is how a node announces what it is.
    ///
    /// Text, deliberately: it is written by the far end for a human to read,
    /// and no mode gives it structure worth parsing.
    case stationInfo(String)

    public var description: String {
        switch self {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected(let reason): return "disconnected: \(reason)"
        case .transmitting: return "transmitting"
        case .receiving: return "receiving"
        case .transmitWatchdogExpired(let timeout):
            return "transmit watchdog expired after \(timeout)"
        case .dtmfReceived(let digit): return "DTMF \(digit)"
        case .incomingAudioDropped(let issue): return "\(issue)"
        case .remoteTransmitStarted(let station):
            return station.map { "\($0) started transmitting" } ?? "the other end started transmitting"
        case .remoteTransmitEnded(let station, let displaced):
            let who = station ?? "the other end"
            return displaced ? "\(who) was cut off by another station" : "\(who) stopped transmitting"
        case .stationInfo(let text): return "station info: \(text)"
        }
    }
}
