import Foundation

/// L2/L3 — control session over the CONTROL channel.
/// Phase 0 scope: hello/hello_ack handshake + ping/pong RTT.
/// Video (L4) and input (L4) pipelines will plug into the same mux later.
public final class Session {
    let transport: Transport
    let role: String
    /// Local media roles offered in hello. Defaults reproduce the v2 Mac-source wire exactly.
    public let supportedMediaRoles: Set<MediaRole>
    public let desiredMediaRole: MediaRole
    public let projectionMode: ProjectionMode
    public let authorizedCapabilities: SessionCapabilityAuthorization
    /// Six-axis product authorization injected independently from legacy capability bits.
    public let capabilityIntentProductProfile: PortableCapabilityIntentProductProfile
    /// Already-authorized six-axis Session request used by capability-intent v2.
    public let collaborationIntent: CollaborationIntentDraft
    /// Platform-persisted identity; Session never consults UserDefaults or Keychain.
    public let localIdentity: PortableSessionIdentity
    public let secretStore: (any PairSecretStore)?
    /// A platform/product driver supplies only capabilities that are both linked and authorized.
    /// Zero is the public reliable-only baseline; the generic Session never imports or infers a
    /// private transport implementation.
    public let udpVideoVersion: UInt8
    let stateLock = NSLock()
    /// One owner for SC-RECORD counter allocation and reliable transport enqueue ordering.
    private let outboundEnqueueLock = NSLock()
    var pingTimestamps: [Int: UInt64] = [:]
    var nextSeq = 1
    // Compatibility builds keep the historical one-shot guards. Shipping builds delegate duplicate
    // and out-of-order handling to the portable ScSession reducer instead.
    private var helloAckHandled = false
    private var connectedDelivered = false
    var authCryptography: any SessionAuthCryptography = SessionAuthCryptographyProvider.active
    var rustSession: RustInitiatorSessionDriver?
    var rustCapabilities: RustCapabilityNegotiationDriver?
    /// Deterministic scheduling point used only by native concurrency regressions.
    var outboundFramePreparedForTesting: ((Channel) -> Void)?

    /// Peer capabilities announced in hello/hello_ack.
    public internal(set) var peerCaps: [String: Any]?

    /// v2 handshake peer identity/role (nil when talking to a v1 peer — treat as v1 defaults).
    public internal(set) var peerId: String?
    public internal(set) var peerPlatform: String?
    public internal(set) var peerProtocolVersion: Int = 1
    /// The peer role accepted by hello_ack. A v1/v2 peer that omits it defaults to sink/receiver.
    public internal(set) var peerAcceptedMediaRole: MediaRole?
    /// The peer's friendly device name from hello_ack (e.g. "HUAWEI MatePad Pro") — surfaced so even a
    /// wired card, named by hdc serial at discovery, shows the real device once connected.
    public internal(set) var peerDeviceName: String?
    /// ¥6 low-latency (open-core, private): the tablet's bound UDP video port from hello_ack, or 0 when
    /// it has no UDP receiver → the host keeps sending VIDEO over the reliable TCP path.
    public internal(set) var peerUdpVideoPort: Int = 0
    /// Negotiated private UDP wire version. A missing/mismatched value forces the safe TCP fallback.
    public internal(set) var peerUdpVideoVersion: Int = 0
    /// Negotiated per-frame identity header. v1 = 16-byte legacy; v2 adds a 64-bit stream epoch.
    public internal(set) var peerFrameMetaVersion: Int = 1
    /// Reliable-anchor transaction protocol. Zero means the peer cannot prove decoder output, so an
    /// optional dependent-frame route must remain disabled for the whole session.
    public internal(set) var peerMediaRecoveryVersion: Int = 0

    /// Optional wireless proximity-pairing token (from BLE bootstrap). DEMOTED (audit M10): no longer an
    /// auth credential and no longer sent in `hello` — kept only so existing callers compile. Trust now
    /// comes from SC-AUTH-v1 (below), not this broadcast value.
    public var pairingToken: String?

    /// Client-side FACT: did the Mac dial genuine loopback (wired hdc/USB)? Set by HostConnection from
    /// `TcpTransport.isLoopback(host)`. The auth exemption is honored ONLY when this is true — we never
    /// trust the peer merely OMITTING a challenge to mean "exempt" (audit H4 client fail-open).
    public var peerIsLoopback = false

