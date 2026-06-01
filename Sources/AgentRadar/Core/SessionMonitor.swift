import Foundation
import CoreServices

@MainActor
final class SessionMonitor {
    private let store: SessionStore
    private var streams: [FSEventStreamRef] = []
    private var idleTimer: Timer?
    private let initialScanFileLimit = 80
    private let initialScanTailBytes: UInt64 = 64 * 1024

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        for runtime in RuntimeKind.allCases {
            let dir = PathUtils.sessionsDir(for: runtime)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            startFSEvents(path: dir.path)
            scanInitial(runtime: runtime)
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
            break
        }
    }

    private func scanClaudeInitial() {
        let dir = PathUtils.sessionsDir(for: .claude)
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        var candidates: [(url: URL, modifiedAt: Date)] = []

        for project in projects {
            let projectDir = dir.appendingPathComponent(project)
            candidates.append(contentsOf: claudeJSONLCandidates(in: projectDir))
        }

        // 启动阶段只恢复最近会话的尾部，避免大量历史 transcript 阻塞菜单栏交互。
        let recentFiles = candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(initialScanFileLimit)

        for candidate in recentFiles {
            ingestFile(candidate.url, runtime: .claude)
        }
    }

    private func claudeJSONLCandidates(in dir: URL) -> [(url: URL, modifiedAt: Date)] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.compactMap { fileName in
            guard fileName.hasSuffix(".jsonl") else { return nil }
            let url = dir.appendingPathComponent(fileName)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
            return (url, modifiedAt)
        }
    }

    private func ingestFile(_ url: URL, runtime: RuntimeKind) {
        let rawSessionId = rawSessionId(for: url, runtime: runtime)
        let sessionId = "\(runtime.rawValue):\(rawSessionId)"
        let projectPath = initialProjectPath(for: url, runtime: runtime)
        let projectName = PathUtils.projectNameFromPath(projectPath)

        let existing = store.sessions[sessionId]
        if runtime == .codex, existing == nil {
            // Codex 状态只信 hook；没有 hook 占位的 JSONL 文件变化不能创建项目。
            return
        }
        var session = existing ?? Session(
            id: sessionId,
            runtime: runtime,
            projectPath: projectPath,
            projectName: projectName,
            status: .idle,
            lastActivity: Date.distantPast,
            lastEventTimestamp: Date.distantPast,
            activeStartedAt: nil,
            activeStartedTokenTotal: nil,
            tpsSampleTokenTotal: nil,
            tpsSampleTimestamp: nil,
            currentTPS: nil,
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

        let readResult = readLines(from: url, existing: existing, runtime: runtime)
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
            if runtime == .claude {
                session.lastEventTimestamp = summary.timestamp
            }
            if let cwd = summary.cwd, !cwd.isEmpty {
                session.projectPath = cwd
                session.projectName = PathUtils.projectNameFromPath(cwd)
            }
            applyTokenSummary(summary, to: &session)
        }

        // Codex 访问内部 memory 仓库时也会写 hook / transcript；这些不是用户项目，直接忽略。
        guard !PathUtils.isIgnoredProjectPath(session.projectPath) else { return }

        refreshDerivedStatus(&session, runtime: runtime)

        store.upsert(session)
    }

    private func readLines(from url: URL, existing: Session?, runtime: RuntimeKind) -> (lines: [Data], newOffset: UInt64) {
        if runtime == .claude, existing == nil {
            return JSONLReader.readRecentLines(from: url, maxBytes: initialScanTailBytes)
        }
        let startOffset = existing?.fileOffset ?? 0
        return JSONLReader.readNewLines(from: url, startingAt: startOffset)
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
        let previousTotal = totalTokens(for: session)
        if let totalTokens = summary.totalTokens {
            session.inputTokens = summary.inputTokens
            session.outputTokens = summary.outputTokens
            session.cacheReadTokens = summary.cacheReadTokens
            session.lastTokenTotal = totalTokens
            updateCurrentTPS(previousTotal: previousTotal, currentTotal: totalTokens, timestamp: summary.timestamp, session: &session)
            return
        }
        guard summary.inputTokens > 0 || summary.outputTokens > 0 || summary.cacheReadTokens > 0 else {
            return
        }

        session.inputTokens += summary.inputTokens
        session.outputTokens += summary.outputTokens
        session.cacheReadTokens += summary.cacheReadTokens
        session.lastTokenTotal = session.inputTokens + session.outputTokens + session.cacheReadTokens
        updateCurrentTPS(previousTotal: previousTotal, currentTotal: session.lastTokenTotal, timestamp: summary.timestamp, session: &session)
    }

    private func updateCurrentTPS(previousTotal: Int, currentTotal: Int, timestamp: Date, session: inout Session) {
        guard currentTotal > previousTotal else { return }

        guard
            let previousSampleTotal = session.tpsSampleTokenTotal,
            let previousSampleTimestamp = session.tpsSampleTimestamp
        else {
            session.tpsSampleTokenTotal = currentTotal
            session.tpsSampleTimestamp = timestamp
            return
        }

        let elapsed = timestamp.timeIntervalSince(previousSampleTimestamp)
        guard elapsed > 0 else {
            session.tpsSampleTokenTotal = currentTotal
            session.tpsSampleTimestamp = timestamp
            return
        }

        // 运行中 TPS 只在 token 计数真实变化时刷新，避免“没有新 token 但时间增加”造成假低速。
        session.currentTPS = Double(currentTotal - previousSampleTotal) / elapsed
        session.tpsSampleTokenTotal = currentTotal
        session.tpsSampleTimestamp = timestamp
    }

    private func totalTokens(for session: Session) -> Int {
        max(
            session.lastTokenTotal,
            session.inputTokens + session.outputTokens + session.cacheReadTokens
        )
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
            ingestFile(url, runtime: runtime)
        }
    }

    private func runtime(for url: URL) -> RuntimeKind? {
        let path = url.path
        if path.hasPrefix(PathUtils.sessionsDir(for: .claude).path) { return .claude }
        if path.hasPrefix(PathUtils.sessionsDir(for: .codex).path) { return .codex }
        return nil
    }
}
