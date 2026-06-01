import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController {
    private let store: SessionStore
    private let statusItem: NSStatusItem
    private let trafficLight: TrafficLightView
    private let popover: NSPopover
    private let completionPopover: NSPopover
    private var eventMonitor: Any?
    private var versionCancellable: AnyCancellable?
    private var completionCancellable: AnyCancellable?
    private var completionCloseTimer: Timer?

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.trafficLight = TrafficLightView(frame: NSRect(x: 0, y: 0, width: 56, height: 22))
        self.popover = NSPopover()
        self.completionPopover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.contentViewController = NSHostingController(rootView: PopoverContent(store: store))
        completionPopover.behavior = .transient
        completionPopover.animates = true

        if let button = statusItem.button {
            button.frame = NSRect(x: 0, y: 0, width: 56, height: 22)
            button.addSubview(trafficLight)
            trafficLight.frame = button.bounds
            trafficLight.autoresizingMask = [.width, .height]
            trafficLight.statusItem = statusItem
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        versionCancellable = store.$version.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        completionCancellable = store.$latestCompletion.compactMap { $0 }.sink { [weak self] notice in
            Task { @MainActor in self?.showCompletionNotice(notice) }
        }
        refresh()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func refresh() {
        trafficLight.update(status: store.aggregateStatus, activeCount: store.activeCount)
    }

    private func showCompletionNotice(_ notice: CompletionNotice) {
        guard let button = statusItem.button else { return }
        completionCloseTimer?.invalidate()
        completionPopover.performClose(nil)
        // 用独立 popover 模拟状态栏 tooltip，避免打断主列表弹窗的内容状态。
        completionPopover.contentSize = NSSize(width: 300, height: 82)
        completionPopover.contentViewController = NSHostingController(rootView: CompletionNoticeView(notice: notice))
        completionPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        completionCloseTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.completionPopover.performClose(nil) }
        }
    }
}

struct CompletionNoticeView: View {
    let notice: CompletionNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.runtime.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(notice.runtime.displayName) 任务完成")
                    .font(.system(size: 12, weight: .semibold))
                Text(notice.taskTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text("耗时 \(durationText)")
                    Text("Token \(formatTokens(notice.tokenTotal))")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 300, height: 82)
    }

    private var durationText: String {
        guard let duration = notice.duration else {
            return "--"
        }
        if duration < 60 {
            return "\(Int(duration))s"
        }
        if duration < 3600 {
            let minutes = Int(duration / 60)
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        }
        let hours = Int(duration / 3600)
        let minutes = Int(duration / 60) % 60
        return "\(hours)h \(minutes)m"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
