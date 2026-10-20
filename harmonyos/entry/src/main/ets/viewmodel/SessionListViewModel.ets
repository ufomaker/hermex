import { HermesSession, cloneSession } from '../model/Session';
import { HermesRESTClient, SessionUpdatePayload } from '../network/HermesRESTClient';
import { HermesGatewayClient } from '../network/HermesGatewayClient';
import { LegacySSEClient } from '../network/legacy/LegacySSEClient';
import { BotConnection } from '../model/Connection';

export type SessionFilterTab = 'all' | 'pinned' | 'archived';

export class SessionListViewModel {
  // 全量会话池 (去重缓存)
  private allSessions: HermesSession[] = [];
  // 过滤/搜索后呈现给界面的会话列表
  private displayedSessions: HermesSession[] = [];

  private isLoading: boolean = false;
  private isLoadingMore: boolean = false;
  private hasMore: boolean = true;
  private offset: number = 0;
  private pageSize: number = 20;
  private totalCount: number = 0;

  private searchQuery: string = '';
  private activeFilterTab: SessionFilterTab = 'all';

  // 跨服务器/Profile 隔离与防竞态请求代次
  private currentServerUrl: string = '';
  private currentProfile: string = '';
  private requestSerial: number = 0;
  private actionError: string | null = null;

  public getSessions(): HermesSession[] {
    return this.displayedSessions;
  }

  public getRawSessions(): HermesSession[] {
    return this.allSessions;
  }

  public getIsLoading(): boolean {
    return this.isLoading;
  }

  public getIsLoadingMore(): boolean {
    return this.isLoadingMore;
  }

  public getHasMore(): boolean {
    return this.hasMore;
  }

  public getTotalCount(): number {
    return this.totalCount;
  }

  public getSearchQuery(): string {
    return this.searchQuery;
  }

  public getActiveFilterTab(): SessionFilterTab {
    return this.activeFilterTab;
  }

  public getActionError(): string | null {
    return this.actionError;
  }

  public clearActionError(): void {
    this.actionError = null;
  }

  /**
   * 首次/重新加载会话列表 (支持 legacy-webui 与 Hermes 直连)
   */
  public async loadSessions(conn: BotConnection): Promise<HermesSession[]> {
    this.requestSerial++;
    const thisSerial = this.requestSerial;

    this.currentServerUrl = conn.url;
    this.currentProfile = conn.activeProfile || 'default';
    this.isLoading = true;
    this.actionError = null;
    this.offset = 0;

    try {
      if (conn.serverVersion === 'legacy-webui') {
        const legacyItems = await LegacySSEClient.listSessions(conn.url, conn.token, conn.cookies);
        if (thisSerial !== this.requestSerial) {
          // 竞态拦截：用户在请求期间切换了服务器或发起新请求
          return this.displayedSessions;
        }
        this.allSessions = legacyItems.map((item) => {
          const s: HermesSession = {
            id: item.id,
            runtime_id: item.id,
            title: item.title || '历史会话',
            profile: 'default',
            created_at: item.createdAt || Date.now(),
            updated_at: item.updatedAt || Date.now(),
            running: false,
            is_pinned: false,
            is_archived: false
          };
          return s;
        });
        this.totalCount = this.allSessions.length;
        this.hasMore = false;
        this.applyFilterAndSearch();
        return this.displayedSessions;
      }

      // Hermes 直连：带分页
      const res = await HermesRESTClient.listSessionsPage(
        conn.url,
        this.currentProfile,
        conn.token,
        conn.cookies,
        0,
        this.pageSize,
        false
      );

      if (thisSerial !== this.requestSerial) {
        // 竞态拦截
        return this.displayedSessions;
      }

      this.allSessions = this.deduplicateSessions(res.sessions);
      this.totalCount = res.total;
      this.hasMore = res.hasMore;
      this.offset = this.allSessions.length;
      this.applyFilterAndSearch();
      return this.displayedSessions;
    } catch (e) {
      if (thisSerial === this.requestSerial) {
        this.actionError = `加载会话失败: ${(e as Error).message || String(e)}`;
      }
      return this.displayedSessions;
    } finally {
      if (thisSerial === this.requestSerial) {
        this.isLoading = false;
      }
    }
  }

