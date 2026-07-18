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

@MainActor
final class LoopStore: ObservableObject {
    private enum DefaultsKey {
        static let minimumMinutes = "loopMinimumMinutes"
        static let maximumMinutes = "loopMaximumMinutes"
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

    static let defaultMinimumMinutes = 1
    static let defaultMaximumMinutes = 5
    static let maximumDisplayedCharacters = 20_000

    @Published private(set) var minimumMinutes: Int
    @Published private(set) var maximumMinutes: Int
    @Published private(set) var notifyOnSuccess: Bool
    @Published private(set) var phase: LoopPhase = .idle
    @Published private(set) var lastResult: LoopRunResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestSuccess: LoopSuccessNotice?

    private let defaults: UserDefaults
    private var loopTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var currentProcess: Process?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedMinimum = defaults.object(forKey: DefaultsKey.minimumMinutes) == nil
            ? Self.defaultMinimumMinutes
            : defaults.integer(forKey: DefaultsKey.minimumMinutes)
        let storedMaximum = defaults.object(forKey: DefaultsKey.maximumMinutes) == nil
            ? Self.defaultMaximumMinutes
            : defaults.integer(forKey: DefaultsKey.maximumMinutes)
        let storedRange = LoopMinuteRange(minimum: storedMinimum, maximum: storedMaximum)

        minimumMinutes = storedRange?.minimum ?? Self.defaultMinimumMinutes
        maximumMinutes = storedRange?.maximum ?? Self.defaultMaximumMinutes
        notifyOnSuccess = defaults.bool(forKey: DefaultsKey.notifyOnSuccess)
    }

    var isActive: Bool {
        phase != .idle
    }

    func setMinuteRange(_ range: LoopMinuteRange) {
        minimumMinutes = range.minimum
        maximumMinutes = range.maximum
        defaults.set(range.minimum, forKey: DefaultsKey.minimumMinutes)
        defaults.set(range.maximum, forKey: DefaultsKey.maximumMinutes)
    }

    func setNotifyOnSuccess(_ enabled: Bool) {
        notifyOnSuccess = enabled
        defaults.set(enabled, forKey: DefaultsKey.notifyOnSuccess)
    }

    func start(range: LoopMinuteRange) {
        guard !isActive else { return }

        setMinuteRange(range)
        lastResult = nil
        errorMessage = nil
        latestSuccess = nil
        phase = .resolvingCodex

        let runID = UUID()
        activeRunID = runID
        loopTask = Task { [weak self] in
            await self?.runLoop(range: range, runID: runID)
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

    private func runLoop(range: LoopMinuteRange, runID: UUID) async {
        let codexURL: URL
        do {
            codexURL = try await resolveCodexURL()
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
            let delayNanoseconds = range.randomDelayNanoseconds()
            let delaySeconds = TimeInterval(delayNanoseconds) / 1_000_000_000
            phase = .waiting(count: count, nextRunAt: Date().addingTimeInterval(delaySeconds))

            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                break
            }
            guard activeRunID == runID, !Task.isCancelled else { break }

            let startedAt = Date()
            phase = .running(count: count, startedAt: startedAt)
            let outcome = await executeCodex(codexURL: codexURL, count: count, startedAt: startedAt)
            guard activeRunID == runID, !Task.isCancelled else { break }

            lastResult = outcome.result
            errorMessage = nil
            if outcome.result.succeeded, notifyOnSuccess, let message = outcome.notificationMessage {
                latestSuccess = LoopSuccessNotice(count: count, message: message, duration: outcome.result.duration)
            }
            count += 1
        }

        finish(runID: runID)
    }

    private func resolveCodexURL() async throws -> URL {
        let execution = try await runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lic", "command -v codex"],
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        guard execution.terminationStatus == EXIT_SUCCESS else {
            throw LoopStoreError.codexNotFound
        }

        let path = execution.standardOutput
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.hasPrefix("/") }
        guard
            let path,
            FileManager.default.isExecutableFile(atPath: path)
        else {
            throw LoopStoreError.codexNotFound
        }
        return URL(fileURLWithPath: path)
    }

    private func executeCodex(codexURL: URL, count: Int, startedAt: Date) async -> CodexExecutionOutcome {
        do {
            var environment = ProcessInfo.processInfo.environment
            let codexBinDirectory = codexURL.deletingLastPathComponent().path
            let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = "\(codexBinDirectory):\(inheritedPath)"

            let execution = try await runProcess(
                executableURL: codexURL,
                arguments: [
                    "exec",
                    "--json",
                    "--ephemeral",
                    "--ignore-user-config",
                    "--ignore-rules",
                    "--disable", "hooks",
                    "--sandbox", "read-only",
                    "--skip-git-repo-check",
                    String(count)
                ],
                currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                environment: environment
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
