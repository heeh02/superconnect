import Foundation
import SuperconnectCoreFFI

enum RustWireRuntime {
    static let verifiedABI: Void = {
        precondition(
            sc_mac_rust_wire_active_marker() == UInt32(SC_API_VERSION_V1)
                && sc_mac_rust_auth_active_marker() == UInt32(SC_API_VERSION_V1),
            "Rust core ABI version mismatch"
        )
    }()

    static func encodeFrameHeader(channel: UInt8, flags: UInt8, payloadLength: Int) -> Data {
        _ = verifiedABI
        precondition((0...FrameCodec.maxPayload).contains(payloadLength), "frame payload is too large")
        var output = Data(count: FrameCodec.headerSize)
        var needed = output.count
        let status = output.withUnsafeMutableBytes { bytes in
            sc_frame_encode_header_v1(
                channel,
                flags,
                payloadLength,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &needed
            )
        }
        requireOK(status, operation: "frame header encode")
        precondition(needed == output.count, "Rust frame header length mismatch")
        return output
    }

    static func encodeFrame(channel: UInt8, flags: UInt8, payload: Data) -> Data {
        _ = verifiedABI
        precondition(payload.count <= FrameCodec.maxPayload, "frame payload is too large")
        return payload.withUnsafeBytes { payloadBytes in
            var frame = ScFrameV1()
            frame.struct_size = UInt32(MemoryLayout<ScFrameV1>.size)
            frame.api_version = UInt32(SC_API_VERSION_V1)
            frame.channel = channel
            frame.flags = flags
            frame.reserved = 0
            frame.payload = payloadBytes.bindMemory(to: UInt8.self).baseAddress
            frame.payload_length = payloadBytes.count

            var output = Data(count: FrameCodec.headerSize + payload.count)
            var needed = output.count
            let status = output.withUnsafeMutableBytes { outputBytes in
                sc_frame_encode_v1(
                    &frame,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputBytes.count,
                    &needed
                )
            }
            requireOK(status, operation: "frame encode")
            precondition(needed == output.count, "Rust frame length mismatch")
            return output
        }
    }

    static func makeFrameDecoder() -> OpaquePointer {
        _ = verifiedABI
        var config = ScFrameDecoderConfigV1()
        config.struct_size = UInt32(MemoryLayout<ScFrameDecoderConfigV1>.size)
        config.api_version = UInt32(SC_API_VERSION_V1)
        config.max_buffered_bytes = 0
        var handle: OpaquePointer?
        requireOK(sc_frame_decoder_new_v1(&config, &handle), operation: "frame decoder create")
        guard let handle else { preconditionFailure("Rust frame decoder returned no handle") }
        return handle
    }

    static func freeFrameDecoder(_ handle: OpaquePointer) {
        requireOK(sc_frame_decoder_free_v1(handle), operation: "frame decoder free")
    }

    static func resetFrameDecoder(_ handle: OpaquePointer) {
        requireOK(sc_frame_decoder_reset_v1(handle), operation: "frame decoder reset")
    }

