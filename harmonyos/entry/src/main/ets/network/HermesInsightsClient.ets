import http from '@ohos.net.http';

export interface UsageSummary {
  totalTokens: number;
  promptTokens: number;
  completionTokens: number;
  totalCostUsd?: number;
}

export interface ModelUsageItem {
  model: string;
  calls: number;
  totalTokens: number;
  costUsd?: number;
}

/**
 * Hermes 统计分析与记忆客户端
 * 严格对齐 HermesInsightsClient.swift 与 /api/analytics/*
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
   * 拉取用量总计：GET /api/analytics/usage
   */
  public static async getUsageSummary(
    baseUrl: string,
    profile?: string,
    token?: string,
    cookies?: string
  ): Promise<UsageSummary> {
    const cleanUrl = HermesInsightsClient.sanitizeUrl(baseUrl);
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

      const query = profile ? `?profile=${encodeURIComponent(profile)}` : '';
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

      return {
        totalTokens: Number(parsed['total_tokens'] || 0),
        promptTokens: Number(parsed['prompt_tokens'] || 0),
        completionTokens: Number(parsed['completion_tokens'] || 0),
        totalCostUsd: typeof parsed['cost_usd'] === 'number' ? Number(parsed['cost_usd']) : undefined
      };
    } finally {
      client.destroy();
    }
  }

  /**
   * 拉取模型用量明细：GET /api/analytics/models
   */
  public static async getModelUsageList(
    baseUrl: string,
    profile?: string,
    token?: string,
    cookies?: string
  ): Promise<ModelUsageItem[]> {
    const cleanUrl = HermesInsightsClient.sanitizeUrl(baseUrl);
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

      const query = profile ? `?profile=${encodeURIComponent(profile)}` : '';
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
          model: String(row['model'] || row['name'] || '未知模型'),
          calls: Number(row['calls'] || 0),
          totalTokens: Number(row['total_tokens'] || 0),
          costUsd: typeof row['cost_usd'] === 'number' ? Number(row['cost_usd']) : undefined
        });
      }

      return list;
    } finally {
      client.destroy();
    }
  }
}
