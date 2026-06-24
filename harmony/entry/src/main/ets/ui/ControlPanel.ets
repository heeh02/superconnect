import { Theme } from './Theme';
import { TrustedPeer } from '../services/wireless/PairingStore';

// ControlPanel — the settings / cheat-sheet / quick-toggles overlay. Status + stream info
// are passed in; the toggles bind two-way (@Link) except "pause input" which has a side
// effect (cursor) so it calls back. Mirrors Mac Views/AdvancedPanel + the toggle rows.
@Component
export struct ControlPanel {
  @Prop statusText: string = '';
  @Prop port: number = 0;
  @Prop vWidth: number = 0;
  @Prop vHeight: number = 0;
  @Prop vCodec: string = '';
  @Prop wirelessOn: boolean = false;
  @Prop wifiIp: string = '';
  onToggleWireless?: (v: boolean) => void;
  @Prop pairedPeers: TrustedPeer[] = [];
  onForgetPeer?: (peerId: string) => void;
  @Link isDrawingMode: boolean;
  @Link ballHidden: boolean;
  @Prop inputDisabled: boolean = false;
  @Prop showExitFullscreen: boolean = false;
  onToggleInput?: (v: boolean) => void;
  onExitFullscreen?: () => void;
  onClose?: () => void;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // dim backdrop, tap to close
      Column()
        .width('100%').height('100%').backgroundColor('#80000000')
        .onClick(() => { this.onClose?.(); })
      // card
      Column() {
        Row() {
          Text('控制面板').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Text('✕').fontSize(18).fontColor($r('sys.color.font_secondary'))
            .width(32).height(32).textAlign(TextAlign.Center)
            .onClick(() => { this.onClose?.(); })
        }.width('100%').margin({ bottom: 6 })

        Scroll() {
          Column({ space: 18 }) {
            // Quick-Settings first: the controls the user reaches for most while streaming sit at the
            // top so they're a single tap away; reference info + cheat-sheets follow below. (UI-POLISH)
            this.Section('快捷开关')
            this.ToggleRow('绘画模式（手写笔）', this.isDrawingMode, (v: boolean) => { this.isDrawingMode = v; })
            this.ToggleRow('暂停输入（操作平板）', this.inputDisabled, (v: boolean) => { this.onToggleInput?.(v); })
            this.ToggleRow('隐藏悬浮球', this.ballHidden, (v: boolean) => { this.ballHidden = v; })

            this.Section('显示模式')
            if (this.showExitFullscreen) {
              Row() {
                Text('退出全屏 · 回到小窗').fontSize(15).fontColor(Theme.accent)
                Blank()
                Text('›').fontSize(18).fontColor($r('sys.color.font_secondary'))
              }.width('100%').padding({ top: 8, bottom: 8 })
              .onClick(() => { this.onExitFullscreen?.(); this.onClose?.(); })
            } else {
              Text('小窗模式 · 双击画面进入全屏')
                .fontSize(13).fontColor($r('sys.color.font_tertiary')).width('100%')
            }

            this.Section('连接状态')
            this.InfoRow('状态', this.statusText)
            this.InfoRow('端口', this.port.toString())
            this.InfoRow('分辨率', this.vWidth > 0 ? (this.vWidth + ' × ' + this.vHeight) : '—')
            this.InfoRow('编码', this.vCodec !== '' ? this.vCodec.toUpperCase() : '—')

            this.Section('无线连接')
            this.ToggleRow('无线模式 (Wi‑Fi)', this.wirelessOn, (v: boolean) => { this.onToggleWireless?.(v); })
            this.InfoRow('Wi‑Fi 地址',
              this.wirelessOn ? (this.wifiIp !== '' ? (this.wifiIp + ' : ' + this.port) : '未连接 Wi‑Fi') : '仅 USB')
            Text(this.wirelessOn
              ? '同一 Wi‑Fi 下的 Mac 可自动发现，或手动输入上面的地址连接。'
              : '开启后可让同网段的 Mac 无线连接；关闭时仅支持数据线 (USB)。')
              .fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')

            this.Section('已配对设备')
            if (this.pairedPeers.length === 0) {
              Text('暂无。首次无线连接时在本机点「允许」即可记住该 Mac。')
                .fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
            } else {
              ForEach(this.pairedPeers, (p: TrustedPeer) => {
                Row() {
                  Text(p.name !== '' ? p.name : 'Mac').fontSize(15).fontColor($r('sys.color.font_primary')).layoutWeight(1).maxLines(1)
                  Button('移除').fontSize(13).height(30).fontColor(Theme.accent)
                    .backgroundColor($r('sys.color.comp_background_secondary'))
                    .onClick(() => { this.onForgetPeer?.(p.peerId); })
                }.width('100%').padding({ top: 4, bottom: 4 })
              }, (p: TrustedPeer) => p.peerId)
            }

            this.Section('触控板手势')
            this.CheatRow('移动', '单指滑动')
            this.CheatRow('单击 / 右键', '轻点 / 双指轻点')
            this.CheatRow('滚动 / 缩放', '双指滑动 / 双指捏合')
            this.CheatRow('拖动', '双击后滑动，再轻点放下')

            this.Section('键盘映射')
            this.CheatRow('Alt', '⌘ Command')
            this.CheatRow('⊙ 圆环', '⌥ Option')
            this.CheatRow('Ctrl', 'Control')
            this.CheatRow('Caps', '切换中 / 英文输入')
            this.CheatRow('Ctrl+Alt+空格', '表情与符号')

            this.Section('画质设置')
            Text('分辨率 / 刷新率 / 编码 / 码率由 Mac 端自动协商，可在 Mac 菜单栏 App 中调整。')
              .fontSize(12).fontColor($r('sys.color.font_tertiary')).width('100%')
          }.width('100%')
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      }
      .width('86%').constraintSize({ maxWidth: 520 }).height('80%')
      .padding(22).borderRadius(Theme.radiusLg)
      .backgroundColor($r('sys.color.comp_background_primary'))
      .shadow({ radius: 24, color: '#50000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%').height('100%').zIndex(20)
  }

  @Builder
  Section(title: string) {
    Text(title).fontSize(13).fontWeight(FontWeight.Medium)
      .fontColor(Theme.accent).width('100%').margin({ top: 4 })
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(15).fontColor($r('sys.color.font_secondary'))
      Blank()
      Text(value).fontSize(15).fontColor($r('sys.color.font_primary'))
    }.width('100%').padding({ top: 6, bottom: 6 })
  }

  @Builder
  ToggleRow(label: string, on: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(label).fontSize(15).fontColor($r('sys.color.font_primary'))
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor(Theme.accent)
        .onChange((v: boolean) => { onChange(v); })
    }.width('100%').padding({ top: 4, bottom: 4 })
  }

  @Builder
  CheatRow(action: string, how: string) {
    Row() {
      Text(action).fontSize(14).fontColor($r('sys.color.font_primary'))
      Blank()
      Text(how).fontSize(14).fontColor($r('sys.color.font_secondary'))
    }.width('100%').padding({ top: 5, bottom: 5 })
  }
}
