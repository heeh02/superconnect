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

    private let bitrateMbps = 50
    private let maxFps = 120

    private var host = "127.0.0.1"
    private var port: UInt16 = 8888

    private var transport: TcpTransport?
    private var session: Session?
    private var virtualDisplay: VirtualDisplay?
    private var producer: Producer?
    private var injector: InputInjector?

    private var fpsTimer: DispatchSourceTimer?
    private let frameLock = NSLock()
    private var frames = 0
    private var lastFrames = 0

    private var running = false
    private var generation = 0
    private var tele = SessionTelemetry()

    // MARK: - ConnectionEngine

    func connect(host: String, port: UInt16) {
        self.host = host
        self.port = port
        running = true
        generation += 1
        tele = SessionTelemetry(); tele.bitrateMbps = bitrateMbps
        stateSubject.send(.connecting)
        startFpsTimer()
        openSession(generation: generation)
    }

    func disconnect() {
        running = false
        generation += 1
        fpsTimer?.cancel(); fpsTimer = nil
        // Heavy teardown (producer.stop awaits VTCompressionSession invalidate) off the
        // main thread so the UI never hangs; generation bump already neutered callbacks.
        let prod = producer; producer = nil
        let t = transport; transport = nil
        session = nil; virtualDisplay = nil; injector = nil
        DispatchQueue.global().async {
            if let prod {
                let sem = DispatchSemaphore(value: 0)
                Task { await prod.stop(); sem.signal() }
                _ = sem.wait(timeout: .now() + 2)
            }
            t?.stop()
        }
        stateSubject.send(.idle)
    }

    // MARK: - Session lifecycle (generation-guarded retry)

    private func openSession(generation gen: Int) {
        guard running, gen == generation else { return }
        let transport = TcpTransport(host: host, port: port)
        let session = Session(transport: transport, role: "mac")
        self.transport = transport
        self.session = session

        session.onConnected = { [weak self] in
            guard let self, self.running, gen == self.generation else { return }
            let negCodec = self.codec(from: session.peerCaps)
            let negHdr = self.hdrEnabled(from: session.peerCaps)
            var cfg = self.displayConfig(from: session.peerCaps)
            cfg.hdr = negHdr   // HDR reference display → macOS keeps EDR headroom
            let vd = VirtualDisplay(cfg)
            self.virtualDisplay = vd
            self.injector = InputInjector(displayID: vd.displayID)
            let negFps = Int(cfg.refreshRate)
            let mi = vd.modeInfo()
            self.tele.resolution = "\(mi.pointW)×\(mi.pointH)"
            self.tele.codec = negCodec.rawValue.uppercased() + (negHdr ? " · HDR10" : "")
            self.telemetrySubject.send(self.tele)

            let prod = Producer(virtualDisplay: vd, fps: negFps,
                                bitrate: self.bitrateMbps * 1_000_000, codec: negCodec, hdr: negHdr)
            prod.onResolution = { w, h in
                session.sendVideoConfig(width: w, height: h, codec: negCodec.rawValue, hdr: negHdr ? "pq" : "off")
            }
            prod.onEncoded = { [weak self] data, isKeyframe in
                transport.send(FrameCodec.encode(channel: .video, flags: isKeyframe ? .keyframe : [], payload: data))
                guard let self else { return }
                self.frameLock.lock(); self.frames += 1; self.frameLock.unlock()
                if self.stateSubject.value != .connected { self.stateSubject.send(.connected) }
            }
            self.producer = prod
            Task { try? await prod.start() }
        }
        session.onInput = { [weak self] data in
            if let e = InputCodec.decode(data) { self?.injector?.inject(e) }
        }
        session.onText = { [weak self] t in self?.injector?.injectText(t) }
        session.onError = { [weak self] _ in self?.retry(gen: gen) }
        session.onClosed = { [weak self] in self?.retry(gen: gen) }
        session.start()
    }

    private func retry(gen: Int) {
        guard running, gen == generation else { return }
        teardownSession()
        stateSubject.send(.connecting)
        let next = generation
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.openSession(generation: next)
        }
    }

    private func teardownSession() {
        let prod = producer; producer = nil
        if let prod {
            let sem = DispatchSemaphore(value: 0)
            Task { await prod.stop(); sem.signal() }
            _ = sem.wait(timeout: .now() + 2)
        }
        transport?.stop()
        session = nil; transport = nil; virtualDisplay = nil; injector = nil
    }

    // MARK: - Telemetry

    private func startFpsTimer() {
        guard fpsTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.frameLock.lock(); let now = self.frames; self.frameLock.unlock()
            let delta = now - self.lastFrames
            self.lastFrames = now
            self.tele.fps = max(0, delta / 2)
            self.telemetrySubject.send(self.tele)
        }
        t.resume()
        fpsTimer = t
    }

    // MARK: - Caps → config

    private func displayConfig(from caps: [String: Any]?) -> VirtualDisplayConfig {
        guard let caps,
              let sw = (caps["screenWidth"] as? NSNumber)?.intValue,
              let sh = (caps["screenHeight"] as? NSNumber)?.intValue,
              sw >= 640, sh >= 400 else { return VirtualDisplayConfig() }
        let scale = 2
        let reported = (caps["refreshRate"] as? NSNumber)?.doubleValue ?? 60
        let refresh = max(30, min(Double(maxFps), reported))
        return VirtualDisplayConfig(pointWidth: sw / scale, pointHeight: sh / scale, scale: scale, refreshRate: refresh)
    }

    private func codec(from caps: [String: Any]?) -> VideoCodec {
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
