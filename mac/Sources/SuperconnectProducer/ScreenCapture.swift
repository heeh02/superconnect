import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

/// Captures a single display (by CGDirectDisplayID) via ScreenCaptureKit and
/// delivers encoder-ready, IOSurface-backed pixel buffers (420f / NV12).
public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let fps: Int
    private let hdr: Bool
    private let outputQueue = DispatchQueue(label: "superconnect.capture.output")
    private var stream: SCStream?

    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    public var onError: ((String) -> Void)?

    public init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int = 60, hdr: Bool = false) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        self.hdr = hdr
    }

    // MARK: - TCC (Screen Recording) permission

    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Diagnostic: which display IDs ScreenCaptureKit currently exposes.
    public static func shareableDisplayIDs() async throws -> [CGDirectDisplayID] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.displays.map { $0.displayID }
    }

    // MARK: - Lifecycle

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            let available = content.displays.map { $0.displayID }
            throw NSError(domain: "superconnect.capture", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "virtual display \(displayID) not found in SCShareableContent.displays (available: \(available))"
            ])
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        if hdr, #available(macOS 15.0, *) {
            // 10-bit HDR capture from the virtual display. PQ is used (not HLG): SCK was
            // verified to silently drop HLG tagging on this path while tagging PQ correctly.
            config.captureDynamicRange = .hdrLocalDisplay
            config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange // 'x420', 10-bit
            config.colorSpaceName = CGColorSpace.itur_2100_PQ
        } else {
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange // '420f', encoder-ready
        }
        config.queueDepth = 5
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Only forward frames with new, complete pixel content.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pixelBuffer, pts)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }
}
