import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: SessionStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let completionPopover: NSPopover
    private var eventMonitor: Any?
    private var resignObserver: Any?
    private var versionCancellable: AnyCancellable?
    private var styleCancellable: AnyCancellable?
    private var completionCancellable: AnyCancellable?
    private var failureCancellable: AnyCancellable?
    private var completionCloseTimer: Timer?
    private var statusAnimationTimer: Timer?
    private var statusAnimationStyle: StatusBarStyle?
    private var statusAnimationStep = 0

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
            // 多屏菜单栏镜像不会稳定复制自定义 subview，改用系统 button 的 image/title 渲染更稳。
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone
            button.font = .systemFont(ofSize: 12, weight: .bold)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        versionCancellable = store.$version.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        styleCancellable = store.$statusBarStyle.sink { [weak self] _ in
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
        updateStatusAnimation()
        renderStatusItem()
    }

    private func updateStatusAnimation() {
        guard store.aggregateStatus == .running else {
            statusAnimationTimer?.invalidate()
            statusAnimationTimer = nil
            statusAnimationStyle = nil
            statusAnimationStep = 0
            return
        }
        let style = store.statusBarStyle
        guard statusAnimationTimer == nil || statusAnimationStyle != style else { return }
        statusAnimationTimer?.invalidate()
        statusAnimationStyle = style
        statusAnimationStep = 0
        // 不同图形节奏不同；切换样式时重建定时器，避免动画相位残留。
        statusAnimationTimer = Timer.scheduledTimer(withTimeInterval: style.animationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusAnimationStep += 1
                self.renderStatusItem()
            }
        }
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        statusItem.length = NSStatusItem.variableLength
        button.image = makeStatusImage()
        button.attributedTitle = makeBadgeTitle(activeCount: store.activeCount)
    }

    private func makeBadgeTitle(activeCount: Int) -> NSAttributedString {
        guard activeCount > 0 else {
            return NSAttributedString(string: "")
        }
        return NSAttributedString(
            string: "\(activeCount)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func makeStatusImage() -> NSImage {
        let size = store.statusBarStyle.canvasSize
        let image = NSImage(size: size)
        image.lockFocus()
        switch store.statusBarStyle {
        case .defaultDot:
            drawDefaultDot(in: NSRect(origin: .zero, size: size))
        case .nineGrid:
            drawNineGrid(in: NSRect(origin: .zero, size: size))
        case .signalBars:
            drawSignalBars(in: NSRect(origin: .zero, size: size))
        case .orbitRing:
            drawOrbitRing(in: NSRect(origin: .zero, size: size))
        case .tripleDots:
            drawTripleDots(in: NSRect(origin: .zero, size: size))
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func statusColor(alpha: CGFloat = 1.0) -> NSColor {
        switch store.aggregateStatus {
        case .running:
            return NSColor.systemGreen.withAlphaComponent(alpha)
        case .error:
            return NSColor.systemRed.withAlphaComponent(alpha)
        case .idle, .waiting, .completed:
            return NSColor(white: 0.5, alpha: 0.35 * alpha)
        }
    }

    private func drawDefaultDot(in rect: NSRect) {
        let alpha: CGFloat
        switch store.aggregateStatus {
        case .running:
            alpha = statusAnimationStep.isMultiple(of: 2) ? 1.0 : 0.35
        case .error:
            alpha = 1.0
        case .idle, .waiting, .completed:
            alpha = 1.0
        }
        statusColor(alpha: alpha).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func drawNineGrid(in rect: NSRect) {
        let cell: CGFloat = 3
        let gap: CGFloat = 1.5
        let activeIndex = statusAnimationStep % 9

        for index in 0..<9 {
            let row = index / 3
            let column = index % 3
            let x = CGFloat(column) * (cell + gap)
            let y = rect.height - cell - CGFloat(row) * (cell + gap)
            let alpha: CGFloat

            switch store.aggregateStatus {
            case .running:
                // 九宫格按左上到右下顺序轮转，和用户看到的“0 到 8”保持一致。
                alpha = index == activeIndex ? 1.0 : 0.18
            case .error:
                alpha = 1.0
            case .idle, .waiting, .completed:
                alpha = 1.0
            }

            statusColor(alpha: alpha).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: cell, height: cell),
                xRadius: 0.8,
                yRadius: 0.8
            ).fill()
        }
    }

    private func drawSignalBars(in rect: NSRect) {
        let barWidth: CGFloat = 2
        let gap: CGFloat = 4.0 / 3.0
        let corner: CGFloat = 1
        let heights: [CGFloat]

        switch store.aggregateStatus {
        case .running:
            let frames: [[CGFloat]] = [
                [4, 7, 10, 7],
                [6, 10, 7, 4],
                [10, 7, 4, 6],
                [7, 4, 6, 10]
            ]
            heights = frames[statusAnimationStep % frames.count]
        case .error:
            heights = [10, 10, 10, 10]
        case .idle, .waiting, .completed:
            heights = [4, 6, 8, 10]
        }

        for index in 0..<heights.count {
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let height = heights[index]
            statusColor(alpha: 1.0).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: rect.minY, width: barWidth, height: height),
                xRadius: corner,
                yRadius: corner
            ).fill()
        }
    }

    private func drawOrbitRing(in rect: NSRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let orbitRadius: CGFloat = 4
        let dotSize: CGFloat = 2.4
        let activeIndex = statusAnimationStep % 8

        for index in 0..<8 {
            let angle = (CGFloat.pi * 2 / 8) * CGFloat(index) - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * orbitRadius,
                y: center.y + sin(angle) * orbitRadius
            )
            let alpha: CGFloat

            switch store.aggregateStatus {
            case .running:
                if index == activeIndex {
                    alpha = 1.0
                } else if index == (activeIndex + 7) % 8 {
                    alpha = 0.45
                } else {
                    alpha = 0.18
                }
            case .error:
                alpha = 1.0
            case .idle, .waiting, .completed:
                alpha = 1.0
            }

            statusColor(alpha: alpha).setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: point.x - dotSize / 2,
                    y: point.y - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
            ).fill()
        }
    }

    private func drawTripleDots(in rect: NSRect) {
        let dotSize: CGFloat = 3.2
        let gap: CGFloat = 2.2
        let activeIndex = statusAnimationStep % 3

        for index in 0..<3 {
            let x = CGFloat(index) * (dotSize + gap)
            let alpha: CGFloat

            switch store.aggregateStatus {
            case .running:
                alpha = index == activeIndex ? 1.0 : 0.22
            case .error:
                alpha = 1.0
            case .idle, .waiting, .completed:
                alpha = 1.0
            }

            statusColor(alpha: alpha).setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: x,
                    y: (rect.height - dotSize) / 2,
                    width: dotSize,
                    height: dotSize
                )
            ).fill()
        }
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
        completionPopover.contentSize = NSSize(width: 320, height: 90)
        completionPopover.contentViewController = NSHostingController(rootView: CompletionNoticeView(notice: notice))
        completionPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        completionCloseTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.completionPopover.performClose(nil) }
        }
    }

    private func showFailureBubble(_ notice: FailureNotice) {
        guard let button = statusItem.button else { return }
        completionCloseTimer?.invalidate()
        completionPopover.performClose(nil)
        completionPopover.contentSize = NSSize(width: 320, height: 72)
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

private extension StatusBarStyle {
    var canvasSize: NSSize {
        switch self {
        case .defaultDot:
            return NSSize(width: 10, height: 10)
        case .nineGrid, .signalBars, .orbitRing:
            return NSSize(width: 12, height: 12)
        case .tripleDots:
            return NSSize(width: 14, height: 10)
        }
    }

    var animationInterval: TimeInterval {
        switch self {
        case .defaultDot:
            return 0.7
        case .nineGrid:
            return 0.18
        case .signalBars:
            return 0.22
        case .orbitRing:
            return 0.14
        case .tripleDots:
            return 0.24
        }
    }
}

struct CompletionNoticeView: View {
    let notice: CompletionNotice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.runtime.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 320, height: 90)
    }
}

struct FailureNoticeView: View {
    let notice: FailureNotice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.runtime.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 320, height: 72)
    }
}
