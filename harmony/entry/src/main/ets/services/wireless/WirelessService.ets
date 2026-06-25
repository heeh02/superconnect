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
import util from '@ohos.util';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { PermissionRequestResult } from '@ohos.abilityAccessCtrl';
import { common } from '@kit.AbilityKit';
import { PairingStore, TrustedPeer } from './PairingStore';
import { MdnsAdvertiser } from './MdnsAdvertiser';
import { BleAdvertiser } from './BleAdvertiser';
import { deviceDisplayName, stablePeerId } from '../DeviceIdentity';
import { AuthCrypto } from './AuthCrypto';
import { SecretStore } from './SecretStore';
import { AuthGate, AuthDecision, AuthVerdict } from '../../session/Session';

const STORE: string = 'sc_wireless';
const KEY_ENABLED: string = 'enabled';
const KEY_PEERID: string = 'blePeerId';
const PAIR_TIMEOUT_MS: number = 60000;   // auto-reject an unanswered pairing prompt after 60s

export class WirelessService implements AuthGate {
  private prefs: preferences.Preferences | null = null;
  // Privacy default: OFF — no LAN exposure until the user explicitly opts in.
  private enabledFlag: boolean = false;
  // Wired into the receiver by AppEnvironment: rebinds the listen socket to the new address.
  private restartFn: () => void = (): void => {};

