import Foundation
import Combine

/// Wired discovery for ANDROID tablets via `adb devices` (~2s poll), mirroring `WiredDiscovery`'s
/// hdc path. Publishes one `.wired`-badged `Device` per authorized serial, reached through a
/// `.wiredAdb` endpoint (→ `AdbFportTunnel`). Ids are namespaced `adb:<serial>` so an Android serial
/// can never collide with a HarmonyOS hdc serial in the merged store. Free tier: 1 Mac ↔ 1 pad still
/// works here; multi-device is unaffected (each serial is its own card).
final class AndroidWiredDiscovery: DeviceDiscovery {
    let kind: TransportKind = .wired
    private let port: UInt16
    private let subject = CurrentValueSubject<[Device], Never>([])
    private var timer: DispatchSourceTimer?
    private var nameCache: [String: String] = [:]   // serial → real name (queried once over adb)

    init(port: UInt16 = 8888) { self.port = port }

    var devices: AnyPublisher<[Device], Never> { subject.eraseToAnyPublisher() }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sc.android.wired.discovery"))
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        let serials = AdbTool.listDevices()
        let next = serials.map { serial in
            Device(id: "adb:\(serial)",
                   name: displayName(for: serial),
                   transport: .wired,
                   capabilities: .canReceive,
                   endpoint: .wiredAdb(serial: serial, port: port))
        }
        nameCache = nameCache.filter { serials.contains($0.key) }   // forget unplugged devices
        if next != subject.value { subject.send(next) }
    }

    private func displayName(for serial: String) -> String {
        if let cached = nameCache[serial] { return cached }
        if let real = AdbTool.deviceName(serial: serial) {
            nameCache[serial] = real
            return real
        }
        return "安卓设备 · " + String(serial.suffix(4))
    }
}
