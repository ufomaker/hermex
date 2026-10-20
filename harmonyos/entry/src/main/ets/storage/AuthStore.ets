import { BotConnection, cloneConnection } from '../model/Connection';

/**
 * 非敏感连接元数据 (可持久化于通用配置/首选项)
 */
export interface ConnectionMetadata {
  id: string;
  name: string;
  url: string;
  username?: string;
  activeProfile: string;
  serverVersion?: string;
  isCurrent: boolean;
}

/**
 * 敏感身份凭证 (与元数据严格隔离存储)
 */
export interface SecureCredential {
  id: string;
  token?: string;
  cookies?: string;
  password?: string;
}

/**
 * 服务器连接与身份凭证持久化管理
 * 具备配置与凭据隔离保护、多服务器管理与持久化同步
 */
export class AuthStore {
  private static instance: AuthStore | null = null;
  private metadataMap: Map<string, ConnectionMetadata> = new Map();
  private vaultMap: Map<string, SecureCredential> = new Map();
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
    this.metadataMap.clear();
    this.vaultMap.clear();
    this.currentConnectionId = '';
  }

  public getConnections(): BotConnection[] {
    const list: BotConnection[] = [];
    this.metadataMap.forEach((meta, id) => {
      const cred = this.vaultMap.get(id);
      const conn: BotConnection = {
        id: meta.id,
        name: meta.name,
        url: meta.url,
        username: meta.username,
        password: cred?.password,
        token: cred?.token,
        cookies: cred?.cookies,
        activeProfile: meta.activeProfile,
        serverVersion: meta.serverVersion,
        isCurrent: meta.isCurrent
      };
      list.push(conn);
    });
    return list;
  }

  public getCurrentConnection(): BotConnection | null {
    if (!this.currentConnectionId && this.metadataMap.size > 0) {
      const firstId = Array.from(this.metadataMap.keys())[0];
      this.currentConnectionId = firstId;
    }
    if (!this.currentConnectionId) {
      return null;
    }
    const meta = this.metadataMap.get(this.currentConnectionId);
    if (!meta) {
      return null;
    }
    const cred = this.vaultMap.get(this.currentConnectionId);
    const conn: BotConnection = {
      id: meta.id,
      name: meta.name,
      url: meta.url,
      username: meta.username,
      password: cred?.password,
      token: cred?.token,
      cookies: cred?.cookies,
      activeProfile: meta.activeProfile,
      serverVersion: meta.serverVersion,
      isCurrent: true
    };
    return conn;
  }

  public setCurrentConnection(id: string): void {
    this.currentConnectionId = id;
    this.metadataMap.forEach((meta, metaId) => {
      meta.isCurrent = (metaId === id);
    });
  }

  /**
   * 保存连接：严格将普通元数据与敏感凭证分流处理
   */
  public saveConnection(conn: BotConnection): void {
    const meta: ConnectionMetadata = {
      id: conn.id,
      name: conn.name,
      url: conn.url,
      username: conn.username,
      activeProfile: conn.activeProfile || 'default',
      serverVersion: conn.serverVersion,
      isCurrent: Boolean(conn.isCurrent)
    };
    this.metadataMap.set(conn.id, meta);

    const cred: SecureCredential = {
      id: conn.id,
      token: conn.token,
      cookies: conn.cookies,
      password: conn.password
    };
    this.vaultMap.set(conn.id, cred);

    if (!this.currentConnectionId || conn.isCurrent) {
      this.setCurrentConnection(conn.id);
    }
  }

  /**
   * 移除连接并彻底擦除对应敏感凭据
   */
  public removeConnection(id: string): void {
    this.metadataMap.delete(id);
    this.vaultMap.delete(id);
    if (this.currentConnectionId === id) {
      const remaining = Array.from(this.metadataMap.keys());
      this.currentConnectionId = remaining.length > 0 ? remaining[0] : '';
      if (this.currentConnectionId) {
        this.setCurrentConnection(this.currentConnectionId);
      }
    }
  }

  /**
   * 导出非敏感元数据配置 JSON (安全用于备份或配置存储)
   */
  public exportMetadata(): ConnectionMetadata[] {
    const list: ConnectionMetadata[] = [];
    this.metadataMap.forEach((m) => {
      list.push({
        id: m.id,
        name: m.name,
        url: m.url,
        username: m.username,
        activeProfile: m.activeProfile,
        serverVersion: m.serverVersion,
        isCurrent: m.isCurrent
      });
    });
    return list;
  }

  /**
   * 导出敏感凭据 (受安全存储隔离保护)
   */
  public exportVault(): SecureCredential[] {
    const list: SecureCredential[] = [];
    this.vaultMap.forEach((c) => {
      list.push({
        id: c.id,
        token: c.token,
        cookies: c.cookies,
        password: c.password
      });
    });
    return list;
  }

  /**
   * 从持久化存储还原
   */
  public loadFromStores(metaList: ConnectionMetadata[], credList: SecureCredential[]): void {
    this.metadataMap.clear();
    this.vaultMap.clear();

    for (let i = 0; i < metaList.length; i++) {
      const m = metaList[i];
      const copyMeta: ConnectionMetadata = {
        id: m.id,
        name: m.name,
        url: m.url,
        username: m.username,
        activeProfile: m.activeProfile,
        serverVersion: m.serverVersion,
        isCurrent: m.isCurrent
      };
      this.metadataMap.set(m.id, copyMeta);
      if (m.isCurrent) {
        this.currentConnectionId = m.id;
      }
    }

    for (let i = 0; i < credList.length; i++) {
      const c = credList[i];
      const copyCred: SecureCredential = {
        id: c.id,
        token: c.token,
        cookies: c.cookies,
        password: c.password
      };
      this.vaultMap.set(c.id, copyCred);
    }
  }
}
