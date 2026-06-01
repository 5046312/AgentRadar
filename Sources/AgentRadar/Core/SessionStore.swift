import Foundation
import AppKit
import UserNotifications

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
    private enum DefaultsKey {
        static let soundEnabled = "soundEnabled"
        static let reminderStyle = "reminderStyle"
        static let statusBarStyle = "statusBarStyle"
    }

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var version: Int = 0
    @Published private(set) var latestCompletion: CompletionNotice?
    @Published private(set) var latestFailure: FailureNotice?
    @Published var soundEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.soundEnabled)
    @Published var reminderStyle: ReminderStyle = {
        let rawValue = UserDefaults.standard.string(forKey: DefaultsKey.reminderStyle)
        return ReminderStyle(rawValue: rawValue ?? "") ?? .statusBarBubble
    }()
    @Published var statusBarStyle: StatusBarStyle = {
        let rawValue = UserDefaults.standard.string(forKey: DefaultsKey.statusBarStyle)
        return StatusBarStyle(rawValue: rawValue ?? "") ?? .defaultDot
    }()

    private var trackedSessions: [Session] {
        // `~/.codex/memories` 是代理内部工作目录，不应显示成用户项目，也不应影响状态栏计数。
        sessions.values.filter { !PathUtils.isIgnoredProjectPath($0.projectPath) }
    }

    var sortedSessions: [Session] {
        trackedSessions.sorted { lhs, rhs in
            if lhs.status.priority != rhs.status.priority {
                return lhs.status.priority < rhs.status.priority
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    var projectGroups: [ProjectGroup] {
        projectGroups(runtime: nil)
    }

    func projectGroups(runtime: RuntimeKind?) -> [ProjectGroup] {
        var groups: [String: ProjectGroup] = [:]
        for s in trackedSessions {
            if let runtime, s.runtime != runtime { continue }
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

    func count(_ status: SessionStatus, runtime: RuntimeKind) -> Int {
        trackedSessions.filter { $0.runtime == runtime && $0.status == status }.count
    }

    func hasSessions(runtime: RuntimeKind) -> Bool {
        trackedSessions.contains { $0.runtime == runtime }
    }

    var aggregateStatus: SessionStatus {
        let statuses = trackedSessions.map(\.status)
        if statuses.contains(.error) { return .error }
        if statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.running) { return .running }
        if statuses.contains(where: { $0 == .completed }) { return .completed }
        return .idle
    }

    var activeCount: Int {
        // 状态栏按钮只展示真正执行中的任务数，等待输入不算正在执行。
        trackedSessions.filter { $0.status == .running }.count
    }

    func upsert(_ session: Session) {
        guard !PathUtils.isIgnoredProjectPath(session.projectPath) else { return }
        let oldStatus = sessions[session.id]?.status
        sessions[session.id] = session
        version &+= 1
        if session.status == .completed && oldStatus != .completed {
            publishCompletion(session)
        }
    }

    func update(id: String, transform: (inout Session) -> Void) {
        guard var s = sessions[id] else { return }
        guard !PathUtils.isIgnoredProjectPath(s.projectPath) else { return }
        let oldStatus = s.status
        transform(&s)
        sessions[id] = s
        version &+= 1
        if s.status == .completed && oldStatus != .completed {
            publishCompletion(s)
        }
        if s.status == .error && oldStatus != .error {
            publishFailure(s)
        }
    }

    func setStatus(id: String, status: SessionStatus, eventTime: Date = Date(), flashUntil: Date? = nil) {
        guard var s = sessions[id] else { return }
        guard !PathUtils.isIgnoredProjectPath(s.projectPath) else { return }
        let oldStatus = s.status
        s.status = status
        s.lastEventTimestamp = eventTime
        s.lastActivity = max(s.lastActivity, eventTime)
        if status == .running, oldStatus != .running {
            s.activeStartedAt = eventTime
            s.lastDuration = nil
        }
        if (status == .completed || status == .error), oldStatus != status, let startedAt = s.activeStartedAt {
            s.lastDuration = max(0, eventTime.timeIntervalSince(startedAt))
        }
        if let f = flashUntil { s.completedFlashUntil = f }
        sessions[id] = s
        version &+= 1
        if status == .completed && oldStatus != .completed {
            publishCompletion(s)
        }
        if status == .error && oldStatus != .error {
            publishFailure(s)
        }
    }

    func setHookStatus(runtime: RuntimeKind, rawSessionId: String?, status: SessionStatus, eventTime: Date = Date(), cwd: String? = nil, flashUntil: Date? = nil) {
        // hook 事件可能早于 session 文件落盘；先建占位，后续 JSONL 再补齐详情。
        if let rawSessionId, !rawSessionId.isEmpty {
            let id = "\(runtime.rawValue):\(rawSessionId)"
            if let existing = sessions[id], PathUtils.isIgnoredProjectPath(existing.projectPath) {
                return
            }
            if sessions[id] == nil {
                if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                   PathUtils.isIgnoredProjectPath(cwd) {
                    return
                }
                sessions[id] = placeholderSession(id: id, runtime: runtime, cwd: cwd, eventTime: eventTime)
            }
            setStatus(id: id, status: status, eventTime: eventTime, flashUntil: flashUntil)
            return
        }
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
           PathUtils.isIgnoredProjectPath(cwd) {
            return
        }
        setRuntimeStatus(runtime: runtime, status: status, eventTime: eventTime, cwd: cwd, flashUntil: flashUntil)
    }

    func setRuntimeStatus(runtime: RuntimeKind, status: SessionStatus, eventTime: Date = Date(), cwd: String? = nil, flashUntil: Date? = nil) {
        // Codex hook 可能只带 cwd，不带 session_id；用 cwd 缩小范围后取最近活跃会话。
        let candidates = trackedSessions.filter { session in
            guard session.runtime == runtime else { return false }
            guard let cwd, !cwd.isEmpty else { return true }
            return session.projectPath == cwd
        }
        guard let target = candidates.sorted(by: { lhs, rhs in
            lhs.lastActivity > rhs.lastActivity
        }).first else {
            return
        }
        setStatus(id: target.id, status: status, eventTime: eventTime, flashUntil: flashUntil)
    }

    private func placeholderSession(id: String, runtime: RuntimeKind, cwd: String?, eventTime: Date) -> Session {
        let projectPath = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? PathUtils.sessionsDir(for: runtime).path
        return Session(
            id: id,
            runtime: runtime,
            projectPath: projectPath,
            projectName: PathUtils.projectNameFromPath(projectPath),
            gitBranch: nil,
            status: .idle,
            lastActivity: eventTime,
            lastEventTimestamp: eventTime,
            activeStartedAt: nil,
            currentTool: nil,
            taskTitle: nil,
            lastAssistantText: nil,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            lastTokenTotal: 0,
            fileURL: PathUtils.sessionsDir(for: runtime),
            fileOffset: 0,
            completedFlashUntil: nil,
            lastDuration: nil
        )
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
            if s.status == .running, s.runtime == .claude {
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
        UserDefaults.standard.set(soundEnabled, forKey: DefaultsKey.soundEnabled)
    }

    func setReminderStyle(_ style: ReminderStyle) {
        reminderStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: DefaultsKey.reminderStyle)
    }

    func setStatusBarStyle(_ style: StatusBarStyle) {
        statusBarStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: DefaultsKey.statusBarStyle)
    }

    func requestSystemNotificationAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await loadNotificationSettings(center)
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            // 只在用户主动切到系统消息时申请权限，避免首次启动就打断。
            return await requestNotificationAuthorization(center)
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func canDeliverSystemNotification() async -> Bool {
        let settings = await loadNotificationSettings(UNUserNotificationCenter.current())
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func playCompletionSound() {
        guard soundEnabled else { return }
        NSSound(named: "Glass")?.play()
    }

    private func loadNotificationSettings(_ center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func requestNotificationAuthorization(_ center: UNUserNotificationCenter) async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func publishCompletion(_ session: Session) {
        // 完成提示和音效共用同一次状态跃迁，避免 JSONL 补写内容时重复弹出。
        latestCompletion = CompletionNotice(session: session)
        playCompletionSound()
    }

    private func publishFailure(_ session: Session) {
        // 失败提示只跟着 error 跃迁走，避免 Stop 与后续展示字段补写重复提醒。
        latestFailure = FailureNotice(session: session)
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

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
