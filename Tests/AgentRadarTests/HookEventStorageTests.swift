import Foundation
import XCTest
@testable import AgentRadar

final class HookEventStorageTests: XCTestCase {
    func testTruncatesEventFileAtSizeLimit() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 4 * 1024 * 1024).write(to: url)

        try HookEventStorage.truncateIfNeeded(at: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.size] as? UInt64, 0)
    }

    func testKeepsEventFileBelowSizeLimit() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let contents = Data("event\n".utf8)
        try contents.write(to: url)

        try HookEventStorage.truncateIfNeeded(at: url)

        XCTAssertEqual(try Data(contentsOf: url), contents)
    }

    func testClearsEventFile() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("event\n".utf8).write(to: url)

        try HookEventStorage.clear(at: url)

        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRadar-HookEventStorage-\(UUID().uuidString).jsonl")
    }
}
