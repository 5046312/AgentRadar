import Foundation

struct JSONLEntrySummary {
    let timestamp: Date
    let role: String?
    let toolName: String?
    let userText: String?
    let assistantText: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int?
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

        let (lines, lastNewline) = completeLines(in: data)
        let consumed = lastNewline + 1
        let newOffset = offset + UInt64(consumed)
        return (lines, newOffset)
    }

    static func readTailLines(from url: URL, maxLines: Int) -> (lines: [Data], newOffset: UInt64) {
        guard maxLines > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], 0)
        }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return ([], 0)
        }

        let chunkSize: UInt64 = 16 * 1024
        var position = fileSize
        var buffer = Data()
        var newlineCount = 0

        while position > 0 && newlineCount <= maxLines {
            let readSize = min(chunkSize, position)
            position -= readSize
            do {
                try handle.seek(toOffset: position)
            } catch {
                return ([], fileSize)
            }
            guard let chunk = try? handle.read(upToCount: Int(readSize)), !chunk.isEmpty else {
                break
            }
            buffer.insert(contentsOf: chunk, at: 0)
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A {
                    count += 1
                }
            }
        }

        let (parsedLines, _) = completeLines(in: buffer)
        let lines = position > 0 ? Array(parsedLines.dropFirst()) : parsedLines
        if lines.count <= maxLines {
            return (lines, fileSize)
        }
        return (Array(lines.suffix(maxLines)), fileSize)
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

        let text = assistantText?.trimmingCharacters(in: .whitespacesAndNewlines)

        return JSONLEntrySummary(
            timestamp: timestamp,
            role: role,
            toolName: toolName,
            userText: role == "user" ? text : nil,
            assistantText: role == "assistant" ? text : nil,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            totalTokens: nil,
            gitBranch: gitBranch,
            cwd: cwd,
            sessionId: sessionId
        )
    }

    static func parseCodexSummary(_ data: Data) -> JSONLEntrySummary? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        // Codex 状态只信 hook；JSONL 只补项目、文本、工具和 token，避免回到文件增长推断。
        let timestamp = parseTimestamp(obj["timestamp"] as? String) ?? Date()
        let type = obj["type"] as? String
        let payload = obj["payload"] as? [String: Any]

        var role: String?
        var toolName: String?
        var userText: String?
        var assistantText: String?
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var totalTokens: Int?
        var cwd = payload?["cwd"] as? String
        var sessionId = payload?["id"] as? String

        if type == "event_msg", let eventType = payload?["type"] as? String {
            switch eventType {
            case "task_complete":
                assistantText = payload?["last_agent_message"] as? String
            case "token_count":
                if let usage = (payload?["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] {
                    inputTokens = int(usage["input_tokens"])
                    outputTokens = int(usage["output_tokens"])
                    cacheReadTokens = int(usage["cached_input_tokens"])
                    totalTokens = int(usage["total_tokens"])
                }
            case "agent_message":
                role = "assistant"
                assistantText = payload?["message"] as? String
            case "user_message":
                role = "user"
                userText = payload?["message"] as? String
            default:
                break
            }
        }

        if type == "response_item", let itemType = payload?["type"] as? String {
            if itemType == "function_call" {
                toolName = payload?["name"] as? String
            }
            if itemType == "message" {
                role = payload?["role"] as? String
                let text = textContent(from: payload?["content"])
                if role == "user" {
                    userText = text
                } else if role == "assistant" {
                    assistantText = text
                }
            }
        }

        if type == "turn_context" {
            cwd = payload?["cwd"] as? String
        }
        if sessionId == nil {
            sessionId = obj["session_id"] as? String
        }

        return JSONLEntrySummary(
            timestamp: timestamp,
            role: role,
            toolName: toolName,
            userText: userText?.trimmingCharacters(in: .whitespacesAndNewlines),
            assistantText: assistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            totalTokens: totalTokens,
            gitBranch: nil,
            cwd: cwd,
            sessionId: sessionId
        )
    }

    private static func textContent(from value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let content = value as? [[String: Any]] else {
            return nil
        }
        return content.compactMap { item in
            item["text"] as? String
        }.joined(separator: "\n")
    }

    private static func int(_ value: Any?) -> Int {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let numberValue = value as? NSNumber { return numberValue.intValue }
        return 0
    }

    private static func completeLines(in data: Data) -> (lines: [Data], lastNewline: Int) {
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
        return (lines, lastNewline)
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
