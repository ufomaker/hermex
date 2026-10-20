import dataPreferences from '@ohos.data.preferences';
import asset from '@ohos.security.asset';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { BotConnection, cloneConnection } from '../model/Connection';

/**
 * 非敏感连接元数据 (可安全存储于通用首选项中，不含敏感密钥、Token与密码)
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
 * 敏感身份凭证 (与元数据分离，必须存储于平台硬件保护的 Asset Store 凭据保管库)
 */
export interface SecureCredential {
  id: string;
  token?: string;
  cookies?: string;
  password?: string;
}

/**
 * 持久化存储适配器契约 (支持平台 Preferences/Asset 与测试注入)
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
 * 默认内存持久化适配器 (仅供独立测试或 Mock 模式使用)
 */
export class DefaultPersistentAdapter implements AuthStorageAdapter {
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
 * 鸿蒙原生平台安全持久化适配器
 * - 非敏感连接元数据 -> @ohos.data.preferences (配置存储)
 * - 敏感身份凭证 (Token/Cookie/密码) -> @ohos.security.asset (硬件级 Keystore/AssetStoreKit 密文保管库)
 * - 杜绝静默吞错：所有写入/删除异常严格传播，确保数据真实持久化
 */
export class HarmonyPlatformAuthAdapter implements AuthStorageAdapter {
  private context: Object;

  constructor(context: Object) {
    this.context = context;
  }

  private async getMetaPref(): Promise<dataPreferences.Preferences> {
    return await dataPreferences.getPreferences(this.context as Context, 'hermex_auth_metadata');
  }

  public async saveMetadata(list: ConnectionMetadata[]): Promise<void> {
    const pref = await this.getMetaPref();
    await pref.put('connections_metadata', JSON.stringify(list));
    await pref.flush();
  }

  public async loadMetadata(): Promise<ConnectionMetadata[]> {
    const pref = await this.getMetaPref();
    const raw = await pref.get('connections_metadata', '[]');
    const str = String(raw || '[]');
    const list = JSON.parse(str) as ConnectionMetadata[];
    return Array.isArray(list) ? list : [];
  }

  public async saveCredential(cred: SecureCredential): Promise<void> {
    const aliasBytes = HarmonyPlatformAuthAdapter.stringToUint8Array(`hermex_cred_${cred.id}`);
    const secretBytes = HarmonyPlatformAuthAdapter.stringToUint8Array(JSON.stringify(cred));

    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.ALIAS, aliasBytes);
    attr.set(asset.Tag.SECRET, secretBytes);

    try {
      await asset.add(attr);
    } catch (err) {
      const bErr = err as BusinessError;
      // 24000003: Asset already exists -> 执行更新
      if (bErr && bErr.code === 24000003) {
        const query: asset.AssetMap = new Map();
        query.set(asset.Tag.ALIAS, aliasBytes);
        const updateAttrs: asset.AssetMap = new Map();
        updateAttrs.set(asset.Tag.SECRET, secretBytes);
        await asset.update(query, updateAttrs);
      } else {
        if (err instanceof Error) {
          throw err;
        }
        throw new Error(`Asset add/update failed: ${err}`);
      }
    }
  }

