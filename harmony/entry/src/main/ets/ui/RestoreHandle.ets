/**
 * RestoreHandle — the tiny "⋯" affordance shown when the floating ball is hidden; tapping it brings
 * the ball back. Pure presentation: reads only the surface dims and fires one callback. Extracted
 * from Index.ets so the page's build() stays a thin composition.
 */
@Component
export struct RestoreHandle {
  @Prop surfaceW: number = 0;
  @Prop surfaceH: number = 0;
  onRestore?: () => void;

  build() {
    Text('⋯')
      .fontSize(20).fontColor('#FFFFFF').textAlign(TextAlign.Center)
      .width(28).height(28).borderRadius(14).backgroundColor('#66202832')
      .position({ x: this.surfaceW - 30, y: this.surfaceH / 2 - 14 }).zIndex(11)
      .onClick(() => { if (this.onRestore !== undefined) { this.onRestore(); } })
  }
}
