use std::{mem::size_of, ptr, slice};

use crate::media_recovery::{
    decode_keyframe_request_wire_v1, decode_media_recovery_wire_v1, decode_video_config_wire_v1,
    encode_keyframe_request_wire_v1, encode_media_recovery_wire_v1, encode_video_config_wire_v1,
    KeyframeRequestReasonV1, MediaRecoveryWireTypeV1, MediaRecoveryWireV1, VideoCodecV1,
    VideoConfigWireV1, VideoHdrModeV1, KEYFRAME_REQUEST_WIRE_MAX_BYTES_V1,
    MEDIA_RECOVERY_WIRE_MAX_BYTES_V1, VIDEO_CONFIG_WIRE_MAX_BYTES_V1,
};

use super::{
    ScKeyframeRequestWireV1, ScMediaRecoveryWireV1, ScVideoConfigWireV1,
    SC_KEYFRAME_REQUEST_REASON_CONFIG_REARM, SC_KEYFRAME_REQUEST_REASON_DECODER_BACKLOG,
    SC_KEYFRAME_REQUEST_REASON_DECODER_ERROR, SC_KEYFRAME_REQUEST_REASON_DECODER_INPUT_FAILURE,
    SC_KEYFRAME_REQUEST_REASON_DECODER_NOT_READY, SC_KEYFRAME_REQUEST_REASON_UDP_AUTH,
    SC_KEYFRAME_REQUEST_REASON_UDP_GAP, SC_KEYFRAME_REQUEST_REASON_UDP_REASSEMBLY_OVERFLOW,
    SC_KEYFRAME_REQUEST_REASON_UNSPECIFIED, SC_MEDIA_RECOVERY_WIRE_ACCEPTED,
    SC_MEDIA_RECOVERY_WIRE_ANCHOR, SC_MEDIA_RECOVERY_WIRE_OUTPUT, SC_VIDEO_CODEC_H264_V1,
    SC_VIDEO_HDR_OFF_V1,
};
use crate::ffi::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};

fn wire_type_from_ffi(value: u32) -> Option<MediaRecoveryWireTypeV1> {
    match value {
        SC_MEDIA_RECOVERY_WIRE_ANCHOR => Some(MediaRecoveryWireTypeV1::Anchor),
        SC_MEDIA_RECOVERY_WIRE_ACCEPTED => Some(MediaRecoveryWireTypeV1::Accepted),
        SC_MEDIA_RECOVERY_WIRE_OUTPUT => Some(MediaRecoveryWireTypeV1::Output),
        _ => None,
    }
}

fn wire_to_ffi(struct_size: u32, value: MediaRecoveryWireV1) -> ScMediaRecoveryWireV1 {
    ScMediaRecoveryWireV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        message_type: value.message_type as u32,
        reserved: 0,
        generation: value.generation,
        recovery_id: value.recovery_id,
        source_frame_id: value.source_frame_id,
        reserved_u64: [0; 2],
    }
}

