#include "AndroidSessionBridge.h"

#include <algorithm>
#include <new>
#include <utility>

namespace superconnect::android_session {
namespace {

bool Identity(ScSessionPeerIdentityV1* output, const std::uint8_t* bytes, std::size_t length) {
    if (output == nullptr || bytes == nullptr || length == 0 ||
        length > SC_SESSION_MAX_PEER_IDENTITY_BYTES_V1) return false;
    output->length = static_cast<std::uint32_t>(length);
    std::copy_n(bytes, length, output->bytes);
    return true;
}

void Present(ScSessionEventV1* event, std::uint64_t bit, std::uint64_t value,
             std::uint64_t* field) {
    if (value != 0) {
        event->presence |= bit;
        *field = value;
    }
}

bool Decode(const Event& input, ScSessionEventV1* event) {
    if (event == nullptr || input.generation == 0) return false;
    *event = {};
    event->struct_size = sizeof(*event);
    event->api_version = SC_API_VERSION_V1;
    event->type = input.type;
    event->generation = input.generation;
    event->presence = SC_SESSION_FIELD_GENERATION;
    switch (input.type) {
        case SC_SESSION_EVENT_START:
        case SC_SESSION_EVENT_STREAMING_STARTED:
        case SC_SESSION_EVENT_CLOSE_REQUESTED:
        case SC_SESSION_EVENT_TRANSPORT_CLOSED:
        case SC_SESSION_EVENT_TRANSPORT_FAILED:
            return true;
        case SC_SESSION_EVENT_TRANSPORT_OPENED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            return input.operation != 0;
        case SC_SESSION_EVENT_PEER_HELLO_ACK:
            if (!Identity(&event->peer_identity, input.identity, input.identity_length)) return false;
            event->presence |= SC_SESSION_FIELD_IDENTITY;
            if (input.auth_version != 0) {
                event->presence |= SC_SESSION_FIELD_AUTH_VERSION;
                event->auth_version = input.auth_version;
            }
            Present(event, SC_SESSION_FIELD_CHALLENGE, input.first, &event->challenge);
            Present(event, SC_SESSION_FIELD_PEER_ENROLLMENT_KEY, input.second,
                    &event->peer_enrollment_key);
            event->enrollment = input.flag ? 1 : 0;
            return true;
        case SC_SESSION_EVENT_PEER_HELLO:
            if (!Identity(&event->peer_identity, input.identity, input.identity_length)) return false;
            event->presence |= SC_SESSION_FIELD_IDENTITY;
            if (input.auth_version != 0) {
                event->presence |= SC_SESSION_FIELD_AUTH_VERSION;
                event->auth_version = input.auth_version;
            }
            Present(event, SC_SESSION_FIELD_PEER_ENROLLMENT_KEY, input.first,
                    &event->peer_enrollment_key);
            return true;
        case SC_SESSION_EVENT_CREDENTIAL_LOADED:
            event->credential_state = input.credential_state;
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            if (input.credential_state == SC_SESSION_CREDENTIAL_PRESENT) {
                Present(event, SC_SESSION_FIELD_CREDENTIAL, input.first, &event->credential);
                return input.operation != 0 && input.first != 0;
            }
            return input.operation != 0 &&
                   (input.credential_state == SC_SESSION_CREDENTIAL_MISSING ||
                    input.credential_state == SC_SESSION_CREDENTIAL_UNAVAILABLE);
        case SC_SESSION_EVENT_ENROLLMENT_OPENED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            Present(event, SC_SESSION_FIELD_CANDIDATE_CREDENTIAL, input.first,
                    &event->candidate_credential);
            return input.operation != 0 && input.first != 0;
        case SC_SESSION_EVENT_ENROLLMENT_APPROVED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            event->approved = input.flag ? 1 : 0;
            return input.operation != 0;
        case SC_SESSION_EVENT_ENROLLMENT_PREPARED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            Present(event, SC_SESSION_FIELD_CANDIDATE_CREDENTIAL, input.first,
                    &event->candidate_credential);
            Present(event, SC_SESSION_FIELD_CHALLENGE, input.second, &event->challenge);
            Present(event, SC_SESSION_FIELD_ENVELOPE, input.third, &event->envelope);
            return input.operation != 0 && input.first != 0 && input.second != 0 && input.third != 0;
        case SC_SESSION_EVENT_CHALLENGE_GENERATED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            Present(event, SC_SESSION_FIELD_CHALLENGE, input.first, &event->challenge);
            return input.operation != 0 && input.first != 0;
        case SC_SESSION_EVENT_AUTH_PROOF_CREATED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            Present(event, SC_SESSION_FIELD_PROOF, input.first, &event->proof);
            Present(event, SC_SESSION_FIELD_LOCAL_CHALLENGE, input.second,
                    &event->local_challenge);
            return input.operation != 0 && input.first != 0 && input.second != 0;
        case SC_SESSION_EVENT_PEER_AUTH:
            Present(event, SC_SESSION_FIELD_PROOF, input.first, &event->proof);
            Present(event, SC_SESSION_FIELD_PEER_CHALLENGE, input.second, &event->peer_challenge);
            return input.first != 0 && input.second != 0;
        case SC_SESSION_EVENT_PEER_PROOF_VERIFIED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            event->valid = input.flag ? 1 : 0;
            return input.operation != 0;
        case SC_SESSION_EVENT_ADMISSION_CLAIM_SUCCEEDED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            Present(event, SC_SESSION_FIELD_ADMISSION_CLAIM, input.first, &event->admission_claim);
            return input.operation != 0 && input.first != 0;
        case SC_SESSION_EVENT_ADMISSION_CLAIM_FAILED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            return input.operation != 0;
        case SC_SESSION_EVENT_MUTUAL_PROOF_CREATED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            Present(event, SC_SESSION_FIELD_PROOF, input.first, &event->proof);
            return input.operation != 0 && input.first != 0;
        case SC_SESSION_EVENT_PEER_AUTH_ACK:
            Present(event, SC_SESSION_FIELD_PROOF, input.first, &event->proof);
            return input.first != 0;
        case SC_SESSION_EVENT_MUTUAL_PROOF_VERIFIED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            event->valid = input.flag ? 1 : 0;
            return input.operation != 0;
        case SC_SESSION_EVENT_CREDENTIAL_WRITE_COMPLETED:
        case SC_SESSION_EVENT_FINAL_ACK_SUBMITTED:
        case SC_SESSION_EVENT_CAPABILITIES_COMMITTED:
            Present(event, SC_SESSION_FIELD_OPERATION, input.operation, &event->operation);
            event->success = input.flag ? 1 : 0;
            return input.operation != 0;
        case SC_SESSION_EVENT_TIMER_FIRED:
            Present(event, SC_SESSION_FIELD_TIMER_TOKEN, input.first, &event->timer_token);
            return input.first != 0;
        default:
            return false;
    }
}

}  // namespace

ScStatus New(std::uint64_t generation, std::uint64_t first_operation,
             std::uint64_t local_enrollment_key, std::uint32_t origin,
             std::uint32_t side, std::uint32_t media_role,
             const std::uint8_t* local_identity, std::size_t local_identity_length,
             Handle** output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    *output = nullptr;
    ScSecureConnectionConfigV1 config{};
    config.struct_size = sizeof(config);
    config.api_version = SC_API_VERSION_V1;
    config.session.struct_size = sizeof(config.session);
    config.session.api_version = SC_API_VERSION_V1;
    config.session.generation = generation;
    config.session.first_operation_id = first_operation;
    config.session.local_enrollment_key = local_enrollment_key;
    config.session.side = side;
    config.session.media_role = media_role;
    config.session.origin = origin;
    if (!Identity(&config.session.local_identity, local_identity, local_identity_length)) {
        return SC_INVALID_ARGUMENT;
    }
    auto* wrapper = new (std::nothrow) Handle{};
    if (wrapper == nullptr) return SC_INTERNAL_ERROR;
    const auto status = sc_secure_connection_new_v1(&config, &wrapper->connection);
    if (status != SC_OK) {
        delete wrapper;
        return status;
    }
    wrapper->generation = generation;
    wrapper->side = side;
    wrapper->media_role = media_role;
    *output = wrapper;
    return SC_OK;
}

ScStatus Apply(Handle* handle, const Event& input, Effects* output) {
    if (handle == nullptr || handle->connection == nullptr || output == nullptr) {
        return SC_INVALID_ARGUMENT;
    }
    output->values = {};
    output->written = 0;
    ScSessionEventV1 event{};
    if (!Decode(input, &event)) return SC_INVALID_ARGUMENT;
    const auto status = sc_secure_connection_apply_session_v1(handle->connection, &event);
    return status == SC_OK ? DrainEffects(handle, output) : status;
}

ScStatus DrainEffects(Handle* handle, Effects* output) {
    if (handle == nullptr || handle->connection == nullptr || output == nullptr) {
        return SC_INVALID_ARGUMENT;
    }
    output->values = {};
    output->written = 0;
    while (output->written < output->values.size()) {
        auto& effect = output->values[output->written];
        effect.struct_size = sizeof(effect);
        effect.api_version = SC_API_VERSION_V1;
        const auto status = sc_secure_connection_pop_effect_v1(handle->connection, &effect);
        if (status == SC_NO_FRAME) return SC_OK;
        if (status != SC_OK) return status;
        ++output->written;
    }
    ScSecureConnectionEffectV1 extra{};
    extra.struct_size = sizeof(extra);
    extra.api_version = SC_API_VERSION_V1;
    return sc_secure_connection_pop_effect_v1(handle->connection, &extra) == SC_NO_FRAME
        ? SC_OK : SC_INTERNAL_ERROR;
}

ScStatus ObserveRecordVersion(Handle* handle, std::uint16_t version, Effects* output) {
    if (handle == nullptr || handle->connection == nullptr) return SC_INVALID_ARGUMENT;
    const auto status = sc_secure_connection_observe_record_version_v1(
        handle->connection, handle->generation, version);
    return status == SC_OK ? DrainEffects(handle, output) : status;
}

ScStatus RecordMaterialPrepared(Handle* handle, std::uint64_t operation,
                                const std::uint8_t* pair_secret,
                                const std::uint8_t* responder_challenge,
                                const std::uint8_t* initiator_challenge,
                                Effects* output) {
    if (handle == nullptr || handle->connection == nullptr || operation == 0) {
        return SC_INVALID_ARGUMENT;
    }
    const bool success = pair_secret != nullptr || responder_challenge != nullptr ||
        initiator_challenge != nullptr;
    if (success && (pair_secret == nullptr || responder_challenge == nullptr ||
                    initiator_challenge == nullptr)) return SC_INVALID_ARGUMENT;
    ScSecureRecordMaterialV1 material{};
    material.struct_size = sizeof(material);
    material.api_version = SC_API_VERSION_V1;
    material.generation = handle->generation;
    material.operation = operation;
    material.success = success ? 1 : 0;
    if (success) {
        std::copy_n(pair_secret, 32, material.pair_secret);
        std::copy_n(responder_challenge, 32, material.responder_challenge);
        std::copy_n(initiator_challenge, 32, material.initiator_challenge);
    }
    const auto status =
        sc_secure_connection_record_material_prepared_v1(handle->connection, &material);
    std::fill_n(material.pair_secret, 32, 0);
    std::fill_n(material.responder_challenge, 32, 0);
    std::fill_n(material.initiator_challenge, 32, 0);
    return status == SC_OK ? DrainEffects(handle, output) : status;
}

ScStatus RecordsActivated(Handle* handle, std::uint64_t operation, bool success, Effects* output) {
    if (handle == nullptr || handle->connection == nullptr || operation == 0) {
        return SC_INVALID_ARGUMENT;
    }
    const auto status = sc_secure_connection_records_activated_v1(
        handle->connection, handle->generation, operation, success ? 1 : 0);
    return status == SC_OK ? DrainEffects(handle, output) : status;
}

ScStatus Snapshot(const Handle* handle, ScSecureConnectionSnapshotV1* output) {
    if (handle == nullptr || handle->connection == nullptr || output == nullptr) {
        return SC_INVALID_ARGUMENT;
    }
    *output = {};
    output->struct_size = sizeof(*output);
    output->api_version = SC_API_VERSION_V1;
    return sc_secure_connection_snapshot_v1(handle->connection, output);
}

ScStatus SealFrame(Handle* handle, std::uint8_t channel, std::uint8_t flags,
                   const std::uint8_t* payload, std::size_t length,
                   std::vector<std::uint8_t>* output) {
    if (handle == nullptr || handle->connection == nullptr || output == nullptr ||
        (payload == nullptr && length != 0)) return SC_INVALID_ARGUMENT;
    output->clear();
    std::size_t needed = 0;
    auto status = sc_secure_connection_seal_frame_v1(
        handle->connection, channel, flags, payload, length, nullptr, 0, &needed);
    if (status != SC_BUFFER_TOO_SMALL || needed < 6) return status;
    output->resize(needed);
    status = sc_secure_connection_seal_frame_v1(handle->connection, channel, flags, payload,
        length, output->data(), output->size(), &needed);
    if (status != SC_OK || needed != output->size()) output->clear();
    return status;
}

ScStatus Push(Handle* handle, const std::uint8_t* bytes, std::size_t length,
              std::vector<InboundFrame>* output) {
    if (handle == nullptr || handle->connection == nullptr || output == nullptr ||
        (bytes == nullptr && length != 0)) return SC_INVALID_ARGUMENT;
    output->clear();
    auto status = sc_secure_connection_push_v1(handle->connection, bytes, length);
    if (status != SC_OK) return status;
    ScSecureInboundViewV1 view{};
    view.struct_size = sizeof(view);
    view.api_version = SC_API_VERSION_V1;
    status = sc_secure_connection_next_inbound_v1(handle->connection, &view);
    if (status == SC_NO_FRAME) return SC_OK;
    if (status != SC_OK) return status;
    InboundFrame frame{};
    frame.channel = view.channel;
    frame.flags = view.flags;
    if (view.payload_length != 0) {
        frame.payload.assign(view.payload, view.payload + view.payload_length);
    }
    frame.has_control = view.control_present != 0;
    if (frame.has_control) frame.control = view.control;
    status = sc_secure_connection_consume_inbound_v1(handle->connection, view.generation);
    if (status != SC_OK) return status;
    output->push_back(std::move(frame));
    return SC_OK;
}

ScStatus Free(Handle* handle) {
    if (handle == nullptr) return SC_INVALID_ARGUMENT;
    const auto status = sc_secure_connection_free_v1(handle->connection);
    handle->connection = nullptr;
    delete handle;
    return status;
}

}  // namespace superconnect::android_session
