#pragma once

#include <stddef.h>
#include <stdint.h>

#include "superconnect_ffi_types.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_CAPABILITY_MAX_EFFECTS_V1 = 3,
};

enum {
    SC_CAPABILITY_SIDE_OFFERER = 1,
    SC_CAPABILITY_SIDE_SELECTOR = 2,
};

enum {
    SC_CAPABILITY_ROLE_HOST = 1,
    SC_CAPABILITY_ROLE_RECEIVER = 2,
};

enum {
    SC_CAPABILITY_PROJECTION_EXTEND = 1,
    SC_CAPABILITY_PROJECTION_MIRROR = 2,
    SC_CAPABILITY_PROJECTION_PRIMARY = 3,
};

enum {
    SC_CAPABILITY_TRANSPORT_TCP = 1,
};

enum {
    SC_CAPABILITY_ID_MEDIA_HOST = 0,
    SC_CAPABILITY_ID_MEDIA_RECEIVER = 1,
    SC_CAPABILITY_ID_PROJECTION_EXTEND = 8,
    SC_CAPABILITY_ID_PROJECTION_MIRROR = 9,
    SC_CAPABILITY_ID_PROJECTION_PRIMARY = 10,
    SC_CAPABILITY_ID_TRANSPORT_TCP = 16,
};

#define SC_CAPABILITY_BIT_MEDIA_HOST \
    (UINT64_C(1) << SC_CAPABILITY_ID_MEDIA_HOST)
#define SC_CAPABILITY_BIT_MEDIA_RECEIVER \
    (UINT64_C(1) << SC_CAPABILITY_ID_MEDIA_RECEIVER)
#define SC_CAPABILITY_BIT_PROJECTION_EXTEND \
    (UINT64_C(1) << SC_CAPABILITY_ID_PROJECTION_EXTEND)
#define SC_CAPABILITY_BIT_PROJECTION_MIRROR \
    (UINT64_C(1) << SC_CAPABILITY_ID_PROJECTION_MIRROR)
#define SC_CAPABILITY_BIT_PROJECTION_PRIMARY \
    (UINT64_C(1) << SC_CAPABILITY_ID_PROJECTION_PRIMARY)
#define SC_CAPABILITY_BIT_TRANSPORT_TCP \
    (UINT64_C(1) << SC_CAPABILITY_ID_TRANSPORT_TCP)

enum {
    SC_CAPABILITY_EVENT_PEER_HELLO = 1,
    SC_CAPABILITY_EVENT_OFFER = 2,
    SC_CAPABILITY_EVENT_SELECTION = 3,
    SC_CAPABILITY_EVENT_COMMIT = 4,
};

enum {
    SC_CAPABILITY_EFFECT_SEND_OFFER = 1,
    SC_CAPABILITY_EFFECT_SEND_SELECTION = 2,
    SC_CAPABILITY_EFFECT_SEND_COMMIT = 3,
    SC_CAPABILITY_EFFECT_COMMITTED = 4,
    SC_CAPABILITY_EFFECT_CONNECTED = 5,
    SC_CAPABILITY_EFFECT_REJECTED = 6,
    SC_CAPABILITY_EFFECT_FATAL = 7,
};

enum {
    SC_CAPABILITY_REASON_NONE = 0,
    SC_CAPABILITY_REASON_OUT_OF_ORDER = 1,
    SC_CAPABILITY_REASON_STALE_GENERATION = 2,
    SC_CAPABILITY_REASON_UNSUPPORTED_VERSION = 3,
    SC_CAPABILITY_REASON_UNSUPPORTED_CAPABILITY = 4,
    SC_CAPABILITY_REASON_ROLE_MISMATCH = 5,
    SC_CAPABILITY_REASON_PROJECTION_MISMATCH = 6,
    SC_CAPABILITY_REASON_COMMIT_MISMATCH = 7,
};

