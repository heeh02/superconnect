import Foundation

/// L2/L3 — control session over the CONTROL channel.
/// Phase 0 scope: hello/hello_ack handshake + ping/pong RTT.
/// Video (L4) and input (L4) pipelines will plug into the same mux later.
public final class Session {
    private let transport: Transport
    private let role: String
    private let decoder = FrameDecoder()
    private let stateLock = NSLock()
    private var pingTimestamps: [Int: UInt64] = [:]
    private var nextSeq = 1

    /// Peer capabilities announced in hello/hello_ack.
    public private(set) var peerCaps: [String: Any]?

    /// v2 handshake peer identity/role (nil when talking to a v1 peer — treat as v1 defaults).
    public private(set) var peerId: String?
    public private(set) var peerPlatform: String?
    public private(set) var peerAcceptedRole: String?
    public private(set) var peerProtocolVersion: Int = 1
    /// The peer's friendly device name from hello_ack (e.g. "HUAWEI MatePad Pro") — surfaced so even a
    /// wired card, named by hdc serial at discovery, shows the real device once connected.
    public private(set) var peerDeviceName: String?

    /// Stable per-install id (UUID), the trust/routing key for v2. Persisted in UserDefaults.
    public static let localPeerId: String = {
        let key = "com.superconnect.peerId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// Optional wireless proximity-pairing token (from BLE bootstrap) to present in `hello`. When set,
    /// the tablet auto-trusts this Mac (closes the cleartext-peerId replay gap). Set before `start()`.
    public var pairingToken: String?

    public var onLog: ((String) -> Void)?
    public var onConnected: (() -> Void)?        // fired after hello_ack
    public var onCapsUpdate: (([String: Any]) -> Void)?   // tablet panel caps changed (rotation/resolution)
    public var onRTT: ((Double) -> Void)?         // milliseconds
    public var onInput: ((Data) -> Void)?         // INPUT-channel payload (Pad→Mac)
    public var onText: ((String) -> Void)?        // committed Unicode text (Pad→Mac IME)
    public var onError: ((String) -> Void)?
    public var onClosed: (() -> Void)?

    public init(transport: Transport, role: String) {
        self.transport = transport
        self.role = role
    }

    public func start() {
        transport.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onLog?("transport ready → sending hello")
                self.sendHello()
            case .failed(let msg):
                self.onError?("transport failed: \(msg)")
            case .cancelled:
                self.onClosed?()
            case .setup:
                break
            }
        }
        transport.onReceive = { [weak self] data in
            self?.ingest(data)
        }
        transport.start()
    }

    // MARK: - Outgoing

    private func sendControl(_ object: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
            onError?("failed to serialize control message")
            return
        }
        transport.send(FrameCodec.encode(channel: .control, payload: payload))
    }

    private func sendHello() {
        var hello: [String: Any] = [
            "type": "hello",
            "role": role,
            "protocolVersion": 2,
            "app": "superconnect",
            // v2 (all additive — a v1 peer ignores these): identity + role negotiation groundwork.
            "peerId": Session.localPeerId,
            "platform": "macos",
            "deviceName": Host.current().localizedName ?? "Mac",
            "supportedRoles": ["host"],
            "desiredRole": "host",
            "caps": ["codecs": ["h264"], "maxWidth": 3840, "maxHeight": 2160, "hidpi": true],
        ]
        if let token = pairingToken, !token.isEmpty { hello["pairingToken"] = token }   // BLE proximity proof
        sendControl(hello)
    }

    public func sendPing() {
        stateLock.lock()
        let seq = nextSeq
        nextSeq += 1
        let t0 = DispatchTime.now().uptimeNanoseconds
        pingTimestamps[seq] = t0
        stateLock.unlock()
        sendControl(["type": "ping", "seq": seq, "t0": t0])
    }

    public func sendBye() {
        sendControl(["type": "bye"])
    }

    /// Tell the peer the actual encoded video resolution (Mac→Pad, Phase 1).
    public func sendVideoConfig(width: Int, height: Int, codec: String = "h264", hdr: String = "off") {
        sendControl(["type": "video_config", "codec": codec, "width": width, "height": height, "hdr": hdr])
    }

    // MARK: - Incoming

    private func ingest(_ data: Data) {
        let frames: [Frame]
        do {
            frames = try decoder.push(data)
        } catch {
            onError?("decode error: \(error)")
            return
        }
        for frame in frames {
            switch frame.channel {
            case Channel.control.rawValue:
                handleControl(frame.payload)
            case Channel.input.rawValue:
                onInput?(frame.payload)
            default:
                onLog?("ignoring frame on channel \(frame.channel)")
            }
        }
    }

    private func handleControl(_ payload: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let type = object["type"] as? String
        else {
            onError?("malformed control message")
            return
        }
        switch type {
        case "hello_ack":
            peerCaps = object["caps"] as? [String: Any]
            peerId = object["peerId"] as? String
            peerPlatform = object["platform"] as? String
            peerAcceptedRole = object["acceptedRole"] as? String
            peerDeviceName = object["deviceName"] as? String
            peerProtocolVersion = (object["protocolVersion"] as? Int) ?? 1   // absent ⇒ v1 peer
            onLog?("received hello_ack (v\(peerProtocolVersion) platform=\(peerPlatform ?? "?"))")
            onConnected?()
        case "caps_update":
            // Tablet rotated / changed resolution → updated panel caps. Re-negotiate the display.
            peerCaps = object["caps"] as? [String: Any]
            onLog?("received caps_update from peer")
            NSLog("SCDIAG mac received caps_update")
            if let caps = peerCaps { onCapsUpdate?(caps) }
        case "hello":
            // We are the client in Phase 0; a hello here would be unexpected, but be lenient.
            onLog?("received hello (peer also greeted)")
        case "pong":
            stateLock.lock()
            let t0 = (object["seq"] as? Int).flatMap { pingTimestamps.removeValue(forKey: $0) }
            stateLock.unlock()
            if let t0 {
                let now = DispatchTime.now().uptimeNanoseconds
                let rttMs = Double(now &- t0) / 1_000_000.0
                onRTT?(rttMs)
            }
        case "error":
            onError?("peer error: \(object["message"] as? String ?? "unknown")")
        case "bye":
            onClosed?()
        case "text":
            onText?(object["text"] as? String ?? "")
        default:
            onLog?("unhandled control type: \(type)")
        }
    }
}
