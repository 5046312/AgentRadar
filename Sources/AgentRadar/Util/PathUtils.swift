import Foundation

enum PathUtils {
    static var claudeProjectsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static var hookEventsFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".agentradar/events.jsonl")
    }

    static func decodeProjectDir(_ encoded: String) -> String {
        guard encoded.hasPrefix("-") else { return encoded }
        return "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    static func projectNameFromPath(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
