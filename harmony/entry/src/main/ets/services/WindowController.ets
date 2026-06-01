import { common } from '@kit.AbilityKit';
import { DisplayMode } from '../models/DisplayMode';
import { WindowMode } from './WindowMode';
import { FullscreenNotification } from './FullscreenNotification';

/**
 * WindowController — owns the system-window + fullscreen-exit-notification side-effects for a
 * display-mode transition. Previously Index.ets smeared the `WindowMode.apply(...)` +
 * `FullscreenNotification.{enable,show,cancel}` pairing across aboutToAppear / enterFullscreen /
 * exitFullscreen (the same closure, the same calls, three times). Now one object owns that pairing.
 *
 * It does NOT own `displayMode` — that stays page @State (it drives build()); the page sets the
 * mode then calls the matching method here, so the window side-effects can't drift from the layout.
 */
export class WindowController {
  private ctx: common.UIAbilityContext;
  private onLog: (m: string) => void;

  constructor(ctx: common.UIAbilityContext, onLog: (m: string) => void) {
    this.ctx = ctx;
    this.onLog = onLog;
  }

  /** App launch: windowed layout + register the fullscreen-exit notification capability. */
  start(): void {
    WindowMode.apply(this.ctx, DisplayMode.Windowed, this.onLog);
    FullscreenNotification.enable(this.ctx, this.onLog);
  }

  /** Enter immersive fullscreen + post the "exit fullscreen" notification. */
  enterFullscreen(): void {
    WindowMode.apply(this.ctx, DisplayMode.Fullscreen, this.onLog);
    FullscreenNotification.show(this.ctx, this.onLog);
  }

  /** Back to the windowed layout + clear the notification. */
  exitFullscreen(): void {
    WindowMode.apply(this.ctx, DisplayMode.Windowed, this.onLog);
    FullscreenNotification.cancel(this.onLog);
  }
}
