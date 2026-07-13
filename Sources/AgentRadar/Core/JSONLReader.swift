import Foundation

struct JSONLEntrySummary {
    let timestamp: Date
    let cwd: String?
}

enum CodexTranscriptStatusEvent {
    case started(turnId: String?)
    case interrupted
    case failed
}

enum CodexTurnOutcome: Equatable {
    case completed
    case interrupted
    case failed
    case pending
}

enum JSONLReader {
    private struct CodexTurnOutcomeScan {
        let outcome: CodexTurnOutcome
        let needsFullScan: Bool
    }

    private static let codexOutcomeTailBytes: UInt64 = 2 * 1024 * 1024

    private struct CodexSessionIndexEntry: Decodable {
        let id: String
        let thread_name: String?
    }

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

        let completeResult = completeLines(in: data)
        var lines = completeResult.lines
        if shouldDropFirstLine, !lines.isEmpty {
            // 尾读可能从一行中间开始，丢掉半截 JSON，避免启动阶段解码失败刷无效工作。
            lines.removeFirst()
        }
        // 最后一行可能仍在写入，offset 必须停在最后一个完整换行后，避免永久漏掉半行 JSON。
        let consumed = max(0, completeResult.lastNewline + 1)
        return (lines, startOffset + UInt64(consumed))
    }

    static func readInitialLines(from url: URL, maxBytes: UInt64) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: Int(maxBytes)), !data.isEmpty else {
            return []
        }
        return completeLines(in: data).lines
    }

    static func readCodexThreadNames(from url: URL) -> [String: String] {
        guard
            let text = try? String(contentsOf: url, encoding: .utf8),
            !text.isEmpty
        else {
            return [:]
        }

        var result: [String: String] = [:]
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            guard
                let entry = try? decoder.decode(CodexSessionIndexEntry.self, from: Data(line.utf8)),
                let threadName = stringValue(entry.thread_name),
                !threadName.isEmpty
            else {
                continue
            }
            // Codex 会在首次消息后写入自动标题；同一 id 若后写更新，列表展示最后一次标题。
            result[entry.id] = threadName
        }
        return result
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
        // Codex 完成只由 Stop hook 触发；这里先统一补时间和 cwd，非完成状态兜底单独解析 event_msg。
        let type = obj["type"] as? String
        let payload = obj["payload"] as? [String: Any]
        let timestamp = parseCodexTimestamp(type: type, payload: payload, fallback: obj["timestamp"] as? String) ?? Date()

        var cwd = payload?["cwd"] as? String

        if type == "turn_context" {
            cwd = payload?["cwd"] as? String
        }

        return JSONLEntrySummary(
            timestamp: timestamp,
            cwd: cwd
        )
    }

    static func parseCodexStatusEvent(_ data: Data) -> CodexTranscriptStatusEvent? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            obj["type"] as? String == "event_msg",
            let payload = obj["payload"] as? [String: Any],
            let eventType = payload["type"] as? String
        else {
            return nil
        }

        switch eventType {
        case "task_started":
            return .started(turnId: stringValue(payload["turn_id"]))
        case "task_complete":
            // 完成状态必须只走 Stop hook，避免 transcript 补写绕过 hook 触发完成。
            return nil
        case "turn_aborted":
            // interrupted 是用户主动 stop / retry；其余中断原因仍按失败处理。
            return isUserCancellationReason(payload["reason"]) ? .interrupted : .failed
        default:
            return nil
        }
    }

    static func codexTurnOutcome(at url: URL, turnId: String, startedAt: Date? = nil) -> CodexTurnOutcome {
        let recentLines = readRecentLines(from: url, maxBytes: codexOutcomeTailBytes).lines
        let recentScan = scanCodexTurnOutcome(in: recentLines, turnId: turnId, startedAt: startedAt)
        guard recentScan.outcome == .pending else {
            return recentScan.outcome
        }

        guard
            recentScan.needsFullScan,
            (fileSize(at: url) ?? 0) > codexOutcomeTailBytes
        else {
            return .pending
        }

        // Review 模式可能使用不同 turn_id；仅遇到相关终止事件时退回全量扫描。
        let fullLines = readNewLines(from: url, startingAt: 0).lines
        return scanCodexTurnOutcome(in: fullLines, turnId: turnId, startedAt: startedAt).outcome
    }

    private static func scanCodexTurnOutcome(in lines: [Data], turnId: String, startedAt: Date?) -> CodexTurnOutcomeScan {
        guard !lines.isEmpty else {
            return CodexTurnOutcomeScan(outcome: .pending, needsFullScan: false)
        }

        var isInReviewMode = false
        var didSeeRequestedTurnStart = false
        var requestedTurnAllowsMismatchedTerminal = false
        var sawRelevantMismatchedTerminal = false
        for line in lines {
            guard
                let obj = try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any],
                obj["type"] as? String == "event_msg",
                let payload = obj["payload"] as? [String: Any],
                let eventType = payload["type"] as? String
            else {
                continue
            }

            let eventTurnId = payload["turn_id"] as? String
            switch eventType {
            case "entered_review_mode":
                isInReviewMode = true
            case "exited_review_mode":
                isInReviewMode = false
            case "task_started":
                if eventTurnId == turnId {
                    didSeeRequestedTurnStart = true
                    requestedTurnAllowsMismatchedTerminal = isInReviewMode
                    continue
                }
                if didSeeRequestedTurnStart {
                    return CodexTurnOutcomeScan(outcome: .pending, needsFullScan: false)
                }
            case "task_complete":
                if eventTurnId == turnId {
                    return CodexTurnOutcomeScan(outcome: .completed, needsFullScan: false)
                }
                // Review 模式会把完成事件写成另一个 turn_id；普通任务仍必须精确匹配，避免误收真正运行中的任务。
                let isRelevantTerminal = isTerminalEventValidForRequestedTurn(payload: payload, startedAt: startedAt)
                if didSeeRequestedTurnStart && requestedTurnAllowsMismatchedTerminal && isRelevantTerminal {
                    return CodexTurnOutcomeScan(outcome: .completed, needsFullScan: false)
                }
                sawRelevantMismatchedTerminal = sawRelevantMismatchedTerminal || isRelevantTerminal
            case "turn_aborted":
                // interrupted 是用户主动打断；其他终止原因都按失败处理。
                let outcome: CodexTurnOutcome = isUserCancellationReason(payload["reason"]) ? .interrupted : .failed
                if eventTurnId == turnId {
                    return CodexTurnOutcomeScan(outcome: outcome, needsFullScan: false)
                }
                let isRelevantTerminal = isTerminalEventValidForRequestedTurn(payload: payload, startedAt: startedAt)
                if didSeeRequestedTurnStart && requestedTurnAllowsMismatchedTerminal && isRelevantTerminal {
                    return CodexTurnOutcomeScan(outcome: outcome, needsFullScan: false)
                }
                sawRelevantMismatchedTerminal = sawRelevantMismatchedTerminal || isRelevantTerminal
            default:
                continue
            }
        }

        return CodexTurnOutcomeScan(outcome: .pending, needsFullScan: sawRelevantMismatchedTerminal)
    }

    static func codexApprovalsReviewerIsAutoReview(at url: URL) -> Bool {
        let lines = readInitialLines(from: url, maxBytes: 1024 * 1024)
        for line in lines {
            if codexApprovalsReviewerIsAutoReview(in: line) {
                return true
            }
        }
        return false
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

    private static func codexApprovalsReviewerIsAutoReview(in data: Data) -> Bool {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let type = obj["type"] as? String,
            let payload = obj["payload"] as? [String: Any]
        else {
            return false
        }

        if type == "turn_context" {
            return stringValue(payload["approvals_reviewer"]) == "auto_review"
        }

        guard
            type == "response_item",
            payload["role"] as? String == "developer",
            let content = payload["content"] as? [[String: Any]]
        else {
            return false
        }

        // 当前 Codex 把 auto review 写在 developer 权限说明里，还没有稳定同步到 hook payload。
        return content.contains { item in
            guard let text = item["text"] as? String else { return false }
            return text.contains("approvals_reviewer") && text.contains("auto_review")
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUserCancellationReason(_ value: Any?) -> Bool {
        guard let reason = stringValue(value)?.lowercased(), !reason.isEmpty else {
            return false
        }
        // Codex 不同版本的取消 reason 文案不完全一致；只收敛用户取消/中断，不吞真正失败。
        return reason == "interrupted"
            || reason.contains("cancel")
            || reason.contains("interrupt")
    }

    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        if let d = fractionalTimestampFormatter.date(from: s) { return d }
        return internetTimestampFormatter.date(from: s)
    }

    private static func parseCodexTimestamp(type: String?, payload: [String: Any]?, fallback: String?) -> Date? {
        guard type == "event_msg", let payload else {
            return parseTimestamp(fallback)
        }

        // Codex event_msg 没有顶层 timestamp；不用 payload 时间会把历史补读误判成“现在发生”。
        if let startedAt = unixTimestamp(payload["started_at"]) {
            return startedAt
        }
        if let completedAt = unixTimestamp(payload["completed_at"]) {
            return completedAt
        }
        return parseTimestamp(fallback)
    }

    private static func unixTimestamp(_ value: Any?) -> Date? {
        if let value = value as? TimeInterval {
            return Date(timeIntervalSince1970: value)
        }
        if let value = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    private static func isTerminalEventValidForRequestedTurn(payload: [String: Any], startedAt: Date?) -> Bool {
        guard let startedAt else { return true }
        guard let completedAt = unixTimestamp(payload["completed_at"]) else {
            return false
        }
        return completedAt >= startedAt
    }

    private static func fileSize(at url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value
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
