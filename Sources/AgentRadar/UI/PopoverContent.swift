import SwiftUI
import AppKit

struct PopoverContent: View {
    @ObservedObject var store: SessionStore
    @State private var selectedRuntime: RuntimeKind = .claude
    @State private var showingHelp = false

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

            helpRow("安装 hooks", "在项目目录执行 ./install-hooks.sh，会同时配置 Claude 和 Codex。")
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
