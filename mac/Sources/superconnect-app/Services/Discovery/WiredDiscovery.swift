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
                   name: friendlyName(for: serial),
                   transport: .wired,
                   capabilities: .canReceive,    // tablet receives; Mac hosts (today)
                   endpoint: .wiredHdc(serial: serial, port: port))
        }
        if next.map(\.id) != subject.value.map(\.id) { subject.send(next) }
    }

    private func friendlyName(for serial: String) -> String {
        "平板设备 · " + String(serial.suffix(4))
    }
}
