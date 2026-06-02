import Foundation
import Combine
import CoreBluetooth

/// WIRELESS discovery over BLE (v0.2.2) — the SUBNET-INDEPENDENT path. On a big routed Wi-Fi the Mac
/// and tablet often land on different subnets, where mDNS multicast can't reach (so `WirelessDiscovery`
/// finds nothing) even though the IP route works. BLE is proximity-based, not subnet-bound: the tablet
/// advertises a custom GATT service; this central scans by that service UUID, connects, reads a compact
/// JSON blob `{n,ip,p,tok,pid}`, and publishes a `.wireless` Device with the resolved `.tcp(host,port)`
/// + the proximity `pairingToken`. Connecting then reuses the EXISTING path (DirectTunnel → TcpTransport
/// → HostConnection) — BLE carries ONLY bootstrap metadata, never video/input.
///
/// Requires `NSBluetoothAlwaysUsageDescription` in Info.plist; the one-time Bluetooth permission
/// persists across rebuilds via the app's stable self-signed identity (like Screen Recording).
/// UUIDs MUST match the tablet (BleAdvertiser.ets).
final class BleDiscovery: NSObject, DeviceDiscovery {
    let kind: TransportKind = .wireless

    private static let serviceUUID = CBUUID(string: "53430001-5343-4f4e-4e45-435400000001")
    private static let charUUID = CBUUID(string: "53430002-5343-4f4e-4e45-435400000001")

    private let subject = CurrentValueSubject<[Device], Never>([])
    private let bleQueue = DispatchQueue(label: "sc.ble.discovery")
    private var central: CBCentralManager?
    private var wantScan = false
    /// Peripherals we're mid-resolve on, retained so iOS/macOS doesn't drop the connection (by id).
    private var connecting: [UUID: CBPeripheral] = [:]
    /// Resolved devices keyed by the tablet's peerId (`pid`) so re-reads dedupe cleanly.
    private var found: [String: Device] = [:]

    var devices: AnyPublisher<[Device], Never> { subject.eraseToAnyPublisher() }

    func start() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.wantScan = true
            if self.central == nil {
                // Creating the manager triggers the one-time Bluetooth permission prompt.
                self.central = CBCentralManager(delegate: self, queue: self.bleQueue)
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
            self.connecting.values.forEach { self.central?.cancelPeripheralConnection($0) }
            self.connecting.removeAll()
            self.found.removeAll()
            self.subject.send([])
        }
    }

    // MARK: - internals (all on bleQueue)

    private func beginScan() {
        central?.scanForPeripherals(withServices: [BleDiscovery.serviceUUID],
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func publish() { subject.send(Array(found.values).sorted { $0.name < $1.name }) }
}

extension BleDiscovery: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantScan { beginScan() }
        case .unauthorized, .poweredOff, .unsupported, .resetting, .unknown:
            // No access / radio off — wireless still works via mDNS / manual IP. Surface nothing here.
            break
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connecting[peripheral.identifier] == nil else { return }
        connecting[peripheral.identifier] = peripheral   // retain across the async connect
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([BleDiscovery.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connecting[peripheral.identifier] = nil
    }
}

extension BleDiscovery: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == BleDiscovery.serviceUUID }) else {
            central?.cancelPeripheralConnection(peripheral); return
        }
        peripheral.discoverCharacteristics([BleDiscovery.charUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let ch = service.characteristics?.first(where: { $0.uuid == BleDiscovery.charUUID }) else {
            central?.cancelPeripheralConnection(peripheral); return
        }
        peripheral.readValue(for: ch)   // CoreBluetooth does the ATT long-read; full value arrives below
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        defer { central?.cancelPeripheralConnection(peripheral) }   // transient: we have what we need
        guard error == nil, let data = characteristic.value,
              let device = BleDiscovery.device(from: data) else { return }
        found[device.id] = device
        publish()
    }

    /// Parse the bootstrap blob `{n,ip,p,tok,pid}` into a `.wireless` Device dialed via `.tcp(host,port)`.
    private static func device(from data: Data) -> Device? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = obj["ip"] as? String, !ip.isEmpty,
              let port = (obj["p"] as? NSNumber)?.uint16Value, port != 0
        else { return nil }
        let name = (obj["n"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ip
        let pid = (obj["pid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(ip):\(port)"
        let token = (obj["tok"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Device(id: "ble:\(pid)", name: name, transport: .wireless,
                      capabilities: .canReceive, endpoint: .tcp(host: ip, port: port),
                      pairingToken: token)
    }
}
