#pragma once

#include <stddef.h>
#include <stdint.h>

#include "superconnect_control_envelope.h"
#include "superconnect_ffi_types.h"
#include "superconnect_session.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_SECURE_CONNECTION_MAX_EFFECTS_V1 = 10,
    SC_SECURE_CONNECTION_MAX_INBOUND_FRAMES_V1 = 1,
    SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1 = 32,
};

enum {
    SC_SECURE_CONNECTION_RECORD_NOT_REQUIRED_V1 = 0,
    SC_SECURE_CONNECTION_RECORD_INACTIVE_V1 = 1,
    SC_SECURE_CONNECTION_RECORD_PREPARING_V1 = 2,
    SC_SECURE_CONNECTION_RECORD_ACTIVATING_V1 = 3,
    SC_SECURE_CONNECTION_RECORD_ACTIVE_V1 = 4,
    SC_SECURE_CONNECTION_RECORD_DISPOSED_V1 = 5,
};

enum {
    SC_SECURE_CONNECTION_EFFECT_SESSION_V1 = 1,
    SC_SECURE_CONNECTION_EFFECT_PREPARE_RECORD_CONTEXT_V1 = 2,
    SC_SECURE_CONNECTION_EFFECT_ACTIVATE_RECORDS_V1 = 3,
    SC_SECURE_CONNECTION_EFFECT_DISPOSE_RECORDS_V1 = 4,
};

enum {
    SC_SECURE_CONNECTION_PROTOCOL_REJECTED = 120,
    SC_SECURE_CONNECTION_NOT_ACTIVE = 121,
    SC_SECURE_CONNECTION_PENDING_OUTPUT = 122,
};

/* max_plaintext_bytes=0 selects the SC-RECORD-v1 hard maximum. */
typedef struct ScSecureConnectionConfigV1 {
    uint32_t struct_size;
    uint32_t api_version;
    ScSessionConfigV1 session;
    uint64_t max_plaintext_bytes;
    uint64_t reserved0;
    uint64_t reserved1;
} ScSecureConnectionConfigV1;

/*
 * success=1 requires three nonzero secret buffers. success=0 requires all
 * secret bytes to be zero. Core overwrites its temporary copy on every path;
 * the caller remains responsible for overwriting the caller-owned record.
 */
typedef struct ScSecureRecordMaterialV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t operation;
    uint8_t success;
    uint8_t reserved0[7];
    uint8_t pair_secret[SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1];
    uint8_t responder_challenge[SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1];
    uint8_t initiator_challenge[SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1];
    uint64_t reserved1;
} ScSecureRecordMaterialV1;

/* A copied effect. session_effect is zero for non-session effect types. */
typedef struct ScSecureConnectionEffectV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t type;
    uint32_t reserved0;
    uint64_t generation;
    uint64_t operation;
    ScSessionEffectV1 session_effect;
    uint64_t reserved1;
    uint64_t reserved2;
} ScSecureConnectionEffectV1;

typedef struct ScSecureConnectionSnapshotV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint32_t session_phase;
    uint32_t record_phase;
    uint32_t records_active;
    uint32_t records_required;
    uint32_t invariants_hold;
    uint32_t pending_effect_count;
    uint32_t pending_inbound_count;
    uint32_t inbound_view_outstanding;
    uint64_t reserved0;
    uint64_t reserved1;
} ScSecureConnectionSnapshotV1;

/*
 * payload borrows handle-owned memory until consume or free. control is
 * canonical and populated only when control_present=1. One push exposes at
 * most one inbound frame. Coalesced bytes remain in the Core decoder until the
 * platform consumes and routes that frame, reports every resulting typed
 * completion, then calls push again with bytes=NULL and length=0. This state
 * barrier prevents later authenticated records from being opened under the
 * preceding handshake state.
 */
typedef struct ScSecureInboundViewV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t channel;
    uint8_t flags;
    uint8_t control_present;
    uint8_t reserved0;
    uint32_t reserved1;
    const uint8_t* payload;
    size_t payload_length;
    uint64_t generation;
    ScControlEnvelopeV1 control;
    uint64_t reserved2;
} ScSecureInboundViewV1;

typedef struct ScSecureConnectionV1 ScSecureConnectionV1;

/*
 * One serial owner. Every state-changing call requires the effect queue to be
 * drained first. Every push requires the inbound queue to be drained first.
 * After routing one inbound, call push(NULL, 0) until next_inbound reports
 * SC_NO_FRAME before accepting more socket bytes. This makes transition and
 * queue bounds part of the ABI rather than an allocation accident.
 */
ScStatus sc_secure_connection_new_v1(
    const ScSecureConnectionConfigV1* config,
    ScSecureConnectionV1** output
);
ScStatus sc_secure_connection_free_v1(ScSecureConnectionV1* connection);
ScStatus sc_secure_connection_observe_record_version_v1(
    ScSecureConnectionV1* connection,
    uint64_t generation,
    uint16_t record_version
);
ScStatus sc_secure_connection_apply_session_v1(
    ScSecureConnectionV1* connection,
    const ScSessionEventV1* event
);
ScStatus sc_secure_connection_record_material_prepared_v1(
    ScSecureConnectionV1* connection,
    const ScSecureRecordMaterialV1* material
);
ScStatus sc_secure_connection_records_activated_v1(
    ScSecureConnectionV1* connection,
    uint64_t generation,
    uint64_t operation,
    uint8_t success
);
ScStatus sc_secure_connection_pop_effect_v1(
    ScSecureConnectionV1* connection,
    ScSecureConnectionEffectV1* output
);
ScStatus sc_secure_connection_snapshot_v1(
    const ScSecureConnectionV1* connection,
    ScSecureConnectionSnapshotV1* output
);

/* A short output buffer never advances a record counter. */
ScStatus sc_secure_connection_seal_frame_v1(
    ScSecureConnectionV1* connection,
    uint8_t channel,
    uint8_t flags,
    const uint8_t* plaintext,
    size_t plaintext_length,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_secure_connection_push_v1(
    ScSecureConnectionV1* connection,
    const uint8_t* bytes,
    size_t length
);
ScStatus sc_secure_connection_next_inbound_v1(
    ScSecureConnectionV1* connection,
    ScSecureInboundViewV1* output
);
ScStatus sc_secure_connection_consume_inbound_v1(
    ScSecureConnectionV1* connection,
    uint64_t generation
);

#ifdef __cplusplus
}
#endif
