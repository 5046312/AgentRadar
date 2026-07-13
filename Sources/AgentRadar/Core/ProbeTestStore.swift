import Foundation
import Security

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
    var model: String
    var intervalSeconds: Double

    // 仅用于把旧版 UserDefaults 明文凭据迁移到 Keychain，新配置不会写入此字段。
    fileprivate var legacyAPIKey: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case protocolType
        case baseURL
        case apiKey
        case model
        case intervalSeconds
    }

    init(
        id: UUID,
        protocolType: ProbeTestProtocol,
        baseURL: String,
        model: String,
        intervalSeconds: Double
    ) {
        self.id = id
        self.protocolType = protocolType
        self.baseURL = baseURL
        self.model = model
        self.intervalSeconds = intervalSeconds
        self.legacyAPIKey = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        protocolType = try container.decode(ProbeTestProtocol.self, forKey: .protocolType)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        intervalSeconds = try container.decode(Double.self, forKey: .intervalSeconds)
        legacyAPIKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(protocolType, forKey: .protocolType)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(intervalSeconds, forKey: .intervalSeconds)
        if let legacyAPIKey {
            // Keychain 迁移失败时先保留旧值，避免静默丢失用户凭据。
            try container.encode(legacyAPIKey, forKey: .apiKey)
        }
    }
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
    private var pollingTokens: [UUID: UUID] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    nonisolated private static let minimumIntervalSeconds = 1.0
    nonisolated private static let maximumRetryIntervalSeconds = 60.0
    nonisolated private static let maximumPollingAttempts = 10

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        loadConfigs()
        syncRows()
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
    ) throws {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try makeEndpointURL(baseURL: trimmedBaseURL, path: "/models")
        guard !trimmedAPIKey.isEmpty else { throw ProbeTestError.missingAPIKey }
        let id = UUID()
        try ProbeCredentialStore.save(apiKey: trimmedAPIKey, for: id)
        let config = ProbeTestConfig(
            id: id,
            protocolType: protocolType,
            baseURL: trimmedBaseURL,
            model: trimmedModel,
            intervalSeconds: max(Self.minimumIntervalSeconds, intervalSeconds)
        )
        configs.insert(config, at: 0)
        persistConfigs()
        startPolling(for: config, resetStatus: true)
    }

    func startConfig(id: UUID) {
        guard let config = configs.first(where: { $0.id == id }) else { return }
        startPolling(for: config, resetStatus: true)
    }

    func stopConfig(id: UUID) {
        pollingTasks[id]?.cancel()
        pollingTasks[id] = nil
        pollingTokens[id] = nil
        if statuses[id] != .success {
            updateStatus(for: id, status: .failed(message: "已停止"))
        }
        syncRows()
    }

    func deleteConfig(id: UUID) {
        pollingTasks[id]?.cancel()
        pollingTasks[id] = nil
        pollingTokens[id] = nil
        statuses[id] = nil
        histories[id] = nil
        configs.removeAll { $0.id == id }
        ProbeCredentialStore.delete(for: id)
        persistConfigs()
        syncRows()
    }

    func history(for id: UUID) -> [ProbeTestHistoryEntry] {
        histories[id] ?? []
    }

    private func startPolling(for config: ProbeTestConfig, resetStatus: Bool) {
        pollingTasks[config.id]?.cancel()
        let token = UUID()
        pollingTokens[config.id] = token
        if resetStatus {
            updateStatus(for: config.id, status: .idle)
        }
        pollingTasks[config.id] = Task { [weak self] in
            defer { self?.finishPolling(id: config.id, token: token) }

            for attempt in 1...Self.maximumPollingAttempts {
                guard !Task.isCancelled else { return }
                guard let shouldStop = await self?.performProbeAttempt(config: config, attempt: attempt, token: token) else { return }
                if shouldStop { return }

                if attempt == Self.maximumPollingAttempts {
                    guard let self, self.pollingTokens[config.id] == token else { return }
                    self.updateStatus(for: config.id, status: .failed(message: "连续失败 \(attempt) 次，已停止"))
                    return
                }

                let interval = Self.retryInterval(base: config.intervalSeconds, attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        syncRows()
    }

    private func performProbeAttempt(config: ProbeTestConfig, attempt: Int, token: UUID) async -> Bool {
        guard pollingTokens[config.id] == token else { return true }
        updateStatus(for: config.id, status: .polling(attempt: attempt))
        syncRows()

        do {
            // 只要拿到非空文本就视为接口可用，立即停掉当前轮询。
            let responseText = try await sendProbe(config: config)
            guard !Task.isCancelled, pollingTokens[config.id] == token else { return true }
            if !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateStatus(for: config.id, status: .success)
                syncRows()
                sessionStore.publishProbeSuccessNotice(baseURL: config.baseURL, model: config.model)
                return true
            }

            updateStatus(for: config.id, status: .failed(message: "返回为空，\(attempt)次"))
            syncRows()
        } catch {
            guard !Task.isCancelled, pollingTokens[config.id] == token else { return true }
            updateStatus(for: config.id, status: .failed(message: failureText(from: error, attempt: attempt)))
            syncRows()
        }
        return false
    }

    private func finishPolling(id: UUID, token: UUID) {
        guard pollingTokens[id] == token else { return }
        pollingTasks[id] = nil
        pollingTokens[id] = nil
        syncRows()
    }

    private func sendProbe(config: ProbeTestConfig) async throws -> String {
        guard let apiKey = ProbeCredentialStore.load(for: config.id) ?? config.legacyAPIKey, !apiKey.isEmpty else {
            throw ProbeTestError.missingAPIKey
        }
        let requestURL = try makeEndpointURL(baseURL: config.baseURL, path: "/chat/completions")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        guard var storedConfigs = try? decoder.decode([ProbeTestConfig].self, from: data) else { return }
        var shouldPersist = false

        for index in storedConfigs.indices {
            if storedConfigs[index].intervalSeconds < Self.minimumIntervalSeconds {
                storedConfigs[index].intervalSeconds = Self.minimumIntervalSeconds
                shouldPersist = true
            }
            guard let legacyAPIKey = storedConfigs[index].legacyAPIKey, !legacyAPIKey.isEmpty else { continue }
            do {
                try ProbeCredentialStore.save(apiKey: legacyAPIKey, for: storedConfigs[index].id)
                storedConfigs[index].legacyAPIKey = nil
                shouldPersist = true
            } catch {
                statuses[storedConfigs[index].id] = .failed(message: "API Key 迁移失败，请删除后重建")
            }
        }

        configs = storedConfigs
        if shouldPersist {
            persistConfigs()
        }
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
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            throw ProbeTestError.invalidBaseURL
        }
        guard let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty else {
            throw ProbeTestError.invalidBaseURL
        }
        let isLocalHTTP = scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        guard scheme == "https" || isLocalHTTP else {
            throw ProbeTestError.insecureBaseURL
        }

        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw ProbeTestError.invalidBaseURL
        }
        return url
    }

    nonisolated private static func retryInterval(base: Double, attempt: Int) -> Double {
        let multiplier = pow(2.0, Double(max(0, attempt - 1)))
        return min(maximumRetryIntervalSeconds, max(minimumIntervalSeconds, base) * multiplier)
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
    case insecureBaseURL
    case invalidResponse
    case missingAPIKey
    case keychain(OSStatus)
    case http(statusCode: Int, message: String?)

    var displayText: String {
        switch self {
        case .invalidBaseURL:
            return "baseUrl 无效"
        case .insecureBaseURL:
            return "Base URL 必须使用 HTTPS；本机 localhost 可使用 HTTP"
        case .invalidResponse:
            return "响应无效"
        case .missingAPIKey:
            return "Keychain 中没有找到 API Key"
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            return "Keychain 写入失败：\(detail)"
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

private enum ProbeCredentialStore {
    private static let service = Bundle.main.bundleIdentifier ?? "com.long.agentradar"

    static func save(apiKey: String, for id: UUID) throws {
        let query = baseQuery(for: id)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(apiKey.utf8)
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ProbeTestError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = Data(apiKey.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProbeTestError.keychain(addStatus)
        }
    }

    static func load(for id: UUID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for id: UUID) {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
    }

    private static func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "probe-test-\(id.uuidString)"
        ]
    }
}
