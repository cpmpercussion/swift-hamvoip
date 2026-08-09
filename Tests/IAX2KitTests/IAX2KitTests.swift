// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import IAX2Kit

final class IAX2KitSmokeTests: XCTestCase {
    func testDefaultPortIsTheIANARegisteredIAXPort() {
        XCTAssertEqual(IAX2Kit.defaultPort, 4569)
    }
}
