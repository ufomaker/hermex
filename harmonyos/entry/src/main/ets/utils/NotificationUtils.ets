import notificationManager from '@ohos.notificationManager';

/**
 * 鸿蒙平台系统通知与后台提示工具类 (F10)
 * 封装系统通知发布、审批提醒、任务完成通知，具备容错与跨平台降级保护
 */
export class NotificationUtils {
  private static nextNotificationId: number = 2000;

  /**
   * 检查通知能力是否可用
   */
  public static async isNotificationEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (_e) {
      return false;
    }
  }

  /**
   * 发送基础文本通知
   */
  public static async publishNotification(
    title: string,
    text: string,
    notificationId?: number
  ): Promise<boolean> {
    try {
      const id = notificationId || ++NotificationUtils.nextNotificationId;
      const request: notificationManager.NotificationRequest = {
        id: id,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: 'Hermex'
          }
        }
      };
      await notificationManager.publish(request);
      return true;
    } catch (_e) {
      return false;
    }
  }

  /**
   * 提示用户存在需要审批的命令或工具调用
   */
  public static async notifyApprovalRequired(command?: string, tool?: string): Promise<void> {
    const detail = command ? `待执行命令: ${command}` : `请求工具: ${tool || '终端'}`;
    await NotificationUtils.publishNotification('需要审批操作', `Hermes 正在等待审批：${detail}`);
  }

  /**
   * 提示后台生成或多轮任务已完成
   */
  public static async notifyTurnComplete(summary?: string): Promise<void> {
    const detail = summary || 'Agent 任务已完成';
    await NotificationUtils.publishNotification('任务完成', detail);
  }

  /**
   * 取消指定通知
   */
  public static async cancelNotification(notificationId: number): Promise<void> {
    try {
      await notificationManager.cancel(notificationId);
    } catch (_e) {
      // 容错忽略
    }
  }
}
