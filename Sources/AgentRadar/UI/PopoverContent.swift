import Foundation
import SwiftUI
import AppKit
import UserNotifications

struct PopoverContent: View {
    @ObservedObject var store: SessionStore
    @StateObject private var hookSetup = HookSetupStore()
    @State private var selectedRuntime: RuntimeKind = .claude
    @State private var showingHelp = false
    @State private var showingSettings = false
    @State private var now = Date()
    @State private var clockTimer: Timer?
    @State private var clockTimerInterval: TimeInterval?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !store.hasSessions(runtime: selectedRuntime) {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.projectGroups(runtime: selectedRuntime)) { group in
                            ProjectSection(group: group, now: now)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 440)
        // 弹窗内操作以鼠标为主，统一关掉按钮获得焦点时的系统光环。
        .focusEffectDisabled()
        .onAppear {
            syncClockTimer()
        }
        .onDisappear {
            stopClockTimer()
        }
        .onChange(of: selectedRuntime) { _, _ in
            syncClockTimer()
        }
        .onReceive(store.$version) { _ in
            syncClockTimer()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("AgentRadar")
                    .font(.system(size: 13, weight: .semibold))
                if !hookSetup.state.allInstalled {
                    Text("未设置 Hooks")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                }
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("设置")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    HookSettingsView(store: hookSetup, sessionStore: store)
                }
                Button(action: { showingHelp = true }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("使用说明")
                .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                    HookHelpView()
                }
                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(RuntimeKind.allCases) { runtime in
                    runtimeTab(runtime)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: selectedRuntime.iconName)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("尚无 \(selectedRuntime.displayName) 会话")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: { store.toggleSound() }) {
                HStack(spacing: 4) {
                    Image(systemName: store.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    Text(store.soundEnabled ? "音效开" : "音效关")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(store.soundEnabled ? .primary : .secondary)

            Spacer()

            Button("打开 \(runtimeDirLabel)") { openRuntimeDir() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func runtimeTab(_ runtime: RuntimeKind) -> some View {
        let selected = runtime == selectedRuntime
        let runningCount = store.count(.running, runtime: runtime)
        return Button(action: { selectedRuntime = runtime }) {
            HStack(spacing: 5) {
                Image(systemName: runtime.iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(runtime.displayName)
                    .font(.system(size: 11, weight: .semibold))
                // 切换按钮显示各 runtime 自己的运行数，避免跨 runtime 时误判当前忙碌来源。
                if runningCount > 0 {
                    Text("\(runningCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 14)
                        .frame(height: 14)
                        .background(Color.green, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(
                selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
    }

    private var runtimeDirLabel: String {
        switch selectedRuntime {
        case .claude: return "~/.claude"
        case .codex:  return "~/.codex"
        }
    }

    private func openRuntimeDir() {
        let url: URL
        switch selectedRuntime {
        case .claude:
            url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        case .codex:
            url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        NSWorkspace.shared.open(url)
    }

    private func syncClockTimer() {
        guard let interval = clockInterval else {
            stopClockTimer()
            return
        }
        startClockTimer(interval: interval)
    }

    private var clockInterval: TimeInterval? {
        if store.count(.running, runtime: selectedRuntime) > 0 {
            return 1.0
        }
        if store.hasCurrentRunCompletion(runtime: selectedRuntime) {
            return 60.0
        }
        return nil
    }

    private func startClockTimer(interval: TimeInterval) {
        guard clockTimer == nil || clockTimerInterval != interval else { return }
        stopClockTimer()
        now = Date()
        // 运行计时秒级刷新；完成后的相对时间只需分钟级刷新，避免空闲时后台空转。
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            now = Date()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
        clockTimerInterval = interval
    }

    private func stopClockTimer() {
        clockTimer?.invalidate()
        clockTimer = nil
        clockTimerInterval = nil
    }
}

private struct HookHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使用说明")
                .font(.system(size: 13, weight: .semibold))

            helpRow("安装 hooks", "点齿轮按钮会先预览 diff，确认后再写入；重启当前 Claude/Codex 会话后才生效。")
            helpRow("Codex 状态", "Codex 的运行、等待输入、完成状态来自 hooks，不再靠 session 文件增长猜测。")
            helpRow("首次信任", "Codex 下次启动可能要求 Review hooks，选择信任后状态才会写入。")
            helpRow("事件文件", "所有事件写入 ~/.agentradar/events.jsonl，AgentRadar 只读本机文件。")
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func helpRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HookSettingsView: View {
    @ObservedObject var store: HookSetupStore
    @ObservedObject var sessionStore: SessionStore
    @State private var notificationMessage: String?
    @State private var notificationErrorMessage: String?
    @State private var intervalVariationText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.system(size: 13, weight: .semibold))

            settingsSection("Hooks") {
                statusRow("Claude hooks", store.state.claudeInstalled)
                statusRow("Codex features.hooks", store.state.codexFeatureEnabled)
                statusRow("Codex hooks.json", store.state.codexHooksInstalled)
                statusRow("事件文件", store.state.eventsFileExists)

                if let message = store.lastMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(store.state.allInstalled ? "重装 Hooks" : "安装 Hooks") {
                        store.prepareInstallPreview()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isApplying)

                    Button("重新检查") {
                        store.refresh()
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isApplying)
                }
            }

            settingsSection("系统通知") {
                if let notificationErrorMessage {
                    Text(notificationErrorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let notificationMessage {
                    Text(notificationMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("任务完成、失败和等待确认都会通过 macOS 系统通知提醒。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("请求通知权限") {
                        Task { @MainActor in
                            await requestNotificationAuthorization()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("打开系统通知设置") {
                        openSystemNotificationSettings()
                    }
                    .buttonStyle(.bordered)

                    Button("测试") {
                        Task { @MainActor in
                            await sendTestNotification()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            settingsSection("九宫格速度") {
                Slider(
                    value: nineGridAnimationIntervalBinding,
                    in: SessionStore.minNineGridAnimationInterval...SessionStore.maxNineGridAnimationInterval,
                    step: 0.05
                ) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("快")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("慢")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("九宫格速度")

                Text(nineGridAnimationDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("间隔浮动比例")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    TextField("50", text: intervalVariationTextBinding)
                        .font(.system(size: 11, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 54)
                    Text("%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(nineGridVariationDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .sheet(
            isPresented: Binding(
                get: { store.pendingPlan != nil },
                set: { presented in
                    if !presented {
                        store.dismissInstallPreview()
                    }
                }
            )
        ) {
            if let pendingPlan = store.pendingPlan {
                HookInstallPreviewSheet(store: store, plan: pendingPlan)
            }
        }
        .onAppear {
            syncIntervalVariationText()
        }
        .onReceive(sessionStore.$nineGridIntervalVariationPercent) { _ in
            syncIntervalVariationText()
        }
    }

    private var nineGridAnimationIntervalBinding: Binding<Double> {
        Binding(
            get: { sessionStore.nineGridAnimationInterval },
            set: { newValue in
                sessionStore.setNineGridAnimationInterval(newValue)
            }
        )
    }

    private var intervalVariationTextBinding: Binding<String> {
        Binding(
            get: { intervalVariationText },
            set: { newValue in
                let filtered = numericText(from: newValue)
                intervalVariationText = filtered
                guard let value = Double(filtered) else { return }
                sessionStore.setNineGridIntervalVariationPercent(value)
            }
        )
    }

    private var nineGridAnimationDescription: String {
        "当前 \(formatInterval(sessionStore.nineGridAnimationInterval)) 秒/格，可在 \(formatInterval(SessionStore.minNineGridAnimationInterval)) 到 \(formatInterval(SessionStore.maxNineGridAnimationInterval)) 秒之间调整。"
    }

    private var nineGridVariationDescription: String {
        "当前左右浮动 ±\(formatPercent(sessionStore.nineGridIntervalVariationPercent))%，可填 0 到 100 的数字。"
    }

    private func requestNotificationAuthorization() async {
        notificationMessage = nil
        notificationErrorMessage = nil

        // 用户明确点击后才申请系统通知权限，避免打开设置页时直接弹系统授权框。
        if await sessionStore.requestSystemNotificationAuthorization() {
            notificationMessage = "系统通知已开启。"
        } else {
            notificationErrorMessage = "系统通知未授权，请到系统设置 > 通知开启 AgentRadar。"
        }
    }

    private func openSystemNotificationSettings() {
        notificationMessage = nil
        notificationErrorMessage = nil
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.long.agentradar"
        let encodedBundleIdentifier = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleIdentifier
        let urlTexts = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(encodedBundleIdentifier)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for text in urlTexts {
            guard let url = URL(string: text) else { continue }
            // macOS 不同版本通知面板 URL 不完全一致，先尝试定位到本 App，再退回通知总页。
            if NSWorkspace.shared.open(url) {
                notificationMessage = "已打开系统通知设置。"
                return
            }
        }
        notificationErrorMessage = "无法打开系统通知设置。"
    }

    private func sendTestNotification() async {
        notificationMessage = nil
        notificationErrorMessage = nil

        guard await sessionStore.canDeliverSystemNotification() else {
            notificationErrorMessage = "系统通知未授权，请先请求权限或到系统设置开启 AgentRadar。"
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "AgentRadar 测试提醒"
        content.body = "这是一条系统通知示例。"
        let request = UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        let delivered = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
        if delivered {
            notificationMessage = "测试通知已发送。"
        } else {
            notificationErrorMessage = "测试通知发送失败。"
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusRow(_ title: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Text(ok ? "OK" : "未安装")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func formatInterval(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func syncIntervalVariationText() {
        intervalVariationText = formatPercent(sessionStore.nineGridIntervalVariationPercent)
    }

    private func numericText(from value: String) -> String {
        value.filter { character in
            character.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
        }
    }
}

private struct HookInstallPreviewSheet: View {
    @ObservedObject var store: HookSetupStore
    let plan: HookInstallPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认 Hooks 变更")
                .font(.system(size: 14, weight: .semibold))

            Text("确认后直接覆盖目标文件，不再备份。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if plan.createsEventsFile {
                Text("将创建空文件：~/.agentradar/events.jsonl")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if plan.changes.isEmpty {
                Spacer()
                Text("本次仅创建事件文件。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.changes) { change in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(change.displayPath)
                                    .font(.system(size: 11, weight: .semibold))

                                ScrollView(.horizontal) {
                                    HookDiffBlockView(lines: change.diffLines)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()

                Button("取消") {
                    store.dismissInstallPreview()
                }
                .buttonStyle(.bordered)
                .disabled(store.isApplying)

                Button("确认写入") {
                    store.applyPendingPlan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isApplying)
            }
        }
        .padding(16)
        .frame(width: 700, height: 520, alignment: .topLeading)
    }
}

private struct HookDiffBlockView: View {
    let lines: [HookDiffLine]

    var body: some View {
        // 纯 Text 很难做增删行着色，按行渲染才能接近编辑器里的 diff 观感。
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HookDiffLineView(line: line)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 8)
    }
}

private struct HookDiffLineView: View {
    let line: HookDiffLine

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)

            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
    }

    private var foregroundColor: Color {
        switch line.kind {
        case .header:
            return .secondary
        case .context:
            return .primary
        case .addition:
            return Color(nsColor: .systemGreen)
        case .deletion:
            return Color(nsColor: .systemRed)
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .header:
            return Color.secondary.opacity(0.08)
        case .context:
            return .clear
        case .addition:
            return Color(nsColor: .systemGreen).opacity(0.14)
        case .deletion:
            return Color(nsColor: .systemRed).opacity(0.14)
        }
    }

    private var accentColor: Color {
        switch line.kind {
        case .header:
            return Color.secondary.opacity(0.25)
        case .context:
            return .clear
        case .addition:
            return Color(nsColor: .systemGreen)
        case .deletion:
            return Color(nsColor: .systemRed)
        }
    }
}

struct ProjectSection: View {
    let group: ProjectGroup
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            projectHeader

            if group.shouldShowTaskRows {
                VStack(spacing: 0) {
                    ForEach(group.visibleTaskSessions) { session in
                        SessionTaskRow(
                            session: session,
                            taskNumber: taskNumber(for: session),
                            now: now
                        )
                    }
                }
                .padding(.bottom, 4)
            }

            Divider().opacity(0.6)
        }
    }

    private var projectHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: group.aggregateStatus.color))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(group.statusLabel(now: now))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(statusTextColor(group.aggregateStatus))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func taskNumber(for session: Session) -> Int {
        (group.visibleTaskSessions.firstIndex { $0.id == session.id } ?? 0) + 1
    }
}

private struct SessionTaskRow: View {
    let session: Session
    let taskNumber: Int
    let now: Date

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: session.status.color))
                .frame(width: 6, height: 6)
            Text(session.taskName ?? "任务 \(taskNumber)")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(session.statusLabel(now: now))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
                .foregroundStyle(statusTextColor(session.status))
        }
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        // 子行只在同一项目有多个未结束任务时出现，计时必须跟随各自 session。
        .background(Color.secondary.opacity(0.05))
    }
}

private let idleStatusTextColor = Color(red: 191.0 / 255.0, green: 191.0 / 255.0, blue: 191.0 / 255.0)

private func statusTextColor(_ status: SessionStatus) -> Color {
    status == .idle ? idleStatusTextColor : Color(nsColor: status.color)
}
