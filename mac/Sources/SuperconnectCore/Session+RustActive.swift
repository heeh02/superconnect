import Foundation
import SuperconnectCoreFFI

extension Session {
    func startRustSession() {
        precondition(
            sc_mac_rust_session_active_marker() == UInt32(SC_API_VERSION_V1)
                && sc_mac_rust_secure_connection_active_marker() == UInt32(SC_API_VERSION_V1)
                && sc_mac_rust_capability_active_marker() == UInt32(SC_API_VERSION_V1),
            "Rust secure-session/capability ABI version mismatch"
        )
        do {
            let driver = try RustInitiatorSessionDriver(
                localPeerID: localIdentity.rawValue,
                localRole: desiredMediaRole,
                trustedLocal: peerIsLoopback,
                store: secretStore,
                crypto: authCryptography
            )
            let capabilityDriver = try RustCapabilityNegotiationDriver(
                generation: driver.generation,
                localRole: desiredMediaRole,
                projection: projectionMode,
                authorized: authorizedCapabilities,
                intentProductProfile: capabilityIntentProductProfile,
                collaborationIntent: collaborationIntent
            )
            driver.openTransport = { [weak self] in self?.transport.start() }
            driver.stopTransport = { [weak self] in self?.transport.stop() }
            driver.sendHello = { [weak self] publicKey in self?.sendHello(publicKey: publicKey) }
            driver.sendAuth = { [weak self, weak driver] proof, challenge in
                guard let payload = try? PortableAuthWireCodec.encode(
                    .auth(proof: proof, challenge: challenge))
                else { driver?.transportFailed("auth wire encode failed"); return }
                self?.sendPayload(channel: .control, payload: payload)
            }
            driver.notifyReady = { [weak self] in
                self?.onLog?("Rust session ready")
                self?.onConnected?()
            }
            driver.notifyClosed = { [weak self] in self?.onClosed?() }
            driver.notifyError = { [weak self] in self?.onError?($0) }
            driver.log = { [weak self] in self?.onLog?($0) }
            capabilityDriver.sendWireControl = { [weak self] payload in
                self?.sendPayload(channel: .control, payload: payload)
            }
            capabilityDriver.failed = { [weak driver] message in
                driver?.capabilityCommitCompleted(false, failure: message)
            }
            capabilityDriver.log = { [weak self] in self?.onLog?($0) }
            rustSession = driver
            rustCapabilities = capabilityDriver
            driver.start()
        } catch {
            onError?("Rust session initialization failed")
            transport.stop()
        }
    }

    func handleRustHelloAck(_ object: [String: Any]) {
        let peer = object["peerId"] as? String ?? ""
        let challenge = (object["nonce"] as? String).flatMap { Data(base64Encoded: $0) }
        let peerKey = (object["ephPub"] as? String).flatMap { Data(base64Encoded: $0) }
        let authVersion = object["authVersion"] as? Int
        let enrollment = object["needsPairing"] as? Bool ?? false
        rustSession?.receiveHelloAck(
            peer: peer,
            authVersion: authVersion,
            recordVersion: object["recordVersion"] as? Int,
            challenge: challenge,
            enrollment: enrollment,
            peerEnrollmentKey: peerKey
        ) { [weak self] in
            guard let self, let capabilityDriver = self.rustCapabilities else { return }
            capabilityDriver.connected = { [weak self] binding in
                guard let self, let driver = self.rustSession else { return }
                let roleMatches = self.helloAckRoleMatches(object)
                let bindingMatches = binding.localRole == self.desiredMediaRole
                    && binding.peerRole == self.desiredMediaRole.peerRole
                    && binding.projection == self.projectionMode
                let valid = roleMatches && bindingMatches
                if valid { _ = self.commitHelloAckMetadata(object) }
                driver.capabilityCommitCompleted(
                    valid,
                    failure: valid ? nil : roleMatches
                        ? "capability binding does not match authorized intent"
                        : "role_negotiation_failed: peer accepted incompatible role"
                )
            }
            capabilityDriver.begin(
                peerVersion: object["capabilityNegotiationVersion"] as? Int,
                peerIntentVersion: object["capabilityIntentNegotiationVersion"] as? Int
            )
        }
    }

    private func commitHelloAckMetadata(_ object: [String: Any]) -> Bool {
        guard helloAckRoleMatches(object) else { return false }
        let acceptedWire = (object["acceptedRole"] as? String) ?? MediaRole.sink.legacyWireValue
        peerAcceptedMediaRole = MediaRole(legacyWireValue: acceptedWire)
        peerCaps = object["caps"] as? [String: Any]
        peerId = object["peerId"] as? String
        peerPlatform = object["platform"] as? String
        peerDeviceName = object["deviceName"] as? String
        peerUdpVideoPort = (object["udpVideoPort"] as? Int) ?? 0
        peerUdpVideoVersion = (object["udpVideoVersion"] as? Int) ?? 0
        peerFrameMetaVersion = max(1, min(
            Int(VideoFrameMeta.latestVersion), (object["frameMetaVersion"] as? Int) ?? 1))
        peerMediaRecoveryVersion = (object["mediaRecoveryVersion"] as? Int) == 1 ? 1 : 0
        peerProtocolVersion = (object["protocolVersion"] as? Int) ?? 1
        onLog?("Rust session committed hello_ack capabilities")
        return true
    }

    private func helloAckRoleMatches(_ object: [String: Any]) -> Bool {
        let acceptedWire = (object["acceptedRole"] as? String) ?? MediaRole.sink.legacyWireValue
        return MediaRole(legacyWireValue: acceptedWire) == desiredMediaRole.peerRole
    }
}
