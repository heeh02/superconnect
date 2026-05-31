import Foundation
import Network

/// State of the underlying byte-stream link.
public enum TransportState: Equatable {
    case setup
    case ready
    case failed(String)
    case cancelled
}

/// L1 — the swap boundary. A Transport is *any* reliable, ordered,
/// bidirectional byte stream. Today the only impl is `TcpTransport`
/// (used for BOTH wired `hdc fport` over USB and future LAN/Wi-Fi).
/// Nothing above this layer knows or cares which physical link is underneath.
public protocol Transport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onStateChange: ((TransportState) -> Void)? { get set }
    func start()
    func send(_ data: Data)
    func stop()
}

/// TCP implementation over Network.framework.
///
/// Wired (Phase 1):   connect to 127.0.0.1:<port>, with `hdc fport tcp:<port> tcp:<port>`
///                    tunnelling that port to the tablet over USB.
/// Wireless (Phase 4): connect to <tablet-ip>:<port> discovered via mDNS.
/// Same class, same code path — only the host changes.
public final class TcpTransport: Transport {
    public var onReceive: ((Data) -> Void)?
    public var onStateChange: ((TransportState) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "superconnect.tcp")

    public init(host: String, port: UInt16) {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        // Low latency: disable Nagle so small input/control frames go out immediately.
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            _ = tcp // placeholder; IP options not needed here
        }
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        connection = NWConnection(host: endpointHost, port: endpointPort, using: params)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStateChange?(.ready)
                self?.receiveLoop()
            case .failed(let error):
                self?.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self?.onStateChange?(.cancelled)
            case .setup, .preparing, .waiting:
                self?.onStateChange?(.setup)
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.onStateChange?(.failed(error.localizedDescription)) }
        })
    }

    public func stop() {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onReceive?(data) }
            if let error {
                self.onStateChange?(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.onStateChange?(.cancelled)
                return
            }
            self.receiveLoop()
        }
    }
}
