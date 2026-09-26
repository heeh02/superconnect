#pragma once

#include <stddef.h>
#include <stdint.h>

#include "superconnect_ffi_types.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_ADMISSION_EVENT_ACCEPTED = 1,
    SC_ADMISSION_EVENT_PAIRING_PROMPT = 2,
    SC_ADMISSION_EVENT_AUTHENTICATED = 3,
    SC_ADMISSION_EVENT_TIMED_OUT = 4,
    SC_ADMISSION_EVENT_CLOSED = 5,
};

enum {
    SC_ADMISSION_EFFECT_ARM_TIMER = 1,
    SC_ADMISSION_EFFECT_CANCEL_TIMER = 2,
    SC_ADMISSION_EFFECT_CLAIM = 3,
    SC_ADMISSION_EFFECT_REJECT_BUSY = 4,
    SC_ADMISSION_EFFECT_REJECT_CAPACITY = 5,
    SC_ADMISSION_EFFECT_CLOSE = 6,
    SC_ADMISSION_EFFECT_PENDING_RELEASED = 7,
    SC_ADMISSION_EFFECT_ACTIVE_RELEASED = 8,
};

enum {
    SC_ADMISSION_TIMER_NONE = 0,
    SC_ADMISSION_TIMER_AUTHENTICATION = 1,
    SC_ADMISSION_TIMER_PAIRING = 2,
};

/* Stable 16-byte layout on supported 32-bit and 64-bit C ABIs. */
typedef struct ScAdmissionConfigV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t max_pending;
    uint32_t reserved;
} ScAdmissionConfigV1;

/* Stable 32-byte layout on supported 32-bit and 64-bit C ABIs. */
typedef struct ScAdmissionEventV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t kind;
    uint32_t reserved;
    uint64_t owner;
    uint64_t token;
} ScAdmissionEventV1;

/* Stable 40-byte known prefix on supported 32-bit and 64-bit C ABIs. */
typedef struct ScAdmissionEffectV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t kind;
    uint32_t timer_kind;
    uint64_t owner;
    uint64_t token;
    uint64_t timeout_ms;
} ScAdmissionEffectV1;

/* Stable 32-byte layout on supported 32-bit and 64-bit C ABIs. */
typedef struct ScAdmissionSnapshotV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t active_owner;
    uint32_t pending_count;
    uint32_t max_pending;
    uint32_t reserved[2];
} ScAdmissionSnapshotV1;

typedef struct ScAdmissionV1 ScAdmissionV1;

/*
 * The handle has exactly one owner and may only be used serially. Core retains
 * no caller pointer and invokes no callback. All events and effects are copied.
 */
ScStatus sc_admission_new_v1(
    const ScAdmissionConfigV1* config,
    ScAdmissionV1** output
);
ScStatus sc_admission_free_v1(ScAdmissionV1* admission);

/*
 * effect_stride is the byte distance between caller-owned effect slots. It must
 * be at least sizeof(ScAdmissionEffectV1), fit uint32_t, and preserve the type's
 * alignment. Larger slots are accepted; bytes after the known prefix remain
 * untouched. If capacity is short, state is unchanged, written is zero, needed
 * is exact, and SC_BUFFER_TOO_SMALL is returned.
 */
ScStatus sc_admission_apply_v1(
    ScAdmissionV1* admission,
    const ScAdmissionEventV1* event,
    ScAdmissionEffectV1* effects,
    size_t effect_capacity,
    size_t effect_stride,
    size_t* written,
    size_t* needed
);

ScStatus sc_admission_snapshot_v1(
    const ScAdmissionV1* admission,
    ScAdmissionSnapshotV1* output
);

#ifdef __cplusplus
}
#endif
