import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { DisplayMode } from '../models/DisplayMode';

// WindowMode — applies the system-window state for a DisplayMode so the page never touches window
// APIs directly. Fullscreen = immersive (layout under + hide system bars); Windowed = bars visible.
export class WindowMode {
  static apply(context: common.UIAbilityContext, mode: DisplayMode, onLog?: (msg: string) => void): void {
    const fullscreen: boolean = mode === DisplayMode.Fullscreen;
    window.getLastWindow(context).then((win: window.Window): void => {
      win.setWindowLayoutFullScreen(fullscreen).catch((e: Object): void => { onLog?.('layoutFullScreen ' + JSON.stringify(e)); });
      const bars: Array<'status' | 'navigation'> = fullscreen ? [] : ['status', 'navigation'];
      win.setWindowSystemBarEnable(bars).catch((e: Object): void => { onLog?.('systemBar ' + JSON.stringify(e)); });
    }).catch((e: Object): void => { onLog?.('getLastWindow ' + JSON.stringify(e)); });
  }
}
