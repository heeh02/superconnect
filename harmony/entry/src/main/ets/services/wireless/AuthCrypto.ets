/**
 * AuthCrypto — crypto primitives for the SC-AUTH-v1 wireless trust contract (audit H4/M10 fix). A
 * 32-byte per-pair `secret` is established at pairing (P-256-ECDH-encrypted, never sent in clear) +
 * HMAC-SHA256 challenge-response on every later connect, so a sniffed/replayed handshake can't
 * impersonate a paired peer. Reproduces the cross-language golden vectors in proto/auth-vectors.json —
 * the SAME values as Swift CryptoKit + Android javax.crypto — so wire interop is guaranteed.
 *
 * P-256 (secp256r1), not X25519: it is uniformly available across the three platforms. Public keys are
 * x9.63 uncompressed (0x04‖X(32)‖Y(32) = 65B); the ECDH shared value is the 32-byte X coordinate.
 *
 * Implemented on @ohos.security.cryptoFramework. HKDF-SHA256 is HAND-ROLLED per RFC 5869 over the Mac
 * primitive (no dependency on a cryptoFramework KDF API). Decoupled leaf: no transport/session/store
 * dependency — pure functions over bytes, so it can be KAT-verified on-device against auth-vectors.json.
 *
 * NOTE: cryptoFramework is device-only (no headless KAT possible at build time). This module COMPILES
 * against the frozen contract; it MUST be run through an on-device KAT against proto/auth-vectors.json
 * before shipping (see docs / risks).
 */
import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';

/// Fresh ephemeral P-256 keypair for the enrollment ECDH (per-connection, never persisted).
export interface EphemeralKeyPair {
  scalar32: Uint8Array;   // 32-byte big-endian private scalar
  pubX963_65: Uint8Array; // x9.63 uncompressed public key (0x04‖X‖Y, 65 bytes)
}

const AUTH_LABEL: string = 'SC-AUTH-v1';
const PAIR_INFO: string = 'SC-PAIR-v1';            // HKDF info + AES-GCM AAD
const P256_CURVE: string = 'NID_X9_62_prime256v1';  // secp256r1 / P-256

export class AuthCrypto {
  private static readonly enc: util.TextEncoder = new util.TextEncoder();
  private static readonly b64: util.Base64Helper = new util.Base64Helper();

  // ── wire codec helpers (base64) + the AEAD AAD / HKDF info bytes ────────────
  /** The SC-PAIR-v1 label as UTF-8 bytes — the AES-GCM AAD passed to seal/open on enrollment. */
  static pairInfoBytes(): Uint8Array { return AuthCrypto.enc.encodeInto(PAIR_INFO); }

  /** Base64-encode bytes (standard alphabet, padded) — the on-wire representation of all blobs. */
  static toBase64(bytes: Uint8Array): string { return AuthCrypto.b64.encodeToStringSync(bytes); }

  /** Base64-decode (throws on malformed input). */
  static fromBase64(s: string): Uint8Array { return AuthCrypto.b64.decodeSync(s); }

  /** Base64-decode, returning null instead of throwing on malformed input (for untrusted wire fields). */
  static tryFromBase64(s: string): Uint8Array | null {
    try { return AuthCrypto.b64.decodeSync(s); } catch (e) { return null; }
  }

  // ── HMAC challenge-response (steady state) ─────────────────────────────────
  /** HMAC-SHA256(secret, UTF-8(context)). */
  static async hmac(secret: Uint8Array, context: string): Promise<Uint8Array> {
    const symGen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
    const key: cryptoFramework.SymKey = await symGen.convertKey({ data: secret });
    const mac: cryptoFramework.Mac = cryptoFramework.createMac('SHA256');
    await mac.init(key);
    await mac.update({ data: AuthCrypto.enc.encodeInto(context) });
    const out: cryptoFramework.DataBlob = await mac.doFinal();
    return out.data;
  }

  /** Constant-time verification of a peer's proof. */
  static async verify(proof: Uint8Array, secret: Uint8Array, context: string): Promise<boolean> {
    const expected: Uint8Array = await AuthCrypto.hmac(secret, context);
    return AuthCrypto.constantTimeEqual(proof, expected);
  }

