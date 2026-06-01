/**
 * WirelessService — the ISOLATED owner of the tablet's Wi‑Fi LAN mode (v0.2.1).
 *
 * Decoupled from the wired (hdc/USB) path so a wireless bug can never touch the proven pipeline:
 *  - OFF (default): the receiver binds 127.0.0.1 → reachable ONLY through `hdc fport` over USB,
 *    no LAN exposure at all.
 *  - ON: the receiver binds 0.0.0.0 → reachable over Wi‑Fi too (and, Inc4, advertised via mDNS).
 *
 * It also owns the TOFU pairing GATE: a LAN client must be approved (once) by the user before the
 * handshake completes; localhost (hdc/USB) clients are auto-trusted. Persists the on/off choice and
 * the trusted-peer list, and exposes the tablet's Wi‑Fi IPv4 for manual connect. Everything wireless
 * lives under services/wireless/. The wired path knows nothing about this file.
 */
import preferences from '@ohos.data.preferences';
import wifiManager from '@ohos.wifiManager';
import hilog from '@ohos.hilog';
import { common } from '@kit.AbilityKit';
import { PairingStore, TrustedPeer } from './PairingStore';
import { MdnsAdvertiser } from './MdnsAdvertiser';

const STORE: string = 'sc_wireless';
const KEY_ENABLED: string = 'enabled';
const PAIR_TIMEOUT_MS: number = 60000;   // auto-reject an unanswered pairing prompt after 60s
const SERVICE_NAME: string = 'Superconnect Pad';   // mDNS service name (shown as the device on the Mac)

export class WirelessService {
  private prefs: preferences.Preferences | null = null;
  // Privacy default: OFF — no LAN exposure until the user explicitly opts in.
  private enabledFlag: boolean = false;
  // Wired into the receiver by AppEnvironment: rebinds the listen socket to the new address.
  private restartFn: () => void = (): void => {};

  // ── TOFU pairing ──
  private pairing: PairingStore;
  // mDNS advertiser — publishes _superconnect._tcp once the socket is listening on the LAN.
  private advertiser: MdnsAdvertiser;
  // Peers the user explicitly rejected THIS app run — silently refused (no re-prompt) until restart
  // or until wireless is re-enabled.
  private sessionDenied: string[] = [];
  // At most one pairing prompt is in flight; its resolver gates the awaiting handshake.
  private pendingResolve: ((allow: boolean) => void) | null = null;
  private pendingPeerId: string = '';
  private pendingDeviceName: string = '';
  private pendingTimer: number = -1;
  // UI hooks (the page shows/hides the 允许/拒绝 dialog).
  onPairingRequest: ((peerId: string, deviceName: string) => void) | null = null;
  onPairingDismiss: (() => void) | null = null;

  constructor(ctx: common.UIAbilityContext) {
    this.pairing = new PairingStore(ctx);
    this.advertiser = new MdnsAdvertiser(ctx);
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

  /**
   * Called by the receiver once the socket is listening. Advertise over mDNS only when bound to the
   * LAN (0.0.0.0); on 127.0.0.1 (wireless off / USB only) ensure no advertisement is live.
   */
  onListening(address: string, port: number): void {
    if (this.enabledFlag && address !== '127.0.0.1') {
      this.advertiser.advertise(SERVICE_NAME, port);
    } else {
      this.advertiser.unadvertise();
    }
  }

  setEnabled(v: boolean): void {
    if (v === this.enabledFlag) { return; }
    this.enabledFlag = v;
    if (v) { this.sessionDenied = []; }   // re-enabling → give previously-denied peers a fresh prompt
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

  // ── Pairing gate ──────────────────────────────────────────────────────────────────────────────

  /**
   * The gate the Session awaits before sending hello_ack. Localhost (hdc/USB) and already-trusted
   * peers pass instantly; an unknown LAN peer raises a 允许/拒绝 prompt and resolves on the user's tap.
   * Resolves false (reject) when wireless is off, the peer is anonymous, already denied this run, or
   * a prompt is unanswered for PAIR_TIMEOUT_MS.
   */
  evaluatePairing(peerId: string, deviceName: string, isLocalhost: boolean): Promise<boolean> {
    if (isLocalhost) { return Promise.resolve(true); }            // hdc/USB → always trusted
    if (!this.enabledFlag) { return Promise.resolve(false); }     // wireless off → refuse LAN
    if (peerId === '') { return Promise.resolve(false); }         // can't TOFU an anonymous peer
    if (this.pairing.isTrusted(peerId)) { return Promise.resolve(true); }
    if (this.sessionDenied.indexOf(peerId) >= 0) { return Promise.resolve(false); }
    // REFUSE (do NOT supersede) a second unknown peer while a prompt is in flight: superseding would
    // silently re-target the visible dialog to the newcomer and let it ride the user's tap (a hijack,
    // since deviceName is attacker-controlled). The refused peer is NOT denied — it may retry once the
    // current prompt is answered or its connection is cancelled (cancelPairing on disconnect).
    if (this.pendingResolve !== null) { return Promise.resolve(false); }
    return new Promise<boolean>((resolve: (allow: boolean) => void): void => {
      this.pendingResolve = resolve;
      this.pendingPeerId = peerId;
      this.pendingDeviceName = deviceName;
      this.pendingTimer = setTimeout((): void => { this.settlePending(false, false); }, PAIR_TIMEOUT_MS);
      if (this.onPairingRequest !== null) { this.onPairingRequest(peerId, deviceName); }
    });
  }

  /** The user tapped 允许 (true) or 拒绝 (false) in the pairing dialog. */
  respondPairing(allow: boolean): void { this.settlePending(allow, !allow); }

  /**
   * A connecting peer's session closed (or it gave up). If it owns the in-flight prompt, clear it
   * immediately (dialog dismissed + slot freed) instead of waiting out the 60s timeout — so a peer
   * that disconnected mid-prompt can't be trusted by a late tap, and the next peer isn't blocked.
   */
  cancelPairing(peerId: string): void {
    if (this.pendingResolve !== null && peerId !== '' && peerId === this.pendingPeerId) {
      this.settlePending(false, false);
    }
  }

  /** App teardown: drop any pending prompt + stop advertising (avoid a lingering mDNS service). */
  dispose(): void {
    this.settlePending(false, false);
    this.advertiser.unadvertise();
  }

  /** Resolve the in-flight prompt. allow ⇒ trust + remember; deny ⇒ session-deny (no re-prompt). */
  private settlePending(allow: boolean, deny: boolean): void {
    if (this.pendingTimer >= 0) { clearTimeout(this.pendingTimer); this.pendingTimer = -1; }
    const resolve: ((allow: boolean) => void) | null = this.pendingResolve;
    const peerId: string = this.pendingPeerId;
    const name: string = this.pendingDeviceName;
    this.pendingResolve = null;
    this.pendingPeerId = '';
    this.pendingDeviceName = '';
    if (resolve === null) { return; }
    if (allow && peerId !== '') { this.pairing.trust(peerId, name); }
    if (deny && peerId !== '') { this.sessionDenied.push(peerId); }
    if (this.onPairingDismiss !== null) { this.onPairingDismiss(); }
    resolve(allow);
  }

  // ── Trusted-peer management (UI) ──
  pairedPeers(): TrustedPeer[] { return this.pairing.list(); }
  forgetPeer(peerId: string): void { this.pairing.forget(peerId); }
}
