import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = SessionStore()
    private var statusBar: StatusBarController?
    private var monitor: SessionMonitor?
    private var hookReader: HookEventReader?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 设置页里点“测试”时 App 仍在前台；不显式允许，macOS 会静默吞掉横幅。
        completionHandler([.banner, .list, .sound])
    }
}