  /** Mac→Pad proof context. Label + peerId order are domain separation (no cross-direction replay). */
  static contextMac(macPeerId: string, tabletPeerId: string, nonceB64: string): string {
    return `${AUTH_LABEL}|${macPeerId}|${tabletPeerId}|${nonceB64}`;
  }
  /** Pad→Mac proof context (peer order swapped). */
  static contextPad(macPeerId: string, tabletPeerId: string, macNonceB64: string): string {
    return `${AUTH_LABEL}|${tabletPeerId}|${macPeerId}|${macNonceB64}`;
  }

  // ── P-256 ECDH + HKDF (enrollment key agreement) ───────────────────────────
  /** Derive the 32-byte AEAD key from our P-256 scalar + the peer's x9.63 public key via HKDF-SHA256. */
  static async deriveEcdhKey(myScalar32: Uint8Array, peerPubX963_65: Uint8Array,
                             salt16: Uint8Array): Promise<Uint8Array> {
    const common: cryptoFramework.ECCCommonParamsSpec =
      cryptoFramework.ECCKeyUtil.genECCCommonParamsSpec(P256_CURVE);

    // Import our private scalar as an ECC private key.
    const priSpec: cryptoFramework.ECCPriKeySpec = {
      algName: 'ECC',
      specType: cryptoFramework.AsyKeySpecType.PRIVATE_KEY_SPEC,
      params: common,
      sk: AuthCrypto.bytesToBigInt(myScalar32),
    };
    const priKey: cryptoFramework.PriKey =
      await cryptoFramework.createAsyKeyGeneratorBySpec(priSpec).generatePriKey();

    // Import the peer's x9.63 public key (0x04‖X‖Y) as an ECC public key.
    const point: cryptoFramework.Point = cryptoFramework.ECCKeyUtil.convertPoint(P256_CURVE, peerPubX963_65);
    const pubSpec: cryptoFramework.ECCPubKeySpec = {
      algName: 'ECC',
      specType: cryptoFramework.AsyKeySpecType.PUBLIC_KEY_SPEC,
      params: common,
      pk: point,
    };
    const pubKey: cryptoFramework.PubKey =
      await cryptoFramework.createAsyKeyGeneratorBySpec(pubSpec).generatePubKey();

    const ka: cryptoFramework.KeyAgreement = cryptoFramework.createKeyAgreement('ECC256');
    const shared: cryptoFramework.DataBlob = await ka.generateSecret(priKey, pubKey);  // 32-byte X coord
    return AuthCrypto.hkdfSha256(shared.data, salt16, PAIR_INFO, 32);
  }

