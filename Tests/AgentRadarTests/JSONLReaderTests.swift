import Foundation
import XCTest
@testable import AgentRadar

final class JSONLReaderTests: XCTestCase {
    func testRecentReadKeepsTrailingPartialLineForNextDrain() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstLine = #"{"id":1}"# + "\n"
        let partialLine = #"{"id":"#
        try Data((firstLine + partialLine).utf8).write(to: url)

        let recent = JSONLReader.readRecentLines(from: url, maxBytes: 64 * 1024)
        XCTAssertEqual(recent.lines.count, 1)
        XCTAssertEqual(recent.newOffset, UInt64(firstLine.utf8.count))

        // 写入剩余半行后，应从上次完整换行处重新拼出完整 JSON。
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("2}\n".utf8))
        try handle.close()

        let next = JSONLReader.readNewLines(from: url, startingAt: recent.newOffset)
        XCTAssertEqual(next.lines.count, 1)
        XCTAssertEqual(String(data: next.lines[0], encoding: .utf8), #"{"id":2}"#)
    }

    func testCodexTurnOutcomeFindsExactTerminalEvent() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let transcript = """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","started_at":100}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","completed_at":101}}

        """
        try Data(transcript.utf8).write(to: url)

        XCTAssertEqual(
            JSONLReader.codexTurnOutcome(
                at: url,
                turnId: "turn-1",
                startedAt: Date(timeIntervalSince1970: 100)
            ),
            .completed
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentradar-jsonl-\(UUID().uuidString).jsonl")
    }
}
