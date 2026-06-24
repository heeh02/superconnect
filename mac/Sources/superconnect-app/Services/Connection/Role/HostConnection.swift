import Foundation
import CoreGraphics
import Combine
import SuperconnectCore
import SuperconnectProducer

/// The HOST role: capture this Mac's screen and stream it to the connected device, and
/// inject the device's returned input. This is the old `HostController` pipeline relocated
/// behind `ConnectionEngine` — the tunnel + permission preflight now live one layer up, so
/// this just dials the resolved host:port. All technical detail (fps/codec/bitrate) stays
/// internal and is surfaced only through the optional telemetry publisher.
final class HostConnection: ConnectionEngine {
    private let stateSubject = CurrentValueSubject<ConnectionState, Never>(.idle)
    private let telemetrySubject = CurrentValueSubject<SessionTelemetry, Never>(SessionTelemetry())
    var statePublisher: AnyPublisher<ConnectionState, Never> { stateSubject.eraseToAnyPublisher() }
    var telemetryPublisher: AnyPublisher<SessionTelemetry, Never>? { telemetrySubject.eraseToAnyPublisher() }

    private var bitrateMbps = 50
    private let maxFps = 120
    private var pairingToken: String?   // wireless BLE proximity token to present in hello (nil = none)
    private var avoidVirtualInterfaces = false   // wireless: dial over physical NIC, excluding VPN/utun
    // Set once we've already fallen back from the physical-NIC pin to default routing for a wireless
    // target (see the connect-timeout watchdog). Prevents an infinite pin→default→pin oscillation and
    // keeps the final error classified as wireless. Reset on a fresh connect().
    private var triedDefaultRoute = false
    // Consecutive connect-timeout watchdog trips. A VPN/EasyConnect route hijack makes every dial time
    // out, and the plain retry loop would re-attempt forever; after this many in a row we stop with a
    // clear error instead of spinning. Reset on a real connect (onConnected) and on a fresh connect().
    private var consecutiveTimeouts = 0
    private let maxConsecutiveTimeouts = 3
    // True only while a session is fully handshaked. Gates the liveness heartbeat so we don't ping (and
    // false-trip the no-pong timeout) during the connect/handshake window — the connect watchdog owns that.
    private var handshakeDone = false

    private var host = "127.0.0.1"
    private var port: UInt16 = 8888

    private var transport: TcpTransport?
    private var session: Session?
    private var virtualDisplay: VirtualDisplay?
    private var producer: Producer?
    private var injector: InputInjector?
    // Shared, refcounted guard: with multiple simultaneous connections (#51) every HostConnection
    // shares ONE guard so the real-display snapshot is taken once, before any virtual display (#58).

    private var fpsTimer: DispatchSourceTimer?
    private let frameLock = NSLock()
    private var frames = 0
    private var lastFrames = 0
    private var bytes = 0           // encoded bytes since the last telemetry tick (→ measured Mbps)

    private var running = false
    private var generation = 0
    private var guardRetained = false   // did THIS connection retain the shared DisplayModeGuard? (balance release, #51)
    private var tele = SessionTelemetry()

    /// Serializes the ENTIRE session lifecycle (connect / openSession / retry / teardown / build /
    /// reconfigure). Before this, a connection that kept failing fired onError AND onClosed → two
    /// retries (neither bumping the generation), and those ran on arbitrary threads → a storm of
    /// concurrent openSession() racing on transport/session → crash (SIGSEGV in Session.start).
    private let lifeQ = DispatchQueue(label: "superconnect.host.life")

    /// `injector` is written on lifeQ (buildPipeline / teardown) but read on the transport's callback
    /// thread (onInput/onText), so guard it — an unlocked read while it's being replaced races the
    /// ARC refcount. Reuses frameLock (always tiny critical sections, no nesting).
    private func currentInjector() -> InputInjector? { frameLock.lock(); defer { frameLock.unlock() }; return injector }
    private func setInjector(_ inj: InputInjector?) { frameLock.lock(); injector = inj; frameLock.unlock() }

    // MARK: - ConnectionEngine

