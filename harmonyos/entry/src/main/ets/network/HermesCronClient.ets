import http from '@ohos.net.http';

export interface CronJobItem {
  id: string;
  name: string;
  schedule: string;
  prompt: string;
  enabled: boolean;
  state?: string;
  profile?: string;
  lastRunAt?: number;
  lastStatus?: string;
  lastError?: string;
  nextRunAt?: string | number;
  createdAt?: string | number;
  deliver?: string;
  warning?: string;
}

export interface CronRunItem {
  id: string;
  startedAt?: number;
  endedAt?: number;
  isActive: boolean;
  title?: string;
  lastStatus?: string;
  endReason?: string;
  model?: string;
  preview?: string;
}

export interface CreateCronJobPayload {
  name: string;
  schedule: string;
  prompt: string;
  deliver?: string;
  skills?: string[];
  model?: string;
  provider?: string;
}

export interface UpdateCronJobPayload {
  name?: string;
  schedule?: string;
  prompt?: string;
  deliver?: string;
  skills?: string[];
  model?: string;
  provider?: string;
}

/**
 * Hermes 定时任务 (Cron) 客户端
 * 严格对齐 HermesCronClient.swift、HermesREST.swift:500-516 与 /api/cron/*
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
   * 拉取定时任务列表：GET /api/cron/jobs?profile=<profile>
   * 容错兼容 Hermes 原生数组 [CronJob] 与 WebUI { jobs: [CronJob] }
   */
  public static async listCronJobs(
    baseUrl: string,
    profile?: string,
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

      const query = (profile && profile.length > 0) ? `?profile=${encodeURIComponent(profile)}` : '';
      const res = await client.request(`${cleanUrl}/api/cron/jobs${query}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`listCronJobs failed with HTTP ${res.responseCode}`);
      }

      const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const parsed = JSON.parse(dataStr) as Object;
      let rawJobs: Array<Record<string, Object>> = [];
      if (Array.isArray(parsed)) {
        rawJobs = parsed as Array<Record<string, Object>>;
      } else if (parsed && typeof parsed === 'object') {
        const obj = parsed as Record<string, Object>;
        if (Array.isArray(obj['jobs'])) {
          rawJobs = obj['jobs'] as Array<Record<string, Object>>;
        }
      }

      const jobs: CronJobItem[] = [];
      for (let i = 0; i < rawJobs.length; i++) {
        const j = rawJobs[i];
        let schedStr = '* * * * *';
        if (typeof j['schedule'] === 'string') {
          schedStr = String(j['schedule']);
        } else if (j['schedule_display']) {
          schedStr = String(j['schedule_display']);
        } else if (j['schedule'] && typeof j['schedule'] === 'object') {
          const sObj = j['schedule'] as Record<string, Object>;
          schedStr = String(sObj['expr'] || sObj['display'] || '* * * * *');
        }

        jobs.push({
          id: String(j['id'] || j['job_id'] || ''),
          name: String(j['name'] || '定时任务'),
          schedule: schedStr,
          prompt: String(j['prompt'] || ''),
          enabled: Boolean(j['enabled']),
          state: j['state'] ? String(j['state']) : undefined,
          profile: j['profile'] ? String(j['profile']) : undefined,
          lastRunAt: typeof j['last_run_at'] === 'number' ? Number(j['last_run_at']) : undefined,
          lastStatus: j['last_status'] ? String(j['last_status']) : undefined,
          lastError: j['last_error'] ? String(j['last_error']) : undefined,
          nextRunAt: (typeof j['next_run_at'] === 'string' || typeof j['next_run_at'] === 'number') ? j['next_run_at'] : undefined,
          createdAt: (typeof j['created_at'] === 'string' || typeof j['created_at'] === 'number') ? j['created_at'] : undefined,
          deliver: j['deliver'] ? String(j['deliver']) : undefined
        });
      }

      return jobs;
    } finally {
      client.destroy();
    }
  }

  /**
   * 创建定时任务：POST /api/cron/jobs?profile=<profile>
   * 对齐 HermesREST.swift:500-501
   */
  public static async createCronJob(
    baseUrl: string,
    payload: CreateCronJobPayload,
    profile?: string,
    token?: string,
    cookies?: string
  ): Promise<CronJobItem> {
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

      const bodyFields: Record<string, Object> = {
        'name': payload.name || '',
        'schedule': payload.schedule || '* * * * *',
        'prompt': payload.prompt || '',
        'deliver': payload.deliver || 'local',
        'skills': payload.skills || []
      };
      if (payload.model) bodyFields['model'] = payload.model;
      if (payload.provider) bodyFields['provider'] = payload.provider;

      const query = (profile && profile.length > 0) ? `?profile=${encodeURIComponent(profile)}` : '';
      const res = await client.request(`${cleanUrl}/api/cron/jobs${query}`, {
        method: http.RequestMethod.POST,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers,
        extraData: JSON.stringify(bodyFields)
      });

      // 上游 HermesCronClient.swift:32-49: HTTP 424 表示任务已成功持久化，但调度注册遇到警告，需返回 warning 及 reload，不报创建失败
      if (res.responseCode === 424) {
        const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
        let warnMsg = '任务已保存，但调度器未能成功注册该定时规则';
        try {
          const j = JSON.parse(dataStr) as Record<string, Object>;
          if (j['detail'] && typeof j['detail'] === 'object') {
            const detail = j['detail'] as Record<string, Object>;
            if (typeof detail['error'] === 'string') {
              warnMsg = detail['error'];
            }
          }
        } catch (_e) {}
        return {
          id: '',
          name: payload.name,
          schedule: payload.schedule,
          prompt: payload.prompt,
          enabled: false,
          state: 'warning',
          warning: warnMsg
        };
      }

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`createCronJob failed with HTTP ${res.responseCode}`);
      }

      const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const j = JSON.parse(dataStr) as Record<string, Object>;
      const createdObj = (j['job'] && typeof j['job'] === 'object') ? (j['job'] as Record<string, Object>) : j;

      let schedStr = payload.schedule;
      if (typeof createdObj['schedule'] === 'string') {
        schedStr = String(createdObj['schedule']);
      } else if (createdObj['schedule_display']) {
        schedStr = String(createdObj['schedule_display']);
      }

      return {
        id: String(createdObj['id'] || createdObj['job_id'] || ''),
        name: String(createdObj['name'] || payload.name),
        schedule: schedStr,
        prompt: String(createdObj['prompt'] || payload.prompt),
        enabled: Boolean(createdObj['enabled'] ?? true),
        state: createdObj['state'] ? String(createdObj['state']) : undefined,
        profile: createdObj['profile'] ? String(createdObj['profile']) : profile,
        lastStatus: createdObj['last_status'] ? String(createdObj['last_status']) : undefined
      };
    } finally {
      client.destroy();
    }
  }

  /**
   * 更新定时任务：PUT /api/cron/jobs/{id}?profile=<profile>
   * 对齐 HermesREST.swift:502-503: body {"updates": { ... }}
   */
  public static async updateCronJob(
    baseUrl: string,
    jobId: string,
    updates: UpdateCronJobPayload,
    profile?: string,
    token?: string,
    cookies?: string
  ): Promise<CronJobItem> {
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

      const updatesObj: Record<string, Object> = {};
      if (updates.name !== undefined) updatesObj['name'] = updates.name;
      if (updates.schedule !== undefined) updatesObj['schedule'] = updates.schedule;
      if (updates.prompt !== undefined) updatesObj['prompt'] = updates.prompt;
      if (updates.deliver !== undefined) updatesObj['deliver'] = updates.deliver;
      if (updates.skills !== undefined) updatesObj['skills'] = updates.skills;
      if (updates.model !== undefined) updatesObj['model'] = updates.model;
      if (updates.provider !== undefined) updatesObj['provider'] = updates.provider;

      const query = (profile && profile.length > 0) ? `?profile=${encodeURIComponent(profile)}` : '';
      const res = await client.request(`${cleanUrl}/api/cron/jobs/${encodeURIComponent(jobId)}${query}`, {
        method: http.RequestMethod.PUT,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers,
        extraData: JSON.stringify({ updates: updatesObj })
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`updateCronJob failed with HTTP ${res.responseCode}`);
      }

      const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const j = JSON.parse(dataStr) as Record<string, Object>;
      const updatedObj = (j['job'] && typeof j['job'] === 'object') ? (j['job'] as Record<string, Object>) : j;

      let schedStr = updates.schedule || '* * * * *';
      if (typeof updatedObj['schedule'] === 'string') {
        schedStr = String(updatedObj['schedule']);
      } else if (updatedObj['schedule_display']) {
        schedStr = String(updatedObj['schedule_display']);
      }

      return {
        id: String(updatedObj['id'] || updatedObj['job_id'] || jobId),
        name: String(updatedObj['name'] || updates.name || '定时任务'),
        schedule: schedStr,
        prompt: String(updatedObj['prompt'] || updates.prompt || ''),
        enabled: Boolean(updatedObj['enabled'] ?? true),
        state: updatedObj['state'] ? String(updatedObj['state']) : undefined,
        profile: updatedObj['profile'] ? String(updatedObj['profile']) : profile,
        lastStatus: updatedObj['last_status'] ? String(updatedObj['last_status']) : undefined
      };
    } finally {
      client.destroy();
    }
  }

  /**
   * 手动触发执行指定定时任务：POST /api/cron/jobs/{id}/trigger?profile=<profile>
   * 严格对齐上游 HermesREST.swift:509-510 (case .cronTrigger: POST .../trigger)
   */
  public static async triggerCronJob(
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

      const query = (profile && profile.length > 0) ? `?profile=${encodeURIComponent(profile)}` : '';
      const res = await client.request(`${cleanUrl}/api/cron/jobs/${encodeURIComponent(jobId)}/trigger${query}`, {
        method: http.RequestMethod.POST,
        connectTimeout: 30000,
        readTimeout: 30000,
        header: headers,
        extraData: JSON.stringify({})
      });

      if (res.responseCode === 409) {
        const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
        let detailMsg = '任务已在运行中 (409 Conflict)';
        try {
          const j = JSON.parse(dataStr) as Record<string, Object>;
          if (typeof j['detail'] === 'string') {
            detailMsg = `任务冲突: ${j['detail']}`;
          }
        } catch (_e) {}
        throw new Error(detailMsg);
      }

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`triggerCronJob failed with HTTP ${res.responseCode}`);
      }

      return true;
    } finally {
      client.destroy();
    }
  }

  /**
   * 兼容别名：调用 triggerCronJob
   */
  public static async runCronJob(
    baseUrl: string,
    jobId: string,
    profile?: string,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
    return HermesCronClient.triggerCronJob(baseUrl, jobId, profile, token, cookies);
  }

  /**
   * 暂停任务：POST /api/cron/jobs/{id}/pause?profile=<profile>
   * 对齐 HermesREST.swift:504-505
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

      const query = (profile && profile.length > 0) ? `?profile=${encodeURIComponent(profile)}` : '';
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
   * 恢复任务：POST /api/cron/jobs/{id}/resume?profile=<profile>
   * 对齐 HermesREST.swift:506-507
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

      const query = (profile && profile.length > 0) ? `?profile=${encodeURIComponent(profile)}` : '';
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

  /**
   * 获取任务运行历史：GET /api/cron/jobs/{id}/runs?profile=<profile>&limit=100
   * 严格对齐 HermesREST.swift:511-516 与 HermesCronClient.swift:120-125
   */
  public static async listCronRuns(
    baseUrl: string,
    jobId: string,
    profile?: string,
    limit: number = 100,
    token?: string,
    cookies?: string
  ): Promise<CronRunItem[]> {
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

      const params: string[] = [`limit=${limit}`];
      if (profile && profile.length > 0) {
        params.push(`profile=${encodeURIComponent(profile)}`);
      }
      const query = `?${params.join('&')}`;

      const res = await client.request(`${cleanUrl}/api/cron/jobs/${encodeURIComponent(jobId)}/runs${query}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`listCronRuns failed with HTTP ${res.responseCode}`);
      }

      const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const rawRuns = Array.isArray(parsed['runs']) ? (parsed['runs'] as Array<Record<string, Object>>) : [];

      const runs: CronRunItem[] = [];
      for (let i = 0; i < rawRuns.length; i++) {
        const r = rawRuns[i];
        runs.push({
          id: String(r['id'] || ''),
          startedAt: typeof r['started_at'] === 'number' ? Number(r['started_at']) : undefined,
          endedAt: typeof r['ended_at'] === 'number' ? Number(r['ended_at']) : undefined,
          isActive: Boolean(r['is_active']),
          title: r['title'] ? String(r['title']) : undefined,
          lastStatus: r['last_status'] ? String(r['last_status']) : (r['end_reason'] ? String(r['end_reason']) : undefined),
          endReason: r['end_reason'] ? String(r['end_reason']) : undefined,
          model: r['model'] ? String(r['model']) : undefined,
          preview: r['preview'] ? String(r['preview']) : undefined
        });
      }

      return runs;
    } finally {
      client.destroy();
    }
  }
}
