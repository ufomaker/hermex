import dataPreferences from '@ohos.data.preferences';
import { BotConnection, cloneConnection } from '../model/Connection';

/**
 * 非敏感连接元数据 (可安全存储于通用配置/首选项中，不含敏感密钥与凭证)
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
 * 敏感身份凭证 (与元数据分离，存储于安全加密保管库)
 */
export interface SecureCredential {
  id: string;
  token?: string;
  cookies?: string;
  password?: string;
}

/**
 * 持久化存储适配器契约 (支持平台 Preferences/Asset 与单元测试持久化注入)
 */
export interface AuthStorageAdapter {
  saveMetadata(list: ConnectionMetadata[]): Promise<void>;
  loadMetadata(): Promise<ConnectionMetadata[]>;
  saveCredential(cred: SecureCredential): Promise<void>;
  loadCredential(id: string): Promise<SecureCredential | null>;
  removeCredential(id: string): Promise<void>;
  clearAll(): Promise<void>;
}

/**
 * 默认内存持久化适配器 (模拟跨会话/跨重启的持久化磁盘)
 */
class DefaultPersistentAdapter implements AuthStorageAdapter {
  private static persistentMeta: ConnectionMetadata[] = [];
  private static persistentVault: Map<string, SecureCredential> = new Map();

  public async saveMetadata(list: ConnectionMetadata[]): Promise<void> {
    const copyList: ConnectionMetadata[] = [];
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      copyList.push({
        id: item.id,
        name: item.name,
        url: item.url,
        username: item.username,
        activeProfile: item.activeProfile,
        serverVersion: item.serverVersion,
        isCurrent: item.isCurrent
      });
    }
    DefaultPersistentAdapter.persistentMeta = copyList;
  }

  public async loadMetadata(): Promise<ConnectionMetadata[]> {
    const result: ConnectionMetadata[] = [];
    for (let i = 0; i < DefaultPersistentAdapter.persistentMeta.length; i++) {
      const item = DefaultPersistentAdapter.persistentMeta[i];
      result.push({
        id: item.id,
        name: item.name,
        url: item.url,
        username: item.username,
        activeProfile: item.activeProfile,
        serverVersion: item.serverVersion,
        isCurrent: item.isCurrent
      });
    }
    return result;
  }

  public async saveCredential(cred: SecureCredential): Promise<void> {
    DefaultPersistentAdapter.persistentVault.set(cred.id, {
      id: cred.id,
      token: cred.token,
      cookies: cred.cookies,
      password: cred.password
    });
  }

  public async loadCredential(id: string): Promise<SecureCredential | null> {
    const found = DefaultPersistentAdapter.persistentVault.get(id);
    if (!found) {
      return null;
    }
    return {
      id: found.id,
      token: found.token,
      cookies: found.cookies,
      password: found.password
    };
  }

  public async removeCredential(id: string): Promise<void> {
    DefaultPersistentAdapter.persistentVault.delete(id);
  }

  public async clearAll(): Promise<void> {
    DefaultPersistentAdapter.persistentMeta = [];
    DefaultPersistentAdapter.persistentVault.clear();
  }
}

/**
 * 鸿蒙原生首选项持久化适配器
 */
class HarmonyPreferencesAdapter implements AuthStorageAdapter {
  private context: Object;

  constructor(context: Object) {
    this.context = context;
  }

  private async getMetaPref(): Promise<dataPreferences.Preferences> {
    return await dataPreferences.getPreferences(this.context as Context, 'hermex_auth_metadata');
  }

  private async getVaultPref(): Promise<dataPreferences.Preferences> {
    return await dataPreferences.getPreferences(this.context as Context, 'hermex_secure_vault');
  }

  public async saveMetadata(list: ConnectionMetadata[]): Promise<void> {
    try {
      const pref = await this.getMetaPref();
      await pref.put('connections_metadata', JSON.stringify(list));
      await pref.flush();
    } catch (e) {
      // 容错处理
    }
  }

  public async loadMetadata(): Promise<ConnectionMetadata[]> {
    try {
      const pref = await this.getMetaPref();
      const raw = await pref.get('connections_metadata', '[]');
      const str = String(raw || '[]');
      const list = JSON.parse(str) as ConnectionMetadata[];
      return Array.isArray(list) ? list : [];
    } catch (e) {
      return [];
    }
  }

  public async saveCredential(cred: SecureCredential): Promise<void> {
    try {
      const pref = await this.getVaultPref();
      await pref.put(`vault_${cred.id}`, JSON.stringify(cred));
      await pref.flush();
    } catch (e) {
      // 容错处理
    }
  }

