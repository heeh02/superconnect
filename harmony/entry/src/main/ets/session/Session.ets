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
}

// Stable peer id for the v2 handshake. Per-process for now; TODO: persist across launches via
// @ohos.data.preferences so it's truly per-install (the trust/routing key for v1 multi-device).
let MODULE_PEER_ID: string = '';
function localPeerId(): string {
  if (MODULE_PEER_ID.length === 0) { MODULE_PEER_ID = util.generateRandomUUID(true); }
  return MODULE_PEER_ID;
}

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
  // Wireless TOFU gate (set by the transport when wireless is on). Given (peerId, deviceName,
  // isLocalhost, ownerId), resolves true to allow the handshake. Null ⇒ no gate (wired) ⇒ always allow.
  private pairingGate: ((peerId: string, deviceName: string, isLocalhost: boolean, ownerId: number) => Promise<boolean>) | null = null;

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

  /** Install the wireless pairing gate (the transport does this per connection when wireless is on). */
  setPairingGate(fn: (peerId: string, deviceName: string, isLocalhost: boolean, ownerId: number) => Promise<boolean>): void {
    this.pairingGate = fn;
  }

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
      case 'video_config':
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
   * Handle a hello: run the wireless pairing gate (if installed), then reply hello_ack. The gate
   * exempts localhost (hdc/USB) and already-trusted peers; an unknown LAN peer waits for the user's
   * 允许. On rejection we send an error and send NO hello_ack, so the Mac surfaces a clear failure.
   */
  private async onHello(msg: ControlMsg): Promise<void> {
    this.log('received hello from ' + (msg.role ?? 'peer') + ' v' + (msg.protocolVersion ?? 1));
    this.peerId = msg.peerId ?? '';   // v2 peer identity ('' for a v1 peer)
    const deviceName: string = msg.deviceName ?? 'Mac';

    if (this.pairingGate !== null) {
      await this.awaitClientInfo();   // ensure localhost-vs-LAN is known before deciding
      let allowed: boolean = false;
      try {
        allowed = await this.pairingGate(this.peerId, deviceName, this.clientLocalhost, this.ownerId);
      } catch (e) {
        this.log('pairing gate error ' + JSON.stringify(e));
        allowed = false;
      }
      if (!allowed) {
        this.log('pairing REJECTED for peer ' + this.peerId);
        this.sendControl({ type: 'error', message: 'pairing_rejected' });
        return;   // no hello_ack
      }
    }

    const caps: HelloAckCaps = this.localCaps();
    this.lastCapsW = caps.screenWidth;   // baseline so the first 'change' isn't a spurious re-negotiation
    this.lastCapsH = caps.screenHeight;
    this.sendControl({
      type: 'hello_ack',
      role: 'pad',
      protocolVersion: 2,
      // v2 (all additive — a v1 Mac ignores these): identity + the role this side accepts.
      peerId: localPeerId(),
      platform: 'harmonyos',
      deviceName: 'HarmonyOS Tablet',
      supportedRoles: ['receiver'],
      acceptedRole: 'receiver',
      caps: caps,
    });
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
