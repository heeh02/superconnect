/**
 * CONTROL-channel session for the tablet (server) side.
 * Phase 0: replies hello_ack to hello, pong to ping. Mirrors mac Session.swift.
 * Phase 1+ : VIDEO frames will be routed to the decoder; INPUT frames produced
 * by the capture layer will be sent through `send`.
 */
import util from '@ohos.util';
import { display } from '@kit.ArkUI';
import { Callback } from '@ohos.base';
import hilog from '@ohos.hilog';
import sc from 'libsuperconnect.so';
import { Channel, Frame, FrameDecoder, encodeFrame } from '../protocol/FrameCodec';
import { deviceDisplayName, stablePeerId } from '../services/DeviceIdentity';
import { AuthCrypto, EphemeralKeyPair } from '../services/wireless/AuthCrypto';

/**
 * SC-AUTH-v1 trust decision the Session asks the gate for on `hello` (audit H4). The crypto/secret
 * minting stays in the Session (it owns the wire); the gate owns POLICY only: exempt wired/loopback,
 * refuse (wireless off / anonymous / session-denied / prompt busy), steady (a secret already exists),
 * or enroll (raise the 允许/拒绝 prompt and, on 允许, mint+persist a fresh per-pair secret).
 */
export enum AuthVerdict { Exempt, Refuse, Steady, Enroll }

export interface AuthDecision {
  verdict: AuthVerdict;
  // Enroll only: resolves to the user's 允许(true)/拒绝(false). On true the gate has already minted +
  // stored the secret keyed by macPeerId, so the Session can read it back via secretFor().
  approve?: Promise<boolean>;
}

/**
 * The wireless trust gate the Session drives for SC-AUTH-v1. Implemented by WirelessService; null on
 * the wired path (then every client is Exempt). Pure policy + secret persistence — no wire/crypto here.
 */
export interface AuthGate {
  decide(macPeerId: string, deviceName: string, isLocalhost: boolean, ownerId: number, token: string): Promise<AuthDecision>;
  secretFor(macPeerId: string): Promise<Uint8Array | null>;
}

export type SendFn = (bytes: Uint8Array) => void;
export type LogFn = (msg: string) => void;

interface HdrCaps {
  hlg: boolean;
  pq: boolean;
}

interface HelloAckCaps {
  codecs: string[];
  pen: boolean;
  screenWidth: number;   // native pixels
  screenHeight: number;  // native pixels
  scale: number;
  refreshRate: number;   // panel refresh (Hz)
  hdr?: HdrCaps;         // present only when decoder + display both support HDR
}

interface ControlMsg {
  type: string;
  seq?: number;
  t0?: number;
  t1?: number;
  role?: string;
  protocolVersion?: number;
  width?: number;
  height?: number;
  codec?: string;
  hdr?: string;          // video_config: "off" | "hlg" | "pq"
  caps?: HelloAckCaps;
  // v2 handshake (all additive; a v1 peer omits these): identity + role negotiation.
  peerId?: string;
  platform?: string;
  deviceName?: string;
  supportedRoles?: string[];
  acceptedRole?: string;
  desiredRole?: string;
  appVersion?: string;
  message?: string;      // error: human/machine-readable reason (e.g. "pairing_rejected")
  reason?: string;       // SC-AUTH-v1 machine-readable error reason (auth_required/auth_failed/…)
  pairingToken?: string; // BLE-delivered token (Mac→Pad in hello); discovery hint only — does NOT grant trust (audit M10)
  // SC-AUTH-v1 (audit H4) — challenge-response over the CONTROL channel (FrameCodec UNCHANGED):
  authVersion?: number;  // hello: present ⇒ upgraded Mac; absent ⇒ fail closed. hello_ack: we echo 1.
  ephPub?: string;       // hello: Mac's ephemeral P-256 pubkey (b64). hello_ack: tablet's (enrollment only).
  nonce?: string;        // hello_ack: our 32-byte challenge (b64). Absent ⇒ wired/loopback exemption.
  needsPairing?: boolean;// hello_ack: true ⇒ enrollment (no stored secret yet), Mac awaits pair_secret.
  encSecret?: string;    // pair_secret: AEAD-sealed per-pair secret (b64).
  salt?: string;         // pair_secret: 16-byte HKDF salt (b64).
  aeadNonce?: string;    // pair_secret: 12-byte AES-GCM nonce (b64).
  proof?: string;        // auth / auth_ack: HMAC(secret, context) (b64).
  macNonce?: string;     // auth: the Mac's 32-byte challenge to us (b64), for our auth_ack proof.
}

