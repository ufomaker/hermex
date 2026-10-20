import http from '@ohos.net.http';

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

export interface KanbanBoardSnapshot {
  boardName: string;
  columns: KanbanColumnItem[];
  latestEventId?: string;
}

/**
 * Hermes 看板客户端
 * 严格对齐 upstream HermesKanbanClient.swift (/api/plugins/kanban)
 */
export class HermesKanbanClient {
  /**
   * 检查看板配置与可用性：GET /api/plugins/kanban/config
   */
  public static async isAvailable(
    baseUrl: string,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
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
      return resp.responseCode === 200;
    } catch (_e) {
      return false;
    } finally {
      req.destroy();
    }
  }

  /**
   * 获取所有看板列表：GET /api/plugins/kanban/boards
   */
  public static async getBoards(
    baseUrl: string,
    token?: string,
    cookies?: string
  ): Promise<string[]> {
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
        const raw = JSON.parse(String(resp.result || '[]'));
        const list: string[] = [];
        if (Array.isArray(raw)) {
          for (let i = 0; i < raw.length; i++) {
            const b = raw[i];
            const name = typeof b === 'string' ? b : String(b.name || b.id || '');
            if (name) list.push(name);
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
   * 获取指定看板快照：GET /api/plugins/kanban/board?board=<name>
   */
  public static async getBoard(
    baseUrl: string,
    boardName: string,
    token?: string,
    cookies?: string
  ): Promise<KanbanBoardSnapshot | null> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const b = encodeURIComponent(boardName);
      const resp = await req.request(`${cleanUrl}/api/plugins/kanban/board?board=${b}`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 12000
      });
      if (resp.responseCode === 200) {
        const data = JSON.parse(String(resp.result || '{}'));
        const rawCols = Array.isArray(data.columns) ? data.columns : [];
        const columns: KanbanColumnItem[] = [];

        for (let i = 0; i < rawCols.length; i++) {
          const col = rawCols[i];
          const colName = String(col.name || 'Column');
          const rawCards = Array.isArray(col.cards) ? col.cards : [];
          const cards: KanbanCardItem[] = [];

          for (let j = 0; j < rawCards.length; j++) {
            const c = rawCards[j];
            cards.push({
              id: String(c.id || `card-${j}`),
              title: String(c.title || c.name || 'Untitled'),
              status: String(c.status || colName),
              assignee: c.assignee ? String(c.assignee) : undefined,
              description: c.description ? String(c.description) : undefined
            });
          }
          columns.push({ name: colName, cards: cards });
        }

        return {
          boardName: boardName,
          columns: columns,
          latestEventId: data.latest_event_id ? String(data.latest_event_id) : undefined
        };
      }
      return null;
    } catch (_e) {
      return null;
    } finally {
      req.destroy();
    }
  }
}
