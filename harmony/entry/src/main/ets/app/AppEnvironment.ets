import { ConnectionManager } from '../services/ConnectionManager';
import { ConnectionEngine } from '../services/connection/ConnectionEngine';
import { ReceiverConnection } from '../services/connection/role/ReceiverConnection';
import { HostConnection } from '../services/connection/role/HostConnection';
import { Role } from '../models/Role';

// AppEnvironment — composition root, mirroring Mac App/AppEnvironment.swift. The ONE place
// concrete roles are wired: today the tablet is a Receiver. Enabling the symmetric Host
// future (MatePad casting out) is a one-line change to the engineForRole branch below —
// nothing else (ConnectionManager, the page, the input layer) changes.
export class AppEnvironment {
  readonly manager: ConnectionManager;

  constructor(port: number) {
    const engineForRole = (role: Role): ConnectionEngine => {
      return role === Role.Host ? new HostConnection() : new ReceiverConnection(port);
    };
    this.manager = new ConnectionManager(engineForRole(Role.Receiver));
  }
}
