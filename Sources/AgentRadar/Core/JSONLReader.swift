import Foundation

struct JSONLEntrySummary {
    let timestamp: Date
    let cwd: String?
}

enum CodexTurnOutcome {
    case completed
    case interrupted
    case failed
    case pending
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

    static func readRecentLines(from url: URL, maxBytes: UInt64) -> (lines: [Data], newOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], 0)
        }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return ([], 0)
        }

        let startOffset = fileSize > maxBytes ? fileSize - maxBytes : 0
        var shouldDropFirstLine = false
        if startOffset > 0 {
            do {
                try handle.seek(toOffset: startOffset - 1)
                let previousByte = try handle.read(upToCount: 1)
                shouldDropFirstLine = previousByte?.first != 0x0A
            } catch {
                shouldDropFirstLine = true
            }
        }

        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return ([], fileSize)
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return ([], fileSize)
        }

        var lines = completeLines(in: data).lines
        if shouldDropFirstLine, !lines.isEmpty {
            // 尾读可能从一行中间开始，丢掉半截 JSON，避免启动阶段解码失败刷无效工作。
            lines.removeFirst()
        }
        return (lines, fileSize)
    }

    static func parseSummary(_ data: Data) -> JSONLEntrySummary? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        let timestamp = parseTimestamp(obj["timestamp"] as? String) ?? Date()
        let cwd = obj["cwd"] as? String

        return JSONLEntrySummary(
            timestamp: timestamp,
            cwd: cwd
        )
    }

    static func parseCodexSummary(_ data: Data) -> JSONLEntrySummary? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        // Codex 状态只信 hook；JSONL 只补项目路径，避免回到文件增长推断。
        let timestamp = parseTimestamp(obj["timestamp"] as? String) ?? Date()
        let type = obj["type"] as? String
        let payload = obj["payload"] as? [String: Any]

        var cwd = payload?["cwd"] as? String

        if type == "turn_context" {
            cwd = payload?["cwd"] as? String
        }

        return JSONLEntrySummary(
            timestamp: timestamp,
            cwd: cwd
        )
    }

    static func codexTurnOutcome(at url: URL, turnId: String) -> CodexTurnOutcome {
        let readResult = readNewLines(from: url, startingAt: 0)
        guard !readResult.lines.isEmpty else {
            return .pending
        }

        for line in readResult.lines {
            guard
                let obj = try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any],
                obj["type"] as? String == "event_msg",
                let payload = obj["payload"] as? [String: Any],
                payload["turn_id"] as? String == turnId,
                let eventType = payload["type"] as? String
            else {
                continue
            }

            switch eventType {
            case "task_complete":
                return .completed
            case "turn_aborted":
                // interrupted 是用户主动打断；其他终止原因都按失败处理。
                return (payload["reason"] as? String) == "interrupted" ? .interrupted : .failed
            default:
                continue
            }
        }

        return .pending
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
        if let d = fractionalTimestampFormatter.date(from: s) { return d }
        return internetTimestampFormatter.date(from: s)
    }

    private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
