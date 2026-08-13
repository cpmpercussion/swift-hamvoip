// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import M17Kit

/// RC-10: M17's vocabulary onto the mode-agnostic `RadioEvent`.
///
/// The interesting half here is stream activity, which IAX2 has no equivalent
/// for — M17 is the mode that made ``RadioEvent/remoteTransmitStarted(station:)``
/// necessary.
final class M17RadioEventTranslationTests: XCTestCase {

    private func address(_ callsign: String) throws -> M17Address {
        try M17Address(callsign: callsign)
    }

    // MARK: - Coverage

    func testEveryEventTranslates() throws {
        let events: [M17ClientEvent] = [
            .connecting,
            .linked(module: "A"),
            .streamStarted(source: try address("VK1XYZ"), streamID: 0x1234),
            .streamEnded(source: try address("VK1XYZ"), reason: .lastFrame),
            .streamRejected(.encrypted),
            .transmitting,
            .receiving,
            .transmitWatchdogExpired(.seconds(180)),
            .disconnected(.localRequest),
            .disconnected(nil),
        ]
        for event in events {
            XCTAssertNotNil(event.radioEvent, "\(event) must have a mode-agnostic form")
        }
    }

    func testLifecycleAndTransmitEventsMapOneForOne() {
        XCTAssertEqual(M17ClientEvent.connecting.radioEvent, .connecting)
        XCTAssertEqual(M17ClientEvent.linked(module: "A").radioEvent, .connected)
        XCTAssertEqual(M17ClientEvent.transmitting.radioEvent, .transmitting)
        XCTAssertEqual(M17ClientEvent.receiving.radioEvent, .receiving)
        XCTAssertEqual(
            M17ClientEvent.transmitWatchdogExpired(.seconds(60)).radioEvent,
            .transmitWatchdogExpired(.seconds(60)))
    }

    /// The module letter is dropped, so two modules must produce the same event.
    /// `M17Client.linkedModule` is where it stays available.
    func testTheModuleLetterIsDropped() {
        XCTAssertEqual(
            M17ClientEvent.linked(module: "A").radioEvent,
            M17ClientEvent.linked(module: "D").radioEvent)
    }

    // MARK: - Stream activity

    /// A station taking the channel carries its callsign through, because "who
    /// is talking" is the label this event exists to feed.
    func testStreamStartCarriesTheCallsignAndDropsTheStreamID() throws {
        XCTAssertEqual(
            M17ClientEvent.streamStarted(source: try address("VK1XYZ"), streamID: 0x1234)
                .radioEvent,
            .remoteTransmitStarted(station: "VK1XYZ"))

        // The stream ID identifies an over on the wire and means nothing above
        // the protocol, so two IDs are the same event.
        XCTAssertEqual(
            M17ClientEvent.streamStarted(source: try address("VK1XYZ"), streamID: 0x0001)
                .radioEvent,
            M17ClientEvent.streamStarted(source: try address("VK1XYZ"), streamID: 0xFFFF)
                .radioEvent)
    }

    /// `preempted` is the distinction worth keeping: it means somebody was talked
    /// over, which an operator should see rather than have the UI silently swap
    /// one callsign for another.
    func testBeingCutOffSurvivesTranslationAsDisplaced() throws {
        XCTAssertEqual(
            M17ClientEvent.streamEnded(source: try address("VK1XYZ"), reason: .preempted)
                .radioEvent,
            .remoteTransmitEnded(station: "VK1XYZ", displaced: true))
        XCTAssertEqual(
            M17ClientEvent.streamEnded(source: try address("VK1XYZ"), reason: .lastFrame)
                .radioEvent,
            .remoteTransmitEnded(station: "VK1XYZ", displaced: false))
        XCTAssertNotEqual(
            M17ClientEvent.streamEnded(source: try address("VK1XYZ"), reason: .preempted)
                .radioEvent,
            M17ClientEvent.streamEnded(source: try address("VK1XYZ"), reason: .lastFrame)
                .radioEvent)
    }

    // MARK: - Rejections

    /// FR-2.5: an encrypted stream is not missing audio, it is unlistenable
    /// audio, and there is deliberately no decrypt path. It must stay its own
    /// kind rather than collapse into "undecodable".
    func testEncryptedStaysItsOwnKind() {
        XCTAssertEqual(M17StreamReceiver.Rejection.encrypted.radioAudioIssue, .encrypted)

        let others: [M17StreamReceiver.Rejection] = [
            .crcFailed(carried: 0x1111, computed: 0x2222),
            .malformedPayload(payloadBytes: 15, codecFrameBytes: 8),
            .wrongStream(expected: 0x0001, actual: 0x0002),
        ]
        for rejection in others {
            XCTAssertEqual(
                rejection.radioAudioIssue, .undecodable(detail: rejection.description))
            XCTAssertNotEqual(rejection.radioAudioIssue, .encrypted)
        }
    }

    // MARK: - Disconnects

    /// A NACK means the link never existed — usually the module letter or the
    /// callsign, both of which the operator can fix — so it must not look like
    /// the reflector having hung up on an established link.
    func testARefusedLinkIsDistinctFromOneTheReflectorEnded() {
        let rejected = M17DisconnectReason.rejectedByReflector.radioDisconnectReason
        let remote = M17DisconnectReason.remoteRequest.radioDisconnectReason
        XCTAssertEqual(rejected, .rejected(detail: "the reflector sent NACK"))
        XCTAssertEqual(remote, .remoteRequest(detail: "the reflector sent DISC"))
        XCTAssertNotEqual(rejected, remote)
    }

    /// A reflector that stops sending PING is gone; it just never said so. That
    /// is `linkTimedOut`, not a transport failure — nothing broke locally.
    func testAStalledKeepaliveReadsAsAQuietLink() {
        XCTAssertEqual(
            M17DisconnectReason.keepaliveTimeout.radioDisconnectReason, .linkTimedOut(nil))
        XCTAssertEqual(
            M17DisconnectReason.connectTimeout.radioDisconnectReason, .connectTimedOut(nil))
        XCTAssertEqual(M17DisconnectReason.localRequest.radioDisconnectReason, .localRequest)
        XCTAssertEqual(
            M17DisconnectReason.transportClosed.radioDisconnectReason, .transportFailure())
    }

    func testATerminationlessDisconnectIsATransportFailure() {
        XCTAssertEqual(
            M17ClientEvent.disconnected(nil).radioEvent, .disconnected(.transportFailure()))
    }
}