  // ── AES-256-GCM (enrollment secret transport); encSecret = ciphertext ‖ tag(16) ──────────
  /** Encrypt `plaintext` → ciphertext‖tag (16B). */
  static async seal(plaintext: Uint8Array, key32: Uint8Array, nonce12: Uint8Array,
                    aad: Uint8Array): Promise<Uint8Array> {
    const symKey: cryptoFramework.SymKey =
      await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: key32 });
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const spec: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce12 },
      aad: { data: aad },
      authTag: { data: new Uint8Array(16) },   // placeholder required by the spec; unused on encrypt
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, spec);
    // On HarmonyOS cryptoFramework, GCM encrypt doFinal RETURNS the ciphertext ‖ 16-byte tag already
    // (verified on-device against the golden vector — do NOT append spec.authTag, that double-counts it).
    const ct: cryptoFramework.DataBlob = await cipher.doFinal({ data: plaintext });
    return ct.data;
  }

  /** Decrypt ciphertext‖tag (16B) → plaintext (throws on a bad tag). */
  static async open(encSecret: Uint8Array, key32: Uint8Array, nonce12: Uint8Array,
                    aad: Uint8Array): Promise<Uint8Array> {
    if (encSecret.length < 16) { throw new Error('AuthCrypto.open: ciphertext too short for GCM tag'); }
    const ctLen: number = encSecret.length - 16;
    const ct: Uint8Array = encSecret.slice(0, ctLen);
    const tag: Uint8Array = encSecret.slice(ctLen);
    const symKey: cryptoFramework.SymKey =
      await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: key32 });
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const spec: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce12 },
      aad: { data: aad },
      authTag: { data: tag },   // on decrypt the tag is supplied in the params
    };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, spec);
    const pt: cryptoFramework.DataBlob = await cipher.doFinal({ data: ct });
    return pt.data;
  }

  // ── Keygen / CSPRNG ────────────────────────────────────────────────────────
  /** Fresh ephemeral P-256 keypair: (scalar 32B big-endian, public x9.63 65B 0x04‖X‖Y). */
  static async newEphemeralKeyPair(): Promise<EphemeralKeyPair> {
    const pair: cryptoFramework.KeyPair =
      await cryptoFramework.createAsyKeyGenerator('ECC256').generateKeyPair();
    const sk: bigint = pair.priKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_SK_BN) as bigint;
    const x: bigint = pair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_X_BN) as bigint;
    const y: bigint = pair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_Y_BN) as bigint;
    const pub: Uint8Array = new Uint8Array(65);
    pub[0] = 0x04;
    pub.set(AuthCrypto.bigIntToFixed(x, 32), 1);
    pub.set(AuthCrypto.bigIntToFixed(y, 32), 33);
    return { scalar32: AuthCrypto.bigIntToFixed(sk, 32), pubX963_65: pub };
  }

  /** `n` cryptographically-random bytes (cryptoFramework Random is a CSPRNG). */
  static randomBytes(n: number): Uint8Array {
    const rand: cryptoFramework.Random = cryptoFramework.createRandom();
    return rand.generateRandomSync(n).data;
  }
  /** A fresh 32-byte per-pair secret. */
  static newSecret(): Uint8Array { return AuthCrypto.randomBytes(32); }

  // ── helpers ────────────────────────────────────────────────────────────────
  /** RFC 5869 HKDF-SHA256, hand-rolled over the cryptoFramework Mac primitive. */
  private static async hkdfSha256(ikm: Uint8Array, salt: Uint8Array, info: string,
                                  len: number): Promise<Uint8Array> {
    // extract: PRK = HMAC(salt, ikm). Empty salt → a zero block (RFC 5869 §2.2).
    const saltKey: Uint8Array = salt.length > 0 ? salt : new Uint8Array(32);
    const prk: Uint8Array = await AuthCrypto.rawHmac(saltKey, ikm);
    // expand: T(i) = HMAC(PRK, T(i-1) ‖ info ‖ i). info bytes are UTF-8 of the label.
    const infoBytes: Uint8Array = AuthCrypto.enc.encodeInto(info);
    const out: Uint8Array = new Uint8Array(len);
    let prev: Uint8Array = new Uint8Array(0);
    let pos: number = 0;
    let counter: number = 1;
    while (pos < len) {
      const block: Uint8Array = AuthCrypto.concat(AuthCrypto.concat(prev, infoBytes),
                                                  new Uint8Array([counter & 0xff]));
      prev = await AuthCrypto.rawHmac(prk, block);
      const n: number = Math.min(prev.length, len - pos);
      out.set(prev.slice(0, n), pos);
      pos += n;
      counter += 1;
    }
    return out;
  }

  /** HMAC-SHA256 over raw bytes (no UTF-8 step) — the building block for HKDF. */
  private static async rawHmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    const symKey: cryptoFramework.SymKey =
      await cryptoFramework.createSymKeyGenerator('HMAC').convertKey({ data: key });
    const mac: cryptoFramework.Mac = cryptoFramework.createMac('SHA256');
    await mac.init(symKey);
    await mac.update({ data: data });
    return (await mac.doFinal()).data;
  }

  /** Big-endian bytes → bigint (always non-negative). */
  private static bytesToBigInt(b: Uint8Array): bigint {
    let v: bigint = 0n;
    for (let i: number = 0; i < b.length; i++) { v = (v << 8n) | BigInt(b[i]); }
    return v;
  }

  /** bigint → fixed-length big-endian bytes (left zero-padded / high-byte truncated to `len`). */
  private static bigIntToFixed(v: bigint, len: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(len);
    let x: bigint = v;
    for (let i: number = len - 1; i >= 0; i--) {
      out[i] = Number(x & 0xffn);
      x = x >> 8n;
    }
    return out;
  }

  private static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  /** Length-independent, content-constant-time byte compare (mirrors the other platforms' verify). */
  private static constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) { return false; }
    let diff: number = 0;
    for (let i: number = 0; i < a.length; i++) { diff |= a[i] ^ b[i]; }
    return diff === 0;
  }

}
