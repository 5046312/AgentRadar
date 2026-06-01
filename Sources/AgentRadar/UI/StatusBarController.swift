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
    private var speedCancellable: AnyCancellable?
    private var completionCancellable: AnyCancellable?
    private var failureCancellable: AnyCancellable?
    private var completionCloseTimer: Timer?
    private var statusAnimationTimer: Timer?
    private var activeAnimationInterval: TimeInterval?
    private var lastAnimationTokenSample: (tokens: Int, timestamp: Date)?
    private var lastIntervalTPS: Double?
    private var litCellColors: [NSColor] = Array(repeating: .systemGreen, count: 9)
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
        speedCancellable = store.$nineGridAnimationInterval.sink { [weak self] _ in
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
            activeAnimationInterval = nil
            lastAnimationTokenSample = nil
            lastIntervalTPS = nil
            litCellColors = Array(repeating: .systemGreen, count: 9)
            statusAnimationStep = 0
            return
        }
        let interval = store.nineGridAnimationInterval
        let needsSpeedUpdate = activeAnimationInterval.map { abs($0 - interval) > 0.001 } ?? true
        guard statusAnimationTimer == nil || needsSpeedUpdate else { return }
        let wasAnimating = statusAnimationTimer != nil
        statusAnimationTimer?.invalidate()
        activeAnimationInterval = interval
        if !wasAnimating {
            lastAnimationTokenSample = (store.runningTokenDeltaTotal(), Date())
            lastIntervalTPS = nil
            litCellColors = Array(repeating: .systemGreen, count: 9)
            statusAnimationStep = 0
        }
        // 只在用户调整九宫格速度时重建 Timer，避免普通状态刷新打断动画节奏。
        statusAnimationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.advanceNineGridAnimation()
                self.renderStatusItem()
                self.updateStatusAnimation()
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
        let size = nineGridCanvasSize
        let image = NSImage(size: size)
        image.lockFocus()
        drawNineGrid(in: NSRect(origin: .zero, size: size))
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

    private func drawNineGrid(in rect: NSRect) {
        let gap: CGFloat = 0.5
        let cell = (rect.width - gap * 2) / 3
        let corner = min(1.1, cell * 0.22)
        let phase = statusAnimationStep % 10

        for index in 0..<9 {
            let row = index / 3
            let column = index % 3
            let x = CGFloat(column) * (cell + gap)
            let y = rect.height - cell - CGFloat(row) * (cell + gap)
            switch store.aggregateStatus {
            case .running:
                // 运行中按左上到右下逐个累积点亮，满格后整组熄灭再开始下一轮。
                let litCount = phase == 9 ? 0 : phase + 1
                let color = index < litCount
                    ? litCellColors[index].withAlphaComponent(1.0)
                    : NSColor(white: 0.5, alpha: 0.18)
                color.setFill()
            case .error:
                statusColor(alpha: 1.0).setFill()
            case .idle, .waiting, .completed:
                statusColor(alpha: 1.0).setFill()
            }

            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: cell, height: cell),
                xRadius: corner,
                yRadius: corner
            ).fill()
        }
    }

    private func advanceNineGridAnimation() {
        let nextStep = statusAnimationStep + 1
        let phase = nextStep % 10

        if phase == 9 {
            // 第 10 帧是整组熄灭，不产生“新亮起”颜色样本。
            statusAnimationStep = nextStep
            return
        }

        if phase == 0 {
            litCellColors = Array(repeating: .systemGreen, count: 9)
        }

        litCellColors[phase] = nextRunningStepColor()
        statusAnimationStep = nextStep
    }

    private func nextRunningStepColor() -> NSColor {
        let now = Date()
        let currentTokens = store.runningTokenDeltaTotal()

        guard
            let previousSample = lastAnimationTokenSample,
            now.timeIntervalSince(previousSample.timestamp) > 0
        else {
            lastAnimationTokenSample = (currentTokens, now)
            return .systemGreen
        }

        let elapsed = now.timeIntervalSince(previousSample.timestamp)
        let tokenDelta = max(0, currentTokens - previousSample.tokens)
        let currentTPS = Double(tokenDelta) / elapsed
        defer {
            lastAnimationTokenSample = (currentTokens, now)
            lastIntervalTPS = currentTPS
        }

        guard let previousTPS = lastIntervalTPS else {
            return .systemGreen
        }
        guard previousTPS > 0 else {
            return currentTPS > 0 ? .systemGreen : .systemYellow
        }

        // 颜色按相邻两次亮起之间的区间 TPS 变化决定：明显下滑红色，小幅下降黄色，上升绿色。
        let changeRatio = (currentTPS - previousTPS) / previousTPS
        if changeRatio > 0 { return .systemGreen }
        if changeRatio <= -0.20 { return .systemRed }
        return .systemYellow
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
    private var nineGridCanvasSize: NSSize {
        NSSize(width: 13, height: 13)
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
