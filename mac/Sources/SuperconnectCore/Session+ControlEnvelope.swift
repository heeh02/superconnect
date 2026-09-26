import Foundation
import SuperconnectCoreFFI

extension Session {
    func handleControl(_ payload: Data, envelope: PortableControlEnvelope) {
        if envelope.kind == SC_CONTROL_KIND_RECEIVER_PROGRESS_V1 {
            guard let progress = ReceiverProgress(wirePayload: payload) else {
                rustSession?.transportFailed("invalid receiver_progress")
                return
            }
            onReceiverProgress?(progress)
            return
        }
        if envelope.kind == SC_CONTROL_KIND_RECOVERY_ANCHOR_V1
            || envelope.kind == SC_CONTROL_KIND_ANCHOR_ACCEPTED_V1
            || envelope.kind == SC_CONTROL_KIND_ANCHOR_OUTPUT_V1,
           envelope.has(UInt32(SC_CONTROL_ENVELOPE_FIELD_OPERATION_V1)) {
            guard let recovery = MediaRecoveryControl(wirePayload: payload) else {
                rustSession?.transportFailed("invalid media recovery control")
                return
            }
            switch recovery.type {
            case .accepted: onRecoveryAnchorAccepted?(recovery)
            case .output: onRecoveryAnchorOutput?(recovery)
            case .anchor: onLog?("ignoring unexpected recovery_anchor")
            }
            return
        }
        if envelope.kind == SC_CONTROL_KIND_REQUEST_KEYFRAME_V1 {
            guard let request = KeyframeRequestControl(wirePayload: payload) else {
                rustSession?.transportFailed("invalid request_keyframe")
                return
            }
            onRequestKeyframe?(request.reason.wireName)
            return
        }
        if envelope.kind == SC_CONTROL_KIND_INPUT_RESET_V1 {
            guard let reset = InputResetControl(wirePayload: payload) else {
                rustSession?.transportFailed("invalid input_reset")
                return
            }
            onInputReset?(reset.reason)
            return
        }
        if envelope.kind == SC_CONTROL_KIND_PING_V1
            || envelope.kind == SC_CONTROL_KIND_PONG_V1
            || envelope.kind == SC_CONTROL_KIND_BYE_V1 {
            guard let control = SessionControlWire(wirePayload: payload) else {
                rustSession?.transportFailed("invalid session control")
                return
            }
            switch control {
            case let .ping(sequence, t0):
                let now = DispatchTime.now().uptimeNanoseconds
                if let reply = SessionControlWire.pong(
                    sequence: sequence, t0: t0, t1: max(1, now / 1_000), t2: nil).wirePayload {
                    sendPayload(channel: .control, payload: reply)
                }
            case let .pong(sequence, _, _, _):
                stateLock.lock()
                let sent = Int(exactly: sequence).flatMap { pingTimestamps.removeValue(forKey: $0) }
                stateLock.unlock()
                if let sent {
                    let now = DispatchTime.now().uptimeNanoseconds
                    onRTT?(Double(now &- sent) / 1_000_000.0)
                }
            case .bye:
                rustSession?.transportClosed()
            }
            return
        }
        if envelope.kind == SC_CONTROL_KIND_CAPABILITY_V1 {
            rustCapabilities?.receive(payload: payload)
            return
        }
        if envelope.kind == SC_CONTROL_KIND_CAPABILITY_INTENT_PROFILE_V2_V1 {
            rustCapabilities?.receiveIntentProfile(payload: payload)
            return
        }
        if envelope.kind == SC_CONTROL_KIND_CAPABILITY_INTENT_V2_V1 {
            rustCapabilities?.receiveIntent(payload: payload)
            return
        }
        if envelope.kind == SC_CONTROL_KIND_AUTH_V1
            || envelope.kind == SC_CONTROL_KIND_AUTH_ACK_V1
            || envelope.kind == SC_CONTROL_KIND_PAIR_SECRET_V1 {
            guard let auth = try? PortableAuthWireCodec.decode(payload) else {
                rustSession?.transportFailed("invalid auth control")
                return
            }
            switch auth {
            case .pairSecret(let sealed, let salt, let nonce):
                rustSession?.receivePairSecret(sealed: sealed, salt: salt, nonce: nonce)
            case .authAck(let proof): rustSession?.receiveAuthAck(proof: proof)
            case .auth: rustSession?.transportFailed("unexpected auth message")
            }
            return
        }
        if envelope.kind == SC_CONTROL_KIND_HELLO_V1
            || envelope.kind == SC_CONTROL_KIND_HELLO_ACK_V1 {
            guard let hello = try? PortableSessionHelloWireCodec.decode(payload) else {
                rustSession?.transportFailed("invalid hello control")
                return
            }
            switch hello.kind {
            case .helloAck: handleRustHelloAck(hello.foundationObject)
            case .hello: onLog?("received hello (peer also greeted)")
            }
            return
        }
        if envelope.kind == SC_CONTROL_KIND_CAPS_UPDATE_V1 {
            guard let caps = PortableControlEnvelopeCodec.decodeCapsUpdate(payload) else {
                rustSession?.transportFailed("invalid caps_update")
                return
            }
            peerCaps = caps
            onLog?("received caps_update from peer")
            NSLog("SCDIAG mac received caps_update")
            onCapsUpdate?(caps)
            return
        }
        if envelope.kind == SC_CONTROL_KIND_ERROR_V1 {
            let reason = PortableControlEnvelopeCodec.errorReason(envelope.detail)
            onError?("peer error: \(reason)")
            return
        }
        if envelope.kind == SC_CONTROL_KIND_TEXT_V1 {
            guard let text = PortableControlEnvelopeCodec.decodeText(payload) else {
                rustSession?.transportFailed("invalid text control")
                return
            }
            onText?(text)
            return
        }
        if envelope.kind == SC_CONTROL_KIND_UDP_PROBE_ACK_V1 {
            guard envelope.has(UInt32(SC_CONTROL_ENVELOPE_FIELD_OPERATION_V1)),
                  let token = UInt32(exactly: envelope.operation) else {
                rustSession?.transportFailed("invalid udp_probe_ack")
                return
            }
            onUdpProbeAck?(token)
            return
        }
        if envelope.kind == SC_CONTROL_KIND_UDP_UNAVAILABLE_V1 {
            onUdpUnavailable?()
            return
        }
        if envelope.kind == SC_CONTROL_KIND_ANCHOR_ACCEPTED_V1 {
            guard envelope.has(UInt32(SC_CONTROL_ENVELOPE_FIELD_GENERATION_V1)),
                  envelope.has(UInt32(SC_CONTROL_ENVELOPE_FIELD_VALUE0_V1)),
                  let sourceFrameID = UInt32(exactly: envelope.value0) else {
                rustSession?.transportFailed("invalid auxiliary anchor_accepted")
                return
            }
            onAnchorAccepted?(
                UInt32(truncatingIfNeeded: envelope.generation >> 32),
                UInt32(truncatingIfNeeded: envelope.generation), sourceFrameID)
            return
        }
        rustSession?.transportFailed("unexpected typed CONTROL kind \(envelope.kind)")
    }
}
