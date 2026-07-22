import Foundation

enum LoopChannelValidationError: LocalizedError, Equatable {
    case nameRequired
    case invalidBaseURL
    case apiKeyRequired

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            return "请输入渠道名称。"
        case .invalidBaseURL:
            return "请输入 HTTPS 地址；本机调试可使用 localhost 或 127.0.0.1。"
        case .apiKeyRequired:
            return "请输入 API Key。"
        }
    }
}

enum LoopChannelStoreError: LocalizedError, Equatable {
    case duplicateName
    case channelNotFound
    case channelRunning

    var errorDescription: String? {
        switch self {
        case .duplicateName:
            return "渠道名称不能重复。"
        case .channelNotFound:
            return "未找到渠道。"
        case .channelRunning:
            return "请先停止渠道。"
        }
    }
}

enum LoopChannelImportError: LocalizedError, Equatable {
    case emptyFile
    case invalidChannel(Int, String)
    case missingField(String)
    case multipleChannelsWhileEditing

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "TXT 中没有渠道配置。"
        case let .invalidChannel(index, message):
            return "第 \(index) 条渠道：\(message)"
        case let .missingField(field):
            return "TXT 缺少 \(field)=...。"
        case .multipleChannelsWhileEditing:
            return "编辑渠道时只能导入一条配置。"
        }
    }
}

struct LoopChannelImportValues: Equatable {
    static let templateText = """
    # 多个渠道请复制三行配置，并使用 --- 单独一行分隔
    name=主渠道
    baseUrl=https://example.com/v1
    apiKey=请替换为真实API Key
    """

    let name: String
    let baseURL: String
    let apiKey: String

    static func parseMany(text: String) throws -> [LoopChannelImportValues] {
        var blocks: [[String]] = []
        var currentBlock: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                if !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                    currentBlock = []
                }
            } else {
                currentBlock.append(line)
            }
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }
        blocks = blocks.filter { block in
            block.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
        }
        guard !blocks.isEmpty else {
            throw LoopChannelImportError.emptyFile
        }

        return try blocks.enumerated().map { offset, block in
            do {
                return try LoopChannelImportValues(text: block.joined(separator: "\n"))
            } catch {
                throw LoopChannelImportError.invalidChannel(offset + 1, error.localizedDescription)
            }
        }
    }

    init(text: String) throws {
        var fields: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = value
        }

        guard let name = fields["name"], !name.isEmpty else {
            throw LoopChannelImportError.missingField("name")
        }
        guard let baseURL = fields["baseurl"], !baseURL.isEmpty else {
            throw LoopChannelImportError.missingField("baseUrl")
        }
        guard let apiKey = fields["apikey"], !apiKey.isEmpty else {
            throw LoopChannelImportError.missingField("apiKey")
        }
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

enum LoopAggregateStatus: Equatable {
    case inactive
    case pending
    case success
    case failure
    case recovered

    static func resolve(_ channels: [LoopChannel]) -> LoopAggregateStatus {
        let activeChannels = channels.filter { $0.isActive }
        guard !activeChannels.isEmpty else { return .inactive }
        if activeChannels.contains(where: { $0.streakSucceeded == false }) {
            return .failure
        }
        if activeChannels.contains(where: { $0.recoveredFromFailure }) {
            return .recovered
        }
        if activeChannels.contains(where: { $0.streakSucceeded == nil }) {
            return .pending
        }
        return .success
    }
}

struct LoopChannelConfiguration: Codable, Equatable, Identifiable {
    static let apiKeyEnvironmentName = "AGENTRADAR_LOOP_API_KEY"

    let id: UUID
    let name: String
    let baseURL: String
    let apiKey: String

    var codexConfigurationOverrides: [String] {
        [
            "model_provider=\"agentradar_loop\"",
            "model_providers.agentradar_loop.name=\"AgentRadar Loop\"",
            "model_providers.agentradar_loop.base_url=\"\(baseURL)\"",
            "model_providers.agentradar_loop.wire_api=\"responses\"",
            "model_providers.agentradar_loop.env_key=\"\(Self.apiKeyEnvironmentName)\"",
            "model_providers.agentradar_loop.supports_websockets=false"
        ]
    }

    init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw LoopChannelValidationError.nameRequired
        }
        guard Self.isAllowedBaseURL(normalizedBaseURL) else {
            throw LoopChannelValidationError.invalidBaseURL
        }
        guard !normalizedAPIKey.isEmpty else {
            throw LoopChannelValidationError.apiKeyRequired
        }

        self.id = id
        self.name = normalizedName
        self.baseURL = normalizedBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = normalizedAPIKey
    }

    private static func isAllowedBaseURL(_ value: String) -> Bool {
        guard
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty
        else {
            return false
        }
        if scheme == "https" {
            return true
        }
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1")
    }
}

struct LoopChannel: Equatable, Identifiable {
    var configuration: LoopChannelConfiguration
    var phase: LoopPhase = .idle
    var lastResult: LoopRunResult?
    var errorMessage: String?
    var successCount = 0
    var failureCount = 0
    var streakCount = 0
    var streakSucceeded: Bool?
    var recoveredFromFailure = false
    var nextRunCount = 1

    var id: UUID { configuration.id }
    var name: String { configuration.name }
    var baseURL: String { configuration.baseURL }
    var apiKey: String { configuration.apiKey }
    var isActive: Bool { phase != .idle }
}
