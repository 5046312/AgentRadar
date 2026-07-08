import Foundation

enum ProbeTestProtocol: String, Codable, CaseIterable, Identifiable {
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        }
    }
}

struct ProbeTestConfig: Identifiable, Codable, Equatable {
    let id: UUID
    var protocolType: ProbeTestProtocol
    var baseURL: String
    var apiKey: String
    var model: String
    var intervalSeconds: Double
}

struct ProbeTestRow: Identifiable {
    let id: UUID
    let config: ProbeTestConfig
    let statusText: String
    let isRunning: Bool

    var protocolName: String {
        config.protocolType.displayName
    }
}

struct ProbeTestHistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

private enum ProbeTestStatus: Equatable {
    case idle
    case polling(attempt: Int)
    case failed(message: String)
    case success

    var text: String {
        switch self {
        case .idle:
            return "等待开始"
        case let .polling(attempt):
            return "轮询中 第\(attempt)次"
        case let .failed(message):
            return message
        case .success:
            return "成功"
        }
    }
}

private struct OpenAIModelListResponse: Decodable {
    struct Item: Decodable {
        let id: String
    }

    let data: [Item]
}

private struct OpenAIChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct OpenAIChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: OpenAIMessageContent?
        }

        let message: Message?
    }

    let choices: [Choice]
}

private enum OpenAIMessageContent: Decodable {
    struct Part: Decodable {
        let text: String?
    }

    case text(String)
    case parts([Part])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        if let parts = try? container.decode([Part].self) {
            self = .parts(parts)
            return
        }
        throw DecodingError.typeMismatch(
            OpenAIMessageContent.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported content shape")
        )
    }

    var plainText: String {
        switch self {
        case let .text(text):
            return text
        case let .parts(parts):
            return parts.compactMap(\.text).joined()
        }
    }
}

@MainActor
final class ProbeTestStore: ObservableObject {
    private enum DefaultsKey {
        static let configs = "probeTestConfigs"
    }

    @Published private(set) var configs: [ProbeTestConfig] = []
    @Published private(set) var rows: [ProbeTestRow] = []

    private let sessionStore: SessionStore
    private var statuses: [UUID: ProbeTestStatus] = [:]
    private var histories: [UUID: [ProbeTestHistoryEntry]] = [:]
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        loadConfigs()
        syncRows()
        restartPolling()
    }

    deinit {
        pollingTasks.values.forEach { $0.cancel() }
    }

    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let requestURL = try makeEndpointURL(baseURL: baseURL, path: "/models")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let payload = try decoder.decode(OpenAIModelListResponse.self, from: data)
        return payload.data.map(\.id).sorted()
    }

    func addConfig(
        protocolType: ProbeTestProtocol,
        baseURL: String,
        apiKey: String,
        model: String,
        intervalSeconds: Double
    ) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ProbeTestConfig(
            id: UUID(),
            protocolType: protocolType,
            baseURL: trimmedBaseURL,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: trimmedModel,
            intervalSeconds: max(0.1, intervalSeconds)
        )
        configs.insert(config, at: 0)
        persistConfigs()
        startPolling(for: config, resetStatus: true)
    }

    func stopConfig(id: UUID) {
        pollingTasks[id]?.cancel()
        pollingTasks[id] = nil
        if statuses[id] != .success {
            updateStatus(for: id, status: .failed(message: "已停止"))
        }
        syncRows()
    }

    func deleteConfig(id: UUID) {
        pollingTasks[id]?.cancel()
        pollingTasks[id] = nil
        statuses[id] = nil
        histories[id] = nil
        configs.removeAll { $0.id == id }
        persistConfigs()
        syncRows()
    }

    func history(for id: UUID) -> [ProbeTestHistoryEntry] {
        histories[id] ?? []
    }

    private func restartPolling() {
        for config in configs {
            if statuses[config.id] != .success {
                startPolling(for: config, resetStatus: false)
            }
        }
    }

    private func startPolling(for config: ProbeTestConfig, resetStatus: Bool) {
        pollingTasks[config.id]?.cancel()
        if resetStatus {
            updateStatus(for: config.id, status: .idle)
        }
        syncRows()

        pollingTasks[config.id] = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                attempt += 1
                await MainActor.run {
                    self.updateStatus(for: config.id, status: .polling(attempt: attempt))
                    self.syncRows()
                }

                do {
                    // 只要拿到非空文本就视为接口可用，立即停掉当前轮询。
                    let responseText = try await self.sendProbe(config: config)
                    if !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await MainActor.run {
                            self.updateStatus(for: config.id, status: .success)
                            self.syncRows()
                            self.sessionStore.publishProbeSuccessNotice(baseURL: config.baseURL, model: config.model)
                        }
                        return
                    }

                    await MainActor.run {
                        self.updateStatus(for: config.id, status: .failed(message: "返回为空，\(attempt)次"))
                        self.syncRows()
                    }
                } catch {
                    await MainActor.run {
                        self.updateStatus(for: config.id, status: .failed(message: self.failureText(from: error, attempt: attempt)))
                        self.syncRows()
                    }
                }

                let interval = UInt64(config.intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func sendProbe(config: ProbeTestConfig) async throws -> String {
        let requestURL = try makeEndpointURL(baseURL: config.baseURL, path: "/chat/completions")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(
            OpenAIChatCompletionRequest(
                model: config.model,
                messages: [.init(role: "user", content: "hi")]
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let payload = try decoder.decode(OpenAIChatCompletionResponse.self, from: data)
        // OpenAI 兼容接口有的返回字符串，有的返回分段数组，这里统一收敛成纯文本。
        return payload.choices.compactMap { $0.message?.content?.plainText }.joined()
    }

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.configs) else { return }
        guard let storedConfigs = try? decoder.decode([ProbeTestConfig].self, from: data) else { return }
        configs = storedConfigs
    }

    private func persistConfigs() {
        guard let data = try? encoder.encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.configs)
    }

    private func syncRows() {
        rows = configs.map { config in
            ProbeTestRow(
                id: config.id,
                config: config,
                statusText: statuses[config.id]?.text ?? ProbeTestStatus.idle.text,
                isRunning: pollingTasks[config.id] != nil
            )
        }
    }

    private func updateStatus(for id: UUID, status: ProbeTestStatus) {
        statuses[id] = status
        appendHistory(for: id, message: status.text)
    }

    private func appendHistory(for id: UUID, message: String) {
        var entries = histories[id] ?? []
        if entries.first?.message == message {
            return
        }
        entries.insert(ProbeTestHistoryEntry(timestamp: Date(), message: message), at: 0)
        if entries.count > 10 {
            entries = Array(entries.prefix(10))
        }
        histories[id] = entries
    }

    private func makeEndpointURL(baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProbeTestError.invalidBaseURL
        }
        let normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: normalizedBase + path) else {
            throw ProbeTestError.invalidBaseURL
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProbeTestError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProbeTestError.http(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func failureText(from error: Error, attempt: Int) -> String {
        let prefix = "失败 \(attempt)次"
        guard let probeError = error as? ProbeTestError else {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? prefix : "\(prefix) \(detail)"
        }
        return "\(prefix) \(probeError.displayText)"
    }
}

private enum ProbeTestError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case http(statusCode: Int, message: String?)

    var displayText: String {
        switch self {
        case .invalidBaseURL:
            return "baseUrl 无效"
        case .invalidResponse:
            return "响应无效"
        case let .http(statusCode, message):
            guard let message, !message.isEmpty else {
                return "HTTP \(statusCode)"
            }
            return "HTTP \(statusCode) \(message)"
        }
    }

    var errorDescription: String? {
        displayText
    }
}
