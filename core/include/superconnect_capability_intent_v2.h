#pragma once

#include <stddef.h>
#include <stdint.h>

#include "superconnect_collaboration_intent.h"
#include "superconnect_ffi_types.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_CAPABILITY_INTENT_API_VERSION_V2 = 2,
    SC_CAPABILITY_INTENT_MAX_EFFECTS_V2 = 3,
};

enum {
    SC_CAPABILITY_INTENT_SIDE_OFFERER = 1,
    SC_CAPABILITY_INTENT_SIDE_SELECTOR = 2,
};

enum {
    SC_CAPABILITY_INTENT_EVENT_PEER_HELLO = 1,
    SC_CAPABILITY_INTENT_EVENT_OFFER = 2,
    SC_CAPABILITY_INTENT_EVENT_SELECTION = 3,
    SC_CAPABILITY_INTENT_EVENT_COMMIT = 4,
};

enum {
    SC_CAPABILITY_INTENT_EFFECT_SEND_OFFER = 1,
    SC_CAPABILITY_INTENT_EFFECT_SEND_SELECTION = 2,
    SC_CAPABILITY_INTENT_EFFECT_SEND_COMMIT = 3,
    SC_CAPABILITY_INTENT_EFFECT_COMMITTED = 4,
    SC_CAPABILITY_INTENT_EFFECT_CONNECTED = 5,
    SC_CAPABILITY_INTENT_EFFECT_REJECTED = 6,
    SC_CAPABILITY_INTENT_EFFECT_FATAL = 7,
};

enum {
    SC_CAPABILITY_INTENT_REASON_NONE = 0,
    SC_CAPABILITY_INTENT_REASON_OUT_OF_ORDER = 1,
    SC_CAPABILITY_INTENT_REASON_STALE_GENERATION = 2,
    SC_CAPABILITY_INTENT_REASON_UNSUPPORTED_VERSION = 3,
    SC_CAPABILITY_INTENT_REASON_ROLE_MISMATCH = 4,
    SC_CAPABILITY_INTENT_REASON_PROJECTION_MISMATCH = 5,
    SC_CAPABILITY_INTENT_REASON_TRANSPORT_MISMATCH = 6,
    SC_CAPABILITY_INTENT_REASON_INTENT_MISMATCH = 7,
    SC_CAPABILITY_INTENT_REASON_COMMIT_MISMATCH = 8,
    SC_CAPABILITY_INTENT_REASON_LEGACY_INTENT_MISMATCH = 9,
};

/* Product/peer capability bits use SC_COLLABORATION_INTENT_BIT_* values. */
typedef struct ScCapabilityIntentConfigV2 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t product_capabilities;
    uint64_t peer_capabilities;
    uint8_t side;
    uint8_t desired_peer_role;
    uint8_t local_role;
    uint8_t source_topology;
    uint8_t sink_presentation;
    uint8_t input_policy;
    uint8_t transport_preference;
    uint8_t topology;
    uint64_t reserved;
} ScCapabilityIntentConfigV2;

/* Unused fields for event_type must be zero. */
typedef struct ScCapabilityIntentEventV2 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint16_t negotiation_version;
    uint8_t event_type;
    uint8_t has_negotiation_version;
    uint8_t offerer_role;
    uint8_t selector_role;
    uint8_t projection;
    uint8_t transport;
    uint8_t local_role;
    uint8_t source_topology;
    uint8_t sink_presentation;
    uint8_t input_policy;
    uint8_t transport_preference;
    uint8_t topology;
    uint8_t reserved0[2];
    uint64_t reserved1;
} ScCapabilityIntentEventV2;

/* Capability bits use SC_COLLABORATION_INTENT_BIT_* values; reserved must be zero. */
typedef struct ScCapabilityIntentProfileV2 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t capabilities;
    uint8_t sender_role;
    uint8_t reserved[7];
} ScCapabilityIntentProfileV2;

