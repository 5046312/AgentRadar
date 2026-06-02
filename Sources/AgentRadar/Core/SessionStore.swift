import Foundation
import AppKit
import UserNotifications

struct ProjectGroup: Identifiable {
    let id: String
    let name: String
    var sessions: [Session]

    var aggregateStatus: SessionStatus {
        let statuses = sessions.map(\.status)
        if statuses.contains(.error) { return .error }
        if statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.running) { return .running }
        if statuses.contains(.completed) { return .completed }
        return .idle
    }

    var visibleTaskSessions: [Session] {
        // 旧 idle 历史继续折叠；本次打开后完成的任务要保留一行，才能显示“上次完成”。
        sessions.filter { $0.status != .idle || $0.lastCompletedAt != nil }
    }

    var shouldShowTaskRows: Bool {
        visibleTaskSessions.count > 1
    }

    func statusLabel(now: Date) -> String {
        if shouldShowTaskRows {
            return "\(visibleTaskSessions.count) 个任务"
        }
        guard aggregateStatus == .running else {
            if aggregateStatus == .idle, let completedAt = latestCompletedAt {
                return idleAfterCompletionLabel(from: completedAt, to: now)
            }
            return aggregateStatus.label
        }
        guard let startedAt = runningStartedAt else {
            return aggregateStatus.label
        }
        return "运行 \(elapsedDurationText(from: startedAt, to: now))"
    }

    private var latestCompletedAt: Date? {
        sessions.compactMap(\.lastCompletedAt).max()
    }

    private var runningStartedAt: Date? {
        // 只有单个未结束任务时才在项目行计时；多个任务会拆到子行各自计时。
        sessions
            .filter { $0.status == .running }
            .compactMap(\.activeStartedAt)
            .min()
    }

}

extension Session {
    func statusLabel(now: Date) -> String {
        if status == .idle, let lastCompletedAt {
            return idleAfterCompletionLabel(from: lastCompletedAt, to: now)
        }
        guard status == .running else {
            return status.label
        }
        guard let startedAt = activeStartedAt else {
            // 起始时间缺失时只展示状态，避免用项目聚合时间冒充单个任务耗时。
            return status.label
        }
        return "运行 \(elapsedDurationText(from: startedAt, to: now))"
    }
}

private func elapsedDurationText(from startedAt: Date, to now: Date) -> String {
    let totalSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return "\(hours)小时\(minutes)分\(seconds)秒"
    }
    if minutes > 0 {
        return "\(minutes)分\(seconds)秒"
    }
    return "\(seconds)秒"
}

private func idleAfterCompletionLabel(from completedAt: Date, to now: Date) -> String {
    "空闲(上次完成\(relativePastText(from: completedAt, to: now)))"
}

private func relativePastText(from date: Date, to now: Date) -> String {
    let totalSeconds = max(0, Int(now.timeIntervalSince(date)))
    if totalSeconds < 60 {
        return "刚刚"
    }
    let minutes = totalSeconds / 60
    if minutes < 60 {
        return "\(minutes)分钟前"
    }
    let hours = minutes / 60
    if hours < 24 {
        return "\(hours)小时前"
    }
    return "\(hours / 24)天前"
}

@MainActor
final class SessionStore: ObservableObject {
    private enum DefaultsKey {
        static let soundEnabled = "soundEnabled"
        static let reminderStyle = "reminderStyle"
        static let nineGridAnimationInterval = "nineGridAnimationInterval"
        static let nineGridIntervalVariationPercent = "nineGridIntervalVariationPercent"
    }

