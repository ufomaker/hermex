import http from '@ohos.net.http';
import { BotConnection, HermesStatus } from '../model/Connection';
import { HermesSession } from '../model/Session';
import { ChatMessage } from '../model/ChatMessage';

/**
 * Hermes REST 客户端
 * 严格对齐 HermesREST.swift 与后端公开接口契约
 */
export class HermesRESTClient {
  private static sanitizeUrl(base: string): string {
    let url = base.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
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
   */
  public static async login(baseUrl: string, username: string, password: string): Promise<string> {
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
      const dataStr = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;
      const token = parsed['access_token'] ? String(parsed['access_token']) : '';
      return token;
    } finally {
      client.destroy();
    }
  }

  /**
   * 换取 WebSocket 鉴权 Ticket
   * 对应 POST /api/auth/ws-ticket (HermesREST.swift:374)
   * 严格核实：路径为 /api/auth/ws-ticket，空载荷 {}
   */
  public static async getWsTicket(baseUrl: string, token?: string): Promise<string> {
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
      return ticket;
    } finally {
      client.destroy();
    }
  }

  /**
   * 拉取会话列表
   * 对应 GET /api/sessions
   */
  public static async listSessions(baseUrl: string, profile: string, token?: string): Promise<HermesSession[]> {
    const cleanUrl = HermesRESTClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Accept': 'application/json'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
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
      const sessions: HermesSession[] = rawList.map((item: Record<string, Object>): HermesSession => {
        const session: HermesSession = {
          id: String(item['id'] || item['session_id'] || ''),
          stored_session_id: item['stored_session_id'] ? String(item['stored_session_id']) : undefined,
          title: String(item['title'] || '新会话'),
          profile: String(item['profile'] || profile || 'default'),
          created_at: Number(item['created_at'] || Date.now()),
          updated_at: Number(item['updated_at'] || Date.now()),
          running: Boolean(item['running']),
          model: item['model'] ? String(item['model']) : undefined,
          is_pinned: Boolean(item['is_pinned']),
          is_archived: Boolean(item['is_archived'])
        };
        return session;
      });
      return sessions;
    } finally {
      client.destroy();
    }
  }
}
