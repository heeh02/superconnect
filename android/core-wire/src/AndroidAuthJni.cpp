#include "AndroidAuthBridge.h"
#include "AndroidWireBridge.h"

#include <jni.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace auth = superconnect::android_auth;
using superconnect::android_wire::ScopedObjectWipe;
using superconnect::android_wire::ScopedVectorWipe;

namespace {

void Throw(JNIEnv* env, const char* type, const char* message) {
    const auto klass = env->FindClass(type);
    if (klass != nullptr) env->ThrowNew(klass, message);
}

void ThrowStatus(JNIEnv* env, ScStatus status) {
    if (status == SC_INVALID_ARGUMENT) {
        Throw(env, "java/lang/IllegalArgumentException", "Rust auth ABI rejected input");
    } else if (status == SC_AUTHENTICATION_FAILED) {
        Throw(env, "java/lang/SecurityException", "authentication failed");
    } else {
        Throw(env, "java/lang/IllegalStateException", "Rust auth ABI operation failed");
    }
}

template <std::size_t Size>
bool ReadExact(JNIEnv* env, jbyteArray input, std::array<std::uint8_t, Size>* output) {
    if (input == nullptr || env->GetArrayLength(input) != static_cast<jsize>(Size)) return false;
    env->GetByteArrayRegion(input, 0, static_cast<jsize>(Size),
                            reinterpret_cast<jbyte*>(output->data()));
    return !env->ExceptionCheck();
}

bool ReadPeer(JNIEnv* env, jbyteArray input, std::string* output) {
    if (input == nullptr) return false;
    const auto length = env->GetArrayLength(input);
    if (length <= 0 || length > SC_AUTH_MAX_PEER_ID_BYTES) return false;
    output->resize(static_cast<std::size_t>(length));
    env->GetByteArrayRegion(input, 0, length, reinterpret_cast<jbyte*>(output->data()));
    return !env->ExceptionCheck();
}

template <std::size_t Size>
jbyteArray ToByteArray(JNIEnv* env, const std::array<std::uint8_t, Size>& bytes) {
    const auto output = env->NewByteArray(static_cast<jsize>(Size));
    if (output != nullptr) {
        env->SetByteArrayRegion(output, 0, static_cast<jsize>(Size),
                                reinterpret_cast<const jbyte*>(bytes.data()));
    }
    return output;
}

template <typename T>
void Wipe(T* value) {
    auto* bytes = reinterpret_cast<volatile std::uint8_t*>(value);
    for (std::size_t index = 0; index < sizeof(T); ++index) bytes[index] = 0;
}

}  // namespace

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_AuthWireNative_nativeEncodeWire(
    JNIEnv* env, jobject, jbyteArray source) {
    std::array<std::uint8_t, sizeof(ScAuthWireMessageV1)> record{};
    ScopedObjectWipe<decltype(record)> record_wipe(&record);
    if (!ReadExact(env, source, &record)) return nullptr;
    ScAuthWireMessageV1 value{};
    ScopedObjectWipe<ScAuthWireMessageV1> value_wipe(&value);
    std::memcpy(&value, record.data(), sizeof(value));
    std::size_t needed = 0;
    if (sc_auth_wire_encode_v1(&value, nullptr, 0, &needed) != SC_BUFFER_TOO_SMALL || needed == 0) {
        return nullptr;
    }
    std::vector<std::uint8_t> bytes(needed);
    ScopedVectorWipe<std::uint8_t> bytes_wipe(&bytes);
    const auto capacity = needed;
    if (sc_auth_wire_encode_v1(&value, bytes.data(), bytes.size(), &needed) != SC_OK ||
        needed != capacity) return nullptr;
    const auto output = env->NewByteArray(static_cast<jsize>(bytes.size()));
    if (output != nullptr) env->SetByteArrayRegion(
        output, 0, static_cast<jsize>(bytes.size()), reinterpret_cast<const jbyte*>(bytes.data()));
    return output;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_AuthWireNative_nativeDecodeWire(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr) return nullptr;
    const auto length = env->GetArrayLength(source);
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    ScopedVectorWipe<std::uint8_t> bytes_wipe(&bytes);
    if (length != 0) env->GetByteArrayRegion(
        source, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
    ScAuthWireMessageV1 value{};
    ScopedObjectWipe<ScAuthWireMessageV1> value_wipe(&value);
    value.struct_size = sizeof(value); value.api_version = SC_API_VERSION_V1;
    if (env->ExceptionCheck() || sc_auth_wire_decode_v1(bytes.data(), bytes.size(), &value) != SC_OK) {
        return nullptr;
    }
    std::array<std::uint8_t, sizeof(value)> record{};
    ScopedObjectWipe<decltype(record)> record_wipe(&record);
    std::memcpy(record.data(), &value, sizeof(value));
    return ToByteArray(env, record);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_superconnect_protocol_AuthNative_nativeAbiVersion(JNIEnv*, jobject) {
    return static_cast<jint>(sc_android_wire_active_marker_v1());
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_superconnect_protocol_AuthNative_nativeValidatePeerId(
    JNIEnv* env, jobject, jbyteArray peer_id) {
    std::string peer;
    return ReadPeer(env, peer_id, &peer) && auth::ValidatePeerId(peer) == SC_OK ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_protocol_AuthNative_nativeCreateProof(
    JNIEnv* env, jobject, jbyteArray secret_value, jbyteArray prover_value,
    jbyteArray verifier_value, jbyteArray nonce_value) {
    auth::Secret32 secret{};
    auth::Nonce32 nonce{};
    std::string prover;
    std::string verifier;
    if (!ReadExact(env, secret_value, &secret) || !ReadPeer(env, prover_value, &prover) ||
        !ReadPeer(env, verifier_value, &verifier) || !ReadExact(env, nonce_value, &nonce)) {
        Wipe(&secret); Wipe(&nonce);
        Throw(env, "java/lang/IllegalArgumentException", "invalid auth proof input");
        return nullptr;
    }
    auth::Secret32 proof{};
    const auto status = auth::CreateProof(secret, prover, verifier, nonce, &proof);
    Wipe(&secret); Wipe(&nonce);
    if (status != SC_OK) { Wipe(&proof); ThrowStatus(env, status); return nullptr; }
    const auto output = ToByteArray(env, proof);
    Wipe(&proof);
    return output;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_superconnect_protocol_AuthNative_nativeVerifyProof(
    JNIEnv* env, jobject, jbyteArray proof_value, jbyteArray secret_value,
    jbyteArray prover_value, jbyteArray verifier_value, jbyteArray nonce_value) {
    auth::Secret32 proof{};
    auth::Secret32 secret{};
    auth::Nonce32 nonce{};
    std::string prover;
    std::string verifier;
    if (!ReadExact(env, proof_value, &proof) || !ReadExact(env, secret_value, &secret) ||
        !ReadPeer(env, prover_value, &prover) || !ReadPeer(env, verifier_value, &verifier) ||
        !ReadExact(env, nonce_value, &nonce)) {
        Wipe(&proof); Wipe(&secret); Wipe(&nonce);
        return JNI_FALSE;
    }
    const auto status = auth::VerifyProof(proof, secret, prover, verifier, nonce);
    Wipe(&proof); Wipe(&secret); Wipe(&nonce);
    if (status == SC_OK) return JNI_TRUE;
    if (status == SC_AUTHENTICATION_FAILED || status == SC_INVALID_ARGUMENT) return JNI_FALSE;
    ThrowStatus(env, status);
    return JNI_FALSE;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_protocol_AuthNative_nativePublicFromPrivate(
    JNIEnv* env, jobject, jbyteArray scalar_value) {
    auth::Private32 scalar{};
    if (!ReadExact(env, scalar_value, &scalar)) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid private scalar");
        return nullptr;
    }
    auth::Public65 output{};
    const auto status = auth::PublicFromPrivate(scalar, &output);
    Wipe(&scalar);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    return ToByteArray(env, output);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_protocol_AuthNative_nativeDerivePairKey(
    JNIEnv* env, jobject, jbyteArray scalar_value, jbyteArray public_value, jbyteArray salt_value) {
    auth::Private32 scalar{};
    auth::Public65 peer_public{};
    auth::Salt16 salt{};
    if (!ReadExact(env, scalar_value, &scalar) || !ReadExact(env, public_value, &peer_public) ||
        !ReadExact(env, salt_value, &salt)) {
        Wipe(&scalar);
        Throw(env, "java/lang/IllegalArgumentException", "invalid pair-key input");
        return nullptr;
    }
    auth::Secret32 output{};
    const auto status = auth::DerivePairKey(scalar, peer_public, salt, &output);
    Wipe(&scalar);
    if (status != SC_OK) { Wipe(&output); ThrowStatus(env, status); return nullptr; }
    const auto result = ToByteArray(env, output);
    Wipe(&output);
    return result;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_protocol_AuthNative_nativeSealPairSecret(
    JNIEnv* env, jobject, jbyteArray secret_value, jbyteArray key_value, jbyteArray nonce_value) {
    auth::Secret32 secret{};
    auth::Secret32 key{};
    auth::AeadNonce12 nonce{};
    if (!ReadExact(env, secret_value, &secret) || !ReadExact(env, key_value, &key) ||
        !ReadExact(env, nonce_value, &nonce)) {
        Wipe(&secret); Wipe(&key);
        Throw(env, "java/lang/IllegalArgumentException", "invalid seal input");
        return nullptr;
    }
    auth::Sealed48 output{};
    const auto status = auth::SealPairSecret(secret, key, nonce, &output);
    Wipe(&secret); Wipe(&key);
    if (status != SC_OK) { Wipe(&output); ThrowStatus(env, status); return nullptr; }
    const auto result = ToByteArray(env, output);
    Wipe(&output);
    return result;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_protocol_AuthNative_nativeOpenPairSecret(
    JNIEnv* env, jobject, jbyteArray sealed_value, jbyteArray key_value, jbyteArray nonce_value) {
    auth::Sealed48 sealed{};
    auth::Secret32 key{};
    auth::AeadNonce12 nonce{};
    if (!ReadExact(env, sealed_value, &sealed) || !ReadExact(env, key_value, &key) ||
        !ReadExact(env, nonce_value, &nonce)) {
        Wipe(&key);
        Throw(env, "java/lang/IllegalArgumentException", "invalid open input");
        return nullptr;
    }
    auth::Secret32 output{};
    const auto status = auth::OpenPairSecret(sealed, key, nonce, &output);
    Wipe(&key); Wipe(&sealed);
    if (status != SC_OK) { Wipe(&output); ThrowStatus(env, status); return nullptr; }
    const auto result = ToByteArray(env, output);
    Wipe(&output);
    return result;
}
