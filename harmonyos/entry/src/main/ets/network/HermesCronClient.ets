import http from '@ohos.net.http';

export interface CronJobItem {
  id: string;
  name: string;
  schedule: string;
  prompt: string;
  enabled: boolean;
  profile?: string;
  lastRunAt?: number;
  lastStatus?: string;
}

/**
 * Hermes 定时任务 (Cron) 客户端
 * 严格对齐 HermesCronClient.swift 与 /api/cron/*
 */
export class HermesCronClient {
  private static sanitizeUrl(base: string): string {
    let url = base.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /**
   * 拉取定时任务列表：GET /api/cron/jobs
   */
  public static async listCronJobs(
    baseUrl: string,
    token?: string,
    cookies?: string
  ): Promise<CronJobItem[]> {
    const cleanUrl = HermesCronClient.sanitizeUrl(baseUrl);
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

      const res = await client.request(`${cleanUrl}/api/cron/jobs`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`listCronJobs failed with HTTP ${res.responseCode}`);
      }

      const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const rawJobs = Array.isArray(parsed['jobs']) ? (parsed['jobs'] as Array<Record<string, Object>>) : [];
      const jobs: CronJobItem[] = [];

      for (let i = 0; i < rawJobs.length; i++) {
        const j = rawJobs[i];
        jobs.push({
          id: String(j['id'] || ''),
          name: String(j['name'] || '定时任务'),
          schedule: String(j['schedule'] || '* * * * *'),
          prompt: String(j['prompt'] || ''),
          enabled: Boolean(j['enabled']),
          profile: j['profile'] ? String(j['profile']) : undefined,
          lastRunAt: typeof j['last_run_at'] === 'number' ? Number(j['last_run_at']) : undefined,
          lastStatus: j['last_status'] ? String(j['last_status']) : undefined
        });
      }

      return jobs;
    } finally {
      client.destroy();
    }
  }

  /**
   * 手动触发执行指定定时任务：POST /api/cron/jobs/{id}/run?profile=<profile>
   */
  public static async runCronJob(
    baseUrl: string,
    jobId: string,
    profile?: string,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
    const cleanUrl = HermesCronClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();

    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      if (cookies && cookies.length > 0) {
        headers['Cookie'] = cookies;
      }

      const query = profile ? `?profile=${encodeURIComponent(profile)}` : '';
      const res = await client.request(`${cleanUrl}/api/cron/jobs/${encodeURIComponent(jobId)}/run${query}`, {
        method: http.RequestMethod.POST,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers,
        extraData: JSON.stringify({})
      });

      return res.responseCode >= 200 && res.responseCode < 300;
    } finally {
      client.destroy();
    }
  }

  /**
   * 暂停任务：POST /api/cron/jobs/{id}/pause
   */
  public static async pauseCronJob(
    baseUrl: string,
    jobId: string,
    profile?: string,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
    const cleanUrl = HermesCronClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();

    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      if (cookies && cookies.length > 0) {
        headers['Cookie'] = cookies;
      }

      const query = profile ? `?profile=${encodeURIComponent(profile)}` : '';
      const res = await client.request(`${cleanUrl}/api/cron/jobs/${encodeURIComponent(jobId)}/pause${query}`, {
        method: http.RequestMethod.POST,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers,
        extraData: JSON.stringify({})
      });

      return res.responseCode >= 200 && res.responseCode < 300;
    } finally {
      client.destroy();
    }
  }

  /**
   * 恢复任务：POST /api/cron/jobs/{id}/resume
   */
  public static async resumeCronJob(
    baseUrl: string,
    jobId: string,
    profile?: string,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
    const cleanUrl = HermesCronClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();

    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      if (cookies && cookies.length > 0) {
        headers['Cookie'] = cookies;
      }

      const query = profile ? `?profile=${encodeURIComponent(profile)}` : '';
      const res = await client.request(`${cleanUrl}/api/cron/jobs/${encodeURIComponent(jobId)}/resume${query}`, {
        method: http.RequestMethod.POST,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers,
        extraData: JSON.stringify({})
      });

      return res.responseCode >= 200 && res.responseCode < 300;
    } finally {
      client.destroy();
    }
  }
}