  public async loadCredential(id: string): Promise<SecureCredential | null> {
    const aliasBytes = HarmonyPlatformAuthAdapter.stringToUint8Array(`hermex_cred_${id}`);
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, aliasBytes);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);

    try {
      const res = await asset.query(query);
      if (res && res.length > 0) {
        const secretVal = res[0].get(asset.Tag.SECRET) as Uint8Array;
        if (secretVal) {
          const jsonStr = HarmonyPlatformAuthAdapter.uint8ArrayToString(secretVal);
          return JSON.parse(jsonStr) as SecureCredential;
        }
      }
      return null;
    } catch (err) {
      const bErr = err as BusinessError;
      // 24000002: Asset not found
      if (bErr && bErr.code === 24000002) {
        return null;
      }
      if (err instanceof Error) {
        throw err;
      }
      throw new Error(`Asset query failed: ${err}`);
    }
  }

  public async removeCredential(id: string): Promise<void> {
    const aliasBytes = HarmonyPlatformAuthAdapter.stringToUint8Array(`hermex_cred_${id}`);
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, aliasBytes);

    try {
      await asset.remove(query);
    } catch (err) {
      const bErr = err as BusinessError;
      // 24000002: Asset not found，已经不存在则视为成功
      if (bErr && bErr.code === 24000002) {
        return;
      }
      if (err instanceof Error) {
        throw err;
      }
      throw new Error(`Asset remove failed: ${err}`);
    }
  }

  public async clearAll(): Promise<void> {
    try {
      const metaList = await this.loadMetadata();
      for (let i = 0; i < metaList.length; i++) {
        try {
          await this.removeCredential(metaList[i].id);
        } catch (_e) {
          // 清除流程中吞噬个别凭据清除异常，确保所有凭据尽可能清理完毕
        }
      }
    } catch (_e) {
      // 容错处理
    }
    const pref = await this.getMetaPref();
    await pref.clear();
    await pref.flush();
  }

  public static stringToUint8Array(str: string): Uint8Array {
    try {
      const enc = new util.TextEncoder('utf-8');
      return enc.encodeInto(str);
    } catch (_e) {
      return HarmonyPlatformAuthAdapter.utf8EncodeFallback(str);
    }
  }

  public static uint8ArrayToString(arr: Uint8Array): string {
    try {
      const dec = util.TextDecoder.create('utf-8');
      return dec.decodeToString(arr);
    } catch (_e) {
      return HarmonyPlatformAuthAdapter.utf8DecodeFallback(arr);
    }
  }

  public static utf8EncodeFallback(str: string): Uint8Array {
    const codePoints: number[] = [];
    for (let i = 0; i < str.length; i++) {
      let code = str.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
        const next = str.charCodeAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          code = ((code - 0xD800) << 10) + (next - 0xDC00) + 0x10000;
          i++;
        }
      }
      if (code < 0x80) {
        codePoints.push(code);
      } else if (code < 0x800) {
        codePoints.push(0xC0 | (code >> 6));
        codePoints.push(0x80 | (code & 0x3F));
      } else if (code < 0x10000) {
        codePoints.push(0xE0 | (code >> 12));
        codePoints.push(0x80 | ((code >> 6) & 0x3F));
        codePoints.push(0x80 | (code & 0x3F));
      } else {
        codePoints.push(0xF0 | (code >> 18));
        codePoints.push(0x80 | ((code >> 12) & 0x3F));
        codePoints.push(0x80 | ((code >> 6) & 0x3F));
        codePoints.push(0x80 | (code & 0x3F));
      }
    }
    return new Uint8Array(codePoints);
  }

  public static utf8DecodeFallback(arr: Uint8Array): string {
    let result = '';
    let i = 0;
    while (i < arr.length) {
      const b0 = arr[i++];
      if (b0 < 0x80) {
        result += String.fromCharCode(b0);
      } else if ((b0 & 0xE0) === 0xC0) {
        const b1 = arr[i++];
        result += String.fromCharCode(((b0 & 0x1F) << 6) | (b1 & 0x3F));
      } else if ((b0 & 0xF0) === 0xE0) {
        const b1 = arr[i++];
        const b2 = arr[i++];
        result += String.fromCharCode(((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F));
      } else if ((b0 & 0xF8) === 0xF0) {
        const b1 = arr[i++];
        const b2 = arr[i++];
        const b3 = arr[i++];
        let code = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
        code -= 0x10000;
        result += String.fromCharCode(0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF));
      }
    }
    return result;
  }
}

/**
 * 服务器连接与身份凭证持久化管理单例
 * - 统一启动 ready Promise，页面启动时 await waitUntilReady()
 * - 普通元数据与敏感凭据物理隔离，敏感凭据全量托管于硬件级 Asset Store
 * - 异常传播保护：异常时不破坏现有内存状态，杜绝静默失败
 */
export class AuthStore {
  private static instance: AuthStore | null = null;
  private metadataMap: Map<string, ConnectionMetadata> = new Map();
  private vaultMap: Map<string, SecureCredential> = new Map();
  private currentConnectionId: string = '';
  private adapter: AuthStorageAdapter = new DefaultPersistentAdapter();
  private isReady: boolean = false;
  private initPromise: Promise<void> | null = null;

  private constructor() {}

  public static getInstance(): AuthStore {
    if (!AuthStore.instance) {
      AuthStore.instance = new AuthStore();
    }
    return AuthStore.instance;
  }

  /**
   * 注入存储适配器 (供测试或平台绑定注入)
   */
  public setStorageAdapter(adapter: AuthStorageAdapter): void {
    this.adapter = adapter;
    this.isReady = false;
    this.initPromise = null;
  }

  /**
   * 初始化并从持久化存储恢复连接数据 (返回可等待的 Promise)
   */
  public init(context?: Object): Promise<void> {
    if (!this.initPromise) {
      this.initPromise = (async () => {
        if (context) {
          this.adapter = new HarmonyPlatformAuthAdapter(context);
        }
        await this.restoreFromStorage();
        this.isReady = true;
      })();
    }
    return this.initPromise;
  }

