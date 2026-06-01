import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: SessionStore
    private let statusItem: NSStatusItem
    private let trafficLight: TrafficLightView
    private let popover: NSPopover
    private let completionPopover: NSPopover
    private var eventMonitor: Any?
    private var resignObserver: Any?
    private var versionCancellable: AnyCancellable?
    private var completionCancellable: AnyCancellable?
    private var failureCancellable: AnyCancellable?
    private var completionCloseTimer: Timer?

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.trafficLight = TrafficLightView(frame: NSRect(x: 0, y: 0, width: 56, height: 22))
        self.popover = NSPopover()
        self.completionPopover = NSPopover()
        super.init()

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
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
            Task { @MainActor in
                await self?.presentCompletionNotice(notice)
            }
        }
        failureCancellable = store.$latestFailure.compactMap { $0 }.sink { [weak self] notice in
            Task { @MainActor in
                await self?.presentFailureNotice(notice)
            }
        }
        refresh()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(from: sender)
        }
    }

    private func showPopover(from button: NSStatusBarButton) {
        if !NSApp.isActive {
            NSApp.activate()
        }
        // 多屏下激活应用会先让系统重新确定当前菜单栏归属；等一轮 runloop 再挂 popover，
        // 可以避免 popover 跟着状态栏按钮在不同屏之间来回跳。
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.installPopoverCloseHandlers()
        }
    }

    private func closePopover(_ sender: Any?) {
        guard popover.isShown else { return }
        popover.performClose(sender)
    }

    private func installPopoverCloseHandlers() {
        removePopoverCloseHandlers()
        // 系统 transient 在多屏切换时会重新绑定当前屏的状态栏按钮，关闭动画就会“飞走”。
        // 这里改成应用自己监听外部点击，尽量在屏幕焦点切换前从原锚点收起。
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover(nil)
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover(nil)
            }
        }
    }

    private func removePopoverCloseHandlers() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverCloseHandlers()
    }

    private func refresh() {
        trafficLight.update(status: store.aggregateStatus, activeCount: store.activeCount)
    }

    private func presentCompletionNotice(_ notice: CompletionNotice) async {
        switch store.reminderStyle {
        case .statusBarBubble:
            showCompletionBubble(notice)
        case .systemNotification:
            if await showSystemNotification(
                title: notice.titleText,
                body: notice.notificationBodyText,
                identifierPrefix: "completion"
            ) {
                return
            }
            // 用户后来手动关掉通知权限时，仍然回退到气泡，避免完成事件被吞掉。
            showCompletionBubble(notice)
        }
    }

    private func presentFailureNotice(_ notice: FailureNotice) async {
        switch store.reminderStyle {
        case .statusBarBubble:
            showFailureBubble(notice)
        case .systemNotification:
            if await showSystemNotification(
                title: notice.titleText,
                body: notice.notificationBodyText,
                identifierPrefix: "failure"
            ) {
                return
            }
            // 失败提醒不能静默丢掉，通知权限失效时继续回退到状态栏气泡。
            showFailureBubble(notice)
        }
    }

    private func showCompletionBubble(_ notice: CompletionNotice) {
        guard let button = statusItem.button else { return }
        completionCloseTimer?.invalidate()
        completionPopover.performClose(nil)
        // 用独立 popover 模拟状态栏 tooltip，避免打断主列表弹窗的内容状态。
        completionPopover.contentSize = NSSize(width: 360, height: 106)
        completionPopover.contentViewController = NSHostingController(rootView: CompletionNoticeView(notice: notice))
        completionPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        completionCloseTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.completionPopover.performClose(nil) }
        }
    }

    private func showFailureBubble(_ notice: FailureNotice) {
        guard let button = statusItem.button else { return }
        completionCloseTimer?.invalidate()
        completionPopover.performClose(nil)
        completionPopover.contentSize = NSSize(width: 360, height: 86)
        completionPopover.contentViewController = NSHostingController(rootView: FailureNoticeView(notice: notice))
        completionPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        completionCloseTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.completionPopover.performClose(nil) }
        }
    }

    private func showSystemNotification(title: String, body: String, identifierPrefix: String) async -> Bool {
        guard await store.canDeliverSystemNotification() else {
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error == nil)
            }
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
                Text(notice.titleText)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(notice.bubbleMessageText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let durationText = notice.durationText {
                    Text(durationText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 360, height: 106)
    }
}

struct FailureNoticeView: View {
    let notice: FailureNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.runtime.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(notice.titleText)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(notice.bubbleMessageText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 360, height: 86)
    }
}
