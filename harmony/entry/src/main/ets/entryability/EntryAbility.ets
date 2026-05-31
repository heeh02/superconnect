import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'Superconnect';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok');
      try {
        const win: window.Window = windowStage.getMainWindowSync();
        // Keep the screen awake while acting as an external display.
        win.setWindowKeepScreenOn(true).catch((e: Object) => {
          hilog.error(DOMAIN, TAG, 'keepScreenOn: %{public}s', JSON.stringify(e));
        });
        // Launch WINDOWED (small preview): keep the system bars and don't extend under them.
        // The page switches to immersive fullscreen on double-tap (see WindowMode / DisplayMode).
        win.setWindowLayoutFullScreen(false).catch((e: Object) => {
          hilog.error(DOMAIN, TAG, 'layoutFullScreen: %{public}s', JSON.stringify(e));
        });
        const bars: Array<'status' | 'navigation'> = ['status', 'navigation'];
        win.setWindowSystemBarEnable(bars).catch((e: Object) => {
          hilog.error(DOMAIN, TAG, 'systemBar: %{public}s', JSON.stringify(e));
        });
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'window setup failed: %{public}s', JSON.stringify(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  // Notification "exit fullscreen" action re-foregrounds this (singleton) ability with scAction.
  // Bump an AppStorage key the page watches → page returns to windowed.
  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    const params = want.parameters as Record<string, Object> | undefined;
    if (params && params['scAction'] === 'exitFullscreen') {
      AppStorage.setOrCreate('scExitFullscreen', Date.now());
    }
  }

  onForeground(): void {}

  onBackground(): void {}
}