// The tablet's stable per-install peer id lives in DeviceIdentity (persisted via @ohos.data.preferences,
// loaded once at startup) so it survives relaunches — the reliable cross-transport key for v1
// multi-device conflict reconciliation. See docs/CONFLICTS.md.

export class Session {
  private decoder: FrameDecoder = new FrameDecoder();
  private send: SendFn;
  private log: LogFn;
  private textEncoder: util.TextEncoder = new util.TextEncoder();
  private textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private peerId: string = '';   // v2 handshake: the connected Mac's peer id ('' if v1 peer)
  // Set by TcpServerTransport from the client's remote address: true for hdc/USB (always 127.0.0.1),
  // false for a LAN client. The wireless pairing gate (Inc3) exempts localhost; LAN needs approval.
  private clientLocalhost: boolean = false;
  private clientInfoResolved: boolean = false;
  private clientInfoWaiters: (() => void)[] = [];
  // Transport-assigned connection id (clientId) — the cancel owner for this session's pairing prompt.
  private ownerId: number = 0;
  // SC-AUTH-v1 wireless trust gate (set by the transport when wireless is on). Owns POLICY + secret
  // persistence; the Session owns the wire + crypto. Null ⇒ no gate (wired) ⇒ every client Exempt.
  private authGate: AuthGate | null = null;

  // ── SC-AUTH-v1 per-connection handshake state (audit H4) ──
  private deviceName: string = 'Mac';      // the Mac's friendly name from hello (for the prompt)
  private macEphPub: Uint8Array | null = null;  // the Mac's ephemeral P-256 pubkey (enrollment ECDH)
  private nonce: Uint8Array | null = null;      // OUR fresh 32-byte challenge for this connection
  private nonceB64: string = '';               // …base64 (the value the Mac signs in contextMac)
  private tabletEph: EphemeralKeyPair | null = null;  // our ephemeral keypair (enrollment only)
  private authenticated: boolean = false;       // becomes true only after `auth` proof verifies

  /** Called by the transport once the client's remote address resolves (always, even on error). */
  setClientLocalhost(v: boolean): void {
    this.clientLocalhost = v;
    this.clientInfoResolved = true;
    const waiters: (() => void)[] = this.clientInfoWaiters;
    this.clientInfoWaiters = [];
    for (const w of waiters) { w(); }
  }

  /** The transport's per-connection clientId — used to cancel this session's pairing prompt. */
  setOwnerId(id: number): void { this.ownerId = id; }

  /** Install the SC-AUTH-v1 trust gate (the transport does this per connection when wireless is on). */
  setAuthGate(gate: AuthGate): void {
    this.authGate = gate;
  }

  /**
   * Fired AFTER the wireless `auth` proof verifies (or immediately for a wired/loopback-exempt client):
   * the point at which the link is trusted and the slot may be claimed / video armed. NOT fired at
   * hello_ack time — deferring it past proof verification is the SC-AUTH-v1 anti-DoS rule (§3): an
   * unauthenticated wireless peer never gets the session marked Connected. The transport wires this to
   * its ServerStatus.Connected emission. (A wired peer authenticates synchronously, so behavior there
   * is byte-identical to before.)
   */
  onAuthenticated: (() => void) | null = null;

  /** Resolve once the client's localhost-vs-LAN tag is known, so the gate sees an accurate value. */
  private awaitClientInfo(): Promise<void> {
    if (this.clientInfoResolved) { return Promise.resolve(); }
    return new Promise<void>((resolve: () => void): void => { this.clientInfoWaiters.push(resolve); });
  }

