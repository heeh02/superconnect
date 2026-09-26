import Foundation

extension Session {
    /// Build the established hello CONTROL value. Key generation and JSON transmission are platform
    /// effects; capability decisions remain in the Rust reducers selected after hello_ack.
    func sendHello(publicKey suppliedPublicKey: Data? = nil) {
        // Always offer a fresh ephemeral key because peer identity is learned only in hello_ack.
        let publicKey: Data
        if let suppliedPublicKey {
            publicKey = suppliedPublicKey
        } else {
            let privateScalar = AuthCrypto.newEphemeralPrivateScalar()
            do { publicKey = try authCryptography.publicKey(privateScalar: privateScalar) }
            catch { onError?("auth_failed: ephemeral key setup failed"); return }
            macEphPriv = privateScalar
        }
        var hello = PortableSessionHelloMessage(
            kind: .hello, legacyRole: role, peerID: localIdentity.rawValue)
        hello.authVersion = 1
        hello.recordVersion = 1
        hello.capabilityVersion = 1
        hello.capabilityIntentVersion = 2
        hello.frameMetaVersion = UInt16(VideoFrameMeta.latestVersion)
        hello.udpVideoVersion = UInt16(udpVideoVersion)
        hello.platform = "macos"
        hello.deviceName = Host.current().localizedName ?? "Mac"
        hello.pairingToken = pairingToken
        hello.supportedRoles = supportedMediaRoles
        hello.desiredRole = desiredMediaRole
        hello.projection = projectionMode
        var caps = PortableSessionHelloCaps()
        caps.maxWidth = 3_840
        caps.maxHeight = 2_160
        caps.hidpi = true
        hello.caps = caps
        hello.enrollmentKey = publicKey
        do {
            sendPayload(channel: .control, payload: try PortableSessionHelloWireCodec.encode(hello))
        } catch {
            onError?("auth_failed: canonical hello encode failed")
        }
    }
}
