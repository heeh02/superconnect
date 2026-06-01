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
        sendControl([
            "type": "hello",
            "role": role,
            "protocolVersion": 1,
            "app": "superconnect",
            "caps": ["codecs": ["h264"], "maxWidth": 3840, "maxHeight": 2160, "hidpi": true],
        ])
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
            onLog?("received hello_ack from peer")
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
