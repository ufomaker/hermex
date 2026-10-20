import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AuthStore } from '../storage/AuthStore';
import { DeepLinkUtils, AppDeepLinkRouter } from '../utils/DeepLinkUtils';
import { ShareUtils } from '../utils/ShareUtils';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    AuthStore.getInstance().init(this.context);
    this.handleIncomingWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onNewWant');
    this.handleIncomingWant(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    AppStorage.setOrCreate('appScenePhase', 'active');
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground: active');
  }

  onBackground(): void {
    AppStorage.setOrCreate('appScenePhase', 'background');
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground: background');
  }

  private handleIncomingWant(want: Want): void {
    if (!want) return;

    // 1. 处理深层链接 (Deep Link: hermex:// 或 hermes-agent://) - 脱敏日志，绝不输出敏感参数
    if (want.uri) {
      const scheme = want.uri.split('://')[0] || 'unknown';
      hilog.info(DOMAIN, TAG, 'Handling incoming URI with scheme: %{public}s', scheme);
      const route = DeepLinkUtils.parseDeepLink(want.uri);
      if (route) {
        hilog.info(DOMAIN, TAG, 'Deep link route parsed: %{public}s', route.type);
        AppDeepLinkRouter.getInstance().setPendingRoute(route);
      }
    }

    // 2. 处理系统分享 (Share: ohos.want.action.sendData) - 脱敏日志，仅记录存在性与类型
    if (want.action === 'ohos.want.action.sendData') {
      hilog.info(DOMAIN, TAG, 'Handling incoming share action');
      const share = ShareUtils.parseShareWant(want);
      if (share) {
        hilog.info(DOMAIN, TAG, 'Inbound share parsed: hasText=%{public}s, hasUri=%{public}s',
          share.text ? 'true' : 'false', share.uri ? 'true' : 'false');
        AppDeepLinkRouter.getInstance().setPendingShare(share);
      }
    }
  }
}
