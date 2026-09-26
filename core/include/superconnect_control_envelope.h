#pragma once

#include <stddef.h>

#include "superconnect_control_envelope_types_v1.h"
#include "superconnect_ffi_types.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_CONTROL_ENVELOPE_MAX_BYTES_V1 = 65536,
};

/*
 * Stable 64-byte typed routing event. `generation` and `operation` are populated only when the
 * message schema carries those identities; presence distinguishes an identity whose value is zero.
 * Non-SC_OK results leave the caller-owned output unchanged.
 */
typedef struct ScControlEnvelopeV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t kind;
    uint32_t presence;
    uint64_t generation;
    uint64_t operation;
    uint64_t value0;
    uint64_t value1;
    uint32_t detail;
    uint32_t reserved0;
    uint64_t reserved1;
} ScControlEnvelopeV1;

/* Stable 64-byte `caps_update` projection. Codecs are the session hello codec bitset. */
typedef struct ScControlCapsUpdateV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t presence;
    uint32_t codecs;
    uint32_t values;
    uint32_t screen_width;
    uint32_t screen_height;
    uint32_t refresh_rate;
    uint32_t refresh_rate_max;
    uint32_t reserved0;
    double scale;
    uint64_t reserved1;
    uint64_t reserved2;
} ScControlCapsUpdateV1;

/* SC_UNSUPPORTED_VERSION means a syntactically valid unknown or retired legacy message type. */
ScStatus sc_control_envelope_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScControlEnvelopeV1* output
);
/* Strictly claims one active top-level type before payload validation. This does not make the
 * payload valid; it exists only to route malformed replaceable diagnostics to typed rejection. */
ScStatus sc_control_envelope_claim_kind_v1(
    const uint8_t* input,
    size_t input_length,
    uint32_t* output_kind
);
ScStatus sc_control_caps_update_wire_encode_v1(
    const ScControlCapsUpdateV1* value,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_control_caps_update_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScControlCapsUpdateV1* output
);
ScStatus sc_control_text_wire_encode_v1(
    const uint8_t* text,
    size_t text_length,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_control_text_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_control_error_wire_encode_v1(
    uint32_t reason,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
/* Maps a ScSessionFatalReason to its one canonical peer-visible error. Transport-failed has no
 * encodable peer wire and returns SC_INVALID_ARGUMENT. */
ScStatus sc_control_session_fatal_error_wire_encode_v1(
    uint32_t session_fatal_reason,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_control_udp_aux_wire_encode_v1(
    uint32_t kind,
    uint64_t operation,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_control_aux_anchor_accepted_wire_encode_v1(
    uint64_t generation,
    uint32_t source_frame_id,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_control_video_epoch_wire_encode_v1(
    uint32_t epoch,
    uint32_t first_frame_sequence,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

#ifdef __cplusplus
}
#endif
