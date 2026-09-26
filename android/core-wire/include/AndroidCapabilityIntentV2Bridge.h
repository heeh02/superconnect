#pragma once

#include "superconnect_capability_intent_v2.h"

#include <array>
#include <cstddef>
#include <cstdint>

namespace superconnect::android_capability_intent_v2 {

struct Handle {
    ScCapabilityIntentNegotiationV2* negotiation = nullptr;
};

struct Config {
    std::uint64_t generation = 0;
    std::uint64_t product_capabilities = 0;
    std::uint64_t peer_capabilities = 0;
    std::uint8_t side = 0;
    std::uint8_t desired_peer_role = 0;
    std::uint8_t local_role = 0;
    std::uint8_t source_topology = 0;
    std::uint8_t sink_presentation = 0;
    std::uint8_t input_policy = 0;
    std::uint8_t transport_preference = 0;
    std::uint8_t topology = 0;
};

struct Event {
    std::uint8_t type = 0;
    std::uint64_t generation = 0;
    std::uint16_t version = 0;
    bool has_version = false;
    std::uint8_t offerer_role = 0;
    std::uint8_t selector_role = 0;
    std::uint8_t projection = 0;
    std::uint8_t transport = 0;
    std::uint8_t local_role = 0;
    std::uint8_t source_topology = 0;
    std::uint8_t sink_presentation = 0;
    std::uint8_t input_policy = 0;
    std::uint8_t transport_preference = 0;
    std::uint8_t topology = 0;
};

struct Effects {
    std::array<ScCapabilityIntentEffectV2, SC_CAPABILITY_INTENT_MAX_EFFECTS_V2> values{};
    std::size_t written = 0;
};

ScStatus New(const Config& config, Handle** output);
ScStatus Apply(Handle* handle, const Event& event, Effects* output);
ScStatus Snapshot(const Handle* handle, ScCapabilityIntentSnapshotV2* output);
ScStatus Free(Handle* handle);

}  // namespace superconnect::android_capability_intent_v2
