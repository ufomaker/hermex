import { HermesSession, cloneSession } from '../model/Session';
import { HermesRESTClient, SessionUpdatePayload } from '../network/HermesRESTClient';
import { HermesGatewayClient } from '../network/HermesGatewayClient';
import { LegacySSEClient } from '../network/legacy/LegacySSEClient';
import { BotConnection } from '../model/Connection';

export type SessionFilterTab = 'all' | 'pinned' | 'archived';

/**
 * 单一归档维度的会话分页流状态
 * 严格对齐上游 HermesSessionPages (HermesSessionPage.swift:207-270)
 */
export class SessionStreamState {
  public sessions: HermesSession[] = [];
  public identities: Set<string> = new Set<string>();
  public nextOffset: number = 0;
  public total: number = 0;
  public hasMore: boolean = true;
  public isLoaded: boolean = false;
  public isLoading: boolean = false;
  public isLoadingMore: boolean = false;

  public reset(): void {
    this.sessions = [];
    this.identities.clear();
    this.nextOffset = 0;
    this.total = 0;
    this.hasMore = true;
    this.isLoaded = false;
    this.isLoading = false;
    this.isLoadingMore = false;
  }

  public appendPage(pageSessions: HermesSession[], pageSize: number, isArchivedTarget: boolean, serverTotal?: number): void {
    let added = 0;
    for (let i = 0; i < pageSessions.length; i++) {
      const s = pageSessions[i];
      if (!s.id) {
        continue;
      }
      // 过滤非目标归档状态 (例如排除服务端向归档流回填的未归档置顶会话)
      if (Boolean(s.is_archived) !== isArchivedTarget) {
        continue;
      }
      if (!this.identities.has(s.id)) {
        this.identities.add(s.id);
        this.sessions.push(s);
        added++;
      } else {
        // 就地刷新属性
        for (let j = 0; j < this.sessions.length; j++) {
          if (this.sessions[j].id === s.id) {
            this.sessions[j] = s;
            break;
          }
        }
      }
    }
    this.nextOffset += pageSize;
    // 对齐上游 HermesSessionPages.append: hasMore = page.count >= limit && added > 0
    this.hasMore = pageSessions.length >= pageSize && added > 0;
    this.isLoaded = true;
    if (typeof serverTotal === 'number') {
      this.total = serverTotal;
    } else {
      this.total = this.sessions.length;
    }
  }

  public remove(id: string): void {
    if (this.identities.has(id)) {
      this.identities.delete(id);
      this.total = Math.max(0, this.total - 1);
    }
    const nextList: HermesSession[] = [];
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id !== id) {
        nextList.push(this.sessions[i]);
      }
    }
    this.sessions = nextList;
  }

  public add(session: HermesSession): void {
    if (!session.id) return;
    this.remove(session.id);
    this.identities.add(session.id);
    this.sessions.unshift(session);
    this.total++;
  }
}

/**
 * 会话列表视图模型
 * 严格支持多服务器/Profile隔离、独立活跃流与归档流分页、防竞态代次保护、即时模糊搜索与一键清空恢复
 */
export class SessionListViewModel {
  // 活跃会话分页流 (archived: false / archived=exclude)
  private activeStream: SessionStreamState = new SessionStreamState();
  // 归档会话分页流 (archived: true / archived=only)
  private archivedStream: SessionStreamState = new SessionStreamState();

  // 最终呈现给 UI 的会话列表
  private displayedSessions: HermesSession[] = [];

  private isLoading: boolean = false;
  private isLoadingMore: boolean = false;
  private pageSize: number = 20;

  private searchQuery: string = '';
  private activeFilterTab: SessionFilterTab = 'all';

  // 显式服务器与 Profile 所有者身份 + 请求代次
  private currentServerUrl: string = '';
  private currentProfile: string = '';
  private requestSerial: number = 0;
  private searchRequestSerial: number = 0;
  private actionError: string | null = null;

  public getSessions(): HermesSession[] {
    return this.displayedSessions;
  }

  public getRawSessions(): HermesSession[] {
    return this.activeFilterTab === 'archived' ? this.archivedStream.sessions : this.activeStream.sessions;
  }

  public getIsLoading(): boolean {
    return this.isLoading;
  }

