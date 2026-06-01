import Foundation
import Combine

struct HookSetupState {
    let claudeInstalled: Bool
    let codexFeatureEnabled: Bool
    let codexHooksInstalled: Bool
    let eventsFileExists: Bool

    var allInstalled: Bool {
        claudeInstalled && codexFeatureEnabled && codexHooksInstalled && eventsFileExists
    }
}

@MainActor
final class HookSetupStore: ObservableObject {
    @Published private(set) var state: HookSetupState
    @Published private(set) var isApplying = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var errorMessage: String?

    init() {
        state = HookConfigurationManager.inspect(executablePath: HookConfigurationManager.currentExecutablePath)
    }

    func refresh() {
        state = HookConfigurationManager.inspect(executablePath: HookConfigurationManager.currentExecutablePath)
    }

    func installHooks() {
        isApplying = true
        lastMessage = nil
        errorMessage = nil

        do {
            try HookConfigurationManager.install(executablePath: HookConfigurationManager.currentExecutablePath)
            refresh()
            lastMessage = "Hooks 已安装，Codex 首次运行时记得信任 AgentRadar hook。"
        } catch {
            errorMessage = error.localizedDescription
        }

        isApplying = false
    }
}

enum HookConfigurationManager {
    static var currentExecutablePath: String {
        // App 内安装时要写入当前可执行文件路径，CLI 模式则退回到命令本身。
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    private static let claudeEvents = [
        "Stop",
        "SubagentStop",
        "Notification",
        "PreToolUse",
        "PostToolUse",
        "UserPromptSubmit"
    ]

    private static let codexEvents = [
        "SessionStart",
        "Stop",
        "PermissionRequest",
        "PreToolUse",
        "PostToolUse"
    ]

    static func inspect(executablePath: String) -> HookSetupState {
        let claudeCommandMap = commandMap(runtime: .claude, events: claudeEvents, executablePath: executablePath)
        let codexCommandMap = commandMap(runtime: .codex, events: codexEvents, executablePath: executablePath)

        let claudeInstalled = hasRequiredHooks(at: PathUtils.claudeSettingsFile, expectedCommands: claudeCommandMap)
        let codexFeatureEnabled = codexHooksEnabled(in: try? String(contentsOf: PathUtils.codexConfigFile, encoding: .utf8))
        let codexHooksInstalled = hasRequiredHooks(at: PathUtils.codexHooksFile, expectedCommands: codexCommandMap)
        let eventsFileExists = FileManager.default.fileExists(atPath: PathUtils.hookEventsFile.path)

        return HookSetupState(
            claudeInstalled: claudeInstalled,
            codexFeatureEnabled: codexFeatureEnabled,
            codexHooksInstalled: codexHooksInstalled,
            eventsFileExists: eventsFileExists
        )
    }

    static func install(executablePath: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: PathUtils.hookEventsDirectory, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: PathUtils.claudeSettingsFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: PathUtils.codexDirectory, withIntermediateDirectories: true, attributes: nil)

        if !fileManager.fileExists(atPath: PathUtils.hookEventsFile.path) {
            _ = fileManager.createFile(atPath: PathUtils.hookEventsFile.path, contents: nil)
        }

        try backupIfExists(PathUtils.claudeSettingsFile)
        try backupIfExists(PathUtils.codexConfigFile)
        try backupIfExists(PathUtils.codexHooksFile)

        try installHooks(
            at: PathUtils.claudeSettingsFile,
            runtime: .claude,
            events: claudeEvents,
            executablePath: executablePath
        )

        let existingConfig = try? String(contentsOf: PathUtils.codexConfigFile, encoding: .utf8)
        let updatedConfig = updatedCodexConfigText(from: existingConfig)
        try updatedConfig.write(to: PathUtils.codexConfigFile, atomically: true, encoding: .utf8)

        try installHooks(
            at: PathUtils.codexHooksFile,
            runtime: .codex,
            events: codexEvents,
            executablePath: executablePath
        )
    }

