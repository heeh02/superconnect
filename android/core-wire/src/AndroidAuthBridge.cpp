#include "AndroidAuthBridge.h"
#include "AndroidWireBridge.h"

#include <algorithm>
#include <cstddef>

namespace superconnect::android_auth {
using superconnect::android_wire::ScopedObjectWipe;
namespace {

template <typename T>
void Wipe(T* value) {
    auto* bytes = reinterpret_cast<volatile std::uint8_t*>(value);
    for (std::size_t index = 0; index < sizeof(T); ++index) bytes[index] = 0;
}

bool CopyPeer(std::string_view source, std::uint32_t* length,
              std::uint8_t (&destination)[SC_AUTH_MAX_PEER_ID_BYTES]) {
    if (source.empty() || source.size() > SC_AUTH_MAX_PEER_ID_BYTES) return false;
    *length = static_cast<std::uint32_t>(source.size());
    std::copy(source.begin(), source.end(), destination);
    return true;
}

}  // namespace

ScStatus ValidatePeerId(std::string_view peer_id) {
    ScAuthPeerIdV1 input{};
    ScopedObjectWipe<ScAuthPeerIdV1> input_wipe(&input);
    input.struct_size = sizeof(input);
    input.api_version = SC_API_VERSION_V1;
    if (!CopyPeer(peer_id, &input.length, input.bytes)) return SC_INVALID_ARGUMENT;
    return sc_auth_peer_id_validate_v1(&input);
}

ScStatus CreateProof(const Secret32& secret, std::string_view prover, std::string_view verifier,
                     const Nonce32& nonce, Secret32* output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    ScAuthProofCreateRequestV1 input{};
    ScopedObjectWipe<ScAuthProofCreateRequestV1> input_wipe(&input);
    input.struct_size = sizeof(input);
    input.api_version = SC_API_VERSION_V1;
    std::copy(secret.begin(), secret.end(), input.pair_secret);
    std::copy(nonce.begin(), nonce.end(), input.nonce);
    if (!CopyPeer(prover, &input.prover_id_length, input.prover_id) ||
        !CopyPeer(verifier, &input.verifier_id_length, input.verifier_id)) {
        Wipe(&input);
        return SC_INVALID_ARGUMENT;
    }
    ScAuthProofV1 result{};
    ScopedObjectWipe<ScAuthProofV1> result_wipe(&result);
    result.struct_size = sizeof(result);
    result.api_version = SC_API_VERSION_V1;
    const auto status = sc_auth_proof_create_v1(&input, &result);
    Wipe(&input);
    if (status == SC_OK) std::copy(std::begin(result.proof), std::end(result.proof), output->begin());
    Wipe(&result);
    return status;
}

ScStatus VerifyProof(const Secret32& proof, const Secret32& secret, std::string_view prover,
                     std::string_view verifier, const Nonce32& nonce) {
    ScAuthProofVerifyRequestV1 input{};
    ScopedObjectWipe<ScAuthProofVerifyRequestV1> input_wipe(&input);
    input.struct_size = sizeof(input);
    input.api_version = SC_API_VERSION_V1;
    std::copy(secret.begin(), secret.end(), input.pair_secret);
    std::copy(nonce.begin(), nonce.end(), input.nonce);
    std::copy(proof.begin(), proof.end(), input.proof);
    if (!CopyPeer(prover, &input.prover_id_length, input.prover_id) ||
        !CopyPeer(verifier, &input.verifier_id_length, input.verifier_id)) {
        Wipe(&input);
        return SC_INVALID_ARGUMENT;
    }
    const auto status = sc_auth_proof_verify_v1(&input);
    Wipe(&input);
    return status;
}

ScStatus PublicFromPrivate(const Private32& scalar, Public65* output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    ScAuthP256PrivateRequestV1 input{};
    ScopedObjectWipe<ScAuthP256PrivateRequestV1> input_wipe(&input);
    input.struct_size = sizeof(input);
    input.api_version = SC_API_VERSION_V1;
    std::copy(scalar.begin(), scalar.end(), input.private_scalar);
    ScAuthP256PublicKeyV1 result{};
    ScopedObjectWipe<ScAuthP256PublicKeyV1> result_wipe(&result);
    result.struct_size = sizeof(result);
    result.api_version = SC_API_VERSION_V1;
    const auto status = sc_auth_p256_public_from_private_v1(&input, &result);
    Wipe(&input);
    if (status == SC_OK) {
        std::copy(std::begin(result.public_key), std::end(result.public_key), output->begin());
    }
    return status;
}

ScStatus DerivePairKey(const Private32& scalar, const Public65& peer_public,
                       const Salt16& salt, Secret32* output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    ScAuthPairKeyDeriveRequestV1 input{};
    ScopedObjectWipe<ScAuthPairKeyDeriveRequestV1> input_wipe(&input);
    input.struct_size = sizeof(input);
    input.api_version = SC_API_VERSION_V1;
    std::copy(scalar.begin(), scalar.end(), input.private_scalar);
    std::copy(peer_public.begin(), peer_public.end(), input.peer_public_key);
    std::copy(salt.begin(), salt.end(), input.pairing_salt);
    ScAuthPairKeyV1 result{};
    ScopedObjectWipe<ScAuthPairKeyV1> result_wipe(&result);
    result.struct_size = sizeof(result);
    result.api_version = SC_API_VERSION_V1;
    const auto status = sc_auth_pair_key_derive_v1(&input, &result);
    Wipe(&input);
    if (status == SC_OK) {
        std::copy(std::begin(result.pair_key), std::end(result.pair_key), output->begin());
    }
    Wipe(&result);
    return status;
}

ScStatus SealPairSecret(const Secret32& secret, const Secret32& key,
                        const AeadNonce12& nonce, Sealed48* output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    ScAuthSealRequestV1 input{};
    ScopedObjectWipe<ScAuthSealRequestV1> input_wipe(&input);
    input.struct_size = sizeof(input);
    input.api_version = SC_API_VERSION_V1;
    std::copy(secret.begin(), secret.end(), input.pair_secret);
    std::copy(key.begin(), key.end(), input.pair_key);
    std::copy(nonce.begin(), nonce.end(), input.nonce);
    ScAuthSealedPairSecretV1 result{};
    ScopedObjectWipe<ScAuthSealedPairSecretV1> result_wipe(&result);
    result.struct_size = sizeof(result);
    result.api_version = SC_API_VERSION_V1;
    const auto status = sc_auth_pair_secret_seal_v1(&input, &result);
    Wipe(&input);
    if (status == SC_OK) {
        std::copy(std::begin(result.sealed_secret), std::end(result.sealed_secret), output->begin());
    }
    Wipe(&result);
    return status;
}

ScStatus OpenPairSecret(const Sealed48& sealed, const Secret32& key,
                        const AeadNonce12& nonce, Secret32* output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    ScAuthOpenRequestV1 input{};
    ScopedObjectWipe<ScAuthOpenRequestV1> input_wipe(&input);
    input.struct_size = sizeof(input);
    input.api_version = SC_API_VERSION_V1;
    std::copy(sealed.begin(), sealed.end(), input.sealed_secret);
    std::copy(key.begin(), key.end(), input.pair_key);
    std::copy(nonce.begin(), nonce.end(), input.nonce);
    ScAuthPairSecretV1 result{};
    ScopedObjectWipe<ScAuthPairSecretV1> result_wipe(&result);
    result.struct_size = sizeof(result);
    result.api_version = SC_API_VERSION_V1;
    const auto status = sc_auth_pair_secret_open_v1(&input, &result);
    Wipe(&input);
    if (status == SC_OK) {
        std::copy(std::begin(result.pair_secret), std::end(result.pair_secret), output->begin());
    }
    Wipe(&result);
    return status;
}

}  // namespace superconnect::android_auth
