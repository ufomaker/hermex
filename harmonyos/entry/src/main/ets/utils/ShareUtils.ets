import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import systemShare from '@hms.collaboration.systemShare';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InboundShareData } from './DeepLinkUtils';

const TAG = 'ShareUtils';

/**
 * 鸿蒙系统分享接入工具 (F10)
 * 优先采用官方 SystemShare Kit (ShareController / SharedData)，并降级至 startAbility
 */
export class ShareUtils {
  /**
   * 调起系统分享面板分享文本
   */
  public static async shareText(
    context: common.UIAbilityContext,
    text: string,
    title: string = '分享文本'
  ): Promise<boolean> {
    if (!text || text.trim().length === 0) {
      return false;
    }

    try {
      const shareRecord: systemShare.SharedRecord = {
        utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
        content: text,
        title: title
      };
      const sharedData = new systemShare.SharedData(shareRecord);
      const controller = new systemShare.ShareController(sharedData);
      await controller.show(context, {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
      hilog.info(0x0000, TAG, 'System shareText shown successfully');
      return true;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'systemShare.ShareController failed, falling back to Want: %{public}s', JSON.stringify(e));
      try {
        const want: Want = {
          action: 'ohos.want.action.sendData',
          type: 'text/plain',
          parameters: {
            'ability.params.stream': text,
            'content': text,
            'title': title
          }
        };
        await context.startAbility(want);
        return true;
      } catch (err) {
        hilog.error(0x0000, TAG, 'shareText want fallback failed: %{public}s', JSON.stringify(err));
        return false;
      }
    }
  }

  /**
   * 调起系统分享面板分享文件/图片
   */
  public static async shareFile(
    context: common.UIAbilityContext,
    uriOrPath: string,
    mimeType: string = '*/*'
  ): Promise<boolean> {
    if (!uriOrPath || uriOrPath.trim().length === 0) {
      return false;
    }

    try {
      const shareRecord: systemShare.SharedRecord = {
        utd: uniformTypeDescriptor.UniformDataType.FILE,
        uri: uriOrPath,
        title: '分享文件'
      };
      const sharedData = new systemShare.SharedData(shareRecord);
      const controller = new systemShare.ShareController(sharedData);
      await controller.show(context, {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
      hilog.info(0x0000, TAG, 'System shareFile shown successfully');
      return true;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'systemShare.ShareController file failed, falling back to Want: %{public}s', JSON.stringify(e));
      try {
        const want: Want = {
          action: 'ohos.want.action.sendData',
          type: mimeType,
          uri: uriOrPath
        };
        await context.startAbility(want);
        return true;
      } catch (err) {
        hilog.error(0x0000, TAG, 'shareFile want fallback failed: %{public}s', JSON.stringify(err));
        return false;
      }
    }
  }

  /**
   * 解析由外部应用分享传入本应用的 Want 数据
   */
  public static parseShareWant(want: Want): InboundShareData | null {
    if (!want) {
      return null;
    }

    const action = want.action;
    if (action !== 'ohos.want.action.sendData') {
      return null;
    }

    let sharedText: string | undefined = undefined;
    let sharedUri: string | undefined = undefined;
    const mimeType = want.type;

    if (want.parameters) {
      const p = want.parameters as Record<string, Object>;
      if (typeof p['ability.params.stream'] === 'string') {
        sharedText = p['ability.params.stream'] as string;
      } else if (typeof p['content'] === 'string') {
        sharedText = p['content'] as string;
      } else if (typeof p['android.intent.extra.TEXT'] === 'string') {
        sharedText = p['android.intent.extra.TEXT'] as string;
      }
    }

    if (want.uri) {
      sharedUri = want.uri;
    }

    if (sharedText || sharedUri) {
      return {
        text: sharedText,
        uri: sharedUri,
        type: mimeType
      };
    }

    return null;
  }
}
