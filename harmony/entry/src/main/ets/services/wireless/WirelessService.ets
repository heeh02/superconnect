/**
 * WirelessService — the ISOLATED owner of the tablet's Wi‑Fi LAN mode (v0.2.1).
 *
 * Decoupled from the wired (hdc/USB) path so a wireless bug can never touch the proven pipeline:
 *  - OFF (default): the receiver binds 127.0.0.1 → reachable ONLY through `hdc fport` over USB,
 *    no LAN exposure at all.
 *  - ON: the receiver binds 0.0.0.0 → reachable over Wi‑Fi too (and, Inc4, advertised via mDNS).
 *
 * It persists the on/off choice across launches and exposes the tablet's current Wi‑Fi IPv4 so the
 * user can connect manually (the mDNS-blocked-network fallback). Everything wireless lives under
 * services/wireless/. The wired path knows nothing about this file.
 */
import preferences from '@ohos.data.preferences';
import wifiManager from '@ohos.wifiManager';
import hilog from '@ohos.hilog';
import { common } from '@kit.AbilityKit';

const STORE: string = 'sc_wireless';
const KEY_ENABLED: string = 'enabled';

export class WirelessService {
  private prefs: preferences.Preferences | null = null;
  // Privacy default: OFF — no LAN exposure until the user explicitly opts in.
  private enabledFlag: boolean = false;
  // Wired into the receiver by AppEnvironment: rebinds the listen socket to the new address.
  private restartFn: () => void = (): void => {};

  constructor(ctx: common.UIAbilityContext) {
    try {
      this.prefs = preferences.getPreferencesSync(ctx, { name: STORE });
      this.enabledFlag = this.prefs.getSync(KEY_ENABLED, false) as boolean;
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'wireless prefs load failed %{public}s', JSON.stringify(e));
    }
  }

  /** AppEnvironment supplies the rebind action (receiver.restart) so toggling takes effect live. */
  setRestart(fn: () => void): void { this.restartFn = fn; }

  enabled(): boolean { return this.enabledFlag; }

  /** Where the receiver listens: 0.0.0.0 (LAN + localhost) when ON, else 127.0.0.1 (USB only). */
  bindAddress(): string { return this.enabledFlag ? '0.0.0.0' : '127.0.0.1'; }

  setEnabled(v: boolean): void {
    if (v === this.enabledFlag) { return; }
    this.enabledFlag = v;
    if (this.prefs !== null) {
      try {
        this.prefs.putSync(KEY_ENABLED, v);
        this.prefs.flush().then((): void => {}).catch((e: Object): void => {
          hilog.warn(0x0, 'SCDIAG', 'wireless prefs flush failed %{public}s', JSON.stringify(e));
        });
      } catch (e) {
        hilog.warn(0x0, 'SCDIAG', 'wireless prefs save failed %{public}s', JSON.stringify(e));
      }
    }
    this.restartFn();   // rebind the listener to the new address
  }

  /** The tablet's current Wi‑Fi IPv4 (dotted), or '' if not on Wi‑Fi. Shown for manual connect. */
  wifiIpv4(): string {
    try {
      if (!wifiManager.isWifiActive()) { return ''; }
      const ip: number = wifiManager.getIpInfo().ipAddress;
      if (ip === 0) { return ''; }
      hilog.info(0x0, 'SCDIAG', 'wifi ipAddress raw=%{public}d', ip);
      // HarmonyOS returns the IPv4 as a host-order int (little-endian, like Android WifiInfo) —
      // low byte first. (Logged raw above so byte order is verifiable on-device.)
      return `${ip & 0xff}.${(ip >> 8) & 0xff}.${(ip >> 16) & 0xff}.${(ip >> 24) & 0xff}`;
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'wifiIpv4 failed %{public}s', JSON.stringify(e));
      return '';
    }
  }
}
