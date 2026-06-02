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
import { Session } from '../session/Session';

export class TcpServerTransport {
  private server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
  private log: (s: string) => void;
  private onStatus: (s: string) => void;
  private onVideo: ((payload: Uint8Array, isKeyframe: boolean) => void) | null;
  private onVideoConfig: ((width: number, height: number, codec: string, hdr: string) => void) | null;
  // Wireless TOFU gate (null ⇒ wired/no gate). Installed onto each Session so an unknown LAN client
  // must be approved before hello_ack. The wired path passes null → behavior unchanged.
  private pairingGate: ((peerId: string, deviceName: string, isLocalhost: boolean, ownerId: number) => Promise<boolean>) | null;
  private currentSend: ((bytes: Uint8Array) => void) | null = null;
  private currentClientId: number = -1;
  private boundAddress: string = '127.0.0.1';
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
              pairingGate: ((peerId: string, deviceName: string, isLocalhost: boolean, ownerId: number) => Promise<boolean>) | null = null) {
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
   * Listen for the Mac. `bindAddress` is the wired/wireless seam: '127.0.0.1' (default, USB-only via
   * hdc fport) or '0.0.0.0' (LAN + localhost, set by WirelessService when wireless is on). Nothing
   * else about the server differs between the two — Session and above stay transport-agnostic.
   */
  start(port: number, bindAddress: string = '127.0.0.1'): void {
    this.boundAddress = bindAddress;
    const addr: socket.NetAddress = { address: bindAddress, port: port, family: 1 };
    this.server.listen(addr).then(() => {
      this.onStatus('listening ' + bindAddress + ':' + port);
      this.log('TCP server listening on ' + bindAddress + ':' + port);
      if (this.onListening !== null) { this.onListening(bindAddress, port); }
    }).catch((err: Object) => {
      this.onStatus('listen failed');
      this.log('listen error: ' + JSON.stringify(err));
    });

    this.server.on('connect', (client: socket.TCPSocketConnection) => {
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
