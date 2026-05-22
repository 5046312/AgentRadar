import SwiftUI
import AppKit

struct PopoverContent: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.sessions.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.projectGroups) { group in
                            ProjectSection(group: group)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 440)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AgentRadar")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            statusChip(label: "运行 \(count(.running))", color: .green)
            statusChip(label: "等待 \(count(.waiting))", color: .yellow)
            statusChip(label: "完成 \(count(.completed))", color: .gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("尚无 Claude Code 会话")
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

            Button("打开 ~/.claude") { openClaudeDir() }
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

    private func statusChip(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }

    private func count(_ status: SessionStatus) -> Int {
        store.sessions.values.filter { $0.status == status }.count
    }

    private func openClaudeDir() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        NSWorkspace.shared.open(url)
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