  // ── TOFU pairing ──
  private pairing: PairingStore;
  // mDNS advertiser — publishes _superconnect._tcp once the socket is listening on the LAN.
  private advertiser: MdnsAdvertiser;
  // BLE advertiser — cross-subnet bootstrap (carries deviceName/ip/port/token over GATT).
  private bleAdvertiser: BleAdvertiser;
  private ctx: common.UIAbilityContext;
  private btGranted: boolean = false;
  // Pairing token carried over BLE; a discovery hint only — it does NOT grant trust (audit M10).
  // Rotated each time wireless is enabled.
  private bleToken: string = '';
  // Stable per-install tablet id, embedded in the BLE blob so the Mac can dedupe/identify this tablet.
  private blePeerId: string = '';
  // Peers the user explicitly rejected THIS app run — silently refused (no re-prompt) until restart
  // or until wireless is re-enabled.
  private sessionDenied: string[] = [];
  // At most one pairing prompt is in flight; its resolver gates the awaiting handshake.
  private pendingResolve: ((allow: boolean) => void) | null = null;
  private pendingPeerId: string = '';
  private pendingDeviceName: string = '';
  private pendingTimer: number = -1;
  // Identity of the in-flight prompt. ownerId = the transport-assigned clientId (NOT the spoofable
  // peerId) — only the owning connection may cancel its prompt. promptId = a monotonic id stamped
  // per prompt — the user's 允许/拒绝 must carry it, so a tap can never settle a different prompt that
  // replaced this one (no cancel-then-reprompt tap hijack).
  private pendingOwnerId: number = 0;
  private pendingPromptId: number = 0;
  private promptSeq: number = 0;
  // UI hooks (the page shows/hides the 允许/拒绝 dialog). promptId binds the dialog to its prompt.
  onPairingRequest: ((peerId: string, deviceName: string, promptId: number) => void) | null = null;
  onPairingDismiss: (() => void) | null = null;
  // The port the receiver actually bound (may differ from 8888 if it was occupied). Fired on each
  // (re)listen so the UI can show the real ip:port. 0 until the first listen succeeds.
  private listenPort: number = 0;
  onPortChange: ((port: number) => void) | null = null;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
    this.pairing = new PairingStore(ctx);
    this.advertiser = new MdnsAdvertiser(ctx);
    this.bleAdvertiser = new BleAdvertiser();
    try {
      this.prefs = preferences.getPreferencesSync(ctx, { name: STORE });
      this.enabledFlag = this.prefs.getSync(KEY_ENABLED, false) as boolean;
      this.blePeerId = this.prefs.getSync(KEY_PEERID, '') as string;
      if (this.blePeerId.length === 0) {
        this.blePeerId = util.generateRandomUUID(true);
        this.prefs.putSync(KEY_PEERID, this.blePeerId);
        this.prefs.flush().then((): void => {}).catch((e: Object): void => {});
      }
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'wireless prefs load failed %{public}s', JSON.stringify(e));
    }
    if (this.blePeerId.length === 0) { this.blePeerId = util.generateRandomUUID(true); }
    if (this.enabledFlag) { this.bleToken = this.gen16Hex(); }   // mint for a persisted-ON start
  }

  /** AppEnvironment supplies the rebind action (receiver.restart) so toggling takes effect live. */
  setRestart(fn: () => void): void { this.restartFn = fn; }

  enabled(): boolean { return this.enabledFlag; }

  /** Where the receiver listens: 0.0.0.0 (LAN + localhost) when ON, else 127.0.0.1 (USB only). */
  bindAddress(): string { return this.enabledFlag ? '0.0.0.0' : '127.0.0.1'; }

  /**
   * Called by the receiver once the socket is listening. Records the actual bound port (for the UI),
   * and advertises over mDNS — with the real device name + actual port — only when bound to the LAN
   * (0.0.0.0); on 127.0.0.1 (wireless off / USB only) ensure no advertisement is live.
   */
  onListening(address: string, port: number): void {
    this.listenPort = port;
    if (this.onPortChange !== null) { this.onPortChange(port); }
    if (this.enabledFlag && address !== '127.0.0.1') {
      this.advertiser.advertise(deviceDisplayName(), port, stablePeerId());
      this.startBle();
    } else {
      this.advertiser.unadvertise();
      this.bleAdvertiser.stop();
    }
  }

  /** Request BLE permission (once) then advertise the bootstrap payload. mDNS works regardless. */
  private startBle(): void {
    if (this.btGranted) { this.bleAdvertiser.advertise(this.blePayload()); return; }
    try {
      const atm: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      atm.requestPermissionsFromUser(this.ctx, ['ohos.permission.ACCESS_BLUETOOTH'])
        .then((res: PermissionRequestResult): void => {
          const ok: boolean = res.authResults.length > 0 && res.authResults[0] === 0;
          this.btGranted = ok;
          if (ok && this.enabledFlag) {
            this.bleAdvertiser.advertise(this.blePayload());
          } else {
            hilog.warn(0x0, 'SCDIAG', 'BLE permission not granted (mDNS/manual still work)');
          }
        })
        .catch((e: Object): void => { hilog.warn(0x0, 'SCDIAG', 'BLE perm request failed %{public}s', JSON.stringify(e)); });
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'BLE perm manager failed %{public}s', JSON.stringify(e));
    }
  }

  /** The 22-byte BLE advertisement payload: ipv4(4) + port(2, big-endian) + token(8) + peerKey(8). The
   *  Mac reads this straight from the scan (no GATT connect). Token is 16 hex chars → 8 bytes. peerKey is
   *  the first 8 bytes of the stable peerId UUID — the SAME identity the mDNS TXT `pid` carries, so the
   *  Mac can collapse this BLE card and the mDNS card (different LAN IP / different name) into one tablet.
   *  Total 22B + 2B mfr-id header = 24B → fits the 31B BLE advert (flags 3 + 1+1+2+22 = 29). */
  private blePayload(): Uint8Array {
    const buf: Uint8Array = new Uint8Array(22);
    const parts: string[] = this.wifiIpv4().split('.');
    for (let i = 0; i < 4; i++) {
      buf[i] = parts.length === 4 ? (parseInt(parts[i], 10) & 0xff) : 0;
    }
    buf[4] = (this.listenPort >> 8) & 0xff;   // port big-endian
    buf[5] = this.listenPort & 0xff;
    for (let i = 0; i < 8; i++) {              // token: 16 hex chars → 8 bytes
      buf[6 + i] = parseInt(this.bleToken.substring(i * 2, i * 2 + 2), 16) & 0xff;
    }
    const pidHex: string = stablePeerId().split('-').join('');   // 32 hex chars; first 16 = first 8 bytes
    for (let i = 0; i < 8; i++) {
      buf[14 + i] = parseInt(pidHex.substring(i * 2, i * 2 + 2), 16) & 0xff;
    }
    return buf;
  }

  /** A 16-hex-char (8-byte) token for the BLE advert. DEMOTED (audit M10): a discovery hint only — it
   *  no longer grants trust in decide(), so it's never matched against an incoming hello. */
  private gen16Hex(): string {
    return util.generateRandomUUID(false).split('-').join('').substring(0, 16);
  }

  /** The actual bound listen port (0 until the first listen succeeds). Shown in the UI. */
  currentPort(): number { return this.listenPort; }

  setEnabled(v: boolean): void {
    if (v === this.enabledFlag) { return; }
    this.enabledFlag = v;
    if (v) {
      this.sessionDenied = [];                          // re-enabling → fresh prompt for denied peers
      this.bleToken = this.gen16Hex();    // rotate the proximity token per enable
    }
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
      // HarmonyOS returns the IPv4 as a BIG-endian host-order int (raw 0x0A0845B9 = 10.8.69.185),
      // MSB first. (Verified on-device against ifconfig; an earlier little-endian guess reversed it.)
      return `${(ip >> 24) & 0xff}.${(ip >> 16) & 0xff}.${(ip >> 8) & 0xff}.${ip & 0xff}`;
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'wifiIpv4 failed %{public}s', JSON.stringify(e));
      return '';
    }
  }

  // ── Pairing gate ──────────────────────────────────────────────────────────────────────────────

  /**
   * SC-AUTH-v1 trust gate (audit H4) — the decision the Session asks for on `hello`. Returns POLICY
   * only; the crypto + nonce live in the Session. Verdicts:
   *  - Exempt : localhost (hdc/USB) → wired stays auth-free (byte-compatible).
   *  - Steady : a per-pair secret already exists for this Mac → challenge it (no prompt).
   *  - Enroll : no secret → raise the 允许/拒绝 prompt; `approve` resolves to the user's choice, and on
   *             允许 we MINT + STORE a fresh 32-byte secret keyed by this Mac's peerId (settlePending),
   *             so the Session can read it back and seal it into pair_secret.
   *  - Refuse : wireless off, anonymous peer, already session-denied, or a prompt is already in flight.
   *
   * The BLE token is DEMOTED (audit M10): it no longer auto-trusts. A matching token is at most a
   * discovery hint — every unknown wireless peer still requires an explicit 允许 to enroll a secret.
   */
  async decide(peerId: string, deviceName: string, isLocalhost: boolean, ownerId: number, token: string): Promise<AuthDecision> {
    if (isLocalhost) { return { verdict: AuthVerdict.Exempt }; }            // hdc/USB → wired exemption
    if (!this.enabledFlag) { return { verdict: AuthVerdict.Refuse }; }      // wireless off → refuse LAN
    if (peerId === '') { return { verdict: AuthVerdict.Refuse }; }          // can't authenticate an anonymous peer
    // Already enrolled (we hold the secret) → steady-state challenge, no prompt. NOTE: trust now lives
    // in the SecretStore (per-pair secret), not the legacy plaintext-peerId PairingStore allow-list.
    const existing: Uint8Array | null = await SecretStore.secret(peerId);
    if (existing !== null) { return { verdict: AuthVerdict.Steady }; }
    if (this.sessionDenied.indexOf(peerId) >= 0) { return { verdict: AuthVerdict.Refuse }; }
    // REFUSE (do NOT supersede) a second unknown peer while a prompt is in flight: superseding would
    // silently re-target the visible dialog to the newcomer and let it ride the user's tap (a hijack,
    // since deviceName is attacker-controlled). The refused peer is NOT denied — it may retry once the
    // current prompt is answered or its connection is cancelled (cancelPairing on disconnect).
    if (this.pendingResolve !== null) { return { verdict: AuthVerdict.Refuse }; }
    const approve: Promise<boolean> = new Promise<boolean>((resolve: (allow: boolean) => void): void => {
      this.pendingResolve = resolve;
      this.pendingPeerId = peerId;
      this.pendingDeviceName = deviceName;
      this.pendingOwnerId = ownerId;
      this.pendingPromptId = ++this.promptSeq;
      const promptId: number = this.pendingPromptId;
      this.pendingTimer = setTimeout((): void => { this.settlePending(false, false); }, PAIR_TIMEOUT_MS);
      if (this.onPairingRequest !== null) { this.onPairingRequest(peerId, deviceName, promptId); }
    });
    return { verdict: AuthVerdict.Enroll, approve: approve };
  }

  /** The stored per-pair secret for this Mac (null = not enrolled). Read by the Session in steady/auth. */
  secretFor(peerId: string): Promise<Uint8Array | null> { return SecretStore.secret(peerId); }

  /**
   * The user tapped 允许 (true) or 拒绝 (false). `promptId` is the id the dialog was shown with — a
   * stale tap (its prompt already settled/replaced) is IGNORED, so a tap can never approve a different
   * peer that took the slot after the dialog was dismissed/re-shown.
   */
  respondPairing(promptId: number, allow: boolean): void {
    if (this.pendingResolve !== null && promptId === this.pendingPromptId) {
      this.settlePending(allow, !allow);
    }
  }

  /**
   * The owning connection (by transport-assigned clientId — NOT the spoofable peerId) closed/gave up.
   * Only that exact connection can clear its prompt, so a different peer can't cancel a legit prompt.
   * Frees the slot immediately (dialog dismissed) instead of waiting out the 60s timeout.
   */
  cancelPairing(ownerId: number): void {
    if (this.pendingResolve !== null && ownerId === this.pendingOwnerId) {
      this.settlePending(false, false);
    }
  }

  /** App teardown: drop any pending prompt + stop advertising (avoid a lingering mDNS/BLE service). */
  dispose(): void {
    this.settlePending(false, false);
    this.advertiser.unadvertise();
    this.bleAdvertiser.stop();
  }

  /**
   * Resolve the in-flight prompt. On 允许 (allow) we MINT a fresh 32-byte per-pair secret and persist
   * it (SecretStore, hardware-backed) keyed by this Mac's peerId BEFORE resolving the approve promise —
   * so by the time the Session reads it back via secretFor() the store write has committed (no race).
   * The legacy PairingStore allow-list is also updated so the trusted-peer UI still shows the device
   * (display history); the AUTHORITATIVE trust is the secret. On 拒绝 (deny) → session-deny, no secret.
   * On cancel/timeout (neither) → just clear the prompt.
   */
  private settlePending(allow: boolean, deny: boolean): void {
    if (this.pendingTimer >= 0) { clearTimeout(this.pendingTimer); this.pendingTimer = -1; }
    const resolve: ((allow: boolean) => void) | null = this.pendingResolve;
    const peerId: string = this.pendingPeerId;
    const name: string = this.pendingDeviceName;
    this.pendingResolve = null;
    this.pendingOwnerId = 0;
    this.pendingPromptId = 0;
    this.pendingPeerId = '';
    this.pendingDeviceName = '';
    if (resolve === null) { return; }
    if (deny && peerId !== '') { this.sessionDenied.push(peerId); }
    if (this.onPairingDismiss !== null) { this.onPairingDismiss(); }
    if (allow && peerId !== '') {
      // Mint + persist the secret, THEN resolve(true). If the store fails, resolve(false) so the
      // Session fails closed (sends auth_required) rather than enrolling a peer with no stored secret.
      const secret: Uint8Array = AuthCrypto.newSecret();
      SecretStore.store(secret, peerId)
        .then((): void => {
          this.pairing.trust(peerId, name);   // display-history only; secret is the authoritative trust
          resolve(true);
        })
        .catch((e: Object): void => {
          hilog.warn(0x0, 'SCDIAG', 'secret store failed on approve %{public}s', JSON.stringify(e));
          resolve(false);
        });
      return;
    }
    resolve(allow);
  }

  // ── Trusted-peer management (UI) ──
  pairedPeers(): TrustedPeer[] { return this.pairing.list(); }
  /** Forget a peer: drop the display-history entry AND the authoritative per-pair secret (so it must
   *  re-enroll with a fresh 允许 next connect). Without the SecretStore.remove this would leave the
   *  peer silently auto-trusted (steady) despite the UI showing it gone. */
  forgetPeer(peerId: string): void {
    this.pairing.forget(peerId);
    SecretStore.remove(peerId).then((): void => {}).catch((e: Object): void => {
      hilog.warn(0x0, 'SCDIAG', 'secret remove failed %{public}s', JSON.stringify(e));
    });
  }
}