  /** VIDEO-channel payloads (Annex-B H.264 access units) + keyframe flag. */
  onVideo: ((payload: Uint8Array, isKeyframe: boolean) => void) | null = null;

  /** Negotiated encoded video resolution + codec + HDR mode (Mac→Pad video_config). */
  onVideoConfig: ((width: number, height: number, codec: string, hdr: string) => void) | null = null;

  // Rotation / resolution re-negotiation: watch the panel and tell the Mac when its
  // dimensions change so it rebuilds the virtual display to match (#58).
  private lastCapsW: number = 0;
  private lastCapsH: number = 0;
  private capsTimer: number = -1;
  private readonly onDisplayChange: Callback<number> = (_id: number): void => {
    hilog.info(0x0, 'SCDIAG', 'display change event');
    // A rotation fires a burst of 'change' events — debounce, then send only if dims changed.
    if (this.capsTimer >= 0) { clearTimeout(this.capsTimer); }
    this.capsTimer = setTimeout((): void => {
      this.capsTimer = -1;
      const caps: HelloAckCaps = this.localCaps();
      if (caps.screenWidth !== this.lastCapsW || caps.screenHeight !== this.lastCapsH) {
        this.lastCapsW = caps.screenWidth;
        this.lastCapsH = caps.screenHeight;
        this.sendControl({ type: 'caps_update', caps: caps });
        hilog.info(0x0, 'SCDIAG', 'caps_update SENT %{public}dx%{public}d', caps.screenWidth, caps.screenHeight);
      } else {
        hilog.info(0x0, 'SCDIAG', 'caps unchanged %{public}dx%{public}d (no send)', caps.screenWidth, caps.screenHeight);
      }
    }, 400);
  };

  constructor(send: SendFn, log: LogFn) {
    this.send = send;
    this.log = log;
    try { display.on('change', this.onDisplayChange); } catch (e) { this.log('display.on failed ' + JSON.stringify(e)); }
  }

  /** Remove the rotation listener — call on disconnect so the subscription doesn't dangle. */
  dispose(): void {
    if (this.capsTimer >= 0) { clearTimeout(this.capsTimer); this.capsTimer = -1; }
    try { display.off('change', this.onDisplayChange); } catch (e) { /* best-effort */ }
  }

  /** Feed raw bytes from the socket. */
  onBytes(data: Uint8Array): void {
    let frames: Frame[] = [];
    try {
      frames = this.decoder.push(data);
    } catch (e) {
      this.log('decode error: ' + JSON.stringify(e));
      return;
    }
    for (const f of frames) {
      if (f.channel === Channel.CONTROL) {
        this.handleControl(f.payload);
      } else if (f.channel === Channel.VIDEO) {
        // VIDEO pre-auth gate (defense-in-depth): drop video before the `auth` proof verifies. The
        // wired/loopback path sets authenticated via the Exempt claim, so wired is unaffected.
        if (!this.authenticated) { this.log('drop VIDEO frame pre-auth'); continue; }
        const isKeyframe: boolean = (f.flags & 0x01) !== 0;
        if (this.onVideo !== null) {
          this.onVideo(f.payload, isKeyframe);
        }
      } else {
        this.log('ignoring channel ' + f.channel + ' (Phase 0)');
      }
    }
  }

  private sendControl(obj: ControlMsg): void {
    const json: string = JSON.stringify(obj);
    const payload: Uint8Array = this.textEncoder.encodeInto(json);
    this.send(encodeFrame(Channel.CONTROL, 0, payload));
  }

