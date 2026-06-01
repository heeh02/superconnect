import { InputRouter } from '../input/InputRouter';
import { KeyboardHandler } from '../input/KeyboardHandler';
import { ConnectionManager } from '../services/ConnectionManager';
import { AppEnvironment } from '../app/AppEnvironment';
import { ConnectionStatus, statusLabel, statusColor } from '../models/ConnectionStatus';
import { DisplayMode } from '../models/DisplayMode';
import { StreamInfo } from '../models/StreamInfo';
import { WindowMode } from '../services/WindowMode';
import { FullscreenNotification } from '../services/FullscreenNotification';
import { FloatingBall } from '../components/FloatingBall';
import { IdleView } from '../ui/IdleView';
import { ControlPanel } from '../ui/ControlPanel';
import { PausedBanner } from '../ui/PausedBanner';
import { WindowedView } from '../ui/WindowedView';
import { common } from '@kit.AbilityKit';
import hilog from '@ohos.hilog';
import sc from 'libsuperconnect.so';


@Entry
@Component
struct Index {
  @State private connStatus: ConnectionStatus = ConnectionStatus.Idle;
  @State private displayMode: DisplayMode = DisplayMode.Windowed;  // small preview until double-tap
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
  // Bumped by EntryAbility.onNewWant when the "exit fullscreen" notification is tapped.
  @StorageLink('scExitFullscreen') @Watch('onExitFsRequest') private exitFsReq: number = 0;
  private imeCtrl: TextInputController = new TextInputController();
  private kbd: KeyboardHandler | null = null;   // physical + soft keyboard → Mac (owns metaHeld)
  private env: AppEnvironment | null = null;    // composition root (selects the role engine)
  private manager: ConnectionManager | null = null;   // connection lifecycle (from env)
  private router: InputRouter | null = null;   // owns pen + trackpad + finger input (FSMs)
  private readonly port: number = 8888;

  private ctx(): common.UIAbilityContext { return getContext(this) as common.UIAbilityContext; }

