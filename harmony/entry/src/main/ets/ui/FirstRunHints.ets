import { Theme } from './Theme';

// FirstRunHints — a dismissible coach bubble shown ONCE on first fullscreen entry, explaining the
// floating ball glyphs (✎ 绘画 / ↖ 普通) and the double-tap-to-exit gesture that are otherwise
// undiscoverable. The page owns the "seen" flag (a UI preference) and the visibility; this component
// is purely presentational + a dismiss callback. View-layer overlay only — touches no service.
@Component
export struct FirstRunHints {
  onDismiss?: () => void;

  build() {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        Text('👋').fontSize(22)
        Text('全屏使用提示').fontSize(Theme.heading).fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
      }
      this.HintRow('↖', '悬浮球：轻点切换绘画模式')
      this.HintRow('☰', '长按悬浮球：打开控制面板与手势速查')
      this.HintRow('⤢', '双击画面：在小窗与全屏之间切换')
      Button('知道了')
        .fontSize(Theme.body).fontColor(Color.White)
        .backgroundColor(Theme.accent)
        .borderRadius(Theme.radius).height(44).width('100%')
        .margin({ top: 4 })
        .onClick(() => { this.onDismiss?.(); })
    }
    .width('78%').constraintSize({ maxWidth: 380 })
    .padding(24).borderRadius(Theme.radiusLg)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .shadow({ radius: 28, color: '#60000000', offsetX: 0, offsetY: 10 })
  }

  @Builder
  HintRow(glyph: string, text: string) {
    Row({ space: 12 }) {
      Text(glyph).fontSize(20).fontColor(Theme.accent).width(28).textAlign(TextAlign.Center)
      Text(text).fontSize(Theme.body).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
    }.width('100%')
  }
}
