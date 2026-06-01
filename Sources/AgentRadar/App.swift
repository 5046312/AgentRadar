import AppKit
import Foundation

@main
@MainActor
struct AgentRadarApp {
    static func main() {
        if let exitCode = HookCommandRouter.runIfNeeded() {
            exit(exitCode)
        }
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
