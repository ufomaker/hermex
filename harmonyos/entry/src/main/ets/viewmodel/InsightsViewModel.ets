import { HermesInsightsClient, UsageSummary, ModelUsageItem } from '../network/HermesInsightsClient';
import { BotConnection } from '../model/Connection';

export class InsightsViewModel {
  public usage: UsageSummary | null = null;
  public modelStats: ModelUsageItem[] = [];
  public isLoading: boolean = false;
  public statusMessage: string = '';

  public async loadInsights(conn: BotConnection, days: number = 7): Promise<void> {
    this.isLoading = true;
    this.statusMessage = '正在读取统计用量...';
    const profile = conn.activeProfile || 'default';

    try {
      this.usage = await HermesInsightsClient.getUsageSummary(conn.url, days, profile, conn.token, conn.cookies);
      this.modelStats = await HermesInsightsClient.getModelUsageList(conn.url, days, profile, conn.token, conn.cookies);
      this.statusMessage = `统计加载完成 (最近 ${days} 天)`;
    } catch (e) {
      this.statusMessage = `读取用量失败: ${e}`;
    } finally {
      this.isLoading = false;
    }
  }
}
