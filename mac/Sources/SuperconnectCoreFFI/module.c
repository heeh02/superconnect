#include "SuperconnectCoreFFI.h"
#include <string.h>

uint32_t sc_mac_rust_wire_active_marker(void) {
    return sc_core_abi_version_v1();
}

uint32_t sc_mac_rust_auth_active_marker(void) {
    const ScStatus expected = SC_INVALID_ARGUMENT;
    if (sc_auth_peer_id_validate_v1(NULL) != expected ||
        sc_auth_proof_create_v1(NULL, NULL) != expected ||
        sc_auth_proof_verify_v1(NULL) != expected ||
        sc_auth_p256_public_from_private_v1(NULL, NULL) != expected ||
        sc_auth_pair_key_derive_v1(NULL, NULL) != expected ||
        sc_auth_pair_secret_seal_v1(NULL, NULL) != expected ||
        sc_auth_pair_secret_open_v1(NULL, NULL) != expected) {
        return 0;
    }
    return sc_core_abi_version_v1();
}



uint32_t sc_mac_rust_session_active_marker(void) {
    ScSessionConfigV1 config = {
        .struct_size = sizeof(ScSessionConfigV1),
        .api_version = SC_API_VERSION_V1,
        .generation = 1,
        .first_operation_id = 1,
        .local_enrollment_key = 1,
        .side = SC_SESSION_SIDE_INITIATOR,
        .media_role = SC_SESSION_MEDIA_ROLE_HOST,
        .origin = SC_SESSION_ORIGIN_TRUSTED_LOCAL,
        .local_identity = {.length = 1, .bytes = {'m'}},
    };
    ScSessionV1* session = NULL;
    if (sc_session_new_v1(&config, &session) != SC_OK || session == NULL) {
        return 0;
    }
    ScSessionEventV1 event = {
        .struct_size = sizeof(ScSessionEventV1),
        .api_version = SC_API_VERSION_V1,
        .type = SC_SESSION_EVENT_START,
        .presence = SC_SESSION_FIELD_GENERATION,
        .generation = config.generation,
    };
    ScSessionEffectV1 effects[SC_SESSION_MAX_EFFECTS_V1] = {0};
    uint32_t written = 0;
    uint32_t needed = 0;
    ScSessionSnapshotV1 snapshot = {
        .struct_size = sizeof(ScSessionSnapshotV1),
        .api_version = SC_API_VERSION_V1,
    };
    if (sc_session_apply_v1(session, &event, effects, SC_SESSION_MAX_EFFECTS_V1,
                            &written, &needed) != SC_OK ||
        written == 0 || needed != SC_SESSION_MAX_EFFECTS_V1 ||
        sc_session_snapshot_v1(session, &snapshot) != SC_OK ||
        snapshot.phase != SC_SESSION_PHASE_TRANSPORT) {
        (void)sc_session_free_v1(session);
        return 0;
    }
    if (sc_session_free_v1(session) != SC_OK) {
        return 0;
    }
    return sc_core_abi_version_v1();
}

uint32_t sc_mac_rust_secure_connection_active_marker(void) {
    ScSecureConnectionConfigV1 config = {
        .struct_size = sizeof(ScSecureConnectionConfigV1),
        .api_version = SC_API_VERSION_V1,
        .session = {
            .struct_size = sizeof(ScSessionConfigV1),
            .api_version = SC_API_VERSION_V1,
            .generation = 1,
            .first_operation_id = 1,
            .local_enrollment_key = 1,
            .side = SC_SESSION_SIDE_INITIATOR,
            .media_role = SC_SESSION_MEDIA_ROLE_HOST,
            .origin = SC_SESSION_ORIGIN_TRUSTED_LOCAL,
            .local_identity = {.length = 1, .bytes = {'m'}},
        },
    };
    ScSecureConnectionV1* connection = NULL;
    if (sc_secure_connection_new_v1(&config, &connection) != SC_OK || connection == NULL) {
        return 0;
    }
    ScSessionEventV1 event = {
        .struct_size = sizeof(ScSessionEventV1),
        .api_version = SC_API_VERSION_V1,
        .type = SC_SESSION_EVENT_START,
        .presence = SC_SESSION_FIELD_GENERATION,
        .generation = config.session.generation,
    };
    ScSecureConnectionEffectV1 effect = {
        .struct_size = sizeof(ScSecureConnectionEffectV1),
        .api_version = SC_API_VERSION_V1,
    };
    ScSecureConnectionSnapshotV1 snapshot = {
        .struct_size = sizeof(ScSecureConnectionSnapshotV1),
        .api_version = SC_API_VERSION_V1,
    };
    if (sc_secure_connection_apply_session_v1(connection, &event) != SC_OK ||
        sc_secure_connection_pop_effect_v1(connection, &effect) != SC_OK ||
        effect.type != SC_SECURE_CONNECTION_EFFECT_SESSION_V1 ||
        sc_secure_connection_snapshot_v1(connection, &snapshot) != SC_OK ||
        snapshot.session_phase != SC_SESSION_PHASE_TRANSPORT || snapshot.invariants_hold != 1) {
        (void)sc_secure_connection_free_v1(connection);
        return 0;
    }
    if (sc_secure_connection_free_v1(connection) != SC_OK) {
        return 0;
    }
    return sc_core_abi_version_v1();
}

