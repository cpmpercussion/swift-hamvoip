// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Transmit state for a connected network.
public enum TransmitState: Sendable, Equatable {
    case receiving
    case transmitting(since: Date)
    case idle
}

/// Every mode conforms to this. The SwiftUI layer talks only to this protocol
/// and knows nothing about IAX2, M17 or EchoLink specifics.
///
/// The protocol carries everything an application needs to run a session end to
/// end: state, events, audio in, audio out, and the four verbs. If an app finds
/// itself reaching for a concrete client type, something is missing *here* and
/// should be added here — not translated in the app's composition root.
///
/// ## The three seams
///
/// | Seam | Member | Direction |
/// |---|---|---|
/// | Events | ``radioEvents`` | client → app |
/// | Received audio | ``receivedAudio`` | client → app |
/// | Transmit audio | ``send(pcm:)`` | app → client |
///
/// Audio *devices* are not in here. `AudioPipeline` (RC-7) is attached by the
/// application layer, which is what lets one client drive a CLI harness, an
/// iOS app and a fixture-driven test with no device at all (AU-5).
///
/// ## Lifecycle contract
///
/// A client is **single-session**. The sequence is:
///
/// ```
/// init ──▶ connect(to:) ──▶ [ startTransmit / stopTransmit / send(pcm:) ] ──▶ disconnect()
///                                                                                  │
///                                                                            (terminal)
/// ```
///
/// - ``connect(to:)`` returns when the link is up, or throws. A failed connect
///   leaves the client able to try again.
/// - ``disconnect()`` is **terminal and idempotent**. It finishes
///   ``radioEvents`` and ``receivedAudio`` — a consumer looping over a stream
///   needs that loop to end — and a finished `AsyncStream` cannot be reopened.
///   **To reconnect, build a new client.** A conforming type must throw from
///   ``connect(to:)`` after ``disconnect()`` rather than appearing to succeed
///   with dead streams.
/// - A session that ends *remotely* (the node hung up, the transport died) is
///   reported as ``RadioEvent/disconnected(_:)`` and leaves the streams **open**,
///   so the application can hear about it. Such a client is still spent: call
///   ``disconnect()`` to release it and build a new one to reconnect.
///
/// This is a real constraint on app architecture — a view model cannot hold one
/// client for the lifetime of a screen — and it is documented rather than
/// designed away because the alternative (streams that reopen) would mean
/// `for await` loops that never end.
public protocol NetworkClient: AnyObject, Sendable {
    associatedtype Destination

    var state: TransmitState { get }

    /// Connection lifecycle, transmit transitions, watchdog expiry, DTMF and
    /// audio problems, in order.
    ///
    /// Named `radioEvents` rather than `events` so that a concrete client can
    /// keep a mode-specific `events` stream alongside it: `IAX2Client` publishes
    /// `AsyncStream<IAX2ClientEvent>` there for callers that want RFC 5456
    /// detail, and translates onto this one for callers that want a radio.
    ///
    /// Buffered without limit — an event that is dropped because the UI was
    /// briefly busy is an event the operator never sees, and SF-1 says they
    /// must see the watchdog fire. Finished by ``disconnect()``.
    ///
    /// Treat as single-consumer, like `DatagramTransport.incoming`: an
    /// `AsyncStream` splits its elements between iterators rather than
    /// duplicating them.
    var radioEvents: AsyncStream<RadioEvent> { get }

    /// Decoded, levelled PCM ready for an output device: 8 kHz signed 16-bit
    /// mono, one frame per media tick, starting when the link comes up and
    /// finishing at ``disconnect()``.
    ///
    /// Concealment and silence are already substituted for missing frames, so a
    /// consumer feeds its audio device and never has to decide what a gap
    /// sounds like. Single-consumer, as above.
    var receivedAudio: AsyncStream<[Int16]> { get }

    func connect(to destination: Destination) async throws

    /// Ends the session and finishes both streams. Terminal and idempotent —
    /// see the lifecycle contract above.
    func disconnect() async

    /// Begin transmitting. Implementations must honour the transmit watchdog
    /// (SF-1) and drop on interruption (SF-3).
    func startTransmit() async throws
    func stopTransmit() async

    /// Offers one frame of captured audio for transmission.
    ///
    /// **Audio offered while not transmitting is discarded, silently, and that
    /// is not an error.** A capture pipeline runs continuously and hands over
    /// every frame it produces; it is the client's job — not the microphone's —
    /// to know that PTT is released. Silently dropping is also the fail-safe
    /// direction: the failure mode of a mistake here is dead air, not an open
    /// microphone. A caller must therefore not treat a successful return as
    /// evidence that anything went on the air; ``state`` is what says that.
    ///
    /// - Parameter pcm: one frame of 8 kHz signed 16-bit mono, of whatever
    ///   length the mode's codec frames at (160 samples — 20 ms — for both
    ///   G.711 µ-law and Codec2 3200).
    /// - Throws: only for a genuine failure — a wrong frame length, or a link
    ///   that died between the check and the write. Never merely for being
    ///   unkeyed.
    func send(pcm: [Int16]) async throws
}
