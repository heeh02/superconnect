#pragma once

#include "superconnect_ffi_types.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_VIDEO_META_V1_SIZE = 16,
    SC_VIDEO_META_V2_SIZE = 24,
};

enum {
    SC_VIDEO_META_ABSENT = 1,
    SC_VIDEO_META_VALID = 2,
    SC_VIDEO_META_MALFORMED = 3,
};

typedef struct ScVideoMetaV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t wire_version;
    uint32_t is_synthetic;
    uint32_t is_keyframe;
    uint32_t source_frame_id;
    uint32_t capture_time_ms;
    uint32_t access_unit_seq;
    uint64_t stream_epoch;
    uint64_t reserved;
} ScVideoMetaV1;

typedef struct ScVideoMetaDecodeV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t result;
    uint32_t wire_version;
    uint32_t is_synthetic;
    uint32_t is_keyframe;
    uint32_t source_frame_id;
    uint32_t capture_time_ms;
    uint32_t access_unit_seq;
    uint32_t payload_offset;
    uint64_t stream_epoch;
    uint64_t reserved;
} ScVideoMetaDecodeV1;

/*
 * Encodes exactly the 16-byte v1 or 24-byte v2 prefix into caller-owned
 * storage. wire_version must be 1 or 2, booleans must be 0 or 1, and reserved
 * must be zero. Query with zero capacity to receive the exact needed size.
 */
ScStatus sc_video_meta_encode_v1(
    const ScVideoMetaV1* input,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

/*
 * Classifies caller-owned bytes without retaining any pointer. ABSENT means
 * the first two bytes are not the SM magic. Once SM is present, every invalid
 * version or truncated header is MALFORMED and must not be treated as media
 * payload. VALID reports the 16/24-byte payload_offset after the prefix.
 */
ScStatus sc_video_meta_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScVideoMetaDecodeV1* output
);

#ifdef __cplusplus
}
#endif
