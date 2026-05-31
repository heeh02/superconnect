import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent, common, Want } from '@kit.AbilityKit';

const NOTIFICATION_ID: number = 4201;

// FullscreenNotification — a persistent "tap to exit fullscreen" notification. Its action re-foregrounds
// EntryAbility with scAction=exitFullscreen (handled in EntryAbility.onNewWant), giving the user a way
// out of immersive mode from the notification shade. Keeps notification/WantAgent logic out of the page.
export class FullscreenNotification {
  // Ask once for notification permission (modal prompt attached to the ability).
  static enable(context: common.UIAbilityContext, onLog?: (msg: string) => void): void {
    notificationManager.requestEnableNotification(context).catch((e: Object): void => { onLog?.('notifyEnable ' + JSON.stringify(e)); });
  }

  static show(context: common.UIAbilityContext, onLog?: (msg: string) => void): void {
    const target: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: 'EntryAbility',
      parameters: { 'scAction': 'exitFullscreen' } as Record<string, Object>,
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [target],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    wantAgent.getWantAgent(info).then((agent: WantAgent): void => {
      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: 'Superconnect 投屏中', text: '点此退出全屏，返回小窗' },
        },
        wantAgent: agent,
      };
      notificationManager.publish(request).catch((e: Object): void => { onLog?.('notifyPublish ' + JSON.stringify(e)); });
    }).catch((e: Object): void => { onLog?.('wantAgent ' + JSON.stringify(e)); });
  }

  static cancel(onLog?: (msg: string) => void): void {
    notificationManager.cancel(NOTIFICATION_ID).catch((e: Object): void => { onLog?.('notifyCancel ' + JSON.stringify(e)); });
  }
}
