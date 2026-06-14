import AppKit
import SwiftUI
import Combine

/// Windowed app: a main window hosts the device dashboard (sidebar + detail), and a menu-bar
/// status item gives quick access + reflects connection state. Dock icon present (.regular).
@main
struct SuperconnectApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)   // Dock icon + main window (was .accessory/menu-bar-only)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let env = AppEnvironment()
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var bag = Set<AnyCancellable>()
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        // Main window hosting the unified dashboard.
        let content = NSHostingController(rootView: DashboardView(vm: env.viewModel))
        let win = NSWindow(contentViewController: content)
        win.title = "Superconnect"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 900, height: 580))
        win.center()
        win.setFrameAutosaveName("SuperconnectMain")
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Menu-bar quick access + state glyph.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Superconnect")
            button.image?.isTemplate = true
            button.action = #selector(showWindow(_:))
            button.target = self
        }

        // Menu-bar glyph reflects whether ANY device is connected (#51 multi-session).
        env.viewModel.$states
            .receive(on: RunLoop.main)
            .sink { [weak self] states in
                let anyConnected = states.values.contains { $0.isConnected }
                let name = anyConnected ? "display.and.arrow.down" : "display"
                let img = NSImage(systemSymbolName: name, accessibilityDescription: "Superconnect")
                img?.isTemplate = true
                self?.statusItem.button?.image = img
            }
            .store(in: &bag)

        // System WAKE → force every live link to rebuild. Across sleep the SCStream dies and the virtual
        // display is invalidated with no error surfaced, so the passive heartbeat is slow/blind to it.
        // Debounce ~1s so the GPU/display subsystem finishes re-enumerating before we recreate a virtual
        // display (else ScreenCapture can't find it in SCShareableContent).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.env.coordinator.reconnectAllForWake()
            }
        }
    }

    @objc private func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-show the window when the Dock icon is clicked with no visible window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        env.coordinator.disconnectAll()
        env.store.stop()
    }

    /// Minimal app menu so Cmd-Q / Hide work in a .regular (non-SwiftUI-lifecycle) app.
    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏 Superconnect", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Superconnect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu

        NSApp.mainMenu = mainMenu
    }
}
