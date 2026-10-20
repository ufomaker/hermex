import { BotConnection } from '../model/Connection';
import { HermesWorkspaceClient, WorkspaceFileEntry, WorkspaceListResult } from '../network/HermesWorkspaceClient';
import { HermesFileClient } from '../network/HermesFileClient';

export interface WorkspaceListener {
  onStateChanged?: () => void;
  onError?: (msg: string) => void;
}

/**
 * 工作区文件管理 ViewModel
 * 严格衔接 HermesWorkspaceClient 与 HermesFileClient
 */
export class WorkspaceViewModel {
  public cwd: string = '/workspace';
  public currentRelativePath: string = '';
  public entries: WorkspaceFileEntry[] = [];
  public isLoading: boolean = false;
  public errorMessage: string = '';
  public selectedFileName: string = '';
  public selectedFileText: string = '';
  public isViewingFile: boolean = false;
  public isDownloading: boolean = false;
  public pathHistory: string[] = [];

  private listener: WorkspaceListener | null = null;

  public setListener(listener: WorkspaceListener): void {
    this.listener = listener;
  }

  private notify(): void {
    if (this.listener && this.listener.onStateChanged) {
      this.listener.onStateChanged();
    }
  }

  public setCwd(cwd: string): void {
    this.cwd = cwd;
    this.currentRelativePath = '';
    this.pathHistory = [];
    this.notify();
  }

  public async loadDirectory(conn: BotConnection, relativePath: string = ''): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    this.notify();

    try {
      const res: WorkspaceListResult = await HermesWorkspaceClient.listDirectory(
        conn.url,
        this.cwd,
        relativePath,
        conn.token,
        conn.cookies
      );

      if (res.error) {
        this.errorMessage = res.error;
        this.entries = [];
      } else {
        this.currentRelativePath = res.currentPath;
        const dirs: WorkspaceFileEntry[] = [];
        const files: WorkspaceFileEntry[] = [];
        for (let i = 0; i < res.entries.length; i++) {
          const item = res.entries[i];
          if (item.isDirectory) {
            dirs.push(item);
          } else {
            files.push(item);
          }
        }
        dirs.sort((a: WorkspaceFileEntry, b: WorkspaceFileEntry) => a.name.localeCompare(b.name));
        files.sort((a: WorkspaceFileEntry, b: WorkspaceFileEntry) => a.name.localeCompare(b.name));
        this.entries = dirs.concat(files);
      }
    } catch (e) {
      this.errorMessage = `加载目录失败: ${e}`;
      this.entries = [];
    } finally {
      this.isLoading = false;
      this.notify();
    }
  }

  public async enterDirectory(conn: BotConnection, dirEntry: WorkspaceFileEntry): Promise<void> {
    if (!dirEntry.isDirectory) return;
    this.pathHistory.push(this.currentRelativePath);
    await this.loadDirectory(conn, dirEntry.path);
  }

  public async navigateUp(conn: BotConnection): Promise<void> {
    if (this.pathHistory.length === 0 && (!this.currentRelativePath || this.currentRelativePath === '')) {
      return;
    }
    const previous = this.pathHistory.pop() || '';
    await this.loadDirectory(conn, previous);
  }

  public async viewFile(conn: BotConnection, fileEntry: WorkspaceFileEntry): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    this.selectedFileName = fileEntry.name;
    this.isViewingFile = true;
    this.notify();

    try {
      const text = await HermesWorkspaceClient.readTextFile(
        conn.url,
        this.cwd,
        fileEntry.path,
        conn.token,
        conn.cookies
      );
      this.selectedFileText = text;
    } catch (e) {
      this.errorMessage = `读取文件失败: ${e}`;
      this.selectedFileText = `无法预览文本内容: ${e}`;
    } finally {
      this.isLoading = false;
      this.notify();
    }
  }

  public closeFileView(): void {
    this.isViewingFile = false;
    this.selectedFileName = '';
    this.selectedFileText = '';
    this.notify();
  }

  public async downloadFile(conn: BotConnection, fileEntry: WorkspaceFileEntry, sessionId?: string): Promise<ArrayBuffer> {
    this.isDownloading = true;
    this.notify();

    try {
      const hostPath = HermesWorkspaceClient.resolveHostPath(this.cwd, fileEntry.path);
      const profile = conn.activeProfile ? conn.activeProfile : 'default';
      const buffer = await HermesFileClient.downloadArtifact(
        conn.url,
        hostPath,
        profile,
        sessionId,
        conn.token,
        conn.cookies
      );
      return buffer;
    } finally {
      this.isDownloading = false;
      this.notify();
    }
  }
}
