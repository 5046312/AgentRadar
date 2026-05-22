import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var statusBar: StatusBarController?
    private var monitor: SessionMonitor?
    private var hookReader: HookEventReader?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(store: store)
        monitor = SessionMonitor(store: store)
        hookReader = HookEventReader(store: store)
        monitor?.start()
        hookReader?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        hookReader?.stop()
    }
}
