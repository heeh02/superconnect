import { Theme } from '../ui/Theme';

// The single, de-jargoned connection state, mirroring Mac Models/ConnectionState.swift.
// Replaces the loose (status: string + streaming: boolean) pair currently in Index.ets.
export enum ConnectionStatus {
  Idle,        // no peer
  Listening,   // server up, waiting for the Mac
  Connected,   // handshook, not yet streaming
  Streaming,   // frames flowing
  Failed,      // error (auto-reconnecting)
}

export function statusLabel(s: ConnectionStatus): string {
  switch (s) {
    case ConnectionStatus.Streaming: return '已连接 · 投屏中';
    case ConnectionStatus.Connected: return '已连接';
    case ConnectionStatus.Failed:    return '连接中断 · 重连中';
    case ConnectionStatus.Listening: return '等待 Mac 连接';
    default:                         return '未连接';
  }
}

export function statusColor(s: ConnectionStatus): string {
  switch (s) {
    case ConnectionStatus.Streaming:
    case ConnectionStatus.Connected: return Theme.ok;       // green
    case ConnectionStatus.Failed:    return Theme.waiting;  // amber
    case ConnectionStatus.Listening: return Theme.busy;     // blue
    default:                         return Theme.waiting;
  }
}
