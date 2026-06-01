import { Theme } from './Theme';

// IdleView — the waiting/connection screen shown before the Mac connects. Status text +
// dot are computed by the page (from connection state) and passed in. Mirrors Mac
// Views/EmptyStateView.
@Component
export struct IdleView {
  @Prop statusText: string = '';
  @Prop statusDot: string = '';   // status color
  @Prop port: number = 0;
  @Prop wirelessOn: boolean = false;
  @Prop wifiIp: string = '';
  onToggleWireless?: (v: boolean) => void;
  onOpenPanel?: () => void;

  build() {
    Column() {
      Blank()
      Column({ space: 14 }) {
        Text('✦').fontSize(46).fontColor(Theme.accent)
        Text('Superconnect').fontSize(30).fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text('把这台平板变成 Mac 的无线/有线扩展屏').fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
        Row({ space: 8 }) {
          Circle().width(9).height(9).fill(this.statusDot)
          Text(this.statusText).fontSize(15).fontColor($r('sys.color.font_primary'))
        }
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor($r('sys.color.comp_background_secondary')).borderRadius(20)

        // Wireless (Wi‑Fi) mode — OFF by default (USB only). ON exposes the tablet on the LAN so
        // the Mac can connect over Wi‑Fi; the IP below is for manual connect when mDNS is blocked.
        Row({ space: 10 }) {
          Text('无线模式 (Wi‑Fi)').fontSize(15).fontColor($r('sys.color.font_primary'))
          Toggle({ type: ToggleType.Switch, isOn: this.wirelessOn })
            .selectedColor(Theme.accent)
            .onChange((v: boolean) => { this.onToggleWireless?.(v); })
        }
        .padding({ left: 16, right: 12, top: 6, bottom: 6 })
        .backgroundColor($r('sys.color.comp_background_secondary')).borderRadius(20)

        if (this.wirelessOn) {
          if (this.wifiIp !== '') {
            Text('Wi‑Fi 地址  ' + this.wifiIp + ' : ' + this.port).fontSize(13).fontColor(Theme.accent)
          } else {
            Text('未连接 Wi‑Fi — 请先连接无线网络').fontSize(13).fontColor($r('sys.color.font_tertiary'))
          }
          Text('在 Mac 上自动发现，或手动输入上面的地址').fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
        } else {
          Text('监听端口 ' + this.port + ' · 仅 USB').fontSize(12).fontColor($r('sys.color.font_tertiary'))
          Text('用数据线连接，在 Mac 上打开 Superconnect 即可自动连接').fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
        }
      }
      .width('100%').alignItems(HorizontalAlign.Center)
      Blank()
      Button('使用帮助 / 设置')
        .fontSize(15).fontColor(Theme.accent)
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .borderRadius(Theme.radiusLg).height(44).width(220)
        .onClick(() => { this.onOpenPanel?.(); })
        .margin({ bottom: 40 })
    }
    .width('100%').height('100%')
    .padding(24)
    .backgroundColor($r('sys.color.background_primary'))
  }
}
