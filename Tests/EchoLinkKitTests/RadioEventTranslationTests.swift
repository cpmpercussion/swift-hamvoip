// SPDX-License-Identifier: Apache-2.0

import RadioCore
import XCTest

@testable import EchoLinkKit

/// RC-10: EchoLink's vocabulary onto the mode-agnostic `RadioEvent`.
///
/// This is the mode that made the translation `Optional`. Its connect sequence
/// has two intermediate steps that mean nothing to an application, because they
/// happen inside a `connect(to:)` that has not returned yet — so `nil` here is a
/// decision, and these tests are what keep it one.
final class EchoLinkRadioEventTranslationTests: XCTestCase {

    // MARK: - What translates, and what deliberately does not

    func testEveryEventEitherTranslatesOrIsNamedHereAsDropped() {
        let translated: [EchoLinkClientEvent] = [
            .connecting,
            .connected(node: "*ECHOTEST*"),
            .disconnected(reason: .localRequest),
            .transmitting,
            .receiving,
            .talkspurtStarted,
            .stationInfo("Audio test server"),
            .transmitTimedOut(after: .seconds(180)),
        ]
        for event in translated {
            XCTAssertNotNil(event.radioEvent, "\(event) must have a mode-agnostic form")
        }

        // The two exceptions, stated rather than discovered.
        XCTAssertNil(EchoLinkClientEvent.directoryLoggedIn.radioEvent)
        XCTAssertNil(EchoLinkClientEvent.nodeAnswered(name: "*ECHOTEST*").radioEvent)
    }

    /// Why those two are dropped: they are steps *inside* `connect(to:)`, so an
    /// application awaiting it cannot act on them, and `connected` follows
    /// immediately. They stay on `EchoLinkClient.events`, which is what the CLI
    /// narrates the sequence from.
    func testTheDroppedEventsAreTheOnesConnectHasNotReturnedFromYet() {
        let insideConnect: [EchoLinkClientEvent] = [
            .directoryLoggedIn, .nodeAnswered(name: "*ECHOTEST*"),
        ]
        for event in insideConnect { XCTAssertNil(event.radioEvent) }

        // But `connecting` itself is reportable — it is the state an app shows
        // while it waits.
        XCTAssertEqual(EchoLinkClientEvent.connecting.radioEvent, .connecting)
        XCTAssertEqual(EchoLinkClientEvent.connected(node: "*ECHOTEST*").radioEvent, .connected)
    }

    /// The node's name is dropped from `connected` because the application named
    /// the destination and so already knows it.
    func testTheNodeNameIsDroppedFromConnected() {
        XCTAssertEqual(
            EchoLinkClientEvent.connected(node: "*ECHOTEST*").radioEvent,
            EchoLinkClientEvent.connected(node: "VK1ABC-L").radioEvent)
    }

    // MARK: - Transmit and talkspurts

    /// EchoLink names the watchdog differently (`transmitTimedOut`) but it is the
    /// same SF-1 event, and the timeout has to survive.
    func testTheWatchdogArrivesAsTheWatchdogWithItsTimeout() {
        XCTAssertEqual(
            EchoLinkClientEvent.transmitTimedOut(after: .seconds(180)).radioEvent,
            .transmitWatchdogExpired(.seconds(180)))
        XCTAssertNotEqual(
            EchoLinkClientEvent.transmitTimedOut(after: .seconds(180)).radioEvent,
            .transmitWatchdogExpired(.seconds(60)))
    }

    /// A talkspurt is somebody else taking the channel, which is a different axis
    /// from our own `receiving`. EchoLink carries no per-over identity, so the
    /// station is `nil` — stated here so that a later "add the callsign" has to
    /// find one on the wire first.
    func testATalkspurtIsRemoteActivityWithNoStationIdentity() {
        XCTAssertEqual(
            EchoLinkClientEvent.talkspurtStarted.radioEvent,
            .remoteTransmitStarted(station: nil))
        XCTAssertNotEqual(EchoLinkClientEvent.talkspurtStarted.radioEvent, .receiving)
    }

    /// The `oNDATA` text is how a node announces what it is, so it survives as
    /// text — the one thing in this mode written by the far end for a human.
    func testStationInfoSurvivesAsText() {
        let text = "Audio test server [9] … records and plays back transmissions"
        XCTAssertEqual(EchoLinkClientEvent.stationInfo(text).radioEvent, .stationInfo(text))
    }

    // MARK: - Disconnects

    /// The reason is typed rather than a `String` precisely so this mapping can
    /// exist. These three used to be the prose "local request", "the node said
    /// goodbye" and "the link closed"; classifying by string would have broken
    /// the first time somebody reworded a message.
    func testEachDisconnectReasonMapsToItsOwnKind() {
        XCTAssertEqual(
            EchoLinkDisconnectReason.localRequest.radioDisconnectReason, .localRequest)
        XCTAssertEqual(
            EchoLinkDisconnectReason.remoteRequest.radioDisconnectReason,
            .remoteRequest(detail: nil))
        XCTAssertEqual(
            EchoLinkDisconnectReason.linkClosed.radioDisconnectReason, .transportFailure())

        // The operator-visible distinction that matters: we hung up, they hung
        // up, or the network went away. None of the three may collapse.
        let all: [RadioDisconnectReason] = [
            EchoLinkDisconnectReason.localRequest.radioDisconnectReason,
            EchoLinkDisconnectReason.remoteRequest.radioDisconnectReason,
            EchoLinkDisconnectReason.linkClosed.radioDisconnectReason,
        ]
        XCTAssertEqual(Set(all.map(\.description)).count, 3)
    }

    func testDisconnectEventCarriesTheReasonThrough() {
        XCTAssertEqual(
            EchoLinkClientEvent.disconnected(reason: .remoteRequest).radioEvent,
            .disconnected(.remoteRequest(detail: nil)))
        XCTAssertEqual(
            EchoLinkClientEvent.disconnected(reason: .linkClosed).radioEvent,
            .disconnected(.transportFailure()))
    }

    /// Every reason still renders for a human, since the CLI prints it.
    func testEveryReasonRenders() {
        let reasons: [EchoLinkDisconnectReason] = [.localRequest, .remoteRequest, .linkClosed]
        for reason in reasons { XCTAssertFalse("\(reason)".isEmpty) }
    }
}
