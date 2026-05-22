import AppKit

@main
@MainActor
struct AgentRadarApp {
    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