    func start(over target: TunnelTarget) {
        // A host engine can only DIAL out. A `.listen` target would mean the factory paired a host
        // engine with a receiver-side tunnel — a composition wiring bug, not a runtime condition —
        // so fail loudly rather than silently no-op.
        guard case let .dial(host, port) = target else {
            diag("HostConnection got non-dial target \(target) — refusing (host can only dial)")
            stateSubject.send(.failed(.tunnelFailed))
            return
        }
        lifeQ.async {
            self.host = host
            self.port = port
            self.running = true
            self.generation += 1
            let gen = self.generation
            self.consecutiveTimeouts = 0   // fresh user-initiated connect → reset the timeout streak
            self.triedDefaultRoute = false // re-allow the physical-pin → default-route fallback this connect
            self.tele = SessionTelemetry(); self.tele.bitrateMbps = self.bitrateMbps
            self.stateSubject.send(.connecting)
            if !self.guardRetained { DisplayModeGuard.shared.retain(); self.guardRetained = true }   // pin real-display resolution before adding the virtual one
            self.startFpsTimer()
            self.openSession(generation: gen)
        }
    }

    func disconnect() {
        // sync (not async): runs serialized with the lifecycle AND completes before returning, so the
        // app-quit path (applicationWillTerminate → disconnectAll) tears the session down before the
        // process exits — as the original synchronous disconnect did. Safe: no lifeQ block waits on
        // main, and disconnect is only called from main.
        lifeQ.sync {
            self.running = false
            self.generation += 1   // neuter all in-flight callbacks / scheduled retries
            self.fpsTimer?.cancel(); self.fpsTimer = nil
            // Only release if we actually retained — disconnect() may run on an engine whose connect()
            // never started, and the guard's refcount is shared (#51).
            if self.guardRetained { DisplayModeGuard.shared.release(); self.guardRetained = false }
            self.frameLock.lock(); let prod = self.producer; self.producer = nil; self.frameLock.unlock()
            let t = self.transport; self.transport = nil
            self.session = nil; self.virtualDisplay = nil; self.setInjector(nil)
            // Heavy teardown (producer.stop awaits VTCompressionSession invalidate) OFF the serial
            // queue so it never blocks a subsequent connect; generation bump already neutered callbacks.
            DispatchQueue.global().async {
                if let prod {
                    let sem = DispatchSemaphore(value: 0)
                    Task { await prod.stop(); sem.signal() }
                    _ = sem.wait(timeout: .now() + 2)
                }
                t?.stop()
            }
            self.stateSubject.send(.idle)
        }
    }

    /// Provide the wireless BLE proximity token to present in the next `hello` (nil = none). Read by
    /// openSession when building the Session; set by the coordinator before connect. Satisfies `ConnectionEngine`.
    func setPairingToken(_ token: String?) {
        lifeQ.async { self.pairingToken = token }
    }

    /// For wireless/LAN targets, dial over the physical interface (exclude VPN/utun). Set by the
    /// coordinator before connect; read by openSession. Satisfies `ConnectionEngine`.
    func setAvoidVirtualInterfaces(_ avoid: Bool) {
        lifeQ.async { self.avoidVirtualInterfaces = avoid }
    }

    /// Re-establish the tunnel (re-forward) before a reconnect. Set by the coordinator at connect;
    /// awaited by `retry()` so a wired link recovers a cleared USB forward instead of looping on a dead
    /// local port. nil ⇒ no tunnel layer (keep the current host:port). Satisfies `ConnectionEngine`.
    private var reopenTunnel: (() async -> TunnelTarget?)?
    func setTunnelReopen(_ reopen: (() async -> TunnelTarget?)?) {
        lifeQ.async { self.reopenTunnel = reopen }
    }

    /// Force a reconnect on system WAKE. Across sleep the SCStream silently dies and the CGVirtualDisplay
    /// is invalidated WITHOUT raising any TCP/producer error, so the passive heartbeat is slow (≈6s) or —
    /// on a half-open socket — never notices. Drive the existing retry() immediately so it tears down and
    /// rebuilds a FRESH virtual display + capture (buildPipeline). No-op if this engine isn't live.
    /// Routed through retry() on lifeQ → shares the generation guard, so it can't race / double up with a
    /// heartbeat-driven retry. Satisfies `ConnectionEngine`.
    func wakeReconnect() {
        lifeQ.async {
            guard self.running else { return }
            self.diag("system wake → forcing reconnect (rebuild display + capture)")
            self.consecutiveTimeouts = 0   // wake is not a connectivity failure; don't count it toward the cap
            self.retry(gen: self.generation)
        }
    }

