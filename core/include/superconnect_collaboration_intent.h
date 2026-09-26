#pragma once

#include "superconnect_ffi_types.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_COLLABORATION_INTENT_REJECTED = 110,
};

enum {
    SC_COLLABORATION_INTENT_ROLE_SOURCE = 1,
    SC_COLLABORATION_INTENT_ROLE_SINK = 2,
    SC_COLLABORATION_INTENT_ROLE_RELAY = 3,
};

enum {
    SC_COLLABORATION_INTENT_SOURCE_EXTEND = 1,
    SC_COLLABORATION_INTENT_SOURCE_MIRROR = 2,
    SC_COLLABORATION_INTENT_SOURCE_PRIMARY = 3,
    SC_COLLABORATION_INTENT_SOURCE_APPLICATION = 4,
};

enum {
    SC_COLLABORATION_INTENT_SINK_WINDOWED = 1,
    SC_COLLABORATION_INTENT_SINK_FULLSCREEN = 2,
    SC_COLLABORATION_INTENT_SINK_PICTURE_IN_PICTURE = 3,
};

enum {
    SC_COLLABORATION_INTENT_INPUT_VIEW_ONLY = 1,
    SC_COLLABORATION_INTENT_INPUT_REMOTE_CONTROL = 2,
    SC_COLLABORATION_INTENT_INPUT_REQUEST_CONTROL = 3,
};

enum {
    SC_COLLABORATION_INTENT_TRANSPORT_RELIABLE = 1,
    SC_COLLABORATION_INTENT_TRANSPORT_LOWEST_LATENCY = 2,
    SC_COLLABORATION_INTENT_TRANSPORT_AUTOMATIC = 3,
};

enum {
    SC_COLLABORATION_INTENT_TOPOLOGY_DIRECT = 1,
    SC_COLLABORATION_INTENT_TOPOLOGY_LOCAL_MULTI_PEER = 2,
    SC_COLLABORATION_INTENT_TOPOLOGY_RELAYED = 3,
};

enum {
    SC_COLLABORATION_INTENT_AXIS_LOCAL_ROLE = 1,
    SC_COLLABORATION_INTENT_AXIS_SOURCE_TOPOLOGY = 2,
    SC_COLLABORATION_INTENT_AXIS_SINK_PRESENTATION = 3,
    SC_COLLABORATION_INTENT_AXIS_INPUT_POLICY = 4,
    SC_COLLABORATION_INTENT_AXIS_TRANSPORT_PREFERENCE = 5,
    SC_COLLABORATION_INTENT_AXIS_TOPOLOGY = 6,
};

enum {
    SC_COLLABORATION_INTENT_SIDE_NONE = 0,
    SC_COLLABORATION_INTENT_SIDE_PRODUCT = 1,
    SC_COLLABORATION_INTENT_SIDE_PEER = 2,
};

enum {
    SC_COLLABORATION_INTENT_ERROR_NONE = 0,
    SC_COLLABORATION_INTENT_ERROR_INVALID_COMBINATION = 1,
    SC_COLLABORATION_INTENT_ERROR_MISSING_CAPABILITY = 2,
};

