import Foundation

struct HookEvent: Decodable {
    let event: String
    let ts: Double
    let session_id: String?
    let cwd: String?
}
