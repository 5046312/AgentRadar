import Foundation

@MainActor
final class HookEventReader {
    private let store: SessionStore
    private let url: URL
    private var fileOffset: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pollTimer: Timer?

    init(store: SessionStore) {
        self.store = store
        self.url = PathUtils.hookEventsFile
    }

    func start() {
        try? HookEventStorage.prepare()
        // App 启动时先清理超限旧事件，避免没有新 hook 时大文件一直残留。
        try? HookEventStorage.truncateIfNeeded(at: url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            fileOffset = size
        }
        attachWatcher()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.source == nil {
                    try? HookEventStorage.prepare()
                    self.attachWatcher()
                }
                self.drain()
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func attachWatcher() {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.main
        )
        s.setEventHandler { [weak self] in
            guard let self = self else { return }
            let mask = s.data
            if mask.contains(.delete) || mask.contains(.rename) {
                self.source?.cancel()
                if self.fd >= 0 { close(self.fd); self.fd = -1 }
                self.fileOffset = 0
                try? HookEventStorage.prepare()
                self.attachWatcher()
                return
            }
            self.drain()
        }
        s.resume()
        source = s
    }

    private func drain() {
        guard let fileSize = currentFileSize() else { return }
        if fileSize < fileOffset {
            fileOffset = 0
        }
        guard fileSize > fileOffset else { return }

        let (lines, newOffset) = JSONLReader.readNewLines(from: url, startingAt: fileOffset)
        fileOffset = newOffset
        for line in lines {
            guard let event = try? JSONDecoder().decode(HookEvent.self, from: line) else { continue }
            apply(event)
        }
    }