  /**
   * 分页加载更多会话 (滚动到底部时触发)
   */
  public async loadMoreSessions(conn: BotConnection): Promise<boolean> {
    if (!this.hasMore || this.isLoadingMore || this.isLoading) {
      return false;
    }
    if (conn.serverVersion === 'legacy-webui') {
      this.hasMore = false;
      return false;
    }

    const thisSerial = this.requestSerial;
    this.isLoadingMore = true;
    try {
      const res = await HermesRESTClient.listSessionsPage(
        conn.url,
        this.currentProfile,
        conn.token,
        conn.cookies,
        this.allSessions.length,
        this.pageSize,
        this.activeFilterTab === 'archived'
      );

      if (thisSerial !== this.requestSerial) {
        return false;
      }

      // 去重追加
      this.allSessions = this.deduplicateSessions(this.allSessions.concat(res.sessions));
      this.totalCount = res.total;
      this.hasMore = res.hasMore;
      this.offset = this.allSessions.length;
      this.applyFilterAndSearch();
      return true;
    } catch (e) {
      if (thisSerial === this.requestSerial) {
        this.actionError = `加载更多失败: ${(e as Error).message || String(e)}`;
      }
      return false;
    } finally {
      if (thisSerial === this.requestSerial) {
        this.isLoadingMore = false;
      }
    }
  }

  /**
   * 设置搜索词 (即时本地检索 + 触发服务端检索)
   */
  public async setSearchQuery(query: string, conn?: BotConnection): Promise<void> {
    this.searchQuery = query.trim();
    this.applyFilterAndSearch();

    // 若搜索词非空且存在 Hermes 连线，可并发查询服务端并合并结果
    if (this.searchQuery.length > 0 && conn && conn.serverVersion !== 'legacy-webui') {
      try {
        const serverResults = await HermesRESTClient.searchSessions(
          conn.url,
          this.currentProfile,
          this.searchQuery,
          conn.token,
          conn.cookies,
          20
        );
        if (serverResults.length > 0) {
          // 合并到全量池中并重新呈现
          this.allSessions = this.deduplicateSessions(this.allSessions.concat(serverResults));
          this.applyFilterAndSearch();
        }
      } catch (_e) {
        // 服务端检索容错回退至纯本地过滤
      }
    }
  }

  /**
   * 清除搜索词并无损恢复全量列表
   */
  public clearSearch(): void {
    this.searchQuery = '';
    this.applyFilterAndSearch();
  }

  /**
   * 切换视图分类 Tab ('all' | 'pinned' | 'archived')
   */
  public setFilterTab(tab: SessionFilterTab): void {
    this.activeFilterTab = tab;
    this.applyFilterAndSearch();
  }

  /**
   * 会话重命名 (非破坏性)
   */
  public async renameSession(conn: BotConnection, session: HermesSession, newTitle: string): Promise<boolean> {
    const trimmed = newTitle.trim();
    if (!trimmed) {
      this.actionError = '会话标题不能为空';
      return false;
    }

    try {
      if (conn.serverVersion !== 'legacy-webui') {
        const payload: SessionUpdatePayload = { title: trimmed };
        await HermesRESTClient.updateSession(
          conn.url,
          session.id,
          session.profile || this.currentProfile,
          payload,
          conn.token,
          conn.cookies
        );
      }
      session.title = trimmed;
      // 遍历更新本地池中对应项
      for (let i = 0; i < this.allSessions.length; i++) {
        if (this.allSessions[i].id === session.id) {
          this.allSessions[i].title = trimmed;
          break;
        }
      }
      this.applyFilterAndSearch();
      return true;
    } catch (e) {
      this.actionError = `改名失败: ${(e as Error).message || String(e)}`;
      return false;
    }
  }

  /**
   * 切换置顶状态
   */
  public async togglePinSession(conn: BotConnection, session: HermesSession): Promise<boolean> {
    const targetState = !session.is_pinned;
    try {
      if (conn.serverVersion !== 'legacy-webui') {
        const payload: SessionUpdatePayload = { pinned: targetState };
        await HermesRESTClient.updateSession(
          conn.url,
          session.id,
          session.profile || this.currentProfile,
          payload,
          conn.token,
          conn.cookies
        );
      }
      session.is_pinned = targetState;
      for (let i = 0; i < this.allSessions.length; i++) {
        if (this.allSessions[i].id === session.id) {
          this.allSessions[i].is_pinned = targetState;
          break;
        }
      }
      this.applyFilterAndSearch();
      return true;
    } catch (e) {
      this.actionError = `置顶操作失败: ${(e as Error).message || String(e)}`;
      return false;
    }
  }

