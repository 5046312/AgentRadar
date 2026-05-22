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
                        ForEach(store.sortedSessions, id: \.id) { s in
                            SessionRow(session: s)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 360, height: 420)
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
        HStack {
            Button("打开 ~/.claude") { openClaudeDir() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
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
