/**
 * L0/L1 — TCP server transport for the tablet (server) side.
 *
 * Wired (Phase 1):   listens on 127.0.0.1:<port>; the Mac reaches it through
 *                    `hdc fport tcp:<port> tcp:<port>` over the USB cable.
 * Wireless (Phase 4): listen on '0.0.0.0' and advertise via mDNS — same code.
 *
 * Only this file knows about sockets; Session and above are transport-agnostic.
 */
import socket from '@ohos.net.socket';
import util from '@ohos.util';
import { Session } from '../session/Session';
import { Channel, encodeFrame } from '../protocol/FrameCodec';

export class TcpServerTransport {
  private server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
  private log: (s: string) => void;
  private onStatus: (s: string) => void;
  private onVideo: ((payload: Uint8Array, isKeyframe: boolean) => void) | null;
  private onVideoConfig: ((width: number, height: number, codec: string, hdr: string) => void) | null;
  // Wireless TOFU gate (null ⇒ wired/no gate). Installed onto each Session so an unknown LAN client
  // must be approved before hello_ack. The wired path passes null → behavior unchanged.
  private pairingGate: ((peerId: string, deviceName: string, isLocalhost: boolean, ownerId: number, token: string) => Promise<boolean>) | null;
  private currentSend: ((bytes: Uint8Array) => void) | null = null;
  private currentClientId: number = -1;
  // Encodes the one-off 'session_busy' rejection frame (single-active-session guard). Reused.
  private busyEncoder: util.TextEncoder = new util.TextEncoder();
  private boundAddress: string = '127.0.0.1';
  private boundPort: number = 0;   // the port actually bound (preferred, or a fallback if occupied)
  // Fired once the socket is listening (after listen succeeds). WirelessService uses this to
  // advertise over mDNS only when bound to the LAN (0.0.0.0). Null on the wired path.
  onListening: ((address: string, port: number) => void) | null = null;
  // Fired when a client disconnects, with its transport-assigned clientId — lets WirelessService
  // clear a pairing prompt owned by a peer that went away (no late trust, dialog dismissed). Keyed on
  // clientId (not the spoofable peerId) so only the owning connection can cancel. Null on wired path.
  onClientGone: ((ownerId: number) => void) | null = null;

  constructor(log: (s: string) => void,
              onStatus: (s: string) => void,
              onVideo: ((payload: Uint8Array, isKeyframe: boolean) => void) | null = null,
              onVideoConfig: ((width: number, height: number, codec: string, hdr: string) => void) | null = null,
              pairingGate: ((peerId: string, deviceName: string, isLocalhost: boolean, ownerId: number, token: string) => Promise<boolean>) | null = null) {
    this.log = log;
    this.onStatus = onStatus;
    this.onVideo = onVideo;
    this.onVideoConfig = onVideoConfig;
    this.pairingGate = pairingGate;
  }

  /** Send a pre-framed message to the connected client (e.g. INPUT frames). */
  sendFrame(bytes: Uint8Array): void {
    if (this.currentSend !== null) {
      this.currentSend(bytes);
    }
  }

  /**
   * Reject a surplus client (single-active-session guard): send a framed `{type:error,
   * message:session_busy}` CONTROL frame, then close the socket. The explicit error lets the Mac fail
   * fast and surface a clear "已被占用" state instead of retry-looping on a silent close. Does NOT touch
   * currentSend/currentClientId — the live session's slot stays intact.
   */
  private rejectBusy(client: socket.TCPSocketConnection): void {
    try {
      const json: string = '{"type":"error","message":"session_busy"}';
      const payload: Uint8Array = this.busyEncoder.encodeInto(json);
      const frame: Uint8Array = encodeFrame(Channel.CONTROL, 0, payload);
      const opt: socket.TCPSendOptions = { data: frame.buffer as ArrayBuffer };
      client.send(opt)
        .then((): void => { client.close().catch((e: Object): void => this.log('busy close err ' + JSON.stringify(e))); })
        .catch((e: Object): void => {
          this.log('busy send err ' + JSON.stringify(e));
          client.close().catch((e2: Object): void => {});
        });
    } catch (e) {
      this.log('rejectBusy failed ' + JSON.stringify(e));
      client.close().catch((e2: Object): void => {});
    }
  }

  /**
   * Listen for the Mac. `bindAddress` is the wired/wireless seam: '127.0.0.1' (default, USB-only via
   * hdc fport) or '0.0.0.0' (LAN, set by WirelessService when wireless is on). `preferredPort` is
   * tried first; if it's occupied on this tablet we fall back to the next free port (so a port clash
   * with another app can't kill the listener). The ACTUAL bound port is reported via onListening —
   * wireless (mDNS/manual) carries it automatically; wired (hdc) assumes the preferred port.
   */
  start(preferredPort: number, bindAddress: string = '127.0.0.1'): void {
    this.boundAddress = bindAddress;
    const candidates: number[] = [];
    for (let i = 0; i < 8; i++) { candidates.push(preferredPort + i); }
    this.tryListen(bindAddress, candidates, 0);
  }

