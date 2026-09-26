#include "AndroidCapabilityIntentV2Bridge.h"

#include <new>

namespace superconnect::android_capability_intent_v2 {

ScStatus New(const Config& input, Handle** output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    *output = nullptr;
    ScCapabilityIntentConfigV2 config{};
    config.struct_size = sizeof(config);
    config.api_version = SC_CAPABILITY_INTENT_API_VERSION_V2;
    config.generation = input.generation;
    config.product_capabilities = input.product_capabilities;
    config.peer_capabilities = input.peer_capabilities;
    config.side = input.side;
    config.desired_peer_role = input.desired_peer_role;
    config.local_role = input.local_role;
    config.source_topology = input.source_topology;
    config.sink_presentation = input.sink_presentation;
    config.input_policy = input.input_policy;
    config.transport_preference = input.transport_preference;
    config.topology = input.topology;
    auto* wrapper = new (std::nothrow) Handle{};
    if (wrapper == nullptr) return SC_INTERNAL_ERROR;
    const auto status = sc_capability_intent_negotiation_new_v2(
        &config, &wrapper->negotiation);
    if (status != SC_OK) {
        delete wrapper;
        return status;
    }
    *output = wrapper;
    return SC_OK;
}

ScStatus Apply(Handle* handle, const Event& input, Effects* output) {
    if (handle == nullptr || handle->negotiation == nullptr || output == nullptr) {
        return SC_INVALID_ARGUMENT;
    }
    ScCapabilityIntentEventV2 event{};
    event.struct_size = sizeof(event);
    event.api_version = SC_CAPABILITY_INTENT_API_VERSION_V2;
    event.generation = input.generation;
    event.negotiation_version = input.version;
    event.event_type = input.type;
    event.has_negotiation_version = input.has_version ? 1 : 0;
    event.offerer_role = input.offerer_role;
    event.selector_role = input.selector_role;
    event.projection = input.projection;
    event.transport = input.transport;
    event.local_role = input.local_role;
    event.source_topology = input.source_topology;
    event.sink_presentation = input.sink_presentation;
    event.input_policy = input.input_policy;
    event.transport_preference = input.transport_preference;
    event.topology = input.topology;
    output->values = {};
    output->written = 0;
    std::size_t written = 0;
    const auto status = sc_capability_intent_negotiation_apply_v2(
        handle->negotiation, &event, output->values.data(), output->values.size(), &written);
    if (status == SC_OK) output->written = written;
    return status;
}

ScStatus Snapshot(const Handle* handle, ScCapabilityIntentSnapshotV2* output) {
    if (handle == nullptr || handle->negotiation == nullptr || output == nullptr) {
        return SC_INVALID_ARGUMENT;
    }
    *output = {};
    output->struct_size = sizeof(*output);
    output->api_version = SC_CAPABILITY_INTENT_API_VERSION_V2;
    return sc_capability_intent_negotiation_snapshot_v2(handle->negotiation, output);
}

ScStatus Free(Handle* handle) {
    if (handle == nullptr) return SC_INVALID_ARGUMENT;
    const auto status = sc_capability_intent_negotiation_free_v2(handle->negotiation);
    handle->negotiation = nullptr;
    delete handle;
    return status;
}

}  // namespace superconnect::android_capability_intent_v2
