import Foundation

enum SessionStatus: String, Codable {
    case running
    case waiting
    case idle
    case completed
    case error
}

struct Session: Identifiable, Equatable {
    let id: String
    var projectPath: String
    var projectName: String
    var gitBranch: String?
    var status: SessionStatus
    var lastActivity: Date
    var lastEventTimestamp: Date
    var currentTool: String?
    var lastAssistantText: String?
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var fileURL: URL
    var fileOffset: UInt64
    var completedFlashUntil: Date?
}
