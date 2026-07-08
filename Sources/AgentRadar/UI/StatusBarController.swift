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
        let isErrorWaveActive: Bool
    }

    // 状态栏矩阵统一使用 3x3，避免绘制和动画步进尺寸不一致。
    private static let statusGridDimension = 3
    private static let statusGridCellCount = statusGridDimension * statusGridDimension
    private static let statusGridMarqueePath = [0, 1, 2, 5, 8, 7, 6, 3]
    private static func initialRunningCellTones() -> [RunningCellTone] {
        Array(repeating: .normal, count: statusGridCellCount)
    }

    private let store: SessionStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let minStatusAnimationTickInterval: TimeInterval = 0.08
    private var currentBadgeText = ""
    private var eventMonitor: Any?
    private var resignObserver: Any?
    private var versionCancellable: AnyCancellable?
    private var speedCancellable: AnyCancellable?
    private var variationCancellable: AnyCancellable?
    private var completionCancellable: AnyCancellable?
    private var failureCancellable: AnyCancellable?
    private var waitingCancellable: AnyCancellable?
    private var probeSuccessCancellable: AnyCancellable?
    private var statusAnimationTimer: Timer?
    private var activeAnimationInterval: TimeInterval?
    private var activeAnimationVariationPercent: Double?
    private var activeAnimationActiveCount = 0
    private var activeAnimationAggregateStatus = SessionStatus.idle
    private var activeAnimationHasWaitingInActiveProject = false
    private var activeAnimationOffset = 0.0
    private var statusAnimationStep = 0
    private var statusAnimationCellTones = StatusBarController.initialRunningCellTones()
    private var ambientGridEffect = AmbientGridEffect.shimmer
    private var ambientGridEffectRemainingTicks = 0
    private var statusFadeTimer: Timer?
    private var statusFadeTargetKey: StatusRenderKey?
    private var statusFadeStartImage: NSImage?
    private var statusFadeEndImage: NSImage?
    private var statusFadeStartTime: Date?
    private let statusFadeDuration: TimeInterval = 0.45
    private var completionFlashUntil: Date?
    private let completionFlashDuration: TimeInterval = 3.0
    private var errorWaveUntil: Date?
    private let errorWaveDuration: TimeInterval = 5.0
    private let errorWaveTickInterval: TimeInterval = 0.12
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
        super.init()

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.contentViewController = NSHostingController(rootView: PopoverContent(store: store))

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
                self?.startCompletionFlashAnimation()
                await self?.presentCompletionNotice(notice)
            }
        }
        failureCancellable = store.$latestFailure.compactMap { $0 }.sink { [weak self] notice in
            Task { @MainActor in
                self?.startErrorWaveAnimation()
                await self?.presentFailureNotice(notice)
            }
        }
        waitingCancellable = store.$latestWaiting.compactMap { $0 }.sink { [weak self] notice in
            Task { @MainActor in
                await self?.presentWaitingNotice(notice)
            }
        }
        probeSuccessCancellable = store.$latestProbeSuccess.compactMap { $0 }.sink { [weak self] notice in
            Task { @MainActor in
                await self?.presentProbeSuccessNotice(notice)
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
        guard let closedPopover = notification.object as? NSPopover else { return }
        if closedPopover === popover {
            removePopoverCloseHandlers()
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
        let timer = Timer(timeInterval: randomizedInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isErrorWaveActive() {
                    self.advanceErrorWaveAnimation()
                } else if self.activeAnimationActiveCount > 0 {
                    self.advanceNineGridAnimation()
                } else {
                    self.advanceAmbientGridAnimation()
                }
                let summary = self.store.statusItemSummary()
                self.renderStatusItem(summary: summary)
                self.scheduleNextStatusAnimationTick()
            }
        }
        statusAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func nextStatusAnimationInterval() -> TimeInterval {
        if isErrorWaveActive() {
            return errorWaveTickInterval
        }
        return activeAnimationActiveCount > 0 ? nextBreathingAnimationInterval() : nextAmbientGridAnimationInterval()
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
        let errorWaveActive = isErrorWaveActive()
        let completionFlashActive = !errorWaveActive && isCompletionFlashActive()
        let visualStatus = completionFlashActive ? SessionStatus.completed : aggregateStatus
        let nextKey = StatusRenderKey(
            activeCount: activeCount,
            aggregateStatus: visualStatus.rawValue,
            hasWaitingInActiveProject: hasWaitingInActiveProject,
            ambientEffect: ambientGridEffect,
            animationStep: statusAnimationStep,
            cellTones: statusAnimationCellTones,
            isErrorWaveActive: errorWaveActive
        )
        guard lastStatusRenderKey != nextKey else { return }
        let previousKey = lastStatusRenderKey
        if shouldKeepStatusImageFade(for: nextKey) {
            // 状态渐变未结束时，后续动画 tick 不能抢画图标，否则视觉上仍像硬切。
            lastStatusRenderKey = nextKey
            return
        }
        lastStatusRenderKey = nextKey
        let nextImage = makeStatusImage(
            activeCount: activeCount,
            aggregateStatus: visualStatus,
            isErrorWaveActive: errorWaveActive,
            isCompletionFlashActive: completionFlashActive
        )

        if shouldFadeStatusImage(from: previousKey, to: nextKey),
           let currentImage = button.image {
            startStatusImageFade(from: currentImage, to: nextImage, targetKey: nextKey, button: button)
        } else {
            stopStatusImageFade()
            button.image = nextImage
        }
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

    private func makeStatusImage(activeCount: Int, aggregateStatus: SessionStatus, isErrorWaveActive: Bool, isCompletionFlashActive: Bool) -> NSImage {
        let size = nineGridCanvasSize
        let image = NSImage(size: size)
        image.lockFocus()
        drawNineGrid(
            in: NSRect(origin: .zero, size: size),
            activeCount: activeCount,
            aggregateStatus: aggregateStatus,
            isErrorWaveActive: isErrorWaveActive,
            isCompletionFlashActive: isCompletionFlashActive
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func shouldFadeStatusImage(from previousKey: StatusRenderKey?, to nextKey: StatusRenderKey) -> Bool {
        guard let previousKey else { return false }
        let fadesToIdle = previousKey.activeCount == 0
            && previousKey.aggregateStatus == SessionStatus.completed.rawValue
            && nextKey.activeCount == 0
            && nextKey.aggregateStatus == SessionStatus.idle.rawValue
        let fadesFromIdleToTask = previousKey.activeCount == 0
            && previousKey.aggregateStatus == SessionStatus.idle.rawValue
            && (nextKey.activeCount > 0 || nextKey.aggregateStatus != SessionStatus.idle.rawValue)
        let fadesToErrorWave = !previousKey.isErrorWaveActive && nextKey.isErrorWaveActive
        let fadesFromErrorWave = previousKey.isErrorWaveActive && !nextKey.isErrorWaveActive
        return fadesToIdle || fadesFromIdleToTask || fadesToErrorWave || fadesFromErrorWave
    }

    private func shouldKeepStatusImageFade(for nextKey: StatusRenderKey) -> Bool {
        guard statusFadeTimer != nil, let targetKey = statusFadeTargetKey else {
            return false
        }
        return targetKey.activeCount == nextKey.activeCount
            && targetKey.aggregateStatus == nextKey.aggregateStatus
            && targetKey.hasWaitingInActiveProject == nextKey.hasWaitingInActiveProject
            && targetKey.isErrorWaveActive == nextKey.isErrorWaveActive
    }

    private func startStatusImageFade(from startImage: NSImage, to endImage: NSImage, targetKey: StatusRenderKey, button: NSStatusBarButton) {
        stopStatusImageFade()
        statusFadeTargetKey = targetKey
        statusFadeStartImage = startImage
        statusFadeEndImage = endImage
        statusFadeStartTime = Date()
        // 状态切换时动画 tick 会立刻换图；用短渐变承接，避免状态栏图标硬切。
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self, weak button] timer in
            Task { @MainActor in
                guard
                    let self,
                    let button,
                    let startImage = self.statusFadeStartImage,
                    let endImage = self.statusFadeEndImage,
                    let startTime = self.statusFadeStartTime
                else {
                    timer.invalidate()
                    return
                }

                let elapsed = Date().timeIntervalSince(startTime)
                let rawProgress = min(1.0, max(0.0, elapsed / self.statusFadeDuration))
                let progress = self.smoothedFadeProgress(rawProgress)
                button.image = self.blendedStatusImage(from: startImage, to: endImage, progress: progress)

                guard rawProgress >= 1 else { return }
                timer.invalidate()
                if self.statusFadeTimer === timer {
                    self.statusFadeTimer = nil
                    self.statusFadeTargetKey = nil
                    self.statusFadeStartImage = nil
                    self.statusFadeEndImage = nil
                    self.statusFadeStartTime = nil
                }
                button.image = endImage
            }
        }
        statusFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopStatusImageFade() {
        statusFadeTimer?.invalidate()
        statusFadeTimer = nil
        statusFadeTargetKey = nil
        statusFadeStartImage = nil
        statusFadeEndImage = nil
        statusFadeStartTime = nil
    }

    private func smoothedFadeProgress(_ progress: Double) -> CGFloat {
        let clamped = min(1.0, max(0.0, progress))
        return CGFloat(clamped * clamped * (3 - 2 * clamped))
    }

    private func blendedStatusImage(from startImage: NSImage, to endImage: NSImage, progress: CGFloat) -> NSImage {
        let size = nineGridCanvasSize
        let rect = NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)
        image.lockFocus()
        startImage.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1 - progress)
        endImage.draw(in: rect, from: rect, operation: .sourceOver, fraction: progress)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func drawNineGrid(in rect: NSRect, activeCount: Int, aggregateStatus: SessionStatus, isErrorWaveActive: Bool, isCompletionFlashActive: Bool) {
        let gap: CGFloat = 0.5
        let dimension = Self.statusGridDimension
        let cell = (rect.width - gap * CGFloat(dimension - 1)) / CGFloat(dimension)
        let corner = min(1.1, cell * 0.22)
        let litCount = min(max(statusAnimationStep, 0), Self.statusGridCellCount)
        let hasActiveSessions = activeCount > 0

        for index in 0..<Self.statusGridCellCount {
            let row = index / dimension
            let column = index % dimension
            let x = rect.minX + CGFloat(column) * (cell + gap)
            let y = rect.minY + rect.height - cell - CGFloat(row) * (cell + gap)
            let cellRect = NSRect(x: x, y: y, width: cell, height: cell)
            if isErrorWaveActive {
                drawErrorWaveCell(in: cellRect, index: index, corner: corner)
            } else if isCompletionFlashActive {
                drawAmbientGridCell(
                    in: cellRect,
                    index: index,
                    corner: corner,
                    status: .completed
                )
            } else if hasActiveSessions {
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

    private func startCompletionFlashAnimation() {
        completionFlashUntil = Date().addingTimeInterval(completionFlashDuration)
        statusAnimationStep = 0
        ambientGridEffect = .flow
        statusAnimationTimer?.invalidate()
        statusAnimationTimer = nil
        refresh()
    }

    private func isCompletionFlashActive() -> Bool {
        guard let completionFlashUntil else { return false }
        if Date() < completionFlashUntil {
            return true
        }
        self.completionFlashUntil = nil
        return false
    }

    private func startErrorWaveAnimation() {
        errorWaveUntil = Date().addingTimeInterval(errorWaveDuration)
        statusAnimationStep = 0
        ambientGridEffect = .flow
        statusAnimationTimer?.invalidate()
        statusAnimationTimer = nil
        refresh()
    }

    private func isErrorWaveActive() -> Bool {
        guard let errorWaveUntil else { return false }
        if Date() < errorWaveUntil {
            return true
        }
        self.errorWaveUntil = nil
        return false
    }

    private func resetRunningGridAnimation() {
        statusAnimationStep = 0
        statusAnimationCellTones = Self.initialRunningCellTones()
        breathingAnimationPhase = Double.random(in: 0...(Double.pi * 2))
        activeAnimationOffset = 0
        advanceNineGridAnimation()
    }

    private func resetAmbientGridAnimation() {
        statusAnimationStep = 0
        statusAnimationCellTones = Self.initialRunningCellTones()
        breathingAnimationPhase = Double.random(in: 0...(Double.pi * 2))
        activeAnimationOffset = 0
        ambientGridEffect = AmbientGridEffect.random(excluding: ambientGridEffect)
        ambientGridEffectRemainingTicks = ambientGridEffect.durationTicks
    }

    private func advanceNineGridAnimation() {
        if statusAnimationStep >= Self.statusGridCellCount {
            statusAnimationStep = 0
            statusAnimationCellTones = Self.initialRunningCellTones()
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

    private func advanceErrorWaveAnimation() {
        statusAnimationStep += 1
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

    private func drawErrorWaveCell(in rect: NSRect, index: Int, corner: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        let baseColor = NSColor.systemRed.withAlphaComponent(0.18)
        baseColor.setFill()
        path.fill()

        let alpha = errorWaveAlpha(index: index)
        let highlight = NSColor(calibratedRed: 1.0, green: 0.06, blue: 0.04, alpha: min(0.88, alpha))
        NSGradient(colors: [
            baseColor,
            highlight,
            baseColor
        ])?.draw(in: path, angle: -45)
    }

    private func errorWaveAlpha(index: Int) -> CGFloat {
        let row = index / Self.statusGridDimension
        let column = index % Self.statusGridDimension
        let tick = Double(statusAnimationStep)
        // 对角线相位差制造红色波浪，额外脉冲让 5 秒错误态更醒目。
        let diagonal = Double(row + column)
        let wave = (sin(tick * 0.82 - diagonal * 1.35) + 1.0) / 2.0
        let pulse = (sin(tick * 0.45) + 1.0) / 2.0
        return CGFloat(0.16 + pow(wave, 1.7) * 0.64 + pulse * 0.10)
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
        let row = index / Self.statusGridDimension
        let column = index % Self.statusGridDimension
        let tick = Double(statusAnimationStep)

        switch ambientGridEffect {
        case .shimmer:
            let wave = (sin(tick * 0.42 + Double(index) * 1.15) + 1.0) / 2.0
            return CGFloat(0.10 + wave * 0.42)
        case .glow:
            let center = Double(Self.statusGridDimension - 1) / 2.0
            let dx = Double(column) - center
            let dy = Double(row) - center
            let distance = sqrt(dx * dx + dy * dy)
            let wave = (sin(tick * 0.38 - distance * 1.4) + 1.0) / 2.0
            return CGFloat(max(0.05, wave * 0.46 - distance * 0.08))
        case .flow:
            let maxHead = (Self.statusGridDimension - 1) * 2
            let cycle = maxHead * 2
            let phase = statusAnimationStep % max(1, cycle)
            let head = phase <= maxHead ? phase : cycle - phase
            let distance = abs((row + column) - head)
            switch distance {
            case 0: return 0.58
            case 1: return 0.26
            default: return 0.07
            }
        case .marquee:
            let path = Self.statusGridMarqueePath
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
            return NSColor(calibratedRed: 0.62, green: 0.70, blue: 0.78, alpha: 1)
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
        guard store.systemNotificationEnabled else { return }
        if store.completionConfirmationEnabled {
            showCompletionAlert(notice)
            return
        }
        _ = await showSystemNotification(
            title: notice.titleText,
            body: notice.notificationBodyText,
            identifierPrefix: "completion"
        )
    }

    private func presentFailureNotice(_ notice: FailureNotice) async {
        guard store.systemNotificationEnabled else { return }
        if store.errorConfirmationEnabled {
            showFailureAlert(notice)
            return
        }
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

    private func presentProbeSuccessNotice(_ notice: ProbeSuccessNotice) async {
        if await showSystemNotification(
            title: notice.title,
            body: notice.body,
            identifierPrefix: "probe-success"
        ) {
            return
        }
        showNoticeAlert(title: notice.title, body: notice.body, style: .informational)
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

    private func showCompletionAlert(_ notice: CompletionNotice) {
        showNoticeAlert(
            title: notice.titleText,
            body: notice.notificationBodyText,
            style: .informational
        )
    }

    private func showFailureAlert(_ notice: FailureNotice) {
        showNoticeAlert(
            title: notice.titleText,
            body: notice.notificationBodyText,
            style: .critical
        )
    }

    private func showNoticeAlert(title: String, body: String, style: NSAlert.Style) {
        if !NSApp.isActive {
            NSApp.activate()
        }

        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "确定")
        // NSAlert 是系统原生模态弹窗；外部点击只切焦点，不会关闭，必须点按钮结束。
        alert.runModal()
    }

    private var nineGridCanvasSize: NSSize {
        NSSize(width: 16, height: 16)
    }
}
