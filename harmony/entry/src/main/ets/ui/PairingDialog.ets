import { Theme } from './Theme';

/// A pending TOFU pairing request surfaced by WirelessService (peer identity + friendly name).
export interface PairingRequest {
  peerId: string;
  deviceName: string;
}

// PairingDialog — the TOFU "trust this Mac?" prompt shown on the first wireless connection from an
// unknown device. 允许 remembers the peer (silent next time); 拒绝 refuses it for this session.
@Component
export struct PairingDialog {
  @Prop deviceName: string = '';
  onAllow?: () => void;
  onDeny?: () => void;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#90000000')
      Column({ space: 14 }) {
        Text('🔗').fontSize(40)
        Text('允许此设备无线连接？').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text(this.deviceName !== '' ? this.deviceName : 'Mac').fontSize(16).fontColor(Theme.accent)
        Text('它将把这台平板作为无线扩展屏。仅在你信任该设备时允许——允许后会记住它，下次自动连接。')
          .fontSize(13).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
        Row({ space: 12 }) {
          Button('拒绝').fontSize(16).layoutWeight(1).height(46)
            .backgroundColor($r('sys.color.comp_background_secondary')).fontColor($r('sys.color.font_primary'))
            .onClick(() => { this.onDeny?.(); })
          Button('允许').fontSize(16).layoutWeight(1).height(46)
            .backgroundColor(Theme.accent).fontColor(Color.White)
            .onClick(() => { this.onAllow?.(); })
        }.width('100%').margin({ top: 8 })
      }
      .width('80%').constraintSize({ maxWidth: 420 }).padding(28).borderRadius(Theme.radiusLg)
      .backgroundColor($r('sys.color.comp_background_primary'))
      .shadow({ radius: 28, color: '#60000000', offsetX: 0, offsetY: 10 })
    }
    .width('100%').height('100%').zIndex(40)
  }
}
