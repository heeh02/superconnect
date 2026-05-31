import Foundation
import CoreMedia
import CoreVideo

/// L4 producer: VirtualDisplay → ScreenCapture → VideoEncoder → Annex-B H.264.
///
/// Robustness behaviors for screen-sharing a mostly-static desktop:
///  • periodic keyframes (~1s) within a short sync window after motion, so a
///    late/just-started decoder can sync and active use recovers from smear;
///  • an idle heartbeat that re-submits the last frame while the screen is static
///    (ScreenCaptureKit delivers nothing when idle). After the sync window these
///    resends are P-frames, not keyframes: the encoder refines the static image to
///    full quality and holds it sharp. Re-sending keyframes — each clamped soft by
///    the low-latency rate controller, with no P-frames to refine it — is what made
///    a long-static screen degrade.
public final class Producer {
    public let virtualDisplay: VirtualDisplay
    private let capture: ScreenCapture
    private var encoder: VideoEncoder?
    private let fps: Int
    private let bitrate: Int
    private let codec: VideoCodec
    private let hdr: Bool

    // All encode submission is serialized here (capture callback + heartbeat).
    private let encodeQueue = DispatchQueue(label: "superconnect.encode")
    private var lastBuffer: CVPixelBuffer?
    private var frameIndex: Int64 = 0
    private var lastEncodeNs: UInt64 = 0
    private var lastKeyframeNs: UInt64 = 0
    private var lastRealFrameNs: UInt64 = 0   // last frame delivered by capture (motion), not a heartbeat resend
    private var heartbeat: DispatchSourceTimer?
    private var stopped = false

    private let keyframeIntervalNs: UInt64 = 1_000_000_000   // force a keyframe at least every 1s (fast smear/late-join recovery)
    private let idleResendNs: UInt64 = 800_000_000           // if idle >0.8s, resend last frame
    private let idleSyncWindowNs: UInt64 = 2_000_000_000     // stop forcing keyframes after 2s static; P-frame resends then refine+hold the image

    public private(set) var encodedResolution: (width: Int, height: Int)?
    public var onEncoded: ((Data, Bool) -> Void)?
    public var onResolution: ((Int, Int) -> Void)?
    public var onError: ((String) -> Void)?

    public init(virtualDisplay: VirtualDisplay, fps: Int = 60, bitrate: Int = 20_000_000, codec: VideoCodec = .h264, hdr: Bool = false) {
        self.virtualDisplay = virtualDisplay
        self.fps = fps
        self.bitrate = bitrate
        self.codec = codec
        self.hdr = hdr
        let backing = virtualDisplay.backingPixelSize()
        self.capture = ScreenCapture(displayID: virtualDisplay.displayID,
                                     width: backing.width, height: backing.height, fps: fps, hdr: hdr)
    }

    public func start() async throws {
        capture.onFrame = { [weak self] pixelBuffer, _ in
            guard let self else { return }
            self.encodeQueue.async { self.submit(pixelBuffer, isRealFrame: true) }
        }
        capture.onError = { [weak self] msg in self?.onError?(msg) }

        // Heartbeat: when the screen is idle, keep the receiver painted/synced.
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, let pb = self.lastBuffer else { return }
            if Self.now() - self.lastEncodeNs >= self.idleResendNs {
                self.submit(pb, isRealFrame: false) // idle resend: P-frame (refines/holds the static image; keyframe only inside the sync window)
            }
        }
        timer.resume()
        heartbeat = timer

        try await capture.start()
    }

    /// Must run on encodeQueue. `isRealFrame` = delivered by capture (motion) vs an idle heartbeat resend.
    private func submit(_ pixelBuffer: CVPixelBuffer, isRealFrame: Bool) {
        if stopped { return }
        if encoder == nil {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let enc = VideoEncoder(width: w, height: h, fps: fps, bitrate: bitrate, codec: codec, hdr: hdr)
            do { try enc.start() } catch {
                onError?("encoder start failed: \(error.localizedDescription)"); return
            }
            enc.onEncoded = { [weak self] data, isKeyframe in self?.onEncoded?(data, isKeyframe) }
            enc.onError = { [weak self] msg in self?.onError?(msg) }
            encoder = enc
            encodedResolution = (w, h)
            onResolution?(w, h)
        }

        let now = Self.now()
        if isRealFrame { lastRealFrameNs = now }
        // Keyframes: the very first frame, plus a ~1s refresh ONLY within a short sync window after
        // the last real frame (covers a decoder that missed the connect keyframe + smear recovery
        // during active use). In deep idle (>idleSyncWindowNs static) we force no keyframes — the
        // heartbeat's P-frame resends let the encoder refine the static image to full quality and
        // hold it sharp, instead of a forced keyframe resetting it to a soft low-latency intra.
        let inSyncWindow = (now - lastRealFrameNs) < idleSyncWindowNs
        let forceKey = lastKeyframeNs == 0 || (inSyncWindow && (now - lastKeyframeNs) >= keyframeIntervalNs)
        lastBuffer = pixelBuffer
        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        frameIndex += 1
        encoder?.encode(pixelBuffer, pts: pts, forceKeyframe: forceKey)
        lastEncodeNs = now
        if forceKey { lastKeyframeNs = now }
    }

    public func stop() async {
        stopped = true
        heartbeat?.cancel()
        heartbeat = nil
        await capture.stop()
        encodeQueue.sync { }      // drain any in-flight submit
        encoder?.stop()
        encoder = nil
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
