/**
 * PairingStore — persisted allow-list of Mac peerIds the user has approved for WIRELESS connections
 * (TOFU "trust on first use"). The Mac sends a stable per-install peerId + deviceName in its hello
 * (v2 handshake); on the first LAN connection from an unknown peer the user taps 允许, and that peer
 * is remembered here so future connects are silent. Wired (hdc/USB) clients never reach this — they
 * connect from localhost and are auto-trusted. Part of the isolated services/wireless/ module.
 */
import preferences from '@ohos.data.preferences';
import hilog from '@ohos.hilog';
import { common } from '@kit.AbilityKit';

export interface TrustedPeer {
  peerId: string;
  name: string;
}

const STORE: string = 'sc_pairing';
const KEY: string = 'trustedPeers';

export class PairingStore {
  private prefs: preferences.Preferences | null = null;
  private trusted: TrustedPeer[] = [];

  constructor(ctx: common.UIAbilityContext) {
    try {
      this.prefs = preferences.getPreferencesSync(ctx, { name: STORE });
      const json: string = this.prefs.getSync(KEY, '[]') as string;
      this.trusted = JSON.parse(json) as TrustedPeer[];
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'pairing load failed %{public}s', JSON.stringify(e));
      this.trusted = [];
    }
  }

  isTrusted(peerId: string): boolean {
    return peerId !== '' && this.trusted.some((p: TrustedPeer): boolean => p.peerId === peerId);
  }

  trust(peerId: string, name: string): void {
    if (peerId === '' || this.isTrusted(peerId)) { return; }
    this.trusted.push({ peerId: peerId, name: name });
    this.persist();
  }

  forget(peerId: string): void {
    this.trusted = this.trusted.filter((p: TrustedPeer): boolean => p.peerId !== peerId);
    this.persist();
  }

  list(): TrustedPeer[] { return this.trusted.slice(); }

  private persist(): void {
    if (this.prefs === null) { return; }
    try {
      this.prefs.putSync(KEY, JSON.stringify(this.trusted));
      this.prefs.flush().then((): void => {}).catch((e: Object): void => {
        hilog.warn(0x0, 'SCDIAG', 'pairing flush failed %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'pairing save failed %{public}s', JSON.stringify(e));
    }
  }
}
