#include "AndroidSessionBridge.h"
#include "AndroidWireBridge.h"

#include <jni.h>

#include <algorithm>
#include <array>
#include <climits>
#include <cstdint>
#include <cstring>
#include <vector>

namespace session = superconnect::android_session;

namespace {

void Throw(JNIEnv* env, const char* type, const char* message) {
    const auto klass = env->FindClass(type);
    if (klass != nullptr) env->ThrowNew(klass, message);
}

void ThrowStatus(JNIEnv* env, ScStatus status) {
    if (status == SC_INVALID_ARGUMENT) {
        Throw(env, "java/lang/IllegalArgumentException", "Rust session ABI rejected input");
    } else {
        Throw(env, "java/lang/IllegalStateException", "Rust session ABI operation failed");
    }
}

session::Handle* Handle(jlong value) {
    return reinterpret_cast<session::Handle*>(static_cast<std::uintptr_t>(value));
}

jlong HandleValue(session::Handle* value) {
    return static_cast<jlong>(reinterpret_cast<std::uintptr_t>(value));
}

jlongArray CreateEffects(JNIEnv* env, const session::Effects& effects) {
    constexpr std::size_t kFields = 18;
    constexpr std::size_t kMaximum = SC_SECURE_CONNECTION_MAX_EFFECTS_V1;
    std::array<jlong, 1 + kMaximum * kFields> values{};
    const auto output = env->NewLongArray(static_cast<jsize>(values.size()));
    if (output == nullptr) return nullptr;
    values[0] = static_cast<jlong>(effects.written);
    for (std::size_t index = 0; index < effects.written; ++index) {
        const auto& secure = effects.values[index];
        const auto offset = 1 + index * kFields;
        if (secure.type == SC_SECURE_CONNECTION_EFFECT_SESSION_V1) {
            const auto& effect = secure.session_effect;
            values[offset] = effect.type;
            values[offset + 1] = effect.fatal_reason;
            values[offset + 2] = static_cast<jlong>(effect.presence);
            values[offset + 3] = static_cast<jlong>(effect.operation);
            values[offset + 4] = static_cast<jlong>(effect.timer_token);
            values[offset + 5] = static_cast<jlong>(effect.admission_claim);
            values[offset + 6] = static_cast<jlong>(effect.credential);
            values[offset + 7] = static_cast<jlong>(effect.candidate_credential);
            values[offset + 8] = static_cast<jlong>(effect.challenge);
            values[offset + 9] = static_cast<jlong>(effect.local_challenge);
            values[offset + 10] = static_cast<jlong>(effect.peer_challenge);
            values[offset + 11] = static_cast<jlong>(effect.proof);
            values[offset + 12] = static_cast<jlong>(effect.envelope);
            values[offset + 13] = static_cast<jlong>(effect.local_enrollment_key);
            values[offset + 14] = static_cast<jlong>(effect.peer_enrollment_key);
            values[offset + 15] = effect.auth_version;
            values[offset + 16] = effect.media_role;
            values[offset + 17] = effect.enrollment;
        } else {
            values[offset] = secure.type == SC_SECURE_CONNECTION_EFFECT_PREPARE_RECORD_CONTEXT_V1
                ? 1001 : secure.type == SC_SECURE_CONNECTION_EFFECT_ACTIVATE_RECORDS_V1
                ? 1002 : secure.type == SC_SECURE_CONNECTION_EFFECT_DISPOSE_RECORDS_V1
                ? 1003 : 0;
            values[offset + 3] = static_cast<jlong>(secure.operation);
        }
    }
    env->SetLongArrayRegion(output, 0, static_cast<jsize>(values.size()), values.data());
    return output;
}

bool ReadSecret(JNIEnv* env, jbyteArray input, std::array<std::uint8_t, 32>* output) {
    if (input == nullptr || output == nullptr || env->GetArrayLength(input) != 32) return false;
    env->GetByteArrayRegion(input, 0, 32, reinterpret_cast<jbyte*>(output->data()));
    return !env->ExceptionCheck();
}

jbyteArray CreateBytes(JNIEnv* env, const std::uint8_t* bytes, std::size_t length) {
    if ((bytes == nullptr && length != 0) || length > static_cast<std::size_t>(INT32_MAX)) {
        return nullptr;
    }
    const auto output = env->NewByteArray(static_cast<jsize>(length));
    if (output != nullptr && length != 0) {
        env->SetByteArrayRegion(output, 0, static_cast<jsize>(length),
                                reinterpret_cast<const jbyte*>(bytes));
    }
    return output;
}

void AppendU32(std::vector<std::uint8_t>* output, std::uint32_t value) {
    output->push_back(static_cast<std::uint8_t>(value));
    output->push_back(static_cast<std::uint8_t>(value >> 8));
    output->push_back(static_cast<std::uint8_t>(value >> 16));
    output->push_back(static_cast<std::uint8_t>(value >> 24));
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_superconnect_receiver_SessionNative_nativeAbiVersion(JNIEnv*, jobject) {
    return static_cast<jint>(sc_android_wire_active_marker_v1());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_superconnect_receiver_SessionNative_nativeSecureAbiVersion(JNIEnv*, jobject) {
    return static_cast<jint>(sc_core_abi_version_v1());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_superconnect_receiver_SessionNative_nativeCoreAbiIdentity(JNIEnv*, jobject) {
    const auto identity = sc_core_abi_identity_v1();
    static_assert(sizeof(identity) == sizeof(jlong));
    jlong output = 0;
    std::memcpy(&output, &identity, sizeof(output));
    return output;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_superconnect_receiver_SessionNative_nativeNew(
    JNIEnv* env, jobject, jlong generation, jlong first_operation, jlong local_enrollment_key,
    jint origin, jint side, jint media_role, jbyteArray local_identity) {
    if (generation <= 0 || first_operation <= 0 || local_enrollment_key <= 0 ||
        local_identity == nullptr ||
        (side != SC_SESSION_SIDE_INITIATOR && side != SC_SESSION_SIDE_RESPONDER) ||
        (media_role != SC_SESSION_MEDIA_ROLE_HOST &&
         media_role != SC_SESSION_MEDIA_ROLE_RECEIVER)) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid session configuration");
        return 0;
    }
    const auto length = env->GetArrayLength(local_identity);
    if (length <= 0 || length > SC_SESSION_MAX_PEER_IDENTITY_BYTES_V1) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid local identity");
        return 0;
    }
    std::array<std::uint8_t, SC_SESSION_MAX_PEER_IDENTITY_BYTES_V1> identity{};
    env->GetByteArrayRegion(local_identity, 0, length,
                            reinterpret_cast<jbyte*>(identity.data()));
    if (env->ExceptionCheck()) return 0;
    session::Handle* output = nullptr;
    const auto status = session::New(static_cast<std::uint64_t>(generation),
                                     static_cast<std::uint64_t>(first_operation),
                                     static_cast<std::uint64_t>(local_enrollment_key),
                                     static_cast<std::uint32_t>(origin),
                                     static_cast<std::uint32_t>(side),
                                     static_cast<std::uint32_t>(media_role), identity.data(),
                                     static_cast<std::size_t>(length), &output);
    if (status != SC_OK || output == nullptr) {
        ThrowStatus(env, status);
        return 0;
    }
    return HandleValue(output);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_SessionNative_nativeApply(
    JNIEnv* env, jobject, jlong handle_value, jint type, jint credential_state,
    jlong generation, jlong operation, jlong first, jlong second, jlong third,
    jint auth_version, jboolean flag, jbyteArray identity_array) {
    auto* handle = Handle(handle_value);
    if (handle == nullptr || type <= 0 || generation <= 0 || operation < 0 || first < 0 ||
        second < 0 || third < 0 || auth_version < 0 || auth_version > UINT16_MAX) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid session event");
        return nullptr;
    }
    session::Event event{};
    event.type = static_cast<std::uint32_t>(type);
    event.credential_state = static_cast<std::uint32_t>(credential_state);
    event.generation = static_cast<std::uint64_t>(generation);
    event.operation = static_cast<std::uint64_t>(operation);
    event.first = static_cast<std::uint64_t>(first);
    event.second = static_cast<std::uint64_t>(second);
    event.third = static_cast<std::uint64_t>(third);
    event.auth_version = static_cast<std::uint16_t>(auth_version);
    event.flag = flag == JNI_TRUE;
    std::array<std::uint8_t, SC_SESSION_MAX_PEER_IDENTITY_BYTES_V1> identity{};
    if (identity_array != nullptr) {
        const auto length = env->GetArrayLength(identity_array);
        if (length <= 0 || length > SC_SESSION_MAX_PEER_IDENTITY_BYTES_V1) {
            Throw(env, "java/lang/IllegalArgumentException", "invalid peer identity");
            return nullptr;
        }
        env->GetByteArrayRegion(identity_array, 0, length,
                                reinterpret_cast<jbyte*>(identity.data()));
        if (env->ExceptionCheck()) return nullptr;
        event.identity = identity.data();
        event.identity_length = static_cast<std::size_t>(length);
    }

    session::Effects effects{};
    const auto status = session::Apply(handle, event, &effects);
    if (status != SC_OK) {
        ThrowStatus(env, status);
        return nullptr;
    }
    return CreateEffects(env, effects);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_SessionNative_nativeSnapshot(
    JNIEnv* env, jobject, jlong handle_value) {
    auto* handle = Handle(handle_value);
    ScSecureConnectionSnapshotV1 snapshot{};
    const auto status = session::Snapshot(handle, &snapshot);
    if (status != SC_OK) {
        ThrowStatus(env, status);
        return nullptr;
    }
    const std::array<jlong, 7> values{static_cast<jlong>(snapshot.generation),
                                      static_cast<jlong>(snapshot.session_phase), 0, 0,
                                      handle == nullptr ? 0 : handle->side,
                                      handle == nullptr ? 0 : handle->media_role,
                                      static_cast<jlong>(snapshot.records_active)};
    const auto output = env->NewLongArray(values.size());
    if (output != nullptr) env->SetLongArrayRegion(output, 0, values.size(), values.data());
    return output;
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_SessionNative_nativeObserveRecordVersion(
    JNIEnv* env, jobject, jlong handle_value, jint version) {
    if (version < 0 || version > UINT16_MAX) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid record version");
        return nullptr;
    }
    session::Effects effects{};
    const auto status = session::ObserveRecordVersion(
        Handle(handle_value), static_cast<std::uint16_t>(version), &effects);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    return CreateEffects(env, effects);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_SessionNative_nativeRecordMaterialPrepared(
    JNIEnv* env, jobject, jlong handle_value, jlong operation,
    jbyteArray pair_secret, jbyteArray responder_challenge, jbyteArray initiator_challenge) {
    const bool success = pair_secret != nullptr || responder_challenge != nullptr ||
        initiator_challenge != nullptr;
    std::array<std::uint8_t, 32> secret{};
    std::array<std::uint8_t, 32> responder{};
    std::array<std::uint8_t, 32> initiator{};
    if (operation <= 0 || (success && (!ReadSecret(env, pair_secret, &secret) ||
        !ReadSecret(env, responder_challenge, &responder) ||
        !ReadSecret(env, initiator_challenge, &initiator)))) {
        secret.fill(0); responder.fill(0); initiator.fill(0);
        Throw(env, "java/lang/IllegalArgumentException", "invalid record material");
        return nullptr;
    }
    session::Effects effects{};
    const auto status = session::RecordMaterialPrepared(
        Handle(handle_value), static_cast<std::uint64_t>(operation),
        success ? secret.data() : nullptr, success ? responder.data() : nullptr,
        success ? initiator.data() : nullptr, &effects);
    secret.fill(0); responder.fill(0); initiator.fill(0);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    return CreateEffects(env, effects);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_SessionNative_nativeRecordsActivated(
    JNIEnv* env, jobject, jlong handle_value, jlong operation, jboolean success) {
    session::Effects effects{};
    const auto status = operation <= 0 ? SC_INVALID_ARGUMENT : session::RecordsActivated(
        Handle(handle_value), static_cast<std::uint64_t>(operation), success == JNI_TRUE, &effects);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    return CreateEffects(env, effects);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_SessionNative_nativeDrainEffects(
    JNIEnv* env, jobject, jlong handle_value) {
    session::Effects effects{};
    const auto status = session::DrainEffects(Handle(handle_value), &effects);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    return CreateEffects(env, effects);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_SessionNative_nativeSealFrame(
    JNIEnv* env, jobject, jlong handle_value, jint channel, jint flags, jbyteArray payload) {
    if (channel < 0 || channel > UINT8_MAX || flags < 0 || flags > UINT8_MAX || payload == nullptr) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid secure frame");
        return nullptr;
    }
    const auto length = env->GetArrayLength(payload);
    std::vector<std::uint8_t> input(static_cast<std::size_t>(length));
    if (length != 0) env->GetByteArrayRegion(
        payload, 0, length, reinterpret_cast<jbyte*>(input.data()));
    if (env->ExceptionCheck()) return nullptr;
    std::vector<std::uint8_t> output;
    const auto status = session::SealFrame(Handle(handle_value), channel, flags,
        input.empty() ? nullptr : input.data(), input.size(), &output);
    std::fill(input.begin(), input.end(), 0);
    input.clear();
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    return CreateBytes(env, output.data(), output.size());
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_SessionNative_nativePush(
    JNIEnv* env, jobject, jlong handle_value, jbyteArray bytes) {
    if (bytes == nullptr) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid secure input");
        return nullptr;
    }
    const auto length = env->GetArrayLength(bytes);
    std::vector<std::uint8_t> input(static_cast<std::size_t>(length));
    if (length != 0) env->GetByteArrayRegion(
        bytes, 0, length, reinterpret_cast<jbyte*>(input.data()));
    if (env->ExceptionCheck()) return nullptr;
    std::vector<session::InboundFrame> frames;
    const auto status = session::Push(Handle(handle_value),
        input.empty() ? nullptr : input.data(), input.size(), &frames);
    std::fill(input.begin(), input.end(), 0);
    input.clear();
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    std::size_t total = 0;
    for (const auto& frame : frames) {
        const auto next = total + 72 + frame.payload.size();
        if (next < total || next > static_cast<std::size_t>(INT32_MAX)) {
            Throw(env, "java/lang/IllegalStateException", "secure inbound batch too large");
            return nullptr;
        }
        total = next;
    }
    std::vector<std::uint8_t> packed;
    packed.reserve(total);
    for (const auto& frame : frames) {
        packed.push_back(frame.channel);
        packed.push_back(frame.flags);
        packed.push_back(frame.has_control ? 1 : 0);
        packed.push_back(0);
        AppendU32(&packed, static_cast<std::uint32_t>(frame.payload.size()));
        const auto control = reinterpret_cast<const std::uint8_t*>(&frame.control);
        packed.insert(packed.end(), control, control + sizeof(frame.control));
        packed.insert(packed.end(), frame.payload.begin(), frame.payload.end());
    }
    const auto result = CreateBytes(env, packed.data(), packed.size());
    std::fill(packed.begin(), packed.end(), 0);
    for (auto& frame : frames) {
        std::fill(frame.payload.begin(), frame.payload.end(), 0);
        std::memset(&frame.control, 0, sizeof(frame.control));
    }
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_superconnect_receiver_SessionNative_nativeFree(
    JNIEnv* env, jobject, jlong handle_value) {
    const auto status = session::Free(Handle(handle_value));
    if (status != SC_OK) ThrowStatus(env, status);
}
