import Foundation

enum LoopOutputParser {
    static func lastAgentMessage(in output: String) -> String? {
        var lastMessage: String?

        for line in output.split(whereSeparator: \.isNewline) {
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "item.completed",
                let item = object["item"] as? [String: Any],
                item["type"] as? String == "agent_message",
                let text = item["text"] as? String
            else {
                continue
            }

            // Codex 可能输出多条 agent_message；测试结果只取最后一次完整回复。
            lastMessage = text
        }

        return lastMessage
    }

    static func completeFailureOutput(standardOutput: String, standardError: String) -> String {
        guard !standardOutput.isEmpty else { return standardError }
        guard !standardError.isEmpty else { return standardOutput }
        return standardOutput + (standardOutput.hasSuffix("\n") ? "" : "\n") + standardError
    }
}
