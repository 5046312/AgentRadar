import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private enum RunningCellTone: Int, Equatable {
        case light
        case normal
        case dark
    }

    private struct StatusRenderKey: Equatable {
        let activeCount: Int
        let aggregateStatus: String
        let animationStep: Int
        let cellTones: [RunningCellTone]
    }

    private let store: SessionStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let noticePopover: NSPopover
    private let minStatusAnimationTickInterval: TimeInterval = 0.08
    private let minNoticeBubbleWidth: CGFloat = 190
    private let maxNoticeBubbleWidth: CGFloat = 360
    private var currentBadgeText = ""
    private var eventMonitor: Any?
    private var resignObserver: Any?
    private var versionCancellable: AnyCancellable?
    private var speedCancellable: AnyCancellable?
    private var variationCancellable: AnyCancellable?
    private var completionCancellable: AnyCancellable?
    private var failureCancellable: AnyCancellable?
    private var waitingCancellable: AnyCancellable?
    private var noticeCloseTimer: Timer?
    private var noticePresentationSerial = 0
    private var statusAnimationTimer: Timer?
    private var activeAnimationInterval: TimeInterval?
    private var activeAnimationVariationPercent: Double?
    private var activeAnimationActiveCount = 0
    private var activeAnimationOffset = 0.0
    private var statusAnimationStep = 0
    private var statusAnimationCellTones = Array(repeating: RunningCellTone.normal, count: 9)
    private var breathingAnimationPhase = Double.random(in: 0...(Double.pi * 2))
    private var lastStatusRenderKey: StatusRenderKey?
    private lazy var lightRunningCellGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.78, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.92, blue: 0.48, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.22, alpha: 1)
    ])
    private lazy var normalRunningCellGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.62, green: 1.0, blue: 0.70, alpha: 1),
        NSColor.systemGreen,
        NSColor(calibratedRed: 0.04, green: 0.45, blue: 0.18, alpha: 1)
    ])
    private lazy var darkRunningCellGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.38, green: 0.82, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.54, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.01, green: 0.28, blue: 0.10, alpha: 1)
    ])

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.noticePopover = NSPopover()
        super.init()

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.contentViewController = NSHostingController(rootView: PopoverContent(store: store))

        noticePopover.behavior = .transient
        noticePopover.animates = true
        noticePopover.delegate = self

        if let button = statusItem.button {
            // 多屏菜单栏镜像不会稳定复制自定义 subview；沿用系统 button 的 image/title。
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.attributedTitle = NSAttributedString(string: "")
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
        variationCancellable = store.$nineGridIntervalVariationPercent.sink { [weak self] _ in
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
        waitingCancellable = store.$latestWaiting.compactMap { $0 }.sink { [weak self] notice in
            Task { @MainActor in
                await self?.presentWaitingNotice(notice)
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

    private func closeNoticeBubble() {
        noticePresentationSerial &+= 1
        noticeCloseTimer?.invalidate()
        noticeCloseTimer = nil
        guard noticePopover.isShown else { return }
        noticePopover.performClose(nil)
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
        guard let closedPopover = notification.object as? NSPopover else { return }
        if closedPopover === popover {
            removePopoverCloseHandlers()
        } else if closedPopover === noticePopover {
            noticeCloseTimer?.invalidate()
            noticeCloseTimer = nil
        }
    }

    private func refresh() {
        syncStatusAnimationTimer()
        renderStatusItem()
    }

    private func syncStatusAnimationTimer() {
        let activeCount = store.activeCount
        guard activeCount > 0 else {
            statusAnimationTimer?.invalidate()
            statusAnimationTimer = nil
            activeAnimationInterval = nil
            activeAnimationVariationPercent = nil
            activeAnimationActiveCount = 0
            activeAnimationOffset = 0
            statusAnimationStep = 0
            statusAnimationCellTones = Array(repeating: .normal, count: 9)
            breathingAnimationPhase = Double.random(in: 0...(Double.pi * 2))
            return
        }

        let interval = store.nineGridAnimationInterval
        let variationPercent = store.nineGridIntervalVariationPercent
        let needsIntervalUpdate = activeAnimationInterval.map { abs($0 - interval) > 0.001 } ?? true
        let needsVariationUpdate = activeAnimationVariationPercent.map { abs($0 - variationPercent) > 0.001 } ?? true
        let needsActiveCountUpdate = activeAnimationActiveCount != activeCount
        guard statusAnimationTimer == nil || needsIntervalUpdate || needsVariationUpdate || needsActiveCountUpdate else {
            return
        }

        statusAnimationTimer?.invalidate()
        activeAnimationInterval = interval
        activeAnimationVariationPercent = variationPercent
        activeAnimationActiveCount = activeCount
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

        // 浮动比例表示本次间隔相对基础速度的最大偏移，正弦负责呼吸感，随机值只打散机械节拍。
        let variation = store.nineGridIntervalVariationPercent / 100.0
        let waveOffset = sin(breathingAnimationPhase) * variation * 0.8
        let jitterOffset = Double.random(in: (-variation * 0.2)...(variation * 0.2))
        activeAnimationOffset = waveOffset + jitterOffset
        // 多个项目同时运行时，提高亮点切换频率：2 个项目就是 2 倍速度，即间隔除以 2。
        let activeMultiplier = max(1.0, Double(activeAnimationActiveCount))
        return store.nineGridAnimationInterval * (1.0 + activeAnimationOffset) / activeMultiplier
    }

    private func clampedStatusAnimationInterval(_ interval: TimeInterval) -> TimeInterval {
        min(
            SessionStore.maxNineGridAnimationInterval,
            max(minStatusAnimationTickInterval, interval)
        )
    }

    private func renderStatusItem() {
        let activeCount = store.activeCount
        let aggregateStatus = store.aggregateStatus
        guard let button = statusItem.button else { return }
        button.imagePosition = activeCount > 0 ? .imageLeading : .imageOnly
        updateStatusImage(activeCount: activeCount, aggregateStatus: aggregateStatus, button: button)
        updateBadgeTitle(activeCount: activeCount, button: button)
    }

    private func updateStatusImage(activeCount: Int, aggregateStatus: SessionStatus, button: NSStatusBarButton) {
        let nextKey = StatusRenderKey(
            activeCount: activeCount,
            aggregateStatus: aggregateStatus.rawValue,
            animationStep: statusAnimationStep,
            cellTones: statusAnimationCellTones
        )
        guard lastStatusRenderKey != nextKey else { return }
        lastStatusRenderKey = nextKey
        button.image = makeStatusImage(activeCount: activeCount, aggregateStatus: aggregateStatus)
    }

    private func updateBadgeTitle(activeCount: Int, button: NSStatusBarButton) {
        let nextText = activeCount > 0 ? badgeText(activeCount: activeCount) : ""
        guard currentBadgeText != nextText else { return }
        currentBadgeText = nextText
        button.attributedTitle = badgeTitle(nextText)
    }

    private func badgeText(activeCount: Int) -> String {
        activeCount > 9 ? "9+" : "\(activeCount)"
    }

    private func badgeTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func makeStatusImage(activeCount: Int, aggregateStatus: SessionStatus) -> NSImage {
        let size = nineGridCanvasSize
        let image = NSImage(size: size)
        image.lockFocus()
        drawNineGrid(in: NSRect(origin: .zero, size: size), activeCount: activeCount, aggregateStatus: aggregateStatus)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func statusColor(_ status: SessionStatus, alpha: CGFloat = 1.0) -> NSColor {
        switch status {
        case .running:
            return NSColor.systemGreen.withAlphaComponent(alpha)
        case .waiting:
            return NSColor.systemYellow.withAlphaComponent(alpha)
        case .error:
            return NSColor.systemRed.withAlphaComponent(alpha)
        case .idle, .completed:
            return NSColor(white: 0.5, alpha: 0.35 * alpha)
        }
    }

    private func drawNineGrid(in rect: NSRect, activeCount: Int, aggregateStatus: SessionStatus) {
        let gap: CGFloat = 0.5
        let cell = (rect.width - gap * 2) / 3
        let corner = min(1.1, cell * 0.22)
        let litCount = min(max(statusAnimationStep, 0), 9)
        let hasActiveSessions = activeCount > 0

        for index in 0..<9 {
            let row = index / 3
            let column = index % 3
            let x = rect.minX + CGFloat(column) * (cell + gap)
            let y = rect.minY + rect.height - cell - CGFloat(row) * (cell + gap)
            let cellRect = NSRect(x: x, y: y, width: cell, height: cell)
            if hasActiveSessions {
                if index < litCount {
                    drawRunningCell(
                        in: cellRect,
                        corner: corner,
                        isNewest: index == litCount - 1,
                        tone: statusAnimationCellTone(at: index)
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
                statusColor(aggregateStatus, alpha: 1.0).setFill()
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
            statusAnimationCellTones = Array(repeating: .normal, count: 9)
        }
        statusAnimationStep += 1
        statusAnimationCellTones[statusAnimationStep - 1] = runningCellTone
    }

    private func drawRunningCell(in rect: NSRect, corner: CGFloat, isNewest: Bool, tone: RunningCellTone) {
        if isNewest {
            runningCellGlowColor(tone: tone).withAlphaComponent(0.16).setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: -0.6, dy: -0.6),
                xRadius: corner + 0.6,
                yRadius: corner + 0.6
            ).fill()
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        runningCellGradient(tone: tone)?.draw(in: path, angle: -45)
    }

    private func statusAnimationCellTone(at index: Int) -> RunningCellTone {
        guard statusAnimationCellTones.indices.contains(index) else {
            return .normal
        }
        return statusAnimationCellTones[index]
    }

    private var runningCellTone: RunningCellTone {
        let variation = store.nineGridIntervalVariationPercent / 100.0
        guard variation > 0 else { return .normal }

        let firstBoundary = -variation / 3.0
        let secondBoundary = variation / 3.0
        if activeAnimationOffset < firstBoundary {
            return .light
        }
        if activeAnimationOffset > secondBoundary {
            return .dark
        }
        return .normal
    }

    private func runningCellGlowColor(tone: RunningCellTone) -> NSColor {
        switch tone {
        case .light:
            return NSColor(calibratedRed: 0.48, green: 0.96, blue: 0.52, alpha: 1)
        case .normal:
            return NSColor.systemGreen
        case .dark:
            return NSColor(calibratedRed: 0.02, green: 0.38, blue: 0.14, alpha: 1)
        }
    }

    private func runningCellGradient(tone: RunningCellTone) -> NSGradient? {
        switch tone {
        case .light:
            return lightRunningCellGradient
        case .normal:
            return normalRunningCellGradient
        case .dark:
            return darkRunningCellGradient
        }
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

    private func presentWaitingNotice(_ notice: WaitingNotice) async {
        switch store.reminderStyle {
        case .statusBarBubble:
            showWaitingBubble(notice)
        case .systemNotification:
            if await showSystemNotification(
                title: notice.titleText,
                body: notice.notificationBodyText,
                identifierPrefix: "waiting"
            ) {
                return
            }
            // 确认提醒不能静默丢掉，通知权限失效时继续回退到状态栏气泡。
            showWaitingBubble(notice)
        }
    }

    private func showCompletionBubble(_ notice: CompletionNotice) {
        let width = noticeBubbleWidth(
            title: notice.titleText,
            lines: [notice.bubbleMessageText, notice.durationText].compactMap { $0 }
        )
        showNoticeBubble(
            contentViewController: NSHostingController(rootView: CompletionNoticeView(notice: notice, width: width)),
            size: NSSize(width: width, height: 64),
            autoCloseAfter: 6.0
        )
    }

    private func showFailureBubble(_ notice: FailureNotice) {
        let width = noticeBubbleWidth(title: notice.titleText, lines: [notice.bubbleMessageText])
        showNoticeBubble(
            contentViewController: NSHostingController(rootView: FailureNoticeView(notice: notice, width: width)),
            size: NSSize(width: width, height: 52),
            autoCloseAfter: 4.0
        )
    }

    private func showWaitingBubble(_ notice: WaitingNotice) {
        let width = noticeBubbleWidth(title: notice.titleText, lines: [notice.bubbleMessageText])
        showNoticeBubble(
            contentViewController: NSHostingController(rootView: WaitingNoticeView(notice: notice, width: width)),
            size: NSSize(width: width, height: 52),
            autoCloseAfter: 6.0
        )
    }

    private func showNoticeBubble(contentViewController: NSViewController, size: NSSize, autoCloseAfter delay: TimeInterval) {
        closeNoticeBubble()
        guard let button = statusItem.button else { return }
        noticePresentationSerial &+= 1
        let serial = noticePresentationSerial

        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, self.noticePresentationSerial == serial, let button else { return }
            self.noticePopover.contentSize = size
            self.noticePopover.contentViewController = contentViewController
            // 提醒气泡退回标准 NSPopover，让系统自己处理多屏位置和越界钳制。
            self.noticePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.noticeCloseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.closeNoticeBubble() }
            }
        }
    }

    private func noticeBubbleWidth(title: String, lines: [String]) -> CGFloat {
        let titleWidth = measuredWidth(title, font: .systemFont(ofSize: 12, weight: .semibold))
        let bodyWidth = lines
            .map { measuredWidth($0, font: .systemFont(ofSize: 11)) }
            .max() ?? 0
        // 图标 18 + 图文间距 8 + 水平 padding 20，再留一点余量避免文字贴边。
        let contentWidth = max(titleWidth, bodyWidth) + 18 + 8 + 24
        return min(maxNoticeBubbleWidth, max(minNoticeBubbleWidth, ceil(contentWidth)))
    }

    private func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
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
    let width: CGFloat

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
        .padding(.vertical, 4)
        .frame(width: width, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct FailureNoticeView: View {
    let notice: FailureNotice
    let width: CGFloat

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
        .padding(.vertical, 4)
        .frame(width: width, height: 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct WaitingNoticeView: View {
    let notice: WaitingNotice
    let width: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.runtime.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.yellow)
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
        .padding(.vertical, 4)
        .frame(width: width, height: 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
