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
            applyStatus(.completed, event: event, runtime: runtime, eventTime: eventTime, flashUntil: Date().addingTimeInterval(3))
        case "Notification", "PermissionRequest":
            applyStatus(.waiting, event: event, runtime: runtime, eventTime: eventTime)
        case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse":
            applyStatus(.running, event: event, runtime: runtime, eventTime: eventTime)
        default:
            break
        }
    }

    private func applyStatus(_ status: SessionStatus, event: HookEvent, runtime: RuntimeKind, eventTime: Date, flashUntil: Date? = nil) {
        store.setHookStatus(runtime: runtime, rawSessionId: event.session_id, status: status, eventTime: eventTime, cwd: event.cwd, flashUntil: flashUntil)
    }
}
