import XCTest
@testable import AgentRadar

final class LoopMinuteRangeTests: XCTestCase {
    func testAcceptsAllowedBoundsAndRejectsInvalidRanges() {
        XCTAssertNotNil(LoopMinuteRange(minimum: 1, maximum: 1))
        XCTAssertNotNil(LoopMinuteRange(minimum: 1, maximum: 1_440))
        XCTAssertNil(LoopMinuteRange(minimum: 0, maximum: 1))
        XCTAssertNil(LoopMinuteRange(minimum: 1, maximum: 1_441))
        XCTAssertNil(LoopMinuteRange(minimum: 5, maximum: 1))
    }
}
