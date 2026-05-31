// Peer — a remote endpoint, mirroring Mac Models/{Device,Endpoint,TransportKind}.swift.
// The tablet has exactly one peer (the connected Mac) today; full discovery of many peers
// is the symmetric-future seam (services/discovery/Discovery.ets).

export enum TransportKind {
  Wired,      // USB / hdc fport — local loopback
  Wireless,   // LAN / Wi-Fi (mDNS) — future
}

export interface Endpoint {
  kind: TransportKind;
  host: string;   // bind/dial host (127.0.0.1 wired, 0.0.0.0 / peer-ip wireless)
  port: number;
}

export interface Peer {
  id: string;             // stable peerId from the handshake (empty = legacy/anonymous)
  name: string;           // friendly device name
  capabilities: number;   // RoleCapability bitmask
  endpoint: Endpoint;
  transportKind: TransportKind;
}
