use std::mem::size_of;
use std::slice;

use crate::wire::video_meta::{
    decode_video_meta, encode_video_meta, VideoFrameMeta, VideoMetaDecode, VideoMetaEncodeError,
    VIDEO_META_V1, VIDEO_META_V1_SIZE, VIDEO_META_V2, VIDEO_META_V2_SIZE,
};

use super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};

pub const SC_VIDEO_META_ABSENT: u32 = 1;
pub const SC_VIDEO_META_VALID: u32 = 2;
pub const SC_VIDEO_META_MALFORMED: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScVideoMetaV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub wire_version: u32,
    pub is_synthetic: u32,
    pub is_keyframe: u32,
    pub source_frame_id: u32,
    pub capture_time_ms: u32,
    pub access_unit_seq: u32,
    pub stream_epoch: u64,
    pub reserved: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScVideoMetaDecodeV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub result: u32,
    pub wire_version: u32,
    pub is_synthetic: u32,
    pub is_keyframe: u32,
    pub source_frame_id: u32,
    pub capture_time_ms: u32,
    pub access_unit_seq: u32,
    pub payload_offset: u32,
    pub stream_epoch: u64,
    pub reserved: u64,
}

fn required_size(wire_version: u32) -> Option<usize> {
    match wire_version {
        value if value == u32::from(VIDEO_META_V1) => Some(VIDEO_META_V1_SIZE),
        value if value == u32::from(VIDEO_META_V2) => Some(VIDEO_META_V2_SIZE),
        _ => None,
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_video_meta_encode_v1(
    input: *const ScVideoMetaV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(input);
        if status != SC_OK {
            return status;
        }
        if needed.is_null() || !pointer_is_aligned(needed) {
            return SC_INVALID_ARGUMENT;
        }
        let Some(input_range) = checked_byte_range(input.cast::<u8>(), size_of::<ScVideoMetaV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast::<u8>(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[input_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }

        let input = input.read();
        let Some(required) = required_size(input.wire_version) else {
            return SC_INVALID_ARGUMENT;
        };
        if input.is_synthetic > 1 || input.is_keyframe > 1 || input.reserved != 0 {
            return SC_INVALID_ARGUMENT;
        }
        needed.write(required);
        if output_capacity < required {
            return SC_BUFFER_TOO_SMALL;
        }
        if output.is_null() {
            return SC_INVALID_ARGUMENT;
        }
        let Some(output_range) = checked_byte_range(output, required) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[input_range, output_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }

        let fields = VideoFrameMeta {
            is_synthetic: input.is_synthetic != 0,
            is_keyframe: input.is_keyframe != 0,
            source_frame_id: input.source_frame_id,
            capture_time_ms: input.capture_time_ms,
            access_unit_seq: input.access_unit_seq,
            stream_epoch: input.stream_epoch,
        };
        let output = slice::from_raw_parts_mut(output, required);
        match encode_video_meta(&fields, input.wire_version as u8, output) {
            Ok(written) if written == required => SC_OK,
            Err(VideoMetaEncodeError::BufferTooSmall) | Ok(_) => SC_INTERNAL_ERROR,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_video_meta_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScVideoMetaDecodeV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(input_range) = checked_byte_range(input, input_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast::<u8>(), size_of::<ScVideoMetaDecodeV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[input_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }

        let struct_size = output.cast::<u32>().read_unaligned();
        let input = if input_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(input, input_length)
        };
        let mut decoded = ScVideoMetaDecodeV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            result: SC_VIDEO_META_ABSENT,
            wire_version: 0,
            is_synthetic: 0,
            is_keyframe: 0,
            source_frame_id: 0,
            capture_time_ms: 0,
            access_unit_seq: 0,
            payload_offset: 0,
            stream_epoch: 0,
            reserved: 0,
        };
        match decode_video_meta(input) {
            VideoMetaDecode::Absent => {}
            VideoMetaDecode::Malformed => decoded.result = SC_VIDEO_META_MALFORMED,
            VideoMetaDecode::Valid {
                wire_version,
                fields,
                rest,
            } => {
                decoded.result = SC_VIDEO_META_VALID;
                decoded.wire_version = u32::from(wire_version);
                decoded.is_synthetic = u32::from(fields.is_synthetic);
                decoded.is_keyframe = u32::from(fields.is_keyframe);
                decoded.source_frame_id = fields.source_frame_id;
                decoded.capture_time_ms = fields.capture_time_ms;
                decoded.access_unit_seq = fields.access_unit_seq;
                decoded.payload_offset = (input.len() - rest.len()) as u32;
                decoded.stream_epoch = fields.stream_epoch;
            }
        }
        output.write(decoded);
        SC_OK
    })
}