  /**
   * 切换归档状态
   */
  public async toggleArchiveSession(conn: BotConnection, session: HermesSession): Promise<boolean> {
    const targetState = !session.is_archived;
    try {
      if (conn.serverVersion !== 'legacy-webui') {
        const payload: SessionUpdatePayload = { archived: targetState };
        await HermesRESTClient.updateSession(
          conn.url,
          session.id,
          session.profile || this.currentProfile,
          payload,
          conn.token,
          conn.cookies
        );
      }
      session.is_archived = targetState;
      for (let i = 0; i < this.allSessions.length; i++) {
        if (this.allSessions[i].id === session.id) {
          this.allSessions[i].is_archived = targetState;
          break;
        }
      }
      this.applyFilterAndSearch();
      return true;
    } catch (e) {
      this.actionError = `归档操作失败: ${(e as Error).message || String(e)}`;
      return false;
    }
  }

  /**
   * 克隆/分支会话
   */
  public async duplicateSession(conn: BotConnection, session: HermesSession): Promise<HermesSession> {
    if (conn.serverVersion === 'legacy-webui') {
      throw new Error('旧版 WebUI 不支持会话分支克隆');
    }
    const newSession = await HermesRESTClient.duplicateSession(
      conn.url,
      session.id,
      session.profile || this.currentProfile,
      session.title,
      conn.token,
      conn.cookies
    );
    // 插入列表首部
    this.allSessions.unshift(newSession);
    this.totalCount++;
    this.applyFilterAndSearch();
    return newSession;
  }

  /**
   * 导出完整会话 JSON 字符串
   */
  public async exportSession(conn: BotConnection, session: HermesSession): Promise<string> {
    if (conn.serverVersion === 'legacy-webui') {
      throw new Error('旧版 WebUI 不支持会话导出');
    }
    return await HermesRESTClient.exportSession(
      conn.url,
      session.id,
      session.profile || this.currentProfile,
      conn.token,
      conn.cookies
    );
  }

  /**
   * 真实在服务端创建会话并拿回真实会话身份
   */
  public async createSession(gateway: HermesGatewayClient, profile: string): Promise<HermesSession> {
    const res = await gateway.createSession(profile);
    const sid = String(res['session_id'] || res['id'] || '');
    if (!sid) {
      throw new Error('服务端未返回有效 session_id');
    }
    const session: HermesSession = {
      id: sid,
      runtime_id: sid,
      title: '新对话',
      profile: profile,
      created_at: Date.now(),
      updated_at: Date.now(),
      running: false,
      is_pinned: false,
      is_archived: false
    };
    this.allSessions.unshift(session);
    this.totalCount++;
    this.applyFilterAndSearch();
    return session;
  }

  /**
   * 去重辅助函数 (按 id 保持唯一，保留最新版本)
   */
  private deduplicateSessions(list: HermesSession[]): HermesSession[] {
    const seen = new Set<string>();
    const result: HermesSession[] = [];
    for (let i = 0; i < list.length; i++) {
      const s = list[i];
      if (!s.id || seen.has(s.id)) {
        continue;
      }
      seen.add(s.id);
      result.push(s);
    }
    return result;
  }

  /**
   * 综合应用当前过滤 Tab 与搜索词
   */
  private applyFilterAndSearch(): void {
    let filtered = this.allSessions.slice();

    // 1. 分类 Tab 过滤
    if (this.activeFilterTab === 'pinned') {
      filtered = filtered.filter(s => s.is_pinned === true);
    } else if (this.activeFilterTab === 'archived') {
      filtered = filtered.filter(s => s.is_archived === true);
    } else {
      // 'all' Tab 默认展示未归档会话
      filtered = filtered.filter(s => s.is_archived !== true);
    }

    // 2. 搜索词本地模糊匹配 (匹配标题、预览、会话ID)
    if (this.searchQuery.length > 0) {
      const q = this.searchQuery.toLowerCase();
      filtered = filtered.filter(s => {
        const titleMatch = (s.title || '').toLowerCase().includes(q);
        const previewMatch = (s.preview || '').toLowerCase().includes(q);
        const idMatch = s.id.toLowerCase().includes(q);
        return titleMatch || previewMatch || idMatch;
      });
    }

    // 3. 排序策略：置顶的会话排在前面，其余按 updated_at 倒序排列
    filtered.sort((a, b) => {
      if (a.is_pinned && !b.is_pinned) return -1;
      if (!a.is_pinned && b.is_pinned) return 1;
      return (b.updated_at || 0) - (a.updated_at || 0);
    });

    this.displayedSessions = filtered;
  }
}
