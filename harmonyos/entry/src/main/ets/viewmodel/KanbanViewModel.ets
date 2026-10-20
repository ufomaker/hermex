import { BotConnection } from '../model/Connection';
import {
  HermesKanbanClient,
  KanbanBoardSnapshot,
  KanbanColumnItem,
  KanbanCardItem,
  KanbanBoardItem,
  KanbanAvailability
} from '../network/HermesKanbanClient';

export interface KanbanViewModelListener {
  onStateChanged: () => void;
}

/**
 * 看板业务 ViewModel (F11)
 * 严格按照 upstream Kanban 契约实现可用性检测、看板列表、列与卡片快照管理、新建与状态流转，遵循只读权限保护
 */
export class KanbanViewModel {
  public isAvailable: boolean = false;
  public availability: KanbanAvailability | null = null;
  public boards: KanbanBoardItem[] = [];
  public selectedBoardSlug: string = '';
  public selectedBoardName: string = '';
  public isReadOnly: boolean = false;
  public currentSnapshot: KanbanBoardSnapshot | null = null;
  public isLoading: boolean = false;
  public statusMessage: string = '';

  private listener?: KanbanViewModelListener;

  public setListener(listener: KanbanViewModelListener) {
    this.listener = listener;
  }

  private notify() {
    if (this.listener) {
      this.listener.onStateChanged();
    }
  }

  /**
   * 加载所有看板与可用性状态
   */
  public async loadBoards(conn: BotConnection): Promise<void> {
    this.isLoading = true;
    this.statusMessage = '正在检测看板插件与看板列表...';
    this.notify();

    try {
      const avail = await HermesKanbanClient.checkAvailability(conn.url, conn.token, conn.cookies);
      this.availability = avail;
      this.isAvailable = avail.available;
      if (!avail.available) {
        this.statusMessage = avail.message;
        this.boards = [];
        this.currentSnapshot = null;
        this.notify();
        return;
      }

      const res = await HermesKanbanClient.getBoards(conn.url, conn.token, conn.cookies);
      this.boards = res.boards;
      this.isReadOnly = Boolean(res.readOnly);

      if (res.boards.length > 0) {
        let target = res.boards.find(b => b.slug === this.selectedBoardSlug);
        if (!target) {
          if (res.current) {
            target = res.boards.find(b => b.slug === res.current) || res.boards[0];
          } else {
            target = res.boards[0];
          }
        }
        this.selectedBoardSlug = target.slug;
        this.selectedBoardName = target.name;
        if (target.readOnly !== undefined) {
          this.isReadOnly = target.readOnly;
        }
        await this.loadBoardSnapshot(conn, target.slug);
      } else {
        this.statusMessage = '当前服务端未配置任何看板';
        this.currentSnapshot = null;
      }
    } catch (e) {
      this.statusMessage = `加载看板异常: ${e}`;
    } finally {
      this.isLoading = false;
      this.notify();
    }
  }

  /**
   * 加载指定看板卡片快照 (参数使用 boardSlug)
   */
  public async loadBoardSnapshot(conn: BotConnection, boardSlug: string): Promise<void> {
    this.selectedBoardSlug = boardSlug;
    const targetBoard = this.boards.find(b => b.slug === boardSlug);
    if (targetBoard) {
      this.selectedBoardName = targetBoard.name;
      if (targetBoard.readOnly !== undefined) {
        this.isReadOnly = targetBoard.readOnly;
      }
    }
    this.isLoading = true;
    this.statusMessage = `正在拉取看板【${this.selectedBoardName || boardSlug}】数据...`;
    this.notify();

    try {
      const snapshot = await HermesKanbanClient.getBoard(conn.url, boardSlug, conn.token, conn.cookies);
      this.currentSnapshot = snapshot;
      if (snapshot) {
        if (snapshot.readOnly !== undefined) {
          this.isReadOnly = snapshot.readOnly;
        }
        let totalCards = 0;
        for (let i = 0; i < snapshot.columns.length; i++) {
          totalCards += snapshot.columns[i].cards.length;
        }
        const roText = this.isReadOnly ? ' [只读模式]' : '';
        this.statusMessage = `已加载 ${snapshot.columns.length} 个泳道，共 ${totalCards} 张卡片${roText}`;
      } else {
        this.statusMessage = '未能获取到看板快照';
      }
    } catch (e) {
      this.statusMessage = `获取看板快照失败: ${e}`;
    } finally {
      this.isLoading = false;
      this.notify();
    }
  }

  /**
   * 在当前看板创建新卡片 (严格受只读权限保护)
   */
  public async createCard(
    conn: BotConnection,
    title: string,
    description?: string,
    assignee?: string
  ): Promise<boolean> {
    if (!this.selectedBoardSlug) {
      this.statusMessage = '未选择有效看板';
      this.notify();
      return false;
    }
    if (this.isReadOnly) {
      this.statusMessage = '当前看板处于只读模式，无法创建卡片';
      this.notify();
      return false;
    }
    this.isLoading = true;
    this.statusMessage = '正在创建卡片...';
    this.notify();

    try {
      const ok = await HermesKanbanClient.createCard(
        conn.url,
        this.selectedBoardSlug,
        title,
        description,
        assignee,
        conn.token,
        conn.cookies
      );
      if (ok) {
        await this.loadBoardSnapshot(conn, this.selectedBoardSlug);
        return true;
      } else {
        this.statusMessage = '创建卡片被服务端拒绝或失败';
        return false;
      }
    } catch (e) {
      this.statusMessage = `创建卡片异常: ${e}`;
      return false;
    } finally {
      this.isLoading = false;
      this.notify();
    }
  }

  /**
   * 变更卡片状态/流转泳道 (严格受只读权限保护)
   */
  public async updateCardStatus(
    conn: BotConnection,
    cardId: string,
    nextStatus: string
  ): Promise<boolean> {
    if (!this.selectedBoardSlug) {
      this.statusMessage = '未选择有效看板';
      this.notify();
      return false;
    }
    if (this.isReadOnly) {
      this.statusMessage = '当前看板处于只读模式，无法更新卡片状态';
      this.notify();
      return false;
    }
    this.isLoading = true;
    this.statusMessage = `正在通过 PATCH 更新卡片状态至 ${nextStatus}...`;
    this.notify();

    try {
      const ok = await HermesKanbanClient.updateCardStatus(
        conn.url,
        this.selectedBoardSlug,
        cardId,
        nextStatus,
        conn.token,
        conn.cookies
      );
      if (ok) {
        await this.loadBoardSnapshot(conn, this.selectedBoardSlug);
        return true;
      } else {
        this.statusMessage = '更新状态被服务端拒绝或失败';
        return false;
      }
    } catch (e) {
      this.statusMessage = `更新状态异常: ${e}`;
      return false;
    } finally {
      this.isLoading = false;
      this.notify();
    }
  }
}
