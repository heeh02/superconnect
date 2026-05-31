import Combine

/// STUB for the RECEIVER role (this Mac being cast TO by another device). Conforms to
/// `ConnectionEngine` and is selectable via the role factory, so enabling it later needs
/// no coordinator/UI change — just a real implementation here.
///
/// FUTURE: session.onVideo → VideoToolbox decode → AVSampleBufferDisplayLayer in a
/// borderless NSWindow; capture local input → FrameCodec(.input). That belongs in a new
/// `SuperconnectConsumer` library this drives — created only when the receiver is built.
final class ReceiverConnection: ConnectionEngine {
    private let stateSubject = CurrentValueSubject<ConnectionState, Never>(.idle)
    var statePublisher: AnyPublisher<ConnectionState, Never> { stateSubject.eraseToAnyPublisher() }
    var telemetryPublisher: AnyPublisher<SessionTelemetry, Never>? { nil }

    func connect(host: String, port: UInt16) {
        stateSubject.send(.failed(.receiverNotSupported))
    }

    func disconnect() {
        stateSubject.send(.idle)
    }
}
