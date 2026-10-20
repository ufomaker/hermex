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
   * 安全组合路径：防止跨越根目录跳跃
   */
  public static resolveHostPath(cwd: string, relativePath: string): string {
    let base = cwd.trim();
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    let rel = relativePath.trim();
    if (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    if (!rel) {
      return base;
    }
    return `${base}/${rel}`;
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
