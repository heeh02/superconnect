import { Theme } from './Theme';
import { ConnectionStatus } from '../models/ConnectionStatus';

// StatusBanner — a thin, top-anchored transitional banner shown during non-steady link states
// (connecting / reconnecting) so the jump between idle and streaming isn't silent. Purely presentational:
// the page passes the current ConnectionStatus + the peer name it already holds (pairingName). Mirrors the
// Mac transitional caption + the Android Material banner. View-layer only — reads no service.
@Component
export struct StatusBanner {
  @Prop status: ConnectionStatus = ConnectionStatus.Idle;
  @Prop peerName: string = '';

  // Only the in-between states warrant a banner; steady (Streaming) + resting (Idle) show none.
  private visible(): boolean {
    return this.status === ConnectionStatus.Listening
        || this.status === ConnectionStatus.Connected
        || this.status === ConnectionStatus.Failed;
  }

  private dotColor(): string {
    switch (this.status) {
      case ConnectionStatus.Connected: return Theme.ok;       // handshook, frames imminent
      case ConnectionStatus.Failed:    return Theme.waiting;  // amber — reconnecting
      default:                         return Theme.busy;     // blue — listening / connecting
    }
  }

  private label(): string {
    const who: string = this.peerName !== '' ? this.peerName : 'Mac';
    switch (this.status) {
      case ConnectionStatus.Failed:    return '连接中断 · 正在重连 ' + who + '…';
      case ConnectionStatus.Connected: return '已连接 ' + who + ' · 正在准备画面…';
      default:                         return '等待 ' + who + ' 连接…';
    }
  }

  build() {
    if (this.visible()) {
      Row({ space: 8 }) {
        Circle().width(8).height(8).fill(this.dotColor())
        Text(this.label()).fontSize(Theme.small).fontColor('#FFFFFF').maxLines(1)
      }
      .padding({ left: 14, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#CC1C1F26')
      .borderRadius(20)
      .shadow({ radius: 12, color: '#40000000', offsetX: 0, offsetY: 3 })
      .accessibilityText(this.label())
    }
  }
}
