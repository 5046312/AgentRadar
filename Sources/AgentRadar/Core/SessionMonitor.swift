import Foundation
import CoreServices

@MainActor
final class SessionMonitor {
    private let store: SessionStore
    private var streams: [FSEventStreamRef] = []
    private var idleTimer: Timer?
    private let initialScanFileLimit = 80
    private let initialScanTailBytes: UInt64 = 64 * 1024
    private let eventScanDirectoryLimit = 40
    private let eventScanFileLimit = 20

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
            } else if let event = JSONLReader.parseCodexStatusEvent(line) {
                // Codex interrupted 场景不一定会发 Stop hook；这里用 transcript 增量把状态补齐。
                applyCodexStatusEvent(event, to: &session, eventTime: summary.timestamp)
            }
            if let cwd = summary.cwd, !cwd.isEmpty {
                session.projectPath = cwd
                session.projectName = PathUtils.projectNameFromPath(cwd)
            }
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
        // Codex 仍以 hooks 为主；这里只保留 transcript 兜底，不再额外做超时推断。
    }

    private func applyCodexStatusEvent(_ event: CodexTranscriptStatusEvent, to session: inout Session, eventTime: Date) {
        session.lastEventTimestamp = eventTime

        switch event {
        case .started:
            // retry 会先把旧 turn 中断，再立刻写入新 task_started；这里必须重置起始时间。
            session.status = .running
            session.activeStartedAt = eventTime
            session.lastDuration = nil
            session.completedFlashUntil = nil
        case .completed:
            session.status = .completed
            if let startedAt = session.activeStartedAt {
                session.lastDuration = max(0, eventTime.timeIntervalSince(startedAt))
            }
            session.completedFlashUntil = Date().addingTimeInterval(3)
        case .interrupted:
            session.status = .idle
            session.completedFlashUntil = nil
        case .failed:
            session.status = .error
            if let startedAt = session.activeStartedAt {
                session.lastDuration = max(0, eventTime.timeIntervalSince(startedAt))
            }
            session.completedFlashUntil = nil
        }
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
            0.2,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
            streams.append(stream)
        }
    }

    private func handleFSEvents(_ paths: [String]) {
        var ingestedPaths = Set<String>()
        for path in paths {
            let changedURL = URL(fileURLWithPath: path)
            let changedRuntime = runtime(for: changedURL)
            let urls = changedRuntime == .codex && changedURL.pathExtension != "jsonl"
                ? activeSessionJSONLFiles(under: changedURL, runtime: .codex)
                : jsonlURLsForChangedPath(changedURL)

            for url in urls {
                guard ingestedPaths.insert(url.path).inserted else { continue }
                guard let runtime = runtime(for: url) else { continue }
                ingestFile(url, runtime: runtime)
            }
        }
    }

    private func activeSessionJSONLFiles(under rootURL: URL, runtime: RuntimeKind) -> [URL] {
        let rootPath = rootURL.path
        return store.sessions.values.compactMap { session in
            guard session.runtime == runtime, session.status == .running, session.fileURL.pathExtension == "jsonl" else {
                return nil
            }
            let filePath = session.fileURL.path
            guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
                return nil
            }
            // Codex hook 已带 transcript_path；目录事件只补读已知运行中会话，避免扫整棵 sessions 历史目录。
            return session.fileURL
        }
    }

    private func jsonlURLsForChangedPath(_ url: URL) -> [URL] {
        if url.pathExtension == "jsonl" {
            return [url]
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        return recentJSONLFiles(under: url)
    }

    private func recentJSONLFiles(under rootURL: URL) -> [URL] {
        var queue = [rootURL]
        var scannedDirectoryCount = 0
        var candidates: [(url: URL, modifiedAt: Date)] = []

        while !queue.isEmpty, scannedDirectoryCount < eventScanDirectoryLimit, candidates.count < eventScanFileLimit {
            let currentURL = queue.removeFirst()
            scannedDirectoryCount += 1

            guard let children = try? FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            var childDirectories: [(url: URL, modifiedAt: Date)] = []
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                if values?.isDirectory == true {
                    childDirectories.append((child, modifiedAt))
                } else if child.pathExtension == "jsonl" {
                    candidates.append((child, modifiedAt))
                }
            }

            // FSEvents 有时只给父目录；优先扫最近变动目录，避免 sessions 历史很多时误扫太深。
            queue.append(contentsOf: childDirectories.sorted { $0.modifiedAt > $1.modifiedAt }.map { $0.url })
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(eventScanFileLimit)
            .map { $0.url }
    }

    private func runtime(for url: URL) -> RuntimeKind? {
        let path = url.path
        if path.hasPrefix(PathUtils.sessionsDir(for: .claude).path) { return .claude }
        if path.hasPrefix(PathUtils.sessionsDir(for: .codex).path) { return .codex }
        return nil
    }
}
