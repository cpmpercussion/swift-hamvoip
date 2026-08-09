// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import M17Kit

final class M17KitSmokeTests: XCTestCase {
    func testDefaultReflectorPort() {
        XCTAssertEqual(M17Kit.defaultReflectorPort, 17000)
    }
}
