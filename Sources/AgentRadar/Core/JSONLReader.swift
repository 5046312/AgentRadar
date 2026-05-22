import Foundation

struct JSONLEntrySummary {
    let timestamp: Date
    let role: String?
    let stopReason: String?
    let toolName: String?
    let assistantText: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let gitBranch: String?
    let cwd: String?
    let sessionId: String?
}

enum JSONLReader {
    static func readNewLines(from url: URL, startingAt offset: UInt64) -> (lines: [Data], newOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], offset)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return ([], offset)
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return ([], offset)
        }

        var lines: [Data] = []
        var lastNewline = -1
        let bytes = [UInt8](data)
        for (i, b) in bytes.enumerated() {
            if b == 0x0A {
                let start = lastNewline + 1
                if i > start {
                    lines.append(Data(bytes[start..<i]))
                }
                lastNewline = i
            }
        }
        let consumed = lastNewline + 1
        let newOffset = offset + UInt64(consumed)
        return (lines, newOffset)
    }

    static func parseSummary(_ data: Data) -> JSONLEntrySummary? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        let timestamp = parseTimestamp(obj["timestamp"] as? String) ?? Date()
        let cwd = obj["cwd"] as? String
        let gitBranch = obj["gitBranch"] as? String
        let sessionId = obj["sessionId"] as? String

        let message = obj["message"] as? [String: Any]
        let role = message?["role"] as? String
        let stopReason = message?["stop_reason"] as? String

        var toolName: String?
        var assistantText: String?

        if let content = message?["content"] as? [[String: Any]] {
            for item in content.reversed() {
                if let type = item["type"] as? String {
                    if type == "tool_use", toolName == nil {
                        toolName = item["name"] as? String
                    }
                    if type == "text", assistantText == nil {
                        assistantText = item["text"] as? String
                    }
                }
            }
        } else if let textContent = message?["content"] as? String {
            assistantText = textContent
        }

        let usage = message?["usage"] as? [String: Any]
        let inputTokens = (usage?["input_tokens"] as? Int) ?? 0
        let outputTokens = (usage?["output_tokens"] as? Int) ?? 0
        let cacheRead = (usage?["cache_read_input_tokens"] as? Int) ?? 0

        return JSONLEntrySummary(
            timestamp: timestamp,
            role: role,
            stopReason: stopReason,
            toolName: toolName,
            assistantText: assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            gitBranch: gitBranch,
            cwd: cwd,
            sessionId: sessionId
        )
    }

    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
