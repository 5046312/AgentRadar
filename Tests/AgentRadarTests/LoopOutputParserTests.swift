import XCTest
@testable import AgentRadar

final class LoopOutputParserTests: XCTestCase {
    func testExtractsLastCompletedAgentMessage() {
        let output = """
        {"type":"thread.started","thread_id":"thread-1"}
        {"type":"item.completed","item":{"type":"agent_message","text":"first"}}
        {"type":"item.completed","item":{"type":"command_execution","text":"ignored"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"final answer"}}

        """

        XCTAssertEqual(LoopOutputParser.lastAgentMessage(in: output), "final answer")
    }

    func testReturnsCompleteFailureOutputWithoutTruncatingJSON() {
        let standardOutput = "{\"type\":\"error\",\"message\":\"\(String(repeating: "x", count: 25_000))\"}\n"
        let standardError = "request failed\n"

        let output = LoopOutputParser.completeFailureOutput(
            standardOutput: standardOutput,
            standardError: standardError
        )

        XCTAssertEqual(output, standardOutput + standardError)
        XCTAssertGreaterThan(output.count, 25_000)
    }
}
