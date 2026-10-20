import http from '@ohos.net.http';

export interface SkillSummary {
  name: string;
  description?: string;
  enabled: boolean;
  folder?: string;
}

/**
 * Hermes 技能客户端
 * 严格对齐 upstream HermesSkillsClient.swift (/api/skills)
 */
export class HermesSkillsClient {
  /**
   * 拉取技能列表：GET /api/skills?profile=<profile>
   */
  public static async getSkills(
    baseUrl: string,
    profile: string,
    token?: string,
    cookies?: string
  ): Promise<SkillSummary[]> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const q = encodeURIComponent(profile || 'default');
      const resp = await req.request(`${cleanUrl}/api/skills?profile=${q}`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (resp.responseCode === 200) {
        const raw = JSON.parse(String(resp.result || '[]')) as Record<string, Object>[];
        const list: SkillSummary[] = [];
        if (Array.isArray(raw)) {
          for (let i = 0; i < raw.length; i++) {
            const item = raw[i];
            const name = String(item['name'] || '');
            if (name) {
              list.push({
                name: name,
                description: item['description'] ? String(item['description']) : undefined,
                enabled: item['enabled'] !== false,
                folder: item['folder'] ? String(item['folder']) : undefined
              });
            }
          }
        }
        return list;
      }
      return [];
    } catch (_e) {
      return [];
    } finally {
      req.destroy();
    }
  }

  /**
   * 开关技能启用状态：POST /api/skills/set?profile=<profile>
   */
  public static async toggleSkill(
    baseUrl: string,
    profile: string,
    name: string,
    enabled: boolean,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {
      'Content-Type': 'application/json'
    };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const q = encodeURIComponent(profile || 'default');
      const resp = await req.request(`${cleanUrl}/api/skills/set?profile=${q}`, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify({
          name: name,
          enabled: enabled
        }),
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (resp.responseCode === 200) {
        const body = JSON.parse(String(resp.result || '{}')) as Record<string, Object>;
        return Boolean(body['ok'] !== false);
      }
      return false;
    } catch (_e) {
      return false;
    } finally {
      req.destroy();
    }
  }
}
