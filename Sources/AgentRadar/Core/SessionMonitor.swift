import Foundation
import CoreServices

@MainActor
final class SessionMonitor {
    private let store: SessionStore
    private var streams: [FSEventStreamRef] = []
    private var idleTimer: Timer?

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        for runtime in RuntimeKind.allCases {
            let dir = PathUtils.sessionsDir(for: runtime)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            scanInitial(runtime: runtime)
            startFSEvents(path: dir.path)
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.tickIdle() }
        }
    }

    func stop() {
        for s in streams {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        streams.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func scanInitial(runtime: RuntimeKind) {
        switch runtime {
        case .claude:
            scanClaudeInitial()
        case .codex:
            scanCodexInitial()
        }
    }

    private func scanClaudeInitial() {
        let dir = PathUtils.sessionsDir(for: .claude)
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for project in projects {
            let projectDir = dir.appendingPathComponent(project)
            scanClaudeProjectDir(projectDir)
        }
    }

    private func scanClaudeProjectDir(_ dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where f.hasSuffix(".jsonl") {
            let url = dir.appendingPathComponent(f)
            ingestFile(url, runtime: .claude, fullScan: true)
        }
    }

    private func scanCodexInitial() {
        let dir = PathUtils.sessionsDir(for: .codex)
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            ingestFile(url, runtime: .codex, fullScan: true)
        }
    }

    private func ingestFile(_ url: URL, runtime: RuntimeKind, fullScan: Bool) {
        let rawSessionId = rawSessionId(for: url, runtime: runtime)
        let sessionId = "\(runtime.rawValue):\(rawSessionId)"
        let projectPath = initialProjectPath(for: url, runtime: runtime)
        let projectName = PathUtils.projectNameFromPath(projectPath)

        let existing = store.sessions[sessionId]
        var session = existing ?? Session(
            id: sessionId,
            runtime: runtime,
            projectPath: projectPath,
            projectName: projectName,
            gitBranch: nil,
            status: .idle,
            lastActivity: Date.distantPast,
            lastEventTimestamp: Date.distantPast,
            activeStartedAt: nil,
            currentTool: nil,
            taskTitle: nil,
            lastAssistantText: nil,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            lastTokenTotal: 0,
            fileURL: url,
            fileOffset: 0,
            completedFlashUntil: nil,
            lastDuration: nil
        )
        session.fileURL = url

        let startOffset = fullScan ? 0 : session.fileOffset
        let readResult = runtime == .codex && fullScan
            ? JSONLReader.readTailLines(from: url, maxLines: 16)
            : JSONLReader.readNewLines(from: url, startingAt: startOffset)
        let lines = readResult.lines
        let newOffset = readResult.newOffset
        session.fileOffset = newOffset

        guard !lines.isEmpty else {
            refreshDerivedStatus(&session, runtime: runtime)
            if existing == nil { store.upsert(session) }
            return
        }

        for line in lines {
            guard let summary = parseSummary(line, runtime: runtime) else { continue }
            session.lastActivity = max(session.lastActivity, summary.timestamp)
            if runtime == .claude || session.status == .idle {
                session.lastEventTimestamp = summary.timestamp
            }
            if let cwd = summary.cwd, !cwd.isEmpty {
                session.projectPath = cwd
                session.projectName = PathUtils.projectNameFromPath(cwd)
            }
            if let b = summary.gitBranch { session.gitBranch = b }
            if let tool = summary.toolName { session.currentTool = tool }
            if let txt = summary.userText, !txt.isEmpty {
                session.taskTitle = String(txt.prefix(120))
            }
            if let txt = summary.assistantText, !txt.isEmpty {
                session.lastAssistantText = String(txt.prefix(200))
            }
            applyTokenSummary(summary, to: &session)
        }

        refreshDerivedStatus(&session, runtime: runtime)

        store.upsert(session)
    }

    private func rawSessionId(for url: URL, runtime: RuntimeKind) -> String {
        let fileName = (url.lastPathComponent as NSString).deletingPathExtension
        guard runtime == .codex else { return fileName }
        let suffix = String(fileName.suffix(36))
        // Codex hook 上报的是 session UUID；rollout 文件名后缀同一 UUID，需对齐才能精准更新。
        return UUID(uuidString: suffix) == nil ? fileName : suffix
    }

    private func initialProjectPath(for url: URL, runtime: RuntimeKind) -> String {
        switch runtime {
        case .claude:
            let projectDirName = url.deletingLastPathComponent().lastPathComponent
            return PathUtils.decodeProjectDir(projectDirName)
        case .codex:
            return PathUtils.sessionsDir(for: .codex).path
        }
    }

    private func parseSummary(_ data: Data, runtime: RuntimeKind) -> JSONLEntrySummary? {
        switch runtime {
        case .claude:
            return JSONLReader.parseSummary(data)
        case .codex:
            return JSONLReader.parseCodexSummary(data)
        }
    }

    private func applyTokenSummary(_ summary: JSONLEntrySummary, to session: inout Session) {
        if let totalTokens = summary.totalTokens {
            session.inputTokens = summary.inputTokens
            session.outputTokens = summary.outputTokens
            session.cacheReadTokens = summary.cacheReadTokens
            session.lastTokenTotal = totalTokens
            return
        }
        guard summary.inputTokens > 0 || summary.outputTokens > 0 || summary.cacheReadTokens > 0 else {
            return
        }

        session.inputTokens += summary.inputTokens
        session.outputTokens += summary.outputTokens
        session.cacheReadTokens += summary.cacheReadTokens
        session.lastTokenTotal = session.inputTokens + session.outputTokens + session.cacheReadTokens
    }

    private func refreshDerivedStatus(_ session: inout Session, runtime: RuntimeKind) {
        let now = Date()
        if runtime == .claude {
            if session.status == .completed, let until = session.completedFlashUntil, now <= until {
                return
            }
            // 启动恢复只保留 Claude 近期状态，避免旧会话误亮。
            if now.timeIntervalSince(session.lastEventTimestamp) > 30 {
                session.status = .idle
                if session.completedFlashUntil != nil, now > (session.completedFlashUntil ?? now) {
                    session.completedFlashUntil = nil
                }
            }
            return
        }
        // Codex 状态由 hooks 写入，session JSONL 只更新展示信息。
    }

    private func startFSEvents(path: String) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info = info else { return }
            let monitor = Unmanaged<SessionMonitor>.fromOpaque(info).takeUnretainedValue()
            let pathsPtr = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var changed: [String] = []
            for i in 0..<count {
                changed.append(String(cString: pathsPtr[i]))
            }
            Task { @MainActor in monitor.handleFSEvents(changed) }
        }
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
            streams.append(stream)
        }
    }

    private func handleFSEvents(_ paths: [String]) {
        for p in paths where p.hasSuffix(".jsonl") {
            let url = URL(fileURLWithPath: p)
            guard let runtime = runtime(for: url) else { continue }
            ingestFile(url, runtime: runtime, fullScan: false)
        }
    }

    private func runtime(for url: URL) -> RuntimeKind? {
        let path = url.path
        if path.hasPrefix(PathUtils.sessionsDir(for: .claude).path) { return .claude }
        if path.hasPrefix(PathUtils.sessionsDir(for: .codex).path) { return .codex }
        return nil
    }
}
