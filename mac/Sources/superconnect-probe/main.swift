import Foundation
import CoreGraphics
import AppKit
import SuperconnectProducer
import SuperconnectCore
import CGVirtualDisplayPrivate

// Phase 1 probe.
//
//   swift run superconnect-probe                       # step A only (no TCC)
//   swift run superconnect-probe --capture             # + capture & encode 5s
//   swift run superconnect-probe --capture --seconds 8 --fps 60 --bitrate 30000000
//   swift run superconnect-probe --capture --stream 127.0.0.1:8888   # also push VIDEO frames
//
// Step A validates the private virtual-display API via CoreGraphics (no TCC).
// Step B validates ScreenCaptureKit enumeration + capture + VideoToolbox encode
// (needs Screen Recording permission).

let argv = CommandLine.arguments
func hasFlag(_ name: String) -> Bool { argv.contains(name) }
func value(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

// ─────────────── HDR diagnostic: can a CGVirtualDisplay report EDR > 1.0? ───────────
//   swift run superconnect-probe --hdrdump
// Bounded: a few sequential create/teardown cycles (NOT a runaway sweep).
if hasFlag("--hdrdump") {
    func edr(_ id: CGDirectDisplayID) -> (Double, Double) {
        for s in NSScreen.screens
        where (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id {
            return (s.maximumExtendedDynamicRangeColorComponentValue,
                    s.maximumPotentialExtendedDynamicRangeColorComponentValue)
        }
        return (-1, -1)
    }
    let main = CGMainDisplayID()
    let me = edr(main)
    print("[hdrdump] built-in main display \(main): EDR max=\(me.0) potential=\(me.1)  (>1.0 = the Mac CAN show HDR)")

    func test(_ label: String, isRef: Bool, tf: Int?, dumpInfo: Bool) {
        let d = CGVirtualDisplayDescriptor()
        d.queue = DispatchQueue.global(qos: .userInteractive)
        d.name = "HDRProbe"
        d.maxPixelsWide = 2880; d.maxPixelsHigh = 1920
        d.sizeInMillimeters = CGSize(width: 290, height: 190)
        d.productID = 0x53; d.vendorID = 0x43; d.serialNum = 1
        d.redPrimary = CGPoint(x: 0.708, y: 0.292); d.greenPrimary = CGPoint(x: 0.170, y: 0.797)
        d.bluePrimary = CGPoint(x: 0.131, y: 0.046); d.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        let disp = CGVirtualDisplay(descriptor: d)
        let s = CGVirtualDisplaySettings()
        s.hiDPI = 1; s.isReference = isRef
        let m = CGVirtualDisplayMode(width: 2880, height: 1920, refreshRate: 60)
        if let tf = tf { m.setValue(NSNumber(value: tf), forKey: "transferFunction") }
        s.modes = [m]
        _ = disp.apply(s)
        let id = disp.displayID
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let e = edr(id)
        print("[\(label)] id=\(id) isRef=\(isRef) tf=\(tf.map(String.init) ?? "nil") → EDR max=\(e.0) potential=\(e.1)")
        if dumpInfo, let info = d.value(forKey: "displayInfo") {
            print("  descriptor.displayInfo keys = \((info as? [String: Any])?.keys.sorted() ?? [])")
            print("  descriptor.displayInfo = \(info)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))   // let teardown settle
    }
    test("baseline", isRef: false, tf: nil, dumpInfo: false)
    test("ref-only", isRef: true, tf: nil, dumpInfo: true)
    test("ref+tf16(PQ)", isRef: true, tf: 16, dumpInfo: false)
    test("ref+tf18(HLG)", isRef: true, tf: 18, dumpInfo: false)
    test("ref+tf2", isRef: true, tf: 2, dumpInfo: false)
    print("[hdrdump] done")
    exit(0)
}

let doCapture = hasFlag("--capture")
let seconds = Double(value("--seconds") ?? "5") ?? 5
let fps = Int(value("--fps") ?? "60") ?? 60
let bitrate = Int(value("--bitrate") ?? "20000000") ?? 20_000_000
let streamTarget = value("--stream")

// ─────────────── HiDPI characterization (no TCC needed) ────────────────────
//   swift run superconnect-probe --modew 1280 --modeh 800 --maxw 2560 --maxh 1600 --hidpi 1
if let mwS = value("--modew") {
    let mw = Int(mwS) ?? 1280
    let mh = Int(value("--modeh") ?? "800") ?? 800
    let maxw = Int(value("--maxw") ?? String(mw)) ?? mw
    let maxh = Int(value("--maxh") ?? String(mh)) ?? mh
    let hidpi = (value("--hidpi") ?? "1") == "1"
    let vd = VirtualDisplay(name: "exp", modeWidth: mw, modeHeight: mh,
                            maxPixelsWide: maxw, maxPixelsHigh: maxh, hiDPI: hidpi)
    Thread.sleep(forTimeInterval: 0.7)
    let b = vd.bounds()
    let mi = vd.modeInfo()
    print("[exp] mode=\(mw)×\(mh) max=\(maxw)×\(maxh) hidpi=\(hidpi) → id=\(vd.displayID) active=\(vd.isActiveInCoreGraphics()) mirrored=\(vd.isMirrored())")
    print("[exp]   bounds(pts)=\(Int(b.width))×\(Int(b.height))  modePoints=\(mi.pointW)×\(mi.pointH)  backingPixels=\(mi.pixelW)×\(mi.pixelH)")
    exit(0)
}

// ───────────────────────── Step A: virtual display ─────────────────────────
print("[probe] === step A: virtual display (risk #1, no TCC) ===")
print("[probe] creating CGVirtualDisplay 2560×1600@60 HiDPI …")
let vd = VirtualDisplay()
Thread.sleep(forTimeInterval: 0.7)

let active = vd.isActiveInCoreGraphics()
let mirrored = vd.isMirrored()
let bounds = vd.bounds()
let mi = vd.modeInfo()
print("[probe] displayID              = \(vd.displayID)")
print("[probe] active in CoreGraphics = \(active)")
print("[probe] mirrored               = \(mirrored)   (false ⇒ true extended display)")
print("[probe] logical points         = \(mi.pointW)×\(mi.pointH)  (bounds \(Int(bounds.width))×\(Int(bounds.height)) @ (\(Int(bounds.minX)),\(Int(bounds.minY))))")
print("[probe] backing pixels         = \(mi.pixelW)×\(mi.pixelH)  (HiDPI ⇒ 2× points)")

guard vd.displayID != 0, active, !mirrored else {
    print("[probe] ❌ step A FAIL — not an active extended display.")
    exit(1)
}
print("[probe] ✅ step A PASS — extended virtual display recognized by CoreGraphics.")

if !doCapture {
    print("[probe] (run with --capture to validate ScreenCaptureKit + VideoToolbox)")
    exit(0)
}

// ───────────────────────── Step B: capture + encode ────────────────────────
print("[probe] === step B: capture + encode (risk #1 capture half) ===")
if !ScreenCapture.hasScreenRecordingPermission() {
    print("[probe] ⚠️ Screen Recording permission not granted — requesting…")
    ScreenCapture.requestScreenRecordingPermission()
    print("[probe]   If capture yields 0 frames, grant it in:")
    print("[probe]   System Settings → Privacy & Security → Screen & System Audio Recording")
    print("[probe]   (enable your terminal), then re-run.")
}

final class Stats {
    private let lock = NSLock()
    private(set) var frames = 0, bytes = 0, keyframes = 0, sentBytes = 0
    func add(bytes n: Int, keyframe: Bool) {
        lock.lock(); frames += 1; bytes += n; if keyframe { keyframes += 1 }; lock.unlock()
    }
    func addSent(_ n: Int) { lock.lock(); sentBytes += n; lock.unlock() }
    func snapshot() -> (Int, Int, Int, Int) {
        lock.lock(); defer { lock.unlock() }; return (frames, bytes, keyframes, sentBytes)
    }
}
let stats = Stats()

// Optional: push encoded frames onto the VIDEO channel of a Transport.
var transport: TcpTransport?
let connected = NSLock()
var isConnected = false
if let target = streamTarget {
    let parts = target.split(separator: ":")
    if parts.count == 2, let port = UInt16(parts[1]) {
        let t = TcpTransport(host: String(parts[0]), port: port)
        t.onStateChange = { state in
            connected.lock(); isConnected = (state == .ready); connected.unlock()
            print("[probe] stream transport: \(state)")
        }
        t.start()
        transport = t
        print("[probe] streaming VIDEO frames to \(target)")
    } else {
        print("[probe] bad --stream target '\(target)', expected host:port")
    }
}

let producer = Producer(virtualDisplay: vd, fps: fps, bitrate: bitrate)
producer.onError = { print("[probe] producer error: \($0)") }
producer.onEncoded = { data, isKeyframe in
    stats.add(bytes: data.count, keyframe: isKeyframe)
    connected.lock(); let up = isConnected; connected.unlock()
    if up, let t = transport {
        let frame = FrameCodec.encode(channel: .video,
                                      flags: isKeyframe ? .keyframe : [],
                                      payload: data)
        t.send(frame)
        stats.addSent(frame.count)
    }
}

print("[probe] capturing display \(vd.displayID) for \(Int(seconds))s @ \(fps)fps, target \(bitrate / 1_000_000) Mbps …")
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        try await producer.start()
    } catch {
        print("[probe] ❌ capture start failed: \(error.localizedDescription)")
        sem.signal()
        return
    }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    await producer.stop()
    sem.signal()
}
sem.wait()

let (frames, bytes, keyframes, sentBytes) = stats.snapshot()
let avgFps = Double(frames) / seconds
let mbps = Double(bytes * 8) / seconds / 1_000_000
print("[probe] ── results ──")
print("[probe] frames encoded   = \(frames)  (~\(String(format: "%.1f", avgFps)) fps)")
print("[probe] keyframes        = \(keyframes)")
print("[probe] encoded bytes    = \(bytes)  (~\(String(format: "%.1f", mbps)) Mbps)")
if transport != nil { print("[probe] streamed bytes   = \(sentBytes)") }

if frames > 0 {
    print("[probe] ✅ step B PASS — ScreenCaptureKit enumerated & captured the virtual display; VideoToolbox produced an H.264 stream.")
    exit(0)
} else {
    print("[probe] ❌ step B — 0 frames. Almost certainly Screen Recording permission (TCC) is not granted to the terminal. Grant it and re-run.")
    exit(3)
}
