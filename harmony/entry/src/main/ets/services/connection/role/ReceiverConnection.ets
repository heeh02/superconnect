import { ConnectionEngine } from '../ConnectionEngine';
import { ConnectionStatus } from '../../../models/ConnectionStatus';
import { StreamInfo } from '../../../models/StreamInfo';
import { TcpServerTransport } from '../../../transport/TcpServerTransport';
import sc from 'libsuperconnect.so';

// ReceiverConnection — the tablet's REAL role: receive a screen stream and display it
// (VIDEO → native decoder; video_config → codec/HDR/size), while the input channel flows
// back out via frameSink(). Mirrors the Mac's HostConnection (the opposite-side real role);
// the tablet's HostConnection is the stub. Selected by AppEnvironment's engineForRole.
export class ReceiverConnection implements ConnectionEngine {
  private port: number;
  // Where to bind — supplied by WirelessService via AppEnvironment: '127.0.0.1' (USB only) or
  // '0.0.0.0' (LAN). Read at start() time so a wireless toggle + restart() picks up the new value.
  private bindAddressFn: () => string;
  private transport: TcpServerTransport | null = null;
  onStatus?: (s: ConnectionStatus) => void;
  onStreamInfo?: (info: StreamInfo) => void;
  onLog?: (msg: string) => void;

  constructor(port: number, bindAddressFn: () => string = (): string => '127.0.0.1') {
    this.port = port;
    this.bindAddressFn = bindAddressFn;
  }

  start(): void {
    this.transport = new TcpServerTransport(
      (msg: string): void => { this.onLog?.(msg); },
      (s: string): void => { this.onStatus?.(this.mapStatus(s)); },
      // VIDEO channel → native decoder (renders onto the XComponent surface).
      (payload: Uint8Array, isKeyframe: boolean): void => {
        sc.pushVideo(payload, isKeyframe);
        this.onStatus?.(ConnectionStatus.Streaming);
      },
      // video_config → set codec + HDR mode + resolution on native, which starts decode.
      (width: number, height: number, codec: string, hdr: string): void => {
        sc.setCodec(codec);
        sc.setHdr(hdr);
        sc.setVideoSize(width, height);
        this.onStreamInfo?.({ width: width, height: height, codec: codec, hdr: hdr });
        this.onLog?.('decoder armed ' + width + '×' + height + ' ' + codec + ' hdr=' + hdr);
      },
    );
    this.transport.start(this.port, this.bindAddressFn());
  }

  stop(): void {
    const t: TcpServerTransport | null = this.transport;
    this.transport = null;
    // Close the listen socket (best-effort) so a later re-listen doesn't hit EADDRINUSE.
    t?.stop().catch((e: Object): void => { this.onLog?.('transport close ' + JSON.stringify(e)); });
  }

  /**
   * Rebind to the CURRENT bindAddressFn() — called when the wireless mode is toggled. Closes the
   * old listener first (awaited) so the port is free, then re-listens on the new address. Any
   * in-flight stream drops; the page falls back to "listening". Wireless-only side door; the wired
   * lifecycle (start/stop) is untouched.
   */
  async restart(): Promise<void> {
    const t: TcpServerTransport | null = this.transport;
    this.transport = null;
    if (t !== null) {
      try { await t.stop(); } catch (e) { this.onLog?.('transport stop ' + JSON.stringify(e)); }
    }
    this.start();
  }

  // Input frames flow out over the same transport. The closure reads transport at call time.
  frameSink(): (bytes: Uint8Array) => void {
    return (b: Uint8Array): void => { this.transport?.sendFrame(b); };
  }

  private mapStatus(s: string): ConnectionStatus {
    if (s.indexOf('disconnect') >= 0) { return ConnectionStatus.Listening; }
    if (s.indexOf('connect') >= 0) { return ConnectionStatus.Connected; }
    if (s.indexOf('fail') >= 0) { return ConnectionStatus.Failed; }
    if (s.indexOf('listen') >= 0) { return ConnectionStatus.Listening; }
    return ConnectionStatus.Idle;
  }
}
