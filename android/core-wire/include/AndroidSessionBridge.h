#pragma once

#include "superconnect_secure_connection.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace superconnect::android_session {

struct Handle {
    ScSecureConnectionV1* connection = nullptr;
    std::uint64_t generation = 0;
    std::uint32_t side = 0;
    std::uint32_t media_role = 0;
};

struct Event {
    std::uint32_t type = 0;
    std::uint32_t credential_state = SC_SESSION_CREDENTIAL_NONE;
    std::uint64_t generation = 0;
    std::uint64_t operation = 0;
    std::uint64_t first = 0;
    std::uint64_t second = 0;
    std::uint64_t third = 0;
    std::uint16_t auth_version = 0;
    bool flag = false;
    const std::uint8_t* identity = nullptr;
    std::size_t identity_length = 0;
};

struct Effects {
    std::array<ScSecureConnectionEffectV1, SC_SECURE_CONNECTION_MAX_EFFECTS_V1> values{};
    std::size_t written = 0;
};

ScStatus New(std::uint64_t generation, std::uint64_t first_operation,
             std::uint64_t local_enrollment_key, std::uint32_t origin,
             std::uint32_t side, std::uint32_t media_role,
             const std::uint8_t* local_identity, std::size_t local_identity_length,
             Handle** output);
ScStatus Apply(Handle* handle, const Event& event, Effects* output);
ScStatus ObserveRecordVersion(Handle* handle, std::uint16_t version, Effects* output);
ScStatus RecordMaterialPrepared(Handle* handle, std::uint64_t operation,
                                const std::uint8_t* pair_secret,
                                const std::uint8_t* responder_challenge,
                                const std::uint8_t* initiator_challenge,
                                Effects* output);
ScStatus RecordsActivated(Handle* handle, std::uint64_t operation, bool success, Effects* output);
ScStatus DrainEffects(Handle* handle, Effects* output);
ScStatus Snapshot(const Handle* handle, ScSecureConnectionSnapshotV1* output);
ScStatus SealFrame(Handle* handle, std::uint8_t channel, std::uint8_t flags,
                   const std::uint8_t* payload, std::size_t length,
                   std::vector<std::uint8_t>* output);
struct InboundFrame {
    std::uint8_t channel = 0;
    std::uint8_t flags = 0;
    std::vector<std::uint8_t> payload;
    bool has_control = false;
    ScControlEnvelopeV1 control{};
};
ScStatus Push(Handle* handle, const std::uint8_t* bytes, std::size_t length,
              std::vector<InboundFrame>* output);
ScStatus Free(Handle* handle);

}  // namespace superconnect::android_session
