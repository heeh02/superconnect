#pragma once

#include <stddef.h>
#include <stdint.h>

#include "superconnect_ffi_types.h"
#include "superconnect_core_abi_identity_v1.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    /* Shipping FFI archives currently support 64-bit targets only. */
    SC_CORE_RELEASE_POINTER_BITS = 64,
    /* Fixed wire sizes; these are not sizeof(ScInputEventV1). */
    SC_INPUT_RECORD_V1_SIZE = 44,
    SC_INPUT_SEQUENCED_RECORD_V1_SIZE = 52,
};

/*
 * SC_CORE_CANONICAL_ABI_ID_V1 is generated from the complete target-qualified
 * public ABI manifest. It selects the full identity by default. Consumers of
 * a minimal archive must define SC_CORE_ABI_VARIANT_MINIMAL before including
 * this header. Unsupported 32-bit syntax-only targets expose no identity.
 */

typedef struct ScFrameDecoderConfigV1 {
    uint32_t struct_size;
    uint32_t api_version;
    /* 0 selects 16 MiB + 6 bytes; nonzero values may only lower that hard bound. */
    size_t max_buffered_bytes;
} ScFrameDecoderConfigV1;

typedef struct ScFrameV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t channel;
    uint8_t flags;
    uint16_t reserved;
    const uint8_t* payload;
    size_t payload_length;
} ScFrameV1;

typedef struct ScFrameViewV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t channel;
    uint8_t flags;
    uint16_t reserved;
    const uint8_t* payload;
    size_t payload_length;
    uint64_t generation;
} ScFrameViewV1;

/* Stable 56-byte layout on supported 32-bit and 64-bit C ABIs. */
typedef struct ScInputEventV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t type;
    uint8_t tool;
    uint8_t buttons;
    uint8_t flags;
    uint32_t reserved;
    uint64_t timestamp_ms;
    float x;
    float y;
    float pressure;
    float tilt_x;
    float tilt_y;
    float scroll_x;
    float scroll_y;
    uint16_t key_code;
    uint16_t pointer_id;
} ScInputEventV1;

typedef struct ScFrameDecoder ScFrameDecoder;
typedef ScFrameDecoder ScFrameDecoderV1;

uint32_t sc_core_abi_version_v1(void);
uint64_t sc_core_abi_identity_v1(void);

ScStatus sc_frame_encode_header_v1(
    uint8_t channel,
    uint8_t flags,
    size_t payload_length,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

ScStatus sc_frame_encode_v1(
    const ScFrameV1* frame,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

/*
 * A decoder handle has exactly one owner and may only be used serially.
 * Core creates no thread and stores no platform pointer. A returned view borrows
 * decoder memory until consume, reset, or a poisoning error invalidates it; do
 * not push while a view is outstanding. Oversize declarations and hard buffer
 * limit errors poison the handle until explicit reset.
 * These pull functions never call host code while decoder memory is borrowed.
 */
ScStatus sc_frame_decoder_new_v1(
    const ScFrameDecoderConfigV1* config,
    ScFrameDecoderV1** output
);
ScStatus sc_frame_decoder_free_v1(ScFrameDecoderV1* decoder);
ScStatus sc_frame_decoder_reset_v1(ScFrameDecoderV1* decoder);
ScStatus sc_frame_decoder_push_v1(
    ScFrameDecoderV1* decoder,
    const uint8_t* bytes,
    size_t length
);
ScStatus sc_frame_decoder_next_v1(
    ScFrameDecoderV1* decoder,
    ScFrameViewV1* output
);
ScStatus sc_frame_decoder_consume_v1(
    ScFrameDecoderV1* decoder,
    uint64_t generation
);

ScStatus sc_input_encode_v1(
    const ScInputEventV1* event,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_input_decode_v1(
    const uint8_t* bytes,
    size_t length,
    ScInputEventV1* output
);
/*
 * A fail-closed scheduling hint. On SC_OK, replaceable is exactly 1 for a
 * button-free touchMove or hover event and 0 for every other valid event.
 * Every non-SC_OK result leaves replaceable unchanged.
 */
ScStatus sc_input_is_replaceable_v1(
    const ScInputEventV1* event,
    uint8_t* replaceable
);

/*
 * Negotiated sequenced-input v1 has an exact 52-byte wire record: the
 * canonical 44-byte input record followed by a nonzero little-endian u64.
 * These explicit symbols replace the conflicting A-line use of
 * sc_input_encode_v1/sc_input_decode_v1 without changing canonical v1.
 */
ScStatus sc_input_sequenced_encode_v1(
    const ScInputEventV1* event,
    uint64_t sequence,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_input_sequenced_decode_v1(
    const uint8_t* bytes,
    size_t length,
    ScInputEventV1* output,
    uint64_t* sequence
);

#ifdef __cplusplus
}
#endif

#include "superconnect_admission.h"
#include "superconnect_auth_v1.h"
#include "superconnect_capability.h"
#include "superconnect_capability_intent_v2.h"
#include "superconnect_collaboration_intent.h"
#include "superconnect_control_envelope.h"
#include "superconnect_input_ownership.h"
#include "superconnect_media_recovery.h"
#include "superconnect_receiver_progress.h"
#include "superconnect_record_v1.h"
#include "superconnect_secure_connection.h"
#include "superconnect_session.h"
#include "superconnect_video_meta.h"