typedef struct ScCapabilityIntentEffectV2 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t expected_generation;
    uint64_t received_generation;
    uint16_t negotiation_version;
    uint16_t expected_version;
    uint16_t received_version;
    uint8_t effect_type;
    uint8_t reason;
    uint8_t offerer_role;
    uint8_t selector_role;
    uint8_t local_role;
    uint8_t peer_role;
    uint8_t projection;
    uint8_t transport;
    uint8_t negotiated;
    uint8_t reserved0;
    uint8_t resolved_local_role;
    uint8_t resolved_source_topology;
    uint8_t resolved_sink_presentation;
    uint8_t resolved_input_policy;
    uint8_t resolved_transport_preference;
    uint8_t resolved_topology;
    uint8_t expected_role;
    uint8_t received_role;
    uint8_t expected_projection;
    uint8_t received_projection;
    uint8_t expected_transport;
    uint8_t received_transport;
    uint32_t reserved1;
    uint64_t reserved2;
} ScCapabilityIntentEffectV2;

typedef struct ScCapabilityIntentSnapshotV2 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t product_capabilities;
    uint64_t peer_capabilities;
    uint8_t side;
    uint8_t desired_peer_role;
    uint8_t has_binding;
    uint8_t binding_negotiated;
    uint8_t resolved_local_role;
    uint8_t resolved_source_topology;
    uint8_t resolved_sink_presentation;
    uint8_t resolved_input_policy;
    uint8_t resolved_transport_preference;
    uint8_t resolved_topology;
    uint8_t binding_local_role;
    uint8_t binding_source_topology;
    uint8_t binding_sink_presentation;
    uint8_t binding_input_policy;
    uint8_t binding_transport_preference;
    uint8_t binding_topology;
    uint8_t binding_peer_role;
    uint8_t reserved0[7];
    uint64_t reserved1;
} ScCapabilityIntentSnapshotV2;

typedef struct ScCapabilityIntentNegotiationV2 ScCapabilityIntentNegotiationV2;

/*
 * Canonical JSON wire codecs. Encoded output is not NUL-terminated and needed
 * reports its exact byte length. A short buffer returns SC_BUFFER_TOO_SMALL,
 * writes only needed and leaves output unchanged. PeerHello is not a wire
 * message and is rejected by sc_capability_intent_wire_encode_v2.
 */
ScStatus sc_capability_intent_wire_encode_v2(
    const ScCapabilityIntentEventV2* event,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

/* Caller initializes output.struct_size and output.api_version. */
ScStatus sc_capability_intent_wire_decode_v2(
    const uint8_t* input,
    size_t input_length,
    ScCapabilityIntentEventV2* output
);

ScStatus sc_capability_intent_profile_wire_encode_v2(
    const ScCapabilityIntentProfileV2* profile,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

/* Caller initializes output.struct_size and output.api_version. */
ScStatus sc_capability_intent_profile_wire_decode_v2(
    const uint8_t* input,
    size_t input_length,
    ScCapabilityIntentProfileV2* output
);

/*
 * The opaque handle has one serial owner. Core retains no caller pointer,
 * creates no thread and invokes no callback.
 */
ScStatus sc_capability_intent_negotiation_new_v2(
    const ScCapabilityIntentConfigV2* config,
    ScCapabilityIntentNegotiationV2** output
);
ScStatus sc_capability_intent_negotiation_free_v2(
    ScCapabilityIntentNegotiationV2* handle
);

/*
 * Effects are copied into caller-owned storage. output_capacity must not
 * exceed SC_CAPABILITY_INTENT_MAX_EFFECTS_V2. A smaller capacity returns
 * SC_BUFFER_TOO_SMALL, reports that fixed bound and does not advance state.
 */
ScStatus sc_capability_intent_negotiation_apply_v2(
    ScCapabilityIntentNegotiationV2* handle,
    const ScCapabilityIntentEventV2* event,
    ScCapabilityIntentEffectV2* output,
    size_t output_capacity,
    size_t* output_count
);

/* Caller initializes snapshot.struct_size and snapshot.api_version. */
ScStatus sc_capability_intent_negotiation_snapshot_v2(
    const ScCapabilityIntentNegotiationV2* handle,
    ScCapabilityIntentSnapshotV2* snapshot
);

#ifdef __cplusplus
}
#endif
