import http from '@ohos.net.http';

/**
 * 用量汇总数据 (严格匹配 HermesREST.swift:671 与 analytics.json totals 结构)
 */
export interface UsageSummary {
  totalInputTokens: number;
  totalOutputTokens: number;
  totalReasoningTokens: number;
  totalApiCalls: number;
  totalActualCostUsd: number;
  totalEstimatedCostUsd: number;
  periodDays: number;
}

/**
 * 单模型用量明细 (严格匹配 HermesREST.swift:671 与 analytics.json models 结构)
 */
export interface ModelUsageItem {
  model: string;
  provider?: string;
  apiCalls: number;
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
  actualCostUsd: number;
  estimatedCostUsd: number;
}

/**
 * Hermes 统计分析与记忆客户端
 * 严格对齐 HermesREST.swift:671-680 (api/analytics/usage & api/analytics/models) 契约
 */
export class HermesInsightsClient {
  private static sanitizeUrl(base: string): string {
    let url = base.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /**
   * 拉取用量总计：GET /api/analytics/usage?days=<days>&profile=<profile>
   * 严格校验 days (1...365) 与 profile
   */
  public static async getUsageSummary(
    baseUrl: string,
    days: number = 30,
    profile: string = 'default',
    token?: string,
    cookies?: string
  ): Promise<UsageSummary> {
    const cleanUrl = HermesInsightsClient.sanitizeUrl(baseUrl);
    const validDays = Math.max(1, Math.min(365, days));
    const validProfile = profile || 'default';
    const client = http.createHttp();

    try {
      const headers: Record<string, string> = {
        'Accept': 'application/json'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      if (cookies && cookies.length > 0) {
        headers['Cookie'] = cookies;
      }

      const query = `?days=${validDays}&profile=${encodeURIComponent(validProfile)}`;
      const res = await client.request(`${cleanUrl}/api/analytics/usage${query}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`getUsageSummary failed with HTTP ${res.responseCode}`);
      }

      const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const totals = (parsed['totals'] as Record<string, Object>) || {};

      return {
        totalInputTokens: Number(totals['total_input'] || 0),
        totalOutputTokens: Number(totals['total_output'] || 0),
        totalReasoningTokens: Number(totals['total_reasoning'] || 0),
        totalApiCalls: Number(totals['total_api_calls'] || 0),
        totalActualCostUsd: Number(totals['total_actual_cost'] || 0),
        totalEstimatedCostUsd: Number(totals['total_estimated_cost'] || 0),
        periodDays: Number(parsed['period_days'] || validDays)
      };
    } finally {
      client.destroy();
    }
  }

  /**
   * 拉取模型用量明细：GET /api/analytics/models?days=<days>&profile=<profile>
   * 严格校验 days (1...365) 与 profile
   */
  public static async getModelUsageList(
    baseUrl: string,
    days: number = 30,
    profile: string = 'default',
    token?: string,
    cookies?: string
  ): Promise<ModelUsageItem[]> {
    const cleanUrl = HermesInsightsClient.sanitizeUrl(baseUrl);
    const validDays = Math.max(1, Math.min(365, days));
    const validProfile = profile || 'default';
    const client = http.createHttp();

    try {
      const headers: Record<string, string> = {
        'Accept': 'application/json'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      if (cookies && cookies.length > 0) {
        headers['Cookie'] = cookies;
      }

      const query = `?days=${validDays}&profile=${encodeURIComponent(validProfile)}`;
      const res = await client.request(`${cleanUrl}/api/analytics/models${query}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`getModelUsageList failed with HTTP ${res.responseCode}`);
      }

      const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const rawRows = Array.isArray(parsed['models']) ? (parsed['models'] as Array<Record<string, Object>>) : [];
      const list: ModelUsageItem[] = [];

      for (let i = 0; i < rawRows.length; i++) {
        const row = rawRows[i];
        list.push({
          model: String(row['model'] || '未知模型'),
          provider: row['provider'] ? String(row['provider']) : undefined,
          apiCalls: Number(row['api_calls'] || 0),
          inputTokens: Number(row['input_tokens'] || 0),
          outputTokens: Number(row['output_tokens'] || 0),
          reasoningTokens: Number(row['reasoning_tokens'] || 0),
          actualCostUsd: Number(row['actual_cost'] || 0),
          estimatedCostUsd: Number(row['estimated_cost'] || 0)
        });
      }

      return list;
    } finally {
      client.destroy();
    }
  }
}
