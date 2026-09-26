#pragma once

#include "superconnect_admission.h"

#include <array>
#include <cstddef>
#include <cstdint>

namespace superconnect::android_admission {

using Handle = ScAdmissionV1;

struct Effects {
    std::array<ScAdmissionEffectV1, 2> values{};
    std::size_t written = 0;
};

ScStatus New(std::uint32_t max_pending, Handle** output);
ScStatus Apply(Handle* handle, std::uint32_t kind, std::uint64_t owner,
               std::uint64_t token, Effects* output);
ScStatus Snapshot(const Handle* handle, ScAdmissionSnapshotV1* output);
ScStatus Free(Handle* handle);

}  // namespace superconnect::android_admission