    // Client-side auth handshake state (reset per session/connect).
    var macEphPriv: Data?               // shared only with the atomic hello effect adapter
    private var macNonce: Data?         // our challenge to the tablet (mutual auth)
    private var authSecret: Data?       // the per-pair secret in use once known (looked up or enrolled)
    private var pendingEnroll: (tabletPeerId: String, tabletEphPub: Data, tabletNonce: Data)?

    public var onLog: ((String) -> Void)?
    public var onConnected: (() -> Void)?        // fired after hello_ack
    public var onCapsUpdate: (([String: Any]) -> Void)?   // tablet panel caps changed (rotation/resolution)
    public var onRTT: ((Double) -> Void)?         // milliseconds
    public var onInput: ((Data) -> Void)?         // INPUT-channel payload (Pad→Mac)
    /// Reliable remote-control ownership reset. The source must release every injected button,
    /// modifier, pointer and pen stroke immediately; this is intentionally CONTROL rather than INPUT
    /// so an escape cannot be lost behind coalesced pointer traffic.
    public var onInputReset: ((String) -> Void)?
    public var onText: ((String) -> Void)?        // committed Unicode text (Pad→Mac IME)
    public var onError: ((String) -> Void)?
    public var onClosed: (() -> Void)?
    /// ¥6 low-latency (open-core, private): the tablet asks for an IDR. The `reason` classifies the
    /// recovery: network loss ("udp_gap", legacy absent) is a CONGESTION signal (adaptive bitrate may
    /// step down); decoder-local causes ("decoder_backlog", "decoder_error", "config_rearm", …) are
    /// NOT congestion — the host forces the IDR but must not punish the bitrate for them.
    public var onRequestKeyframe: ((String?) -> Void)?
    /// UDP viability probe answered by the tablet (FrameIdentityV1 fallback): it received our probe
    /// datagram and echoed the token over this reliable session.
    public var onUdpProbeAck: ((UInt32) -> Void)?
    /// The tablet reports UDP video starvation while in low-latency mode (it expects UDP P-frames and
    /// none arrive) → the host downgrades this session to TCP video.
    public var onUdpUnavailable: (() -> Void)?
    /// Receiver-side stage counters. This is the only proof that a complete frame progressed beyond
    /// the sender; see `ReceiverProgress` for the deliberately separate stage semantics.
    public var onReceiverProgress: ((ReceiverProgress) -> Void)?
    /// Receiver accepted the reliable anchor into its native decoder queue. Private UDP GOP pacing
    /// resumes only after this barrier (with a bounded compatibility timeout on older peers).
    public var onAnchorAccepted: ((_ streamEpochHi: UInt32, _ streamEpochLo: UInt32,
                                   _ sourceFrameId: UInt32) -> Void)?
    public var onRecoveryAnchorAccepted: ((MediaRecoveryControl) -> Void)?
    public var onRecoveryAnchorOutput: ((MediaRecoveryControl) -> Void)?

    public init(
        transport: Transport,
        role: String,
        localIdentity: PortableSessionIdentity,
        secretStore: (any PairSecretStore)? = nil,
        supportedMediaRoles: Set<MediaRole> = [.source],
        desiredMediaRole: MediaRole = .source,
        projectionMode: ProjectionMode = .extend,
        udpVideoVersion: UInt8 = 0,
        authorizedCapabilities: SessionCapabilityAuthorization? = nil,
        capabilityIntentProductProfile: PortableCapabilityIntentProductProfile? = nil,
        collaborationIntent: CollaborationIntentDraft? = nil
    ) {
        self.transport = transport
        self.role = role
        self.localIdentity = localIdentity
        self.secretStore = secretStore
        self.supportedMediaRoles = supportedMediaRoles.union([desiredMediaRole])
        self.desiredMediaRole = desiredMediaRole
        self.projectionMode = projectionMode
        self.udpVideoVersion = udpVideoVersion
        self.authorizedCapabilities = authorizedCapabilities
            ?? .minimum(localRole: desiredMediaRole, projection: projectionMode)
        let projected = CollaborationIntentDraft(projectionIntent: .init(
            localRole: desiredMediaRole,
            mode: projectionMode,
            inputPolicy: .remoteControl,
            transportProfile: .tcp
        ))
        let selected = collaborationIntent ?? projected
        precondition(
            selected.localRole == projected.localRole
                && selected.sourceTopology == projected.sourceTopology,
            "Session collaboration intent must match its active media role and projection"
        )
        self.collaborationIntent = selected
        self.capabilityIntentProductProfile = capabilityIntentProductProfile
            ?? .init(exact: .init(selected))
    }
    convenience init(transport: Transport, role: String,
                     localIdentity: PortableSessionIdentity,
                     secretStore: (any PairSecretStore)? = nil,
                     authCryptography: any SessionAuthCryptography) {
        self.init(transport: transport, role: role, localIdentity: localIdentity,
                  secretStore: secretStore)
        self.authCryptography = authCryptography
    }

