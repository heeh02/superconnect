import Foundation
import Combine

/// Real, built-now discovery for WIRED devices: polls `hdc list targets` (~2s) and
/// publishes one `Device` per attached serial. Replaces the old "blindly retry against
/// the one assumed tablet" behavior — discovery is now explicit and multi-device.
final class WiredDiscovery: DeviceDiscovery {
    let kind: TransportKind = .wired
    private let port: UInt16
    private let subject = CurrentValueSubject<[Device], Never>([])
    private var timer: DispatchSourceTimer?
    /// Real device name (e.g. "HUAWEI MatePad Pro") per serial, queried once over hdc. Cached so we
    /// don't re-run `param get` every 2s poll; only successful names are cached (a not-yet-ready param
    /// is retried next poll instead of being pinned to the serial fallback).
    private var nameCache: [String: String] = [:]

    init(port: UInt16 = 8888) { self.port = port }

    var devices: AnyPublisher<[Device], Never> { subject.eraseToAnyPublisher() }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sc.wired.discovery"))
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        let serials = HdcTool.listTargets()
        let next = serials.map { serial in
            Device(id: serial,
                   name: displayName(for: serial),
                   transport: .wired,
                   capabilities: .canReceive,    // tablet receives; Mac hosts (today)
                   endpoint: .wiredHdc(serial: serial, port: port))
        }
        nameCache = nameCache.filter { serials.contains($0.key) }   // forget unplugged devices
        // Republish on ANY change (id set OR a name resolving from the serial fallback to the real
        // market name a poll later), not just when the serial set changes.
        if next != subject.value { subject.send(next) }
    }

    /// The real market name if hdc can read it (cached after the first success), else the serial
    /// fallback. Queried lazily so a freshly-attached device's card still appears promptly.
    private func displayName(for serial: String) -> String {
        if let cached = nameCache[serial] { return cached }
        if let real = HdcTool.deviceName(serial: serial) {
            nameCache[serial] = real
            return real
        }
        return friendlyName(for: serial)
    }

    private func friendlyName(for serial: String) -> String {
        "平板设备 · " + String(serial.suffix(4))
    }
}
