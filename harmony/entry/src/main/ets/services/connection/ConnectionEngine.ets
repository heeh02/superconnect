import { ConnectionStatus } from '../../models/ConnectionStatus';
import { StreamInfo } from '../../models/StreamInfo';

// ConnectionEngine — role-agnostic "what a live link DOES", the ArkTS analog of Mac's
// ConnectionEngine protocol. ReceiverConnection (real today) and HostConnection (future
// stub) both implement it, so the ConnectionManager is role-agnostic and the symmetric
// future is a one-line factory flip in app/AppEnvironment.ets.
export interface ConnectionEngine {
  start(): void;
  stop(): void;
  // Raw byte sink for this link (receiver: input frames; host: video frames). The
  // ConnectionManager builds the InputSender from this so it shares the engine's transport.
  frameSink(): (bytes: Uint8Array) => void;
  onStatus?: (s: ConnectionStatus) => void;
  onStreamInfo?: (info: StreamInfo) => void;
  onLog?: (msg: string) => void;
}