    /// Live bitrate change (clamped 10–100 Mbps). Retunes the running encoder immediately AND is read
    /// by the next buildProducer, so a reconnect/rotation re-applies it. Satisfies `ConnectionEngine`.
    func setBitrate(_ mbps: Int) {
        let m = max(10, min(100, mbps))
        lifeQ.async {
            self.bitrateMbps = m
            self.tele.bitrateMbps = m
            self.telemetrySubject.send(self.tele)
            self.producer?.setBitrate(m * 1_000_000)
            self.diag("setBitrate \(m)Mbps applied (producer=\(self.producer != nil))")
        }
    }

    // MARK: - Session lifecycle — ALL on lifeQ (serial). Exactly one session is ever live; retry
    // bumps the generation so a failure's onError+onClosed (and any stale callback) collapse into one.

    /// MUST run on lifeQ.
    private func openSession(generation gen: Int) {
        guard running, gen == generation else { return }
        let transport = TcpTransport(host: host, port: port, avoidVirtualInterfaces: self.avoidVirtualInterfaces)
        let session = Session(transport: transport, role: "mac")
        session.pairingToken = self.pairingToken   // BLE proximity token (nil for wired/mDNS/manual)
        session.secretStore = KeychainPairSecretStore()   // SC-AUTH-v1: per-pair secret for wireless challenge-response (wired tablet exempts → unused)
        session.peerIsLoopback = TcpTransport.isLoopback(self.host)   // auth exemption is a CLIENT fact (wired hdc), not the peer's word (H4)
        self.transport = transport
        self.session = session

        // Transport/Session callbacks fire on the network thread → hop onto lifeQ before touching
        // lifecycle state (so they serialize with connect/retry/teardown).
        // weak session: Session holds onConnected, and onConnected referencing `session` would form a
        // Session→closure→Session cycle that leaks the Session/Transport/NWConnection on every retry. (review P2)
        session.onConnected = { [weak self, weak session] in
            guard let self, let session else { return }
            self.lifeQ.async {
                guard self.running, gen == self.generation else { return }
                self.consecutiveTimeouts = 0   // a real connection landed → streak broken
                self.handshakeDone = true      // arm the liveness heartbeat (see startFpsTimer)
                self.tele.deviceName = session.peerDeviceName   // surface the real name (wired card too)
                self.tele.peerId = session.peerId               // cross-transport id for conflict reconcile
                self.diag("handshake done host=\(self.host) peerId=\(session.peerId ?? "<nil>") name=\(session.peerDeviceName ?? "<nil>")")
                self.buildPipeline(caps: session.peerCaps, gen: gen)
            }
        }
        session.onCapsUpdate = { [weak self] caps in
            guard let self else { return }
            self.lifeQ.async {
                self.diag("onCapsUpdate fired: \(caps["screenWidth"] ?? "?")x\(caps["screenHeight"] ?? "?")")
                self.reconfigure(caps: caps, gen: gen)
            }
        }
        session.onInput = { [weak self] data in
            if let e = InputCodec.decode(data) { self?.currentInjector()?.inject(e) }   // injector read is locked
        }
        session.onText = { [weak self] t in self?.currentInjector()?.injectText(t) }
        session.onError = { [weak self] msg in
            guard let self else { return }
            self.lifeQ.async {
                guard self.running, gen == self.generation else { return }
                // A wireless pairing rejection is FATAL: the tablet refused this Mac. Retrying would
                // just re-prompt the tablet every 1.5s, so stop the lifecycle and surface a clear
                // message. Bump the generation first so the imminent onClosed→retry guards out.
                if msg.contains("pairing_rejected") {
                    self.diag("pairing rejected by tablet — fatal (no retry)")
                    self.generation += 1
                    self.running = false
                    self.teardownSession()
                    self.stateSubject.send(.failed(.pairingRejected))
                    return
                }
                // The tablet is already serving another link (single-active session). FATAL like a
                // rejection — retrying would just bounce off the tablet's guard forever. Surface a calm
                // .blocked so the user disconnects the other link instead of seeing a retry storm.
                if msg.contains("session_busy") {
                    self.diag("tablet busy (single active session) — fatal (no retry)")
                    self.generation += 1
                    self.running = false
                    self.teardownSession()
                    self.stateSubject.send(.blocked(.alreadyConnectedElsewhere))
                    return
                }
                // SC-AUTH-v1 (H4): the tablet refused our proof (or we hold no/stale secret, or the tablet
                // needs updating). FATAL like a rejection — retrying can't fix a trust mismatch; the user
                // must re-pair. Surfaced as .authFailed so the UI says "re-pair on the tablet".
                if msg.contains("auth_failed") || msg.contains("auth_required") {
                    self.diag("wireless auth failed/required — fatal (re-pair needed)")
                    self.generation += 1
                    self.running = false
                    self.teardownSession()
                    self.stateSubject.send(.failed(.authFailed))
                    return
                }
                // Repeated connect-timeouts mean the route never reaches the tablet — classically a
                // VPN/EasyConnect hijack capturing the LAN IP onto utun. Cap the retries so we surface
                // an actionable error instead of looping forever (each attempt already burns a 10s
                // watchdog). Wired vs wireless pick different guidance.
                if msg.contains("connect timeout") {
                    self.consecutiveTimeouts += 1
                    if self.consecutiveTimeouts >= self.maxConsecutiveTimeouts {
                        // A wireless dial PINNED to the physical NIC (en0) never reached the tablet. The
                        // classic cause is a full-tunnel VPN (EasyConnect) capturing every route so there
                        // is no physical-LAN path at all. Before giving up, fall back ONCE to default
                        // routing (unpinned): it connects whenever any route exists, trading the
                        // LAN-direct guarantee for reachability. Only if THAT also times out do we surface
                        // a fatal — still classified wireless so the UI shows the right guidance.
                        if self.avoidVirtualInterfaces && !self.triedDefaultRoute {
                            self.triedDefaultRoute = true
                            self.avoidVirtualInterfaces = false
                            self.consecutiveTimeouts = 0
                            self.diag("wireless en0-pin unreachable (likely a full-tunnel VPN) — retrying over the default route")
                            self.retry(gen: gen)
                            return
                        }
                        let reason: AppError = (self.avoidVirtualInterfaces || self.triedDefaultRoute) ? .wirelessUnreachable : .tunnelFailed
                        self.diag("connect timeout x\(self.consecutiveTimeouts) — fatal (\(reason))")
                        self.generation += 1
                        self.running = false
                        self.teardownSession()
                        self.stateSubject.send(.failed(reason))
                        return
                    }
                }
                self.retry(gen: gen)
            }
        }
        session.onClosed = { [weak self] in self?.lifeQ.async { self?.retry(gen: gen) } }
        session.start()
    }

