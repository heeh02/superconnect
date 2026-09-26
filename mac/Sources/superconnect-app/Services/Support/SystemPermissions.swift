import Foundation
import SuperconnectProducer

/// Viewing needs Screen Recording. Optional tablet control requests Accessibility separately.
enum SystemPermissions {
    static func preflight(for role: Role) -> AppError? {
        switch role {
        case .host:
            if !ScreenCapture.hasScreenRecordingPermission() {
                ScreenCapture.requestScreenRecordingPermission()
                return .needsScreenRecording
            }
            return nil
        case .receiver:
            // A future receiver only displays a stream — no capture/inject gates today.
            return nil
        }
    }

    /// Read-only status (no prompts / no side effects) for the GUI's permissions section.
    static func hostStatus() -> Bool {
        ScreenCapture.hasScreenRecordingPermission()
    }

    /// Trigger the grant flow (opens System Settings panes) for whatever host gates are missing.
    static func requestHost() {
        if !ScreenCapture.hasScreenRecordingPermission() { ScreenCapture.requestScreenRecordingPermission() }
    }
}
