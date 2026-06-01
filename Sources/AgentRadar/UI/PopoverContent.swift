import SwiftUI
import AppKit

struct PopoverContent: View {
    @ObservedObject var store: SessionStore
    @StateObject private var hookSetup = HookSetupStore()
    @State private var selectedRuntime: RuntimeKind = .claude
    @State private var showingHelp = false
    @State private var showingSettings = false

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
                            ProjectSection(group: group)
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
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("AgentRadar")
                    .font(.system(size: 13, weight: .semibold))
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("设置")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    HookSettingsView(store: hookSetup)
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
                statusChip(label: "运行 \(count(.running))", color: .green)
                statusChip(label: "等待 \(count(.waiting))", color: .yellow)
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

    private func statusChip(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }

    private func count(_ status: SessionStatus) -> Int {
        store.count(status, runtime: selectedRuntime)
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
}

private struct HookHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使用说明")
                .font(.system(size: 13, weight: .semibold))

            helpRow("安装 hooks", "点齿轮按钮会先预览 diff，确认后再写入；也可以在项目目录执行 ./install-hooks.sh。")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.system(size: 13, weight: .semibold))

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

            Text("安装前会先显示 diff 预览。确认后直接覆盖目标文件，不再备份。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
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
                                    Text(change.diffText)
                                        .textSelection(.enabled)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
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

struct ProjectSection: View {
    let group: ProjectGroup

    @State private var expanded: Bool

    init(group: ProjectGroup) {
        self.group = group
        // 默认只展开有运行中会话的项目
        _expanded = State(initialValue: group.sessions.contains { $0.status == .running })
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(nsColor: group.aggregateStatus.color))
                        .frame(width: 8, height: 8)
                    Text(group.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(group.sessions.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(group.sessions, id: \.id) { s in
                    SessionRow(session: s)
                    Divider().opacity(0.3).padding(.leading, 30)
                }
            }

            Divider().opacity(0.6)
        }
    }
}
