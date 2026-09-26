import Foundation

/// Receiver-side media progress reported over the reliable CONTROL channel.
///
/// Counts are scoped to one receiver session/decoder generation. They deliberately name distinct
/// pipeline boundaries: a complete wire frame is not a decoder submission, decoder output is not a
/// render call, and none of these claim that the panel has scanned the frame. This keeps diagnostics
/// from treating sender-side encode FPS as proof that the user can see a picture.
public struct ReceiverProgress: Equatable, Sendable {
    public static let schemaVersion = 1

    public let sessionGeneration: UInt32
    /// Decoder lifecycle generation within the authenticated session. Decoder-stage counters reset
    /// when this changes; receiverComplete remains scoped to sessionGeneration.
    public let decoderGeneration: UInt64
    public let receiverComplete: UInt64
    public let decoderSubmitted: UInt64
    public let decoderOutput: UInt64
    public let renderCalled: UInt64
    public let lastReceiverCompleteFrameId: UInt32
    public let lastDecoderSubmittedFrameId: UInt32
    public let lastDecoderOutputFrameId: UInt32
    public let lastRenderCalledFrameId: UInt32
    public let awaitingKeyframe: Bool

    public init(
        sessionGeneration: UInt32,
        decoderGeneration: UInt64,
        receiverComplete: UInt64,
        decoderSubmitted: UInt64,
        decoderOutput: UInt64,
        renderCalled: UInt64,
        lastReceiverCompleteFrameId: UInt32,
        lastDecoderSubmittedFrameId: UInt32,
        lastDecoderOutputFrameId: UInt32,
        lastRenderCalledFrameId: UInt32,
        awaitingKeyframe: Bool
    ) {
        self.sessionGeneration = sessionGeneration
        self.decoderGeneration = decoderGeneration
        self.receiverComplete = receiverComplete
        self.decoderSubmitted = decoderSubmitted
        self.decoderOutput = decoderOutput
        self.renderCalled = renderCalled
        self.lastReceiverCompleteFrameId = lastReceiverCompleteFrameId
        self.lastDecoderSubmittedFrameId = lastDecoderSubmittedFrameId
        self.lastDecoderOutputFrameId = lastDecoderOutputFrameId
        self.lastRenderCalledFrameId = lastRenderCalledFrameId
        self.awaitingKeyframe = awaitingKeyframe
    }

    init?(wirePayload: Data) {
        guard let value = RustWireRuntime.decodeReceiverProgress(wirePayload) else { return nil }
        self = value
    }
}
