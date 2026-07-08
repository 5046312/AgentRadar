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
    var status: SessionStatus
    var lastActivity: Date
    var lastEventTimestamp: Date
    var taskName: String?
    var activeStartedAt: Date?
    var activeTurnId: String?
    var fileURL: URL
    var fileOffset: UInt64
    var completedFlashUntil: Date?
    var lastDuration: TimeInterval?
    var lastCompletedAt: Date?
}

struct CompletionNotice: Identifiable, Equatable {
    let id = UUID()
    let projectName: String
    let taskName: String?
    let duration: TimeInterval?

    init(projectName: String, taskName: String?, duration: TimeInterval?) {
        self.projectName = projectName
        self.taskName = taskName
        self.duration = duration
    }

    init(session: Session) {
        self.init(
            projectName: session.projectName,
            taskName: session.taskName,
            duration: session.lastDuration
        )
    }
}

struct FailureNotice: Identifiable, Equatable {
    let id = UUID()
    let projectName: String

    init(projectName: String) {
        self.projectName = projectName
    }

    init(session: Session) {
        projectName = session.projectName
    }
}

struct WaitingNotice: Identifiable, Equatable {
    let id = UUID()
    let projectName: String

    init(session: Session) {
        projectName = session.projectName
    }
}

struct ProbeSuccessNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let body: String
}

extension CompletionNotice {
    var titleText: String {
        projectName
    }

    var messageText: String {
        guard let taskName, !taskName.isEmpty else {
            return "任务完成，请及时审阅"
        }
        return "\(taskName)，任务完成，请及时审阅"
    }

    var notificationBodyText: String {
        [messageText, durationText].compactMap { $0 }.joined(separator: "\n")
    }

    var durationText: String? {
        guard let duration else { return nil }
        let totalSeconds = max(1, Int(duration.rounded(.up)))
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

extension WaitingNotice {
    var titleText: String {
        projectName
    }

    var messageText: String {
        "需要用户确认，请及时处理"
    }

    var notificationBodyText: String {
        messageText
    }
}

extension FailureNotice {
    var titleText: String {
        projectName
    }

    var messageText: String {
        "任务失败，请及时审阅"
    }

    var notificationBodyText: String {
        messageText
    }
}
