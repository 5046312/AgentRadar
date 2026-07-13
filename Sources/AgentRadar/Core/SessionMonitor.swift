import Foundation
import CoreServices

@MainActor
final class SessionMonitor {
    private struct InitialScanResult: Sendable {
        let claudeFiles: [URL]
        let codexFiles: [URL]
    }

    private let store: SessionStore
    private var streams: [FSEventStreamRef] = []
    private var idleTimer: Timer?
    private var initialScanTask: Task<Void, Never>?
    private var codexSettlementTask: Task<Void, Never>?
    private var codexThreadNameRefreshTask: Task<Void, Never>?
    private let initialScanFileLimit = 80
    private let initialScanTailBytes: UInt64 = 64 * 1024
    private let eventScanDirectoryLimit = 40
    private let eventScanFileLimit = 20
    private let maxRestoredCodexRunningAge: TimeInterval = 30 * 60
    private var codexThreadNameIndexSignature: String?

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        for runtime in RuntimeKind.allCases {
            let dir = PathUtils.sessionsDir(for: runtime)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            startFSEvents(path: dir.path)
        }
        startInitialScan()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshCodexThreadNames()
                self.refreshIdleStates()
            }
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
        initialScanTask?.cancel()
        initialScanTask = nil
        codexSettlementTask?.cancel()
        codexSettlementTask = nil
        codexThreadNameRefreshTask?.cancel()
        codexThreadNameRefreshTask = nil
    }

    private func refreshIdleStates() {
        let now = Date()
        let candidates = store.codexSettlementCandidates(now: now)
        store.tickIdle(now: now)
        guard codexSettlementTask == nil, !candidates.isEmpty else { return }

        codexSettlementTask = Task { [weak self] in
            let settledTurns = await Task.detached(priority: .utility) { () -> [String: String] in
                Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
                    switch JSONLReader.codexTurnOutcome(
                        at: candidate.fileURL,
                        turnId: candidate.turnId,
                        startedAt: candidate.startedAt
                    ) {
                    case .completed, .interrupted, .failed:
                        return (candidate.sessionId, candidate.turnId)
                    case .pending:
                        return nil
                    }
                })
            }.value

            guard !Task.isCancelled, let self else { return }
            self.store.tickIdle(settledCodexTurns: settledTurns)
            self.codexSettlementTask = nil
        }
    }

    private func startInitialScan() {
        initialScanTask?.cancel()
        let fileLimit = initialScanFileLimit
        initialScanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.makeInitialScanResult(fileLimit: fileLimit)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.codexThreadNameIndexSignature = nil
            self.refreshCodexThreadNames(force: true)

            // 每个文件处理后主动让出主线程，避免恢复历史会话时阻塞菜单栏交互。
            for url in result.claudeFiles {
                guard !Task.isCancelled else { return }
                self.ingestFile(url, runtime: .claude)
                await Task.yield()
            }
            for url in result.codexFiles {
                guard !Task.isCancelled else { return }
                self.ingestFile(url, runtime: .codex, allowCodexCreate: true)
                await Task.yield()
            }
            self.initialScanTask = nil
        }
    }

    nonisolated private static func makeInitialScanResult(fileLimit: Int) -> InitialScanResult {
        InitialScanResult(
            claudeFiles: recentClaudeJSONLFiles(limit: fileLimit),
            codexFiles: recentCodexJSONLFiles(limit: fileLimit)
        )
    }

    nonisolated private static func recentClaudeJSONLFiles(limit: Int) -> [URL] {
        let root = PathUtils.sessionsDir(for: .claude)
        guard let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for projectDir in projects {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in files where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                candidates.append((url, values?.contentModificationDate ?? .distantPast))
            }
        }
        return candidates.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit).map(\.url)
    }

    nonisolated private static func recentCodexJSONLFiles(limit: Int) -> [URL] {
        let root = PathUtils.sessionsDir(for: .codex)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            candidates.append((url, values?.contentModificationDate ?? .distantPast))
        }
        // 完整枚举放后台执行，保留“按文件真实修改时间取最近会话”的原有行为。
        return candidates.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit).map(\.url)
    }

    nonisolated private static func makeCodexThreadNameIndexSignature() -> String? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: PathUtils.codexSessionIndexFile.path),
            let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(modifiedAt.timeIntervalSince1970):\(size)"
    }

    private func ingestFile(_ url: URL, runtime: RuntimeKind, allowCodexCreate: Bool = false) {
        if runtime == .codex {
            refreshCodexThreadNames()
        }
        let rawSessionId = rawSessionId(for: url, runtime: runtime)
        let sessionId = "\(runtime.rawValue):\(rawSessionId)"
        var projectPath = initialProjectPath(for: url, runtime: runtime)
        if runtime == .codex, allowCodexCreate {
            guard let restoredProjectPath = codexInitialProjectPath(for: url) else {
                return
            }
            projectPath = restoredProjectPath
        }
        let projectName = PathUtils.projectNameFromPath(projectPath)

        let existing = store.sessions[sessionId]
        if runtime == .codex, existing == nil, !allowCodexCreate {
            // 运行期仍只信 hook 占位；启动恢复允许最近 transcript 创建旧会话行。
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
            taskName: nil,
            activeStartedAt: nil,
            activeTurnId: nil,
            fileURL: url,
            fileOffset: 0,
            completedFlashUntil: nil,
            lastDuration: nil,
            lastCompletedAt: nil
        )
        session.fileURL = url

        let readResult = readLines(
            from: url,
            existing: existing,
            runtime: runtime,
            readRecentWhenNew: allowCodexCreate
        )
        let lines = readResult.lines
        let newOffset = readResult.newOffset
        session.fileOffset = newOffset
        guard !lines.isEmpty else {
            refreshDerivedStatus(&session, runtime: runtime)
            if existing == nil { store.upsert(session, notify: !allowCodexCreate) }
            return
        }

        for line in lines {
            guard let summary = parseSummary(line, runtime: runtime) else { continue }
            session.lastActivity = max(session.lastActivity, summary.timestamp)
            if runtime == .claude {
                session.lastEventTimestamp = summary.timestamp
            } else if let event = JSONLReader.parseCodexStatusEvent(line) {
                // Codex 完成只等 Stop hook；transcript 只补齐 started / aborted 这类非完成状态。
                applyCodexStatusEvent(event, to: &session, eventTime: summary.timestamp)
            }
            if let cwd = summary.cwd, !cwd.isEmpty {
                session.projectPath = cwd
                session.projectName = PathUtils.projectNameFromPath(cwd)
            }
        }

        // Codex 访问内部 memory 仓库时也会写 hook / transcript；这些不是用户项目，直接忽略。
        guard !PathUtils.isIgnoredProjectPath(session.projectPath) else { return }

        if allowCodexCreate {
            normalizeRestoredCodexSession(&session)
        }
        refreshDerivedStatus(&session, runtime: runtime)

        store.upsert(session, notify: !allowCodexCreate)
    }

    private func codexInitialProjectPath(for url: URL) -> String? {
        let lines = JSONLReader.readInitialLines(from: url, maxBytes: initialScanTailBytes)
        for line in lines {
            guard
                let cwd = JSONLReader.parseCodexSummary(line)?.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
                !cwd.isEmpty,
                cwd != PathUtils.sessionsDir(for: .codex).path,
                !PathUtils.isIgnoredProjectPath(cwd)
            else {
                continue
            }
            // Codex transcript 尾部不一定还有 cwd；启动恢复必须从头部 meta 拿真实项目路径。
            return cwd
        }
        return nil
    }

    private func refreshCodexThreadNames(force: Bool = false) {
        let url = PathUtils.codexSessionIndexFile
        guard let signature = Self.makeCodexThreadNameIndexSignature() else { return }
        guard force || signature != codexThreadNameIndexSignature else { return }

        codexThreadNameIndexSignature = signature
        codexThreadNameRefreshTask?.cancel()
        codexThreadNameRefreshTask = Task { [weak self] in
            let names = await Task.detached(priority: .utility) {
                JSONLReader.readCodexThreadNames(from: url)
            }.value
            guard
                !Task.isCancelled,
                let self,
                self.codexThreadNameIndexSignature == signature
            else {
                return
            }
            // session_index 只负责 Codex 自动标题；任务状态仍由 hook / transcript 事件链维护。
            self.store.updateCodexThreadNames(names)
            self.codexThreadNameRefreshTask = nil
        }
    }

    private func normalizeRestoredCodexSession(_ session: inout Session) {
        // 启动恢复只还原列表；完成时间只记录本次 App 打开后触发的完成事件。
        session.lastCompletedAt = nil
        if session.status == .completed {
            // 启动恢复只还原列表，不重放历史完成闪态，否则打开菜单会短暂铺满旧完成任务。
            session.status = .idle
            session.completedFlashUntil = nil
            return
        }

        guard session.status == .running else { return }
        let age = Date().timeIntervalSince(session.lastEventTimestamp)
        guard age > maxRestoredCodexRunningAge else { return }
        // 启动恢复不靠 task_complete 判完成；旧 running 不能继续按开始时间累计成几十小时。
        session.status = .idle
        session.activeStartedAt = nil
        session.activeTurnId = nil
        session.lastDuration = nil
    }

    private func readLines(from url: URL, existing: Session?, runtime: RuntimeKind, readRecentWhenNew: Bool = false) -> (lines: [Data], newOffset: UInt64) {
        if existing == nil, runtime == .claude || readRecentWhenNew {
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
                session.lastCompletedAt = nil
                if session.completedFlashUntil != nil, now > (session.completedFlashUntil ?? now) {
                    session.completedFlashUntil = nil
                }
            }
            return
        }
        // Codex 完成只信 Stop hook；这里不做 transcript 完成兜底，也不做超时推断。
    }

    private func applyCodexStatusEvent(_ event: CodexTranscriptStatusEvent, to session: inout Session, eventTime: Date) {
        // Stop hook 可能先把任务收掉，随后 FSEvents 才补读到更早的 task_started，不能让旧事件倒灌回 running。
        guard eventTime >= session.lastEventTimestamp else {
            return
        }
        session.lastEventTimestamp = eventTime

        switch event {
        case .started(let turnId):
            // retry 会先把旧 turn 中断，再立刻写入新 task_started；这里必须重置起始时间。
            session.status = .running
            session.activeStartedAt = eventTime
            session.activeTurnId = turnId
            session.lastDuration = nil
            session.lastCompletedAt = nil
            session.completedFlashUntil = nil
        case .interrupted:
            session.status = .idle
            // transcript 旁路不经过 SessionStore.setStatus；取消时也要清掉活动字段，避免旧运行态残留。
            session.activeStartedAt = nil
            session.activeTurnId = nil
            session.lastCompletedAt = nil
            session.completedFlashUntil = nil
        case .failed:
            session.status = .error
            session.activeTurnId = nil
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
