import SwiftUI
import AppKit

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color(nsColor: session.status.color))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let branch = session.gitBranch {
                        Text(branch)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    }
                    Text(primaryTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hasPrimaryTitle ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(session.status.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: session.status.color))
                }
                if let detail = detailText {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(relativeTime(session.lastEventTimestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if session.lastTokenTotal > 0 {
                        Text("\(formatTokens(session.lastTokenTotal)) tokens")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else if session.outputTokens > 0 {
                        Text("\(formatTokens(session.outputTokens)) out")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if session.cacheReadTokens > 0 {
                        Text("\(formatTokens(session.cacheReadTokens)) cache")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
        }
    }

    private var primaryTitle: String {
        // 旧会话可能只有状态和 token；占位文案让行首不再空白。
        titleText ?? "暂无任务内容"
    }

    private var hasPrimaryTitle: Bool {
        titleText != nil
    }

    private var titleText: String? {
        trimmed(session.taskTitle)
            ?? trimmed(session.lastAssistantText)
            ?? trimmed(session.currentTool).map { "→ " + $0 }
    }

    private var detailText: String? {
        if let tool = trimmed(session.currentTool), trimmed(session.taskTitle) != nil || trimmed(session.lastAssistantText) != nil {
            return "→ " + tool
        }
        return nil
    }

    private func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func relativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 1 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
