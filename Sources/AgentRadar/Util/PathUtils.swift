import Foundation

enum PathUtils {
    static var claudeSettingsFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json")
    }

    static var claudeProjectsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static var codexDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    static var codexConfigFile: URL {
        codexDirectory.appendingPathComponent("config.toml")
    }

    static var codexHooksFile: URL {
        codexDirectory.appendingPathComponent("hooks.json")
    }

    static var codexSessionIndexFile: URL {
        codexDirectory.appendingPathComponent("session_index.jsonl")
    }

    static var codexSessionsDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    static var codexMemoriesDir: URL {
        codexDirectory.appendingPathComponent("memories", isDirectory: true)
    }

    static var hookEventsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".agentradar", isDirectory: true)
    }

    static var hookEventsFile: URL {
        hookEventsDirectory.appendingPathComponent("events.jsonl")
    }

    static func sessionsDir(for runtime: RuntimeKind) -> URL {
        switch runtime {
        case .claude: return claudeProjectsDir
        case .codex:  return codexSessionsDir
        }
    }

    static func decodeProjectDir(_ encoded: String) -> String {
        guard encoded.hasPrefix("-") else { return encoded }
        return "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    static func projectNameFromPath(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func isIgnoredProjectPath(_ path: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        // `.codex/sessions` 是 transcript 存储目录，不是真实项目；缺 cwd 时不能显示成 sessions 项目。
        let ignoredRoots = [codexMemoriesDir.path, codexSessionsDir.path]

        return ignoredRoots.contains { root in
            normalizedPath == root || normalizedPath.hasPrefix(root + "/")
        }
    }
}
