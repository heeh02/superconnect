#pragma once
#include <stddef.h>
#include "superconnect_ffi_types.h"
#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_MEDIA_RECOVERY_WIRE_ANCHOR = 1,
    SC_MEDIA_RECOVERY_WIRE_ACCEPTED = 2,
    SC_MEDIA_RECOVERY_WIRE_OUTPUT = 3,
};

enum {
    SC_VIDEO_CODEC_H264_V1 = 1,
};

enum {
    SC_VIDEO_HDR_OFF_V1 = 1,
};

enum {
    SC_KEYFRAME_REQUEST_REASON_UNSPECIFIED = 0,
    SC_KEYFRAME_REQUEST_REASON_UDP_GAP = 1,
    SC_KEYFRAME_REQUEST_REASON_UDP_REASSEMBLY_OVERFLOW = 2,
    SC_KEYFRAME_REQUEST_REASON_UDP_AUTH = 3,
    SC_KEYFRAME_REQUEST_REASON_DECODER_BACKLOG = 4,
    SC_KEYFRAME_REQUEST_REASON_DECODER_INPUT_FAILURE = 5,
    SC_KEYFRAME_REQUEST_REASON_DECODER_NOT_READY = 6,
    SC_KEYFRAME_REQUEST_REASON_DECODER_ERROR = 7,
    SC_KEYFRAME_REQUEST_REASON_CONFIG_REARM = 8,
};

typedef struct ScMediaRecoveryWireV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t message_type;
    uint32_t reserved;
    uint64_t generation;
    uint64_t recovery_id;
    uint64_t source_frame_id;
    uint64_t reserved_u64[2];
} ScMediaRecoveryWireV1;

typedef struct ScKeyframeRequestWireV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t reason;
    uint32_t reserved;
    uint64_t reserved_u64;
} ScKeyframeRequestWireV1;

typedef struct ScVideoConfigWireV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t codec;
    uint32_t hdr;
    uint32_t width;
    uint32_t height;
    uint32_t refresh_rate;
    uint8_t low_latency;
    uint8_t reserved_u8[3];
    uint64_t reserved_u64[2];
} ScVideoConfigWireV1;

ScStatus sc_media_recovery_wire_encode_v1(
    const ScMediaRecoveryWireV1* value,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

ScStatus sc_media_recovery_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScMediaRecoveryWireV1* output
);

ScStatus sc_keyframe_request_wire_encode_v1(
    const ScKeyframeRequestWireV1* value,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

ScStatus sc_keyframe_request_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScKeyframeRequestWireV1* output
);

ScStatus sc_video_config_wire_encode_v1(
    const ScVideoConfigWireV1* value,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

ScStatus sc_video_config_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScVideoConfigWireV1* output
);

#ifdef __cplusplus
}
#endif
