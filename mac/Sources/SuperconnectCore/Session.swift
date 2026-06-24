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

    /// Optional wireless proximity-pairing token (from BLE bootstrap). DEMOTED (audit M10): no longer an
    /// auth credential and no longer sent in `hello` — kept only so existing callers compile. Trust now
    /// comes from SC-AUTH-v1 (below), not this broadcast value.
    public var pairingToken: String?

    /// SC-AUTH-v1 (audit H4): per-pair secret store for the wireless challenge-response handshake. When
    /// non-nil AND the peer challenges (sends a `nonce`), the Mac (the TCP client) must prove possession
    /// of the shared secret before `onConnected` fires. nil ⇒ no auth (the tablet exempts wired/loopback
    /// by omitting the nonce; tests pass nil). Set before `start()`.
    public var secretStore: PairSecretStore?

    /// Client-side FACT: did the Mac dial genuine loopback (wired hdc/USB)? Set by HostConnection from
    /// `TcpTransport.isLoopback(host)`. The auth exemption is honored ONLY when this is true — we never
    /// trust the peer merely OMITTING a challenge to mean "exempt" (audit H4 client fail-open).
    public var peerIsLoopback = false

    // Client-side auth handshake state (reset per session/connect).
    private var macEphPriv: Data?       // our ephemeral P-256 scalar (enrollment ECDH)
    private var macNonce: Data?         // our challenge to the tablet (mutual auth)
    private var authSecret: Data?       // the per-pair secret in use once known (looked up or enrolled)
    private var pendingEnroll: (tabletPeerId: String, tabletEphPub: Data, nonceB64: String)?

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
        // Always offer a fresh ephemeral P-256 public key: the tablet uses it ONLY if it must enroll
        // this Mac (no stored secret), and ignores it in steady state. Sending it unconditionally avoids
        // a chicken-and-egg (we don't learn the tablet's peerId until hello_ack, so we can't decide
        // "enroll or not" before sending hello). Cheap; harmless when unused.
        let eph = AuthCrypto.newEphemeralKeyPair()
        macEphPriv = eph.priv
        let hello: [String: Any] = [
            "type": "hello",
            "role": role,
            "protocolVersion": 2,
            "authVersion": 1,                 // SC-AUTH-v1: peers without this are refused (fail closed)
            "app": "superconnect",
            "peerId": Session.localPeerId,
            "platform": "macos",
            "deviceName": Host.current().localizedName ?? "Mac",
            "supportedRoles": ["host"],
            "desiredRole": "host",
            "caps": ["codecs": ["h264"], "maxWidth": 3840, "maxHeight": 2160, "hidpi": true],
            "ephPub": eph.pub.base64EncodedString(),
        ]
        sendControl(hello)
    }

    /// Prove possession of the per-pair secret: send `auth` with HMAC(secret, contextMac) + our own nonce.
    private func sendAuth(secret: Data, tabletPeerId: String, nonceB64: String) {
        let mn = AuthCrypto.randomBytes(32)
        macNonce = mn
        let ctx = AuthCrypto.contextMac(macPeerId: Session.localPeerId, tabletPeerId: tabletPeerId, nonceB64: nonceB64)
        let proof = AuthCrypto.hmac(secret: secret, context: ctx)
        sendControl(["type": "auth", "proof": proof.base64EncodedString(), "macNonce": mn.base64EncodedString()])
    }

    /// Max pings we'll let go unanswered before declaring the link dead. A half-open link (peer gone,
    /// no TCP error — common through an adb/hdc USB forward) shows up here as pongs that stop arriving
    /// while pings keep being sent. At the host's 2s ping cadence this is ~6s of silence.
    private let maxOutstandingPings = 3

    public func sendPing() {
        stateLock.lock()
        // Liveness check FIRST: if previous pings were never answered, the link is half-open. Surface it
        // as an error so the engine tears down + retries (which re-forwards and reconnects) instead of
        // streaming forever into a dead socket. Clear the backlog so a fresh session starts clean.
        if pingTimestamps.count >= maxOutstandingPings {
            pingTimestamps.removeAll()
            stateLock.unlock()
            onError?("heartbeat timeout — no pong (link half-open)")
            return
        }
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
            peerDeviceName = object["deviceName"] as? String
            peerProtocolVersion = (object["protocolVersion"] as? Int) ?? 1   // absent ⇒ v1 peer
            let authVersion = object["authVersion"] as? Int
            let nonceB64 = object["nonce"] as? String
            onLog?("received hello_ack (v\(peerProtocolVersion) auth=\(authVersion ?? 0) platform=\(peerPlatform ?? "?"))")
            // SC-AUTH-v1 client decision (audit H4):
            if let nonceB64, authVersion != nil {
                // The tablet challenged us → wireless auth REQUIRED before connecting.
                guard let tabletPeerId = peerId, let store = secretStore else {
                    onError?("auth_required: no secret store on this connection"); return
                }
                if (object["needsPairing"] as? Bool) == true {
                    // FAIL CLOSED on an unsolicited re-enroll: if we ALREADY hold a secret for this tablet,
                    // an attacker spoofing its peerId could otherwise force us to overwrite the good secret
                    // with an attacker-minted one. A genuine re-pair must explicitly remove the old secret.
                    if store.secret(for: tabletPeerId) != nil {
                        onError?("auth_failed: unexpected re-enroll for a known tablet — re-pair explicitly"); return
                    }
                    // Enrollment: the tablet has no secret for us → it will send `pair_secret` next. Stash
                    // its ephemeral pubkey + nonce and wait (don't send `auth` until we hold the secret).
                    guard let tEph = (object["ephPub"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                        onError?("auth_failed: enrollment hello_ack missing tablet ephPub"); return
                    }
                    pendingEnroll = (tabletPeerId: tabletPeerId, tabletEphPub: tEph, nonceB64: nonceB64)
                    onLog?("enrollment: awaiting pair_secret")
                } else {
                    // Steady state: we must already hold the secret (else the user must re-pair). FAIL CLOSED.
                    guard let secret = store.secret(for: tabletPeerId) else {
                        onError?("auth_required: no stored secret for this tablet — re-pair"); return
                    }
                    authSecret = secret
                    sendAuth(secret: secret, tabletPeerId: tabletPeerId, nonceB64: nonceB64)
                }
            } else if authVersion == nil {
                // Un-upgraded peer (no SC-AUTH-v1): refuse rather than fall back to spoofable peerId trust.
                onError?("auth_required: tablet needs update (no authVersion)")
            } else if peerIsLoopback {
                // authVersion present, no nonce, AND we genuinely dialed loopback (wired hdc) → exempt.
                onLog?("auth-exempt (wired/loopback dial) → connected")
                onConnected?()
            } else {
                // A WIRELESS peer that sent no challenge must NOT be trusted on its word — FAIL CLOSED
                // (audit H4: the exemption is a client-side fact, not the peer omitting the nonce).
                onError?("auth_required: wireless peer sent no challenge (refusing unauthenticated connect)")
            }
        case "pair_secret":
            // Enrollment step 2: decrypt the tablet-minted secret under the ECDH key, persist it, then auth.
            guard let pe = pendingEnroll, let store = secretStore, let macEphPriv,
                  let enc = (object["encSecret"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let salt = (object["salt"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let aeadNonce = (object["aeadNonce"] as? String).flatMap({ Data(base64Encoded: $0) })
            else { onError?("auth_failed: malformed pair_secret"); return }
            do {
                let key = try AuthCrypto.deriveEcdhKey(myPrivRaw: macEphPriv, peerPubRaw: pe.tabletEphPub, salt: salt)
                let secret = try AuthCrypto.open(encSecret: enc, key: key, nonce: aeadNonce, aad: AuthCrypto.pairInfo)
                store.store(secret, for: pe.tabletPeerId)
                authSecret = secret
                pendingEnroll = nil
                sendAuth(secret: secret, tabletPeerId: pe.tabletPeerId, nonceB64: pe.nonceB64)
                onLog?("enrollment: secret installed → sent auth")
            } catch {
                onError?("auth_failed: enrollment decrypt failed (\(error))")
            }
        case "auth_ack":
            // Mutual auth: the tablet proves it ALSO holds the secret. Only now is the link trusted.
            guard let secret = authSecret, let tabletPeerId = peerId, let mn = macNonce,
                  let proof = (object["proof"] as? String).flatMap({ Data(base64Encoded: $0) })
            else { onError?("auth_failed: malformed auth_ack"); return }
            let ctx = AuthCrypto.contextPad(macPeerId: Session.localPeerId, tabletPeerId: tabletPeerId,
                                            macNonceB64: mn.base64EncodedString())
            if AuthCrypto.verify(proof: proof, secret: secret, context: ctx) {
                onLog?("auth ok (mutual) → connected")
                onConnected?()
            } else {
                onError?("auth_failed: tablet proof mismatch")
            }
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
            // SC-AUTH-v1 surfaces a machine-readable `reason` (auth_failed / pairing_rejected / …); fall
            // back to `message`. HostConnection treats auth_failed/required as fatal (no retry storm).
            let reason = (object["reason"] as? String) ?? (object["message"] as? String) ?? "unknown"
            onError?("peer error: \(reason)")
        case "bye":
            onClosed?()
        case "text":
            onText?(object["text"] as? String ?? "")
        default:
            onLog?("unhandled control type: \(type)")
        }
    }
}
