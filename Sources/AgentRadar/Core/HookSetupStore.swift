import Foundation
import Combine
import Darwin

struct HookSetupState {
    let claudeInstalled: Bool
    let codexFeatureEnabled: Bool
    let codexHooksInstalled: Bool
    let eventsFileExists: Bool

    var allInstalled: Bool {
        claudeInstalled && codexFeatureEnabled && codexHooksInstalled && eventsFileExists
    }
}

struct HookFileChange: Identifiable {
    let id: String
    let url: URL
    let currentText: String?
    let updatedText: String

    init(url: URL, currentText: String?, updatedText: String) {
        self.id = url.path
        self.url = url
        self.currentText = currentText
        self.updatedText = updatedText
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home) {
            return "~" + String(url.path.dropFirst(home.count))
        }
        return url.path
    }

    var diffLines: [HookDiffLine] {
        HookDiffFormatter.makeDiffLines(path: displayPath, currentText: currentText, updatedText: updatedText)
    }
}

enum HookDiffLineKind: String {
    case header
    case context
    case addition
    case deletion
}

struct HookDiffLine: Identifiable {
    let id: String
    let kind: HookDiffLineKind
    let text: String
}

struct HookInstallPlan: Identifiable {
    let id = UUID()
    let changes: [HookFileChange]
    let createsEventsFile: Bool

    var hasChanges: Bool {
        !changes.isEmpty || createsEventsFile
    }
}

@MainActor
final class HookSetupStore: ObservableObject {
    @Published private(set) var state: HookSetupState
    @Published private(set) var isApplying = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingPlan: HookInstallPlan?

    init() {
        state = HookConfigurationManager.inspect(executablePath: HookConfigurationManager.currentExecutablePath)
    }

    func refresh() {
        state = HookConfigurationManager.inspect(executablePath: HookConfigurationManager.currentExecutablePath)
    }

