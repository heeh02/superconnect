import Foundation

public extension Session {
    internal static var usesRustSessionLifecycle: Bool {
        true
    }

    func sendBye() {
        if let payload = SessionControlWire.bye.wirePayload {
            sendPayload(channel: .control, payload: payload)
        }
    }

    func sendPing() {
        stateLock.lock()
        if pingTimestamps.count >= 3 {
            pingTimestamps.removeAll()
            stateLock.unlock()
            onError?("heartbeat timeout — no pong (link half-open)")
            return
        }
        let sequence = nextSeq
        nextSeq += 1
        let now = DispatchTime.now().uptimeNanoseconds
        if now > 10_000_000_000 {
            let cutoff = now - 10_000_000_000
            pingTimestamps = pingTimestamps.filter { $0.value >= cutoff }
        }
        pingTimestamps[sequence] = now
        stateLock.unlock()
        guard let sequence = UInt64(exactly: sequence),
              let payload = SessionControlWire.ping(
                sequence: sequence, t0: max(1, now / 1_000)).wirePayload
        else { return }
        sendPayload(channel: .control, payload: payload)
    }

    /// Relinquish remote input ownership and ask the controlled peer to clear all injected state.
    func sendInputReset(reason: String = "local_escape") {
        guard let payload = InputResetControl(reason: reason)?.wirePayload else {
            onError?("invalid input reset reason")
            return
        }
        sendPayload(channel: .control, payload: payload)
    }

    /// Tell the peer the actual encoded video resolution and the already-authorized latency mode.
    func sendVideoConfig(
        width: Int,
        height: Int,
        codec: String = "h264",
        hdr: String = "off",
        lowLatency: Bool = false,
        refreshRate: Int = 0
    ) {
        guard codec == "h264", hdr == "off",
              let message = VideoConfigControl(
                width: width, height: height, refreshRate: refreshRate,
                lowLatency: lowLatency),
              let payload = message.wirePayload else {
            onError?("invalid video_config")
            return
        }
        sendPayload(channel: .control, payload: payload)
    }

    /// Announce the GOP carried by the next reliable TCP keyframe.
    func sendVideoEpoch(_ epoch: UInt32, firstFrameSeq: UInt32) {
        guard let payload = PortableControlEnvelopeCodec.encodeVideoEpoch(
            epoch, firstFrameSequence: firstFrameSeq) else {
            rustSession?.transportFailed("Rust video_epoch encoder rejected values")
            return
        }
        sendPayload(channel: .control, payload: payload)
    }

    /// Framed CONTROL record used by `ReliableVideoFrameWriter` to atomically enqueue the recovery
    /// transaction immediately before its VIDEO anchor on the same ordered transport.
    func recoveryAnchorControlFrame(_ identity: PortableRecoveryIdentity) -> Data? {
        guard let payload = MediaRecoveryControl(type: .anchor, identity: identity).wirePayload
        else { return nil }
        return framedPayload(channel: .control, payload: payload)
    }
}
