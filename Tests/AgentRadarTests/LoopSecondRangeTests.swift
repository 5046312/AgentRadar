import XCTest
@testable import AgentRadar

final class LoopSecondRangeTests: XCTestCase {
    func testAcceptsAllowedBoundsAndRejectsInvalidRanges() {
        XCTAssertNotNil(LoopSecondRange(minimum: 1, maximum: 1))
        XCTAssertNotNil(LoopSecondRange(minimum: 1, maximum: 86_400))
        XCTAssertNil(LoopSecondRange(minimum: 0, maximum: 1))
        XCTAssertNil(LoopSecondRange(minimum: 1, maximum: 86_401))
        XCTAssertNil(LoopSecondRange(minimum: 5, maximum: 1))
    }
}
