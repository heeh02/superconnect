import { Theme } from './Theme';

// WindowedView — the chrome shown over the small windowed preview: app title + status at the top, a
// "double-tap to go fullscreen" hint at the bottom, and a double-tap gesture covering the whole area
// (windowed mode is a passive preview — it doesn't forward input, so any double-tap means "fullscreen").
// The video XComponent itself is rendered (and sized) by the page behind this overlay.
@Component
export struct WindowedView {
  @Prop statusText: string;
  onEnterFullscreen: () => void = () => {};

  build() {
    Column() {
      Column({ space: 4 }) {
        Text('Superconnect')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        Text(this.statusText)
          .fontSize(13).fontColor('#99FFFFFF')
      }
      .alignItems(HorizontalAlign.Center)

      Blank()

      Row({ space: 8 }) {
        Text('⤢').fontSize(16).fontColor('#FFFFFF')
        Text('双击进入全屏').fontSize(15).fontColor('#FFFFFF')
      }
      .padding({ left: 18, right: 18, top: 10, bottom: 10 })
      .backgroundColor(Theme.accent)
      .borderRadius(Theme.radius)
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 48, bottom: 48 })
    .hitTestBehavior(HitTestMode.Block)
    .gesture(TapGesture({ count: 2 }).onAction((_e: GestureEvent): void => { this.onEnterFullscreen(); }))
  }
}