  private tryListen(bindAddress: string, ports: number[], i: number): void {
    if (i >= ports.length) {
      this.onStatus('listen failed');
      this.log('listen failed: no free port in ' + ports[0] + '..' + ports[ports.length - 1]);
      return;
    }
    const port: number = ports[i];
    this.server = socket.constructTCPSocketServerInstance();   // fresh instance per attempt
    const addr: socket.NetAddress = { address: bindAddress, port: port, family: 1 };
    this.server.listen(addr).then((): void => {
      this.boundPort = port;
      this.onStatus('listening ' + bindAddress + ':' + port);
      this.log('TCP server listening on ' + bindAddress + ':' + port);
      this.attachConnectHandler();
      if (this.onListening !== null) { this.onListening(bindAddress, port); }
    }).catch((err: Object): void => {
      this.log('listen ' + port + ' failed (' + JSON.stringify(err) + '), trying next');
      this.tryListen(bindAddress, ports, i + 1);
    });
  }

  private attachConnectHandler(): void {
    this.server.on('connect', (client: socket.TCPSocketConnection) => {
      // SINGLE-ACTIVE-SESSION GUARD (see docs/CONFLICTS.md). The tablet is structurally single-session
      // — ONE decoder, ONE surface, ONE input-send slot — so a second concurrent client would
      // interleave two video streams into one decoder (corrupt display) and misroute input. Reject the
      // newcomer and KEEP the incumbent. This runs BEFORE currentSend/currentClientId are assigned, so
      // the live session's input slot is never clobbered; currentClientId returns to -1 when the active
      // client closes (see the 'close' handler), so a later reconnect is accepted normally. It is the
      // ONLY place "many Macs / many transports → one tablet" can be arbitrated (neither Mac sees the
      // other), and a no-op when wireless is off (≤1 hdc client). We send an explicit 'session_busy'
      // error so the Mac fails fast (no reconnect-loop) instead of treating a silent close as a drop.
      if (this.currentClientId !== -1) {
        this.log('rejecting 2nd client id=' + client.clientId + ' — single active session (incumbent=' + this.currentClientId + ')');
        this.onStatus('已拒绝第二个连接（同一时间仅支持一条连接）');
        this.rejectBusy(client);
        return;
      }
      this.onStatus('client connected');
      this.log('client connected (id=' + client.clientId + ')');

      const sendFn = (bytes: Uint8Array): void => {
        // Send the exact frame bytes. encodeFrame returns a fresh, offset-0 array.
        const opt: socket.TCPSendOptions = { data: bytes.buffer as ArrayBuffer };
        client.send(opt).catch((e: Object) => this.log('send error: ' + JSON.stringify(e)));
      };
      this.currentSend = sendFn;
      this.currentClientId = client.clientId;

      const session: Session = new Session(sendFn, this.log);
      session.onVideo = this.onVideo;
      session.onVideoConfig = this.onVideoConfig;
      session.setOwnerId(client.clientId);   // cancel-owner identity (transport-assigned, not spoofable)
      if (this.pairingGate !== null) { session.setPairingGate(this.pairingGate); }
      // Determine localhost (hdc/USB) vs LAN so the pairing gate exempts wired clients.
      // When bound to 127.0.0.1 EVERY client is local by construction (the wired/USB path) — decide
      // SYNCHRONOUSLY and never depend on getRemoteAddress, so the proven wired handshake can't be
      // regressed or stalled by an address-API quirk. Only consult getRemoteAddress on a LAN bind.
      if (this.boundAddress === '127.0.0.1') {
        session.setClientLocalhost(true);
      } else {
        client.getRemoteAddress().then((ra: socket.NetAddress): void => {
          const local: boolean =
            ra.address === '127.0.0.1' || ra.address === '::1' || ra.address === '::ffff:127.0.0.1';
          session.setClientLocalhost(local);
          this.log('client remote ' + ra.address + (local ? ' (localhost)' : ' (LAN)'));
        }).catch((e: Object): void => {
          this.log('getRemoteAddress failed ' + JSON.stringify(e));
          session.setClientLocalhost(false);   // unknown → treat as LAN (require pairing)
        });
      }

      client.on('message', (value: socket.SocketMessageInfo): void => {
        session.onBytes(new Uint8Array(value.message));
      });
      client.on('close', (): void => {
        this.onStatus('client disconnected');
        // If this client owned an in-flight pairing prompt, free it (dialog clears, no late trust).
        // Keyed on the transport-assigned clientId so only THIS connection can cancel its prompt.
        if (this.onClientGone !== null) { this.onClientGone(client.clientId); }
        session.dispose();   // remove the rotation listener for this session
        // Only clear the sender if it's still the active client.
        if (client.clientId === this.currentClientId) {
          this.currentSend = null;
          this.currentClientId = -1;
        }
        this.log('client closed');
      });
    });
  }

  /**
   * Close the listening socket. Awaited by ReceiverConnection.restart() before re-listening on a
   * new bind address (wireless toggle), so the port is free and we never hit EADDRINUSE.
   */
  stop(): Promise<void> {
    return this.server.close();
  }
}
