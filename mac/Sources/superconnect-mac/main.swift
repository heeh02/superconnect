import Foundation
import CoreGraphics
import AppKit
import SuperconnectCore
import SuperconnectProducer

// The Mac app.
//   swift run superconnect-mac                  # Phase 0: connectivity/handshake + RTT
//   swift run superconnect-mac --produce         # Phase 1: host the extended display
//   swift run superconnect-mac --produce --fps 60 --bitrate 30000000 --host 127.0.0.1 --port 8888
//
// In both modes the Mac is the TCP CLIENT, reaching the tablet's server through
// `hdc fport tcp:<port> tcp:<port>` over USB (or directly over LAN later).

let argv = CommandLine.arguments
setvbuf(stdout, nil, _IONBF, 0) // unbuffered stdout so logs appear live when redirected
func hasFlag(_ name: String) -> Bool { argv.contains(name) }
func value(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

let host = value("--host") ?? "127.0.0.1"
let port = UInt16(value("--port") ?? "8888") ?? 8888
let bitrate = Int(value("--bitrate") ?? "50000000") ?? 50_000_000
let maxFps = Int(value("--maxfps") ?? "120") ?? 120   // cap; actual fps negotiated from the tablet's panel

/// Tiny lock-guarded counter (onEncoded runs on the encoder queue, the stats
/// timer on another queue).
final class AtomicInt {
    private let lock = NSLock()
    private var v = 0
    func inc() { lock.lock(); v += 1; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return v }
}

/// Build a virtual-display config matching the tablet's native panel (from the
/// handshake caps): resolution, refresh rate, so the stream is 1:1 and as smooth
/// as the panel allows. Falls back to sensible defaults for unknown tablets.
func displayConfigFromCaps(_ caps: [String: Any]?, maxFps: Int) -> VirtualDisplayConfig {
    guard let caps,
          let sw = (caps["screenWidth"] as? NSNumber)?.intValue,
          let sh = (caps["screenHeight"] as? NSNumber)?.intValue,
          sw >= 640, sh >= 400 else {
        return VirtualDisplayConfig()
    }
    let scale = 2
    let reported = (caps["refreshRate"] as? NSNumber)?.doubleValue ?? 60
    let refresh = max(30, min(Double(maxFps), reported))
    return VirtualDisplayConfig(pointWidth: sw / scale, pointHeight: sh / scale,
                                scale: scale, refreshRate: refresh)
}

/// Pick the best codec the tablet can hardware-decode (extensible: av1 later).
func codecFromCaps(_ caps: [String: Any]?) -> VideoCodec {
    if let arr = caps?["codecs"] as? [Any] {
        let codecs = arr.compactMap { $0 as? String }
        if codecs.contains("hevc") { return .hevc }
    }
    return .h264
}

/// HDR10/PQ negotiation. GATED OFF (2026-05-31): a private CGVirtualDisplay cannot report
/// EDR>1.0, so macOS tone-maps HDR→SDR before capture and the 10-bit path gives no real
/// benefit. The full HDR transport (capture/encode/decode) is intact — flip this back on
/// when the source can actually be HDR (e.g. a DriverKit HDR virtual display).
func hdrFromCaps(_ caps: [String: Any]?) -> Bool {
    _ = caps
    return false
}

if hasFlag("--produce") {
    runProduce(host: host, port: port, bitrate: bitrate)
} else {
    runPing(host: host, port: port)
}

// ───────────────────────────── Phase 0: ping ───────────────────────────────
func runPing(host: String, port: UInt16) {
    print("[superconnect-mac] (ping) connecting to \(host):\(port) …")
    let transport = TcpTransport(host: host, port: port)
    let session = Session(transport: transport, role: "mac")
    var pingsLeft = 3
    var shuttingDown = false

    session.onLog = { print("[session] \($0)") }
    session.onConnected = {
        print("[superconnect-mac] handshake OK. peer caps: \(session.peerCaps ?? [:])")
        session.sendPing()
    }
    session.onRTT = { rtt in
        print(String(format: "[superconnect-mac] RTT = %.3f ms", rtt))
        pingsLeft -= 1
        if pingsLeft <= 0 {
            shuttingDown = true
            session.sendBye()
            print("[superconnect-mac] done ✓")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { session.sendPing() }
        }
    }
    session.onError = { fputs("[superconnect-mac] ERROR: \($0)\n", stderr); exit(1) }
    session.onClosed = { if shuttingDown { exit(0) }; fputs("[superconnect-mac] closed by peer\n", stderr); exit(1) }

    DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
        fputs("[superconnect-mac] TIMEOUT — is the tablet listening and 'hdc fport tcp:\(port) tcp:\(port)' set up?\n", stderr)
        exit(2)
    }
    session.start()
    RunLoop.main.run()
}

