import { HermesProjectClient, ProjectItem, GitStatusSummary, GitBranchInfo } from '../network/HermesProjectClient';
import { BotConnection } from '../model/Connection';

export class GitWorkspaceViewModel {
  public projects: ProjectItem[] = [];
  public gitStatus: GitStatusSummary | null = null;
  public branches: GitBranchInfo[] = [];
  public activeRepositoryRoot: string = '';
  public isLoading: boolean = false;
  public statusMessage: string = '';

  public async loadProjectsAndGit(conn: BotConnection, workspacePath: string): Promise<void> {
    this.isLoading = true;
    this.statusMessage = '正在读取项目与 Git 仓库状态...';

    try {
      this.projects = await HermesProjectClient.getProjects(conn.url, conn.token, conn.cookies);
      const root = await HermesProjectClient.resolveGitRoot(conn.url, workspacePath, conn.token, conn.cookies);
      this.activeRepositoryRoot = root || '';

      if (root) {
        this.gitStatus = await HermesProjectClient.getGitStatus(conn.url, root, conn.token, conn.cookies);
        this.branches = await HermesProjectClient.getGitBranches(conn.url, root, conn.token, conn.cookies);
        this.statusMessage = `Git 状态: 分支 ${this.gitStatus?.branch || '未知'}, 改动 ${this.gitStatus?.changed || 0} 个`;
      } else {
        this.gitStatus = null;
        this.branches = [];
        this.statusMessage = '当前工作区未处于 Git 仓库中';
      }
    } catch (e) {
      this.statusMessage = `Git 读取失败: ${e}`;
    } finally {
      this.isLoading = false;
    }
  }

  public async switchBranch(conn: BotConnection, targetBranch: string): Promise<boolean> {
    if (!this.activeRepositoryRoot) {
      return false;
    }
    this.isLoading = true;
    try {
      const ok = await HermesProjectClient.switchBranch(conn.url, this.activeRepositoryRoot, targetBranch, conn.token, conn.cookies);
      if (ok) {
        this.statusMessage = `已切换至分支: ${targetBranch}`;
        await this.loadProjectsAndGit(conn, '');
      }
      return ok;
    } catch (e) {
      this.statusMessage = `分支切换失败: ${e}`;
      return false;
    } finally {
      this.isLoading = false;
    }
  }
}
