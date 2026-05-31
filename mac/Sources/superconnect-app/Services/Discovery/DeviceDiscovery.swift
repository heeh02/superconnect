import Combine

/// The discovery seam — finds peers reachable over ONE transport kind. Distinct from the
/// byte-pipe `Transport` in SuperconnectCore. Long-lived; republishes the full current
/// set whenever it changes. `DeviceStore` merges several of these.
protocol DeviceDiscovery: AnyObject {
    var kind: TransportKind { get }
    var devices: AnyPublisher<[Device], Never> { get }
    func start()
    func stop()
}
