import AppKit
import SwiftUI
import Combine

/// Menu-bar (accessory) entry point: a status item whose popover hosts `RootView`. No
/// dock icon, no auto-start — the user opens the popover, picks a device, and connects.
@main
struct SuperconnectApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let env = AppEnvironment()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Superconnect")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 440)
        popover.contentViewController = NSHostingController(rootView: RootView(vm: env.viewModel))

        // Reflect connection state in the menu-bar glyph.
        env.viewModel.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                let name = state.isConnected ? "display.and.arrow.down" : "display"
                let img = NSImage(systemSymbolName: name, accessibilityDescription: "Superconnect")
                img?.isTemplate = true
                self?.statusItem.button?.image = img
            }
            .store(in: &bag)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.coordinator.disconnect()
        env.store.stop()
    }
}