// ─────────────────────────── Phase 1: produce ──────────────────────────────
func runProduce(host: String, port: UInt16, bitrate: Int) {
    print("[superconnect-mac] (produce) connecting to \(host):\(port) …")

    // Permission preflight (both gates must be granted for a full session).
    if !ScreenCapture.hasScreenRecordingPermission() {
        ScreenCapture.requestScreenRecordingPermission()
        fputs("[superconnect-mac] ⚠️ grant Screen Recording (System Settings → Privacy → Screen & System Audio Recording)\n", stderr)
    }
    if !InputInjector.hasAccessibilityPermission() {
        InputInjector.requestAccessibilityPermission()
        fputs("[superconnect-mac] ⚠️ grant Accessibility (System Settings → Privacy → Accessibility) for input injection\n", stderr)
    }

    let transport = TcpTransport(host: host, port: port)
    let session = Session(transport: transport, role: "mac")

    // Retained for the lifetime of the process so the virtual display stays attached.
    var virtualDisplay: VirtualDisplay?
    var producer: Producer?
    var injector: InputInjector?
    let frameCount = AtomicInt()
    var inputCount = 0

    session.onLog = { print("[session] \($0)") }

    session.onConnected = {
        print("[superconnect-mac] handshake OK. peer caps: \(session.peerCaps ?? [:])")
        let negCodec = codecFromCaps(session.peerCaps)
        let negHdr = hdrFromCaps(session.peerCaps)
        var cfg = displayConfigFromCaps(session.peerCaps, maxFps: maxFps)
        cfg.hdr = negHdr   // create the virtual display as HDR so macOS keeps EDR headroom
        let vd = VirtualDisplay(cfg)
        virtualDisplay = vd
        injector = InputInjector(displayID: vd.displayID)
        let mi = vd.modeInfo()
        let negFps = Int(cfg.refreshRate)
        let actualHz = vd.currentRefreshRate()
        print("[superconnect-mac] virtual display \(vd.displayID): \(mi.pointW)×\(mi.pointH) pts, \(mi.pixelW)×\(mi.pixelH) backing @ \(negFps)Hz (macOS mode reports \(String(format: "%.0f", actualHz))Hz), codec \(negCodec.rawValue)\(negHdr ? " HDR10/PQ" : "")")
        if negHdr {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                for s in NSScreen.screens where (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == vd.displayID {
                    print(String(format: "[superconnect-mac] HDR display check: EDR max=%.2f potential=%.2f (>1.0 = HDR active)",
                                 s.maximumExtendedDynamicRangeColorComponentValue,
                                 s.maximumPotentialExtendedDynamicRangeColorComponentValue))
                }
            }
        }
        let vb = vd.bounds()
        print("[superconnect-mac] display global bounds: origin=(\(Int(vb.minX)),\(Int(vb.minY))) size=\(Int(vb.width))×\(Int(vb.height)) pts  ← touches map into this rect")

        let prod = Producer(virtualDisplay: vd, fps: negFps, bitrate: bitrate, codec: negCodec, hdr: negHdr)
        prod.onResolution = { w, h in
            print("[superconnect-mac] encoding \(w)×\(h)@\(negFps) \(negCodec.rawValue)\(negHdr ? " HDR10" : "") → sending video_config")
            session.sendVideoConfig(width: w, height: h, codec: negCodec.rawValue, hdr: negHdr ? "pq" : "off")
        }
        prod.onEncoded = { data, isKeyframe in
            transport.send(FrameCodec.encode(channel: .video,
                                             flags: isKeyframe ? .keyframe : [],
                                             payload: data))
            frameCount.inc()
            // Diag: keyframes are infrequent; their cadence (and their absence after ~2s
            // static) confirms idle is now P-frame-refined rather than re-keyframed.
            if isKeyframe { print("[superconnect-mac] keyframe \(data.count / 1024)KB") }
        }
        prod.onError = { fputs("[superconnect-mac] producer: \($0)\n", stderr) }
        producer = prod
        Task {
            do { try await prod.start() }
            catch { fputs("[superconnect-mac] capture failed: \(error.localizedDescription)\n", stderr) }
        }
    }

    session.onInput = { data in
        if let event = InputCodec.decode(data) {
            injector?.inject(event)
            inputCount += 1
            let t = InputType(rawValue: event.type)
            if t == .keyDown || t == .keyUp {
                let verb = (t == .keyDown) ? "down" : "up"
                print("[superconnect-mac] key #\(inputCount) \(verb) hmKeyCode=\(Int(event.keyCode)) flags=0x" + String(Int(event.flags), radix: 16))
            } else {
                let discrete = (t == .touchDown || t == .touchUp || (t == .zoom && event.buttons != 0)) // clicks / right-clicks / drag ends / pinch begin+end
                if discrete || inputCount % 30 == 0 {
                    print(String(format: "[superconnect-mac] input #%d tool=%d type=%d btn=%d x=%.3f y=%.3f p=%.3f sx=%.1f sy=%.1f",
                                 inputCount, Int(event.tool), Int(event.type), Int(event.buttons),
                                 event.x, event.y, event.pressure, event.scrollX, event.scrollY))
                }
            }
        }
    }
    session.onText = { print("[superconnect-mac] text: \"\($0)\""); injector?.injectText($0) }   // committed Unicode (IME) → typed on Mac
    session.onError = {
        fputs("[superconnect-mac] ERROR: \($0)\n", stderr)
        // Fatal for this session (e.g. connection reset). Exit so the supervisor
        // loop relaunches and keeps retrying until the tablet accepts again.
        exit(1)
    }
    session.onClosed = {
        if let vd = virtualDisplay { print("[superconnect-mac] tearing down virtual display \(vd.displayID)") }
        // Tear down capture/encoder synchronously so stopCapture +
        // VTCompressionSessionInvalidate actually run before we exit.
        let sem = DispatchSemaphore(value: 0)
        Task { await producer?.stop(); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
        fputs("[superconnect-mac] connection closed.\n", stderr)
        exit(0)
    }

    // Periodic throughput readout.
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + 2, repeating: 2)
    var last = 0
    timer.setEventHandler {
        let now = frameCount.get()
        let delta = now - last
        last = now
        if delta > 0 { print("[superconnect-mac] streaming ~\(delta / 2) fps") }
    }
    timer.resume()

    session.start()
    RunLoop.main.run()
}
