import { BotConnection, cloneConnection } from '../model/Connection';

/**
 * 服务器连接与身份凭证持久化管理
 * 具备隔离保护与内存状态同步
 */
export class AuthStore {
  private static instance: AuthStore | null = null;
  private connections: BotConnection[] = [];
  private currentConnectionId: string = '';

  private constructor() {
    this.initDefault();
  }

  public static getInstance(): AuthStore {
    if (!AuthStore.instance) {
      AuthStore.instance = new AuthStore();
    }
    return AuthStore.instance;
  }

  private initDefault(): void {
    this.connections = [];
  }

  public getConnections(): BotConnection[] {
    const list: BotConnection[] = [];
    for (let i = 0; i < this.connections.length; i++) {
      list.push(cloneConnection(this.connections[i]));
    }
    return list;
  }

  public getCurrentConnection(): BotConnection | null {
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].id === this.currentConnectionId) {
        return cloneConnection(this.connections[i]);
      }
    }
    if (this.connections.length > 0) {
      return cloneConnection(this.connections[0]);
    }
    return null;
  }

  public setCurrentConnection(id: string): void {
    this.currentConnectionId = id;
    for (let i = 0; i < this.connections.length; i++) {
      this.connections[i].isCurrent = (this.connections[i].id === id);
    }
  }

  public saveConnection(conn: BotConnection): void {
    let found = false;
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].id === conn.id) {
        this.connections[i] = cloneConnection(conn);
        found = true;
        break;
      }
    }
    if (!found) {
      this.connections.push(cloneConnection(conn));
    }
    if (!this.currentConnectionId || conn.isCurrent) {
      this.setCurrentConnection(conn.id);
    }
  }

  public removeConnection(id: string): void {
    const nextList: BotConnection[] = [];
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].id !== id) {
        nextList.push(this.connections[i]);
      }
    }
    this.connections = nextList;
    if (this.currentConnectionId === id) {
      this.currentConnectionId = this.connections.length > 0 ? this.connections[0].id : '';
    }
  }
}
