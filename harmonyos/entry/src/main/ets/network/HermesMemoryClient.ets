import http from '@ohos.net.http';

export interface MemorySectionContent {
  section: string;
  content: string;
  canEdit: boolean;
}

/**
 * Hermes 记忆与灵魂 (Soul/Memory) 客户端
 * 严格对齐 upstream APIClient+Memory.swift
 */
export class HermesMemoryClient {
  /**
   * 获取 Profile 的 Soul/设定：GET /api/profiles/{name}/soul
   */
  public static async getSoul(
    baseUrl: string,
    profile: string,
    token?: string,
    cookies?: string
  ): Promise<string> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const p = encodeURIComponent(profile || 'default');
      const resp = await req.request(`${cleanUrl}/api/profiles/${p}/soul`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (resp.responseCode === 200) {
        const data = JSON.parse(String(resp.result || '{}')) as Record<string, Object>;
        return String(data['soul'] || data['text'] || resp.result || '');
      }
      return '';
    } catch (_e) {
      return '';
    } finally {
      req.destroy();
    }
  }

  /**
   * 保存 Profile 的 Soul/设定：POST /api/profiles/{name}/soul
   */
  public static async saveSoul(
    baseUrl: string,
    profile: string,
    soulText: string,
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
      const p = encodeURIComponent(profile || 'default');
      const resp = await req.request(`${cleanUrl}/api/profiles/${p}/soul`, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify({
          soul: soulText
        }),
        connectTimeout: 8000,
        readTimeout: 12000
      });
      return resp.responseCode === 200;
    } catch (_e) {
      return false;
    } finally {
      req.destroy();
    }
  }

  /**
   * 获取核心记忆文件内容：通过 fs/read-text 读取 memories/MEMORY.md，或 legacy webui /api/memory
   */
  public static async getMemory(
    baseUrl: string,
    profile: string,
    token?: string,
    cookies?: string
  ): Promise<string> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      // 优先探测 Hermes 文件路由
      const resp = await req.request(`${cleanUrl}/api/fs/read-text?path=memories/MEMORY.md`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (resp.responseCode === 200) {
        const data = JSON.parse(String(resp.result || '{}')) as Record<string, Object>;
        return String(data['text'] || '');
      }

      // Legacy fallback: /api/memory
      const legacyResp = await req.request(`${cleanUrl}/api/memory`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (legacyResp.responseCode === 200) {
        const leg = JSON.parse(String(legacyResp.result || '{}')) as Record<string, Object>;
        return String(leg['content'] || leg['memory'] || '');
      }
      return '';
    } catch (_e) {
      return '';
    } finally {
      req.destroy();
    }
  }
}