uint32_t sc_mac_rust_capability_active_marker(void) {
    ScCapabilityConfigV1 config = {
        .struct_size = sizeof(ScCapabilityConfigV1),
        .api_version = SC_API_VERSION_V1,
        .generation = 1,
        .authorized_capabilities = SC_CAPABILITY_BIT_MEDIA_HOST |
            SC_CAPABILITY_BIT_PROJECTION_EXTEND | SC_CAPABILITY_BIT_TRANSPORT_TCP,
        .side = SC_CAPABILITY_SIDE_OFFERER,
        .local_role = SC_CAPABILITY_ROLE_HOST,
        .desired_peer_role = SC_CAPABILITY_ROLE_RECEIVER,
        .projection = SC_CAPABILITY_PROJECTION_EXTEND,
        .transport = SC_CAPABILITY_TRANSPORT_TCP,
    };
    ScCapabilityNegotiationV1* negotiation = NULL;
    if (sc_capability_negotiation_new_v1(&config, &negotiation) != SC_OK ||
        negotiation == NULL) {
        return 0;
    }
    ScCapabilityEventV1 event = {
        .struct_size = sizeof(ScCapabilityEventV1),
        .api_version = SC_API_VERSION_V1,
        .generation = config.generation,
        .event_type = SC_CAPABILITY_EVENT_PEER_HELLO,
    };
    ScCapabilityEffectV1 effects[SC_CAPABILITY_MAX_EFFECTS_V1] = {0};
    size_t count = 0;
    ScCapabilitySnapshotV1 snapshot = {
        .struct_size = sizeof(ScCapabilitySnapshotV1),
        .api_version = SC_API_VERSION_V1,
    };
    if (sc_capability_negotiation_apply_v1(
            negotiation, &event, effects, SC_CAPABILITY_MAX_EFFECTS_V1, &count) != SC_OK ||
        count != 2 || sc_capability_negotiation_snapshot_v1(negotiation, &snapshot) != SC_OK ||
        snapshot.has_binding != 1) {
        (void)sc_capability_negotiation_free_v1(negotiation);
        return 0;
    }
    if (sc_capability_negotiation_free_v1(negotiation) != SC_OK) {
        return 0;
    }
    return sc_core_abi_version_v1();
}





uint32_t sc_mac_rust_admission_active_marker(void) {
    ScAdmissionConfigV1 config = {
        .struct_size = sizeof(ScAdmissionConfigV1),
        .api_version = SC_API_VERSION_V1,
        .max_pending = 1,
    };
    ScAdmissionV1* admission = NULL;
    if (sc_admission_new_v1(&config, &admission) != SC_OK || admission == NULL) return 0;
    ScAdmissionEventV1 event = {
        .struct_size = sizeof(ScAdmissionEventV1),
        .api_version = SC_API_VERSION_V1,
        .kind = SC_ADMISSION_EVENT_ACCEPTED,
        .owner = 1,
    };
    ScAdmissionEffectV1 effects[2] = {0};
    size_t written = 0;
    size_t needed = 0;
    ScAdmissionSnapshotV1 snapshot = {
        .struct_size = sizeof(ScAdmissionSnapshotV1),
        .api_version = SC_API_VERSION_V1,
    };
    const ScStatus applied = sc_admission_apply_v1(
        admission, &event, effects, 2, sizeof(ScAdmissionEffectV1), &written, &needed);
    const ScStatus snapped = sc_admission_snapshot_v1(admission, &snapshot);
    const ScStatus freed = sc_admission_free_v1(admission);
    if (applied != SC_OK || written != 1 || needed != 1 ||
        effects[0].kind != SC_ADMISSION_EFFECT_ARM_TIMER || snapped != SC_OK ||
        snapshot.pending_count != 1 || freed != SC_OK) return 0;
    return sc_core_abi_version_v1();
}

void sc_mac_auth_zeroize(void* bytes, size_t length) {
    volatile unsigned char* cursor = (volatile unsigned char*)bytes;
    while (cursor != NULL && length != 0) {
        *cursor++ = 0;
        --length;
    }
}
