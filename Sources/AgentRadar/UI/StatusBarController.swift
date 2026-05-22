import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController {
    private let store: SessionStore
    private let statusItem: NSStatusItem
    private let trafficLight: TrafficLightView
    private let popover: NSPopover
    private var eventMonitor: Any?
    private var cancellable: AnyCancellable?

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.trafficLight = TrafficLightView(frame: NSRect(x: 0, y: 0, width: 56, height: 22))
        self.popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.contentViewController = NSHostingController(rootView: PopoverContent(store: store))

        if let button = statusItem.button {
            button.frame = NSRect(x: 0, y: 0, width: 56, height: 22)
            button.addSubview(trafficLight)
            trafficLight.frame = button.bounds
            trafficLight.autoresizingMask = [.width, .height]
            trafficLight.statusItem = statusItem
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        cancellable = store.$version.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func refresh() {
        trafficLight.update(status: store.aggregateStatus, activeCount: store.activeCount)
    }
}
