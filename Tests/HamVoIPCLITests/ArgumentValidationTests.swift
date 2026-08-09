// SPDX-License-Identifier: Apache-2.0

import IAX2Kit
import XCTest

@testable import hamvoip_cli

/// Argument validation is the only part of the CLI that decides what a user is
/// allowed to type, and the only part whose failure mode is "the node rejects
/// the call for a reason that has nothing to do with what it says".
final class ArgumentValidationTests: XCTestCase {

    // MARK: Simple strings

    func testAcceptsAnOrdinaryValue() throws {
        XCTAssertEqual(try ArgumentValidation.requireSimpleString("node.example", option: "--host"), "node.example")
    }

    func testRejectsEmptyValues() {
        XCTAssertThrowsError(try ArgumentValidation.requireSimpleString("", option: "--host")) { error in
            XCTAssertEqual(error as? CLIValidationError, .emptyValue(option: "--host"))
        }
    }

    func testRejectsEmbeddedAndTrailingWhitespace() {
        // A trailing space in --node reaches the peer inside the CALLED NUMBER
        // IE and comes back as a REJECT that says nothing about spaces.
        for value in ["55553 ", " 55553", "555 53", "555\t53", "555\n53"] {
            XCTAssertThrowsError(try ArgumentValidation.requireSimpleString(value, option: "--node"), value) { error in
                XCTAssertEqual(error as? CLIValidationError, .whitespaceInValue(option: "--node"))
            }
        }
    }

    // MARK: Ports

    func testAcceptsTheWholeValidPortRange() throws {
        XCTAssertEqual(try ArgumentValidation.requirePort(1), 1)
        XCTAssertEqual(try ArgumentValidation.requirePort(4569), 4569)
        XCTAssertEqual(try ArgumentValidation.requirePort(65535), 65535)
    }

    func testRejectsPortsOutsideTheRangeIncludingZero() {
        for port in [0, -1, 65536, 1_000_000] {
            XCTAssertThrowsError(try ArgumentValidation.requirePort(port), "\(port)") { error in
                XCTAssertEqual(error as? CLIValidationError, .portOutOfRange(port))
            }
        }
    }

    // MARK: Callsigns

    func testAcceptsCallsignsFromSeveralCountriesAndSuffixes() throws {
        for (input, expected) in [
            ("vk1xyz", "VK1XYZ"), ("M0ABC", "M0ABC"), ("2E0ABC", "2E0ABC"),
            ("VK1XYZ/P", "VK1XYZ/P"), ("W1AW-1", "W1AW-1"), ("  vk2def  ", "VK2DEF"),
        ] {
            XCTAssertEqual(try ArgumentValidation.requireCallsign(input), expected)
        }
    }

    func testRejectsThingsThatAreObviouslyNotCallsigns() {
        XCTAssertThrowsError(try ArgumentValidation.requireCallsign("hi")) { error in
            XCTAssertEqual(error as? CLIValidationError, .callsignTooShort("hi"))
        }
        XCTAssertThrowsError(try ArgumentValidation.requireCallsign("VK1@XYZ")) { error in
            XCTAssertEqual(error as? CLIValidationError, .callsignHasInvalidCharacters("VK1@XYZ"))
        }
    }

    // MARK: Transmit timeout (SF-1)

    func testAcceptsTheDefaultWatchdogTimeout() throws {
        XCTAssertEqual(try ArgumentValidation.requireTransmitTimeout(seconds: 180), .seconds(180))
    }

    func testRefusesToDisableTheWatchdogOrToStretchItAbsurdly() {
        // SF-1 exists so a stuck PTT cannot hold a repeater open. `0` would
        // silently mean "no watchdog", which is the one value that must not be
        // reachable by typo.
        for seconds in [0, -1, 4, 3601, 86400] {
            XCTAssertThrowsError(try ArgumentValidation.requireTransmitTimeout(seconds: seconds), "\(seconds)") { error in
                XCTAssertEqual(error as? CLIValidationError, .timeoutOutOfRange(seconds: seconds))
            }
        }
    }

    // MARK: DTMF

    func testAcceptsEveryDigitRFC5456Defines() throws {
        let digits = try ArgumentValidation.requireDTMFSequence("0123456789*#ABCD")
        XCTAssertEqual(String(digits), "0123456789*#ABCD")
    }

    func testUpperCasesLetterDigitsAndIgnoresWhitespace() throws {
        XCTAssertEqual(String(try ArgumentValidation.requireDTMFSequence("*3 55553")), "*355553")
        XCTAssertEqual(String(try ArgumentValidation.requireDTMFSequence("abcd")), "ABCD")
    }

    func testRejectsCharactersThatAreNotDTMF() {
        for bad in ["*3E", "hello", "55553!"] {
            XCTAssertThrowsError(try ArgumentValidation.requireDTMFSequence(bad), bad)
        }
    }

    func testAnEmptySequenceIsEmptyRatherThanAnError() throws {
        XCTAssertTrue(try ArgumentValidation.requireDTMFSequence("").isEmpty)
    }

    // MARK: Destination assembly

    func testBuildsADestinationWithEveryFieldInTheRightPlace() throws {
        let destination = try ArgumentValidation.makeDestination(
            host: "node.example.org",
            port: 4569,
            node: "55553",
            username: "vk1xyz",
            callsign: "vk1xyz/p",
            secret: "hunter2")

        XCTAssertEqual(destination.host, "node.example.org")
        XCTAssertEqual(destination.port, 4569)
        XCTAssertEqual(destination.node, "55553")
        XCTAssertEqual(destination.username, "vk1xyz", "USERNAME is an account name, not a callsign — not upper-cased")
        XCTAssertEqual(destination.callsign, "VK1XYZ/P")
        XCTAssertEqual(destination.secret, "hunter2")
    }

    func testTheCallRequestCarriesTheNodeAndUsernameButNeverTheSecret() throws {
        let destination = try ArgumentValidation.makeDestination(
            host: "node.example.org", port: 4569, node: "55553",
            username: "vk1xyz", callsign: "VK1XYZ", secret: "hunter2")
        let elements = destination.callRequest.newInformationElements()

        XCTAssertTrue(elements.contains(.calledNumber("55553")))
        XCTAssertTrue(elements.contains(.username("vk1xyz")))
        for element in elements {
            if case .password = element { XCTFail("a NEW must never carry the secret") }
        }
    }

    func testAnEmptySecretIsAllowedForNodesThatDoNotAuthenticate() throws {
        let destination = try ArgumentValidation.makeDestination(
            host: "h", port: 1, node: "n", username: "u", callsign: "VK1XYZ", secret: "")
        XCTAssertEqual(destination.secret, "")
    }

    func testABadFieldIsReportedAgainstTheOptionThatCarriedIt() {
        XCTAssertThrowsError(
            try ArgumentValidation.makeDestination(
                host: "h", port: 4569, node: "", username: "u", callsign: "VK1XYZ", secret: "")
        ) { error in
            XCTAssertEqual(error as? CLIValidationError, .emptyValue(option: "--node"))
        }
    }
}
