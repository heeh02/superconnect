#pragma once
#include <stddef.h>
#include "superconnect_ffi_types.h"
#ifdef __cplusplus
extern "C" {
#endif

enum { SC_RECEIVER_PROGRESS_TRANSITION_COUNT = 4 };

typedef struct ScReceiverProgressWireV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t session_generation;
    uint32_t awaiting_keyframe;
    uint64_t decoder_generation;
    uint64_t stage_counts[SC_RECEIVER_PROGRESS_TRANSITION_COUNT];
    uint32_t latest_source_frame_ids[SC_RECEIVER_PROGRESS_TRANSITION_COUNT];
} ScReceiverProgressWireV1;

ScStatus sc_receiver_progress_wire_encode_v1(
    const ScReceiverProgressWireV1* value,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

ScStatus sc_receiver_progress_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScReceiverProgressWireV1* output
);

#ifdef __cplusplus
}
#endif
