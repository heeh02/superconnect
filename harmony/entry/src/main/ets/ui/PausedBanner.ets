import { Theme } from './Theme';

// PausedBanner — shown while input capture is paused; tapping it resumes. Extracted from
// the Index page (mirrors a Mac Views/Components piece).
@Component
export struct PausedBanner {
  @Prop surfaceW: number = 0;
  onResume?: () => void;

  build() {
    Row({ space: 8 }) {
      Text('⏸').fontSize(15)
      Text('输入已暂停 · 点此恢复').fontSize(14).fontColor(Color.White)
    }
    .padding({ left: 16, right: 16, top: 9, bottom: 9 })
    .backgroundColor('#E60A84FF').borderRadius(20)
    .shadow({ radius: 10, color: '#40000000', offsetX: 0, offsetY: 2 })
    .position({ x: this.surfaceW / 2 - 92, y: 16 })
    .zIndex(15)
    .onClick(() => { this.onResume?.(); })
  }
}