fn keyframe_reason_from_ffi(value: u32) -> Option<KeyframeRequestReasonV1> {
    Some(match value {
        SC_KEYFRAME_REQUEST_REASON_UNSPECIFIED => KeyframeRequestReasonV1::Unspecified,
        SC_KEYFRAME_REQUEST_REASON_UDP_GAP => KeyframeRequestReasonV1::UdpGap,
        SC_KEYFRAME_REQUEST_REASON_UDP_REASSEMBLY_OVERFLOW => {
            KeyframeRequestReasonV1::UdpReassemblyOverflow
        }
        SC_KEYFRAME_REQUEST_REASON_UDP_AUTH => KeyframeRequestReasonV1::UdpAuth,
        SC_KEYFRAME_REQUEST_REASON_DECODER_BACKLOG => KeyframeRequestReasonV1::DecoderBacklog,
        SC_KEYFRAME_REQUEST_REASON_DECODER_INPUT_FAILURE => {
            KeyframeRequestReasonV1::DecoderInputFailure
        }
        SC_KEYFRAME_REQUEST_REASON_DECODER_NOT_READY => KeyframeRequestReasonV1::DecoderNotReady,
        SC_KEYFRAME_REQUEST_REASON_DECODER_ERROR => KeyframeRequestReasonV1::DecoderError,
        SC_KEYFRAME_REQUEST_REASON_CONFIG_REARM => KeyframeRequestReasonV1::ConfigRearm,
        _ => return None,
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_keyframe_request_wire_encode_v1(
    value: *const ScKeyframeRequestWireV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(value);
        if status != SC_OK {
            return status;
        }
        if needed.is_null()
            || !pointer_is_aligned(needed)
            || (output.is_null() && output_capacity != 0)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(value_range) =
            checked_byte_range(value.cast(), size_of::<ScKeyframeRequestWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let value = value.read();
        let Some(reason) = keyframe_reason_from_ffi(value.reason) else {
            return SC_INVALID_ARGUMENT;
        };
        if value.reserved != 0 || value.reserved_u64 != 0 {
            return SC_INVALID_ARGUMENT;
        }
        let Ok(encoded) = encode_keyframe_request_wire_v1(reason) else {
            return SC_INVALID_ARGUMENT;
        };
        let bytes = encoded.as_bytes();
        let Some(output_range) = checked_byte_range(output, output_capacity.min(bytes.len()))
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[value_range, output_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        needed.write(bytes.len());
        if output_capacity < bytes.len() {
            return SC_BUFFER_TOO_SMALL;
        }
        ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_keyframe_request_wire_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScKeyframeRequestWireV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > KEYFRAME_REQUEST_WIRE_MAX_BYTES_V1 {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(input_range) = checked_byte_range(input, input_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScKeyframeRequestWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[input_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let bytes = if input_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(input, input_length)
        };
        let Ok(reason) = decode_keyframe_request_wire_v1(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(ScKeyframeRequestWireV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            reason: reason as u32,
            reserved: 0,
            reserved_u64: 0,
        });
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_media_recovery_wire_encode_v1(
    value: *const ScMediaRecoveryWireV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(value);
        if status != SC_OK {
            return status;
        }
        if needed.is_null()
            || !pointer_is_aligned(needed)
            || (output.is_null() && output_capacity != 0)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(value_range) =
            checked_byte_range(value.cast(), size_of::<ScMediaRecoveryWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let value = value.read();
        let Some(message_type) = wire_type_from_ffi(value.message_type) else {
            return SC_INVALID_ARGUMENT;
        };
        if value.reserved != 0 || value.reserved_u64 != [0; 2] {
            return SC_INVALID_ARGUMENT;
        }
        let Some(encoded) = encode_media_recovery_wire_v1(MediaRecoveryWireV1 {
            message_type,
            generation: value.generation,
            recovery_id: value.recovery_id,
            source_frame_id: value.source_frame_id,
        })
        .ok() else {
            return SC_INVALID_ARGUMENT;
        };
        let bytes = encoded.as_bytes();
        let Some(output_range) = checked_byte_range(output, output_capacity.min(bytes.len()))
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[value_range, output_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        needed.write(bytes.len());
        if output_capacity < bytes.len() {
            return SC_BUFFER_TOO_SMALL;
        }
        ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_media_recovery_wire_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScMediaRecoveryWireV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > MEDIA_RECOVERY_WIRE_MAX_BYTES_V1 {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(input_range) = checked_byte_range(input, input_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScMediaRecoveryWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[input_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let bytes = if input_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(input, input_length)
        };
        let Ok(value) = decode_media_recovery_wire_v1(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(wire_to_ffi(struct_size, value));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_video_config_wire_encode_v1(
    value: *const ScVideoConfigWireV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(value);
        if status != SC_OK {
            return status;
        }
        if needed.is_null()
            || !pointer_is_aligned(needed)
            || (output.is_null() && output_capacity != 0)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(value_range) = checked_byte_range(value.cast(), size_of::<ScVideoConfigWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let value = value.read();
        if value.codec != SC_VIDEO_CODEC_H264_V1
            || value.hdr != SC_VIDEO_HDR_OFF_V1
            || value.low_latency > 1
            || value.reserved_u8 != [0; 3]
            || value.reserved_u64 != [0; 2]
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(encoded) = encode_video_config_wire_v1(VideoConfigWireV1 {
            codec: VideoCodecV1::H264,
            width: value.width,
            height: value.height,
            hdr: VideoHdrModeV1::Off,
            low_latency: value.low_latency != 0,
            refresh_rate: value.refresh_rate,
        })
        .ok() else {
            return SC_INVALID_ARGUMENT;
        };
        let bytes = encoded.as_bytes();
        let Some(output_range) = checked_byte_range(output, output_capacity.min(bytes.len()))
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[value_range, output_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        needed.write(bytes.len());
        if output_capacity < bytes.len() {
            return SC_BUFFER_TOO_SMALL;
        }
        ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_video_config_wire_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScVideoConfigWireV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > VIDEO_CONFIG_WIRE_MAX_BYTES_V1 {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(input_range) = checked_byte_range(input, input_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScVideoConfigWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[input_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let bytes = if input_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(input, input_length)
        };
        let Ok(value) = decode_video_config_wire_v1(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(ScVideoConfigWireV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            codec: value.codec as u32,
            hdr: value.hdr as u32,
            width: value.width,
            height: value.height,
            refresh_rate: value.refresh_rate,
            low_latency: u8::from(value.low_latency),
            reserved_u8: [0; 3],
            reserved_u64: [0; 2],
        });
        SC_OK
    })
}