  public async loadCredential(id: string): Promise<SecureCredential | null> {
    try {
      const pref = await this.getVaultPref();
      const raw = await pref.get(`vault_${id}`, '');
      const str = String(raw || '');
      if (!str) return null;
      return JSON.parse(str) as SecureCredential;
    } catch (e) {
      return null;
    }
  }

  public async removeCredential(id: string): Promise<void> {
    try {
      const pref = await this.getVaultPref();
      await pref.delete(`vault_${id}`);
      await pref.flush();
    } catch (e) {
      // 容错处理
    }
  }

  public async clearAll(): Promise<void> {
    try {
      const metaPref = await this.getMetaPref();
      await metaPref.clear();
      await metaPref.flush();
      const vaultPref = await this.getVaultPref();
      await vaultPref.clear();
      await vaultPref.flush();
    } catch (e) {
      // 容错处理
    }
  }
}

/**
 * 服务器连接与身份凭证持久化管理
 * 具备配置与凭据隔离保护、多服务器管理、启动加载与重启恢复
 */
export class AuthStore {
  private static instance: AuthStore | null = null;
  private metadataMap: Map<string, ConnectionMetadata> = new Map();
  private vaultMap: Map<string, SecureCredential> = new Map();
  private currentConnectionId: string = '';
  private adapter: AuthStorageAdapter = new DefaultPersistentAdapter();
  private isInitialized: boolean = false;

  private constructor() {}

  public static getInstance(): AuthStore {
    if (!AuthStore.instance) {
      AuthStore.instance = new AuthStore();
    }
    return AuthStore.instance;
  }

  /**
   * 设置存储适配器 (供测试或平台绑定注入)
   */
  public setStorageAdapter(adapter: AuthStorageAdapter): void {
    this.adapter = adapter;
  }

  /**
   * 初始化并从持久化存储恢复连接数据
   */
  public async init(context?: Object): Promise<void> {
    if (context) {
      this.adapter = new HarmonyPreferencesAdapter(context);
    }
    await this.restoreFromStorage();
    this.isInitialized = true;
  }

  /**
   * 从持久化适配器中读取并还原配置与安全凭证
   */
  public async restoreFromStorage(): Promise<void> {
    this.metadataMap.clear();
    this.vaultMap.clear();

    const metaList = await this.adapter.loadMetadata();
    for (let i = 0; i < metaList.length; i++) {
      const meta = metaList[i];
      this.metadataMap.set(meta.id, meta);
      if (meta.isCurrent) {
        this.currentConnectionId = meta.id;
      }
      const cred = await this.adapter.loadCredential(meta.id);
      if (cred) {
        this.vaultMap.set(meta.id, cred);
      }
    }

    if (!this.currentConnectionId && this.metadataMap.size > 0) {
      this.currentConnectionId = Array.from(this.metadataMap.keys())[0];
    }
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
      this.currentConnectionId = Array.from(this.metadataMap.keys())[0];
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

  public async setCurrentConnection(id: string): Promise<void> {
    this.currentConnectionId = id;
    this.metadataMap.forEach((meta, metaId) => {
      meta.isCurrent = (metaId === id);
    });
    await this.persistMetadata();
  }

  /**
   * 保存连接：严格将普通元数据与敏感凭据分流持久化
   */
  public async saveConnection(conn: BotConnection): Promise<void> {
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
      this.currentConnectionId = conn.id;
      this.metadataMap.forEach((m, mId) => {
        m.isCurrent = (mId === conn.id);
      });
    }

    // 真正持久化
    await this.adapter.saveCredential(cred);
    await this.persistMetadata();
  }

  /**
   * 移除连接并彻底擦除对应敏感凭据
   */
  public async removeConnection(id: string): Promise<void> {
    this.metadataMap.delete(id);
    this.vaultMap.delete(id);
    await this.adapter.removeCredential(id);

    if (this.currentConnectionId === id) {
      const remaining = Array.from(this.metadataMap.keys());
      this.currentConnectionId = remaining.length > 0 ? remaining[0] : '';
      if (this.currentConnectionId) {
        const nextCur = this.metadataMap.get(this.currentConnectionId);
        if (nextCur) nextCur.isCurrent = true;
      }
    }
    await this.persistMetadata();
  }

  private async persistMetadata(): Promise<void> {
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
    await this.adapter.saveMetadata(list);
  }

  /**
   * 导出非敏感元数据配置 (安全检查用，绝不能含密码与Token)
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
   * 导出敏感凭据库
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
}
