import Darwin
import Foundation

enum LoopPhase: Equatable {
    case idle
    case resolvingCodex
    case waiting(count: Int, nextRunAt: Date)
    case running(count: Int, startedAt: Date)
    case stopping
}

struct LoopRunResult: Equatable {
    let count: Int
    let completedAt: Date
    let duration: TimeInterval
    let terminationStatus: Int32?
    let message: String?
    let errorText: String?

    var succeeded: Bool {
        guard let message else { return false }
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayText: String {
        if let message, !message.isEmpty {
            return message
        }
        if let errorText, !errorText.isEmpty {
            return errorText
        }
        return "未提取到 agent_message。"
    }
}

struct CodexCommandContext {
    static let executablePathPrefix = "__AGENTRADAR_CODEX_PATH__="
    static let loginShellPathPrefix = "__AGENTRADAR_LOGIN_PATH__="

    let executableURL: URL
    let loginShellPath: String

    init?(discoveryOutput: String) {
        let lines = discoveryOutput
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard
            let executableLine = lines.last(where: { $0.hasPrefix(Self.executablePathPrefix) }),
            let loginShellPathLine = lines.last(where: { $0.hasPrefix(Self.loginShellPathPrefix) })
        else {
            return nil
        }

        let executablePath = String(executableLine.dropFirst(Self.executablePathPrefix.count))
        let loginShellPath = String(loginShellPathLine.dropFirst(Self.loginShellPathPrefix.count))
        guard
            !loginShellPath.isEmpty,
            FileManager.default.isExecutableFile(atPath: executablePath)
        else {
            return nil
        }

        self.executableURL = URL(fileURLWithPath: executablePath)
        self.loginShellPath = loginShellPath
    }

    func executionEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        // 查找和执行必须复用同一 PATH，避免 GUI 进程缺少 NVM、pnpm 或 Homebrew 目录。
        environment["PATH"] = loginShellPath
        return environment
    }
}

@MainActor
final class LoopStore: ObservableObject {
    private enum DefaultsKey {
        static let successMinimumSeconds = "loopSuccessMinimumSeconds"
        static let successMaximumSeconds = "loopSuccessMaximumSeconds"
        static let failureMinimumSeconds = "loopFailureMinimumSeconds"
        static let failureMaximumSeconds = "loopFailureMaximumSeconds"
        static let legacyMinimumMinutes = "loopMinimumMinutes"
        static let legacyMaximumMinutes = "loopMaximumMinutes"
        static let notifyOnSuccess = "loopNotifyOnSuccess"
    }

    private enum LoopStoreError: LocalizedError {
        case codexNotFound
        case outputFileCreationFailed

        var errorDescription: String? {
            switch self {
            case .codexNotFound:
                return "未找到 codex，请先确认终端中可执行 command -v codex。"
            case .outputFileCreationFailed:
                return "无法创建 Loop 临时输出文件。"
            }
        }
    }

    private struct ProcessExecution {
        let standardOutput: String
        let standardError: String
        let terminationStatus: Int32
    }

    private struct CodexExecutionOutcome {
        let result: LoopRunResult
        let notificationMessage: String?
    }

    static let defaultSuccessMinimumSeconds = 60
    static let defaultSuccessMaximumSeconds = 300
    static let defaultFailureMinimumSeconds = 60
    static let defaultFailureMaximumSeconds = 300
    static let maximumDisplayedCharacters = 20_000

    @Published private(set) var successMinimumSeconds: Int
    @Published private(set) var successMaximumSeconds: Int
    @Published private(set) var failureMinimumSeconds: Int
    @Published private(set) var failureMaximumSeconds: Int
    @Published private(set) var notifyOnSuccess: Bool
    @Published private(set) var phase: LoopPhase = .idle
    @Published private(set) var lastResult: LoopRunResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestSuccess: LoopSuccessNotice?
    @Published private(set) var successCount = 0
    @Published private(set) var failureCount = 0
    @Published private(set) var streakCount = 0
    @Published private(set) var streakSucceeded: Bool?

    private let defaults: UserDefaults
    private var loopTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var currentProcess: Process?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let successRange = Self.loadRange(
            defaults: defaults,
            minimumKey: DefaultsKey.successMinimumSeconds,
            maximumKey: DefaultsKey.successMaximumSeconds,
            fallback: LoopSecondRange(
                minimum: Self.defaultSuccessMinimumSeconds,
                maximum: Self.defaultSuccessMaximumSeconds
            )!,
            legacyMinimumKey: DefaultsKey.legacyMinimumMinutes,
            legacyMaximumKey: DefaultsKey.legacyMaximumMinutes
        )
        let failureRange = Self.loadRange(
            defaults: defaults,
            minimumKey: DefaultsKey.failureMinimumSeconds,
            maximumKey: DefaultsKey.failureMaximumSeconds,
            fallback: LoopSecondRange(
                minimum: Self.defaultFailureMinimumSeconds,
                maximum: Self.defaultFailureMaximumSeconds
            )!,
            legacyMinimumKey: DefaultsKey.legacyMinimumMinutes,
            legacyMaximumKey: DefaultsKey.legacyMaximumMinutes
        )

