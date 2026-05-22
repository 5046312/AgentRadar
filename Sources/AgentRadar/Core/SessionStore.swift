import Foundation
import AppKit

struct ProjectGroup: Identifiable {
    let id: String
    let name: String
    let path: String
    var sessions: [Session]

    var aggregateStatus: SessionStatus {
        let statuses = sessions.map(\.status)
        if statuses.contains(.error) { return .error }
        if statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.running) { return .running }
        if statuses.contains(.completed) { return .completed }
        return .idle
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var version: Int = 0
    @Published var soundEnabled: Bool = UserDefaults.standard.bool(forKey: "soundEnabled")

    var sortedSessions: [Session] {
        sessions.values.sorted { lhs, rhs in
            if lhs.status.priority != rhs.status.priority {
                return lhs.status.priority < rhs.status.priority
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    var projectGroups: [ProjectGroup] {
        var groups: [String: ProjectGroup] = [:]
        for s in sessions.values {
            if groups[s.projectPath] == nil {
                groups[s.projectPath] = ProjectGroup(id: s.projectPath, name: s.projectName, path: s.projectPath, sessions: [])
            }
            groups[s.projectPath]?.sessions.append(s)
        }
        var result = Array(groups.values)
        for i in result.indices {
            result[i].sessions.sort { lhs, rhs in
                if lhs.status.priority != rhs.status.priority { return lhs.status.priority < rhs.status.priority }
                return lhs.lastActivity > rhs.lastActivity
            }
        }
        result.sort { lhs, rhs in
            if lhs.aggregateStatus.priority != rhs.aggregateStatus.priority {
                return lhs.aggregateStatus.priority < rhs.aggregateStatus.priority
            }
            let lhsLatest = lhs.sessions.first?.lastActivity ?? .distantPast
            let rhsLatest = rhs.sessions.first?.lastActivity ?? .distantPast
            return lhsLatest > rhsLatest
        }
        return result
    }

    var aggregateStatus: SessionStatus {
        let statuses = sessions.values.map(\.status)
        if statuses.contains(.error) { return .error }
        if statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.running) { return .running }
        if statuses.contains(where: { $0 == .completed }) { return .completed }
        return .idle
    }

    var activeCount: Int {
        sessions.values.filter { $0.status == .running || $0.status == .waiting }.count
    }

    func upsert(_ session: Session) {
        let oldStatus = sessions[session.id]?.status
        sessions[session.id] = session
        version &+= 1
        if session.status == .completed && oldStatus != .completed {
            playCompletionSound()
        }
    }

    func update(id: String, transform: (inout Session) -> Void) {
        guard var s = sessions[id] else { return }
        let oldStatus = s.status
        transform(&s)
        sessions[id] = s
        version &+= 1
        if s.status == .completed && oldStatus != .completed {
            playCompletionSound()
        }
    }

    func setStatus(id: String, status: SessionStatus, flashUntil: Date? = nil) {
        guard var s = sessions[id] else { return }
        let oldStatus = s.status
        s.status = status
        if let f = flashUntil { s.completedFlashUntil = f }
        sessions[id] = s
        version &+= 1
        if status == .completed && oldStatus != .completed {
            playCompletionSound()
        }
    }

    func tickIdle(now: Date = Date()) {
        var changed = false
        for (id, var s) in sessions {
            if s.status == .completed, let until = s.completedFlashUntil, now > until {
                s.status = .idle
                s.completedFlashUntil = nil
                sessions[id] = s
                changed = true
                continue
            }
            if s.status == .running {
                let elapsed = now.timeIntervalSince(s.lastEventTimestamp)
                if elapsed > 30 {
                    s.status = .idle
                    sessions[id] = s
                    changed = true
                }
            }
        }
        if changed { version &+= 1 }
    }

    func toggleSound() {
        soundEnabled.toggle()
        UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled")
    }

    private func playCompletionSound() {
        guard soundEnabled else { return }
        NSSound(named: "Glass")?.play()
    }
}

extension SessionStatus {
    var priority: Int {
        switch self {
        case .error: return 0
        case .waiting: return 1
        case .running: return 2
        case .completed: return 3
        case .idle: return 4
        }
    }

    var color: NSColor {
        switch self {
        case .running:   return NSColor.systemGreen
        case .waiting:   return NSColor.systemYellow
        case .error:     return NSColor.systemRed
        case .completed: return NSColor.systemGreen
        case .idle:      return NSColor(white: 0.55, alpha: 1.0)
        }
    }

    var label: String {
        switch self {
        case .running:   return "运行中"
        case .waiting:   return "等待输入"
        case .error:     return "出错"
        case .completed: return "已完成"
        case .idle:      return "空闲"
        }
    }
}