  /**
   * 确保等待存储初始化与冷启动恢复完成
   */
  public async waitUntilReady(): Promise<void> {
    if (this.isReady) {
      return;
    }
    if (this.initPromise) {
      await this.initPromise;
    }
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
      const keys = Array.from(this.metadataMap.keys());
      this.currentConnectionId = keys[0];
    }
  }

  public getConnections(): BotConnection[] {
    const list: BotConnection[] = [];
    this.metadataMap.forEach((meta, id) => {
      const cred = this.vaultMap.get(id);
      list.push({
        id: meta.id,
        name: meta.name,
        url: meta.url,
        username: meta.username,
        token: cred ? cred.token : undefined,
        cookies: cred ? cred.cookies : undefined,
        password: cred ? cred.password : undefined,
        activeProfile: meta.activeProfile,
        serverVersion: meta.serverVersion,
        isCurrent: (id === this.currentConnectionId)
      });
    });
    return list;
  }

  public getConnection(id: string): BotConnection | null {
    const meta = this.metadataMap.get(id);
    if (!meta) {
      return null;
    }
    const cred = this.vaultMap.get(id);
    return {
      id: meta.id,
      name: meta.name,
      url: meta.url,
      username: meta.username,
      token: cred ? cred.token : undefined,
      cookies: cred ? cred.cookies : undefined,
      password: cred ? cred.password : undefined,
      activeProfile: meta.activeProfile,
      serverVersion: meta.serverVersion,
      isCurrent: (id === this.currentConnectionId)
    };
  }

  public getCurrentConnection(): BotConnection | null {
    if (!this.currentConnectionId) {
      if (this.metadataMap.size > 0) {
        const keys = Array.from(this.metadataMap.keys());
        this.currentConnectionId = keys[0];
      } else {
        return null;
      }
    }
    return this.getConnection(this.currentConnectionId);
  }

  public async setCurrentConnection(id: string): Promise<void> {
    this.currentConnectionId = id;
    this.metadataMap.forEach((meta, metaId) => {
      meta.isCurrent = (metaId === id);
    });
    await this.persistMetadata();
  }

  /**
   * 保存连接：先物理持久化敏感凭据到安全保管库，再写入元数据与更新内存
   * 包含原子回滚：如果后续元数据落盘失败，立即恢复内存映射与选中态，杜绝内存与磁盘不一致
   */
  public async saveConnection(conn: BotConnection): Promise<void> {
    const meta: ConnectionMetadata = {
      id: conn.id,
      name: conn.name,
      url: conn.url,
      username: conn.username,
      activeProfile: conn.activeProfile || 'default',
      serverVersion: conn.serverVersion,
      isCurrent: conn.isCurrent || false
    };

    const cred: SecureCredential = {
      id: conn.id,
      token: conn.token,
      cookies: conn.cookies,
      password: conn.password
    };

    // 快照旧内存状态以便发生异常时原子回滚
    const prevMeta = this.metadataMap.get(conn.id);
    const prevCred = this.vaultMap.get(conn.id);
    const prevCurrentId = this.currentConnectionId;

    // 1. 物理写入安全硬件保管库 (若失败会抛出异常，杜绝伪成功)
    await this.adapter.saveCredential(cred);

    // 2. 更新内存映射
    this.metadataMap.set(conn.id, meta);
    this.vaultMap.set(conn.id, cred);

    if (!this.currentConnectionId || conn.isCurrent) {
      this.currentConnectionId = conn.id;
      this.metadataMap.forEach((m, mId) => {
        m.isCurrent = (mId === conn.id);
      });
    }

    // 3. 物理持久化元数据 (若失败必须原子回滚内存映射与保管库，保持一致性)
    try {
      await this.persistMetadata();
    } catch (err) {
      // 物理回滚凭证保管库状态
      if (!prevCred) {
        try {
          await this.adapter.removeCredential(conn.id);
        } catch (_ignore) {}
      } else {
        try {
          await this.adapter.saveCredential(prevCred);
        } catch (_ignore) {}
      }

      if (prevMeta) {
        this.metadataMap.set(conn.id, prevMeta);
      } else {
        this.metadataMap.delete(conn.id);
      }
      if (prevCred) {
        this.vaultMap.set(conn.id, prevCred);
      } else {
        this.vaultMap.delete(conn.id);
      }
      this.currentConnectionId = prevCurrentId;
      this.metadataMap.forEach((m, mId) => {
        m.isCurrent = (mId === prevCurrentId);
      });
      if (err instanceof Error) {
        throw err;
      }
      throw new Error(`Persist metadata failed: ${err}`);
    }
  }

  /**
   * 彻底清空所有连接与硬件保管库凭证
   */
  public async clearAll(): Promise<void> {
    await this.adapter.clearAll();
    this.metadataMap.clear();
    this.vaultMap.clear();
    this.currentConnectionId = '';
  }

  /**
   * 移除连接并彻底物理擦除安全保管库中的敏感凭据
   */
  public async removeConnection(id: string): Promise<void> {
    // 1. 物理从安全硬件保管库删除 (若失败会抛出异常)
    await this.adapter.removeCredential(id);

    // 2. 更新内存状态
    this.metadataMap.delete(id);
    this.vaultMap.delete(id);

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
   * 导出敏感凭据库 (仅测试或受控安全迁移用)
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
