import http from '@ohos.net.http';

export interface WorkspaceFileEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  size?: number;
}

export interface WorkspaceListResult {
  entries: WorkspaceFileEntry[];
  currentPath: string;
  error?: string;
}

/**
 * 远程工作区与文件管理客户端
 * 严格对齐 HermesWorkspaceFileClient.swift 与 /api/fs/* 契约
 */
export class HermesWorkspaceClient {
  private static sanitizeUrl(base: string): string {
    let url = base.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /**
   * 安全组合路径：防止跨越根目录跳跃与越界注入
   * 严格对齐 HermesWorkspaceFileClient.swift:117-124 hostPath 安全防线
   */
  public static resolveHostPath(cwd: string, relativePath: string): string {
    const trimmedCwd = cwd.trim();
    const root = (trimmedCwd.length > 1 && trimmedCwd.endsWith('/')) ? trimmedCwd.substring(0, trimmedCwd.length - 1) : trimmedCwd;
    const path = relativePath.trim();

    // 根路径标识
    if (!path || path === '.' || path === '') {
      return root;
    }

    // 拒绝绝对路径
    if (path.startsWith('/')) {
      throw new Error(`Invalid workspace path: absolute path not allowed (${relativePath})`);
    }

    // 拒绝家目录波浪号前缀
    if (path.startsWith('~')) {
      throw new Error(`Invalid workspace path: home directory traversal not allowed (${relativePath})`);
    }

    // 拒绝空字节注入
    if (path.includes('\0')) {
      throw new Error('Invalid workspace path: null bytes forbidden');
    }

    const parts = path.split('/');

    // 拒绝目录向上穿越 (..)
    if (parts.includes('..')) {
      throw new Error(`Invalid workspace path: directory traversal (..) forbidden (${relativePath})`);
    }

    // 必须包含有效路径片段
    let hasValidSegment = false;
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].length > 0 && parts[i] !== '.') {
        hasValidSegment = true;
        break;
      }
    }
    if (!hasValidSegment) {
      return root;
    }

    return (root === '/' ? '' : root) + '/' + path;
  }

  /**
   * 读取目录文件列表：GET /api/fs/list?path=<path>
   */
  public static async listDirectory(
    baseUrl: string,
    cwd: string,
    relativePath: string = '',
    token?: string,
    cookies?: string
  ): Promise<WorkspaceListResult> {
    const cleanUrl = HermesWorkspaceClient.sanitizeUrl(baseUrl);
    const hostPath = HermesWorkspaceClient.resolveHostPath(cwd, relativePath);
    const client = http.createHttp();

    try {
      const headers: Record<string, string> = {
        'Accept': 'application/json'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      if (cookies && cookies.length > 0) {
        headers['Cookie'] = cookies;
      }

      const encodedPath = encodeURIComponent(hostPath).replace(/\+/g, '%2B');
      const res = await client.request(`${cleanUrl}/api/fs/list?path=${encodedPath}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`listDirectory failed with HTTP ${res.responseCode}`);
      }

      const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;

      if (parsed['error']) {
        return {
          entries: [],
          currentPath: relativePath,
          error: String(parsed['error'])
        };
      }

      const rawRows = Array.isArray(parsed['entries']) ? (parsed['entries'] as Array<Record<string, Object>>) : [];
      const list: WorkspaceFileEntry[] = [];

      for (let i = 0; i < rawRows.length; i++) {
        const row = rawRows[i];
        const name = String(row['name'] || '');
        if (!name) continue;
        const isDir = Boolean(row['isDirectory'] || row['is_directory']);
        const entryRelPath = relativePath ? `${relativePath}/${name}` : name;
        list.push({
          name: name,
          path: entryRelPath,
          isDirectory: isDir,
          size: typeof row['size'] === 'number' ? Number(row['size']) : undefined
        });
      }

      return {
        entries: list,
        currentPath: relativePath
      };
    } finally {
      client.destroy();
    }
  }

  /**
   * 读取文本文件内容：GET /api/fs/read-text?path=<path>
   */
  public static async readTextFile(
    baseUrl: string,
    cwd: string,
    relativePath: string,
    token?: string,
    cookies?: string
  ): Promise<string> {
    const cleanUrl = HermesWorkspaceClient.sanitizeUrl(baseUrl);
    const hostPath = HermesWorkspaceClient.resolveHostPath(cwd, relativePath);
    const client = http.createHttp();

    try {
      const headers: Record<string, string> = {
        'Accept': 'text/plain, application/json'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      if (cookies && cookies.length > 0) {
        headers['Cookie'] = cookies;
      }

      const encodedPath = encodeURIComponent(hostPath).replace(/\+/g, '%2B');
      const res = await client.request(`${cleanUrl}/api/fs/read-text?path=${encodedPath}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: headers
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`readTextFile failed with HTTP ${res.responseCode}`);
      }

      return typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
    } finally {
      client.destroy();
    }
  }
}
