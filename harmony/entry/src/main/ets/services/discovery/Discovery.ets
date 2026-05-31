import { Peer, TransportKind } from '../../models/Peer';

// Discovery — long-lived source publishing the current set of peers reachable over one
// TransportKind, mirroring Mac Services/Discovery/DeviceDiscovery. The tablet is passive
// (it listens) today, so its "discovery" yields the single connected Mac; active discovery
// of many peers lands with tablet-as-host / wireless. Interface now, body deferred.
export interface Discovery {
  readonly kind: TransportKind;
  peers(): Peer[];
  onChange?: (peers: Peer[]) => void;
  start(): void;
  stop(): void;
}
