import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Negotiated video codec. Extensible (AV1 etc. later).
public enum VideoCodec: String {
    case h264
    case hevc
}

/// Hardware video encoder (VideoToolbox) tuned for low latency.
/// Emits an Annex-B elementary stream; on keyframes it prepends the parameter
/// sets (H.264 SPS/PPS, or HEVC VPS/SPS/PPS) so a late/just-synced decoder can
/// initialize. Codec is chosen from the negotiated capabilities.
public final class VideoEncoder {
    private let width: Int32
    private let height: Int32
    private let fps: Int32
    private var bitrate: Int32
    private let codec: VideoCodec
    private let hdr: Bool                 // HEVC Main10 + BT.2020/PQ when true
    private var session: VTCompressionSession?

    /// (annexBData, isKeyframe)
    public var onEncoded: ((Data, Bool) -> Void)?
    public var onError: ((String) -> Void)?

    public init(width: Int, height: Int, fps: Int = 60, bitrate: Int = 50_000_000, codec: VideoCodec = .h264, hdr: Bool = false) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.fps = Int32(fps)
        self.bitrate = Int32(bitrate)
        self.codec = codec
        self.hdr = hdr && codec == .hevc   // HDR only on the HEVC path
    }

    public func start() throws {
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!,
        ]
        var session: VTCompressionSession?
        let codecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: codecType,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw NSError(domain: "superconnect.encoder", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate(\(codec.rawValue)) failed (\(status))"])
        }

        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? (hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
                           : kVTProfileLevel_H264_High_AutoLevel)
        // HDR10: BT.2020 primaries + PQ transfer, signalled in the bitstream VUI so the
        // tablet's decoder/compositor present it as HDR. Metadata SEI is auto-inserted.
        if hdr {
            set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020)
            set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
            set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)
            if #available(macOS 11.0, *) {
                set(kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTHDRMetadataInsertionMode_Auto)
            }
        }
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        // Favor quality over raw speed — the M-series HW encoder keeps up at high
        // fps and screen text wants the fidelity.
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanFalse)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false) {
        guard let session else { return }
        var props: CFDictionary?
        if forceKeyframe { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sb = sampleBuffer else { self.onError?("encode failed (\(status))"); return }
            self.emit(sb)
        }
    }

    public func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    /// Live bitrate change (AverageBitRate is a dynamic property — no session rebuild). MUST be
    /// called on the owning queue (Producer.encodeQueue) that creates `session` and runs encode().
    /// If the session isn't started yet, the stored value is applied in start().
    public func setBitrate(_ bps: Int) {
        bitrate = Int32(bps)
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
    }

    // MARK: - AVCC/HVCC → Annex-B

    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    private func paramSetInfo(_ fmt: CMFormatDescription) -> (count: Int, nalLen: Int32) {
        var count = 0
        var nalLen: Int32 = 4
        if codec == .hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
        }
        return (count, nalLen)
    }

    private func parameterSet(_ fmt: CMFormatDescription, _ index: Int) -> (ptr: UnsafePointer<UInt8>?, size: Int) {
        var ptr: UnsafePointer<UInt8>?
        var size = 0
        if codec == .hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: index,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: index,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        }
        return (ptr, size)
    }

    private func emit(_ sb: CMSampleBuffer) {
        let isKeyframe: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
                  let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool else { return true }
            return !notSync
        }()

        let fmt = CMSampleBufferGetFormatDescription(sb)
        let prefix = fmt.map { Int(paramSetInfo($0).nalLen) } ?? 4
        guard prefix >= 1, prefix <= 4 else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { return }
        let total = CMBlockBufferGetDataLength(blockBuffer)
        guard total > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: total)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: total, destination: raw.baseAddress!)
        }
        guard status == noErr else { return }

        var out = Data()
        if isKeyframe, let fmt { out.append(parameterSetsAnnexB(fmt)) }

        var offset = 0
        while offset + prefix <= total {
            var nalLength = 0
            for i in 0..<prefix { nalLength = (nalLength << 8) | Int(bytes[offset + i]) }
            offset += prefix
            if nalLength <= 0 || offset + nalLength > total { break }
            out.append(contentsOf: VideoEncoder.startCode)
            bytes.withUnsafeBufferPointer { p in out.append(p.baseAddress! + offset, count: nalLength) }
            offset += nalLength
        }
        onEncoded?(out, isKeyframe)
    }

    private func parameterSetsAnnexB(_ fmt: CMFormatDescription) -> Data {
        var out = Data()
        let count = paramSetInfo(fmt).count
        for i in 0..<count {
            let (ptr, size) = parameterSet(fmt, i)
            if let p = ptr {
                out.append(contentsOf: VideoEncoder.startCode)
                out.append(p, count: size)
            }
        }
        return out
    }
}
