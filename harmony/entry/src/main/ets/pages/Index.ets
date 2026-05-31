import { InputRouter } from '../input/InputRouter';
import { KeyboardHandler } from '../input/KeyboardHandler';
import { ConnectionManager } from '../services/ConnectionManager';
import { AppEnvironment } from '../app/AppEnvironment';
import { ConnectionStatus, statusLabel, statusColor } from '../models/ConnectionStatus';
import { StreamInfo } from '../models/StreamInfo';
import { FloatingBall } from '../components/FloatingBall';
import { IdleView } from '../ui/IdleView';
import { ControlPanel } from '../ui/ControlPanel';
import { PausedBanner } from '../ui/PausedBanner';
import hilog from '@ohos.hilog';
import sc from 'libsuperconnect.so';


@Entry
@Component
struct Index {
  @State private connStatus: ConnectionStatus = ConnectionStatus.Idle;
  @State logs: string[] = [];
  @State isDrawingMode: boolean = false;
  @State surfaceW: number = 0;
  @State surfaceH: number = 0;
  @State ballX: number = 0;
  @State ballY: number = 0;
  @State imeText: string = '';        // hidden IME catcher buffer (cleared after each commit)
  // GUI state
  @State private showPanel: boolean = false;   // control panel (settings / cheat-sheet / toggles)
  @State private ballHidden: boolean = false;  // quick toggle: hide the floating ball
  @State private inputDisabled: boolean = false; // pause capture → let the tablet's own UI work
  @State private vWidth: number = 0;           // live stream resolution / codec (from video_config)
  @State private vHeight: number = 0;
  @State private vCodec: string = '';
  private imeCtrl: TextInputController = new TextInputController();
  private kbd: KeyboardHandler | null = null;   // physical + soft keyboard → Mac (owns metaHeld)
  private env: AppEnvironment | null = null;    // composition root (selects the role engine)
  private manager: ConnectionManager | null = null;   // connection lifecycle (from env)
  private router: InputRouter | null = null;   // owns pen + trackpad + finger input (FSMs)
  private readonly port: number = 8888;

  aboutToAppear(): void {
    // HDR capability probe (decisive gate): log the HW HEVC decoder's 10-bit/HDR support.
    try {
      hilog.info(0x0, 'SCDIAG', 'hdrDecodeCaps=%{public}d supportsHevc=%{public}d',
                 sc.hdrDecodeCaps(), sc.supportsHevc() ? 1 : 0);
    } catch (e) { this.appendLog('hdrProbe ' + JSON.stringify(e)); }
    // Composition root selects the role engine (Receiver today); the manager owns the
    // connection lifecycle. The page just binds the view state it shows.
    this.env = new AppEnvironment(this.port);
    const mgr: ConnectionManager = this.env.manager;
    this.manager = mgr;
    mgr.onLog = (msg: string): void => { this.appendLog(msg); };
    mgr.onStatus = (s: ConnectionStatus): void => { this.connStatus = s; };
    mgr.onStreamInfo = (info: StreamInfo): void => {
      this.vWidth = info.width; this.vHeight = info.height;
      this.vCodec = info.codec + (info.hdr !== 'off' ? ' · HDR' : '');
    };
    // Input layer shares the manager's transport via the sender seam.
    this.kbd = new KeyboardHandler(mgr.sender());
    this.router = new InputRouter(
      mgr.sender(),
      (): number => this.surfaceW,
      (): number => this.surfaceH,
      (): boolean => this.isDrawingMode,
    );
    mgr.start();
  }

  aboutToDisappear(): void {
    this.manager?.stop();
  }

  private appendLog(msg: string): void {
    const next: string[] = this.logs.slice();
    next.push(msg);
    this.logs = next.slice(-100);
  }


  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The Mac screen renders here.
      XComponent({ id: 'sc_surface', type: XComponentType.SURFACE, libraryname: 'superconnect' })
        .onLoad(() => { this.appendLog('XComponent surface loaded'); })
        .width('100%')
        .height('100%')

