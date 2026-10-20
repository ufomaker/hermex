import http from '@ohos.net.http';
import { rcp } from '@kit.RemoteCommunicationKit';

export interface KanbanCardItem {
  id: string;
  title: string;
  status: string;
  assignee?: string;
  description?: string;
}

export interface KanbanColumnItem {
  name: string;
  cards: KanbanCardItem[];
}

export interface KanbanBoardItem {
  slug: string;
  name: string;
  description?: string;
  icon?: string;
  color?: string;
  readOnly?: boolean;
}

export interface KanbanBoardsResult {
  boards: KanbanBoardItem[];
  current?: string;
  readOnly?: boolean;
}

export interface KanbanBoardSnapshot {
  boardSlug: string;
  boardName?: string;
  columns: KanbanColumnItem[];
  latestEventId?: number;
  readOnly?: boolean;
}

export interface KanbanAvailability {
  available: boolean;
  status: 'available' | 'not_installed' | 'unauthorized' | 'server_error' | 'network_error';
  httpCode?: number;
  message: string;
}

/**
 * Hermes 看板客户端
 * 严格对齐 upstream HermesKanbanClient.swift 与 HermesREST.swift (/api/plugins/kanban)
 */
export class HermesKanbanClient {
  /**
   * 检查看板配置与可用性：GET /api/plugins/kanban/config
   * 严密区分 200(就绪)、404(未安装)、401/403(认证失效)、5xx(服务端异常) 与网络故障
   */
  public static async checkAvailability(
    baseUrl: string,
    token?: string,
    cookies?: string
  ): Promise<KanbanAvailability> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const resp = await req.request(`${cleanUrl}/api/plugins/kanban/config`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 5000,
        readTimeout: 6000
      });
      if (resp.responseCode === 200) {
        return {
          available: true,
          status: 'available',
          httpCode: 200,
          message: '看板插件已就绪'
        };
      } else if (resp.responseCode === 404) {
        return {
          available: false,
          status: 'not_installed',
          httpCode: 404,
          message: '服务端未安装或未启用看板插件 (/api/plugins/kanban 返回 404)'
        };
      } else if (resp.responseCode === 401 || resp.responseCode === 403) {
        return {
          available: false,
          status: 'unauthorized',
          httpCode: resp.responseCode,
          message: `无权访问看板服务 (HTTP ${resp.responseCode})，请检查登录态`
        };
      } else {
        return {
          available: false,
          status: 'server_error',
          httpCode: resp.responseCode,
          message: `看板服务暂时不可用 (HTTP ${resp.responseCode})`
        };
      }
    } catch (e) {
      return {
        available: false,
        status: 'network_error',
        message: `看板网络探测异常: ${e}`
      };
    } finally {
      req.destroy();
    }
  }

  public static async isAvailable(
    baseUrl: string,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
    const res = await HermesKanbanClient.checkAvailability(baseUrl, token, cookies);
    return res.available;
  }

  /**
   * 获取所有看板列表：GET /api/plugins/kanban/boards
   * 严格对齐 upstream KanbanBoardsResponse (Kanban.swift:439)
   */
  public static async getBoards(
    baseUrl: string,
    token?: string,
    cookies?: string
  ): Promise<KanbanBoardsResult> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const resp = await req.request(`${cleanUrl}/api/plugins/kanban/boards`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (resp.responseCode === 200) {
        const raw = JSON.parse(String(resp.result || '{}')) as Record<string, Object>;
        const list: KanbanBoardItem[] = [];
        let rawBoards: Array<Record<string, Object> | string> = [];
        let currentBoardSlug: string | undefined = undefined;
        let readOnly: boolean | undefined = undefined;

        if (Array.isArray(raw)) {
          rawBoards = raw as Array<Record<string, Object> | string>;
        } else if (raw && typeof raw === 'object') {
          if (Array.isArray(raw['boards'])) {
            rawBoards = raw['boards'] as Array<Record<string, Object> | string>;
          }
          if (raw['current']) {
            currentBoardSlug = String(raw['current']);
          }
          if (raw['readOnly'] !== undefined) {
            readOnly = Boolean(raw['readOnly']);
          } else if (raw['read_only'] !== undefined) {
            readOnly = Boolean(raw['read_only']);
          }
        }

        for (let i = 0; i < rawBoards.length; i++) {
          const b = rawBoards[i];
          if (typeof b === 'string') {
            list.push({
              slug: b,
              name: b
            });
          } else if (b && typeof b === 'object') {
            const slug = String(b['slug'] || b['id'] || b['name'] || `board-${i}`);
            const name = String(b['name'] || b['title'] || slug);
            const desc = b['description'] ? String(b['description']) : undefined;
            const icon = b['icon'] ? String(b['icon']) : undefined;
            const color = b['color'] ? String(b['color']) : undefined;
            const bReadOnly = b['readOnly'] !== undefined ? Boolean(b['readOnly']) : (b['read_only'] !== undefined ? Boolean(b['read_only']) : undefined);
            list.push({
              slug: slug,
              name: name,
              description: desc,
              icon: icon,
              color: color,
              readOnly: bReadOnly
            });
          }
        }

        return {
          boards: list,
          current: currentBoardSlug || (list.length > 0 ? list[0].slug : undefined),
          readOnly: readOnly
        };
      }
      return { boards: [] };
    } catch (_e) {
      return { boards: [] };
    } finally {
      req.destroy();
    }
  }

  /**
   * 获取指定看板快照：GET /api/plugins/kanban/board?board=<slug>
   * 严格对齐 upstream KanbanBoardSnapshot (Kanban.swift:506: latestEventID = "latestEventId", readOnly)
   */
  public static async getBoard(
    baseUrl: string,
    boardSlug: string,
    token?: string,
    cookies?: string
  ): Promise<KanbanBoardSnapshot | null> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const b = encodeURIComponent(boardSlug);
      const resp = await req.request(`${cleanUrl}/api/plugins/kanban/board?board=${b}`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 12000
      });
      if (resp.responseCode === 200) {
        const data = JSON.parse(String(resp.result || '{}')) as Record<string, Object>;
        const rawCols = (data['columns'] as Array<Record<string, Object>>) || [];
        const columns: KanbanColumnItem[] = [];

        for (let i = 0; i < rawCols.length; i++) {
          const col = rawCols[i];
          const colName = String(col['name'] || 'Column');
          const rawCards = (col['cards'] as Array<Record<string, Object>>) || [];
          const cards: KanbanCardItem[] = [];

          for (let j = 0; j < rawCards.length; j++) {
            const c = rawCards[j];
            cards.push({
              id: String(c['id'] || `card-${j}`),
              title: String(c['title'] || c['name'] || 'Untitled'),
              status: String(c['status'] || colName),
              assignee: c['assignee'] ? String(c['assignee']) : undefined,
              description: c['description'] ? String(c['description']) : undefined
            });
          }
          columns.push({ name: colName, cards: cards });
        }

        const rawEventId = data['latestEventId'] !== undefined ? data['latestEventId'] : data['latest_event_id'];
        let eventIdNum: number | undefined = undefined;
        if (typeof rawEventId === 'number') {
          eventIdNum = rawEventId;
        } else if (rawEventId) {
          eventIdNum = parseInt(String(rawEventId), 10);
        }

        const readOnly = data['readOnly'] !== undefined ? Boolean(data['readOnly']) : (data['read_only'] !== undefined ? Boolean(data['read_only']) : undefined);

        return {
          boardSlug: boardSlug,
          boardName: data['name'] ? String(data['name']) : undefined,
          columns: columns,
          latestEventId: eventIdNum,
          readOnly: readOnly
        };
      }
      return null;
    } catch (_e) {
      return null;
    } finally {
      req.destroy();
    }
  }

  /**
   * 创建看板卡片：POST /api/plugins/kanban/tasks?board=<slug>
   */
  public static async createCard(
    baseUrl: string,
    boardSlug: string,
    title: string,
    description?: string,
    assignee?: string,
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

    const payload: Record<string, Object> = {
      'title': title,
      'body': description || '',
      'idempotency_key': `card_${Date.now()}`
    };
    if (assignee) {
      payload['assignee'] = assignee;
    }

    try {
      const b = encodeURIComponent(boardSlug);
      const resp = await req.request(`${cleanUrl}/api/plugins/kanban/tasks?board=${b}`, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: 8000,
        readTimeout: 10000
      });
      return resp.responseCode === 200 || resp.responseCode === 201;
    } catch (_e) {
      return false;
    } finally {
      req.destroy();
    }
  }

  /**
   * 更新看板卡片状态：PATCH /api/plugins/kanban/tasks/<id>?board=<slug>
   * 严格对齐 upstream HermesREST.swift:632-634 (PATCH)
   * 在鸿蒙平台上使用 rcp (@kit.RemoteCommunicationKit) 发送原生 HTTP PATCH 动词
   */
  public static async updateCardStatus(
    baseUrl: string,
    boardSlug: string,
    cardId: string,
    status: string,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const headers: Record<string, string> = {
      'content-type': 'application/json'
    };
    if (token) headers['authorization'] = `Bearer ${token}`;
    if (cookies) headers['cookie'] = cookies;

    const payload: Record<string, Object> = {
      'status': status
    };

    const b = encodeURIComponent(boardSlug);
    const id = encodeURIComponent(cardId);
    const targetUrl = `${cleanUrl}/api/plugins/kanban/tasks/${id}?board=${b}`;

    try {
      const session = rcp.createSession();
      try {
        const req = new rcp.Request(
          targetUrl,
          'PATCH',
          headers,
          JSON.stringify(payload)
        );
        const resp = await session.fetch(req);
        return resp.statusCode === 200 || resp.statusCode === 204;
      } finally {
        session.close();
      }
    } catch (_e) {
      return false;
    }
  }
}
