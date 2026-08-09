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
    ]
)