      // Transparent layer ON TOP that reliably captures touch in ArkTS (the
      // XComponent's native path would otherwise swallow touches).
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#00000000')
        .hitTestBehavior(this.inputDisabled ? HitTestMode.None : HitTestMode.Block)
        .onAreaChange((_o: Area, n: Area) => {
          this.surfaceW = Number(n.width);
          this.surfaceH = Number(n.height);
          if (this.surfaceW <= 0 || this.surfaceH <= 0) { return; }
          if (this.ballX === 0 && this.ballY === 0) {
            this.ballX = this.surfaceW - 56 - 12;
            this.ballY = this.surfaceH / 2 - 28;
          } else {
            // Keep the ball on-screen across rotation / size changes.
            this.ballX = Math.min(Math.max(this.ballX, 12), this.surfaceW - 56 - 12);
            this.ballY = Math.min(Math.max(this.ballY, 12), this.surfaceH - 56 - 12);
          }
        })
        .onTouch((e: TouchEvent) => { this.router?.onTouch(e); })
        .onMouse((e: MouseEvent) => { this.router?.onMouse(e); })        // trackpad cursor/click/drag
        .onAxisEvent((e: AxisEvent) => { this.router?.onAxis(e); })      // trackpad scroll/pinch
        .focusable(false)   // never steal key focus from the hidden IME catcher

      // Hidden, focused TextInput that owns the physical keyboard. Shortcuts / named
      // keys are consumed pre-IME and sent as raw keys; printable + IME-composed
      // (Chinese) text falls through and is sent as committed Unicode text.
      TextInput({ text: this.imeText, controller: this.imeCtrl })
        .id('imecatcher')
        .focusable(true)
        .defaultFocus(true)
        .opacity(0)
        .width(1)
        .height(1)
        .onKeyPreIme((e: KeyEvent): boolean => {
          return this.kbd?.onKeyPreIme(e) ?? false;   // physical keys → Mac (handler owns the logic)
        })
        .onWillInsert((info: InsertValue): boolean => {
          return this.kbd?.onWillInsert(info) ?? false;
        })
        .onChange((value: string, preview?: PreviewText): void => {
          this.kbd?.onCommit(value, preview);   // 3rd-party IME commit → Mac
          this.imeText = '';                    // clear so the hidden field can't grow
          this.imeCtrl.caretPosition(0);
        })
        .onWillDelete((info: DeleteValue): boolean => {
          return this.kbd?.onWillDelete(info) ?? false;   // soft backspace/del → Mac keystroke
        })

      if (this.connStatus !== ConnectionStatus.Streaming) {
        IdleView({
          statusText: statusLabel(this.connStatus),
          statusDot: statusColor(this.connStatus),
          port: this.port,
          onOpenPanel: () => { this.showPanel = true; },
        })
      }

      // Paused banner — safe way back when input capture is paused.
      if (this.connStatus === ConnectionStatus.Streaming && this.inputDisabled) {
        PausedBanner({ surfaceW: this.surfaceW, onResume: () => { this.setInputDisabled(false); } })
      }

      // Floating control — last child so it z-orders above the touch overlay; its
      // own gestures consume only touches on the 56vp circle. Tap = drawing toggle,
      // long-press = open the control panel.
      if (this.surfaceW > 0 && !this.ballHidden) {
        FloatingBall({
          drawing: $isDrawingMode,
          ballX: $ballX,
          ballY: $ballY,
          screenW: this.surfaceW,
          screenH: this.surfaceH,
          onMenu: () => { this.showPanel = true; },
        })
      }
      // Tiny restore handle when the ball is hidden.
      if (this.surfaceW > 0 && this.ballHidden) {
        Text('⋯')
          .fontSize(20).fontColor('#FFFFFF').textAlign(TextAlign.Center)
          .width(28).height(28).borderRadius(14).backgroundColor('#66202832')
          .position({ x: this.surfaceW - 30, y: this.surfaceH / 2 - 14 }).zIndex(11)
          .onClick(() => { this.ballHidden = false; })
      }

      // Control panel — top-most overlay (settings / cheat-sheet / toggles).
      if (this.showPanel) {
        ControlPanel({
          statusText: statusLabel(this.connStatus),
          port: this.port,
          vWidth: this.vWidth,
          vHeight: this.vHeight,
          vCodec: this.vCodec,
          isDrawingMode: $isDrawingMode,
          ballHidden: $ballHidden,
          inputDisabled: this.inputDisabled,
          onToggleInput: (v: boolean) => { this.setInputDisabled(v); },
          onClose: () => { this.showPanel = false; },
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  private setInputDisabled(v: boolean): void {
    this.inputDisabled = v;
    // Paused → reveal the tablet's own cursor; capturing → hide it (manager owns the cursor).
    this.manager?.setCaptureEnabled(!v);
  }

}
