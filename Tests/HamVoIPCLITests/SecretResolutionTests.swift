// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import hamvoip_cli

/// Where the secret comes from, and what the user is told about it.
///
/// The prompt itself needs a terminal and is not testable here; the precedence
/// rules and the reporting are, and they are the part that decides whether a
/// password ends up in the shell history.
final class SecretResolutionTests: XCTestCase {

    func testTheCommandLineWinsWhenItIsGiven() throws {
        let resolved = try SecretPrompt.resolve(
            commandLineValue: "from-argv",
            environment: [SecretPrompt.environmentVariable: "from-env"],
            allowPrompt: false)
        XCTAssertEqual(resolved.secret, "from-argv")
        if case .commandLine = resolved.source {} else { XCTFail("expected .commandLine") }
    }

    func testTheEnvironmentIsUsedWhenTheCommandLineIsSilent() throws {
        let resolved = try SecretPrompt.resolve(
            commandLineValue: nil,
            environment: [SecretPrompt.environmentVariable: "from-env"],
            allowPrompt: false)
        XCTAssertEqual(resolved.secret, "from-env")
        if case .environment = resolved.source {} else { XCTFail("expected .environment") }
    }

    func testAnEmptyEnvironmentVariableIsTreatedAsAbsent() throws {
        // `HAMVOIP_SECRET=` in a script is much more likely to be a mistake
        // than a deliberate request to authenticate with an empty password.
        let resolved = try SecretPrompt.resolve(
            commandLineValue: nil,
            environment: [SecretPrompt.environmentVariable: ""],
            allowPrompt: false)
        XCTAssertEqual(resolved.secret, "")
        if case .none = resolved.source {} else { XCTFail("expected .none") }
    }

    func testWithoutATerminalItProceedsUnauthenticatedRatherThanBlocking() throws {
        // A CLI whose input is a pipe has nobody to prompt. Blocking forever on
        // a read that will never be answered is the worse failure.
        let resolved = try SecretPrompt.resolve(
            commandLineValue: nil, environment: [:], allowPrompt: false)
        XCTAssertEqual(resolved.secret, "")
        if case .none = resolved.source {} else { XCTFail("expected .none") }
    }

    func testTheCommandLineSourceNamesItsOwnHazard() {
        // The banner prints this. A user who can see where their secret came
        // from is a user who can go and clean up their shell history.
        XCTAssertTrue(SecretPrompt.Source.commandLine(flag: "--secret").description.contains("argv"))
        XCTAssertTrue(SecretPrompt.Source.commandLine(flag: "--secret").description.contains("history"))
    }

    func testEverySourceDescribesItself() {
        let sources: [SecretPrompt.Source] = [
            .commandLine(flag: "--secret"),
            .environment(SecretPrompt.environmentVariable),
            .configFile("/somewhere/HAMVOIP_SECRET"),
            .prompt,
            .none,
        ]
        for source in sources {
            XCTAssertFalse(source.description.isEmpty)
        }
        XCTAssertTrue(
            SecretPrompt.Source.environment(SecretPrompt.environmentVariable)
                .description.contains(SecretPrompt.environmentVariable))
        XCTAssertTrue(
            SecretPrompt.Source.configFile("/somewhere/HAMVOIP_SECRET")
                .description.contains("/somewhere/HAMVOIP_SECRET"),
            "the banner must name the file, so a stale value is findable")
    }
}
