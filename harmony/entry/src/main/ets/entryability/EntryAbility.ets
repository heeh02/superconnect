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
        // Immersive full screen: extend layout under the system bars and hide
        // them, so the Mac screen fills the panel edge-to-edge.
        win.setWindowLayoutFullScreen(true).catch((e: Object) => {
          hilog.error(DOMAIN, TAG, 'layoutFullScreen: %{public}s', JSON.stringify(e));
        });
        const noBars: Array<'status' | 'navigation'> = [];
        win.setWindowSystemBarEnable(noBars).catch((e: Object) => {
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

  onForeground(): void {}

  onBackground(): void {}
}
