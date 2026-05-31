import Combine

/// STUB for WIRELESS (LAN / Wi-Fi) discovery. Conforms and is injectable today but emits
/// nothing. Enabling wireless = implement this one file (NWBrowser for a Bonjour service
/// like `_superconnect._tcp`) and uncomment its line in `AppEnvironment`. Nothing else
/// changes — the badge UI already renders the `.wireless` case.
final class WirelessDiscovery: DeviceDiscovery {
    let kind: TransportKind = .wireless
    var devices: AnyPublisher<[Device], Never> { Just([]).eraseToAnyPublisher() }
    func start() { /* TODO: NWBrowser(for: .bonjour(type: "_superconnect._tcp", domain: nil)) */ }
    func stop() {}
}
