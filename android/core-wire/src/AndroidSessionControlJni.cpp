#include <jni.h>

#include <array>
#include <cstring>
#include <cstdint>
#include <vector>

#include "AndroidWireBridge.h"
#include "superconnect_control_envelope.h"
#include "superconnect_session.h"

using superconnect::android_wire::ScopedObjectWipe;
using superconnect::android_wire::ScopedVectorWipe;

namespace {

jbyteArray ByteArray(JNIEnv* env, const std::vector<std::uint8_t>& bytes) {
    const auto output = env->NewByteArray(static_cast<jsize>(bytes.size()));
    if (output != nullptr) env->SetByteArrayRegion(
        output, 0, static_cast<jsize>(bytes.size()), reinterpret_cast<const jbyte*>(bytes.data()));
    return env->ExceptionCheck() ? nullptr : output;
}

template<std::size_t Count>
jlongArray LongArray(JNIEnv* env, const std::array<jlong, Count>& values) {
    const auto output = env->NewLongArray(static_cast<jsize>(values.size()));
    if (output != nullptr) env->SetLongArrayRegion(
        output, 0, static_cast<jsize>(values.size()), values.data());
    return env->ExceptionCheck() ? nullptr : output;
}

template<typename Encode>
jbyteArray EncodeBytes(JNIEnv* env, std::size_t maximum, Encode encode) {
    std::size_t needed = 0;
    if (encode(nullptr, 0, &needed) != SC_BUFFER_TOO_SMALL || needed == 0 || needed > maximum) {
        return nullptr;
    }
    std::vector<std::uint8_t> bytes(needed);
    ScopedVectorWipe<std::uint8_t> bytes_wipe(&bytes);
    const std::size_t expected = needed;
    if (encode(bytes.data(), bytes.size(), &needed) != SC_OK || needed != expected) return nullptr;
    return ByteArray(env, bytes);
}

jlong SignedBits(std::uint64_t value) {
    static_assert(sizeof(jlong) == sizeof(value));
    jlong output = 0;
    std::memcpy(&output, &value, sizeof(output));
    return output;
}

}  // namespace

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_ControlEnvelopeNative_nativeDecode(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr) return nullptr;
    const jsize length = env->GetArrayLength(source);
    if (length < 0 || length > SC_CONTROL_ENVELOPE_MAX_BYTES_V1) return nullptr;
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    ScopedVectorWipe<std::uint8_t> bytes_wipe(&bytes);
    if (length != 0) env->GetByteArrayRegion(
        source, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
    if (env->ExceptionCheck()) return nullptr;
    ScControlEnvelopeV1 value{};
    ScopedObjectWipe<ScControlEnvelopeV1> value_wipe(&value);
    value.struct_size = sizeof(value);
    value.api_version = SC_API_VERSION_V1;
    if (sc_control_envelope_decode_v1(bytes.data(), bytes.size(), &value) != SC_OK) return nullptr;
    return LongArray(env, std::array<jlong, 7>{
        value.kind, value.presence, SignedBits(value.generation),
        SignedBits(value.operation), SignedBits(value.value0), SignedBits(value.value1), value.detail,
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_ControlEnvelopeNative_nativeEncodeText(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr) return nullptr;
    const jsize length = env->GetArrayLength(source);
    if (length <= 0 || length > 4096) return nullptr;
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    ScopedVectorWipe<std::uint8_t> bytes_wipe(&bytes);
    env->GetByteArrayRegion(source, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
    if (env->ExceptionCheck()) return nullptr;
    return EncodeBytes(env, SC_CONTROL_ENVELOPE_MAX_BYTES_V1,
        [&](std::uint8_t* output, std::size_t capacity, std::size_t* needed) {
            return sc_control_text_wire_encode_v1(
                bytes.data(), bytes.size(), output, capacity, needed);
        });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_ControlEnvelopeNative_nativeEncodeError(
    JNIEnv* env, jobject, jint reason) {
    return EncodeBytes(env, 512,
        [&](std::uint8_t* output, std::size_t capacity, std::size_t* needed) {
            return sc_control_error_wire_encode_v1(
                static_cast<std::uint32_t>(reason), output, capacity, needed);
        });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_ControlEnvelopeNative_nativeEncodeSessionFatalError(
    JNIEnv* env, jobject, jint reason) {
    return EncodeBytes(env, 512,
        [&](std::uint8_t* output, std::size_t capacity, std::size_t* needed) {
            return sc_control_session_fatal_error_wire_encode_v1(
                static_cast<std::uint32_t>(reason), output, capacity, needed);
        });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_ControlEnvelopeNative_nativeEncodeUdpAux(
    JNIEnv* env, jobject, jint kind, jlong operation) {
    // The only exposed auxiliary operation is the protocol's UInt32 UDP probe token.
    if (operation < 0) return nullptr;
    return EncodeBytes(env, 256,
        [&](std::uint8_t* output, std::size_t capacity, std::size_t* needed) {
            return sc_control_udp_aux_wire_encode_v1(
                static_cast<std::uint32_t>(kind), static_cast<std::uint64_t>(operation),
                output, capacity, needed);
        });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_SessionControlNative_nativeEncode(
    JNIEnv* env, jobject, jint kind, jint presence, jlong sequence, jlong t0, jlong t1, jlong t2) {
    ScSessionControlWireV1 value{};
    ScopedObjectWipe<ScSessionControlWireV1> value_wipe(&value);
    value.struct_size = sizeof(value);
    value.api_version = SC_API_VERSION_V1;
    value.kind = static_cast<std::uint32_t>(kind);
    value.presence = static_cast<std::uint32_t>(presence);
    value.sequence = static_cast<std::uint64_t>(sequence);
    value.t0 = static_cast<std::uint64_t>(t0);
    value.t1 = static_cast<std::uint64_t>(t1);
    value.t2 = static_cast<std::uint64_t>(t2);
    std::size_t needed = 0;
    if (sc_session_control_wire_encode_v1(&value, nullptr, 0, &needed) != SC_BUFFER_TOO_SMALL ||
        needed == 0 || needed > 160) return nullptr;
    std::vector<std::uint8_t> bytes(needed);
    ScopedVectorWipe<std::uint8_t> bytes_wipe(&bytes);
    const std::size_t capacity = needed;
    if (sc_session_control_wire_encode_v1(&value, bytes.data(), bytes.size(), &needed) != SC_OK ||
        needed != capacity) return nullptr;
    return ByteArray(env, bytes);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_SessionControlNative_nativeDecode(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr) return nullptr;
    const jsize length = env->GetArrayLength(source);
    if (length < 0 || length > 160) return nullptr;
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    ScopedVectorWipe<std::uint8_t> bytes_wipe(&bytes);
    if (length != 0) env->GetByteArrayRegion(
        source, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
    if (env->ExceptionCheck()) return nullptr;
    ScSessionControlWireV1 value{};
    ScopedObjectWipe<ScSessionControlWireV1> value_wipe(&value);
    value.struct_size = sizeof(value);
    value.api_version = SC_API_VERSION_V1;
    if (sc_session_control_wire_decode_v1(bytes.data(), bytes.size(), &value) != SC_OK) return nullptr;
    return LongArray(env, std::array<jlong, 6>{
        value.kind, value.presence, static_cast<jlong>(value.sequence),
        static_cast<jlong>(value.t0), static_cast<jlong>(value.t1), static_cast<jlong>(value.t2),
    });
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_SessionHelloWireNative_nativeEncode(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr || env->GetArrayLength(source) != sizeof(ScSessionHelloWireV1)) return nullptr;
    ScSessionHelloWireV1 value{};
    ScopedObjectWipe<ScSessionHelloWireV1> value_wipe(&value);
    env->GetByteArrayRegion(source, 0, sizeof(value), reinterpret_cast<jbyte*>(&value));
    if (env->ExceptionCheck()) return nullptr;
    std::size_t needed = 0;
    if (sc_session_hello_wire_encode_v1(&value, nullptr, 0, &needed) != SC_BUFFER_TOO_SMALL ||
        needed == 0 || needed > 4096) return nullptr;
    std::vector<std::uint8_t> bytes(needed);
    ScopedVectorWipe<std::uint8_t> bytes_wipe(&bytes);
    const std::size_t capacity = needed;
    if (sc_session_hello_wire_encode_v1(&value, bytes.data(), bytes.size(), &needed) != SC_OK ||
        needed != capacity) return nullptr;
    return ByteArray(env, bytes);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_SessionHelloWireNative_nativeDecode(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr) return nullptr;
    const jsize length = env->GetArrayLength(source);
    if (length < 0 || length > 4096) return nullptr;
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    ScopedVectorWipe<std::uint8_t> bytes_wipe(&bytes);
    if (length != 0) env->GetByteArrayRegion(source, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
    if (env->ExceptionCheck()) return nullptr;
    ScSessionHelloWireV1 value{};
    ScopedObjectWipe<ScSessionHelloWireV1> value_wipe(&value);
    value.struct_size = sizeof(value);
    value.api_version = SC_API_VERSION_V1;
    if (sc_session_hello_wire_decode_v1(bytes.data(), bytes.size(), &value) != SC_OK) return nullptr;
    std::vector<std::uint8_t> record(sizeof(value));
    ScopedVectorWipe<std::uint8_t> record_wipe(&record);
    std::memcpy(record.data(), &value, sizeof(value));
    return ByteArray(env, record);
}
