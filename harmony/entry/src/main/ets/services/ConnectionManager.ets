import { ConnectionEngine } from './connection/ConnectionEngine';
import { FrameInputSender } from '../input/FrameInputSender';
import { InputSender } from '../input/Sender';
import { ConnectionStatus } from '../models/ConnectionStatus';
import { StreamInfo } from '../models/StreamInfo';
import pointer from '@ohos.multimodalInput.pointer';

// ConnectionManager — the role-agnostic connection lifecycle owner (mirrors Mac
// ConnectionCoordinator). It drives a ConnectionEngine (ReceiverConnection today, a future
// HostConnection), builds the InputSender from the engine's frame sink (so input shares the
// engine's transport), owns the local-cursor lifecycle, and forwards the engine's status /
// stream-info / log to the page. The role itself is chosen in AppEnvironment, not here.
export class ConnectionManager {
  private engine: ConnectionEngine;
  private senderImpl: FrameInputSender;

  // View-state hooks the page binds (kept minimal — only what the UI shows).
  onLog?: (msg: string) => void;
  onStatus?: (s: ConnectionStatus) => void;
  onStreamInfo?: (info: StreamInfo) => void;

  constructor(engine: ConnectionEngine) {
    this.engine = engine;
    engine.onLog = (msg: string): void => { this.onLog?.(msg); };
    engine.onStatus = (s: ConnectionStatus): void => { this.onStatus?.(s); };
    engine.onStreamInfo = (info: StreamInfo): void => { this.onStreamInfo?.(info); };
    // Input layer sends through this seam; it shares the engine's transport via frameSink().
    this.senderImpl = new FrameInputSender(engine.frameSink());
  }

  sender(): InputSender { return this.senderImpl; }

  start(): void {
    // Hide the local HarmonyOS cursor so only the Mac cursor (in the video) shows.
    try { pointer.setPointerVisibleSync(false); } catch (e) { this.onLog?.('hideCursor ' + JSON.stringify(e)); }
    this.engine.start();
  }

  stop(): void {
    // setPointerVisibleSync is SYSTEM-WIDE — restore on exit or the cursor stays hidden.
    try { pointer.setPointerVisibleSync(true); } catch (e) { /* best-effort restore */ }
    this.engine.stop();
  }

  // Paused (captureEnabled=false) → reveal the tablet's own cursor so the user can operate
  // HarmonyOS; capturing → hide it again.
  setCaptureEnabled(enabled: boolean): void {
    try { pointer.setPointerVisibleSync(!enabled); } catch (e) { /* best-effort */ }
  }
}
