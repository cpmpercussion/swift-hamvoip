// swift-tools-version: 5.9
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "QSOKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "QSOCore", targets: ["QSOCore"]),
        .library(name: "IAX2Kit", targets: ["IAX2Kit"]),
        .library(name: "M17Kit", targets: ["M17Kit"]),
    ],
    targets: [
        // Transport, codec protocol, jitter buffer, audio graph.
        // Knows nothing about any specific network.
        .target(name: "QSOCore"),

        // AllStarLink via IAX2 (RFC 5456). Priority 1.
        .target(name: "IAX2Kit", dependencies: ["QSOCore"]),

        // M17 reflector protocol. Priority 3 — needs Codec2 XCFramework (OQ-2).
        .target(name: "M17Kit", dependencies: ["QSOCore"]),

        .testTarget(name: "QSOCoreTests", dependencies: ["QSOCore"]),
        .testTarget(name: "IAX2KitTests", dependencies: ["IAX2Kit"]),
    ]
)
