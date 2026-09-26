pub mod frame;
pub mod input;
pub mod video_meta;

pub use frame::{
    encode_frame, encode_frame_header, FrameDecoder, FrameError, FrameMeta,
    DEFAULT_MAX_BUFFERED_BYTES, FRAME_HEADER_SIZE, MAX_FRAME_PAYLOAD,
};
pub use input::{
    input_decode, input_encode, input_is_replaceable, input_sequenced_decode,
    input_sequenced_encode, ScInputEvent, INPUT_RECORD_SIZE, INPUT_SEQUENCED_RECORD_SIZE,
};
pub use video_meta::{
    decode_video_meta, encode_video_meta, VideoFrameMeta, VideoMetaDecode, VideoMetaEncodeError,
    VIDEO_META_KEYFRAME_FLAG, VIDEO_META_MAGIC, VIDEO_META_SYNTHETIC_FLAG, VIDEO_META_V1,
    VIDEO_META_V1_SIZE, VIDEO_META_V2, VIDEO_META_V2_SIZE,
};
