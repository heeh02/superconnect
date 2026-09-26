#include "AndroidCapabilityIntentV2Bridge.h"

#include <jni.h>

#include <array>
#include <cstdint>
#include <limits>

namespace intent = superconnect::android_capability_intent_v2;

namespace {

constexpr std::size_t kEffectFields = 27;
constexpr std::size_t kWireRecordFields = 13;
constexpr std::size_t kProfileRecordFields = 3;

void Throw(JNIEnv* env, const char* type, const char* message) {
    const auto klass = env->FindClass(type);
    if (klass != nullptr) env->ThrowNew(klass, message);
}

void ThrowStatus(JNIEnv* env, ScStatus status) {
    Throw(env, status == SC_INVALID_ARGUMENT ? "java/lang/IllegalArgumentException"
                                             : "java/lang/IllegalStateException",
          status == SC_INVALID_ARGUMENT ? "Rust capability intent v2 ABI rejected input"
                                        : "Rust capability intent v2 ABI operation failed");
}

intent::Handle* Handle(jlong value) {
    return reinterpret_cast<intent::Handle*>(static_cast<std::uintptr_t>(value));
}

jlong HandleValue(intent::Handle* value) {
    return static_cast<jlong>(reinterpret_cast<std::uintptr_t>(value));
}

template <typename T>
bool IsByte(T value) {
    return value >= 0 && value <= UINT8_MAX;
}

template <std::size_t Size>
bool CopyRecord(JNIEnv* env, jlongArray source, std::array<jlong, Size>* output) {
    if (source == nullptr || output == nullptr ||
        env->GetArrayLength(source) != static_cast<jsize>(Size)) {
        return false;
    }
    env->GetLongArrayRegion(source, 0, static_cast<jsize>(Size), output->data());
    return !env->ExceptionCheck();
}

bool InvalidStatusOrThrow(JNIEnv* env, ScStatus status) {
    if (status == SC_INVALID_ARGUMENT) return true;
    if (status != SC_OK) ThrowStatus(env, status);
    return status != SC_OK;
}

template <std::size_t Size>
jlongArray LongArray(JNIEnv* env, const std::array<jlong, Size>& values) {
    const auto result = env->NewLongArray(static_cast<jsize>(Size));
    if (result == nullptr) return nullptr;
    env->SetLongArrayRegion(result, 0, static_cast<jsize>(Size), values.data());
    return result;
}

template <typename Input, typename Encode>
jbyteArray EncodeBytes(JNIEnv* env, const Input& input, Encode encode) {
    std::size_t needed = 0;
    auto status = encode(&input, static_cast<std::uint8_t*>(nullptr), 0, &needed);
    if (status == SC_INVALID_ARGUMENT) return nullptr;
    if (status != SC_BUFFER_TOO_SMALL || needed == 0 ||
        needed > static_cast<std::size_t>(std::numeric_limits<jsize>::max())) {
        ThrowStatus(env, status == SC_BUFFER_TOO_SMALL ? SC_INTERNAL_ERROR : status);
        return nullptr;
    }
    const auto expected_needed = needed;
    const auto result = env->NewByteArray(static_cast<jsize>(expected_needed));
    if (result == nullptr) return nullptr;
    auto* bytes = env->GetByteArrayElements(result, nullptr);
    if (bytes == nullptr) return nullptr;
    status = encode(
        &input, reinterpret_cast<std::uint8_t*>(bytes), expected_needed, &needed);
    const auto exact = status == SC_OK && needed == expected_needed;
    env->ReleaseByteArrayElements(result, bytes, exact ? 0 : JNI_ABORT);
    if (!exact) {
        ThrowStatus(env, status == SC_OK ? SC_INTERNAL_ERROR : status);
        return nullptr;
    }
    return result;
}

template <typename Output, typename Decode>
bool DecodeBytes(JNIEnv* env, jbyteArray input, Output* output, Decode decode) {
    if (input == nullptr) return false;
    const auto length = env->GetArrayLength(input);
    auto* bytes = length == 0 ? nullptr : env->GetByteArrayElements(input, nullptr);
    if (length != 0 && bytes == nullptr) return false;
    const auto status = decode(
        reinterpret_cast<const std::uint8_t*>(bytes), static_cast<std::size_t>(length), output);
    if (bytes != nullptr) env->ReleaseByteArrayElements(input, bytes, JNI_ABORT);
    return !InvalidStatusOrThrow(env, status);
}

void PackEffect(const ScCapabilityIntentEffectV2& effect, jlong* output) {
    output[0] = effect.effect_type;
    output[1] = effect.reason;
    output[2] = static_cast<jlong>(effect.generation);
    output[3] = static_cast<jlong>(effect.expected_generation);
    output[4] = static_cast<jlong>(effect.received_generation);
    output[5] = effect.negotiation_version;
    output[6] = effect.expected_version;
    output[7] = effect.received_version;
    output[8] = effect.offerer_role;
    output[9] = effect.selector_role;
    output[10] = effect.local_role;
    output[11] = effect.peer_role;
    output[12] = effect.projection;
    output[13] = effect.transport;
    output[14] = effect.negotiated;
    output[15] = effect.resolved_local_role;
    output[16] = effect.resolved_source_topology;
    output[17] = effect.resolved_sink_presentation;
    output[18] = effect.resolved_input_policy;
    output[19] = effect.resolved_transport_preference;
    output[20] = effect.resolved_topology;
    output[21] = effect.expected_role;
    output[22] = effect.received_role;
    output[23] = effect.expected_projection;
    output[24] = effect.received_projection;
    output[25] = effect.expected_transport;
    output[26] = effect.received_transport;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_superconnect_receiver_CapabilityIntentV2Native_nativeAbiVersion(JNIEnv*, jobject) {
    return SC_CAPABILITY_INTENT_API_VERSION_V2;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_superconnect_receiver_CapabilityIntentV2Native_nativeNew(
    JNIEnv* env, jobject, jlong generation, jlong product_capabilities,
    jlong peer_capabilities, jint side, jint desired_peer_role, jint local_role,
    jint source_topology, jint sink_presentation, jint input_policy,
    jint transport_preference, jint topology) {
    if (generation == 0 || !IsByte(side) || !IsByte(desired_peer_role) ||
        !IsByte(local_role) || !IsByte(source_topology) || !IsByte(sink_presentation) ||
        !IsByte(input_policy) || !IsByte(transport_preference) || !IsByte(topology)) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid capability intent v2 config");
        return 0;
    }
    intent::Config config{};
    config.generation = static_cast<std::uint64_t>(generation);
    config.product_capabilities = static_cast<std::uint64_t>(product_capabilities);
    config.peer_capabilities = static_cast<std::uint64_t>(peer_capabilities);
    config.side = static_cast<std::uint8_t>(side);
    config.desired_peer_role = static_cast<std::uint8_t>(desired_peer_role);
    config.local_role = static_cast<std::uint8_t>(local_role);
    config.source_topology = static_cast<std::uint8_t>(source_topology);
    config.sink_presentation = static_cast<std::uint8_t>(sink_presentation);
    config.input_policy = static_cast<std::uint8_t>(input_policy);
    config.transport_preference = static_cast<std::uint8_t>(transport_preference);
    config.topology = static_cast<std::uint8_t>(topology);
    intent::Handle* output = nullptr;
    const auto status = intent::New(config, &output);
    if (status != SC_OK || output == nullptr) {
        ThrowStatus(env, status);
        return 0;
    }
    return HandleValue(output);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_CapabilityIntentV2Native_nativeApply(
    JNIEnv* env, jobject, jlong handle_value, jint type, jlong generation,
    jint version, jboolean has_version, jint offerer_role, jint selector_role,
    jint projection, jint transport, jint local_role, jint source_topology,
    jint sink_presentation, jint input_policy, jint transport_preference, jint topology) {
    const std::array<jint, 10> bytes = {
        type, offerer_role, selector_role, projection, transport, local_role,
        source_topology, sink_presentation, input_policy, transport_preference,
    };
    if (Handle(handle_value) == nullptr || generation == 0 || version < 0 ||
        version > UINT16_MAX || !IsByte(topology)) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid capability intent v2 event");
        return nullptr;
    }
    for (const auto value : bytes) {
        if (!IsByte(value)) {
            Throw(env, "java/lang/IllegalArgumentException", "invalid capability intent v2 event");
            return nullptr;
        }
    }
    intent::Event event{};
    event.type = static_cast<std::uint8_t>(type);
    event.generation = static_cast<std::uint64_t>(generation);
    event.version = static_cast<std::uint16_t>(version);
    event.has_version = has_version == JNI_TRUE;
    event.offerer_role = static_cast<std::uint8_t>(offerer_role);
    event.selector_role = static_cast<std::uint8_t>(selector_role);
    event.projection = static_cast<std::uint8_t>(projection);
    event.transport = static_cast<std::uint8_t>(transport);
    event.local_role = static_cast<std::uint8_t>(local_role);
    event.source_topology = static_cast<std::uint8_t>(source_topology);
    event.sink_presentation = static_cast<std::uint8_t>(sink_presentation);
    event.input_policy = static_cast<std::uint8_t>(input_policy);
    event.transport_preference = static_cast<std::uint8_t>(transport_preference);
    event.topology = static_cast<std::uint8_t>(topology);
    intent::Effects effects{};
    const auto status = intent::Apply(Handle(handle_value), event, &effects);
    if (status != SC_OK) {
        ThrowStatus(env, status);
        return nullptr;
    }
    std::array<jlong, 1 + SC_CAPABILITY_INTENT_MAX_EFFECTS_V2 * kEffectFields> values{};
    values[0] = static_cast<jlong>(effects.written);
    for (std::size_t index = 0; index < effects.written; ++index) {
        PackEffect(effects.values[index], values.data() + 1 + index * kEffectFields);
    }
    return LongArray(env, values);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_CapabilityIntentV2Native_nativeSnapshot(
    JNIEnv* env, jobject, jlong handle_value) {
    ScCapabilityIntentSnapshotV2 snapshot{};
    const auto status = intent::Snapshot(Handle(handle_value), &snapshot);
    if (status != SC_OK) {
        ThrowStatus(env, status);
        return nullptr;
    }
    const std::array<jlong, 20> values = {
        static_cast<jlong>(snapshot.generation),
        static_cast<jlong>(snapshot.product_capabilities),
        static_cast<jlong>(snapshot.peer_capabilities),
        snapshot.side, snapshot.desired_peer_role, snapshot.has_binding,
        snapshot.binding_negotiated,
        snapshot.resolved_local_role, snapshot.resolved_source_topology,
        snapshot.resolved_sink_presentation, snapshot.resolved_input_policy,
        snapshot.resolved_transport_preference, snapshot.resolved_topology,
        snapshot.binding_local_role, snapshot.binding_source_topology,
        snapshot.binding_sink_presentation, snapshot.binding_input_policy,
        snapshot.binding_transport_preference, snapshot.binding_topology,
        snapshot.binding_peer_role,
    };
    return LongArray(env, values);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_CapabilityIntentV2Native_nativeEncodeWire(
    JNIEnv* env, jobject, jlongArray input) {
    std::array<jlong, kWireRecordFields> record{};
    if (!CopyRecord(env, input, &record) || record[1] == 0 ||
        !IsByte(record[0]) || record[2] < 0 || record[2] > UINT16_MAX) {
        return nullptr;
    }
    for (std::size_t index = 3; index < record.size(); ++index) {
        if (!IsByte(record[index])) return nullptr;
    }
    ScCapabilityIntentEventV2 event{};
    event.struct_size = sizeof(event);
    event.api_version = SC_CAPABILITY_INTENT_API_VERSION_V2;
    event.event_type = static_cast<std::uint8_t>(record[0]);
    event.generation = static_cast<std::uint64_t>(record[1]);
    event.negotiation_version = static_cast<std::uint16_t>(record[2]);
    event.has_negotiation_version = 1;
    event.offerer_role = static_cast<std::uint8_t>(record[3]);
    event.selector_role = static_cast<std::uint8_t>(record[4]);
    event.projection = static_cast<std::uint8_t>(record[5]);
    event.transport = static_cast<std::uint8_t>(record[6]);
    event.local_role = static_cast<std::uint8_t>(record[7]);
    event.source_topology = static_cast<std::uint8_t>(record[8]);
    event.sink_presentation = static_cast<std::uint8_t>(record[9]);
    event.input_policy = static_cast<std::uint8_t>(record[10]);
    event.transport_preference = static_cast<std::uint8_t>(record[11]);
    event.topology = static_cast<std::uint8_t>(record[12]);
    return EncodeBytes(env, event, [](const auto* value, auto* output, auto capacity,
                                      auto* needed) {
        return ::sc_capability_intent_wire_encode_v2(value, output, capacity, needed);
    });
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_CapabilityIntentV2Native_nativeDecodeWire(
    JNIEnv* env, jobject, jbyteArray input) {
    ScCapabilityIntentEventV2 event{};
    event.struct_size = sizeof(event);
    event.api_version = SC_CAPABILITY_INTENT_API_VERSION_V2;
    if (!DecodeBytes(env, input, &event, [](const auto* bytes, auto length, auto* value) {
            return ::sc_capability_intent_wire_decode_v2(bytes, length, value);
        })) return nullptr;
    const std::array<jlong, kWireRecordFields> record = {
        event.event_type,
        static_cast<jlong>(event.generation),
        event.negotiation_version,
        event.offerer_role,
        event.selector_role,
        event.projection,
        event.transport,
        event.local_role,
        event.source_topology,
        event.sink_presentation,
        event.input_policy,
        event.transport_preference,
        event.topology,
    };
    return LongArray(env, record);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_CapabilityIntentV2Native_nativeEncodeProfileWire(
    JNIEnv* env, jobject, jlongArray input) {
    std::array<jlong, kProfileRecordFields> record{};
    if (!CopyRecord(env, input, &record) || record[0] == 0 || !IsByte(record[2])) {
        return nullptr;
    }
    ScCapabilityIntentProfileV2 profile{};
    profile.struct_size = sizeof(profile);
    profile.api_version = SC_CAPABILITY_INTENT_API_VERSION_V2;
    profile.generation = static_cast<std::uint64_t>(record[0]);
    profile.capabilities = static_cast<std::uint64_t>(record[1]);
    profile.sender_role = static_cast<std::uint8_t>(record[2]);
    return EncodeBytes(env, profile, [](const auto* value, auto* output, auto capacity,
                                        auto* needed) {
        return ::sc_capability_intent_profile_wire_encode_v2(value, output, capacity, needed);
    });
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_CapabilityIntentV2Native_nativeDecodeProfileWire(
    JNIEnv* env, jobject, jbyteArray input) {
    ScCapabilityIntentProfileV2 profile{};
    profile.struct_size = sizeof(profile);
    profile.api_version = SC_CAPABILITY_INTENT_API_VERSION_V2;
    if (!DecodeBytes(env, input, &profile, [](const auto* bytes, auto length, auto* value) {
            return ::sc_capability_intent_profile_wire_decode_v2(bytes, length, value);
        })) {
        return nullptr;
    }
    const std::array<jlong, kProfileRecordFields> record = {
        static_cast<jlong>(profile.generation),
        static_cast<jlong>(profile.capabilities),
        profile.sender_role,
    };
    return LongArray(env, record);
}

extern "C" JNIEXPORT void JNICALL
Java_com_superconnect_receiver_CapabilityIntentV2Native_nativeFree(
    JNIEnv* env, jobject, jlong handle_value) {
    const auto status = intent::Free(Handle(handle_value));
    if (status != SC_OK) ThrowStatus(env, status);
}
