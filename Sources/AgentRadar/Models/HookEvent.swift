import Foundation

// Claude 旧事件没有 runtime 字段，读取时会按 Claude 兼容处理。
struct HookEvent: Decodable {
    let event: String
    let ts: Double
    let runtime: RuntimeKind?
    let session_id: String?
    let cwd: String?
}
