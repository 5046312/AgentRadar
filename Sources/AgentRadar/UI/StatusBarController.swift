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
        case waiting
    }

    private enum AmbientGridEffect: Int, CaseIterable, Equatable {
        case shimmer
        case glow
        case flow
        case marquee

        var durationTicks: Int {
            switch self {
            case .shimmer: return Int.random(in: 28...42)
            case .glow: return Int.random(in: 30...46)
            case .flow: return Int.random(in: 24...36)
            case .marquee: return Int.random(in: 32...48)
            }
        }

        static func random(excluding current: AmbientGridEffect) -> AmbientGridEffect {
            let candidates = allCases.filter { $0 != current }
            return candidates.randomElement() ?? current
        }
    }

    private struct StatusRenderKey: Equatable {
        let activeCount: Int
        let aggregateStatus: String
        let hasWaitingInActiveProject: Bool
        let ambientEffect: AmbientGridEffect
        let animationStep: Int
        let cellTones: [RunningCellTone]
    }

    private let store: SessionStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let noticePopover: NSPopover
    private let minStatusAnimationTickInterval: TimeInterval = 0.08
    private var currentBadgeText = ""
    private var eventMonitor: Any?
    private var resignObserver: Any?
    private var noticeEventMonitor: Any?
    private var noticeResignObserver: Any?
    private var versionCancellable: AnyCancellable?
    private var speedCancellable: AnyCancellable?
    private var variationCancellable: AnyCancellable?
    private var completionCancellable: AnyCancellable?
    private var failureCancellable: AnyCancellable?
    private var waitingCancellable: AnyCancellable?
    private var statusAnimationTimer: Timer?
    private var activeAnimationInterval: TimeInterval?
    private var activeAnimationVariationPercent: Double?
    private var activeAnimationActiveCount = 0
    private var activeAnimationAggregateStatus = SessionStatus.idle
    private var activeAnimationHasWaitingInActiveProject = false
    private var activeAnimationOffset = 0.0
    private var statusAnimationStep = 0
    private var statusAnimationCellTones = Array(repeating: RunningCellTone.normal, count: 9)
    private var ambientGridEffect = AmbientGridEffect.shimmer
    private var ambientGridEffectRemainingTicks = 0
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
    private lazy var waitingRunningCellGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.94, blue: 0.58, alpha: 0.74),
        NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.28, alpha: 0.72),
        NSColor(calibratedRed: 0.82, green: 0.62, blue: 0.20, alpha: 0.68)
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

        noticePopover.behavior = .applicationDefined
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

    private func closeNoticePopover(_ sender: Any?) {
        guard noticePopover.isShown else { return }
        noticePopover.performClose(sender)
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

    private func installNoticePopoverCloseHandlers() {
        removeNoticePopoverCloseHandlers()
        // 完成提醒也锚在状态栏按钮上；跨屏点击时先收起，避免 AppKit 重新绑定到另一块屏幕的菜单栏镜像。
        noticeEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closeNoticePopover(nil)
            }
        }
        noticeResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeNoticePopover(nil)
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

    private func removeNoticePopoverCloseHandlers() {
        if let noticeEventMonitor {
            NSEvent.removeMonitor(noticeEventMonitor)
            self.noticeEventMonitor = nil
        }
        if let noticeResignObserver {
            NotificationCenter.default.removeObserver(noticeResignObserver)
            self.noticeResignObserver = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover else { return }
        if closedPopover === popover {
            removePopoverCloseHandlers()
        } else if closedPopover === noticePopover {
            removeNoticePopoverCloseHandlers()
        }
    }

    private func refresh() {
        let summary = store.statusItemSummary()
        syncStatusAnimationTimer(summary: summary)
        renderStatusItem(summary: summary)
    }

    private func syncStatusAnimationTimer(summary: StatusItemSummary) {
        let activeCount = summary.activeCount
        let aggregateStatus = summary.aggregateStatus
        let interval = store.nineGridAnimationInterval
        let variationPercent = store.nineGridIntervalVariationPercent
        let wasActive = activeAnimationActiveCount > 0
        let isActive = activeCount > 0
        let needsIntervalUpdate = activeAnimationInterval.map { abs($0 - interval) > 0.001 } ?? true
        let needsVariationUpdate = activeAnimationVariationPercent.map { abs($0 - variationPercent) > 0.001 } ?? true
        let needsActiveCountUpdate = activeAnimationActiveCount != activeCount
        let needsStatusUpdate = activeAnimationAggregateStatus != aggregateStatus
        let needsWaitingUpdate = activeAnimationHasWaitingInActiveProject != summary.hasWaitingInActiveProject
        guard statusAnimationTimer == nil || needsIntervalUpdate || needsVariationUpdate || needsActiveCountUpdate || needsStatusUpdate || needsWaitingUpdate else {
            return
        }

        statusAnimationTimer?.invalidate()
        activeAnimationInterval = interval
        activeAnimationVariationPercent = variationPercent
        activeAnimationActiveCount = activeCount
        activeAnimationAggregateStatus = aggregateStatus
        activeAnimationHasWaitingInActiveProject = summary.hasWaitingInActiveProject
        if isActive {
            if !wasActive || needsActiveCountUpdate || needsWaitingUpdate || statusAnimationStep == 0 {
                resetRunningGridAnimation()
            }
        } else if wasActive || needsStatusUpdate || ambientGridEffectRemainingTicks <= 0 {
            resetAmbientGridAnimation()
        }
        scheduleNextStatusAnimationTick()
    }

    private func scheduleNextStatusAnimationTick() {
        statusAnimationTimer?.invalidate()
        let randomizedInterval = clampedStatusAnimationInterval(nextStatusAnimationInterval())
        statusAnimationTimer = Timer.scheduledTimer(withTimeInterval: randomizedInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.activeAnimationActiveCount > 0 {
                    self.advanceNineGridAnimation()
                } else {
                    self.advanceAmbientGridAnimation()
                }
                let summary = self.store.statusItemSummary()
                self.renderStatusItem(summary: summary)
                self.scheduleNextStatusAnimationTick()
            }
        }
    }

    private func nextStatusAnimationInterval() -> TimeInterval {
        activeAnimationActiveCount > 0 ? nextBreathingAnimationInterval() : nextAmbientGridAnimationInterval()
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

    private func nextAmbientGridAnimationInterval() -> TimeInterval {
        breathingAnimationPhase += Double.random(in: 0.30...0.52)
        if breathingAnimationPhase > Double.pi * 2 {
            breathingAnimationPhase -= Double.pi * 2
        }

        let variation = store.nineGridIntervalVariationPercent / 100.0
        let waveOffset = sin(breathingAnimationPhase) * variation * 0.45
        let jitterOffset = Double.random(in: (-variation * 0.12)...(variation * 0.12))
        activeAnimationOffset = waveOffset + jitterOffset
        return store.nineGridAnimationInterval * 0.8 * (1.0 + activeAnimationOffset)
    }

    private func clampedStatusAnimationInterval(_ interval: TimeInterval) -> TimeInterval {
        min(
            SessionStore.maxNineGridAnimationInterval,
            max(minStatusAnimationTickInterval, interval)
        )
    }

    private func renderStatusItem(summary: StatusItemSummary) {
        let activeCount = summary.activeCount
        let aggregateStatus = summary.aggregateStatus
        guard let button = statusItem.button else { return }
        button.imagePosition = activeCount > 0 ? .imageLeading : .imageOnly
        updateStatusImage(
            activeCount: activeCount,
            aggregateStatus: aggregateStatus,
            hasWaitingInActiveProject: summary.hasWaitingInActiveProject,
            button: button
        )
        updateBadgeTitle(activeCount: activeCount, button: button)
    }

    private func updateStatusImage(activeCount: Int, aggregateStatus: SessionStatus, hasWaitingInActiveProject: Bool, button: NSStatusBarButton) {
        let nextKey = StatusRenderKey(
            activeCount: activeCount,
            aggregateStatus: aggregateStatus.rawValue,
            hasWaitingInActiveProject: hasWaitingInActiveProject,
            ambientEffect: ambientGridEffect,
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
                drawAmbientGridCell(
                    in: cellRect,
                    index: index,
                    corner: corner,
                    status: aggregateStatus
                )
            }
        }
    }

    private func resetRunningGridAnimation() {
        statusAnimationStep = 0
        statusAnimationCellTones = Array(repeating: .normal, count: 9)
        breathingAnimationPhase = Double.random(in: 0...(Double.pi * 2))
        activeAnimationOffset = 0
        advanceNineGridAnimation()
    }

    private func resetAmbientGridAnimation() {
        statusAnimationStep = 0
        statusAnimationCellTones = Array(repeating: .normal, count: 9)
        breathingAnimationPhase = Double.random(in: 0...(Double.pi * 2))
        activeAnimationOffset = 0
        ambientGridEffect = AmbientGridEffect.random(excluding: ambientGridEffect)
        ambientGridEffectRemainingTicks = ambientGridEffect.durationTicks
    }

    private func advanceNineGridAnimation() {
        if statusAnimationStep >= 9 {
            statusAnimationStep = 0
            statusAnimationCellTones = Array(repeating: .normal, count: 9)
        }
        statusAnimationStep += 1
        statusAnimationCellTones[statusAnimationStep - 1] = runningCellTone
    }

    private func advanceAmbientGridAnimation() {
        // 空闲/等待没有真实进度，靠短状态机随机切换效果，避免状态栏停成静态色块。
        if ambientGridEffectRemainingTicks <= 0 {
            resetAmbientGridAnimation()
        }
        statusAnimationStep += 1
        ambientGridEffectRemainingTicks -= 1
    }

    private func drawRunningCell(in rect: NSRect, corner: CGFloat, isNewest: Bool, tone: RunningCellTone) {
        if isNewest {
            runningCellGlowColor(tone: tone).withAlphaComponent(runningCellGlowAlpha(tone: tone)).setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: -0.6, dy: -0.6),
                xRadius: corner + 0.6,
                yRadius: corner + 0.6
            ).fill()
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        runningCellGradient(tone: tone)?.draw(in: path, angle: -45)
    }

    private func drawAmbientGridCell(in rect: NSRect, index: Int, corner: CGFloat, status: SessionStatus) {
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        ambientGridBaseColor(status).setFill()
        path.fill()

        let alpha = ambientGridAlpha(index: index)
        guard alpha > 0.01 else { return }
        ambientGridGradient(status: status, alpha: alpha)?.draw(in: path, angle: -45)
    }

    private func ambientGridAlpha(index: Int) -> CGFloat {
        let row = index / 3
        let column = index % 3
        let tick = Double(statusAnimationStep)

        switch ambientGridEffect {
        case .shimmer:
            let wave = (sin(tick * 0.42 + Double(index) * 1.15) + 1.0) / 2.0
            return CGFloat(0.10 + wave * 0.42)
        case .glow:
            let dx = Double(column - 1)
            let dy = Double(row - 1)
            let distance = sqrt(dx * dx + dy * dy)
            let wave = (sin(tick * 0.38 - distance * 1.4) + 1.0) / 2.0
            return CGFloat(max(0.05, wave * 0.46 - distance * 0.08))
        case .flow:
            let phase = statusAnimationStep % 8
            let head = phase <= 4 ? phase : 8 - phase
            let distance = abs((row + column) - head)
            switch distance {
            case 0: return 0.58
            case 1: return 0.26
            default: return 0.07
            }
        case .marquee:
            let path = [0, 1, 2, 5, 8, 7, 6, 3]
            guard let position = path.firstIndex(of: index) else { return 0.10 }
            let distance = (position - statusAnimationStep % path.count + path.count) % path.count
            switch distance {
            case 0: return 0.62
            case 1: return 0.32
            case 2: return 0.16
            default: return 0.05
            }
        }
    }

    private func statusAnimationCellTone(at index: Int) -> RunningCellTone {
        guard statusAnimationCellTones.indices.contains(index) else {
            return .normal
        }
        return statusAnimationCellTones[index]
    }

    private var runningCellTone: RunningCellTone {
        if activeAnimationHasWaitingInActiveProject {
            return .waiting
        }

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
        case .waiting:
            return NSColor.systemYellow
        }
    }

    private func runningCellGlowAlpha(tone: RunningCellTone) -> CGFloat {
        switch tone {
        case .waiting:
            return 0.08
        case .light, .normal, .dark:
            return 0.16
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
        case .waiting:
            return waitingRunningCellGradient
        }
    }

    private func ambientGridBaseColor(_ status: SessionStatus) -> NSColor {
        switch status {
        case .waiting:
            return NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.22, alpha: 0.10)
        case .error:
            return NSColor.systemRed.withAlphaComponent(0.12)
        case .completed:
            return NSColor.systemGreen.withAlphaComponent(0.12)
        case .running:
            return NSColor.systemGreen.withAlphaComponent(0.12)
        case .idle:
            return NSColor(white: 0.5, alpha: 0.14)
        }
    }

    private func ambientGridGradient(status: SessionStatus, alpha: CGFloat) -> NSGradient? {
        let scaledAlpha = min(0.68, max(0.04, alpha * ambientGridAlphaScale(status)))
        return NSGradient(colors: [
            ambientGridBaseColor(status),
            ambientGridHighlightColor(status).withAlphaComponent(scaledAlpha),
            ambientGridBaseColor(status)
        ])
    }

    private func ambientGridHighlightColor(_ status: SessionStatus) -> NSColor {
        switch status {
        case .waiting:
            return NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.40, alpha: 1)
        case .error:
            return NSColor.systemRed
        case .completed, .running:
            return NSColor.systemGreen
        case .idle:
            return NSColor(calibratedRed: 0.72, green: 0.78, blue: 0.84, alpha: 1)
        }
    }

    private func ambientGridAlphaScale(_ status: SessionStatus) -> CGFloat {
        switch status {
        case .waiting:
            return 0.54
        case .idle, .completed, .running, .error:
            return 1.0
        }
    }

    private var emptyCellColor: NSColor {
        NSColor(white: 0.5, alpha: 0.18)
    }

    private func presentCompletionNotice(_ notice: CompletionNotice) async {
        showCompletionNoticePopover(notice)
    }

    private func presentFailureNotice(_ notice: FailureNotice) async {
        _ = await showSystemNotification(
            title: notice.titleText,
            body: notice.notificationBodyText,
            identifierPrefix: "failure"
        )
    }

    private func presentWaitingNotice(_ notice: WaitingNotice) async {
        _ = await showSystemNotification(
            title: notice.titleText,
            body: notice.notificationBodyText,
            identifierPrefix: "waiting"
        )
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

    private func showCompletionNoticePopover(_ notice: CompletionNotice) {
        guard let button = statusItem.button else { return }
        if !NSApp.isActive {
            NSApp.activate()
        }

        if noticePopover.isShown {
            noticePopover.performClose(nil)
        }

        noticePopover.contentSize = NSSize(width: 280, height: 150)
        noticePopover.contentViewController = NSHostingController(
            rootView: CompletionNoticeContent(notice: notice) { [weak self] in
                self?.noticePopover.performClose(nil)
            }
        )

        // 完成提醒需要用户主动确认，但位置仍复用状态栏按钮锚点，避免退回居中的 alert。
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button else { return }
            self.noticePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.installNoticePopoverCloseHandlers()
        }
    }

    private var nineGridCanvasSize: NSSize {
        NSSize(width: 16, height: 16)
    }
}

private struct CompletionNoticeContent: View {
    let notice: CompletionNotice
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(notice.titleText)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)

            Text(notice.notificationBodyText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("确定") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .focusEffectDisabled()
    }
}