  aboutToAppear(): void {
    // HDR capability probe (decisive gate): log the HW HEVC decoder's 10-bit/HDR support.
    try {
      hilog.info(0x0, 'SCDIAG', 'hdrDecodeCaps=%{public}d supportsHevc=%{public}d',
                 sc.hdrDecodeCaps(), sc.supportsHevc() ? 1 : 0);
    } catch (e) { this.appendLog('hdrProbe ' + JSON.stringify(e)); }
    // Start windowed; ask once for notification permission (used by the fullscreen exit action).
    WindowMode.apply(this.ctx(), DisplayMode.Windowed, (m: string): void => { this.appendLog(m); });
    FullscreenNotification.enable(this.ctx(), (m: string): void => { this.appendLog(m); });
    // Composition root selects the role engine (Receiver today); the manager owns the
    // connection lifecycle. The page just binds the view state it shows.
    this.env = new AppEnvironment(this.port);
    const mgr: ConnectionManager = this.env.manager;
    this.manager = mgr;
    mgr.onLog = (msg: string): void => { this.appendLog(msg); };
    mgr.onStatus = (s: ConnectionStatus): void => {
      this.connStatus = s;
      // Stream ended while fullscreen → drop back to the windowed window state.
      if (s !== ConnectionStatus.Streaming && this.displayMode === DisplayMode.Fullscreen) {
        this.exitFullscreen();
      }
    };
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

  private streaming(): boolean { return this.connStatus === ConnectionStatus.Streaming; }
  private windowed(): boolean { return this.streaming() && this.displayMode === DisplayMode.Windowed; }
  private fullscreen(): boolean { return this.streaming() && this.displayMode === DisplayMode.Fullscreen; }

  // Windowed preview box: fit the Mac aspect (fallback 16:10) within ~72% of the panel.
  private aspect(): number { return (this.vWidth > 0 && this.vHeight > 0) ? this.vWidth / this.vHeight : 1.6; }
  private windowedW(): number {
    const maxW: number = this.surfaceW * 0.72;
    const maxH: number = this.surfaceH * 0.72;
    return (maxW / this.aspect() <= maxH) ? maxW : maxH * this.aspect();
  }
  private windowedH(): number {
    const maxW: number = this.surfaceW * 0.72;
    const maxH: number = this.surfaceH * 0.72;
    return (maxW / this.aspect() <= maxH) ? maxW / this.aspect() : maxH;
  }

  private enterFullscreen(): void {
    this.displayMode = DisplayMode.Fullscreen;
    WindowMode.apply(this.ctx(), DisplayMode.Fullscreen, (m: string): void => { this.appendLog(m); });
    FullscreenNotification.show(this.ctx(), (m: string): void => { this.appendLog(m); });
    this.refocusIme();   // entering fullscreen mounts the IME catcher — make sure it owns the keyboard
  }

  // Give keyboard focus back to the hidden IME catcher. defaultFocus(true) only fires on the page's
  // first focus pass, NOT when the catcher is (re)mounted on entering fullscreen, and the control
  // panel's buttons/toggles steal focus while open — so we re-request it explicitly. Deferred so it
  // runs AFTER the current view update (panel unmount / window-mode transition), else focus can
  // bounce back to a just-removed control. Without this the soft keyboard never pops and
  // onKeyPreIme never fires (physical keys dead) — the #53 windowed-mode regression. (#kbd-focus)
  private refocusIme(): void {
    if (!this.streaming()) { return; }
    setTimeout((): void => { focusControl.requestFocus('imecatcher'); }, 50);
  }

  private exitFullscreen(): void {
    this.displayMode = DisplayMode.Windowed;
    WindowMode.apply(this.ctx(), DisplayMode.Windowed, (m: string): void => { this.appendLog(m); });
    FullscreenNotification.cancel((m: string): void => { this.appendLog(m); });
  }

  // Watcher for the notification "exit fullscreen" action (AppStorage bump from EntryAbility).
  private onExitFsRequest(): void {
    if (this.fullscreen()) { this.exitFullscreen(); }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // Base layer: dark backdrop + tracks the full panel size (used to lay out the small preview
      // and to keep the floating ball on-screen).
      Column()
        .width('100%').height('100%')
        .backgroundColor('#FF0B0E14')
        .onAreaChange((_o: Area, n: Area) => {
          this.surfaceW = Number(n.width);
          this.surfaceH = Number(n.height);
          if (this.surfaceW <= 0 || this.surfaceH <= 0) { return; }
          if (this.ballX === 0 && this.ballY === 0) {
            this.ballX = this.surfaceW - 56 - 12;
            this.ballY = this.surfaceH / 2 - 28;
          } else {
            this.ballX = Math.min(Math.max(this.ballX, 12), this.surfaceW - 56 - 12);
            this.ballY = Math.min(Math.max(this.ballY, 12), this.surfaceH - 56 - 12);
          }
        })

      // The Mac screen renders here — always mounted (so the decoder surface persists); its size
      // is the full panel in fullscreen, or a centered preview box in windowed mode.
      XComponent({ id: 'sc_surface', type: XComponentType.SURFACE, libraryname: 'superconnect' })
        .onLoad(() => { this.appendLog('XComponent surface loaded'); })
        .width(this.windowed() ? this.windowedW() : '100%')
        .height(this.windowed() ? this.windowedH() : '100%')
        .borderRadius(this.windowed() ? 14 : 0)

      // ── Fullscreen: input capture + IME + floating ball + control panel (today's behavior) ──
      if (this.fullscreen()) {
        // Transparent layer ON TOP that reliably captures touch in ArkTS.
        Column()
          .width('100%').height('100%').backgroundColor('#00000000')
          .hitTestBehavior(this.inputDisabled ? HitTestMode.None : HitTestMode.Block)
          .onTouch((e: TouchEvent) => { this.router?.onTouch(e); })
          .onMouse((e: MouseEvent) => { this.router?.onMouse(e); })        // trackpad cursor/click/drag
          .onAxisEvent((e: AxisEvent) => { this.router?.onAxis(e); })      // trackpad scroll/pinch
          .focusable(false)   // never steal key focus from the hidden IME catcher

        // Hidden, focused TextInput that owns the physical keyboard.
        TextInput({ text: this.imeText, controller: this.imeCtrl })
          .id('imecatcher')
          .focusable(true)
          .defaultFocus(true)
          .opacity(0)
          .width(1)
          .height(1)
          .onAppear(() => { this.refocusIme(); })   // grab the keyboard the moment we enter fullscreen (#kbd-focus)
          .onKeyPreIme((e: KeyEvent): boolean => {
            return this.kbd?.onKeyPreIme(e) ?? false;   // physical keys → Mac
          })
          .onWillInsert((info: InsertValue): boolean => {
            return this.kbd?.onWillInsert(info) ?? false;
          })
          .onChange((value: string, preview?: PreviewText): void => {
            this.kbd?.onCommit(value, preview);   // 3rd-party IME commit → Mac
            this.imeText = '';
            this.imeCtrl.caretPosition(0);
          })
          .onWillDelete((info: DeleteValue): boolean => {
            return this.kbd?.onWillDelete(info) ?? false;   // soft backspace/del → Mac keystroke
          })

        // Paused banner — safe way back when input capture is paused.
        if (this.inputDisabled) {
          PausedBanner({ surfaceW: this.surfaceW, onResume: () => { this.setInputDisabled(false); } })
        }

        // Floating control — tap = drawing toggle, long-press = open the control panel.
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
      }

      // ── Windowed: small preview chrome + double-tap to enter fullscreen ──
      if (this.windowed()) {
        WindowedView({
          statusText: statusLabel(this.connStatus),
          onEnterFullscreen: () => { this.enterFullscreen(); },
        })
      }

      // ── Idle (not streaming): status / how-to-connect ──
      if (!this.streaming()) {
        IdleView({
          statusText: statusLabel(this.connStatus),
          statusDot: statusColor(this.connStatus),
          port: this.port,
          onOpenPanel: () => { this.showPanel = true; },
        })
      }

      // Control panel — top-most overlay (openable when idle or in fullscreen).
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
          showExitFullscreen: this.fullscreen(),
          onToggleInput: (v: boolean) => { this.setInputDisabled(v); },
          onExitFullscreen: () => { this.exitFullscreen(); },
          onClose: () => { this.showPanel = false; this.refocusIme(); },   // panel buttons stole focus → give it back (#kbd-focus)
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
    if (!v) { this.refocusIme(); }   // resuming capture → return keyboard focus to the IME catcher (#kbd-focus)
  }

}
