import http from '@ohos.net.http';
import { rcp } from '@kit.RemoteCommunicationKit';
import { BotConnection, HermesStatus } from '../model/Connection';
import { HermesSession } from '../model/Session';
import { ChatMessage, ToolCallItem } from '../model/ChatMessage';
import { HermesHistoryNormalizer } from '../utils/HermesHistoryNormalizer';

export interface LoginResult {
  token?: string;
  cookies: string;
}

export interface SessionListPageResult {
  sessions: HermesSession[];
  total: number;
  hasMore: boolean;
}

export interface SessionUpdatePayload {
  title?: string;
  pinned?: boolean;
  archived?: boolean;
}

export interface SessionUpdateResult {
  ok: boolean;
  title?: string;
  pinned?: boolean;
  archived?: boolean;
}

export interface SessionImportResult {
  ok: boolean;
  imported_ids: string[];
  errors: string[];
}

/**
 * Hermes REST 客户端
 * 严格对齐 HermesREST.swift 与后端公开接口契约，支持 Cookie Jar 与 auth/me 核验
 */
export class HermesRESTClient {
  private static sanitizeUrl(base: string): string {
    let url = base.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  private static extractCookies(headerObj: Object): string {
    if (!headerObj) {
      return '';
    }
    const header = headerObj as Record<string, Object>;
    const raw = header['set-cookie'] || header['Set-Cookie'];
    if (!raw) {
      return '';
    }
    if (Array.isArray(raw)) {
      const parts: string[] = [];
      for (let i = 0; i < raw.length; i++) {
        const line = String(raw[i]).split(';')[0].trim();
        if (line) {
          parts.push(line);
        }
      }
      return parts.join('; ');
    }
    return String(raw).split(';')[0].trim();
  }

  /**
   * 状态探测接口 (公开，不要求认证)
   * 对应 GET /api/status
   */
  public static async getStatus(baseUrl: string): Promise<HermesStatus> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();
    try {
      const response = await client.request(`${cleanUrl}/api/status`, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000,
        header: {
          'Accept': 'application/json'
        }
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Status probe failed with HTTP ${response.responseCode}`);
      }
      const dataStr = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const status: HermesStatus = {
        version: String(parsed['version'] || ''),
        release_date: parsed['release_date'] ? String(parsed['release_date']) : undefined,
        auth_required: Boolean(parsed['auth_required']),
        profiles: Array.isArray(parsed['profiles']) ? (parsed['profiles'] as string[]) : ['default'],
        gateway_running: Boolean(parsed['gateway_running']),
        gateway_mode: parsed['gateway_mode'] ? String(parsed['gateway_mode']) : undefined,
        overall: parsed['overall'] ? String(parsed['overall']) : undefined
      };
      return status;
    } finally {
      client.destroy();
    }
  }

  /**
   * 密码登录
   * 对应 POST /auth/password-login (HermesREST.swift:360-363)
   * 并使用 GET /api/auth/me 进行真实身份核验
   */
  public static async login(baseUrl: string, username: string, password: string): Promise<LoginResult> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();
    try {
      const payload: Record<string, string> = {
        'provider': 'basic',
        'username': username,
        'password': password
      };
      const response = await client.request(`${cleanUrl}/auth/password-login`, {
        method: http.RequestMethod.POST,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: {
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        extraData: JSON.stringify(payload)
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Login failed with HTTP ${response.responseCode}`);
      }
      const cookies = HermesRESTClient.extractCookies(response.header);
      const dataStr = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      let token = '';
      try {
        const parsed = JSON.parse(dataStr) as Record<string, Object>;
        token = parsed['access_token'] ? String(parsed['access_token']) : '';
      } catch (e) {
        // ignore json parse if only cookie returned
      }

      // 核验身份：GET /api/auth/me
      const meClient = http.createHttp();
      try {
        const meHeaders: Record<string, string> = {
          'Accept': 'application/json'
        };
        if (token) {
          meHeaders['Authorization'] = `Bearer ${token}`;
        }
        if (cookies) {
          meHeaders['Cookie'] = cookies;
        }
        const meRes = await meClient.request(`${cleanUrl}/api/auth/me`, {
          method: http.RequestMethod.GET,
          connectTimeout: 5000,
          readTimeout: 5000,
          header: meHeaders
        });
        if (meRes.responseCode < 200 || meRes.responseCode >= 300) {
          throw new Error(`Authentication verification (/api/auth/me) failed with HTTP ${meRes.responseCode}`);
        }
      } finally {
        meClient.destroy();
      }

      const result: LoginResult = {
        token: token,
        cookies: cookies
      };
      return result;
    } finally {
      client.destroy();
    }
  }

  /**
   * 换取 WebSocket 鉴权 Ticket
   * 对应 POST /api/auth/ws-ticket (HermesREST.swift:374)
   * 支持 Cookie 与 Bearer Token 双通道携带
   */
  public static async getWsTicket(baseUrl: string, token?: string, cookies?: string): Promise<string> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
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
      const response = await client.request(`${cleanUrl}/api/auth/ws-ticket`, {
        method: http.RequestMethod.POST,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers,
        extraData: JSON.stringify({})
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Failed to mint ws-ticket with HTTP ${response.responseCode}`);
      }
      const dataStr = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const ticket = parsed['ticket'] ? String(parsed['ticket']) : '';
      if (!ticket) {
        throw new Error('Response did not contain a valid ticket string');
      }
      return ticket;
    } finally {
      client.destroy();
    }
  }

  /**
   * 分页拉取会话列表
   * 对应 GET /api/sessions?profile={profile}&offset={offset}&limit={limit}&archived={archived}
   */
  public static async listSessionsPage(
    baseUrl: string,
    profile: string,
    token?: string,
    cookies?: string,
    offset: number = 0,
    limit: number = 50,
    archived: boolean = false
  ): Promise<SessionListPageResult> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
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
      const params: string[] = [];
      if (profile) params.push(`profile=${encodeURIComponent(profile)}`);
      params.push(`offset=${offset}`);
      params.push(`limit=${limit}`);
      if (archived) params.push('archived=true');
      const query = params.length > 0 ? `?${params.join('&')}` : '';

      const response = await client.request(`${cleanUrl}/api/sessions${query}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`List sessions failed with HTTP ${response.responseCode}`);
      }
      const dataStr = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const rawList = Array.isArray(parsed['sessions']) ? (parsed['sessions'] as Array<Record<string, Object>>) : [];
      const total = typeof parsed['total'] === 'number' ? parsed['total'] : rawList.length;
      const sessions: HermesSession[] = [];
      for (let i = 0; i < rawList.length; i++) {
        const item = rawList[i];
        const s: HermesSession = {
          id: String(item['id'] || item['session_id'] || ''),
          title: String(item['title'] || item['display_name'] || item['preview'] || '会话'),
          profile: String(item['profile'] || profile || 'default'),
          created_at: Number(item['created_at'] || item['started_at'] || Date.now()),
          updated_at: Number(item['updated_at'] || item['last_active'] || Date.now()),
          running: Boolean(item['running'] || item['is_active']),
          model: item['model'] ? String(item['model']) : undefined,
          is_pinned: Boolean(item['is_pinned'] || item['pinned']),
          is_archived: Boolean(item['is_archived'] || item['archived']),
          preview: item['preview'] ? String(item['preview']) : undefined
        };
        sessions.push(s);
      }
      const hasMore = offset + rawList.length < total;
      const res: SessionListPageResult = { sessions, total, hasMore };
      return res;
    } finally {
      client.destroy();
    }
  }

  /**
   * 拉取会话列表 (全量兼容接口)
   * 对应 GET /api/sessions
   */
  public static async listSessions(baseUrl: string, profile: string, token?: string, cookies?: string): Promise<HermesSession[]> {
    const res = await HermesRESTClient.listSessionsPage(baseUrl, profile, token, cookies, 0, 50, false);
    return res.sessions;
  }

  /**
   * 服务端会话检索
   * 对应 GET /api/sessions/search?profile={profile}&query={query}&limit={limit}
   */
  public static async searchSessions(
    baseUrl: string,
    profile: string,
    query: string,
    token?: string,
    cookies?: string,
    limit: number = 50
  ): Promise<HermesSession[]> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
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
      const q = `?profile=${encodeURIComponent(profile)}&query=${encodeURIComponent(query)}&limit=${limit}`;
      const response = await client.request(`${cleanUrl}/api/sessions/search${q}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return [];
      }
      const dataStr = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const rawList = Array.isArray(parsed['results']) ? (parsed['results'] as Array<Record<string, Object>>) :
        (Array.isArray(parsed['sessions']) ? (parsed['sessions'] as Array<Record<string, Object>>) : []);
      const results: HermesSession[] = [];
      for (let i = 0; i < rawList.length; i++) {
        const item = rawList[i];
        results.push({
          id: String(item['id'] || item['session_id'] || ''),
          title: String(item['title'] || item['display_name'] || item['preview'] || '会话'),
          profile: String(item['profile'] || profile || 'default'),
          created_at: Number(item['created_at'] || item['started_at'] || Date.now()),
          updated_at: Number(item['updated_at'] || item['last_active'] || Date.now()),
          running: Boolean(item['running'] || item['is_active']),
          model: item['model'] ? String(item['model']) : undefined,
          is_pinned: Boolean(item['is_pinned'] || item['pinned']),
          is_archived: Boolean(item['is_archived'] || item['archived']),
          preview: item['preview'] ? String(item['preview']) : undefined
        });
      }
      return results;
    } catch (_e) {
      return [];
    } finally {
      client.destroy();
    }
  }

  /**
   * 更新会话属性 (重命名、置顶、归档)
   * 对应 PATCH /api/sessions/{id} (HermesREST.swift:171, 468)
   */
  public static async updateSession(
    baseUrl: string,
    sessionId: string,
    profile: string,
    updates: SessionUpdatePayload,
    token?: string,
    cookies?: string
  ): Promise<SessionUpdateResult> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
    const headers: Record<string, string> = {
      'content-type': 'application/json',
      'accept': 'application/json'
    };
    if (token && token.length > 0) {
      headers['authorization'] = `Bearer ${token}`;
    }
    if (cookies && cookies.length > 0) {
      headers['cookie'] = cookies;
    }
    const payload: Record<string, Object> = {
      'profile': profile
    };
    if (updates.title !== undefined) payload['title'] = updates.title;
    if (updates.pinned !== undefined) payload['pinned'] = updates.pinned;
    if (updates.archived !== undefined) payload['archived'] = updates.archived;

    const targetUrl = `${cleanUrl}/api/sessions/${encodeURIComponent(sessionId)}`;
    const session = rcp.createSession();
    try {
      const req = new rcp.Request(
        targetUrl,
        'PATCH',
        headers,
        JSON.stringify(payload)
      );
      const resp = await session.fetch(req);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw new Error(`Update session failed with HTTP ${resp.statusCode}`);
      }
      const dataStr = resp.toString() || '{}';
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const res: SessionUpdateResult = {
        ok: Boolean(parsed['ok']),
        title: parsed['title'] ? String(parsed['title']) : updates.title,
        pinned: parsed['pinned'] !== undefined ? Boolean(parsed['pinned']) : updates.pinned,
        archived: parsed['archived'] !== undefined ? Boolean(parsed['archived']) : updates.archived
      };
      return res;
    } finally {
      session.close();
    }
  }

  /**
   * 导出完整会话 JSON
   * 对应 GET /api/sessions/{id}/export?profile={profile} (HermesREST.swift:178, 473)
   */
  public static async exportSession(
    baseUrl: string,
    sessionId: string,
    profile: string,
    token?: string,
    cookies?: string
  ): Promise<string> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
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
      const response = await client.request(`${cleanUrl}/api/sessions/${encodeURIComponent(sessionId)}/export?profile=${encodeURIComponent(profile)}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000,
        header: headers
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Export session failed with HTTP ${response.responseCode}`);
      }
      return typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
    } finally {
      client.destroy();
    }
  }

  /**
   * 批量导入会话
   * 对应 POST /api/sessions/import (HermesREST.swift:182, 481)
   */
  public static async importSessions(
    baseUrl: string,
    profile: string,
    sessions: Array<Record<string, Object>>,
    token?: string,
    cookies?: string
  ): Promise<SessionImportResult> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
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
      const payload: Record<string, Object> = {
        'profile': profile,
        'sessions': sessions
      };
      const response = await client.request(`${cleanUrl}/api/sessions/import`, {
        method: http.RequestMethod.POST,
        connectTimeout: 15000,
        readTimeout: 15000,
        header: headers,
        extraData: JSON.stringify(payload)
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Import sessions failed with HTTP ${response.responseCode}`);
      }
      const dataStr = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const rawIds = Array.isArray(parsed['imported_ids']) ? (parsed['imported_ids'] as string[]) : [];
      const rawErrors = Array.isArray(parsed['errors']) ? (parsed['errors'] as string[]) : [];
      const res: SessionImportResult = {
        ok: Boolean(parsed['ok']),
        imported_ids: rawIds,
        errors: rawErrors
      };
      return res;
    } finally {
      client.destroy();
    }
  }

  /**
   * 会话克隆/分支 (上游 HermesSessionDuplication.swift 规范)
   * 导出原会话 -> 清洗血缘与消息行ID -> 生成唯一新ID -> 导入 -> 重命名为 "<原标题> (copy)"
   */
  public static async duplicateSession(
    baseUrl: string,
    sessionId: string,
    profile: string,
    currentTitle: string,
    token?: string,
    cookies?: string
  ): Promise<HermesSession> {
    const exportRaw = await HermesRESTClient.exportSession(baseUrl, sessionId, profile, token, cookies);
    const exportObj = JSON.parse(exportRaw) as Record<string, Object>;

    // 生成形如 20261021_052926_a1399b 的 Hermes 标准格式会话 ID
    const now = new Date();
    const pad = (n: number) => n < 10 ? '0' + n : String(n);
    const dateStr = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}_${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
    const hex = Math.floor(Math.random() * 0xFFFFFF).toString(16).padStart(6, '0');
    const newId = `${dateStr}_${hex}`;

    // 清洗血统标识与 parent_session_id
    const copyObj: Record<string, Object> = {};
    const keys = Object.keys(exportObj);
    for (let k = 0; k < keys.length; k++) {
      const key = keys[k];
      if (key.startsWith('_lineage_') || key === 'parent_session_id' || key === 'timings') {
        continue;
      }
      copyObj[key] = exportObj[key];
    }
    copyObj['id'] = newId;
    copyObj['title'] = '';
    copyObj['archived'] = false;
    copyObj['pinned'] = false;

    // 清洗 messages 中每行的 row id
    if (Array.isArray(exportObj['messages'])) {
      const msgs = exportObj['messages'] as Array<Record<string, Object>>;
      const cleanedMsgs: Array<Record<string, Object>> = [];
      for (let m = 0; m < msgs.length; m++) {
        const msg = msgs[m];
        const cMsg: Record<string, Object> = {};
        const mKeys = Object.keys(msg);
        for (let mk = 0; mk < mKeys.length; mk++) {
          if (mKeys[mk] !== 'id') {
            cMsg[mKeys[mk]] = msg[mKeys[mk]];
          }
        }
        cleanedMsgs.push(cMsg);
      }
      copyObj['messages'] = cleanedMsgs;
    }

    const importRes = await HermesRESTClient.importSessions(baseUrl, profile, [copyObj], token, cookies);
    if (!importRes.imported_ids.includes(newId)) {
      throw new Error(`Duplicate session failed: new session ${newId} not in imported_ids`);
    }

    const copyTitle = `${currentTitle || '会话'} (copy)`;
    try {
      const copyPayload: SessionUpdatePayload = { title: copyTitle };
      await HermesRESTClient.updateSession(baseUrl, newId, profile, copyPayload, token, cookies);
    } catch (_e) {
      // 容错保留
    }

    const newSession: HermesSession = {
      id: newId,
      runtime_id: newId,
      title: copyTitle,
      profile: profile,
      created_at: Date.now(),
      updated_at: Date.now(),
      running: false,
      is_pinned: false,
      is_archived: false
    };
    return newSession;
  }

  /**
   * 拉取指定会话的历史消息
   * 对应 GET /api/sessions/{id}/messages (HermesREST.swift:19-20)
   */
  public static async getSessionMessages(baseUrl: string, sessionId: string, profile: string, token?: string, cookies?: string): Promise<ChatMessage[]> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
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
      const response = await client.request(`${cleanUrl}/api/sessions/${encodeURIComponent(sessionId)}/messages${query}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Get messages failed with HTTP ${response.responseCode}`);
      }
      const dataStr = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const rawMsgs = Array.isArray(parsed['messages']) ? (parsed['messages'] as Array<Record<string, Object>>) : [];
      return HermesHistoryNormalizer.normalize(rawMsgs);
    } finally {
      client.destroy();
    }
  }
}
