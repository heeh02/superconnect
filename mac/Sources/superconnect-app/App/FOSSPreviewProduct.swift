import Foundation
import SuperconnectCore

enum FOSSPreviewProduct {
    static let appName = "Superconnect FOSS Preview"
    static let bundleIdentifier = "com.superconnect.foss.preview"
    static let executableName = "superconnect-app-foss-preview"
    static let shortVersion = "0.2.1"
    static let buildVersion = "3"
    static let keychainService = "com.superconnect.foss.preview.pairing.secret.v2"
    static let localIdentityDefaultsKey = "com.superconnect.foss.preview.local-peer-id.v2"
    static let inputPolicy = CollaborationInputPolicy.remoteControl
    static let projection = ProjectionMode.extend
    static let transport = CollaborationTransportPreference.reliable
    static let requiresAccessibility = false
}