    /// MUST run on lifeQ. Bumps the generation (dedup) and schedules the next openSession on lifeQ.
    /// Before reconnecting, RE-OPEN THE TUNNEL (re-forward) so a wired link self-heals when the USB
    /// forward was cleared (the old code reconnected the socket to a now-dead local port and looped on
    /// "Connection refused" forever). Wireless reopen returns the same target (no-op). If no reopen hook
    /// is set, fall back to the plain socket retry. The 1.5s backoff is preserved.
    private func retry(gen: Int) {
        guard running, gen == generation else { return }
        generation += 1                       // stale callbacks for `gen` now guard out → one retry only
        let next = generation
        teardownSession()
        stateSubject.send(.connecting)
        lifeQ.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.running, next == self.generation else { return }
            guard let reopen = self.reopenTunnel else { self.openSession(generation: next); return }
            Task { [weak self] in
                let target = await reopen()    // re-run adb/hdc forward (wired) / no-op (wireless)
                self?.lifeQ.async {
                    guard let self, self.running, next == self.generation else { return }
                    if case let .dial(host, port)? = target { self.host = host; self.port = port }
                    self.openSession(generation: next)
                }
            }
        }
    }

    /// MUST run on lifeQ. Nils the refs synchronously; stops the producer/transport off-queue so the
    /// serial lifecycle never blocks on the 2s VTCompressionSession invalidate.
    private func teardownSession() {
        handshakeDone = false   // disarm the heartbeat until the next handshake completes
        frameLock.lock(); let prod = producer; producer = nil; frameLock.unlock()
        let t = transport; transport = nil
        session = nil; virtualDisplay = nil; setInjector(nil)
        DispatchQueue.global().async {
            if let prod {
                let sem = DispatchSemaphore(value: 0)
                Task { await prod.stop(); sem.signal() }
                _ = sem.wait(timeout: .now() + 2)
            }
            t?.stop()
        }
    }

    // MARK: - Pipeline (built on connect, rebuilt on caps_update)

    /// Build the full pipeline on connect: a virtual display matching the panel, an injector bound
    /// to it, and the producer.
    private func buildPipeline(caps: [String: Any]?, gen: Int) {
        guard running, gen == generation else { return }
        var cfg = displayConfig(from: caps)
        cfg.hdr = hdrEnabled(from: caps)   // HDR reference display → macOS keeps EDR headroom
        cfg.serial = DisplaySerial.allocate()   // process-globally unique identity ⇒ always extends, never restores a mirror, never collides across simultaneous connections (#51/#58)
        let vd = VirtualDisplay(cfg)
        self.virtualDisplay = vd
        self.setInjector(InputInjector(displayID: vd.displayID))
        diag("buildPipeline \(cfg.pointWidth)x\(cfg.pointHeight) serial=\(cfg.serial) id=\(vd.displayID)")
        buildProducer(vd: vd, caps: caps, gen: gen)
    }

    /// Create + start the capture→encode→stream producer for an existing virtual display (sends
    /// video_config + a keyframe). Reused on connect and on rotation, where the display + injector
    /// are kept and only the producer is rebuilt at the new size.
    private func buildProducer(vd: VirtualDisplay, caps: [String: Any]?, gen: Int) {
        guard running, gen == generation, let session = self.session, let transport = self.transport else { return }
        let negCodec = codec(from: caps)
        let negHdr = hdrEnabled(from: caps)
        let negFps = Int(displayConfig(from: caps).refreshRate)
        let mi = vd.modeInfo()
        self.tele.resolution = "\(mi.pointW)×\(mi.pointH)"
        self.tele.codec = negCodec.rawValue.uppercased() + (negHdr ? " · HDR10" : "")
        self.telemetrySubject.send(self.tele)

        let prod = Producer(virtualDisplay: vd, fps: negFps,
                            bitrate: self.bitrateMbps * 1_000_000, codec: negCodec, hdr: negHdr)
        prod.onResolution = { [weak session] w, h in
            session?.sendVideoConfig(width: w, height: h, codec: negCodec.rawValue, hdr: negHdr ? "pq" : "off")
        }
        prod.onEncoded = { [weak self, weak prod] data, isKeyframe in
            guard let self, let prod else { return }
            // Drop frames from a STALE producer. teardown/reconfigure stop the old producer
            // ASYNCHRONOUSLY, so its last in-flight frames must NOT be sent on the (old) transport
            // nor flip the UI back to .connected after a disconnect/retry. (review P1)
            self.frameLock.lock()
            let isCurrent = (self.producer === prod)
            if isCurrent { self.frames += 1; self.bytes += data.count }
            self.frameLock.unlock()
            guard isCurrent else { return }
            transport.send(FrameCodec.encode(channel: .video, flags: isKeyframe ? .keyframe : [], payload: data))
            if self.stateSubject.value != .connected { self.stateSubject.send(.connected) }
        }
        frameLock.lock(); self.producer = prod; frameLock.unlock()   // under lock so onEncoded's ===prod check is race-free
        Task { try? await prod.start() }
    }

    /// MUST run on lifeQ. Follow tablet rotation by recreating the virtual display at the new
    /// orientation (an in-place 90° switch is rejected by CoreGraphics, #58).
    private func reconfigure(caps: [String: Any]?, gen: Int) {
        guard running, gen == generation, let vd = virtualDisplay else {
            diag("reconfigure skipped (running=\(running) gen=\(gen)/\(generation) hasVD=\(virtualDisplay != nil))"); return
        }
        let newCfg = displayConfig(from: caps)
        let mi = vd.modeInfo()
        diag("reconfigure new=\(newCfg.pointWidth)x\(newCfg.pointHeight) cur=\(mi.pointW)x\(mi.pointH)")
        if mi.pointW == newCfg.pointWidth && mi.pointH == newCfg.pointHeight { diag("reconfigure no-change"); return }
        stateSubject.send(.connecting)
        frameLock.lock(); let prod = producer; producer = nil; frameLock.unlock()
        let oldVD = virtualDisplay; virtualDisplay = nil; setInjector(nil)
        // Heavy stop + CG settle OFF the serial queue, in order (stop capture → hold old display →
        // settle), THEN hop back onto lifeQ to rebuild — so the rebuild never races other lifecycle
        // steps and the new display is only created after the old one is fully gone.
        DispatchQueue.global().async { [weak self] in
            if let prod {
                let sem = DispatchSemaphore(value: 0)
                Task { await prod.stop(); sem.signal() }
                _ = sem.wait(timeout: .now() + 2)
            }
            withExtendedLifetime(oldVD) {}         // keep the old display alive until capture has stopped
            Thread.sleep(forTimeInterval: 0.4)     // let CoreGraphics settle before recreating
            self?.lifeQ.async {
                guard let self, self.running, gen == self.generation else { return }
                self.buildPipeline(caps: caps, gen: gen)   // fresh display + injector + producer at the new orientation
            }
        }
    }

    /// Append a diagnostic line to /tmp/sc-mac-diag.log (NSLog isn't captured for this app).
    /// Self-bounding: resets the file once it passes ~256 KB so it can never eat disk; /tmp is also
    /// cleared by macOS on reboot.
    private func diag(_ s: String) {
        let path = "/tmp/sc-mac-diag.log"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 256 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        let line = s + "\n"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }

    // MARK: - Telemetry

    private func startFpsTimer() {
        guard fpsTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.frameLock.lock(); let now = self.frames; let b = self.bytes; self.bytes = 0; self.frameLock.unlock()
            // Update + publish telemetry on lifeQ so `tele` (incl. its String fields) is touched on
            // exactly one queue — never raced against buildProducer/connect/setBitrate.
            self.lifeQ.async {
                let delta = now - self.lastFrames
                self.lastFrames = now
                self.tele.fps = max(0, delta / 2)
                self.tele.actualMbps = Int((Double(b) * 8.0 / 2.0 / 1_000_000.0).rounded())   // measured output over the 2s window
                self.telemetrySubject.send(self.tele)
                // Liveness heartbeat (only once handshaked): ping the tablet every 2s. If pongs stop
                // arriving (half-open link the TCP stack didn't surface — e.g. a cleared adb forward),
                // Session.sendPing trips onError("heartbeat timeout") → retry → re-forward → reconnect.
                if self.handshakeDone { self.session?.sendPing() }
            }
        }
        t.resume()
        fpsTimer = t
    }

    // MARK: - Caps → config

    /// Build a virtual display matching ANY tablet's panel from its reported caps. Adapts to
    /// arbitrary resolution + refresh; clamps the long edge to an encoder-safe size (preserving
    /// aspect) and forces even pixels so the H.264/HEVC encoder is happy on any device.
    private func displayConfig(from caps: [String: Any]?) -> VirtualDisplayConfig {
        guard let caps,
              let rawW = (caps["screenWidth"] as? NSNumber)?.intValue,
              let rawH = (caps["screenHeight"] as? NSNumber)?.intValue,
              rawW >= 640, rawH >= 400 else { return VirtualDisplayConfig() }
        let scale = 2
        var pw = rawW, ph = rawH
        // Cap the long edge (codec level limits) preserving aspect — a no-op for current tablets.
        let maxEdge = 4096
        if max(pw, ph) > maxEdge {
            let f = Double(maxEdge) / Double(max(pw, ph))
            pw = Int((Double(pw) * f).rounded()); ph = Int((Double(ph) * f).rounded())
        }
        // Backing pixels divisible by 2×scale ⇒ whole point dims and even pixels (encoder-safe).
        let step = 2 * scale
        pw -= pw % step; ph -= ph % step
        let reported = (caps["refreshRate"] as? NSNumber)?.doubleValue ?? 60
        let refresh = max(30, min(Double(maxFps), reported))
        return VirtualDisplayConfig(pointWidth: pw / scale, pointHeight: ph / scale, scale: scale, refreshRate: refresh)
    }

    private func codec(from caps: [String: Any]?) -> VideoCodec {
        // Compatibility escape hatch (AppViewModel's 编码 toggle): force H.264 even if the tablet offers
        // HEVC, for devices whose HEVC decoder misbehaves. Read here so it applies at session build.
        if UserDefaults.standard.bool(forKey: "sc.forceH264") { return .h264 }
        if let arr = caps?["codecs"] as? [Any], arr.compactMap({ $0 as? String }).contains("hevc") { return .hevc }
        return .h264
    }

    /// HDR10/PQ negotiation. GATED OFF (2026-05-31): a private CGVirtualDisplay cannot report
    /// EDR>1.0, so macOS tone-maps HDR→SDR before capture (no real benefit). The HDR transport
    /// is intact — flip this back on when the source can be HDR (e.g. a DriverKit HDR display).
    private func hdrEnabled(from caps: [String: Any]?) -> Bool {
        _ = caps
        return false
    }
}
