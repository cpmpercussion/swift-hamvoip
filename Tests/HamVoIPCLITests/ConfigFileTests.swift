// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import hamvoip_cli

/// Per-operator defaults read from `~/.config/swift-hamvoip/`.
///
/// Every test drives a temporary directory through an injected environment, so
/// nothing here reads or writes the real config directory.
final class ConfigFileTests: XCTestCase {
    private var root: URL!
    private var environment: [String: String]!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hamvoip-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("swift-hamvoip"),
            withIntermediateDirectories: true)
        environment = ["XDG_CONFIG_HOME": root.path]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ contents: String, permissions: Int? = nil) throws {
        let url = root.appendingPathComponent("swift-hamvoip").appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let permissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        }
    }

    // MARK: - Where the directory is

    func testXDGConfigHomeIsHonoured() {
        let directory = ConfigFile.directory(environment: ["XDG_CONFIG_HOME": "/xdg"])
        XCTAssertEqual(directory?.path, "/xdg/swift-hamvoip")
    }

    func testHomeIsTheFallback() {
        let directory = ConfigFile.directory(environment: ["HOME": "/home/op"])
        XCTAssertEqual(directory?.path, "/home/op/.config/swift-hamvoip")
    }

    func testXDGWinsOverHome() {
        let directory = ConfigFile.directory(
            environment: ["XDG_CONFIG_HOME": "/xdg", "HOME": "/home/op"])
        XCTAssertEqual(directory?.path, "/xdg/swift-hamvoip")
    }

    func testNoHomeAndNoXDGIsNilRatherThanACrash() {
        XCTAssertNil(ConfigFile.directory(environment: [:]))
        XCTAssertNil(ConfigFile.read("CALLSIGN", environment: [:]))
    }

    func testAnEmptyXDGIsIgnored() {
        // An exported-but-empty variable is a common shell accident, and
        // treating it as a path makes the config directory "/swift-hamvoip".
        let directory = ConfigFile.directory(
            environment: ["XDG_CONFIG_HOME": "", "HOME": "/home/op"])
        XCTAssertEqual(directory?.path, "/home/op/.config/swift-hamvoip")
    }

    // MARK: - Reading

    func testReadsAValue() throws {
        try write("CALLSIGN", "N0CALL")
        XCTAssertEqual(ConfigFile.read("CALLSIGN", environment: environment), "N0CALL")
    }

    func testTrailingNewlineIsTrimmed() throws {
        // The case that matters: `echo N0CALL > CALLSIGN` leaves a newline, and
        // a callsign with a trailing \n would go out on the wire and be
        // rejected somewhere far away for a reason nobody would guess.
        try write("CALLSIGN", "N0CALL\n")
        XCTAssertEqual(ConfigFile.read("CALLSIGN", environment: environment), "N0CALL")
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        try write("CALLSIGN", "  N0CALL \n")
        XCTAssertEqual(ConfigFile.read("CALLSIGN", environment: environment), "N0CALL")
    }

    func testOnlyTheFirstLineIsTaken() throws {
        try write("ECHOLINK_PASSWORD", "the-password\n# a note someone added\n")
        XCTAssertEqual(
            ConfigFile.read("ECHOLINK_PASSWORD", environment: environment), "the-password")
    }

    func testAMissingFileIsNil() {
        XCTAssertNil(ConfigFile.read("NOT_THERE", environment: environment))
    }

    func testAnEmptyFileIsNil() throws {
        try write("CALLSIGN", "")
        XCTAssertNil(ConfigFile.read("CALLSIGN", environment: environment))
    }

    func testAWhitespaceOnlyFileIsNil() throws {
        try write("CALLSIGN", "   \n\n")
        XCTAssertNil(ConfigFile.read("CALLSIGN", environment: environment))
    }

    func testAPasswordWithSpacesSurvives() throws {
        // Internal spaces are part of the value; only the ends are trimmed.
        try write("ECHOLINK_PASSWORD", "two words\n")
        XCTAssertEqual(
            ConfigFile.read("ECHOLINK_PASSWORD", environment: environment), "two words")
    }

    // MARK: - Callsign resolution

    func testCommandLineCallsignWinsOverTheFile() throws {
        try write("CALLSIGN", "FROMFILE")
        let resolved = try ConfigFile.requireCallsign(
            commandLineValue: "FROMFLAG", environment: environment)
        XCTAssertEqual(resolved, "FROMFLAG")
    }

    func testTheFileIsUsedWhenNoFlagIsGiven() throws {
        try write("CALLSIGN", "FROMFILE")
        let resolved = try ConfigFile.requireCallsign(
            commandLineValue: nil, environment: environment)
        XCTAssertEqual(resolved, "FROMFILE")
    }

    func testAnEmptyFlagFallsBackToTheFile() throws {
        try write("CALLSIGN", "FROMFILE")
        let resolved = try ConfigFile.requireCallsign(
            commandLineValue: "", environment: environment)
        XCTAssertEqual(resolved, "FROMFILE")
    }

    func testMissingEverywhereNamesBothPlaces() {
        // "callsign is required" is not much help to somebody who thought they
        // had set it, so the error says where it looked.
        do {
            _ = try ConfigFile.requireCallsign(commandLineValue: nil, environment: environment)
            XCTFail("expected a validation error")
        } catch let error as CLIValidationError {
            XCTAssertTrue(error.description.contains("--callsign"))
            XCTAssertTrue(error.description.contains("CALLSIGN"))
            XCTAssertTrue(error.description.contains(root.path), "and the actual path")
        } catch {
            XCTFail("expected a CLIValidationError, got \(error)")
        }
    }

    // MARK: - Precedence through SecretPrompt

    func testEnvironmentBeatsTheConfigFile() throws {
        // So a one-off override never needs an edit.
        try write("ECHOLINK_PASSWORD", "from-file")
        var withVariable = environment!
        withVariable["ECHOLINK_PASSWORD"] = "from-environment"

        let resolved = try SecretPrompt.resolve(
            commandLineValue: nil,
            name: "ECHOLINK_PASSWORD",
            environment: withVariable,
            allowPrompt: false)

        XCTAssertEqual(resolved.secret, "from-environment")
        XCTAssertEqual(resolved.source, .environment("ECHOLINK_PASSWORD"))
    }

    func testTheConfigFileBeatsThePrompt() throws {
        // So the common case is silent.
        try write("ECHOLINK_PASSWORD", "from-file")
        let resolved = try SecretPrompt.resolve(
            commandLineValue: nil,
            name: "ECHOLINK_PASSWORD",
            environment: environment,
            allowPrompt: false)

        XCTAssertEqual(resolved.secret, "from-file")
        guard case .configFile(let path) = resolved.source else {
            return XCTFail("expected .configFile, got \(resolved.source)")
        }
        XCTAssertTrue(path.hasSuffix("swift-hamvoip/ECHOLINK_PASSWORD"))
    }

    func testTheCommandLineBeatsEverything() throws {
        try write("ECHOLINK_PASSWORD", "from-file")
        var withVariable = environment!
        withVariable["ECHOLINK_PASSWORD"] = "from-environment"

        let resolved = try SecretPrompt.resolve(
            commandLineValue: "from-argv",
            name: "ECHOLINK_PASSWORD",
            environment: withVariable,
            allowPrompt: false)

        XCTAssertEqual(resolved.secret, "from-argv")
        XCTAssertEqual(resolved.source, .commandLine(flag: "--secret"))
    }

    func testNothingAnywhereIsNoneRatherThanAHang() throws {
        let resolved = try SecretPrompt.resolve(
            commandLineValue: nil,
            name: "ECHOLINK_PASSWORD",
            environment: environment,
            allowPrompt: false)

        XCTAssertEqual(resolved.secret, "")
        XCTAssertEqual(resolved.source, .none)
    }

    func testTheIAX2SecretUsesTheSameMechanism() throws {
        // The file name matching the environment variable is the whole
        // convention; this asserts the default path also honours it.
        try write("HAMVOIP_SECRET", "node-secret")
        let resolved = try SecretPrompt.resolve(
            commandLineValue: nil,
            environment: environment,
            allowPrompt: false)

        XCTAssertEqual(resolved.secret, "node-secret")
    }

    // MARK: - Permissions

    func testAWorldReadableCredentialWarns() throws {
        try write("ECHOLINK_PASSWORD", "secret", permissions: 0o644)

        XCTAssertTrue(ConfigFile.isReadableByOthers("ECHOLINK_PASSWORD", environment: environment))
        let warning = ConfigFile.permissionWarning(
            for: "ECHOLINK_PASSWORD", environment: environment)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("chmod 600"), "the warning should say how to fix it")
        XCTAssertFalse(warning!.contains("secret"), "and must not quote the credential")
    }

    func testAnOwnerOnlyCredentialIsQuiet() throws {
        try write("ECHOLINK_PASSWORD", "secret", permissions: 0o600)

        XCTAssertFalse(ConfigFile.isReadableByOthers("ECHOLINK_PASSWORD", environment: environment))
        XCTAssertNil(
            ConfigFile.permissionWarning(for: "ECHOLINK_PASSWORD", environment: environment))
    }

    func testAGroupReadableCredentialAlsoWarns() throws {
        try write("ECHOLINK_PASSWORD", "secret", permissions: 0o640)
        XCTAssertTrue(ConfigFile.isReadableByOthers("ECHOLINK_PASSWORD", environment: environment))
    }

    func testAMissingFileDoesNotWarn() {
        XCTAssertFalse(ConfigFile.isReadableByOthers("NOT_THERE", environment: environment))
        XCTAssertNil(ConfigFile.permissionWarning(for: "NOT_THERE", environment: environment))
    }
}
