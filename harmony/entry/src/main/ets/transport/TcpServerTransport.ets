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
  private currentSend: ((bytes: Uint8Array) => void) | null = null;
  private currentClientId: number = -1;

  constructor(log: (s: string) => void,
              onStatus: (s: string) => void,
              onVideo: ((payload: Uint8Array, isKeyframe: boolean) => void) | null = null,
              onVideoConfig: ((width: number, height: number, codec: string, hdr: string) => void) | null = null) {
    this.log = log;
    this.onStatus = onStatus;
    this.onVideo = onVideo;
    this.onVideoConfig = onVideoConfig;
  }

  /** Send a pre-framed message to the connected client (e.g. INPUT frames). */
  sendFrame(bytes: Uint8Array): void {
    if (this.currentSend !== null) {
      this.currentSend(bytes);
    }
  }

  start(port: number): void {
    const addr: socket.NetAddress = { address: '127.0.0.1', port: port, family: 1 };
    this.server.listen(addr).then(() => {
      this.onStatus('listening 127.0.0.1:' + port);
      this.log('TCP server listening on 127.0.0.1:' + port);
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

      client.on('message', (value: socket.SocketMessageInfo): void => {
        session.onBytes(new Uint8Array(value.message));
      });
      client.on('close', (): void => {
        this.onStatus('client disconnected');
        // Only clear the sender if it's still the active client.
        if (client.clientId === this.currentClientId) {
          this.currentSend = null;
          this.currentClientId = -1;
        }
        this.log('client closed');
      });
    });
  }
}
