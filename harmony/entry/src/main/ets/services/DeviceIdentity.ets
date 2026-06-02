/**
 * DeviceIdentity — the tablet's human-friendly name, shared by the wireless module (mDNS service
 * name) and the session handshake (hello_ack deviceName) so the Mac shows the real device, e.g.
 * "HUAWEI MatePad Pro", instead of a hardcoded label. No special permission needed for marketName.
 *
 * It also owns the STABLE per-install peer id — persisted (not per-process), so a relaunched tablet
 * keeps the same identity. That makes peerId a reliable cross-transport key the Mac uses to reconcile
 * the same physical tablet reached over two transports (wired + wireless); see docs/CONFLICTS.md.
 */
import deviceInfo from '@ohos.deviceInfo';
import preferences from '@ohos.data.preferences';
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import { common } from '@kit.AbilityKit';

const ID_STORE: string = 'sc_identity';
const KEY_PEER_ID: string = 'peerId';
let CACHED_PEER_ID: string = '';

export function deviceDisplayName(): string {
  try {
    const market: string = deviceInfo.marketName;
    if (market.length > 0) { return market; }
    const model: string = deviceInfo.productModel;
    if (model.length > 0) { return model; }
  } catch (e) {
    hilog.warn(0x0, 'SCDIAG', 'deviceDisplayName failed %{public}s', JSON.stringify(e));
  }
  return 'Superconnect Pad';
}

/**
 * Load-or-mint the stable per-install peer id, called ONCE at startup with a UIAbility context (the
 * only place a context is available). Persisting it via preferences means the id survives app
 * relaunches, so the Mac's Tier-2 conflict reconciliation keyed on this id stays correct across
 * restarts (a per-process id would re-mint every launch and look like a new peer).
 */
export function initStablePeerId(ctx: common.UIAbilityContext): void {
  try {
    const prefs: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: ID_STORE });
    let id: string = prefs.getSync(KEY_PEER_ID, '') as string;
    if (id.length === 0) {
      id = util.generateRandomUUID(true);
      prefs.putSync(KEY_PEER_ID, id);
      prefs.flush().then((): void => {}).catch((e: Object): void => {
        hilog.warn(0x0, 'SCDIAG', 'peerId flush failed %{public}s', JSON.stringify(e));
      });
    }
    CACHED_PEER_ID = id;
  } catch (e) {
    hilog.warn(0x0, 'SCDIAG', 'initStablePeerId failed %{public}s', JSON.stringify(e));
    if (CACHED_PEER_ID.length === 0) { CACHED_PEER_ID = util.generateRandomUUID(true); }
  }
}

/** The stable peer id (persisted via initStablePeerId). Falls back to a per-process id if init
 *  hasn't run yet — so the handshake always carries a non-empty id. */
export function stablePeerId(): string {
  if (CACHED_PEER_ID.length === 0) { CACHED_PEER_ID = util.generateRandomUUID(true); }
  return CACHED_PEER_ID;
}
