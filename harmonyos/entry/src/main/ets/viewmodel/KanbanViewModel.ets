import { BotConnection } from '../model/Connection';
import { HermesKanbanClient, KanbanBoardSnapshot, KanbanColumnItem, KanbanCardItem } from '../network/HermesKanbanClient';

export interface KanbanViewModelListener {
  onStateChanged: () => void;
}

/**
 * 看板业务 ViewModel (F11)
 * 严格按照 upstream Kanban 契约实现可用性检测、看板列表、列与卡片快照管理、新建与状态流转
 */
export class KanbanViewModel {
  public isAvailable: boolean = false;
  public boards: string[] = [];
  public selectedBoard: string = '';
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
      const avail = await HermesKanbanClient.isAvailable(conn.url, conn.token, conn.cookies);
      this.isAvailable = avail;
      if (!avail) {
        this.statusMessage = '服务端未启用看板插件 (/api/plugins/kanban)';
        this.boards = [];
        this.currentSnapshot = null;
        this.notify();
        return;
      }

      const boardList = await HermesKanbanClient.getBoards(conn.url, conn.token, conn.cookies);
      this.boards = boardList;

      if (boardList.length > 0) {
        if (!this.selectedBoard || !boardList.includes(this.selectedBoard)) {
          this.selectedBoard = boardList[0];
        }
        await this.loadBoardSnapshot(conn, this.selectedBoard);
      } else {
        this.statusMessage = '暂无可用的看板';
        this.currentSnapshot = null;
      }
    } catch (e) {
      this.statusMessage = `加载看板失败: ${e}`;
    } finally {
      this.isLoading = false;
      this.notify();
    }
  }

  /**
   * 加载指定看板卡片快照
   */
  public async loadBoardSnapshot(conn: BotConnection, boardName: string): Promise<void> {
    this.selectedBoard = boardName;
    this.isLoading = true;
    this.statusMessage = `正在拉取看板【${boardName}】数据...`;
    this.notify();

    try {
      const snapshot = await HermesKanbanClient.getBoard(conn.url, boardName, conn.token, conn.cookies);
      this.currentSnapshot = snapshot;
      if (snapshot) {
        let totalCards = 0;
        for (let i = 0; i < snapshot.columns.length; i++) {
          totalCards += snapshot.columns[i].cards.length;
        }
        this.statusMessage = `已加载 ${snapshot.columns.length} 个泳道，共 ${totalCards} 张卡片`;
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
   * 在当前看板创建新卡片
   */
  public async createCard(
    conn: BotConnection,
    title: string,
    description?: string,
    assignee?: string
  ): Promise<boolean> {
    if (!this.selectedBoard) {
      return false;
    }
    this.isLoading = true;
    this.statusMessage = '正在创建卡片...';
    this.notify();

    try {
      const ok = await HermesKanbanClient.createCard(
        conn.url,
        this.selectedBoard,
        title,
        description,
        assignee,
        conn.token,
        conn.cookies
      );
      if (ok) {
        await this.loadBoardSnapshot(conn, this.selectedBoard);
        return true;
      } else {
        this.statusMessage = '创建卡片被拒绝或失败';
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
   * 变更卡片状态/流转泳道
   */
  public async updateCardStatus(
    conn: BotConnection,
    cardId: string,
    nextStatus: string
  ): Promise<boolean> {
    if (!this.selectedBoard) {
      return false;
    }
    this.isLoading = true;
    this.statusMessage = `正在更新卡片状态至 ${nextStatus}...`;
    this.notify();

    try {
      const ok = await HermesKanbanClient.updateCardStatus(
        conn.url,
        this.selectedBoard,
        cardId,
        nextStatus,
        conn.token,
        conn.cookies
      );
      if (ok) {
        await this.loadBoardSnapshot(conn, this.selectedBoard);
        return true;
      } else {
        this.statusMessage = '更新状态失败';
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
