import { ConnectionEngine } from '../ConnectionEngine';
import { ConnectionStatus } from '../../../models/ConnectionStatus';

// HostConnection — STUB for the symmetric future where the MatePad casts ITS screen out
// (capture + encode + dial-out to a peer). Mirrors the Mac's ReceiverConnection stub. To
// enable, implement this (a capture/encode pipeline + a TCP-client transport) and flip the
// engineForRole branch in app/AppEnvironment.ets — no other layer changes.
export class HostConnection implements ConnectionEngine {
  onStatus?: (s: ConnectionStatus) => void;

  start(): void {
    this.onStatus?.(ConnectionStatus.Failed);   // tablet-as-host not supported yet
  }

  stop(): void {}

  frameSink(): (bytes: Uint8Array) => void {
    return (_b: Uint8Array): void => { /* no transport yet */ };
  }
}