    private static func installHooks(at url: URL, runtime: RuntimeKind, events: [String], executablePath: String) throws {
        var root = try loadJSONObject(at: url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in events {
            let command = hookCommand(runtime: runtime, event: event, executablePath: executablePath)
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { entry in
                // 先移除旧的 AgentRadar hook，避免 app 挪位置后残留无效路径。
                hasAgentRadarHook(entry, runtime: runtime, event: event)
            }
            entries.append([
                "hooks": [
                    [
                        "type": "command",
                        "command": command
                    ]
                ]
            ])
            hooks[event] = entries
        }

        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private static func loadJSONObject(at url: URL) throws -> [String: Any] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return [:]
        }

        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let object = jsonObject as? [String: Any] else {
            throw NSError(domain: "HookConfigurationManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) 不是合法 JSON"
            ])
        }
        return object
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func backupIfExists(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).bak.\(Int(Date().timeIntervalSince1970))")
        if !fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.copyItem(at: url, to: backupURL)
        }
    }

    private static func codexHooksEnabled(in configText: String?) -> Bool {
        guard let configText else {
            return false
        }

        var isInFeaturesSection = false
        for rawLine in configText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                isInFeaturesSection = line == "[features]"
                continue
            }
            guard isInFeaturesSection, line.hasPrefix("hooks") else {
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                return false
            }
            return parts[1].trimmingCharacters(in: .whitespaces).lowercased() == "true"
        }

        return false
    }

    private static func updatedCodexConfigText(from existingText: String?) -> String {
        var lines = (existingText ?? "").components(separatedBy: .newlines)
        if lines.count == 1, lines[0].isEmpty {
            lines.removeAll()
        }

        var featuresHeaderIndex: Int?
        var nextSectionIndex = lines.count

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "[features]" {
                featuresHeaderIndex = index
                continue
            }

            if featuresHeaderIndex != nil, index > featuresHeaderIndex!, line.hasPrefix("["), line.hasSuffix("]") {
                nextSectionIndex = index
                break
            }
        }

        if let featuresHeaderIndex {
            for index in (featuresHeaderIndex + 1)..<nextSectionIndex {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("hooks") {
                    lines[index] = "hooks = true"
                    return lines.joined(separator: "\n")
                }
            }

            lines.insert("hooks = true", at: nextSectionIndex)
            return lines.joined(separator: "\n")
        }

        if !lines.isEmpty, lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append("[features]")
        lines.append("hooks = true")
        return lines.joined(separator: "\n")
    }

    private static func hasRequiredHooks(at url: URL, expectedCommands: [String: String]) -> Bool {
        guard
            let data = try? Data(contentsOf: url),
            let rawObject = try? JSONSerialization.jsonObject(with: data),
            let object = rawObject as? [String: Any],
            let hooks = object["hooks"] as? [String: Any]
        else {
            return false
        }

        return expectedCommands.allSatisfy { event, command in
            guard let entries = hooks[event] as? [[String: Any]] else {
                return false
            }
            return entries.contains { entry in
                guard let nestedHooks = entry["hooks"] as? [[String: Any]] else {
                    return false
                }
                return nestedHooks.contains { hook in
                    (hook["type"] as? String) == "command" && (hook["command"] as? String) == command
                }
            }
        }
    }

    private static func hasAgentRadarHook(_ entry: [String: Any], runtime: RuntimeKind, event: String) -> Bool {
        guard let nestedHooks = entry["hooks"] as? [[String: Any]] else {
            return false
        }
        let marker = "record-hook \(runtime.rawValue) \(event)"
        return nestedHooks.contains { hook in
            guard
                (hook["type"] as? String) == "command",
                let command = hook["command"] as? String
            else {
                return false
            }
            return command.contains("AgentRadar") && command.contains(marker)
        }
    }

    private static func commandMap(runtime: RuntimeKind, events: [String], executablePath: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: events.map { event in
            (event, hookCommand(runtime: runtime, event: event, executablePath: executablePath))
        })
    }

    private static func hookCommand(runtime: RuntimeKind, event: String, executablePath: String) -> String {
        [
            shellQuote(executablePath),
            shellQuote("record-hook"),
            shellQuote(runtime.rawValue),
            shellQuote(event)
        ].joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum HookCommandRouter {
    static func runIfNeeded() -> Int32? {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            return nil
        }

        // 先拦截 CLI 子命令，避免安装 hook 时把菜单栏应用也一起拉起。
        switch arguments[1] {
        case "install-hooks":
            do {
                try HookConfigurationManager.install(executablePath: HookConfigurationManager.currentExecutablePath)
                FileHandle.standardOutput.write(Data("Hooks installed.\n".utf8))
                return EXIT_SUCCESS
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return EXIT_FAILURE
            }
        case "record-hook":
            guard arguments.count >= 4 else {
                FileHandle.standardError.write(Data("missing runtime/event\n".utf8))
                return EXIT_FAILURE
            }
            do {
                try HookEventRecorder.record(runtimeName: arguments[2], event: arguments[3])
                return EXIT_SUCCESS
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return EXIT_FAILURE
            }
        default:
            return nil
        }
    }
}

enum HookEventRecorder {
    static func record(runtimeName: String, event: String) throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var payload: [String: Any] = [:]

        if
            !input.isEmpty,
            let rawObject = try? JSONSerialization.jsonObject(with: input),
            let object = rawObject as? [String: Any]
        {
            payload = object
        }

        payload["runtime"] = runtimeName
        payload["event"] = event
        payload["ts"] = Date().timeIntervalSince1970

        // hooks 的原始载荷按行落盘，后续统一由 HookEventReader 消费。
        try FileManager.default.createDirectory(at: PathUtils.hookEventsDirectory, withIntermediateDirectories: true, attributes: nil)
        if !FileManager.default.fileExists(atPath: PathUtils.hookEventsFile.path) {
            _ = FileManager.default.createFile(atPath: PathUtils.hookEventsFile.path, contents: nil)
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: PathUtils.hookEventsFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(data)
        handle.write(Data([0x0A]))
    }
}
