import http from '@ohos.net.http';
import { BotConnection, HermesStatus } from '../model/Connection';
import { HermesSession } from '../model/Session';
import { ChatMessage, ToolCallItem } from '../model/ChatMessage';

export interface LoginResult {
  token?: string;
  cookies: string;
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
   * 拉取会话列表
   * 对应 GET /api/sessions
   */
  public static async listSessions(baseUrl: string, profile: string, token?: string, cookies?: string): Promise<HermesSession[]> {
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
      const sessions: HermesSession[] = [];
      for (let i = 0; i < rawList.length; i++) {
        const item = rawList[i];
        const s: HermesSession = {
          id: String(item['id'] || item['session_id'] || ''),
          title: String(item['title'] || '会话'),
          profile: String(item['profile'] || profile || 'default'),
          created_at: Number(item['created_at'] || Date.now()),
          updated_at: Number(item['updated_at'] || Date.now()),
          running: Boolean(item['running']),
          model: item['model'] ? String(item['model']) : undefined,
          is_pinned: Boolean(item['is_pinned']),
          is_archived: Boolean(item['is_archived'])
        };
        sessions.push(s);
      }
      return sessions;
    } finally {
      client.destroy();
    }
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
      const messages: ChatMessage[] = [];

      for (let i = 0; i < rawMsgs.length; i++) {
        const item = rawMsgs[i];
        const roleStr = String(item['role'] || 'assistant');
        const role = (roleStr === 'user' ? 'user' : (roleStr === 'system' ? 'system' : 'assistant'));
        const content = String(item['content'] || '');
        const rawTools = Array.isArray(item['tool_calls']) ? (item['tool_calls'] as Array<Record<string, Object>>) : [];
        const tools: ToolCallItem[] = [];
        for (let j = 0; j < rawTools.length; j++) {
          const t = rawTools[j];
          tools.push({
            id: String(t['id'] || `tool_${j}`),
            name: String(t['name'] || 'tool'),
            output: t['output'] ? String(t['output']) : undefined,
            status: 'completed'
          });
        }
        messages.push({
          id: String(item['id'] || `msg_${i}_${Date.now()}`),
          role: role,
          content: content,
          toolCalls: tools,
          status: 'complete',
          createdAt: Number(item['created_at'] || Date.now())
        });
      }
      return messages;
    } finally {
      client.destroy();
    }
  }
}