/* Stable 40-byte layout on supported 32-bit and 64-bit C ABIs. */
typedef struct ScCapabilityConfigV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t authorized_capabilities;
    uint8_t side;
    uint8_t local_role;
    uint8_t desired_peer_role;
    uint8_t projection;
    uint8_t transport;
    uint8_t reserved0[3];
    uint64_t reserved1;
} ScCapabilityConfigV1;

/*
 * Stable 40-byte event. Fields unused by event_type must be zero. The presence
 * byte is either 0 or 1; all identifiers and enum values are validated before
 * the reducer can advance.
 */
typedef struct ScCapabilityEventV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t capabilities;
    uint16_t negotiation_version;
    uint8_t event_type;
    uint8_t has_negotiation_version;
    uint8_t offerer_role;
    uint8_t selector_role;
    uint8_t projection;
    uint8_t transport;
    uint8_t reserved[8];
} ScCapabilityEventV1;

/*
 * Stable 64-byte copied effect. reason selects which expected/received fields
 * are meaningful. capability is an SC_CAPABILITY_ID_* value. No field borrows
 * memory from the handle.
 */
typedef struct ScCapabilityEffectV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t capabilities;
    uint64_t expected_generation;
    uint64_t received_generation;
    uint16_t negotiation_version;
    uint16_t expected_version;
    uint16_t received_version;
    uint8_t effect_type;
    uint8_t reason;
    uint8_t capability;
    uint8_t offerer_role;
    uint8_t selector_role;
    uint8_t local_role;
    uint8_t peer_role;
    uint8_t expected_role;
    uint8_t received_role;
    uint8_t projection;
    uint8_t expected_projection;
    uint8_t received_projection;
    uint8_t transport;
    uint8_t negotiated;
    uint32_t reserved;
} ScCapabilityEffectV1;

/* Stable 48-byte copied snapshot. */
typedef struct ScCapabilitySnapshotV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t authorized_capabilities;
    uint8_t side;
    uint8_t local_role;
    uint8_t desired_peer_role;
    uint8_t projection;
    uint8_t transport;
    uint8_t has_binding;
    uint8_t binding_local_role;
    uint8_t binding_peer_role;
    uint8_t binding_projection;
    uint8_t binding_transport;
    uint8_t binding_negotiated;
    uint8_t reserved0[5];
    uint64_t reserved1;
} ScCapabilitySnapshotV1;

typedef struct ScCapabilityNegotiationV1 ScCapabilityNegotiationV1;

/* Canonical nested capability JSON. Output is not NUL-terminated. */
ScStatus sc_capability_wire_encode_v1(
    const ScCapabilityEventV1* event,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

/* Caller initializes output.struct_size and output.api_version. */
ScStatus sc_capability_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScCapabilityEventV1* output
);

/*
 * The handle has one owner and is used serially. Core retains no caller pointer,
 * creates no thread, and invokes no callback. The caller owns every structure
 * and owns the handle returned by new until it is passed to free.
 */
ScStatus sc_capability_negotiation_new_v1(
    const ScCapabilityConfigV1* config,
    ScCapabilityNegotiationV1** output
);
ScStatus sc_capability_negotiation_free_v1(ScCapabilityNegotiationV1* handle);

/*
 * output_capacity must not exceed SC_CAPABILITY_MAX_EFFECTS_V1. A smaller
 * capacity returns SC_BUFFER_TOO_SMALL, writes that fixed bound to output_count,
 * and leaves reducer state unchanged. Success writes the actual effect count.
 */
ScStatus sc_capability_negotiation_apply_v1(
    ScCapabilityNegotiationV1* handle,
    const ScCapabilityEventV1* event,
    ScCapabilityEffectV1* output,
    size_t output_capacity,
    size_t* output_count
);

/* Caller initializes snapshot.struct_size and snapshot.api_version. */
ScStatus sc_capability_negotiation_snapshot_v1(
    const ScCapabilityNegotiationV1* handle,
    ScCapabilitySnapshotV1* snapshot
);

#ifdef __cplusplus
}
#endif
