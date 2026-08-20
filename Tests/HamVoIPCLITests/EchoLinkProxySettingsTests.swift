// SPDX-License-Identifier: Apache-2.0

import EchoLinkKit
import XCTest
@testable import hamvoip_cli

/// The private-proxy setting: host, port and password resolved together.
///
/// Every test drives a temporary directory through an injected environment, so
/// nothing here reads the real config directory — the same arrangement as
/// `ConfigFileTests`.
final class EchoLinkProxySettingsTests: XCTestCase {
    private var root: URL!
    private var environment: [String: String]!

    private let ours = "m17-cbr.example.org"
    private let stranger = "proxy77.example.net"
    private var publicProxy: String { EchoLinkProxyPassword.publicProxy.value }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hamvoip-proxy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("swift-hamvoip"),
            withIntermediateDirectories: true)
        environment = ["XDG_CONFIG_HOME": root.path]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(
            to: root.appendingPathComponent("swift-hamvoip").appendingPathComponent(name),
            atomically: true,
            encoding: .utf8)
    }

    private func resolve(
        host: String? = nil,
        port: UInt16? = nil,
        password: String? = nil,
        autoProxy: Bool = false
    ) throws -> EchoLinkProxySettings.Resolved {
        try EchoLinkProxySettings.resolve(
            commandLineHost: host,
            commandLinePort: port,
            commandLinePassword: password,
            autoProxy: autoProxy,
            environment: environment)
    }

    // MARK: - The host

    func testNothingConfiguredLeavesNoHost() throws {
        XCTAssertNil(try resolve().host)
    }

    func testHostComesFromTheConfigFile() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        XCTAssertEqual(try resolve().host, ours)
    }

    func testCommandLineHostWinsOverTheConfigFile() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        XCTAssertEqual(try resolve(host: stranger).host, stranger)
    }

    func testEnvironmentWinsOverTheConfigFile() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        environment[EchoLinkProxySettings.hostName] = stranger
        XCTAssertEqual(try resolve().host, stranger)
    }

    /// `--auto-proxy` picks its own, so a configured host must not leak into it.
    func testAutoProxyLeavesTheHostForTheSelector() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        XCTAssertNil(try resolve(autoProxy: true).host)
    }

    // MARK: - The port

    func testPortDefaultsWhenNothingSaysOtherwise() throws {
        XCTAssertEqual(try resolve().port, EchoLinkProxyClient.defaultPort)
    }

    func testPortComesFromTheConfigFile() throws {
        try write(EchoLinkProxySettings.portName, "8200")
        XCTAssertEqual(try resolve().port, 8200)
    }

    func testCommandLinePortWins() throws {
        try write(EchoLinkProxySettings.portName, "8200")
        XCTAssertEqual(try resolve(port: 8300).port, 8300)
    }

    /// Failing beats falling back: a silent 8100 would connect to *something*
    /// and the operator would never learn the file was wrong.
    func testMalformedPortIsRefusedRatherThanIgnored() throws {
        try write(EchoLinkProxySettings.portName, "eight thousand")
        XCTAssertThrowsError(try resolve())
    }

    func testZeroPortIsRefused() throws {
        try write(EchoLinkProxySettings.portName, "0")
        XCTAssertThrowsError(try resolve())
    }

    func testOutOfRangePortIsRefused() throws {
        try write(EchoLinkProxySettings.portName, "70000")
        XCTAssertThrowsError(try resolve())
    }

    // MARK: - The password, and who it is allowed to reach

    func testPasswordDefaultsToPublicWhenNothingIsConfigured() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        let resolved = try resolve()
        XCTAssertEqual(resolved.password, publicProxy)
        XCTAssertFalse(resolved.passwordWithheld)
    }

    func testConfiguredPasswordIsUsedForItsOwnProxy() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        try write(EchoLinkProxySettings.passwordName, "s3cret")
        let resolved = try resolve()
        XCTAssertEqual(resolved.host, ours)
        XCTAssertEqual(resolved.password, "s3cret")
        XCTAssertFalse(resolved.passwordWithheld)
    }

    /// The rule this type exists for: a private password never reaches a proxy
    /// it does not belong to. Dialling somebody else's proxy while ours is
    /// configured must fall back to `PUBLIC`.
    func testConfiguredPasswordIsWithheldFromAnotherProxy() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        try write(EchoLinkProxySettings.passwordName, "s3cret")
        let resolved = try resolve(host: stranger)
        XCTAssertEqual(resolved.host, stranger)
        XCTAssertEqual(resolved.password, publicProxy)
        XCTAssertTrue(resolved.passwordWithheld)
    }

    /// `--auto-proxy` chooses from a public list, so the host is by definition
    /// somebody else's.
    func testConfiguredPasswordIsWithheldUnderAutoProxy() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        try write(EchoLinkProxySettings.passwordName, "s3cret")
        let resolved = try resolve(autoProxy: true)
        XCTAssertEqual(resolved.password, publicProxy)
        XCTAssertTrue(resolved.passwordWithheld)
    }

    /// A password with no host beside it is the state the config directory was
    /// actually found in, and it must not attach itself to whatever gets dialled.
    func testConfiguredPasswordWithNoConfiguredHostIsWithheld() throws {
        try write(EchoLinkProxySettings.passwordName, "s3cret")
        let resolved = try resolve(host: stranger)
        XCTAssertEqual(resolved.password, publicProxy)
        XCTAssertTrue(resolved.passwordWithheld)
    }

    /// Host names are case-insensitive; capitalisation must not silently cost
    /// the password.
    func testHostMatchIsCaseInsensitive() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        try write(EchoLinkProxySettings.passwordName, "s3cret")
        let resolved = try resolve(host: ours.uppercased())
        XCTAssertEqual(resolved.password, "s3cret")
        XCTAssertFalse(resolved.passwordWithheld)
    }

    /// Naming both a host and a password is a deliberate act, not a mistake to
    /// second-guess.
    func testCommandLinePasswordWins() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        try write(EchoLinkProxySettings.passwordName, "s3cret")
        let resolved = try resolve(host: stranger, password: "typed")
        XCTAssertEqual(resolved.password, "typed")
        XCTAssertFalse(resolved.passwordWithheld)
        XCTAssertEqual(
            resolved.passwordSource, .commandLine(flag: "--proxy-password"))
    }

    func testPasswordFromEnvironmentBeatsTheConfigFile() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        try write(EchoLinkProxySettings.passwordName, "from-file")
        environment[EchoLinkProxySettings.passwordName] = "from-env"
        let resolved = try resolve()
        XCTAssertEqual(resolved.password, "from-env")
        XCTAssertEqual(
            resolved.passwordSource, .environment(EchoLinkProxySettings.passwordName))
    }

    func testPasswordSourceNamesTheConfigFile() throws {
        try write(EchoLinkProxySettings.hostName, ours)
        try write(EchoLinkProxySettings.passwordName, "s3cret")
        let expected = root
            .appendingPathComponent("swift-hamvoip")
            .appendingPathComponent(EchoLinkProxySettings.passwordName)
            .path
        XCTAssertEqual(try resolve().passwordSource, .configFile(expected))
    }
}
