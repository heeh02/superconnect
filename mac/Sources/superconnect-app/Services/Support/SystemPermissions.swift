import Foundation
import SuperconnectProducer

/// Permission gates, keyed by role so the future receiver can declare different (or no)
/// requirements. Hosting needs Screen Recording (to capture) + Accessibility (to inject
/// the tablet's input back). Returns the `AppError` to surface as `.needsPermission`, or
/// nil when all gates are satisfied. Requesting the grant (which opens System Settings)
/// is triggered as a side-effect when a gate is missing.
enum SystemPermissions {
    static func preflight(for role: Role) -> AppError? {
        switch role {
        case .host:
            if !ScreenCapture.hasScreenRecordingPermission() {
                ScreenCapture.requestScreenRecordingPermission()
                return .needsScreenRecording
            }
            if !InputInjector.hasAccessibilityPermission() {
                InputInjector.requestAccessibilityPermission()
                return .needsAccessibility
            }
            return nil
        case .receiver:
            // A future receiver only displays a stream — no capture/inject gates today.
            return nil
        }
    }

    /// Read-only status (no prompts / no side effects) for the GUI's permissions section.
    static func hostStatus() -> (screenRecording: Bool, accessibility: Bool) {
        (ScreenCapture.hasScreenRecordingPermission(), InputInjector.hasAccessibilityPermission())
    }

    /// Trigger the grant flow (opens System Settings panes) for whatever host gates are missing.
    static func requestHost() {
        if !ScreenCapture.hasScreenRecordingPermission() { ScreenCapture.requestScreenRecordingPermission() }
        if !InputInjector.hasAccessibilityPermission() { InputInjector.requestAccessibilityPermission() }
    }

    /// Reset THIS app's Accessibility (input-injection) grant and re-prompt. For the rare stale-TCC case
    /// where the toggle shows authorized but `CGEventPost` is inert. The free app isn't sandboxed, so it
    /// may spawn `tccutil`; resetting its OWN bundle id needs no extra privilege. Re-prompts afterward so
    /// macOS re-evaluates the current binary (then the user re-ticks it in System Settings if asked).
    static func resetAccessibility() {
        let bid = Bundle.main.bundleIdentifier ?? "com.superconnect.free"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", bid]
        try? p.run()
        p.waitUntilExit()
        InputInjector.requestAccessibilityPermission()
    }
}
