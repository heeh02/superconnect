/// Value-only projection from the established Mac casting request into the six portable Session
/// axes. Authorization remains upstream and resolution/negotiation remains in Rust.
public extension CollaborationIntentDraft {
    init(projectionIntent: ProjectionIntent) {
        let role: CollaborationLocalRole = projectionIntent.localRole == .source ? .source : .sink
        let source: CollaborationSourceTopology
        switch projectionIntent.mode {
        case .extend: source = .extend
        case .mirror: source = .mirror
        case .primary: source = .primary
        }
        let input: CollaborationInputPolicy
        switch projectionIntent.inputPolicy {
        case .viewOnly: input = .viewOnly
        case .remoteControl: input = .remoteControl
        case .requestControl: input = .requestControl
        }
        let transport: CollaborationTransportPreference
        switch projectionIntent.transportProfile {
        case .tcp: transport = .reliable
        case .udpV2, .quic: transport = .lowestLatency
        }
        self.init(
            localRole: role,
            sourceTopology: source,
            sinkPresentation: .windowed,
            inputPolicy: input,
            transportPreference: transport,
            topology: .direct
        )
    }
}
