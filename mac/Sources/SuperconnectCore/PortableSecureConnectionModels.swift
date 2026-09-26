import Foundation

public enum PortableSecureConnectionError: Error, Equatable {
    case coreUnavailable
    case invalidRecordVersion
    case invalidRecordMaterial
    case malformedEffect
    case malformedSnapshot
    case malformedInbound
    case inboundBatchViolation
    case coreFailure(Int32)
}

public enum PortableSecureConnectionEffect: Equatable {
    case session(PortableSessionEffect)
    case prepareRecordContext(
        generation: PortableSessionGeneration,
        operation: PortableSessionOperationID
    )
    case activateRecords(
        generation: PortableSessionGeneration,
        operation: PortableSessionOperationID
    )
    case disposeRecords(generation: PortableSessionGeneration)
}

public struct PortableSecureConnectionSnapshot: Equatable {
    public let generation: PortableSessionGeneration
    public let sessionPhase: PortableSessionPhase
    public let recordPhase: UInt32
    public let recordsActive: Bool
    public let recordsRequired: Bool
    public let invariantsHold: Bool
    public let pendingEffectCount: UInt32
    public let pendingInboundCount: UInt32
    public let inboundViewOutstanding: Bool
}

public struct PortableSecureInboundFrame: Equatable {
    public let frame: Frame
    public let control: PortableControlEnvelope?
}
