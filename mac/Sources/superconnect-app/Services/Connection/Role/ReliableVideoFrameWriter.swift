import Foundation
import SuperconnectCore

/// The only reliable VIDEO writer in the FOSS composition. It cannot emit a legacy plaintext
/// FrameCodec payload: Session owns the canonical SC-RECORD seal and returns the complete frame.
final class ReliableVideoFrameWriter {
    private let session: Session

    init(session: Session, transport _: Transport) {
        self.session = session
    }

    @discardableResult
    func sendVideo(_ payload: Data, isKeyframe: Bool) -> Bool {
        guard session.hasAuthenticatedRecords else { return false }
        return session.enqueuePayload(
                channel: .video,
                flags: isKeyframe ? .keyframe : [],
                payload: payload
        )
    }
}
