# SC-AUTH-v1 — Frozen Interface Contract (H4/M10 wireless trust)

The single source of truth all three platforms implement against. **Frozen** — do not change a field
name, byte order, label, or message shape without regenerating `proto/auth-vectors.json` and updating
all platforms together. Crypto golden vectors: `proto/auth-vectors.json` (independent python reference).

## 1. Crypto primitives (per `auth-vectors.json`)

- **HMAC** = HMAC-SHA256(secret, **UTF-8 bytes of** context-string). `proof` is base64.
- **ECDH** = **NIST P-256** (secp256r1). Private key = 32-byte big-endian scalar. Public key = x9.63
  **uncompressed** `0x04 ‖ X(32) ‖ Y(32)` = 65 bytes, base64 on the wire. Shared = 32-byte X coord.
- **KDF** = HKDF-SHA256(ikm = ECDH shared, salt = 16 random bytes, info = UTF-8 `"SC-PAIR-v1"`, L = 32).
- **AEAD** = AES-256-GCM, key = HKDF output, 12-byte nonce, AAD = UTF-8 `"SC-PAIR-v1"`,
  `encSecret` = ciphertext ‖ 16-byte tag (48 bytes for a 32-byte secret), base64.
- **secret** = 32 random bytes, the long-lived per-pair credential. Never on the wire in clear.

### `AuthCrypto` module interface (identical across platforms; Mac+Android done & KAT-verified)
```
hmac(secret: bytes, context: string) -> bytes
verify(proof: bytes, secret: bytes, context: string) -> bool        // constant-time
contextMac(macPeerId, tabletPeerId, nonceB64) -> "SC-AUTH-v1|{macPeerId}|{tabletPeerId}|{nonceB64}"
contextPad(macPeerId, tabletPeerId, macNonceB64) -> "SC-AUTH-v1|{tabletPeerId}|{macPeerId}|{macNonceB64}"
deriveEcdhKey(myScalar32: bytes, peerPubX963_65: bytes, salt16: bytes) -> key32   // P-256 ECDH + HKDF
seal(plaintext, key32, nonce12, aad) -> bytes      // AES-256-GCM, returns ct‖tag
open(encSecret, key32, nonce12, aad) -> bytes
newEphemeralKeyPair() -> (scalar32, pubX963_65)    // P-256
randomBytes(n) -> bytes ; newSecret() -> bytes32   // CSPRNG
```

### `SecretStore` module interface (per-pair secret persistence, secure store)
```
secret(for peerId: string) -> bytes?      // nil = not enrolled → caller must (re)pair
store(secret: bytes, for peerId: string)  // upsert, secure store
remove(for peerId: string)
```
Mac = Keychain (done). Harmony = `@ohos.security.asset` (Tag.SECRET). Android = Jetpack Security
`EncryptedSharedPreferences` (AES-256-GCM, master key in AndroidKeyStore).

## 2. Handshake wire (additive JSON in the existing CONTROL channel — FrameCodec UNCHANGED)

New negotiation field `authVersion: 1` distinguishes upgraded peers. All fields are additive JSON keys;
a peer **MUST fail closed** if its counterpart lacks `authVersion` (refuse, never fall back to peerId
trust). Wired hdc/USB (127.0.0.1) stays pairing-exempt (physically authenticated).

**Steady state (both sides hold `secret`):**
```
Mac → hello      { type:"hello", role:"mac", protocolVersion:2, authVersion:1, peerId, deviceName, caps }
Pad → hello_ack  { type:"hello_ack", role:"pad", protocolVersion:2, authVersion:1, peerId,
                   nonce:<b64 32B challenge>, needsPairing:false, caps }      // slot NOT claimed yet
Mac → auth       { type:"auth", proof:<b64 HMAC(secret, contextMac)>, macNonce:<b64 32B> }
Pad : verify proof; if OK → auth_ack + CLAIM SLOT + start video; else → error{auth_failed}, close
Pad → auth_ack   { type:"auth_ack", proof:<b64 HMAC(secret, contextPad)> }    // mutual auth
Mac : verify proof; if bad → fatal auth_failed
```

**Enrollment (unknown peer / no secret):**
```
Mac → hello      { …, ephPub:<b64 P-256 x963 65B> }                       // Mac has no secret for this tablet
Pad → hello_ack  { …, nonce, ephPub:<b64 65B>, needsPairing:true }        // raises 允许/拒绝; slot NOT claimed
       user taps 允许
Pad → pair_secret{ type:"pair_secret", encSecret:<b64 AEAD(ecdhKey, secret)>, salt:<b64 16B>, aeadNonce:<b64 12B> }
       (both derive ecdhKey = deriveEcdhKey(myScalar, peerEphPub, salt))
Mac : open encSecret → secret; persist (SecretStore) keyed by tabletPeerId
Mac → auth       { proof=HMAC(secret, contextMac), macNonce }             // proves it got the right secret
Pad : verify; persist secret keyed by macPeerId; auth_ack; CLAIM SLOT
       user taps 拒绝 → error{pairing_rejected} (existing path); no pair_secret sent
```

**Errors (existing `error` message, new reasons):** `auth_failed` (proof invalid → Mac fatal, no retry,
mirror pairing_rejected), `auth_required` (peer sent no authVersion / no secret & not enrolling → refuse).

**Migration:** forced re-pair — old plaintext-peerId "trusted" entries are display-history only; the first
post-upgrade connect from each takes the enrollment path (one 允许 tap). No silent grace.

## 3. Per-platform state-machine notes (the handshake is authored centrally, not in parallel)

- Slot/`onAuthenticated` (tablet) fires AFTER `auth` proof verifies, not at `hello_ack` (stronger anti-DoS).
- All HMAC compares constant-time. Nonces fresh per connection from a CSPRNG (no nonce DB needed).
- BLE token (M10): demoted to a non-authenticating discovery hint — it MUST NOT auto-trust anymore.
- Android wireless default flips ON → OFF (matches HarmonyOS privacy default).
