import XCTest
@testable import AndroidMonitorCore

final class SmokeTests: XCTestCase {
    func testTestTargetLoadsApplicationModule() {
        XCTAssertEqual(AppIdentity.name, "Mirra")
    }
}