#define SC_COLLABORATION_INTENT_BIT_ROLE_SOURCE (UINT64_C(1) << 0)
#define SC_COLLABORATION_INTENT_BIT_ROLE_SINK (UINT64_C(1) << 1)
#define SC_COLLABORATION_INTENT_BIT_ROLE_RELAY (UINT64_C(1) << 2)
#define SC_COLLABORATION_INTENT_BIT_SOURCE_EXTEND (UINT64_C(1) << 8)
#define SC_COLLABORATION_INTENT_BIT_SOURCE_MIRROR (UINT64_C(1) << 9)
#define SC_COLLABORATION_INTENT_BIT_SOURCE_PRIMARY (UINT64_C(1) << 10)
#define SC_COLLABORATION_INTENT_BIT_SOURCE_APPLICATION (UINT64_C(1) << 11)
#define SC_COLLABORATION_INTENT_BIT_SINK_WINDOWED (UINT64_C(1) << 16)
#define SC_COLLABORATION_INTENT_BIT_SINK_FULLSCREEN (UINT64_C(1) << 17)
#define SC_COLLABORATION_INTENT_BIT_SINK_PICTURE_IN_PICTURE (UINT64_C(1) << 18)
#define SC_COLLABORATION_INTENT_BIT_INPUT_VIEW_ONLY (UINT64_C(1) << 24)
#define SC_COLLABORATION_INTENT_BIT_INPUT_REMOTE_CONTROL (UINT64_C(1) << 25)
#define SC_COLLABORATION_INTENT_BIT_INPUT_REQUEST_CONTROL (UINT64_C(1) << 26)
#define SC_COLLABORATION_INTENT_BIT_TRANSPORT_RELIABLE (UINT64_C(1) << 32)
#define SC_COLLABORATION_INTENT_BIT_TRANSPORT_LOWEST_LATENCY (UINT64_C(1) << 33)
#define SC_COLLABORATION_INTENT_BIT_TRANSPORT_AUTOMATIC (UINT64_C(1) << 34)
#define SC_COLLABORATION_INTENT_BIT_TOPOLOGY_DIRECT (UINT64_C(1) << 40)
#define SC_COLLABORATION_INTENT_BIT_TOPOLOGY_LOCAL_MULTI_PEER (UINT64_C(1) << 41)
#define SC_COLLABORATION_INTENT_BIT_TOPOLOGY_RELAYED (UINT64_C(1) << 42)

/* Stable 24-byte layout on supported 32-bit and 64-bit C ABIs. */
typedef struct ScCollaborationIntentProfileV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t capabilities;
    uint64_t reserved;
} ScCollaborationIntentProfileV1;

/* Numeric values are the SC_COLLABORATION_INTENT_* enums above. */
typedef struct ScCollaborationIntentDraftV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t local_role;
    uint8_t source_topology;
    uint8_t sink_presentation;
    uint8_t input_policy;
    uint8_t transport_preference;
    uint8_t topology;
    uint8_t reserved0[2];
    uint64_t reserved1;
} ScCollaborationIntentDraftV1;

typedef struct ScCollaborationIntentResolvedV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t local_role;
    uint8_t source_topology;
    uint8_t sink_presentation;
    uint8_t input_policy;
    uint8_t transport_preference;
    uint8_t topology;
    uint8_t reserved0[2];
    uint64_t reserved1;
} ScCollaborationIntentResolvedV1;

/* Missing-capability errors always identify side, axis and selected value. */
typedef struct ScCollaborationIntentErrorV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t error_type;
    uint8_t side;
    uint8_t axis;
    uint8_t value;
    uint8_t reserved0[4];
    uint64_t reserved1;
} ScCollaborationIntentErrorV1;

ScStatus sc_collaboration_intent_validate_profile_v1(
    const ScCollaborationIntentProfileV1* profile
);
/* Validates both numeric fields and cross-axis combination rules. */
ScStatus sc_collaboration_intent_validate_draft_v1(
    const ScCollaborationIntentDraftV1* draft
);

/*
 * Every pointer is caller-owned and must refer to a disjoint object. Callers
 * initialize output struct_size/api_version. Once all validation succeeds,
 * resolved and error are both replaced. A domain rejection returns
 * SC_COLLABORATION_INTENT_REJECTED and leaves a zero-valued resolved payload.
 */
ScStatus sc_collaboration_intent_resolve_v1(
    const ScCollaborationIntentProfileV1* product,
    const ScCollaborationIntentProfileV1* peer,
    const ScCollaborationIntentDraftV1* draft,
    ScCollaborationIntentResolvedV1* resolved,
    ScCollaborationIntentErrorV1* error
);

#ifdef __cplusplus
}
#endif