    private func currentFileSize() -> UInt64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.size] as? UInt64
    }

    private func apply(_ event: HookEvent) {
        let runtime = event.runtime ?? .claude
        if shouldIgnore(event, runtime: runtime) {
            return
        }
        let eventTime = Date(timeIntervalSince1970: event.ts)
        switch event.event {
        case "Stop", "SubagentStop":
            if runtime == .codex {
                guard shouldHandleCodexStop(event, runtime: runtime) else { return }
                applyCodexStop(event, runtime: runtime, eventTime: eventTime)
            } else {
                applyStatus(.completed, event: event, runtime: runtime, eventTime: eventTime, flashUntil: Date().addingTimeInterval(3))
            }
        case "Notification":
            applyStatus(.waiting, event: event, runtime: runtime, eventTime: eventTime)
        case "PermissionRequest":
            if shouldKeepCodexRunningForAutoReview(event, runtime: runtime) {
                applyStatus(.running, event: event, runtime: runtime, eventTime: eventTime)
                break
            }
            applyStatus(.waiting, event: event, runtime: runtime, eventTime: eventTime)
        case "SessionStart":
            if runtime == .codex {
                // Codex 的 SessionStart 只是会话进程启动，不代表用户已提交任务；
                // 这里若直接切 running，就会出现“凭空多出一个运行中任务”。
                break
            }
            applyStatus(.running, event: event, runtime: runtime, eventTime: eventTime)
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            applyStatus(.running, event: event, runtime: runtime, eventTime: eventTime)
        default:
            break
        }
    }

    private func shouldIgnore(_ event: HookEvent, runtime: RuntimeKind) -> Bool {
        guard runtime == .codex else {
            return false
        }

        if let cwd = event.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), cwd == "/" {
            // Codex 会起一些根目录下的内部分类任务，例如 exclude；它们不对应真实项目。
            return true
        }

        // 真实 Codex 会话会带 transcript_path；没有 transcript 的通常是 suggestions/exclude/memory 之类后台任务。
        return (event.transcript_path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func shouldHandleCodexStop(_ event: HookEvent, runtime: RuntimeKind) -> Bool {
        guard runtime == .codex else {
            return true
        }
        guard let session = hookSession(for: event, runtime: runtime), session.status == .running || session.status == .waiting else {
            return false
        }
        guard let activeTurnId = session.activeTurnId, let stopTurnId = event.turn_id else {
            // 旧 hook 载荷或 waiting 首事件可能没有 active turn，只能按当前状态兜底。
            return true
        }
        // 关闭 VSCode/Codex 可能会补发旧 turn 的 Stop；只处理当前活动 turn。
        return activeTurnId == stopTurnId
    }

    private func hookSession(for event: HookEvent, runtime: RuntimeKind) -> Session? {
        guard let rawSessionId = rawSessionId(for: event, runtime: runtime) else {
            return nil
        }
        return store.sessions["\(runtime.rawValue):\(rawSessionId)"]
    }

    private func shouldKeepCodexRunningForAutoReview(_ event: HookEvent, runtime: RuntimeKind) -> Bool {
        guard runtime == .codex else {
            return false
        }

        if event.approvals_reviewer?.trimmingCharacters(in: .whitespacesAndNewlines) == "auto_review" {
            return true
        }

        guard
            let transcriptPath = event.transcript_path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !transcriptPath.isEmpty
        else {
            return false
        }

        // Codex 自动审查会自己处理权限请求；继续显示“需要用户确认”会误导用户。
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        return JSONLReader.codexApprovalsReviewerIsAutoReview(at: transcriptURL)
    }

    private func applyCodexStop(_ event: HookEvent, runtime: RuntimeKind, eventTime: Date) {
        guard
            let transcriptPath = event.transcript_path,
            !transcriptPath.isEmpty,
            let turnId = event.turn_id,
            !turnId.isEmpty
        else {
            // 老版本 Stop 载荷没有 transcript/turn_id 时，只能退回旧行为，避免误报失败。
            applyStatus(.completed, event: event, runtime: runtime, eventTime: eventTime, flashUntil: Date().addingTimeInterval(3))
            return
        }

        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        let startedAt = hookSession(for: event, runtime: runtime)?.activeStartedAt
        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<6 {
                let outcome = await Task.detached(priority: .utility) {
                    JSONLReader.codexTurnOutcome(at: transcriptURL, turnId: turnId, startedAt: startedAt)
                }.value
                switch outcome {
                case .completed:
                    self.applyCodexStopStatus(.completed, event: event, runtime: runtime, eventTime: eventTime, flashUntil: Date().addingTimeInterval(3))
                    return
                case .interrupted:
                    self.applyCodexStopStatus(.idle, event: event, runtime: runtime, eventTime: eventTime)
                    return
                case .failed:
                    self.applyCodexStopStatus(.error, event: event, runtime: runtime, eventTime: eventTime)
                    return
                case .pending:
                    // Stop hook 可能比 transcript 最后一条 task_complete 更早落盘，短等几轮再判失败。
                    if attempt < 5 {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            }
            self.applyCodexStopStatus(.error, event: event, runtime: runtime, eventTime: eventTime)
        }
    }

    private func applyCodexStopStatus(_ status: SessionStatus, event: HookEvent, runtime: RuntimeKind, eventTime: Date, flashUntil: Date? = nil) {
        // Stop 需要等 transcript 补齐结果；等待期间可能已经进入新 turn，应用前必须再核一次。
        guard shouldHandleCodexStop(event, runtime: runtime) else { return }
        applyStatus(status, event: event, runtime: runtime, eventTime: eventTime, flashUntil: flashUntil)
    }

    private func applyStatus(_ status: SessionStatus, event: HookEvent, runtime: RuntimeKind, eventTime: Date, flashUntil: Date? = nil) {
        store.setHookStatus(
            runtime: runtime,
            rawSessionId: rawSessionId(for: event, runtime: runtime),
            status: status,
            eventTime: eventTime,
            cwd: event.cwd,
            transcriptPath: event.transcript_path,
            turnId: event.turn_id,
            flashUntil: flashUntil
        )
    }

    private func rawSessionId(for event: HookEvent, runtime: RuntimeKind) -> String? {
        if let sessionId = event.session_id?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionId.isEmpty {
            return sessionId
        }

        guard
            runtime == .codex,
            let transcriptPath = event.transcript_path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !transcriptPath.isEmpty
        else {
            return nil
        }

        let fileName = (URL(fileURLWithPath: transcriptPath).lastPathComponent as NSString).deletingPathExtension
        let suffix = String(fileName.suffix(36))
        // Codex hook 有时只带 transcript_path；取 rollout 文件名末尾 UUID，才能在回车后立即命中同一会话。
        return UUID(uuidString: suffix) == nil ? fileName : suffix
    }
}
