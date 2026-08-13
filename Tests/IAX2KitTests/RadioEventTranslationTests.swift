// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import IAX2Kit

/// RC-10: the translation from RFC 5456 vocabulary onto the mode-agnostic
/// `RadioEvent` an application reads.
///
/// These are pure-function tests over the mapping table. They exist because the
/// mapping is where a mode's detail is deliberately thrown away, and "thrown
/// away" and "lost by accident" look identical at a call site. A test that names
/// each pairing is what tells the two apart later.
final class IAX2RadioEventTranslationTests: XCTestCase {

    // MARK: - Events

    /// Alone among the three modes, IAX2 translates totally. If a case is ever
    /// added to `IAX2ClientEvent` that has no mode-agnostic meaning, this is the
    /// test that should be made to argue for it rather than quietly returning
    /// `nil`.
    func testEveryEventTranslates() throws {
        let events: [IAX2ClientEvent] = [
            .connected(format: .g711MuLaw),
            .connected(format: nil),
            .transmitting,
            .receiving,
            .transmitWatchdogExpired(.seconds(180)),
            .dtmf(try IAX2DTMFDigit("7")),
            .mediaRejected(.notAudio),
            .disconnected(.localHangup(cause: nil, causeCode: nil)),
            .disconnected(nil),
        ]
        for event in events {
            XCTAssertNotNil(event.radioEvent, "\(event) must have a mode-agnostic form")
        }
    }

    func testLifecycleAndTransmitEventsMapOneForOne() throws {
        XCTAssertEqual(IAX2ClientEvent.connected(format: .g711MuLaw).radioEvent, .connected)
        XCTAssertEqual(IAX2ClientEvent.transmitting.radioEvent, .transmitting)
        XCTAssertEqual(IAX2ClientEvent.receiving.radioEvent, .receiving)
        XCTAssertEqual(
            IAX2ClientEvent.transmitWatchdogExpired(.seconds(180)).radioEvent,
            .transmitWatchdogExpired(.seconds(180)),
            "SF-1: the timeout has to survive, or the app cannot say how long was held")
        XCTAssertEqual(
            IAX2ClientEvent.dtmf(try IAX2DTMFDigit("*")).radioEvent, .dtmfReceived("*"))
    }

    /// The negotiated codec is the one detail `connected` drops. Deliberate:
    /// there is exactly one codec (§8.7) and `MediaFormat` is RFC 5456's
    /// vocabulary, not a radio's.
    func testTheNegotiatedFormatIsDroppedButStillReachable() {
        XCTAssertEqual(
            IAX2ClientEvent.connected(format: .g711MuLaw).radioEvent,
            IAX2ClientEvent.connected(format: nil).radioEvent,
            "the format does not change the mode-agnostic event")
    }

    // MARK: - Terminations

    func testTerminationsMapToReasonsAnOperatorCanActOn() {
        XCTAssertEqual(
            IAX2CallTermination.localHangup(cause: "done", causeCode: 16).radioDisconnectReason,
            .localRequest,
            "the cause on our own HANGUP is ours; it is not news to the operator")
        XCTAssertEqual(
            IAX2CallTermination.closed.radioDisconnectReason, .localRequest)
        XCTAssertEqual(
            IAX2CallTermination.invalidated.radioDisconnectReason,
            .protocolFailure(detail: "the node sent INVAL (RFC 5456 §6.9.2)"))
        XCTAssertEqual(
            IAX2CallTermination.connectTimedOut(.seconds(5)).radioDisconnectReason,
            .connectTimedOut(.seconds(5)))
    }

    /// A REJECT means the session never existed — usually a credential or a node
    /// name, both of which the operator can fix — so it must not arrive looking
    /// like an ordinary hang-up.
    func testARejectIsDistinctFromAHangUpAndCarriesItsCause() {
        let rejected = IAX2CallTermination
            .rejected(cause: "no such node", causeCode: 3).radioDisconnectReason
        XCTAssertEqual(rejected, .rejected(detail: "no such node (cause code 3)"))
        XCTAssertNotEqual(rejected, .remoteRequest(detail: "no such node (cause code 3)"))

        XCTAssertEqual(
            IAX2CallTermination.remoteHangup(cause: "Bye", causeCode: nil).radioDisconnectReason,
            .remoteRequest(detail: "Bye"))
        XCTAssertEqual(
            IAX2CallTermination.remoteHangup(cause: nil, causeCode: 16).radioDisconnectReason,
            .remoteRequest(detail: "cause code 16"))
        XCTAssertEqual(
            IAX2CallTermination.remoteHangup(cause: nil, causeCode: nil).radioDisconnectReason,
            .remoteRequest(detail: nil),
            "no cause given renders from the reason itself rather than as prose here")
    }

    /// Retries running out is the far end having gone quiet, not a "channel
    /// failure" — that phrase means nothing to an operator and points at the
    /// wrong thing to check.
    func testExhaustedRetriesReadAsAQuietLinkRatherThanAChannelFault() {
        XCTAssertEqual(
            IAX2CallTermination
                .channelFailed(.retriesExhausted(oSeqno: 4, timestamp: 100, attempts: 4))
                .radioDisconnectReason,
            .linkTimedOut(nil))

        // Other channel errors are genuinely transport failures, and keep detail.
        guard case .transportFailure(let detail) = IAX2CallTermination
            .channelFailed(.transportFailed("socket closed")).radioDisconnectReason
        else { return XCTFail("a transport failure should stay one") }
        XCTAssertTrue(detail?.contains("socket closed") ?? false)
    }

    /// A transport that vanishes under a live call reports no termination at all.
    /// That must not become "disconnected locally" — the operator did nothing.
    func testATerminationlessDisconnectIsATransportFailure() {
        XCTAssertEqual(
            IAX2ClientEvent.disconnected(nil).radioEvent,
            .disconnected(.transportFailure()))
    }

    // MARK: - Media rejections

    /// Every rejection maps, and `unsupportedFormat` stays distinguishable from
    /// the rest: "your build cannot play this codec" is a different thing to tell
    /// an operator than "that frame was malformed".
    func testEveryMediaRejectionMapsAndUnsupportedFormatStaysItsOwnKind() {
        XCTAssertEqual(
            IAX2VoiceReceiver.Rejection.unsupportedFormat(0x0000_0008).radioAudioIssue,
            .unsupportedFormat(
                detail: IAX2VoiceReceiver.Rejection.unsupportedFormat(0x0000_0008).description))

        let undecodable: [IAX2VoiceReceiver.Rejection] = [
            .notAudio, .codecNotPinned, .emptyPayload,
            .wrongPayloadLength(expected: 160, got: 80),
            .timestampPrecedesCallOrigin(0x0010),
        ]
        for rejection in undecodable {
            XCTAssertEqual(
                rejection.radioAudioIssue, .undecodable(detail: rejection.description),
                "\(rejection) is 'arrived, could not be decoded'")
        }
    }

    /// The detail is the mode's own description, so nothing an operator might
    /// need is invented here or silently dropped.
    func testRejectionDetailIsTheModesOwnExplanation() {
        let rejection = IAX2VoiceReceiver.Rejection.wrongPayloadLength(expected: 160, got: 80)
        guard case .undecodable(let detail) = rejection.radioAudioIssue else {
            return XCTFail("expected an undecodable issue")
        }
        XCTAssertEqual(detail, rejection.description)
        XCTAssertTrue(detail?.contains("160") ?? false)
    }
}
