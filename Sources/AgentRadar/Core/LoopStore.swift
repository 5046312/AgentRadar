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
    let script: String
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
        static let enabledCommandOptions = "loopEnabledCommandOptions"
        static let channels = "loopChannels"
        static let legacyMinimumMinutes = "loopMinimumMinutes"
        static let legacyMaximumMinutes = "loopMaximumMinutes"
    }

    private enum LoopStoreError: LocalizedError {
        case codexNotFound

        var errorDescription: String? {
            switch self {
            case .codexNotFound:
                return "未找到 codex，请先确认终端中可执行 command -v codex。"
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
    @Published private(set) var enabledCommandOptions: Set<LoopCommandOption>
    @Published private(set) var channels: [LoopChannel]
    @Published private(set) var latestSuccess: LoopSuccessNotice?

    private let defaults: UserDefaults
    private var channelTasks: [UUID: Task<Void, Never>] = [:]
    private var activeRunIDs: [UUID: UUID] = [:]
    private var currentProcesses: [UUID: Process] = [:]

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
        enabledCommandOptions = Self.loadCommandOptions(defaults: defaults)
        channels = Self.loadChannels(defaults: defaults)
    }

    var isActive: Bool {
        channels.contains(where: { $0.isActive })
    }

    var aggregateStatus: LoopAggregateStatus {
        LoopAggregateStatus.resolve(channels)
    }

    var activeChannelCount: Int {
        channels.filter { $0.isActive }.count
    }

    private var successRange: LoopSecondRange {
        LoopSecondRange(minimum: successMinimumSeconds, maximum: successMaximumSeconds)!
    }

    private var failureRange: LoopSecondRange {
        LoopSecondRange(minimum: failureMinimumSeconds, maximum: failureMaximumSeconds)!
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

    func setCommandOption(_ option: LoopCommandOption, enabled: Bool) {
        if enabled {
            enabledCommandOptions.insert(option)
        } else {
            enabledCommandOptions.remove(option)
        }
        let storedValues = LoopCommandOption.allCases
            .filter(enabledCommandOptions.contains)
            .map(\.rawValue)
        defaults.set(storedValues, forKey: DefaultsKey.enabledCommandOptions)
    }

    @discardableResult
    func addChannel(name: String, baseURL: String, apiKey: String) throws -> UUID {
        let configuration = try LoopChannelConfiguration(name: name, baseURL: baseURL, apiKey: apiKey)
        guard !hasChannel(named: configuration.name, excluding: nil) else {
            throw LoopChannelStoreError.duplicateName
        }
        channels.append(LoopChannel(configuration: configuration))
        persistChannels()
        return configuration.id
    }

    @discardableResult
    func addChannels(_ values: [LoopChannelImportValues]) throws -> [UUID] {
        let configurations = try values.map { values in
            try LoopChannelConfiguration(
                name: values.name,
                baseURL: values.baseURL,
                apiKey: values.apiKey
            )
        }
        var names = channels.map(\.name)
        for configuration in configurations {
            guard !names.contains(where: {
                $0.localizedCaseInsensitiveCompare(configuration.name) == .orderedSame
            }) else {
                throw LoopChannelStoreError.duplicateName
            }
            names.append(configuration.name)
        }

        channels.append(contentsOf: configurations.map { LoopChannel(configuration: $0) })
        persistChannels()
        return configurations.map(\.id)
    }

    func updateChannel(id: UUID, name: String, baseURL: String, apiKey: String?) throws {
        guard let index = channels.firstIndex(where: { $0.id == id }) else {
            throw LoopChannelStoreError.channelNotFound
        }
        guard !channels[index].isActive else {
            throw LoopChannelStoreError.channelRunning
        }
        let storedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveAPIKey = storedAPIKey.flatMap { $0.isEmpty ? nil : $0 } ?? channels[index].apiKey
        let configuration = try LoopChannelConfiguration(
            id: id,
            name: name,
            baseURL: baseURL,
            apiKey: effectiveAPIKey
        )
        guard !hasChannel(named: configuration.name, excluding: id) else {
            throw LoopChannelStoreError.duplicateName
        }
        channels[index].configuration = configuration
        persistChannels()
    }

    func deleteChannel(id: UUID) throws {
        guard let index = channels.firstIndex(where: { $0.id == id }) else {
            throw LoopChannelStoreError.channelNotFound
        }
        guard !channels[index].isActive else {
            throw LoopChannelStoreError.channelRunning
        }
        channels.remove(at: index)
        persistChannels()
    }

    func resetStatistics() {
        // 仅清零累计结果，保留各渠道运行阶段和最近一次调用详情。
        for index in channels.indices {
            channels[index].successCount = 0
            channels[index].failureCount = 0
            channels[index].streakCount = 0
            channels[index].streakSucceeded = nil
            channels[index].recoveredFromFailure = false
        }
    }

    func toggleChannel(id: UUID) {
        guard let channel = channel(id: id) else { return }
        channel.isActive ? stopChannel(id: id) : startChannel(id: id)
    }

    func startChannel(id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }), !channels[index].isActive else {
            return
        }
        channels[index].phase = .resolvingCodex
        channels[index].errorMessage = nil

        let runID = UUID()
        activeRunIDs[id] = runID
        channelTasks[id] = Task { [weak self] in
            await self?.runLoop(channelID: id, runID: runID)
        }
    }

    func stopChannel(id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }), channels[index].isActive else {
            return
        }
        channels[index].phase = .stopping
        channelTasks[id]?.cancel()
        terminateCurrentProcess(channelID: id)
    }

    func stopForApplicationTermination() {
        channelTasks.values.forEach { $0.cancel() }
        channelTasks.removeAll()
        activeRunIDs.removeAll()
        // App 即将退出时没有时间等待 SIGTERM fallback，直接结束自己启动的 Codex 子进程。
        for process in currentProcesses.values where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        currentProcesses.removeAll()
        for index in channels.indices {
            channels[index].phase = .idle
        }
    }

    private func runLoop(channelID: UUID, runID: UUID) async {
        let codexContext: CodexCommandContext
        do {
            codexContext = try await resolveCodexContext(channelID: channelID)
        } catch {
            guard isCurrentRun(channelID: channelID, runID: runID), !Task.isCancelled else {
                finish(channelID: channelID, runID: runID)
                return
            }
            updateChannel(id: channelID) { channel in
                channel.errorMessage = error.localizedDescription
            }
            finish(channelID: channelID, runID: runID)
            return
        }

        var shouldWait = false
        while isCurrentRun(channelID: channelID, runID: runID), !Task.isCancelled {
            guard let currentChannel = channel(id: channelID) else { break }
            let count = currentChannel.nextRunCount
            if shouldWait {
                // 各渠道按自身上轮结果选统一间隔；每轮读取最新配置，允许运行中调整。
                let delayRange = currentChannel.streakSucceeded == false ? failureRange : successRange
                let delayNanoseconds = delayRange.randomDelayNanoseconds()
                let delaySeconds = TimeInterval(delayNanoseconds) / 1_000_000_000
                updateChannel(id: channelID) { channel in
                    channel.phase = .waiting(count: count, nextRunAt: Date().addingTimeInterval(delaySeconds))
                }

                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    break
                }
            }
            guard
                isCurrentRun(channelID: channelID, runID: runID),
                !Task.isCancelled,
                let configuration = channel(id: channelID)?.configuration
            else {
                break
            }

            let startedAt = Date()
            updateChannel(id: channelID) { channel in
                channel.phase = .running(count: count, startedAt: startedAt)
            }
            let outcome = await executeCodex(
                context: codexContext,
                configuration: configuration,
                channelID: channelID,
                count: count,
                startedAt: startedAt
            )
            guard isCurrentRun(channelID: channelID, runID: runID), !Task.isCancelled else { break }
            apply(outcome: outcome, channelID: channelID)
            shouldWait = true
        }

        finish(channelID: channelID, runID: runID)
    }

    private func resolveCodexContext(channelID: UUID) async throws -> CodexCommandContext {
        let executablePrefix = CodexCommandContext.executablePathPrefix
        let pathPrefix = CodexCommandContext.loginShellPathPrefix
        let execution = try await runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-lic",
                "codex_path=$(command -v codex) && printf '\\n\(executablePrefix)%s\\n\(pathPrefix)%s\\n' \"$codex_path\" \"$PATH\""
            ],
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            channelID: channelID
        )
        guard execution.terminationStatus == EXIT_SUCCESS else {
            throw LoopStoreError.codexNotFound
        }

        guard let context = CodexCommandContext(discoveryOutput: execution.standardOutput) else {
            throw LoopStoreError.codexNotFound
        }
        return context
    }

    private func executeCodex(
        context: CodexCommandContext,
        configuration: LoopChannelConfiguration,
        channelID: UUID,
        count: Int,
        startedAt: Date
    ) async -> CodexExecutionOutcome {
        let enabledOptions = enabledCommandOptions
        let arguments = configuration.codexArguments(count: count, enabledOptions: enabledOptions)
        let script = configuration.displayScript(
            executablePath: context.executableURL.path,
            count: count,
            enabledOptions: enabledOptions
        )
        do {
            var environment = context.executionEnvironment(base: ProcessInfo.processInfo.environment)
            environment[LoopChannelConfiguration.apiKeyEnvironmentName] = configuration.apiKey
            let execution = try await runProcess(
                executableURL: context.executableURL,
                arguments: arguments,
                currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                environment: environment,
                channelID: channelID
            )
            let completedAt = Date()
            let rawMessage = LoopOutputParser.lastAgentMessage(in: execution.standardOutput)
            let message = rawMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty

            return CodexExecutionOutcome(result: LoopRunResult(
                count: count,
                script: script,
                completedAt: completedAt,
                duration: completedAt.timeIntervalSince(startedAt),
                terminationStatus: execution.terminationStatus,
                message: message.map { Self.trailingCharacters($0, limit: Self.maximumDisplayedCharacters) },
                errorText: message == nil
                    ? LoopOutputParser.completeFailureOutput(
                        standardOutput: execution.standardOutput,
                        standardError: execution.standardError
                    )
                    : nil
            ))
        } catch {
            let completedAt = Date()
            return CodexExecutionOutcome(result: LoopRunResult(
                count: count,
                script: script,
                completedAt: completedAt,
                duration: completedAt.timeIntervalSince(startedAt),
                terminationStatus: nil,
                message: nil,
                errorText: error.localizedDescription
            ))
        }
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        channelID: UUID
    ) async throws -> ProcessExecution {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputReader = outputPipe.fileHandleForReading
        let errorReader = errorPipe.fileHandleForReading
        let outputReadTask = Task.detached(priority: .utility) {
            try outputReader.readToEnd() ?? Data()
        }
        let errorReadTask = Task.detached(priority: .utility) {
            try errorReader.readToEnd() ?? Data()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let terminationStatus = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
            do {
                try process.run()
                currentProcesses[channelID] = process
                // 父进程关闭写端，仅保留子进程副本；后台读取持续排空 Pipe，避免大 JSON 堵塞。
                outputPipe.fileHandleForWriting.closeFile()
                errorPipe.fileHandleForWriting.closeFile()
            } catch {
                process.terminationHandler = nil
                outputPipe.fileHandleForWriting.closeFile()
                errorPipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: error)
            }
        }
        if currentProcesses[channelID] === process {
            currentProcesses[channelID] = nil
        }

        let outputData = try await outputReadTask.value
        let errorData = try await errorReadTask.value
        return ProcessExecution(
            standardOutput: String(data: outputData, encoding: .utf8) ?? "",
            standardError: String(data: errorData, encoding: .utf8) ?? "",
            terminationStatus: terminationStatus
        )
    }

    private func apply(outcome: CodexExecutionOutcome, channelID: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return }
        let previouslySucceeded = channels[index].streakSucceeded
        let consecutiveFailureCount = previouslySucceeded == false ? channels[index].streakCount : 0
        channels[index].lastResult = outcome.result
        channels[index].errorMessage = nil
        channels[index].nextRunCount += 1

        if outcome.result.succeeded {
            channels[index].successCount += 1
            channels[index].streakCount = previouslySucceeded == true ? channels[index].streakCount + 1 : 1
            channels[index].streakSucceeded = true
            channels[index].recoveredFromFailure = previouslySucceeded == false
            if channels[index].recoveredFromFailure, let message = outcome.result.message {
                latestSuccess = LoopSuccessNotice(
                    channelName: channels[index].name,
                    count: outcome.result.count,
                    failureCount: consecutiveFailureCount,
                    succeededAt: outcome.result.completedAt,
                    message: message,
                    duration: outcome.result.duration
                )
            }
        } else {
            channels[index].failureCount += 1
            channels[index].streakCount = previouslySucceeded == false ? channels[index].streakCount + 1 : 1
            channels[index].streakSucceeded = false
            channels[index].recoveredFromFailure = false
        }
    }

    private func channel(id: UUID) -> LoopChannel? {
        channels.first(where: { $0.id == id })
    }

    private func updateChannel(id: UUID, _ update: (inout LoopChannel) -> Void) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        update(&channels[index])
    }

    private func isCurrentRun(channelID: UUID, runID: UUID) -> Bool {
        activeRunIDs[channelID] == runID
    }

    private func terminateCurrentProcess(channelID: UUID) {
        guard let process = currentProcesses[channelID], process.isRunning else { return }
        process.terminate()
        let processID = process.processIdentifier

        // Codex 未响应 SIGTERM 时兜底强制结束，避免“停止”后后台进程继续消耗资源。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                kill(processID, SIGKILL)
            }
        }
    }

    private func finish(channelID: UUID, runID: UUID) {
        guard isCurrentRun(channelID: channelID, runID: runID) else { return }
        activeRunIDs[channelID] = nil
        channelTasks[channelID] = nil
        currentProcesses[channelID] = nil
        updateChannel(id: channelID) { channel in
            channel.phase = .idle
        }
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

    private func hasChannel(named name: String, excluding excludedID: UUID?) -> Bool {
        channels.contains { channel in
            channel.id != excludedID
                && channel.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func persistChannels() {
        let configurations = channels.map(\.configuration)
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        defaults.set(data, forKey: DefaultsKey.channels)
    }

    private static func loadChannels(defaults: UserDefaults) -> [LoopChannel] {
        guard
            let data = defaults.data(forKey: DefaultsKey.channels),
            let configurations = try? JSONDecoder().decode([LoopChannelConfiguration].self, from: data)
        else {
            return []
        }
        return configurations.map { LoopChannel(configuration: $0) }
    }

    private static func loadCommandOptions(defaults: UserDefaults) -> Set<LoopCommandOption> {
        guard defaults.object(forKey: DefaultsKey.enabledCommandOptions) != nil else {
            return Set(LoopCommandOption.allCases)
        }
        let storedValues = defaults.stringArray(forKey: DefaultsKey.enabledCommandOptions) ?? []
        return Set(storedValues.compactMap(LoopCommandOption.init(rawValue:)))
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
