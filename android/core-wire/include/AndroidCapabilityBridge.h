#pragma once

#include "superconnect_capability.h"

#include <array>
#include <cstddef>
#include <cstdint>

namespace superconnect::android_capability {

struct Handle {
    ScCapabilityNegotiationV1* negotiation = nullptr;
};

struct Event {
    std::uint8_t type = 0;
    std::uint64_t generation = 0;
    std::uint64_t capabilities = 0;
    std::uint16_t version = 0;
    bool has_version = false;
    std::uint8_t offerer_role = 0;
    std::uint8_t selector_role = 0;
    std::uint8_t projection = 0;
    std::uint8_t transport = 0;
};

struct Effects {
    std::array<ScCapabilityEffectV1, SC_CAPABILITY_MAX_EFFECTS_V1> values{};
    std::size_t written = 0;
};

ScStatus New(std::uint64_t generation, std::uint64_t authorized_capabilities,
             std::uint8_t projection, Handle** output);
ScStatus Apply(Handle* handle, const Event& event, Effects* output);
ScStatus Free(Handle* handle);

}  // namespace superconnect::android_capability