    func prepareInstallPreview() {
        lastMessage = nil
        errorMessage = nil
        pendingPlan = nil

        do {
            let plan = try HookConfigurationManager.planInstall(executablePath: HookConfigurationManager.currentExecutablePath)
            guard plan.hasChanges else {
                refresh()
                lastMessage = "当前 hooks 配置已是最新。"
                return
            }
            pendingPlan = plan
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissInstallPreview() {
        pendingPlan = nil
    }

    func applyPendingPlan() {
        guard let pendingPlan else {
            return
        }

        isApplying = true
        lastMessage = nil
        errorMessage = nil

        do {
            try HookConfigurationManager.apply(plan: pendingPlan)
            self.pendingPlan = nil
            refresh()
            lastMessage = "Hooks 已安装。重启当前 Claude/Codex 会话后生效；Codex 首次重启记得信任 AgentRadar hook。"
        } catch {
            errorMessage = error.localizedDescription
        }

        isApplying = false
    }

    func clearEventsFile() {
        lastMessage = nil
        errorMessage = nil

        do {
            try HookEventStorage.clear(at: PathUtils.hookEventsFile)
            refresh()
            lastMessage = "事件文件已清空。"
        } catch {
            refresh()
            errorMessage = "清空事件文件失败：\(error.localizedDescription)"
        }
    }
}

enum HookEventStorage {
    private static let maxFileBytes: off_t = 4 * 1024 * 1024

    static func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: PathUtils.hookEventsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: PathUtils.hookEventsDirectory.path)

        if !fileManager.fileExists(atPath: PathUtils.hookEventsFile.path) {
            let created = fileManager.createFile(
                atPath: PathUtils.hookEventsFile.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            guard created else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: PathUtils.hookEventsFile.path)
    }

    static func truncateIfNeeded(fileDescriptor: Int32) throws {
        var fileInfo = stat()
        guard fstat(fileDescriptor, &fileInfo) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard fileInfo.st_size >= maxFileBytes else { return }
        guard ftruncate(fileDescriptor, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func truncateIfNeeded(at url: URL) throws {
        try withLockedFile(at: url) { fd in
            try truncateIfNeeded(fileDescriptor: fd)
        }
    }

    static func clear(at url: URL) throws {
        try withLockedFile(at: url) { fd in
            guard ftruncate(fd, 0) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    private static func withLockedFile(at url: URL, operation: (Int32) throws -> Void) throws {
        let fd = open(url.path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { flock(fd, LOCK_UN) }

        try operation(fd)
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
        "UserPromptSubmit",
        "Stop",
        "PermissionRequest",
        "PreToolUse",
        "PostToolUse"
    ]
    private static let legacyCodexEvents = [
        "SessionStart"
    ]

    static func inspect(executablePath: String) -> HookSetupState {
        let claudeCommandMap = commandMap(runtime: .claude, events: claudeEvents, executablePath: executablePath)
        let codexCommandMap = commandMap(runtime: .codex, events: codexEvents, executablePath: executablePath)

        let claudeInstalled = hasRequiredHooks(at: PathUtils.claudeSettingsFile, runtime: .claude, expectedCommands: claudeCommandMap)
        let codexFeatureEnabled = codexHooksEnabled(in: try? String(contentsOf: PathUtils.codexConfigFile, encoding: .utf8))
        let codexHooksInstalled = hasRequiredHooks(at: PathUtils.codexHooksFile, runtime: .codex, expectedCommands: codexCommandMap)
        let eventsFileExists = FileManager.default.fileExists(atPath: PathUtils.hookEventsFile.path)

        return HookSetupState(
            claudeInstalled: claudeInstalled,
            codexFeatureEnabled: codexFeatureEnabled,
            codexHooksInstalled: codexHooksInstalled,
            eventsFileExists: eventsFileExists
        )
    }

    static func planInstall(executablePath: String) throws -> HookInstallPlan {
        var changes: [HookFileChange] = []

        if let change = try plannedHooksChange(
            at: PathUtils.claudeSettingsFile,
            runtime: .claude,
            events: claudeEvents,
            executablePath: executablePath
        ) {
            changes.append(change)
        }

        if let change = try plannedCodexConfigChange() {
            changes.append(change)
        }

        if let change = try plannedHooksChange(
            at: PathUtils.codexHooksFile,
            runtime: .codex,
            events: codexEvents,
            cleanupEvents: legacyCodexEvents,
            executablePath: executablePath
        ) {
            changes.append(change)
        }

        let createsEventsFile = !FileManager.default.fileExists(atPath: PathUtils.hookEventsFile.path)
        return HookInstallPlan(changes: changes, createsEventsFile: createsEventsFile)
    }

    static func install(executablePath: String) throws {
        let plan = try planInstall(executablePath: executablePath)
        try apply(plan: plan)
    }

    static func apply(plan: HookInstallPlan) throws {
        let fileManager = FileManager.default
        for change in plan.changes {
            let currentText = try loadTextIfExists(at: change.url)
            guard currentText == change.currentText else {
                throw NSError(domain: "HookConfigurationManager", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "\(change.displayPath) 在预览后已变化，请重新生成 diff。"
                ])
            }
        }

        let createdEventsFile = !fileManager.fileExists(atPath: PathUtils.hookEventsFile.path)
        var appliedChanges: [HookFileChange] = []
        do {
            try HookEventStorage.prepare()
            try fileManager.createDirectory(at: PathUtils.claudeSettingsFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: PathUtils.codexDirectory, withIntermediateDirectories: true, attributes: nil)

            for change in plan.changes {
                try fileManager.createDirectory(at: change.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                try change.updatedText.write(to: change.url, atomically: true, encoding: .utf8)
                appliedChanges.append(change)
            }
        } catch {
            // 多文件安装中途失败时恢复本轮已写内容，避免留下半安装状态。
            for change in appliedChanges.reversed() {
                if let currentText = change.currentText {
                    try? currentText.write(to: change.url, atomically: true, encoding: .utf8)
                } else if fileManager.fileExists(atPath: change.url.path) {
                    try? fileManager.removeItem(at: change.url)
                }
            }
            if createdEventsFile, fileManager.fileExists(atPath: PathUtils.hookEventsFile.path) {
                try? fileManager.removeItem(at: PathUtils.hookEventsFile)
            }
            throw error
        }
    }

    private static func plannedHooksChange(
        at url: URL,
        runtime: RuntimeKind,
        events: [String],
        cleanupEvents: [String] = [],
        executablePath: String
    ) throws -> HookFileChange? {
        let currentText = try loadTextIfExists(at: url)
        let currentRoot = try loadJSONObject(at: url)
        let updatedRoot = updatedHooksRoot(
            from: currentRoot,
            runtime: runtime,
            events: events,
            cleanupEvents: cleanupEvents,
            executablePath: executablePath
        )

        guard !jsonObjectsEqual(currentRoot, updatedRoot) else {
            return nil
        }

        return HookFileChange(
            url: url,
            currentText: currentText,
            updatedText: try serializedJSONObjectText(from: updatedRoot)
        )
    }

    private static func updatedHooksRoot(
        from root: [String: Any],
        runtime: RuntimeKind,
        events: [String],
        cleanupEvents: [String] = [],
        executablePath: String
    ) -> [String: Any] {
        var root = root

        for event in cleanupEvents where !events.contains(event) {
            let currentEntries = hookEntries(from: root, runtime: runtime, event: event)
            var entries = currentEntries
            entries.removeAll { entry in
                // 清掉旧版安装过但当前不再需要的 AgentRadar hook，避免继续产生无意义事件。
                hasAgentRadarHook(entry, runtime: runtime, event: event)
            }
            if entries.count != currentEntries.count {
                setHookEntries(entries, into: &root, runtime: runtime, event: event)
            }
        }

        for event in events {
            let command = hookCommand(runtime: runtime, event: event, executablePath: executablePath)
            var entries = hookEntries(from: root, runtime: runtime, event: event)
            entries.removeAll { entry in
                // 先移除旧的 AgentRadar hook，避免 app 挪位置后残留无效路径。
                hasAgentRadarHook(entry, runtime: runtime, event: event)
            }
            entries.append(makeHookEntry(command: command))
            setHookEntries(entries, into: &root, runtime: runtime, event: event)
        }
        return root
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

    private static func serializedJSONObjectText(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func loadTextIfExists(at url: URL) throws -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    static func codexHooksEnabled(in configText: String?) -> Bool {
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
            guard isInFeaturesSection, tomlAssignmentKey(in: line) == "hooks" else {
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

    static func updatedCodexConfigText(from existingText: String?) -> String {
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
                if tomlAssignmentKey(in: trimmed) == "hooks" {
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

    private static func tomlAssignmentKey(in line: String) -> String? {
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private static func plannedCodexConfigChange() throws -> HookFileChange? {
        let currentText = try loadTextIfExists(at: PathUtils.codexConfigFile)
        let updatedText = updatedCodexConfigText(from: currentText)

        guard updatedText != (currentText ?? "") else {
            return nil
        }

        return HookFileChange(
            url: PathUtils.codexConfigFile,
            currentText: currentText,
            updatedText: updatedText
        )
    }

    private static func hasRequiredHooks(at url: URL, runtime: RuntimeKind, expectedCommands: [String: String]) -> Bool {
        guard
            let data = try? Data(contentsOf: url),
            let rawObject = try? JSONSerialization.jsonObject(with: data),
            let object = rawObject as? [String: Any]
        else {
            return false
        }

        return expectedCommands.allSatisfy { event, command in
            let entries = hookEntries(from: object, runtime: runtime, event: event)
            guard !entries.isEmpty else {
                return false
            }
            return entries.contains { entry in
                isRequiredHook(entry, command: command)
            }
        }
    }

    private static func hasAgentRadarHook(_ entry: [String: Any], runtime: RuntimeKind, event: String) -> Bool {
        guard let nestedHooks = entry["hooks"] as? [[String: Any]] else {
            return false
        }
        return nestedHooks.contains { hook in
            guard
                (hook["type"] as? String) == "command",
                let command = hook["command"] as? String
            else {
                return false
            }
            // 早期安装器写入的命令会带 shell 引号，不能只按完整 marker 文本匹配，
            // 否则重装时无法清掉旧 AgentRadar hook，最终同一事件会被重复记录多次。
            return command.contains("AgentRadar")
                && command.contains("record-hook")
                && command.contains(runtime.rawValue)
                && command.contains(event)
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

    private static func hookEntries(from root: [String: Any], runtime: RuntimeKind, event: String) -> [[String: Any]] {
        switch runtime {
        case .claude:
            return root[event] as? [[String: Any]] ?? []
        case .codex:
            let hooks = root["hooks"] as? [String: Any] ?? [:]
            return hooks[event] as? [[String: Any]] ?? []
        }
    }

    private static func setHookEntries(_ entries: [[String: Any]], into root: inout [String: Any], runtime: RuntimeKind, event: String) {
        switch runtime {
        case .claude:
            // Claude 用户 settings.json 用直写格式，事件直接挂在顶层，不能再包一层 hooks。
            if entries.isEmpty {
                root.removeValue(forKey: event)
            } else {
                root[event] = entries
            }
        case .codex:
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
            root["hooks"] = hooks
        }
    }

    private static func makeHookEntry(command: String) -> [String: Any] {
        [
            "matcher": "*",
            "hooks": [
                [
                    "type": "command",
                    "command": command
                ]
            ]
        ]
    }

    private static func isRequiredHook(_ entry: [String: Any], command: String) -> Bool {
        guard
            let matcher = entry["matcher"] as? String,
            matcher == "*",
            let nestedHooks = entry["hooks"] as? [[String: Any]]
        else {
            return false
        }
        return nestedHooks.contains { hook in
            (hook["type"] as? String) == "command" && (hook["command"] as? String) == command
        }
    }

    private static func jsonObjectsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard
            let lhsData = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
            let rhsData = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else {
            return false
        }
        return lhsData == rhsData
    }
}

enum HookDiffFormatter {
    static func makeDiffLines(path: String, currentText: String?, updatedText: String) -> [HookDiffLine] {
        let currentLines = lines(from: currentText ?? "")
        let updatedLines = lines(from: updatedText)
        let prefixCount = commonPrefixCount(currentLines, updatedLines)
        let suffixCount = commonSuffixCount(currentLines, updatedLines, prefixCount: prefixCount)

        var diffLines: [HookDiffLine] = []
        appendLine(&diffLines, kind: .header, text: "--- \(currentText == nil ? "/dev/null" : path)")
        appendLine(&diffLines, kind: .header, text: "+++ \(path)")

        for line in currentLines.prefix(prefixCount) {
            appendLine(&diffLines, kind: .context, text: " \(line)")
        }

        if currentLines.count > prefixCount + suffixCount {
            for line in currentLines[prefixCount..<(currentLines.count - suffixCount)] {
                appendLine(&diffLines, kind: .deletion, text: "-\(line)")
            }
        }

        if updatedLines.count > prefixCount + suffixCount {
            for line in updatedLines[prefixCount..<(updatedLines.count - suffixCount)] {
                appendLine(&diffLines, kind: .addition, text: "+\(line)")
            }
        }

        if suffixCount > 0 {
            for line in currentLines.suffix(suffixCount) {
                appendLine(&diffLines, kind: .context, text: " \(line)")
            }
        }

        return diffLines
    }

    private static func lines(from text: String) -> [String] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        while normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        guard !normalized.isEmpty else {
            return []
        }
        return normalized.components(separatedBy: "\n")
    }

    private static func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    private static func appendLine(_ lines: inout [HookDiffLine], kind: HookDiffLineKind, text: String) {
        lines.append(HookDiffLine(id: "\(kind.rawValue)-\(lines.count)", kind: kind, text: text))
    }

    // 配置文件都很小，这里保留公共前后缀即可，预览足够直观，也避免引入更重的 diff 实现。
    private static func commonSuffixCount(_ lhs: [String], _ rhs: [String], prefixCount: Int) -> Int {
        var count = 0
        while
            count < lhs.count - prefixCount,
            count < rhs.count - prefixCount,
            lhs[lhs.count - 1 - count] == rhs[rhs.count - 1 - count]
        {
            count += 1
        }
        return count
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
    private static let persistedInputKeys = [
        "session_id",
        "cwd",
        "turn_id",
        "transcript_path",
        "approvals_reviewer"
    ]

    static func record(runtimeName: String, event: String) throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var payload: [String: Any] = [:]

        if
            !input.isEmpty,
            let rawObject = try? JSONSerialization.jsonObject(with: input),
            let object = rawObject as? [String: Any]
        {
            // Hook 输入可能包含工具参数，只保留状态识别实际需要的字段。
            for key in persistedInputKeys {
                if let value = object[key] {
                    payload[key] = value
                }
            }
        }

        payload["runtime"] = runtimeName
        payload["event"] = event
        payload["ts"] = Date().timeIntervalSince1970

        try HookEventStorage.prepare()

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var line = data
        line.append(0x0A)

        // Codex/Claude hooks 可能并发触发；这里必须把“整行 JSON + 换行”作为一个临界区写入，
        // 否则 events.jsonl 会出现两条记录互相拼接，HookEventReader 就会直接解码失败。
        let fd = open(PathUtils.hookEventsFile.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { flock(fd, LOCK_UN) }

        // 旧事件不会在 App 重启后重放，限制文件大小可减少敏感数据留存和无效磁盘增长。
        try HookEventStorage.truncateIfNeeded(fileDescriptor: fd)
        try writeAll(line, to: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = write(fd, baseAddress.advanced(by: written), rawBuffer.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard result > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                written += result
            }
        }
    }
}
