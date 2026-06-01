import { ConnectionManager } from '../services/ConnectionManager';
import { ConnectionEngine } from '../services/connection/ConnectionEngine';
import { ReceiverConnection } from '../services/connection/role/ReceiverConnection';
import { HostConnection } from '../services/connection/role/HostConnection';
import { WirelessService } from '../services/wireless/WirelessService';
import { Role } from '../models/Role';
import { common } from '@kit.AbilityKit';

// AppEnvironment — composition root, mirroring Mac App/AppEnvironment.swift. The ONE place
// concrete roles + services are wired: today the tablet is a Receiver. Enabling the symmetric
// Host future is a one-line change to engineForRole; the wireless module is wired here too, fully
// decoupled — it only injects the receiver's bind address + a rebind hook, nothing else.
export class AppEnvironment {
  readonly manager: ConnectionManager;
  readonly wireless: WirelessService;

  constructor(port: number, ctx: common.UIAbilityContext) {
    this.wireless = new WirelessService(ctx);
    // The receiver binds where WirelessService says: 127.0.0.1 (USB only) or 0.0.0.0 (LAN).
    const receiver: ReceiverConnection = new ReceiverConnection(port, (): string => this.wireless.bindAddress());
    const engineForRole = (role: Role): ConnectionEngine => {
      return role === Role.Host ? new HostConnection() : receiver;
    };
    this.manager = new ConnectionManager(engineForRole(Role.Receiver));
    // Toggling wireless rebinds the receiver's listen socket to the new address (live).
    this.wireless.setRestart((): void => { receiver.restart(); });
  }
}