    static func pushFrameBytes(
        _ data: Data,
        offset: Int,
        length: Int,
        into handle: OpaquePointer
    ) throws {
        precondition(offset >= 0 && length >= 0 && offset + length <= data.count)
        let status = data.withUnsafeBytes { bytes in
            let address = length == 0
                ? nil
                : bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset)
            return sc_frame_decoder_push_v1(handle, address, length)
        }
        if status == SC_FRAME_TOO_LARGE || status == SC_DECODER_POISONED {
            throw FrameError.payloadTooLarge(FrameCodec.maxPayload + 1)
        }
        requireOK(status, operation: "frame decoder push")
    }

    static func drainFrames(
        from handle: OpaquePointer,
        declaredOversizeLength: Int? = nil
    ) throws -> [Frame] {
        var frames = [Frame]()
        while true {
            var view = ScFrameViewV1()
            view.struct_size = UInt32(MemoryLayout<ScFrameViewV1>.size)
            view.api_version = UInt32(SC_API_VERSION_V1)
            let status = sc_frame_decoder_next_v1(handle, &view)
            if status == SC_NO_FRAME { return frames }
            if status == SC_FRAME_TOO_LARGE || status == SC_DECODER_POISONED {
                throw FrameError.payloadTooLarge(
                    declaredOversizeLength ?? FrameCodec.maxPayload + 1
                )
            }
            requireOK(status, operation: "frame decoder next")
            let payload: Data
            if view.payload_length == 0 {
                payload = Data()
            } else if let bytes = view.payload {
                payload = Data(bytes: bytes, count: view.payload_length)
            } else {
                preconditionFailure("Rust frame decoder returned a null payload")
            }
            requireOK(
                sc_frame_decoder_consume_v1(handle, view.generation),
                operation: "frame decoder consume"
            )
            frames.append(Frame(channel: view.channel, flags: view.flags, payload: payload))
        }
    }

    static func encodeInput(_ event: InputEvent) -> Data {
        _ = verifiedABI
        var input = inputValue(event)
        var output = Data(count: InputCodec.recordSize)
        var needed = output.count
        let status = output.withUnsafeMutableBytes { bytes in
            sc_input_encode_v1(
                &input,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &needed
            )
        }
        requireOK(status, operation: "input encode")
        precondition(needed == output.count, "Rust input record length mismatch")
        return output
    }

    static func decodeInput(_ data: Data) -> InputEvent? {
        _ = verifiedABI
        guard data.count >= InputCodec.recordSize else { return nil }
        var output = ScInputEventV1()
        output.struct_size = UInt32(MemoryLayout<ScInputEventV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        let status = data.prefix(InputCodec.recordSize).withUnsafeBytes { bytes in
            sc_input_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &output
            )
        }
        guard status == SC_OK else { return nil }
        return InputEvent(
            type: output.type,
            tool: output.tool,
            buttons: output.buttons,
            flags: output.flags,
            timestampMs: output.timestamp_ms,
            x: output.x,
            y: output.y,
            pressure: output.pressure,
            tiltX: output.tilt_x,
            tiltY: output.tilt_y,
            scrollX: output.scroll_x,
            scrollY: output.scroll_y,
            keyCode: output.key_code,
            pointerId: output.pointer_id
        )
    }

    static func encodeVideoMeta(_ fields: VideoFrameMeta.Fields, wireVersion: UInt8) -> Data {
        _ = verifiedABI
        var input = ScVideoMetaV1()
        input.struct_size = UInt32(MemoryLayout<ScVideoMetaV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        input.wire_version = UInt32(wireVersion)
        input.is_synthetic = fields.isSynthetic ? 1 : 0
        input.is_keyframe = fields.isKeyframe ? 1 : 0
        input.source_frame_id = fields.sourceFrameID
        input.capture_time_ms = fields.captureTimeMs
        input.access_unit_seq = fields.accessUnitSeq
        input.stream_epoch = fields.streamEpoch
        input.reserved = 0

        let size = wireVersion == VideoFrameMeta.latestVersion
            ? VideoFrameMeta.v2Size : VideoFrameMeta.size
        var output = Data(count: size)
        var needed = output.count
        let status = output.withUnsafeMutableBytes { bytes in
            sc_video_meta_encode_v1(
                &input,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &needed
            )
        }
        requireOK(status, operation: "video metadata encode")
        precondition(needed == output.count, "Rust video metadata length mismatch")
        return output
    }

    static func decodeVideoMeta(_ data: Data) -> RustVideoMetaDecode {
        _ = verifiedABI
        var output = ScVideoMetaDecodeV1()
        output.struct_size = UInt32(MemoryLayout<ScVideoMetaDecodeV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        let status = data.withUnsafeBytes { bytes in
            sc_video_meta_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &output
            )
        }
        requireOK(status, operation: "video metadata decode")
        switch output.result {
        case UInt32(SC_VIDEO_META_ABSENT):
            return .absent
        case UInt32(SC_VIDEO_META_MALFORMED):
            return .malformed
        case UInt32(SC_VIDEO_META_VALID):
            guard output.payload_offset <= data.count else {
                preconditionFailure("Rust video metadata offset is out of bounds")
            }
            return .valid(
                fields: VideoFrameMeta.Fields(
                    isSynthetic: output.is_synthetic == 1,
                    isKeyframe: output.is_keyframe == 1,
                    sourceFrameID: output.source_frame_id,
                    captureTimeMs: output.capture_time_ms,
                    accessUnitSeq: output.access_unit_seq,
                    streamEpoch: output.stream_epoch
                ),
                payloadOffset: Int(output.payload_offset)
            )
        default:
            preconditionFailure("Rust video metadata returned an unknown result")
        }
    }

    static func decodeReceiverProgress(_ data: Data) -> ReceiverProgress? {
        _ = verifiedABI
        var output = ScReceiverProgressWireV1()
        output.struct_size = UInt32(MemoryLayout<ScReceiverProgressWireV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        let status = data.withUnsafeBytes { bytes in
            sc_receiver_progress_wire_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &output
            )
        }
        guard status == SC_OK else { return nil }
        return ReceiverProgress(
            sessionGeneration: output.session_generation,
            decoderGeneration: output.decoder_generation,
            receiverComplete: output.stage_counts.0,
            decoderSubmitted: output.stage_counts.1,
            decoderOutput: output.stage_counts.2,
            renderCalled: output.stage_counts.3,
            lastReceiverCompleteFrameId: output.latest_source_frame_ids.0,
            lastDecoderSubmittedFrameId: output.latest_source_frame_ids.1,
            lastDecoderOutputFrameId: output.latest_source_frame_ids.2,
            lastRenderCalledFrameId: output.latest_source_frame_ids.3,
            awaitingKeyframe: output.awaiting_keyframe == 1
        )
    }

    static func encodeMediaRecoveryControl(_ control: MediaRecoveryControl) -> Data? {
        _ = verifiedABI
        var value = ScMediaRecoveryWireV1()
        value.struct_size = UInt32(MemoryLayout<ScMediaRecoveryWireV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        switch control.type {
        case .anchor: value.message_type = UInt32(SC_MEDIA_RECOVERY_WIRE_ANCHOR)
        case .accepted: value.message_type = UInt32(SC_MEDIA_RECOVERY_WIRE_ACCEPTED)
        case .output: value.message_type = UInt32(SC_MEDIA_RECOVERY_WIRE_OUTPUT)
        }
        value.generation = control.identity.generation
        value.recovery_id = control.identity.recoveryID
        value.source_frame_id = control.identity.sourceFrameID
        var needed = 0
        guard sc_media_recovery_wire_encode_v1(&value, nil, 0, &needed) == SC_BUFFER_TOO_SMALL,
              needed > 0 else { return nil }
        var output = Data(count: needed)
        let capacity = needed
        let status = output.withUnsafeMutableBytes { bytes in
            sc_media_recovery_wire_encode_v1(
                &value, bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count, &needed)
        }
        guard status == SC_OK, needed == capacity else { return nil }
        return output
    }

    static func decodeMediaRecoveryControl(_ data: Data) -> MediaRecoveryControl? {
        _ = verifiedABI
        var output = ScMediaRecoveryWireV1()
        output.struct_size = UInt32(MemoryLayout<ScMediaRecoveryWireV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        let status = data.withUnsafeBytes { bytes in
            sc_media_recovery_wire_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &output)
        }
        guard status == SC_OK else { return nil }
        let type: MediaRecoveryControlType
        switch output.message_type {
        case UInt32(SC_MEDIA_RECOVERY_WIRE_ANCHOR): type = .anchor
        case UInt32(SC_MEDIA_RECOVERY_WIRE_ACCEPTED): type = .accepted
        case UInt32(SC_MEDIA_RECOVERY_WIRE_OUTPUT): type = .output
        default: return nil
        }
        return MediaRecoveryControl(type: type, identity: PortableRecoveryIdentity(
            generation: output.generation, recoveryID: output.recovery_id,
            sourceFrameID: output.source_frame_id))
    }

    static func encodeKeyframeRequest(_ reason: KeyframeRequestReason) -> Data? {
        _ = verifiedABI
        var value = ScKeyframeRequestWireV1()
        value.struct_size = UInt32(MemoryLayout<ScKeyframeRequestWireV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        switch reason {
        case .unspecified: value.reason = UInt32(SC_KEYFRAME_REQUEST_REASON_UNSPECIFIED)
        case .udpGap: value.reason = UInt32(SC_KEYFRAME_REQUEST_REASON_UDP_GAP)
        case .udpReassemblyOverflow:
            value.reason = UInt32(SC_KEYFRAME_REQUEST_REASON_UDP_REASSEMBLY_OVERFLOW)
        case .udpAuth: value.reason = UInt32(SC_KEYFRAME_REQUEST_REASON_UDP_AUTH)
        case .decoderBacklog: value.reason = UInt32(SC_KEYFRAME_REQUEST_REASON_DECODER_BACKLOG)
        case .decoderInputFailure:
            value.reason = UInt32(SC_KEYFRAME_REQUEST_REASON_DECODER_INPUT_FAILURE)
        case .decoderNotReady:
            value.reason = UInt32(SC_KEYFRAME_REQUEST_REASON_DECODER_NOT_READY)
        case .decoderError: value.reason = UInt32(SC_KEYFRAME_REQUEST_REASON_DECODER_ERROR)
        case .configRearm: value.reason = UInt32(SC_KEYFRAME_REQUEST_REASON_CONFIG_REARM)
        }
        var needed = 0
        guard sc_keyframe_request_wire_encode_v1(&value, nil, 0, &needed) == SC_BUFFER_TOO_SMALL,
              needed > 0 else { return nil }
        var output = Data(count: needed)
        let capacity = needed
        let status = output.withUnsafeMutableBytes { bytes in
            sc_keyframe_request_wire_encode_v1(
                &value, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &needed)
        }
        return status == SC_OK && needed == capacity ? output : nil
    }

    static func decodeKeyframeRequest(_ data: Data) -> KeyframeRequestReason? {
        _ = verifiedABI
        var output = ScKeyframeRequestWireV1()
        output.struct_size = UInt32(MemoryLayout<ScKeyframeRequestWireV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        let status = data.withUnsafeBytes { bytes in
            sc_keyframe_request_wire_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &output)
        }
        guard status == SC_OK else { return nil }
        switch output.reason {
        case UInt32(SC_KEYFRAME_REQUEST_REASON_UNSPECIFIED): return .unspecified
        case UInt32(SC_KEYFRAME_REQUEST_REASON_UDP_GAP): return .udpGap
        case UInt32(SC_KEYFRAME_REQUEST_REASON_UDP_REASSEMBLY_OVERFLOW): return .udpReassemblyOverflow
        case UInt32(SC_KEYFRAME_REQUEST_REASON_UDP_AUTH): return .udpAuth
        case UInt32(SC_KEYFRAME_REQUEST_REASON_DECODER_BACKLOG): return .decoderBacklog
        case UInt32(SC_KEYFRAME_REQUEST_REASON_DECODER_INPUT_FAILURE): return .decoderInputFailure
        case UInt32(SC_KEYFRAME_REQUEST_REASON_DECODER_NOT_READY): return .decoderNotReady
        case UInt32(SC_KEYFRAME_REQUEST_REASON_DECODER_ERROR): return .decoderError
        case UInt32(SC_KEYFRAME_REQUEST_REASON_CONFIG_REARM): return .configRearm
        default: return nil
        }
    }

    static func encodeInputReset(_ reason: String) -> Data? {
        _ = verifiedABI
        let reasonBytes = Data(reason.utf8)
        guard !reasonBytes.isEmpty, reasonBytes.count <= Int(SC_INPUT_RESET_REASON_MAX_BYTES_V1)
        else { return nil }
        var value = ScInputResetWireV1()
        value.struct_size = UInt32(MemoryLayout<ScInputResetWireV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        value.reason_size = UInt32(reasonBytes.count)
        _ = withUnsafeMutableBytes(of: &value.reason) { destination in
            reasonBytes.copyBytes(to: destination.bindMemory(to: UInt8.self))
        }
        var needed = 0
        guard sc_input_reset_wire_encode_v1(&value, nil, 0, &needed) == SC_BUFFER_TOO_SMALL,
              needed > 0 else { return nil }
        var output = Data(count: needed)
        let capacity = needed
        let status = output.withUnsafeMutableBytes { bytes in
            sc_input_reset_wire_encode_v1(
                &value, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &needed)
        }
        return status == SC_OK && needed == capacity ? output : nil
    }

    static func decodeInputReset(_ data: Data) -> String? {
        _ = verifiedABI
        var output = ScInputResetWireV1()
        output.struct_size = UInt32(MemoryLayout<ScInputResetWireV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        let status = data.withUnsafeBytes { bytes in
            sc_input_reset_wire_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &output)
        }
        guard status == SC_OK, output.reason_size <= SC_INPUT_RESET_REASON_MAX_BYTES_V1 else {
            return nil
        }
        return withUnsafeBytes(of: &output.reason) { bytes in
            String(bytes: bytes.prefix(Int(output.reason_size)), encoding: .utf8)
        }
    }

    private static func inputValue(_ event: InputEvent) -> ScInputEventV1 {
        var value = ScInputEventV1()
        value.struct_size = UInt32(MemoryLayout<ScInputEventV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        value.type = event.type
        value.tool = event.tool
        value.buttons = event.buttons
        value.flags = event.flags
        value.reserved = 0
        value.timestamp_ms = event.timestampMs
        value.x = event.x
        value.y = event.y
        value.pressure = event.pressure
        value.tilt_x = event.tiltX
        value.tilt_y = event.tiltY
        value.scroll_x = event.scrollX
        value.scroll_y = event.scrollY
        value.key_code = event.keyCode
        value.pointer_id = event.pointerId
        return value
    }

    private static func requireOK(_ status: ScStatus, operation: StaticString) {
        precondition(status == SC_OK, "Rust \(operation) failed with status \(status)")
    }
}

enum RustVideoMetaDecode {
    case absent
    case valid(fields: VideoFrameMeta.Fields, payloadOffset: Int)
    case malformed
}
