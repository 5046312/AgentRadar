import Foundation
import CoreServices

@MainActor
final class SessionMonitor {
    private let store: SessionStore
    private var stream: FSEventStreamRef?
    private var idleTimer: Timer?

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        let dir = PathUtils.claudeProjectsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scanInitial()
        startFSEvents(path: dir.path)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.tickIdle() }
        }
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func scanInitial() {
        let dir = PathUtils.claudeProjectsDir
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for project in projects {
            let projectDir = dir.appendingPathComponent(project)
            scanProjectDir(projectDir)
        }
    }

    private func scanProjectDir(_ dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where f.hasSuffix(".jsonl") {
            let url = dir.appendingPathComponent(f)
            ingestFile(url, fullScan: true)
        }
    }

    private func ingestFile(_ url: URL, fullScan: Bool) {
        let sessionId = (url.lastPathComponent as NSString).deletingPathExtension
        let projectDirName = url.deletingLastPathComponent().lastPathComponent
        let projectPath = PathUtils.decodeProjectDir(projectDirName)
        let projectName = PathUtils.projectNameFromPath(projectPath)

        let existing = store.sessions[sessionId]
        var session = existing ?? Session(
            id: sessionId,
            projectPath: projectPath,
            projectName: projectName,
            gitBranch: nil,
            status: .idle,
            lastActivity: Date.distantPast,
            lastEventTimestamp: Date.distantPast,
            currentTool: nil,
            lastAssistantText: nil,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            fileURL: url,
            fileOffset: 0,
            completedFlashUntil: nil
        )

        let startOffset = fullScan ? 0 : session.fileOffset
        let (lines, newOffset) = JSONLReader.readNewLines(from: url, startingAt: startOffset)
        session.fileOffset = newOffset

        guard !lines.isEmpty else {
            if existing == nil { store.upsert(session) }
            return
        }

        var lastSummary: JSONLEntrySummary?
        for line in lines {
            guard let summary = JSONLReader.parseSummary(line) else { continue }
            lastSummary = summary
            session.lastEventTimestamp = summary.timestamp
            session.lastActivity = max(session.lastActivity, summary.timestamp)
            if let b = summary.gitBranch { session.gitBranch = b }
            if let tool = summary.toolName { session.currentTool = tool }
            if let txt = summary.assistantText, !txt.isEmpty {
                session.lastAssistantText = String(txt.prefix(200))
            }
            session.inputTokens += summary.inputTokens
            session.outputTokens += summary.outputTokens
            session.cacheReadTokens += summary.cacheReadTokens
        }

        let elapsed = Date().timeIntervalSince(session.lastEventTimestamp)

        if fullScan {
            if let last = lastSummary {
                // 有 stopReason 说明回合结束，5秒内算刚完成，否则已闲置
                if last.stopReason != nil {
                    session.status = elapsed < 5 ? .completed : .idle
                } else if elapsed <= 15 {
                    session.status = .running
                } else {
                    session.status = .idle
                }
            } else {
                session.status = .idle
            }
        } else {
            if let last = lastSummary {
                // 新事件：有 stopReason 就触发完成闪烁（包括 tool_use 结束的情况）
                if last.stopReason != nil {
                    session.status = .completed
                    session.completedFlashUntil = Date().addingTimeInterval(3)
                } else if elapsed <= 30 {
                    session.status = .running
                } else {
                    session.status = .idle
                }
            }
        }

        store.upsert(session)
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
            self.stream = stream
        }
    }

    private func handleFSEvents(_ paths: [String]) {
        for p in paths where p.hasSuffix(".jsonl") {
            let url = URL(fileURLWithPath: p)
            ingestFile(url, fullScan: false)
        }
    }
}
