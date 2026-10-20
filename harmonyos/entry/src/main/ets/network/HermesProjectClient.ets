import http from '@ohos.net.http';
import { BotConnection } from '../model/Connection';

export interface ProjectItem {
  id: string;
  name: string;
  path: string;
  isDefault?: boolean;
}

export interface GitBranchInfo {
  name: string;
  isCurrent: boolean;
  isRemote?: boolean;
}

export interface GitStatusSummary {
  isGit: boolean;
  branch: string;
  changed: number;
  untracked: number;
  ahead?: number;
  behind?: number;
  repositoryRoot?: string;
}

/**
 * 项目与 Git 仓库管理客户端
 * 严格对齐 upstream HermesProjects.swift 与 HermesGitClient.swift
 */
export class HermesProjectClient {
  /**
   * 获取项目列表：GET /api/projects
   */
  public static async getProjects(
    baseUrl: string,
    token?: string,
    cookies?: string
  ): Promise<ProjectItem[]> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const resp = await req.request(`${cleanUrl}/api/projects`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (resp.responseCode === 200) {
        const raw = JSON.parse(String(resp.result || '[]')) as Record<string, Object>[];
        const list: ProjectItem[] = [];
        if (Array.isArray(raw)) {
          for (let i = 0; i < raw.length; i++) {
            const item = raw[i];
            list.push({
              id: String(item['id'] || item['name'] || ''),
              name: String(item['name'] || item['id'] || ''),
              path: String(item['path'] || ''),
              isDefault: Boolean(item['is_default'] || item['default'])
            });
          }
        }
        return list;
      }
      return [];
    } catch (_e) {
      return [];
    } finally {
      req.destroy();
    }
  }

  /**
   * 探测工作区所在的 Git 仓库根目录：GET /api/fs/git-root?path=<workspacePath>
   */
  public static async resolveGitRoot(
    baseUrl: string,
    workspacePath: string,
    token?: string,
    cookies?: string
  ): Promise<string | null> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const q = encodeURIComponent(workspacePath);
      const resp = await req.request(`${cleanUrl}/api/fs/git-root?path=${q}`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 6000,
        readTimeout: 8000
      });
      if (resp.responseCode === 200) {
        const data = JSON.parse(String(resp.result || '{}')) as Record<string, Object>;
        return data['root'] ? String(data['root']) : null;
      }
      return null;
    } catch (_e) {
      return null;
    } finally {
      req.destroy();
    }
  }

  /**
   * 获取 Git 仓库状态摘要：GET /api/git/status?repository=<root>
   */
  public static async getGitStatus(
    baseUrl: string,
    repositoryRoot: string,
    token?: string,
    cookies?: string
  ): Promise<GitStatusSummary | null> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const q = encodeURIComponent(repositoryRoot);
      const resp = await req.request(`${cleanUrl}/api/git/status?repository=${q}`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (resp.responseCode === 200) {
        const s = JSON.parse(String(resp.result || '{}')) as Record<string, Object>;
        const changed = Number(s['changed'] || 0);
        const untracked = Number(s['untracked'] || 0);
        return {
          isGit: true,
          branch: String(s['branch'] || 'main'),
          changed: changed,
          untracked: untracked,
          ahead: s['ahead'] !== undefined ? Number(s['ahead']) : undefined,
          behind: s['behind'] !== undefined ? Number(s['behind']) : undefined,
          repositoryRoot: repositoryRoot
        };
      }
      return null;
    } catch (_e) {
      return null;
    } finally {
      req.destroy();
    }
  }

  /**
   * 获取分支列表：GET /api/git/branches?repository=<root>
   */
  public static async getGitBranches(
    baseUrl: string,
    repositoryRoot: string,
    token?: string,
    cookies?: string
  ): Promise<GitBranchInfo[]> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const q = encodeURIComponent(repositoryRoot);
      const resp = await req.request(`${cleanUrl}/api/git/branches?repository=${q}`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (resp.responseCode === 200) {
        const raw = JSON.parse(String(resp.result || '[]')) as Record<string, Object>[];
        const branches: GitBranchInfo[] = [];
        if (Array.isArray(raw)) {
          for (let i = 0; i < raw.length; i++) {
            const b = raw[i];
            branches.push({
              name: String(b['name'] || b),
              isCurrent: Boolean(b['current'] || b['is_current']),
              isRemote: Boolean(b['remote'] || b['is_remote'])
            });
          }
        }
        return branches;
      }
      return [];
    } catch (_e) {
      return [];
    } finally {
      req.destroy();
    }
  }

  /**
   * 切换分支：POST /api/git/branch/switch
   */
  public static async switchBranch(
    baseUrl: string,
    repositoryRoot: string,
    branchName: string,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
    const cleanUrl = baseUrl.replace(/\/+$/, '');
    const req = http.createHttp();
    const headers: Record<string, string> = {
      'Content-Type': 'application/json'
    };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const resp = await req.request(`${cleanUrl}/api/git/branch/switch`, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify({
          repository: repositoryRoot,
          branch: branchName
        }),
        connectTimeout: 8000,
        readTimeout: 15000
      });
      if (resp.responseCode === 200) {
        const body = JSON.parse(String(resp.result || '{}')) as Record<string, Object>;
        return Boolean(body['ok'] !== false);
      }
      return false;
    } catch (_e) {
      return false;
    } finally {
      req.destroy();
    }
  }
}