  private handleControl(payload: Uint8Array): void {
    let str: string = '';
    try {
      str = this.textDecoder.decodeToString(payload);
    } catch (e) {
      this.log('utf8 decode error: ' + JSON.stringify(e));
      return;
    }
    let msg: ControlMsg;
    try {
      msg = JSON.parse(str) as ControlMsg;
    } catch (e) {
      this.log('json parse error: ' + str);
      return;
    }

    switch (msg.type) {
      case 'hello':
        // Async: the wireless pairing gate may await the user's 允许/拒绝 before we hello_ack.
        // Fire-and-forget with a catch so a rejection can't surface as an unhandled promise.
        this.onHello(msg).catch((e: Object): void => { this.log('onHello error ' + JSON.stringify(e)); });
        break;
      case 'ping':
        // Echo seq + original t0, add our own clock t1 (milliseconds).
        this.sendControl({
          type: 'pong',
          seq: msg.seq,
          t0: msg.t0,
          t1: Date.now(),
        });
        break;
      case 'bye':
        this.log('peer said bye');
        break;
      case 'auth':
        // SC-AUTH-v1 step: the Mac proved possession of the per-pair secret. Verify, then (and only
        // then) claim the slot. Fire-and-forget with a catch — crypto is async.
        this.onAuth(msg).catch((e: Object): void => { this.log('onAuth error ' + JSON.stringify(e)); });
        break;
      case 'video_config':
        // Defense-in-depth: ignore video_config before the link is authenticated (wired sets
        // authenticated via the loopback Exempt claim, so wired is unaffected).
        if (!this.authenticated) { this.log('ignore video_config pre-auth'); break; }
        if (msg.width !== undefined && msg.height !== undefined && this.onVideoConfig !== null) {
          const codec: string = msg.codec ?? 'h264';
          const hdr: string = msg.hdr ?? 'off';
          this.log('video_config ' + msg.width + '×' + msg.height + ' ' + codec + ' hdr=' + hdr);
          this.onVideoConfig(msg.width, msg.height, codec, hdr);
        }
        break;
      default:
        this.log('unhandled control type: ' + msg.type);
    }
  }

