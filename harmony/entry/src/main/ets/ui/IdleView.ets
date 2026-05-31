import { Theme } from './Theme';

// IdleView — the waiting/connection screen shown before the Mac connects. Status text +
// dot are computed by the page (from connection state) and passed in. Mirrors Mac
// Views/EmptyStateView.
@Component
export struct IdleView {
  @Prop statusText: string = '';
  @Prop statusDot: string = '';   // status color
  @Prop port: number = 0;
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
        Text('监听端口 ' + this.port).fontSize(12).fontColor($r('sys.color.font_tertiary'))
        Text('在 Mac 上打开 Superconnect 即可自动连接').fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
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
