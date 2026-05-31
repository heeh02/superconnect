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
}
