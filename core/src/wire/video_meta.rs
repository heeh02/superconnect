pub const VIDEO_META_V1_SIZE: usize = 16;
pub const VIDEO_META_V2_SIZE: usize = 24;
pub const VIDEO_META_MAGIC: [u8; 2] = [0x53, 0x4d];
pub const VIDEO_META_V1: u8 = 1;
pub const VIDEO_META_V2: u8 = 2;
pub const VIDEO_META_SYNTHETIC_FLAG: u8 = 0x01;
pub const VIDEO_META_KEYFRAME_FLAG: u8 = 0x02;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoFrameMeta {
    pub is_synthetic: bool,
    pub is_keyframe: bool,
    pub source_frame_id: u32,
    pub capture_time_ms: u32,
    pub access_unit_seq: u32,
    pub stream_epoch: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VideoMetaDecode<'a> {
    Absent,
    Valid {
        wire_version: u8,
        fields: VideoFrameMeta,
        rest: &'a [u8],
    },
    Malformed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VideoMetaEncodeError {
    BufferTooSmall,
}

pub fn encode_video_meta(
    fields: &VideoFrameMeta,
    wire_version: u8,
    output: &mut [u8],
) -> Result<usize, VideoMetaEncodeError> {
    let use_v2 = wire_version >= VIDEO_META_V2;
    let required = if use_v2 {
        VIDEO_META_V2_SIZE
    } else {
        VIDEO_META_V1_SIZE
    };
    if output.len() < required {
        return Err(VideoMetaEncodeError::BufferTooSmall);
    }

    output[0..2].copy_from_slice(&VIDEO_META_MAGIC);
    output[2] = if use_v2 { VIDEO_META_V2 } else { VIDEO_META_V1 };
    output[3] = (u8::from(fields.is_synthetic) * VIDEO_META_SYNTHETIC_FLAG)
        | (u8::from(fields.is_keyframe) * VIDEO_META_KEYFRAME_FLAG);
    let body_offset = if use_v2 {
        output[4..12].copy_from_slice(&fields.stream_epoch.to_le_bytes());
        12
    } else {
        4
    };
    output[body_offset..body_offset + 4].copy_from_slice(&fields.source_frame_id.to_le_bytes());
    output[body_offset + 4..body_offset + 8].copy_from_slice(&fields.capture_time_ms.to_le_bytes());
    output[body_offset + 8..body_offset + 12]
        .copy_from_slice(&fields.access_unit_seq.to_le_bytes());
    Ok(required)
}

pub fn decode_video_meta(payload: &[u8]) -> VideoMetaDecode<'_> {
    if payload.len() < VIDEO_META_MAGIC.len() || payload[..2] != VIDEO_META_MAGIC {
        return VideoMetaDecode::Absent;
    }

    let Some(&wire_version) = payload.get(2) else {
        return VideoMetaDecode::Malformed;
    };
    let (header_size, body_offset, stream_epoch) = match wire_version {
        VIDEO_META_V1 if payload.len() >= VIDEO_META_V1_SIZE => (VIDEO_META_V1_SIZE, 4, 0),
        VIDEO_META_V2 if payload.len() >= VIDEO_META_V2_SIZE => (
            VIDEO_META_V2_SIZE,
            12,
            u64::from_le_bytes(
                payload[4..12]
                    .try_into()
                    .expect("validated v2 header length"),
            ),
        ),
        _ => return VideoMetaDecode::Malformed,
    };
    let flags = payload[3];
    let read_u32 = |offset: usize| {
        u32::from_le_bytes(
            payload[offset..offset + 4]
                .try_into()
                .expect("validated video metadata body length"),
        )
    };
    VideoMetaDecode::Valid {
        wire_version,
        fields: VideoFrameMeta {
            is_synthetic: flags & VIDEO_META_SYNTHETIC_FLAG != 0,
            is_keyframe: flags & VIDEO_META_KEYFRAME_FLAG != 0,
            source_frame_id: read_u32(body_offset),
            capture_time_ms: read_u32(body_offset + 4),
            access_unit_seq: read_u32(body_offset + 8),
            stream_epoch,
        },
        rest: &payload[header_size..],
    }
}
