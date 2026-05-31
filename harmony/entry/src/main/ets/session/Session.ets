/**
 * CONTROL-channel session for the tablet (server) side.
 * Phase 0: replies hello_ack to hello, pong to ping. Mirrors mac Session.swift.
 * Phase 1+ : VIDEO frames will be routed to the decoder; INPUT frames produced
 * by the capture layer will be sent through `send`.
 */
import util from '@ohos.util';
import { display } from '@kit.ArkUI';
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
}

export class Session {
  private decoder: FrameDecoder = new FrameDecoder();
  private send: SendFn;
  private log: LogFn;
  private textEncoder: util.TextEncoder = new util.TextEncoder();
  private textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  /** VIDEO-channel payloads (Annex-B H.264 access units) + keyframe flag. */
  onVideo: ((payload: Uint8Array, isKeyframe: boolean) => void) | null = null;

  /** Negotiated encoded video resolution + codec + HDR mode (Mac→Pad video_config). */
  onVideoConfig: ((width: number, height: number, codec: string, hdr: string) => void) | null = null;

  constructor(send: SendFn, log: LogFn) {
    this.send = send;
    this.log = log;
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
        this.log('received hello from ' + (msg.role ?? 'peer'));
        this.sendControl({
          type: 'hello_ack',
          role: 'pad',
          protocolVersion: 1,
          caps: this.localCaps(),
        });
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

  /** Advertise this tablet's panel (resolution, refresh) + HW-decodable codecs
   *  so the Mac adapts its output — the adaptation interface for any tablet. */
  private localCaps(): HelloAckCaps {
    let sw: number = 2560;
    let sh: number = 1600;
    let scale: number = 2;
    let refresh: number = 60;
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      sw = d.width;
      sh = d.height;
      scale = Math.max(1, Math.round(d.densityPixels));   // integer backing scale (not the raw density)
      refresh = d.refreshRate;
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
