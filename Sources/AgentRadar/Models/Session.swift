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

enum ReminderStyle: String, Codable, CaseIterable, Identifiable {
    case statusBarBubble
    case systemNotification

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .statusBarBubble: return "状态栏气泡"
        case .systemNotification: return "系统消息"
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
    var status: SessionStatus
    var lastActivity: Date
    var lastEventTimestamp: Date
    var activeStartedAt: Date?
    var activeStartedTokenTotal: Int?
    var tpsSampleTokenTotal: Int?
    var tpsSampleTimestamp: Date?
    var currentTPS: Double?
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
    let projectName: String
    let duration: TimeInterval?
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int

    init(session: Session) {
        runtime = session.runtime
        projectName = session.projectName
        duration = session.lastDuration
        inputTokens = session.inputTokens
        outputTokens = session.outputTokens
        cacheReadTokens = session.cacheReadTokens
        totalTokens = max(
            session.lastTokenTotal,
            session.inputTokens + session.outputTokens + session.cacheReadTokens
        )
    }
}

struct FailureNotice: Identifiable, Equatable {
    let id = UUID()
    let runtime: RuntimeKind
    let projectName: String

    init(session: Session) {
        runtime = session.runtime
        projectName = session.projectName
    }
}

extension CompletionNotice {
    var titleText: String {
        projectName
    }

    var bubbleMessageText: String {
        "任务完成，请及时审阅"
    }

    var messageText: String {
        "\(projectName) 任务完成，请及时审阅"
    }

    var notificationBodyText: String {
        messageText
    }

    var durationText: String? {
        guard let duration else { return nil }
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "耗时 \(hours)小时\(minutes)分\(seconds)秒"
        }
        if minutes > 0 {
            return "耗时 \(minutes)分\(seconds)秒"
        }
        return "耗时 \(seconds)秒"
    }
}

extension FailureNotice {
    var titleText: String {
        projectName
    }

    var bubbleMessageText: String {
        "任务失败，请及时审阅"
    }

    var messageText: String {
        "\(projectName) 任务失败，请及时审阅"
    }

    var notificationBodyText: String {
        messageText
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
