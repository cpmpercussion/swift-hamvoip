// SPDX-License-Identifier: Apache-2.0

import XCTest
import TestSupport
@testable import RadioCore

final class RadioCoreSmokeTests: XCTestCase {
    func testJitterBufferDefaultDepthsMatchAU3() {
        let buffer = JitterBuffer()
        XCTAssertEqual(buffer.minDepth, .milliseconds(60))
        XCTAssertEqual(buffer.maxDepth, .milliseconds(200))
    }

    func testTransmitStateEquality() {
        let instant = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TransmitState.idle, .idle)
        XCTAssertNotEqual(TransmitState.idle, .receiving)
        XCTAssertEqual(TransmitState.transmitting(since: instant), .transmitting(since: instant))
        XCTAssertNotEqual(
            TransmitState.transmitting(since: instant),
            .transmitting(since: instant.addingTimeInterval(1))
        )
    }
}

final class FixtureLoaderTests: XCTestCase {
    func testParsesDatagramsIgnoringCommentsAndWhitespace() throws {
        let datagrams = try FixtureLoader.bytes("loader-smoke.hex", in: Bundle.module)
        XCTAssertEqual(datagrams, [
            [0xde, 0xad, 0xbe, 0xef],
            [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07],
            [0xff],
        ])
    }

    func testMissingFixtureThrows() {
        XCTAssertThrowsError(try FixtureLoader.bytes("no-such-fixture.hex", in: Bundle.module)) { error in
            XCTAssertEqual(error as? FixtureLoader.Error, .notFound(name: "no-such-fixture.hex"))
        }
    }
}