    public func start() {
        transport.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.rustSession?.transportReady()
            case .failed(let msg):
                self.rustSession?.transportFailed(msg)
            case .cancelled:
                self.rustSession?.transportClosed()
            case .setup:
                break
            }
        }
        transport.onReceive = { [weak self] data in
            self?.ingest(data)
        }
        startRustSession()
    }

    // MARK: - Outgoing

    func sendPayload(channel: Channel, flags: FrameFlags = [], payload: Data) {
        guard enqueuePayload(channel: channel, flags: flags, payload: payload) else {
            rustSession?.transportFailed("SC-RECORD-v1 seal failed")
            return
        }
    }

    @discardableResult
    public func enqueuePayload(
        channel: Channel,
        flags: FrameFlags = [],
        payload: Data
    ) -> Bool {
        outboundEnqueueLock.lock()
        defer { outboundEnqueueLock.unlock() }
        guard let frame = framedPayload(channel: channel, flags: flags, payload: payload) else {
            return false
        }
        outboundFramePreparedForTesting?(channel)
        transport.send(frame)
        return true
    }

    public var hasAuthenticatedRecords: Bool {
        rustSession?.hasAuthenticatedRecords() == true
    }

    public func framedPayload(
        channel: Channel,
        flags: FrameFlags = [],
        payload: Data
    ) -> Data? {
        rustSession?.frameOutbound(
            channel: channel.rawValue, flags: flags.rawValue, payload: payload)
    }

    public func authenticatedPayload(
        channel: Channel,
        flags: FrameFlags = [],
        payload: Data
    ) -> Data? {
        rustSession?.authenticatedPayload(
            channel: channel.rawValue, flags: flags.rawValue, payload: payload)
    }

    private func claimFirstHelloAck() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !helloAckHandled else { return false }
        helloAckHandled = true
        return true
    }

    private func deliverConnectedOnce() {
        stateLock.lock()
        let shouldDeliver = !connectedDelivered
        connectedDelivered = true
        stateLock.unlock()
        if shouldDeliver { onConnected?() }
    }

    /// Prove possession of the per-pair secret: send `auth` with HMAC(secret, contextMac) + our own nonce.
    private func sendAuth(secret: Data, tabletPeerId: String, tabletNonce: Data) {
        let mn = AuthCrypto.randomBytes(32)
        do {
            let direction = SessionAuthProofDirection.macToTablet(
                macPeerID: localIdentity.rawValue, tabletPeerID: tabletPeerId,
                tabletNonce: tabletNonce)
            let proof = try authCryptography.createProof(secret: secret, direction: direction)
            macNonce = mn
            let payload = try PortableAuthWireCodec.encode(.auth(proof: proof, challenge: mn))
            sendPayload(channel: .control, payload: payload)
        } catch {
            onError?("auth_failed: invalid authentication inputs")
        }
    }

    private func ingest(_ data: Data) {
        guard let frames = rustSession?.receiveBytes(data) else {
            return
        }
        guard frames.count <= 1 else {
            rustSession?.transportFailed("secure connection returned multiple inbound frames")
            return
        }
        guard let first = frames.first else { return }
        guard routeInbound(first) else { return }

        // Core exposes at most one inbound frame per push. A socket read may nevertheless contain
        // a transition frame followed by an authenticated record. Only after the first frame has
        // been routed (and its typed effects have synchronously completed) may the platform issue
        // the explicit NULL/zero push that crosses the state barrier to the next buffered frame.
        while let frames = rustSession?.receiveBufferedBytes() {
            guard frames.count <= 1 else {
                rustSession?.transportFailed("secure connection returned multiple inbound frames")
                return
            }
            guard let next = frames.first else { break }
            guard routeInbound(next) else { return }
        }
    }

    private func routeInbound(_ inbound: PortableSecureInboundFrame) -> Bool {
        switch inbound.frame.channel {
        case Channel.control.rawValue:
            guard let control = inbound.control else {
                rustSession?.transportFailed("canonical CONTROL classification missing")
                return false
            }
            handleControl(inbound.frame.payload, envelope: control)
        case Channel.input.rawValue:
            onInput?(inbound.frame.payload)
        default:
            onLog?("ignoring frame on channel \(inbound.frame.channel)")
        }
        return true
    }

}