    nonisolated static let minNineGridAnimationInterval: Double = 0.25
    nonisolated static let maxNineGridAnimationInterval: Double = 2.0
    nonisolated static let defaultNineGridAnimationInterval: Double = 1.0
    nonisolated static let minNineGridIntervalVariationPercent: Double = 0
    nonisolated static let maxNineGridIntervalVariationPercent: Double = 100
    nonisolated static let defaultNineGridIntervalVariationPercent: Double = 50

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var version: Int = 0
    @Published private(set) var latestCompletion: CompletionNotice?
    @Published private(set) var latestFailure: FailureNotice?
    @Published private(set) var latestWaiting: WaitingNotice?
    @Published var soundEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.soundEnabled)
    @Published var reminderStyle: ReminderStyle = {
        let rawValue = UserDefaults.standard.string(forKey: DefaultsKey.reminderStyle)
        return ReminderStyle(rawValue: rawValue ?? "") ?? .statusBarBubble
    }()
    @Published var nineGridAnimationInterval: Double = SessionStore.clampedNineGridAnimationInterval(SessionStore.loadDouble(
        forKey: DefaultsKey.nineGridAnimationInterval,
        fallback: SessionStore.defaultNineGridAnimationInterval
    ))
    @Published var nineGridIntervalVariationPercent: Double = SessionStore.clampedNineGridIntervalVariationPercent(SessionStore.loadDouble(
        forKey: DefaultsKey.nineGridIntervalVariationPercent,
        fallback: SessionStore.defaultNineGridIntervalVariationPercent
    ))

    private var trackedSessions: [Session] {
        // `~/.codex/memories` 是代理内部工作目录，不应显示成用户项目，也不应影响状态栏计数。
        sessions.values.filter { !PathUtils.isIgnoredProjectPath($0.projectPath) }
    }

    func projectGroups(runtime: RuntimeKind?) -> [ProjectGroup] {
        var groups: [String: ProjectGroup] = [:]
        for s in trackedSessions {
            if let runtime, s.runtime != runtime { continue }
            if groups[s.projectPath] == nil {
                groups[s.projectPath] = ProjectGroup(id: s.projectPath, name: s.projectName, sessions: [])
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

    func hasCurrentRunCompletion(runtime: RuntimeKind) -> Bool {
        // lastCompletedAt 只在本次 App 运行期间的完成事件里写入；启动恢复不会保留历史完成时间。
        trackedSessions.contains { $0.runtime == runtime && $0.lastCompletedAt != nil }
    }

    func hasSessions(runtime: RuntimeKind) -> Bool {
        return trackedSessions.contains { $0.runtime == runtime }
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

    func upsert(_ session: Session, notify: Bool = true) {
        guard !PathUtils.isIgnoredProjectPath(session.projectPath) else { return }
        let nextSession = session
        let oldStatus = sessions[nextSession.id]?.status
        sessions[nextSession.id] = nextSession
        version &+= 1
        if notify, nextSession.status == .completed && oldStatus != .completed {
            publishCompletion(nextSession)
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
            // 等待权限后回到 running 仍属于同一轮任务，不能重置开始时间，否则完成耗时会变成 0。
            if s.activeStartedAt == nil || oldStatus == .idle || oldStatus == .completed || oldStatus == .error {
                s.activeStartedAt = eventTime
            }
            s.lastDuration = nil
            s.lastCompletedAt = nil
        }
        if (status == .completed || status == .error), oldStatus != status, let startedAt = s.activeStartedAt {
            s.lastDuration = max(0, eventTime.timeIntervalSince(startedAt))
        }
        if status == .completed, oldStatus != .completed {
            s.lastCompletedAt = eventTime
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
        if status == .waiting && oldStatus != .waiting {
            publishWaiting(s)
        }
    }

    func setHookStatus(runtime: RuntimeKind, rawSessionId: String?, status: SessionStatus, eventTime: Date = Date(), cwd: String? = nil, transcriptPath: String? = nil, flashUntil: Date? = nil) {
        // hook 事件可能早于 session 文件落盘；先建占位，后续 JSONL 再补齐详情。
        if let rawSessionId, !rawSessionId.isEmpty {
            let id = "\(runtime.rawValue):\(rawSessionId)"
            if let existing = sessions[id], PathUtils.isIgnoredProjectPath(existing.projectPath) {
                return
            }
            let transcriptURL = transcriptURL(from: transcriptPath)
            if sessions[id] == nil {
                if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                   PathUtils.isIgnoredProjectPath(cwd) {
                    return
                }
                sessions[id] = placeholderSession(id: id, runtime: runtime, cwd: cwd, transcriptURL: transcriptURL, eventTime: eventTime)
            } else if let transcriptURL, var existing = sessions[id], existing.fileURL != transcriptURL {
                // Codex hook 自带 transcript_path；保存它后，FSEvents 漏事件时也能按 running 会话补读文件。
                existing.fileURL = transcriptURL
                if existing.fileOffset == 0 {
                    existing.fileOffset = transcriptOffsetBaseline(for: transcriptURL)
                }
                sessions[id] = existing
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

    private func placeholderSession(id: String, runtime: RuntimeKind, cwd: String?, transcriptURL: URL?, eventTime: Date) -> Session {
        let projectPath = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? PathUtils.sessionsDir(for: runtime).path
        return Session(
            id: id,
            runtime: runtime,
            projectPath: projectPath,
            projectName: PathUtils.projectNameFromPath(projectPath),
            status: .idle,
            lastActivity: eventTime,
            lastEventTimestamp: eventTime,
            activeStartedAt: nil,
            fileURL: transcriptURL ?? PathUtils.sessionsDir(for: runtime),
            fileOffset: transcriptOffsetBaseline(for: transcriptURL),
            completedFlashUntil: nil,
            lastDuration: nil,
            lastCompletedAt: nil
        )
    }

    private func transcriptURL(from path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func transcriptOffsetBaseline(for url: URL?) -> UInt64 {
        guard
            let url,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? UInt64
        else {
            return 0
        }
        // hook 触发前已有的历史 transcript 不需要补读，避免长会话首次处理卡顿。
        return size
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

    func setNineGridAnimationInterval(_ value: Double) {
        let nextValue = SessionStore.clampedNineGridAnimationInterval(value)
        nineGridAnimationInterval = nextValue
        UserDefaults.standard.set(nextValue, forKey: DefaultsKey.nineGridAnimationInterval)
    }

    func setNineGridIntervalVariationPercent(_ value: Double) {
        let nextValue = SessionStore.clampedNineGridIntervalVariationPercent(value)
        nineGridIntervalVariationPercent = nextValue
        UserDefaults.standard.set(nextValue, forKey: DefaultsKey.nineGridIntervalVariationPercent)
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

    private func publishWaiting(_ session: Session) {
        // waiting 来自权限/确认类 hook，只在状态跃迁时提醒，避免同一次确认重复打扰。
        latestWaiting = WaitingNotice(session: session)
    }

    nonisolated private static func loadDouble(forKey key: String, fallback: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.double(forKey: key)
    }

    nonisolated private static func clampedNineGridAnimationInterval(_ value: Double) -> Double {
        min(maxNineGridAnimationInterval, max(minNineGridAnimationInterval, value))
    }

    nonisolated private static func clampedNineGridIntervalVariationPercent(_ value: Double) -> Double {
        min(maxNineGridIntervalVariationPercent, max(minNineGridIntervalVariationPercent, value))
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
