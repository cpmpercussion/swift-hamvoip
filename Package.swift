// swift-tools-version: 5.9
// SPDX-License-Identifier: Apache-2.0

import Foundation
import PackageDescription

// MARK: - Codec2 (M17-4)
//
// The Codec2 XCFramework is built by `scripts/build-codec2-xcframework.sh` and
// is deliberately **never committed**: 7.6 MB of LGPL-2.1 binary, and
// `.gitignore` covers `*.xcframework` precisely so it cannot be. That leaves
// the manifest with a problem, because CI checks out a bare tree and runs
// `swift build && swift test`, and a `binaryTarget` pointing at a path that
// does not exist is a hard manifest error.
//
// So the manifest adapts. When the framework is present the real codec is
// compiled in and `CODEC2` is defined; when it is not, the package still
// builds and every test that does not need codec2 still runs.
//
// This is why M17-4's stream sequencing is written against
// `RadioCore.VoiceCodec` rather than against codec2 directly: the framing,
// the frame numbering and the payload split are covered by tests that pass
// with or without the framework, and only the codec conformance itself is
// conditional. Run the script to compile and test that last piece.
//
// ⚠️ One trap, and it is SwiftPM's rather than ours: the evaluated manifest is
// cached against the manifest's *contents*, not against the filesystem this
// probe reads. So building or deleting the XCFramework does not on its own
// invalidate the cache, and the next build can fail with "local binary target
// 'Codec2' … does not contain a binary artifact". Run `swift package reset`
// (or delete `.build/`) after adding or removing the framework. A fresh
// checkout — CI, and anyone cloning — is unaffected, having no cache at all.
let codec2FrameworkName = "Codec2.xcframework"
let codec2IsBuilt = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/" + codec2FrameworkName)

let package = Package(
    name: "HamVoIP",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "RadioCore", targets: ["RadioCore"]),
        .library(name: "IAX2Kit", targets: ["IAX2Kit"]),
        .library(name: "M17Kit", targets: ["M17Kit"]),
        .library(name: "EchoLinkKit", targets: ["EchoLinkKit"]),

        // CLI-1. Deliberately **not** listed in `platforms` as macOS-only —
        // SwiftPM has no per-target platform restriction, and adding one at
        // package level would drop iOS support for the three libraries. The
        // executable is macOS-only *in practice* (it wants a terminal and a
        // Mac's audio devices); nothing in an iOS build ever references it,
        // because an iOS app depends on the library products, not this.
        .executable(name: "hamvoip-cli", targets: ["hamvoip-cli"]),
    ],
    dependencies: [
        // The one permitted third-party dependency (Apache-2.0), authorised by
        // CLI-1 in docs/DEVELOPMENT-PLAN.md. Nothing else in this package may
        // acquire a dependency without a task that says so (plan rule 8).
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Transport, codec protocol, jitter buffer, audio graph.
        // Knows nothing about any specific network.
        .target(name: "RadioCore"),

        // AllStarLink via IAX2 (RFC 5456). Priority 1.
        .target(name: "IAX2Kit", dependencies: ["RadioCore"]),

        // M17 reflector protocol and stream mode. Priority 3.
        // The Codec2 dependency is conditional — see the note at the top.
        .target(
            name: "M17Kit",
            dependencies: ["RadioCore"] + (codec2IsBuilt ? ["Codec2"] : []),
            swiftSettings: codec2IsBuilt ? [.define("CODEC2")] : []
        ),

        // EchoLink over the proxy (TCP 8100) and the directory (TCP 5200).
        // Priority 2. No published specification — the wire format comes from
        // captures of our own sessions (OQ-9); see Tests/FIXTURES.md.
        .target(name: "EchoLinkKit", dependencies: ["RadioCore"]),

        // Test-only helpers shared by every test target: fixture loading and
        // the mock transport. Deliberately not exposed as a product — nothing
        // outside this package's tests should depend on it.
        .target(name: "TestSupport", dependencies: ["RadioCore"], path: "Tests/TestSupport"),

        // CLI-1 — the macOS harness a human uses to validate the stack against
        // a real AllStar node before any GUI exists (Milestone M2).
        .executableTarget(
            name: "hamvoip-cli",
            dependencies: [
                "IAX2Kit",
                "M17Kit",
                "RadioCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: codec2IsBuilt ? [.define("CODEC2")] : []
        ),

        .testTarget(
            name: "RadioCoreTests",
            dependencies: ["RadioCore", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "IAX2KitTests",
            dependencies: ["IAX2Kit", "RadioCore", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "M17KitTests",
            dependencies: ["M17Kit", "RadioCore", "TestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: codec2IsBuilt ? [.define("CODEC2")] : []
        ),

        .testTarget(
            name: "EchoLinkKitTests",
            dependencies: ["EchoLinkKit", "RadioCore", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),

        // The pure logic inside the CLI: argument validation, the level meter,
        // the capture-frame hand-off, and the OQ-5 encoding catalogue. The
        // terminal and the audio devices are not testable here by definition —
        // that is what a live node is for — but everything that *is* a decision
        // rather than an I/O call lives in a value type with a test.
        .testTarget(
            name: "HamVoIPCLITests",
            dependencies: ["hamvoip-cli", "IAX2Kit", "M17Kit", "RadioCore", "TestSupport"]
        ),
    ]
)

// Appended rather than written inline, because a `binaryTarget` naming a path
// that does not exist fails the manifest outright — it cannot be guarded from
// inside the target list.
if codec2IsBuilt {
    package.targets.append(
        .binaryTarget(name: "Codec2", path: codec2FrameworkName)
    )
}
