import Foundation
import Combine
import CoreBluetooth

/// WIRELESS discovery over BLE (v0.2.2) — the SUBNET-INDEPENDENT path. On a big routed Wi-Fi the Mac
/// and tablet often land on different subnets where mDNS multicast can't reach (so `WirelessDiscovery`
/// finds nothing) even though the IP route works. The tablet BROADCASTS its bootstrap payload
/// {ipv4, port, token} in the BLE advertisement (manufacturer data); this central reads it straight
/// from the scan — NO GATT connection (macOS↔HarmonyOS GATT connect proved unreliable on-device).
/// It publishes a `.wireless` Device with `.tcp(host,port)` + the proximity `pairingToken`; connecting
/// reuses the EXISTING path (DirectTunnel → TcpTransport → HostConnection). BLE carries ONLY bootstrap.
///
/// Requires `NSBluetoothAlwaysUsageDescription` in Info.plist; the one-time Bluetooth permission
/// persists across rebuilds via the app's stable self-signed identity (like Screen Recording).
/// Manufacturer id + payload layout MUST match the tablet (BleAdvertiser.ets).
final class BleDiscovery: NSObject, DeviceDiscovery {
    let kind: TransportKind = .wireless

    private static let mfrID: UInt16 = 0x05C0   // private manufacturer id tagging our advert

    private let subject = CurrentValueSubject<[Device], Never>([])
    private let bleQueue = DispatchQueue(label: "sc.ble.discovery")
    private var central: CBCentralManager?
    private var wantScan = false
    /// Resolved devices keyed by the peripheral identity (stable per-Mac) so re-reads dedupe.
    private var found: [String: Device] = [:]
    /// Last time each device's advert was seen — used to age out tablets that left range / turned
    /// wireless off / rotated their token (CoreBluetooth gives no "gone" callback for adverts).
    private var lastSeen: [String: Date] = [:]
    private var pruneTimer: DispatchSourceTimer?
    private static let staleAfter: TimeInterval = 20   // drop a device not re-advertised within this

    var devices: AnyPublisher<[Device], Never> { subject.eraseToAnyPublisher() }

    func start() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.wantScan = true
            self.startPruneTimer()
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.bleQueue)   // triggers BT permission prompt
            } else if self.central?.state == .poweredOn {
                self.beginScan()
            }
        }
    }

    func stop() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.wantScan = false
            self.central?.stopScan()
            self.pruneTimer?.cancel(); self.pruneTimer = nil
            self.found.removeAll()
            self.lastSeen.removeAll()
            self.subject.send([])
        }
    }

    // MARK: - internals (all on bleQueue)

    private func beginScan() {
        diag("scan start (auth=\(CBManager.authorization.rawValue))")
        // Scan ALL devices and filter by our manufacturer id — robust regardless of which advert
        // packet carries the service UUID. allowDuplicates ON so a still-present tablet keeps
        // refreshing its last-seen stamp (and any rotated token), enabling reliable staleness pruning.
        central?.scanForPeripherals(withServices: nil,
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Drop devices whose advert hasn't been seen within `staleAfter` (left range / wireless off).
    private func startPruneTimer() {
        guard pruneTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: bleQueue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-BleDiscovery.staleAfter)
            let stale = self.lastSeen.filter { $0.value < cutoff }.map { $0.key }
            guard !stale.isEmpty else { return }
            for id in stale { self.found[id] = nil; self.lastSeen[id] = nil }
            self.diag("pruned \(stale.count) stale device(s)")
            self.publish()
        }
        t.resume()
        pruneTimer = t
    }

    private func publish() { subject.send(Array(found.values).sorted { $0.name < $1.name }) }

    /// Parse our manufacturer data `[id-LE(2)][ipv4(4)][port-BE(2)][token(8)]` → a `.wireless` Device.
    private static func device(from mfr: Data, name: String?, peripheralId: UUID) -> Device? {
        let b = [UInt8](mfr)
        guard b.count >= 2 + 14 else { return nil }
        let company = UInt16(b[0]) | (UInt16(b[1]) << 8)
        guard company == mfrID else { return nil }
        let p = Array(b[2...])
        let ip = "\(p[0]).\(p[1]).\(p[2]).\(p[3])"
        let port = (UInt16(p[4]) << 8) | UInt16(p[5])
        guard port != 0, p[0] != 0 else { return nil }
        let token = p[6..<14].map { String(format: "%02x", $0) }.joined()
        let display = (name?.isEmpty == false) ? name! : ip
        return Device(id: "ble:\(peripheralId.uuidString)", name: display, transport: .wireless,
                      capabilities: .canReceive, endpoint: .tcp(host: ip, port: port),
                      pairingToken: token.isEmpty ? nil : token)
    }

    /// Append a diagnostic line to /tmp/sc-mac-diag.log (shared with HostConnection). Self-bounding.
    func diag(_ s: String) {
        let path = "/tmp/sc-mac-diag.log"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 256 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = ("BLE: " + s + "\n").data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }
}

extension BleDiscovery: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        diag("central state=\(central.state.rawValue) auth=\(CBManager.authorization.rawValue) wantScan=\(wantScan)")
        if central.state == .poweredOn, wantScan { beginScan() }
        // .unauthorized / .poweredOff → wireless still works via mDNS / manual IP. Nothing to surface here.
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let device = BleDiscovery.device(from: mfr, name: peripheral.name, peripheralId: peripheral.identifier)
        else { return }
        lastSeen[device.id] = Date()                 // keep-alive (allowDuplicates fires repeatedly)
        guard found[device.id] != device else { return }   // unchanged → just refreshed; don't republish
        if found[device.id] == nil { diag("read OK \(device.name) \(device.endpoint) tok=\(device.pairingToken != nil)") }
        found[device.id] = device
        publish()
    }
}
