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
    private var cellRevealTimer: Timer?
    private var cellRevealStartedAt: Date?
    private var activeAnimationInterval: TimeInterval?
    private var statusAnimationStep = 0
    private var cellRevealProgress: CGFloat = 1.0
    private var breathingAnimationPhase = Double.random(in: 0...(Double.pi * 2))

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
        syncStatusAnimationTimer()
        renderStatusItem()
    }

    private func syncStatusAnimationTimer() {
        guard store.activeCount > 0 else {
            statusAnimationTimer?.invalidate()
            statusAnimationTimer = nil
            cellRevealTimer?.invalidate()
            cellRevealTimer = nil
            cellRevealStartedAt = nil
            activeAnimationInterval = nil
            statusAnimationStep = 0
            cellRevealProgress = 1.0
            breathingAnimationPhase = Double.random(in: 0...(Double.pi * 2))
            return
        }

        let interval = store.nineGridAnimationInterval
        let needsIntervalUpdate = activeAnimationInterval.map { abs($0 - interval) > 0.001 } ?? true
        guard statusAnimationTimer == nil || needsIntervalUpdate else {
            return
        }

        statusAnimationTimer?.invalidate()
        activeAnimationInterval = interval
        if statusAnimationStep == 0 {
            advanceNineGridAnimation()
        }
        scheduleNextStatusAnimationTick()
    }

    private func scheduleNextStatusAnimationTick() {
        statusAnimationTimer?.invalidate()
        let randomizedInterval = clampedStatusAnimationInterval(nextBreathingAnimationInterval())
        statusAnimationTimer = Timer.scheduledTimer(withTimeInterval: randomizedInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.store.activeCount > 0 else {
                    self.syncStatusAnimationTimer()
                    self.renderStatusItem()
                    return
                }
                self.advanceNineGridAnimation()
                self.renderStatusItem()
                self.scheduleNextStatusAnimationTick()
            }
        }
    }

    private func nextBreathingAnimationInterval() -> TimeInterval {
        breathingAnimationPhase += Double.random(in: 0.42...0.68)
        if breathingAnimationPhase > Double.pi * 2 {
            breathingAnimationPhase -= Double.pi * 2
        }

        // 用正弦波做主节奏，只加极小随机扰动；避免 ±1s 那种明显跳变。
        let waveOffset = sin(breathingAnimationPhase) * 0.14
        let jitterOffset = Double.random(in: -0.035...0.035)
        return store.nineGridAnimationInterval * (1.0 + waveOffset + jitterOffset)
    }

    private func clampedStatusAnimationInterval(_ interval: TimeInterval) -> TimeInterval {
        min(
            SessionStore.maxNineGridAnimationInterval,
            max(SessionStore.minNineGridAnimationInterval, interval)
        )
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
        let litCount = min(max(statusAnimationStep, 0), 9)

        for index in 0..<9 {
            let row = index / 3
            let column = index % 3
            let x = CGFloat(column) * (cell + gap)
            let y = rect.height - cell - CGFloat(row) * (cell + gap)
            let cellRect = NSRect(x: x, y: y, width: cell, height: cell)
            if store.activeCount > 0 {
                if index < litCount {
                    drawRunningCell(
                        in: cellRect,
                        corner: corner,
                        isNewest: index == litCount - 1
                    )
                } else {
                    emptyCellColor.setFill()
                    NSBezierPath(
                        roundedRect: cellRect,
                        xRadius: corner,
                        yRadius: corner
                    ).fill()
                }
            } else {
                switch store.aggregateStatus {
                case .error:
                    statusColor(alpha: 1.0).setFill()
                case .running, .idle, .waiting, .completed:
                    statusColor(alpha: 1.0).setFill()
                }
                NSBezierPath(
                    roundedRect: cellRect,
                    xRadius: corner,
                    yRadius: corner
                ).fill()
            }
        }
    }

    private func advanceNineGridAnimation() {
        if statusAnimationStep >= 9 {
            statusAnimationStep = 0
        }
        statusAnimationStep += 1
        startCellRevealAnimation()
    }

    private func startCellRevealAnimation() {
        cellRevealTimer?.invalidate()
        cellRevealProgress = 0
        cellRevealStartedAt = Date()

        // 每格点亮只做一次很短的淡入+放大，避免状态栏图标看起来突然跳变。
        cellRevealTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.store.activeCount > 0 else {
                    self.cellRevealTimer?.invalidate()
                    self.cellRevealTimer = nil
                    return
                }

                self.updateCellRevealProgress()
                self.renderStatusItem()
            }
        }
    }

    private func updateCellRevealProgress() {
        guard let startedAt = cellRevealStartedAt else {
            cellRevealProgress = 1.0
            return
        }

        let interval = activeAnimationInterval ?? store.nineGridAnimationInterval
        let duration = min(0.22, max(0.08, interval * 0.45))
        let progress = Date().timeIntervalSince(startedAt) / duration
        cellRevealProgress = min(1.0, max(0, CGFloat(progress)))

        if cellRevealProgress >= 1.0 {
            cellRevealTimer?.invalidate()
            cellRevealTimer = nil
            cellRevealStartedAt = nil
        }
    }

    private func drawRunningCell(in rect: NSRect, corner: CGFloat, isNewest: Bool) {
        if isNewest {
            NSColor.systemGreen.withAlphaComponent(0.16 * cellRevealProgress).setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: -0.6, dy: -0.6),
                xRadius: corner + 0.6,
                yRadius: corner + 0.6
            ).fill()
        }

        let revealProgress = isNewest ? cellRevealProgress : 1.0
        let easedProgress = CGFloat(1 - pow(1 - Double(revealProgress), 3))
        let inset = (1 - easedProgress) * min(rect.width, rect.height) * 0.28
        let revealRect = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: revealRect, xRadius: corner, yRadius: corner)
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.62, green: 1.0, blue: 0.70, alpha: revealProgress),
            NSColor.systemGreen.withAlphaComponent(revealProgress),
            NSColor(calibratedRed: 0.04, green: 0.45, blue: 0.18, alpha: revealProgress)
        ])
        gradient?.draw(in: path, angle: -45)
    }

    private var emptyCellColor: NSColor {
        NSColor(white: 0.5, alpha: 0.18)
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
        NSSize(width: 16, height: 16)
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
