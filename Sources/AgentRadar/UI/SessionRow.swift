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
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let branch = session.gitBranch {
                        Text(branch)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    Text(session.status.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: session.status.color))
                }
                if let tool = session.currentTool {
                    Text("→ " + tool)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let txt = session.lastAssistantText, !txt.isEmpty {
                    Text(txt)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(relativeTime(session.lastEventTimestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if session.outputTokens > 0 {
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
