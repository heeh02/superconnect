#pragma once

#include "superconnect_auth_v1.h"

#include <array>
#include <cstdint>
#include <string_view>

namespace superconnect::android_auth {

using Secret32 = std::array<std::uint8_t, SC_AUTH_PAIR_SECRET_BYTES>;
using Nonce32 = std::array<std::uint8_t, SC_AUTH_NONCE_BYTES>;
using Private32 = std::array<std::uint8_t, SC_AUTH_P256_PRIVATE_BYTES>;
using Public65 = std::array<std::uint8_t, SC_AUTH_P256_PUBLIC_BYTES>;
using Salt16 = std::array<std::uint8_t, SC_AUTH_PAIRING_SALT_BYTES>;
using AeadNonce12 = std::array<std::uint8_t, SC_AUTH_AEAD_NONCE_BYTES>;
using Sealed48 = std::array<std::uint8_t, SC_AUTH_SEALED_SECRET_BYTES>;

ScStatus ValidatePeerId(std::string_view peer_id);
ScStatus CreateProof(const Secret32& secret, std::string_view prover, std::string_view verifier,
                     const Nonce32& nonce, Secret32* output);
ScStatus VerifyProof(const Secret32& proof, const Secret32& secret, std::string_view prover,
                     std::string_view verifier, const Nonce32& nonce);
ScStatus PublicFromPrivate(const Private32& scalar, Public65* output);
ScStatus DerivePairKey(const Private32& scalar, const Public65& peer_public,
                       const Salt16& salt, Secret32* output);
ScStatus SealPairSecret(const Secret32& secret, const Secret32& key,
                        const AeadNonce12& nonce, Sealed48* output);
ScStatus OpenPairSecret(const Sealed48& sealed, const Secret32& key,
                        const AeadNonce12& nonce, Secret32* output);

}  // namespace superconnect::android_auth