  /**
   * Handle a `hello` (SC-AUTH-v1 server side, audit H4 — mirror of mac Session.swift sendHello):
   *
   *  - LOOPBACK / wired (the existing 127.0.0.1 exemption) → reply hello_ack WITHOUT a nonce and claim
   *    the slot now (onAuthenticated). Byte-compatible with the pre-auth wired handshake.
   *  - authVersion ABSENT (un-upgraded Mac) → FAIL CLOSED: error{auth_required}, no hello_ack. Never
   *    fall back to spoofable peerId trust.
   *  - WIRELESS, upgraded: mint a fresh 32-byte nonce, then ask the gate:
   *      • Steady (secret exists) → hello_ack{ authVersion:1, nonce, needsPairing:false }; slot NOT
   *        claimed yet — we wait for `auth`.
   *      • Enroll (no secret) → mint a tablet ephemeral keypair, raise the 允许/拒绝 prompt, and on 允许
   *        send hello_ack{ authVersion:1, nonce, ephPub:<tablet pub>, needsPairing:true } followed by
   *        pair_secret. On 拒绝 → error{pairing_rejected}, close. Slot NOT claimed (waits for `auth`).
   *      • Refuse (wireless off / anonymous / session-denied / prompt busy) → error{auth_required}.
   *
   * The slot/onAuthenticated is deferred to AFTER `auth` verifies for every wireless client (anti-DoS).
   */
  private async onHello(msg: ControlMsg): Promise<void> {
    this.log('received hello from ' + (msg.role ?? 'peer') + ' v' + (msg.protocolVersion ?? 1)
             + ' auth=' + (msg.authVersion ?? 0));
    this.peerId = msg.peerId ?? '';   // v2 peer identity ('' for a v1 peer)
    this.deviceName = msg.deviceName ?? 'Mac';
    if (msg.ephPub !== undefined) {
      try { this.macEphPub = AuthCrypto.fromBase64(msg.ephPub); } catch (e) { this.macEphPub = null; }
    }

    // No gate installed (wired path / tests) → behave exactly as before: ack + (slot at hello_ack).
    if (this.authGate === null) {
      this.sendHelloAck(null, false, null);
      this.markAuthenticated('no-gate (wired)');
      return;
    }

    await this.awaitClientInfo();   // ensure localhost-vs-LAN is known before deciding

    // FAIL CLOSED BEFORE SIDE EFFECTS (audit): a NON-loopback peer that omits authVersion is an
    // un-upgraded/spoofing Mac — reject it BEFORE decide() so no prompt/timer/onPairingRequest is ever
    // raised (a dangling 允许 prompt would otherwise be a DoS). Loopback stays exempt via decide() below.
    if (!this.clientLocalhost && msg.authVersion === undefined) {
      this.log('hello REFUSED (no authVersion, non-loopback) for peer ' + this.peerId);
      this.sendControl({ type: 'error', reason: 'auth_required' });
      return;   // no hello_ack, no decide() → no prompt
    }

    let decision: AuthDecision;
    try {
      decision = await this.authGate.decide(this.peerId, this.deviceName, this.clientLocalhost, this.ownerId, msg.pairingToken ?? '');
    } catch (e) {
      this.log('auth gate error ' + JSON.stringify(e));
      this.sendControl({ type: 'error', reason: 'auth_required' });
      return;
    }

    // EXEMPT: wired/loopback (the existing 127.0.0.1 exemption). No nonce, no needsPairing; claim now.
    if (decision.verdict === AuthVerdict.Exempt) {
      this.sendHelloAck(null, false, null);
      this.markAuthenticated('wired/loopback exempt');
      return;
    }

    // REFUSE: wireless off, anonymous peer, session-denied, or a prompt already in flight. ALSO the
    // un-upgraded-Mac case (no authVersion) → fail closed, never fall back to spoofable peerId trust.
    // Both map to error{auth_required} (the Mac treats it as fatal — no retry storm).
    if (decision.verdict === AuthVerdict.Refuse || msg.authVersion === undefined) {
      this.log('hello REFUSED for peer ' + this.peerId + ' (authVersion=' + (msg.authVersion ?? 0) + ')');
      this.sendControl({ type: 'error', reason: 'auth_required' });
      return;   // no hello_ack
    }

    // Fresh per-connection challenge (CSPRNG) for both STEADY and ENROLL.
    this.nonce = AuthCrypto.randomBytes(32);
    this.nonceB64 = AuthCrypto.toBase64(this.nonce);

    if (decision.verdict === AuthVerdict.Steady) {
      // We already hold a secret for this Mac → challenge it; wait for `auth`. Slot NOT claimed.
      this.sendHelloAck(this.nonceB64, false, null);
      this.log('steady challenge sent (awaiting auth)');
      return;
    }

    // ENROLL: no stored secret. Mint a tablet ephemeral keypair + wait for the user's 允许/拒绝
    // (the gate raised the prompt and minted+stored the secret on 允许). Then ack + pair_secret.
    try {
      this.tabletEph = await AuthCrypto.newEphemeralKeyPair();
    } catch (e) {
      this.log('enroll keygen failed ' + JSON.stringify(e));
      this.sendControl({ type: 'error', reason: 'auth_required' });
      return;
    }
    let allowed: boolean = false;
    try {
      allowed = decision.approve !== undefined ? await decision.approve : false;
    } catch (e) {
      this.log('enroll prompt error ' + JSON.stringify(e));
      allowed = false;
    }
    if (!allowed) {
      this.log('enrollment REJECTED for peer ' + this.peerId);
      this.sendControl({ type: 'error', reason: 'pairing_rejected' });
      return;   // no hello_ack, no pair_secret
    }

    // The gate has now minted + stored the secret keyed by this Mac's peerId. Read it back and ship it
    // to the Mac (ECDH-sealed). hello_ack carries our ephemeral pubkey + needsPairing:true.
    const secret: Uint8Array | null = await this.authGate.secretFor(this.peerId);
    if (secret === null || this.macEphPub === null || this.tabletEph === null) {
      this.log('enrollment missing secret/ephPub after approve');
      this.sendControl({ type: 'error', reason: 'auth_required' });
      return;
    }
    this.sendHelloAck(this.nonceB64, true, this.tabletEph.pubX963_65);
    try {
      const salt: Uint8Array = AuthCrypto.randomBytes(16);
      const aeadNonce: Uint8Array = AuthCrypto.randomBytes(12);
      const key: Uint8Array = await AuthCrypto.deriveEcdhKey(this.tabletEph.scalar32, this.macEphPub, salt);
      const enc: Uint8Array = await AuthCrypto.seal(secret, key, aeadNonce, AuthCrypto.pairInfoBytes());
      this.sendControl({
        type: 'pair_secret',
        encSecret: AuthCrypto.toBase64(enc),
        salt: AuthCrypto.toBase64(salt),
        aeadNonce: AuthCrypto.toBase64(aeadNonce),
      });
      this.log('enrollment: pair_secret sent (awaiting auth)');
    } catch (e) {
      this.log('enrollment seal failed ' + JSON.stringify(e));
      this.sendControl({ type: 'error', reason: 'auth_required' });
    }
  }