  public getIsLoadingMore(): boolean {
    return this.isLoadingMore;
  }

  public getHasMore(): boolean {
    return this.activeFilterTab === 'archived' ? this.archivedStream.hasMore : this.activeStream.hasMore;
  }

  public getTotalCount(): number {
    const stream = this.activeFilterTab === 'archived' ? this.archivedStream : this.activeStream;
    return stream.total > 0 ? stream.total : stream.sessions.length;
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
   * 检查连接所有者身份是否匹配
   */
  public isMatchingOwner(conn?: BotConnection | null): boolean {
    if (!conn) return false;
    const p = conn.activeProfile || 'default';
    return this.currentServerUrl === conn.url && this.currentProfile === p;
  }

  /**
   * 首次/重新加载会话列表 (支持 legacy-webui 与 Hermes 直连)
   * 若服务器或 profile 变更，立即清空旧会话池与展示列表，杜绝脏数据残留
   */
  public async loadSessions(conn: BotConnection): Promise<HermesSession[]> {
    const p = conn.activeProfile || 'default';
    const serverChanged = (this.currentServerUrl !== conn.url || this.currentProfile !== p);

    if (serverChanged) {
      // 切换连接时立即物理清空旧池，防止请求失败时仍然显示前一个服务器的会话
      this.currentServerUrl = conn.url;
      this.currentProfile = p;
      this.activeStream.reset();
      this.archivedStream.reset();
      this.displayedSessions = [];
      this.searchQuery = '';
    }

    this.requestSerial++;
    const thisSerial = this.requestSerial;
    this.isLoading = true;
    this.actionError = null;

    try {
      if (conn.serverVersion === 'legacy-webui') {
        const legacyItems = await LegacySSEClient.listSessions(conn.url, conn.token, conn.cookies);
        if (thisSerial !== this.requestSerial || !this.isMatchingOwner(conn)) {
          return this.displayedSessions;
        }
        this.activeStream.reset();
        this.activeStream.sessions = legacyItems.map((item) => {
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
        for (let i = 0; i < this.activeStream.sessions.length; i++) {
          this.activeStream.identities.add(this.activeStream.sessions[i].id);
        }
        this.activeStream.hasMore = false;
        this.activeStream.isLoaded = true;
        this.archivedStream.reset();
        this.archivedStream.hasMore = false;
        this.applyFilterAndSearch();
        return this.displayedSessions;
      }

      // Hermes 直连：按当前选中的 Tab 拉取对应 stream
      const isArchived = (this.activeFilterTab === 'archived');
      const res = await HermesRESTClient.listSessionsPage(
        conn.url,
        this.currentProfile,
        conn.token,
        conn.cookies,
        0,
        this.pageSize,
        isArchived
      );

      if (thisSerial !== this.requestSerial || !this.isMatchingOwner(conn)) {
        return this.displayedSessions;
      }

      if (isArchived) {
        this.archivedStream.reset();
        this.archivedStream.appendPage(res.sessions, this.pageSize, true, res.total);
      } else {
        this.activeStream.reset();
        this.activeStream.appendPage(res.sessions, this.pageSize, false, res.total);
      }

      this.applyFilterAndSearch();
      return this.displayedSessions;
    } catch (e) {
      if (thisSerial === this.requestSerial && this.isMatchingOwner(conn)) {
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
    if (!this.isMatchingOwner(conn) || conn.serverVersion === 'legacy-webui') {
      return false;
    }
    if (this.isLoading || this.isLoadingMore) {
      return false;
    }

    const isArchived = (this.activeFilterTab === 'archived');
    const stream = isArchived ? this.archivedStream : this.activeStream;
    if (!stream.hasMore) {
      return false;
    }

    this.isLoadingMore = true;
    stream.isLoadingMore = true;
    this.requestSerial++;
    const thisSerial = this.requestSerial;

    try {
      const res = await HermesRESTClient.listSessionsPage(
        conn.url,
        this.currentProfile,
        conn.token,
        conn.cookies,
        stream.nextOffset,
        this.pageSize,
        isArchived
      );

      if (thisSerial !== this.requestSerial || !this.isMatchingOwner(conn)) {
        return false;
      }

      stream.appendPage(res.sessions, this.pageSize, isArchived, res.total);
      this.applyFilterAndSearch();
      return true;
    } catch (e) {
      if (thisSerial === this.requestSerial && this.isMatchingOwner(conn)) {
        this.actionError = `加载更多失败: ${(e as Error).message || String(e)}`;
      }
      return false;
    } finally {
      if (thisSerial === this.requestSerial) {
        this.isLoadingMore = false;
        stream.isLoadingMore = false;
      }
    }
  }

  /**
   * 设置搜索词 (即时本地检索 + 触发服务端检索)
   * 严格核验代次与当前连接，杜绝慢搜索污染其他服务器或旧会话池
   */
  public async setSearchQuery(query: string, conn?: BotConnection | null): Promise<void> {
    this.searchQuery = (query || '').trim();
    this.applyFilterAndSearch();

    const thisSearchSerial = ++this.searchRequestSerial;

    if (this.searchQuery.length > 0 && conn && conn.serverVersion !== 'legacy-webui') {
      const capturedUrl = conn.url;
      const capturedProfile = conn.activeProfile || 'default';
      try {
        const serverResults = await HermesRESTClient.searchSessions(
          capturedUrl,
          capturedProfile,
          this.searchQuery,
          conn.token,
          conn.cookies,
          20
        );

        // 严格代次与连接归属核验！慢请求返回若连接已切换，必须直接丢弃
        if (thisSearchSerial === this.searchRequestSerial &&
            this.currentServerUrl === capturedUrl &&
            this.currentProfile === capturedProfile &&
            this.searchQuery.length > 0) {
          for (let i = 0; i < serverResults.length; i++) {
            const s = serverResults[i];
            if (Boolean(s.is_archived)) {
              if (!this.archivedStream.identities.has(s.id)) {
                this.archivedStream.identities.add(s.id);
                this.archivedStream.sessions.push(s);
              }
            } else {
              if (!this.activeStream.identities.has(s.id)) {
                this.activeStream.identities.add(s.id);
                this.activeStream.sessions.push(s);
              }
            }
          }
          this.applyFilterAndSearch();
        }
      } catch (_e) {
        // 服务端检索容错回退纯本地过滤
      }
    }
  }

  /**
   * 清除搜索词并无损恢复全量列表
   */
  public clearSearch(): void {
    this.searchQuery = '';
    this.searchRequestSerial++;
    this.applyFilterAndSearch();
  }

  /**
   * 切换视图分类 Tab ('all' | 'pinned' | 'archived')
   * 若切换至 'archived' 且尚未从服务端加载归档页，自动异步拉取
   */
  public async setFilterTab(tab: SessionFilterTab, conn?: BotConnection | null): Promise<void> {
    this.activeFilterTab = tab;
    if (tab === 'archived' && !this.archivedStream.isLoaded && conn && conn.serverVersion !== 'legacy-webui') {
      await this.loadSessions(conn);
    } else {
      this.applyFilterAndSearch();
    }
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

    if (conn.serverVersion === 'legacy-webui') {
      this.actionError = '旧版 WebUI 不支持会话重命名';
      return false;
    }

    if (!this.isMatchingOwner(conn)) {
      this.actionError = '连接状态已变更';
      return false;
    }

    try {
      const payload: SessionUpdatePayload = { title: trimmed };
      await HermesRESTClient.updateSession(
        conn.url,
        session.id,
        session.profile || this.currentProfile,
        payload,
        conn.token,
        conn.cookies
      );

      if (!this.isMatchingOwner(conn)) {
        return false;
      }

      session.title = trimmed;
      // 在两个 stream 中更新对应项
      for (let i = 0; i < this.activeStream.sessions.length; i++) {
        if (this.activeStream.sessions[i].id === session.id) {
          this.activeStream.sessions[i].title = trimmed;
          break;
        }
      }
      for (let i = 0; i < this.archivedStream.sessions.length; i++) {
        if (this.archivedStream.sessions[i].id === session.id) {
          this.archivedStream.sessions[i].title = trimmed;
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
    if (conn.serverVersion === 'legacy-webui') {
      this.actionError = '旧版 WebUI 不支持会话置顶';
      return false;
    }

    if (!this.isMatchingOwner(conn)) {
      this.actionError = '连接状态已变更';
      return false;
    }

    const targetState = !session.is_pinned;
    try {
      const payload: SessionUpdatePayload = { pinned: targetState };
      await HermesRESTClient.updateSession(
        conn.url,
        session.id,
        session.profile || this.currentProfile,
        payload,
        conn.token,
        conn.cookies
      );

      if (!this.isMatchingOwner(conn)) {
        return false;
      }

      session.is_pinned = targetState;
      for (let i = 0; i < this.activeStream.sessions.length; i++) {
        if (this.activeStream.sessions[i].id === session.id) {
          this.activeStream.sessions[i].is_pinned = targetState;
          break;
        }
      }
      for (let i = 0; i < this.archivedStream.sessions.length; i++) {
        if (this.archivedStream.sessions[i].id === session.id) {
          this.archivedStream.sessions[i].is_pinned = targetState;
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
   * 严格实现归档流与活跃流之间的双向转移
   */
  public async toggleArchiveSession(conn: BotConnection, session: HermesSession): Promise<boolean> {
    if (conn.serverVersion === 'legacy-webui') {
      this.actionError = '旧版 WebUI 不支持会话归档';
      return false;
    }

    if (!this.isMatchingOwner(conn)) {
      this.actionError = '连接状态已变更';
      return false;
    }

    const targetState = !session.is_archived;
    try {
      const payload: SessionUpdatePayload = { archived: targetState };
      await HermesRESTClient.updateSession(
        conn.url,
        session.id,
        session.profile || this.currentProfile,
        payload,
        conn.token,
        conn.cookies
      );

      if (!this.isMatchingOwner(conn)) {
        return false;
      }

      session.is_archived = targetState;
      if (targetState === true) {
        // 移入归档流，移出活跃流
        this.activeStream.remove(session.id);
        this.archivedStream.add(session);
      } else {
        // 移出归档流，移入活跃流
        this.archivedStream.remove(session.id);
        this.activeStream.add(session);
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
    if (!this.isMatchingOwner(conn)) {
      throw new Error('连接状态已变更');
    }
    const newSession = await HermesRESTClient.duplicateSession(
      conn.url,
      session.id,
      session.profile || this.currentProfile,
      session.title,
      conn.token,
      conn.cookies
    );

    if (this.isMatchingOwner(conn)) {
      this.activeStream.add(newSession);
      this.applyFilterAndSearch();
    }
    return newSession;
  }

  /**
   * 导出完整会话 JSON 字符串
   */
  public async exportSession(conn: BotConnection, session: HermesSession): Promise<string> {
    if (conn.serverVersion === 'legacy-webui') {
      throw new Error('旧版 WebUI 不支持会话导出');
    }
    if (!this.isMatchingOwner(conn)) {
      throw new Error('连接状态已变更');
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
    this.activeStream.add(session);
    this.applyFilterAndSearch();
    return session;
  }

  /**
   * 综合应用当前过滤 Tab 与搜索词
   */
  private applyFilterAndSearch(): void {
    let sourceList: HermesSession[] = [];

    // 1. 根据当前 Tab 从独立流获取会话数据
    if (this.activeFilterTab === 'archived') {
      sourceList = this.archivedStream.sessions.slice();
    } else if (this.activeFilterTab === 'pinned') {
      sourceList = this.activeStream.sessions.filter(s => s.is_pinned === true && !s.is_archived);
    } else {
      sourceList = this.activeStream.sessions.filter(s => !s.is_archived);
    }

    // 2. 搜索词过滤 (匹配标题、预览、会话ID)
    if (this.searchQuery.length > 0) {
      const q = this.searchQuery.toLowerCase();
      sourceList = sourceList.filter(s => {
        const titleMatch = (s.title || '').toLowerCase().includes(q);
        const previewMatch = (s.preview || '').toLowerCase().includes(q);
        const idMatch = s.id.toLowerCase().includes(q);
        return titleMatch || previewMatch || idMatch;
      });
    }

    // 3. 排序策略：置顶优先，最新活跃优先
    sourceList.sort((a, b) => {
      if (a.is_pinned && !b.is_pinned) return -1;
      if (!a.is_pinned && b.is_pinned) return 1;
      return (b.updated_at || 0) - (a.updated_at || 0);
    });

    this.displayedSessions = sourceList;
  }
}