        successMinimumSeconds = successRange.minimum
        successMaximumSeconds = successRange.maximum
        failureMinimumSeconds = failureRange.minimum
        failureMaximumSeconds = failureRange.maximum
        notifyOnSuccess = defaults.bool(forKey: DefaultsKey.notifyOnSuccess)
    }

    var isActive: Bool {
        phase != .idle
    }

    func setSuccessSecondRange(_ range: LoopSecondRange) {
        successMinimumSeconds = range.minimum
        successMaximumSeconds = range.maximum
        defaults.set(range.minimum, forKey: DefaultsKey.successMinimumSeconds)
        defaults.set(range.maximum, forKey: DefaultsKey.successMaximumSeconds)
    }

    func setFailureSecondRange(_ range: LoopSecondRange) {
        failureMinimumSeconds = range.minimum
        failureMaximumSeconds = range.maximum
        defaults.set(range.minimum, forKey: DefaultsKey.failureMinimumSeconds)
        defaults.set(range.maximum, forKey: DefaultsKey.failureMaximumSeconds)
    }

    func setNotifyOnSuccess(_ enabled: Bool) {
        notifyOnSuccess = enabled
        defaults.set(enabled, forKey: DefaultsKey.notifyOnSuccess)
    }

    func resetStatistics() {
        // 仅清零累计结果，保留当前运行状态和最近一次调用详情。
        successCount = 0
        failureCount = 0
        streakCount = 0
        streakSucceeded = nil
    }

    func start(successRange: LoopSecondRange, failureRange: LoopSecondRange) {
        guard !isActive else { return }

        setSuccessSecondRange(successRange)
        setFailureSecondRange(failureRange)
        lastResult = nil
        errorMessage = nil
        latestSuccess = nil
        resetStatistics()
        phase = .resolvingCodex

        let runID = UUID()
        activeRunID = runID
        loopTask = Task { [weak self] in
            await self?.runLoop(successRange: successRange, failureRange: failureRange, runID: runID)
        }
    }

    func stop() {
        guard isActive else { return }
        phase = .stopping
        loopTask?.cancel()
        terminateCurrentProcess()
    }

    func stopForApplicationTermination() {
        loopTask?.cancel()
        loopTask = nil
        activeRunID = nil

        // App 即将退出时没有时间等待 SIGTERM fallback，直接结束自己启动的 Codex 子进程。
        if let process = currentProcess, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        currentProcess = nil
        phase = .idle
    }

    private func runLoop(successRange: LoopSecondRange, failureRange: LoopSecondRange, runID: UUID) async {
        let codexContext: CodexCommandContext
        do {
            codexContext = try await resolveCodexContext()
        } catch {
            guard activeRunID == runID, !Task.isCancelled else {
                finish(runID: runID)
                return
            }
            errorMessage = error.localizedDescription
            finish(runID: runID)
            return
        }

        var count = 1
        while activeRunID == runID, !Task.isCancelled {
            if count > 1 {
                // 上轮结果决定本轮等待范围；失败后单独配置可避免连续失败时仍沿用成功间隔。
                let delayRange = streakSucceeded == false ? failureRange : successRange
                let delayNanoseconds = delayRange.randomDelayNanoseconds()
                let delaySeconds = TimeInterval(delayNanoseconds) / 1_000_000_000
                phase = .waiting(count: count, nextRunAt: Date().addingTimeInterval(delaySeconds))

                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    break
                }
            }
            guard activeRunID == runID, !Task.isCancelled else { break }

            let startedAt = Date()
            phase = .running(count: count, startedAt: startedAt)
            let outcome = await executeCodex(context: codexContext, count: count, startedAt: startedAt)
            guard activeRunID == runID, !Task.isCancelled else { break }

            lastResult = outcome.result
            errorMessage = nil
            if outcome.result.succeeded {
                successCount += 1
                streakCount = streakSucceeded == true ? streakCount + 1 : 1
                streakSucceeded = true
                if notifyOnSuccess, let message = outcome.notificationMessage {
                    latestSuccess = LoopSuccessNotice(count: count, message: message, duration: outcome.result.duration)
                }
            } else {
                failureCount += 1
                streakCount = streakSucceeded == false ? streakCount + 1 : 1
                streakSucceeded = false
            }
            count += 1
        }

        finish(runID: runID)
    }

    private func resolveCodexContext() async throws -> CodexCommandContext {
        let executablePrefix = CodexCommandContext.executablePathPrefix
        let pathPrefix = CodexCommandContext.loginShellPathPrefix
        let execution = try await runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-lic",
                "codex_path=$(command -v codex) && printf '\\n\(executablePrefix)%s\\n\(pathPrefix)%s\\n' \"$codex_path\" \"$PATH\""
            ],
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        guard execution.terminationStatus == EXIT_SUCCESS else {
            throw LoopStoreError.codexNotFound
        }

        guard let context = CodexCommandContext(discoveryOutput: execution.standardOutput) else {
            throw LoopStoreError.codexNotFound
        }
        return context
    }

    private func executeCodex(context: CodexCommandContext, count: Int, startedAt: Date) async -> CodexExecutionOutcome {
        do {
            let execution = try await runProcess(
                executableURL: context.executableURL,
                arguments: [
                    "exec",
                    "--json",
                    "--ephemeral",
                    "--ignore-rules",
                    "--disable", "hooks",
                    "--sandbox", "read-only",
                    "--skip-git-repo-check",
                    String(count)
                ],
                currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                environment: context.executionEnvironment(base: ProcessInfo.processInfo.environment)
            )
            let completedAt = Date()
            let rawMessage = LoopOutputParser.lastAgentMessage(in: execution.standardOutput)
            let message = rawMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty

            return CodexExecutionOutcome(
                result: LoopRunResult(
                    count: count,
                    completedAt: completedAt,
                    duration: completedAt.timeIntervalSince(startedAt),
                    terminationStatus: execution.terminationStatus,
                    message: message.map { Self.trailingCharacters($0, limit: Self.maximumDisplayedCharacters) },
                    errorText: message == nil
                        ? Self.trailingCharacters(execution.standardError, limit: Self.maximumDisplayedCharacters)
                        : nil
                ),
                notificationMessage: message
            )
        } catch {
            let completedAt = Date()
            return CodexExecutionOutcome(
                result: LoopRunResult(
                    count: count,
                    completedAt: completedAt,
                    duration: completedAt.timeIntervalSince(startedAt),
                    terminationStatus: nil,
                    message: nil,
                    errorText: Self.trailingCharacters(error.localizedDescription, limit: Self.maximumDisplayedCharacters)
                ),
                notificationMessage: nil
            )
        }
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String]
    ) async throws -> ProcessExecution {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory.appendingPathComponent("AgentRadar-Loop-\(UUID().uuidString).stdout")
        let errorURL = fileManager.temporaryDirectory.appendingPathComponent("AgentRadar-Loop-\(UUID().uuidString).stderr")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw LoopStoreError.outputFileCreationFailed
        }
        guard fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            try? fileManager.removeItem(at: outputURL)
            throw LoopStoreError.outputFileCreationFailed
        }
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        let terminationStatus = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
            do {
                try process.run()
                currentProcess = process
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        if currentProcess === process {
            currentProcess = nil
        }

        try outputHandle.synchronize()
        try errorHandle.synchronize()
        return ProcessExecution(
            standardOutput: String(data: try Data(contentsOf: outputURL), encoding: .utf8) ?? "",
            standardError: String(data: try Data(contentsOf: errorURL), encoding: .utf8) ?? "",
            terminationStatus: terminationStatus
        )
    }

    private func terminateCurrentProcess() {
        guard let process = currentProcess, process.isRunning else { return }
        process.terminate()
        let processID = process.processIdentifier

        // Codex 未响应 SIGTERM 时兜底强制结束，避免“停止”后后台进程继续消耗资源。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                kill(processID, SIGKILL)
            }
        }
    }

    private func finish(runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        loopTask = nil
        currentProcess = nil
        phase = .idle
    }

    private static func loadRange(
        defaults: UserDefaults,
        minimumKey: String,
        maximumKey: String,
        fallback: LoopSecondRange,
        legacyMinimumKey: String,
        legacyMaximumKey: String
    ) -> LoopSecondRange {
        let minimum = defaults.object(forKey: minimumKey).map { _ in
            defaults.integer(forKey: minimumKey)
        } ?? defaults.object(forKey: legacyMinimumKey).map { _ in
            defaults.integer(forKey: legacyMinimumKey) * 60
        } ?? fallback.minimum
        let maximum = defaults.object(forKey: maximumKey).map { _ in
            defaults.integer(forKey: maximumKey)
        } ?? defaults.object(forKey: legacyMaximumKey).map { _ in
            defaults.integer(forKey: legacyMaximumKey) * 60
        } ?? fallback.maximum

        return LoopSecondRange(minimum: minimum, maximum: maximum) ?? fallback
    }

    private static func trailingCharacters(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
