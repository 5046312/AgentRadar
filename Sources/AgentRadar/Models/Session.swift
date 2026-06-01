import Foundation

enum RuntimeKind: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "sparkles"
        case .codex:  return "terminal"
        }
    }
}

enum SessionStatus: String, Codable {
    case running
    case waiting
    case idle
    case completed
    case error
}

struct Session: Identifiable, Equatable {
    let id: String
    var runtime: RuntimeKind
    var projectPath: String
    var projectName: String
    var gitBranch: String?
    var status: SessionStatus
    var lastActivity: Date
    var lastEventTimestamp: Date
    var activeStartedAt: Date?
    var currentTool: String?
    var taskTitle: String?
    var lastAssistantText: String?
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var lastTokenTotal: Int
    var fileURL: URL
    var fileOffset: UInt64
    var completedFlashUntil: Date?
    var lastDuration: TimeInterval?
}

struct CompletionNotice: Identifiable, Equatable {
    let id = UUID()
    let runtime: RuntimeKind
    let taskTitle: String
    let duration: TimeInterval?
    let tokenTotal: Int

    init(session: Session) {
        runtime = session.runtime
        taskTitle = session.taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? session.projectName
        duration = session.lastDuration
        tokenTotal = max(
            session.lastTokenTotal,
            session.inputTokens + session.outputTokens + session.cacheReadTokens
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
