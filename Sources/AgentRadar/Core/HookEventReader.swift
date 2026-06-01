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
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            fileOffset = size
        }
        attachWatcher()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
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
                self.attachWatcher()
                return
            }
            self.drain()
        }
        s.resume()
        source = s
    }

    private func drain() {
        let (lines, newOffset) = JSONLReader.readNewLines(from: url, startingAt: fileOffset)
        fileOffset = newOffset
        for line in lines {
            guard let event = try? JSONDecoder().decode(HookEvent.self, from: line) else { continue }
            apply(event)
        }
    }

    private func apply(_ event: HookEvent) {
        let runtime = event.runtime ?? .claude
        let eventTime = Date(timeIntervalSince1970: event.ts)
        switch event.event {
        case "Stop", "SubagentStop":
            if runtime == .codex {
                applyCodexStop(event, runtime: runtime, eventTime: eventTime)
            } else {
                applyStatus(.completed, event: event, runtime: runtime, eventTime: eventTime, flashUntil: Date().addingTimeInterval(3))
            }
        case "Notification", "PermissionRequest":
            applyStatus(.waiting, event: event, runtime: runtime, eventTime: eventTime)
        case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse":
            applyStatus(.running, event: event, runtime: runtime, eventTime: eventTime)
        default:
            break
        }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<6 {
                switch JSONLReader.codexTurnOutcome(at: transcriptURL, turnId: turnId) {
                case .completed:
                    self.applyStatus(.completed, event: event, runtime: runtime, eventTime: eventTime, flashUntil: Date().addingTimeInterval(3))
                    return
                case .interrupted:
                    self.applyStatus(.idle, event: event, runtime: runtime, eventTime: eventTime)
                    return
                case .failed:
                    self.applyStatus(.error, event: event, runtime: runtime, eventTime: eventTime)
                    return
                case .pending:
                    // Stop hook 可能比 transcript 最后一条 task_complete 更早落盘，短等几轮再判失败。
                    if attempt < 5 {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            }
            self.applyStatus(.error, event: event, runtime: runtime, eventTime: eventTime)
        }
    }

    private func applyStatus(_ status: SessionStatus, event: HookEvent, runtime: RuntimeKind, eventTime: Date, flashUntil: Date? = nil) {
        store.setHookStatus(runtime: runtime, rawSessionId: event.session_id, status: status, eventTime: eventTime, cwd: event.cwd, flashUntil: flashUntil)
    }
}