  /**
   * SC-AUTH-v1 `auth` handler: verify HMAC(secret, contextMac(macPeerId, tabletPeerId, OUR nonceB64))
   * (constant-time, via AuthCrypto.verify). On success → auth_ack{ proof:HMAC(secret, contextPad(…,
   * macNonce)) } THEN claim the slot (onAuthenticated). On failure → error{auth_failed}, claim nothing,
   * persist nothing. The secret MUST already exist by now (steady: pre-existing; enroll: just stored).
   */
  private async onAuth(msg: ControlMsg): Promise<void> {
    // DUPLICATE-AUTH GUARD: drop a replayed `auth` frame before any HMAC work (we're already trusted).
    if (this.authenticated) { this.log('auth after authenticated — ignored (replay)'); return; }
    if (this.authGate === null) { this.log('auth without gate — failing closed'); this.sendControl({ type: 'error', reason: 'auth_failed' }); return; }
    if (this.nonce === null) { this.log('auth before challenge — failing closed'); this.sendControl({ type: 'error', reason: 'auth_failed' }); return; }
    const proof: Uint8Array | null = (msg.proof !== undefined) ? AuthCrypto.tryFromBase64(msg.proof) : null;
    const macNonceB64: string | undefined = msg.macNonce;
    if (proof === null || macNonceB64 === undefined) {
      this.sendControl({ type: 'error', reason: 'auth_failed' });
      return;
    }
    const secret: Uint8Array | null = await this.authGate.secretFor(this.peerId);
    if (secret === null) {
      this.log('auth: no stored secret for ' + this.peerId);
      this.sendControl({ type: 'error', reason: 'auth_failed' });
      return;
    }
    const tabletPeerId: string = stablePeerId();
    const ctxMac: string = AuthCrypto.contextMac(this.peerId, tabletPeerId, this.nonceB64);
    let ok: boolean = false;
    try {
      ok = await AuthCrypto.verify(proof, secret, ctxMac);
    } catch (e) {
      this.log('auth verify error ' + JSON.stringify(e));
      ok = false;
    }
    if (!ok) {
      this.log('auth FAILED for peer ' + this.peerId);
      this.sendControl({ type: 'error', reason: 'auth_failed' });
      return;
    }
    // Mutual proof: prove WE also hold the secret over contextPad with the Mac's macNonce.
    try {
      const ctxPad: string = AuthCrypto.contextPad(this.peerId, tabletPeerId, macNonceB64);
      const ackProof: Uint8Array = await AuthCrypto.hmac(secret, ctxPad);
      this.sendControl({ type: 'auth_ack', proof: AuthCrypto.toBase64(ackProof) });
    } catch (e) {
      this.log('auth_ack hmac failed ' + JSON.stringify(e));
      this.sendControl({ type: 'error', reason: 'auth_failed' });
      return;
    }
    this.markAuthenticated('wireless auth verified');
  }

  /** Fire onAuthenticated exactly once — the slot-claim / Connected point (post-auth, anti-DoS §3). */
  private markAuthenticated(why: string): void {
    if (this.authenticated) { return; }
    this.authenticated = true;
    this.log('authenticated (' + why + ') → claiming slot');
    if (this.onAuthenticated !== null) { this.onAuthenticated(); }
  }

