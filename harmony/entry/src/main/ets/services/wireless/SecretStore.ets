/**
 * SecretStore — secure persistence of the 32-byte per-pair `secret` established at pairing (SC-AUTH-v1).
 * Keyed by peerId; the secret is the long-lived credential proven via HMAC on every later connect, so it
 * must live in hardware-backed secure storage, never in plain preferences. Backed by @ohos.security.asset
 * (the asset is encrypted by the system; we never see the key). Accessibility = WHEN_DEVICE_FIRST_UNLOCKED
 * so a connection can authenticate after a reboot once the user has unlocked once. Mirrors the Mac Keychain
 * store + the Android EncryptedSharedPreferences store. Decoupled leaf: no transport/session dependency.
 *
 * NOTE: @ohos.security.asset is device-only; this module COMPILES against the frozen contract but needs an
 * on-device round-trip check (store → query → remove) before shipping (see risks).
 */
import asset from '@ohos.security.asset';
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';

export class SecretStore {
  private static readonly enc: util.TextEncoder = new util.TextEncoder();

  /** The stored secret for `peerId`, or null when not enrolled (caller must (re)pair). */
  static async secret(peerId: string): Promise<Uint8Array | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SecretStore.enc.encodeInto(peerId));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);   // include the SECRET bytes in the result
    try {
      const res: Array<asset.AssetMap> = await asset.query(query);
      if (res.length === 0) { return null; }
      const v: asset.Value | undefined = res[0].get(asset.Tag.SECRET);
      return (v instanceof Uint8Array) ? v : null;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === asset.ErrorCode.NOT_FOUND) { return null; }   // expected for an un-enrolled peer
      hilog.warn(0x0, 'SCDIAG', 'secret query failed %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /** Upsert the secret for `peerId` into secure storage. */
  static async store(secret: Uint8Array, peerId: string): Promise<void> {
    const alias: Uint8Array = SecretStore.enc.encodeInto(peerId);
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.SECRET, secret);
    attrs.set(asset.Tag.ALIAS, alias);
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attrs);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === asset.ErrorCode.DUPLICATED) {
        // Upsert semantics: replace the existing entry (asset.add refuses a duplicate alias).
        await SecretStore.remove(peerId);
        await asset.add(attrs);
        return;
      }
      hilog.warn(0x0, 'SCDIAG', 'secret store failed %{public}s', JSON.stringify(e));
      throw e as Error;
    }
  }

  /** Forget the secret for `peerId` (it must re-pair next time). Safe when not present. */
  static async remove(peerId: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SecretStore.enc.encodeInto(peerId));
    try {
      await asset.remove(query);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === asset.ErrorCode.NOT_FOUND) { return; }   // already gone — fine
      hilog.warn(0x0, 'SCDIAG', 'secret remove failed %{public}s', JSON.stringify(e));
    }
  }
}
