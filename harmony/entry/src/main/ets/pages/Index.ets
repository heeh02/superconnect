import { InputRouter } from '../input/InputRouter';
import { KeyboardHandler } from '../input/KeyboardHandler';
import { ConnectionManager } from '../services/ConnectionManager';
import { AppEnvironment } from '../app/AppEnvironment';
import { ConnectionStatus, statusLabel, statusColor } from '../models/ConnectionStatus';
import { DisplayMode } from '../models/DisplayMode';
import { StreamInfo } from '../models/StreamInfo';
import { WindowController } from '../services/WindowController';
import { FloatingBall } from '../components/FloatingBall';
import { IdleView } from '../ui/IdleView';
import { ControlPanel } from '../ui/ControlPanel';
import { PausedBanner } from '../ui/PausedBanner';
import { WindowedView } from '../ui/WindowedView';
import { ImeCatcher } from '../ui/ImeCatcher';
import { InputOverlay } from '../ui/InputOverlay';
import { RestoreHandle } from '../ui/RestoreHandle';
import { PairingDialog } from '../ui/PairingDialog';
import { StatusBanner } from '../ui/StatusBanner';
import { FirstRunHints } from '../ui/FirstRunHints';
import { TrustedPeer } from '../services/wireless/PairingStore';
import { BallGeometry, BallPos } from '../components/BallGeometry';
import { common } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
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
  // GUI state
  @State private showPanel: boolean = false;   // control panel (settings / cheat-sheet / toggles)
  @State private firstRunHints: boolean = false; // one-time coach bubble on first fullscreen entry
  @State private ballHidden: boolean = false;  // quick toggle: hide the floating ball
  @State private inputDisabled: boolean = false; // pause capture → let the tablet's own UI work
  @State private vWidth: number = 0;           // live stream resolution / codec (from video_config)
  @State private vHeight: number = 0;
  @State private vCodec: string = '';
  // Wireless (Wi‑Fi LAN) mode — owned by AppEnvironment.wireless; mirrored here for the UI toggle.
  @State private wirelessOn: boolean = false;
  @State private wifiIp: string = '';   // tablet's Wi‑Fi IPv4 for manual connect ('' if not on Wi‑Fi)
  @State private pairingVisible: boolean = false;   // TOFU prompt showing?
  @State private pairingName: string = '';          // the requesting Mac's name (for the prompt)
  @State private pairingPromptId: number = 0;        // id binding this dialog to its prompt (anti-swap)
  @State private listenPort: number = 8888;          // ACTUAL bound port (8888 preferred; may fall back)
  @State private pairedPeers: TrustedPeer[] = [];            // trusted Macs (shown in the control panel)
  // Bumped by EntryAbility.onNewWant when the "exit fullscreen" notification is tapped.
  @StorageLink('scExitFullscreen') @Watch('onExitFsRequest') private exitFsReq: number = 0;
  private kbd: KeyboardHandler | null = null;   // physical + soft keyboard → Mac (owns metaHeld)
  private env: AppEnvironment | null = null;    // composition root (selects the role engine)
  private manager: ConnectionManager | null = null;   // connection lifecycle (from env)
  private router: InputRouter | null = null;   // owns pen + trackpad + finger input (FSMs)
  private windowCtl: WindowController | null = null;   // window-layout + fullscreen-notification side-effects
  private uiPrefs: preferences.Preferences | null = null;   // UI-only prefs (first-run hint "seen" flag)
  private readonly port: number = 8888;

  private ctx(): common.UIAbilityContext { return getContext(this) as common.UIAbilityContext; }

  aboutToAppear(): void {
    // HDR capability probe (decisive gate): log the HW HEVC decoder's 10-bit/HDR support.
    try {
      hilog.info(0x0, 'SCDIAG', 'hdrDecodeCaps=%{public}d supportsHevc=%{public}d',
                 sc.hdrDecodeCaps(), sc.supportsHevc() ? 1 : 0);
    } catch (e) { this.appendLog('hdrProbe ' + JSON.stringify(e)); }
    // Start windowed; ask once for notification permission (used by the fullscreen exit action).
    this.windowCtl = new WindowController(this.ctx(), (m: string): void => { this.appendLog(m); });
    this.windowCtl.start();
    // UI-only prefs (the first-run coach bubble's "seen" flag). View-layer state, not a service.
    try { this.uiPrefs = preferences.getPreferencesSync(this.ctx(), { name: 'sc_ui' }); }
    catch (e) { this.appendLog('uiPrefs ' + JSON.stringify(e)); }
    // Composition root selects the role engine (Receiver today); the manager owns the
    // connection lifecycle. The page just binds the view state it shows.
    this.env = new AppEnvironment(this.port, this.ctx());
    const mgr: ConnectionManager = this.env.manager;
    this.manager = mgr;
    // Reflect the persisted wireless state + current Wi‑Fi IP into the UI.
    this.wirelessOn = this.env.wireless.enabled();
    this.wifiIp = this.env.wireless.wifiIpv4();
    // TOFU pairing prompts from LAN clients surface here as a 允许/拒绝 dialog.
    this.env.wireless.onPairingRequest = (peerId: string, deviceName: string, promptId: number): void => {
      this.pairingName = deviceName;
      this.pairingPromptId = promptId;
      this.pairingVisible = true;
    };
    this.env.wireless.onPairingDismiss = (): void => { this.pairingVisible = false; };
    // Reflect the actual bound port (8888 preferred; falls back if occupied) into the UI.
    this.env.wireless.onPortChange = (port: number): void => { this.listenPort = port; };
    const p: number = this.env.wireless.currentPort();
    if (p > 0) { this.listenPort = p; }
    mgr.onLog = (msg: string): void => { this.appendLog(msg); };
    mgr.onStatus = (s: ConnectionStatus): void => {
      this.connStatus = s;
      // Auto-exit fullscreen ONLY on a TERMINAL status (session truly gone/failed), NOT on every
      // non-Streaming value. Display-mode and link-state are two separate concerns: a transient
      // ClientGone→Listening blip (e.g. a Wi-Fi roam, or the single-active guard rejecting a 2nd
      // client) must NOT yank the user out of fullscreen — that conflation is the same one-signal-
      // two-concerns trap behind the earlier keyboard/touch regressions. See docs/MODULARITY_AUDIT.md.
      if ((s === ConnectionStatus.Failed || s === ConnectionStatus.Idle)
          && this.displayMode === DisplayMode.Fullscreen) {
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
    this.env?.wireless.dispose();   // stop mDNS advertising + clear any pending pairing prompt
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
    this.windowCtl?.enterFullscreen();
    // ImeCatcher grabs focus itself when `active` flips true — no manual refocus needed here.
    // First fullscreen ever → show the one-time coach bubble (✎/↖ + double-tap). UI pref, not a service.
    try {
      if (this.uiPrefs !== null && (this.uiPrefs.getSync('seenFullscreenHints', false) as boolean) === false) {
        this.firstRunHints = true;
      }
    } catch (e) { this.appendLog('hints flag ' + JSON.stringify(e)); }
  }

  // Dismiss the first-run coach bubble and remember it (so it shows only once).
  private dismissFirstRunHints(): void {
    this.firstRunHints = false;
    if (this.uiPrefs === null) { return; }
    try {
      this.uiPrefs.putSync('seenFullscreenHints', true);
      this.uiPrefs.flush().then((): void => {}).catch((e: Object): void => {
        hilog.warn(0x0, 'SCDIAG', 'uiPrefs flush failed %{public}s', JSON.stringify(e));
      });
    } catch (e) { this.appendLog('hints save ' + JSON.stringify(e)); }
    this.refocusIme();   // the bubble's button took focus → give it back to the IME catcher (#kbd-focus)
  }

  // Re-assert keyboard focus after a focus-stealing modal (control panel / paused banner) closes.
  // The ImeCatcher stays mounted while streaming and self-focuses on (re)mount + on becoming active,
  // so this is ONLY for the modal case (those controls take focus while open, the catcher doesn't
  // remount). Deferred so it runs after the modal is actually torn down.
  private refocusIme(): void {
    if (!this.fullscreen()) { return; }
    setTimeout((): void => { focusControl.requestFocus(ImeCatcher.ID); }, 50);
  }

  private exitFullscreen(): void {
    this.displayMode = DisplayMode.Windowed;
    this.windowCtl?.exitFullscreen();
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
          // First time → seed at the right edge; afterwards keep it on-screen. Math owned by BallGeometry.
          const p: BallPos = (this.ballX === 0 && this.ballY === 0)
            ? BallGeometry.seed(this.surfaceW, this.surfaceH)
            : BallGeometry.clamp(this.ballX, this.ballY, this.surfaceW, this.surfaceH);
          this.ballX = p.x;
          this.ballY = p.y;
        })

      // The Mac screen renders here — always mounted (so the decoder surface persists); its size
      // is the full panel in fullscreen, or a centered preview box in windowed mode.
      XComponent({ id: 'sc_surface', type: XComponentType.SURFACE, libraryname: 'superconnect' })
        .onLoad(() => { this.appendLog('XComponent surface loaded'); })
        .width(this.windowed() ? this.windowedW() : '100%')
        .height(this.windowed() ? this.windowedH() : '100%')
        .borderRadius(this.windowed() ? 14 : 0)

      // Keyboard capture — mounted for the WHOLE streaming session (NOT gated on fullscreen), so a
      // display-mode change can never unmount it again (the #53 coupling that killed the keyboard).
      // `active` = fullscreen drives focus only, never mounting.
      if (this.streaming()) {
        ImeCatcher({ kbd: this.kbd, active: this.fullscreen() })
      }

      // ── Fullscreen: input capture + floating ball + control panel ──
      if (this.fullscreen()) {
        // Touch + trackpad capture — its own module, mounted on top to grab events.
        InputOverlay({ router: this.router, disabled: this.inputDisabled })

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
            onMenu: () => { this.openPanel(); },
          })
        }
        // Tiny restore handle when the ball is hidden.
        if (this.surfaceW > 0 && this.ballHidden) {
          RestoreHandle({ surfaceW: this.surfaceW, surfaceH: this.surfaceH, onRestore: () => { this.ballHidden = false; } })
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
          port: this.listenPort,
          wirelessOn: this.wirelessOn,
          wifiIp: this.wifiIp,
          onToggleWireless: (v: boolean) => { this.setWireless(v); },
          onOpenPanel: () => { this.openPanel(); },
        })

        // Transitional banner (listening / connecting / reconnecting) anchored to the top, so the
        // idle→streaming jump isn't silent. Reads existing state only (status + the requesting peer name).
        Column() {
          StatusBanner({ status: this.connStatus, peerName: this.pairingName })
        }
        .width('100%').height('100%')
        .padding({ top: 28 })
        .justifyContent(FlexAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // Control panel — top-most overlay (openable when idle or in fullscreen).
      if (this.showPanel) {
        ControlPanel({
          statusText: statusLabel(this.connStatus),
          port: this.listenPort,
          vWidth: this.vWidth,
          vHeight: this.vHeight,
          vCodec: this.vCodec,
          wirelessOn: this.wirelessOn,
          wifiIp: this.wifiIp,
          onToggleWireless: (v: boolean) => { this.setWireless(v); },
          pairedPeers: this.pairedPeers,
          onForgetPeer: (peerId: string) => { this.forgetPeer(peerId); },
          isDrawingMode: $isDrawingMode,
          ballHidden: $ballHidden,
          inputDisabled: this.inputDisabled,
          showExitFullscreen: this.fullscreen(),
          onToggleInput: (v: boolean) => { this.setInputDisabled(v); },
          onExitFullscreen: () => { this.exitFullscreen(); },
          onClose: () => { this.showPanel = false; this.refocusIme(); },   // panel buttons stole focus → give it back (#kbd-focus)
        })
      }

      // TOFU pairing prompt — top-most, shown for an unknown LAN device until the user answers.
      if (this.pairingVisible) {
        PairingDialog({
          deviceName: this.pairingName,
          onAllow: () => { this.respondPairing(true); },
          onDeny: () => { this.respondPairing(false); },
        })
      }

      // First-run coach bubble — one-time overlay on the first fullscreen entry (✎/↖ + double-tap).
      // MUST sit ABOVE the InputOverlay (HitTestMode.Block) or its touches get swallowed; the backdrop +
      // card live in ONE high-zIndex Stack (card on top) and BOTH dismiss, so it can never trap the user.
      if (this.firstRunHints && this.fullscreen()) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%').height('100%').backgroundColor('#90000000')
            .onClick(() => { this.dismissFirstRunHints(); })   // tap anywhere outside the card to dismiss
          FirstRunHints({ onDismiss: () => { this.dismissFirstRunHints(); } })
        }
        .width('100%').height('100%').zIndex(100)   // above input capture / floating ball / panel
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

  // Toggle Wi‑Fi LAN mode: WirelessService persists the choice + rebinds the listener (127.0.0.1 ↔
  // 0.0.0.0); we refresh the shown IP. Wired (USB) connections are unaffected either way.
  private setWireless(v: boolean): void {
    this.env?.wireless.setEnabled(v);
    this.wirelessOn = v;
    this.wifiIp = this.env?.wireless.wifiIpv4() ?? '';
    this.appendLog('wireless ' + (v ? 'ON (0.0.0.0)' : 'OFF (127.0.0.1)') + (v && this.wifiIp !== '' ? ' ip=' + this.wifiIp : ''));
  }

  // Open the control panel, refreshing the live IP + paired-device list first.
  private openPanel(): void {
    this.wifiIp = this.env?.wireless.wifiIpv4() ?? '';
    this.pairedPeers = this.env?.wireless.pairedPeers() ?? [];
    this.showPanel = true;
  }

  // User answered the TOFU prompt (allow → remember + handshake proceeds; deny → refuse this run).
  // The promptId binds the answer to the dialog that was shown — a stale tap is ignored by WirelessService.
  private respondPairing(allow: boolean): void {
    this.env?.wireless.respondPairing(this.pairingPromptId, allow);
    this.pairingVisible = false;
  }

  // Forget a previously-trusted Mac (it must re-pair next time).
  private forgetPeer(peerId: string): void {
    this.env?.wireless.forgetPeer(peerId);
    this.pairedPeers = this.env?.wireless.pairedPeers() ?? [];
  }

}