  /** Emit hello_ack. `nonceB64` null ⇒ wired exemption (no challenge). `tabletEphPub` set ⇒ enrollment. */
  private sendHelloAck(nonceB64: string | null, needsPairing: boolean, tabletEphPub: Uint8Array | null): void {
    const caps: HelloAckCaps = this.localCaps();
    this.lastCapsW = caps.screenWidth;   // baseline so the first 'change' isn't a spurious re-negotiation
    this.lastCapsH = caps.screenHeight;
    const ack: ControlMsg = {
      type: 'hello_ack',
      role: 'pad',
      protocolVersion: 2,
      // v2 (all additive — a v1 Mac ignores these): identity + the role this side accepts.
      peerId: stablePeerId(),
      platform: 'harmonyos',
      deviceName: deviceDisplayName(),
      supportedRoles: ['receiver'],
      acceptedRole: 'receiver',
      caps: caps,
      // Always advertise SC-AUTH-v1 capability — even on the EXEMPT (wired/loopback) path that carries no
      // nonce. Absence of authVersion means "genuinely pre-H4 tablet", NOT "H4 tablet that exempted you";
      // conflating the two made the Mac reject the exempt hello_ack as "needs update". The nonce's
      // presence (below) is what signals a challenge; authVersion just states we speak the protocol.
      authVersion: 1,
    };
    if (nonceB64 !== null) {
      ack.nonce = nonceB64;
      ack.needsPairing = needsPairing;
      if (tabletEphPub !== null) { ack.ephPub = AuthCrypto.toBase64(tabletEphPub); }
    }
    this.sendControl(ack);
  }

  /** Advertise this tablet's panel (resolution, refresh) + HW-decodable codecs
   *  so the Mac adapts its output — the adaptation interface for any tablet. */
  private localCaps(): HelloAckCaps {
    let sw: number = 2560;
    let sh: number = 1600;
    let scale: number = 2;
    let refresh: number = 60;
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      // Derive the VISUAL (oriented) dims from long/short edge + orientation, so rotation is
      // detected even on panels where display.width/height don't swap on rotate.
      const longEdge: number = Math.max(d.width, d.height);
      const shortEdge: number = Math.min(d.width, d.height);
      const portrait: boolean =
        d.orientation === display.Orientation.PORTRAIT || d.orientation === display.Orientation.PORTRAIT_INVERTED;
      sw = portrait ? shortEdge : longEdge;
      sh = portrait ? longEdge : shortEdge;
      scale = Math.max(1, Math.round(d.densityPixels));   // integer backing scale (not the raw density)
      refresh = d.refreshRate;
      hilog.info(0x0, 'SCDIAG', 'localCaps raw=%{public}dx%{public}d orient=%{public}d -> visual=%{public}dx%{public}d',
                 d.width, d.height, d.orientation, sw, sh);
    } catch (e) {
      this.log('display query failed: ' + JSON.stringify(e));
    }
    let codecs: string[] = ['h264'];
    try {
      if (sc.supportsHevc()) {
        codecs = ['hevc', 'h264'];
      }
    } catch (e) {
      this.log('hevc capability check failed: ' + JSON.stringify(e));
    }
    // HDR: advertise only if the HW HEVC decoder does Main10 (bit0). The panel is HDR10;
    // a non-HDR display would tone-map gracefully. We signal PQ (HDR10) — the Mac forces
    // PQ because ScreenCaptureKit can't reliably tag HLG from a virtual display.
    let hdr: HdrCaps | undefined = undefined;
    try {
      if (codecs.includes('hevc') && (sc.hdrDecodeCaps() & 1) !== 0) {
        hdr = { hlg: false, pq: true };
      }
    } catch (e) {
      this.log('hdr capability check failed: ' + JSON.stringify(e));
    }
    return {
      codecs: codecs, pen: true,
      screenWidth: sw, screenHeight: sh, scale: scale, refreshRate: refresh,
      hdr: hdr,
    };
  }
}
