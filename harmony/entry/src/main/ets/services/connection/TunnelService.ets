import { Endpoint, TransportKind } from '../../models/Peer';

// TunnelService — names the listen-side endpoint choice that is currently hardcoded as
// 127.0.0.1 in TcpServerTransport.ets. Mirrors Mac's TunnelService (HdcFportTunnel /
// DirectTunnel). Wired binds loopback (USB/hdc fport reaches it); wireless binds all
// interfaces for LAN/mDNS. Interface now; the real wireless impl lands with tablet-as-host.
export interface TunnelService {
  readonly kind: TransportKind;
  bindHost(): string;        // "127.0.0.1" (wired) | "0.0.0.0" (wireless)
}

// Default wired tunnel = today's behavior, made explicit.
export class WiredTunnel implements TunnelService {
  readonly kind: TransportKind = TransportKind.Wired;
  bindHost(): string { return '127.0.0.1'; }
}
