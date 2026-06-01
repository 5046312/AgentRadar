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

enum StatusBarStyle: String, Codable, CaseIterable, Identifiable {
    case defaultDot
    case nineGrid
    case signalBars
    case orbitRing
    case tripleDots

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .defaultDot: return "默认圆点"
        case .nineGrid: return "九宫格"
        case .signalBars: return "信号柱"
        case .orbitRing: return "环形轨道"
        case .tripleDots: return "三点追踪"
        }
    }

    var detailText: String {
        switch self {
        case .defaultDot:
            return "当前绿色圆点样式。运行中做呼吸闪烁。"
        case .nineGrid:
            return "3x3 方格。运行中从左上第 0 格开始逐个闪烁。"
        case .signalBars:
            return "四段柱形波。运行中按波峰顺序流动。"
        case .orbitRing:
            return "八点环形。运行中沿圆环顺时针轮转。"
        case .tripleDots:
            return "三点横向追踪。运行中按顺序左右流动。"
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
