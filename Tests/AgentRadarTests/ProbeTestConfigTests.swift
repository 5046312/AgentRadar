import Foundation
import XCTest
@testable import AgentRadar

final class ProbeTestConfigTests: XCTestCase {
    func testNewConfigDoesNotPersistAPIKeyField() throws {
        let config = ProbeTestConfig(
            id: UUID(),
            protocolType: .openAI,
            baseURL: "https://example.com/v1",
            model: "test-model",
            intervalSeconds: 1
        )

        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["apiKey"])
    }
}
