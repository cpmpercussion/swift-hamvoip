// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Disconnect reason

/// Why a link ended, in terms every mode shares.
///
/// Each mode has a richer story — `IAX2CallTermination` names the RFC 5456
/// message that ended the leg, `M17DisconnectReason` names the reflector
/// packet — and both stay available on the concrete client's own event stream.
/// This is the part an application can actually act on: whether to offer a
/// reconnect button, whether to blame the user's credentials, whether to say
/// "the node hung up" or "the network went away".
public enum RadioDisconnectReason: Sendable, Equatable, CustomStringConvertible {
    /// We ended it: ``NetworkClient/disconnect()``, or a local hang-up.
    case localRequest

    /// The peer ended it — an IAX2 HANGUP, an M17 `DISC`. `detail` is
    /// whatever reason it gave, if any.
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
    /// wrong length, or before anything established what codec it was in.
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
/// digit that arrived, audio that is arriving but cannot be played.
///
/// ## Why one enum rather than an `associatedtype Event`
///
/// An associated event type would let each mode publish its own vocabulary,
/// but every consumer would then have to be generic over it — a view model, a
/// Live Activity, a log formatter — and none of them would gain anything,
/// because they can only act on what all modes have in common. The mode-
/// specific vocabulary is not lost: each client keeps its own detailed stream
/// (`IAX2Client.events` of `IAX2ClientEvent`) for callers that want it, and
/// translates onto this one for callers that do not. Cases are deliberately
/// coarse and carry `String?` details rather than mode-specific types, so that
/// adding a mode does not change this enum's shape.
///
/// ## Coverage
///
/// Every ``IAX2ClientEvent`` maps onto a case here, and so does every
/// `M17ReflectorEvent`: `.connecting` → ``connecting``, `.linked` →
/// ``connected``, `.disconnected(reason)` → ``disconnected(_:)``, and a
/// `.stream` packet becomes received audio — or, when
/// `packet.playability == .encrypted`, an
/// ``incomingAudioDropped(_:)`` carrying ``RadioAudioIssue/encrypted``.
public enum RadioEvent: Sendable, Equatable, CustomStringConvertible {
    /// A connection attempt is under way. Optional: a mode whose `connect(to:)`
    /// does not return until the link is up need never emit it.
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
        }
    }
}
