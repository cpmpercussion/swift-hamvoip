// swift-tools-version: 5.9
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "HamVoIP",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "RadioCore", targets: ["RadioCore"]),
        .library(name: "IAX2Kit", targets: ["IAX2Kit"]),
        .library(name: "M17Kit", targets: ["M17Kit"]),

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

        // M17 reflector protocol. Priority 3 — needs Codec2 XCFramework (OQ-2).
        .target(name: "M17Kit", dependencies: ["RadioCore"]),

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
                "RadioCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
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
            resources: [.copy("Fixtures")]
        ),

        // The pure logic inside the CLI: argument validation, the level meter,
        // the capture-frame hand-off, and the OQ-5 encoding catalogue. The
        // terminal and the audio devices are not testable here by definition —
        // that is what a live node is for — but everything that *is* a decision
        // rather than an I/O call lives in a value type with a test.
        .testTarget(
            name: "HamVoIPCLITests",
            dependencies: ["hamvoip-cli", "IAX2Kit", "RadioCore"]
        ),
    ]
)
