import { HermesCronClient, CronJobItem, CronRunItem, CreateCronJobPayload, UpdateCronJobPayload } from '../network/HermesCronClient';
import { BotConnection } from '../model/Connection';

export interface CronViewModelListener {
  onStateChanged: () => void;
}

export class CronViewModel {
  public jobs: CronJobItem[] = [];
  public runs: CronRunItem[] = [];
  public selectedJobId: string = '';
  public isLoading: boolean = false;
  public isOperating: boolean = false;
  public isLoadingRuns: boolean = false;
  public statusMessage: string = '';
  public actionError: string | null = null;
  public actionWarning: string | null = null;

  private listener?: CronViewModelListener;
  private currentServerUrl: string = '';
  private currentProfile: string = '';
  private requestSerial: number = 0;
  private runsRequestSerial: number = 0;

  public setListener(listener: CronViewModelListener) {
    this.listener = listener;
  }

  private notify() {
    if (this.listener) {
      this.listener.onStateChanged();
    }
  }

  public isMatchingOwner(conn?: BotConnection | null): boolean {
    if (!conn) return false;
    const p = conn.activeProfile || 'default';
    return this.currentServerUrl === conn.url && this.currentProfile === p;
  }

  public async loadJobs(conn: BotConnection): Promise<void> {
    const p = conn.activeProfile || 'default';
    const serverChanged = (this.currentServerUrl !== conn.url || this.currentProfile !== p);

    if (serverChanged) {
      this.currentServerUrl = conn.url;
      this.currentProfile = p;
      this.jobs = [];
      this.runs = [];
      this.selectedJobId = '';
      this.notify();
    }

    this.requestSerial++;
    const thisSerial = this.requestSerial;
    this.isLoading = true;
    this.statusMessage = '正在拉取定时任务...';
    this.actionError = null;
    this.notify();

    try {
      if (conn.serverVersion === 'legacy-webui') {
        this.actionError = '旧版 WebUI 不支持定时任务调度';
        this.statusMessage = '旧版 WebUI 不支持定时任务';
        this.jobs = [];
        this.notify();
        return;
      }

      const list = await HermesCronClient.listCronJobs(conn.url, p, conn.token, conn.cookies);

      if (thisSerial !== this.requestSerial || !this.isMatchingOwner(conn)) {
        return;
      }

      // 按创建时间倒序排列，确保最新创建或编辑的任务置顶呈现
      const sorted = list.slice().sort((a: CronJobItem, b: CronJobItem) => {
        const timeA = a.createdAt ? new Date(a.createdAt).getTime() : 0;
        const timeB = b.createdAt ? new Date(b.createdAt).getTime() : 0;
        const validA = !isNaN(timeA) ? timeA : 0;
        const validB = !isNaN(timeB) ? timeB : 0;
        if (validA && validB && validA !== validB) {
          return validB - validA;
        }
        return 0;
      });

      this.jobs = sorted;
      this.statusMessage = `成功加载 ${this.jobs.length} 个任务`;
      this.notify();
    } catch (e) {
      if (thisSerial === this.requestSerial && this.isMatchingOwner(conn)) {
        this.actionError = `拉取任务失败: ${(e as Error).message || String(e)}`;
        this.statusMessage = this.actionError;
        this.notify();
      }
    } finally {
      if (thisSerial === this.requestSerial) {
        this.isLoading = false;
        this.notify();
      }
    }
  }

  public async createJob(conn: BotConnection, name: string, schedule: string, prompt: string): Promise<CronJobItem | null> {
    if (conn.serverVersion === 'legacy-webui') {
      this.actionError = '旧版 WebUI 不支持创建定时任务';
      this.notify();
      return null;
    }
    if (!this.isMatchingOwner(conn)) {
      this.actionError = '连接状态已变更';
      this.notify();
      return null;
    }

    const trimmedName = name.trim();
    const trimmedSchedule = schedule.trim();
    const trimmedPrompt = prompt.trim();
    if (!trimmedName || !trimmedSchedule || !trimmedPrompt) {
      this.actionError = '任务名称、Cron表达式与提示词均为必填项';
      this.statusMessage = this.actionError;
      this.notify();
      return null;
    }

    this.isOperating = true;
    const thisSerial = this.requestSerial;
    this.actionError = null;
    this.notify();

    try {
      const payload: CreateCronJobPayload = {
        name: trimmedName,
        schedule: trimmedSchedule,
        prompt: trimmedPrompt,
        deliver: 'local',
        skills: [],
        model: 'hermex-stub'
      };

      const p = conn.activeProfile || 'default';
      const created = await HermesCronClient.createCronJob(conn.url, payload, p, conn.token, conn.cookies);

      if (thisSerial !== this.requestSerial || !this.isMatchingOwner(conn)) {
        return null;
      }

      this.actionWarning = created.warning || null;
      await this.loadJobs(conn);
      if (created.warning) {
        this.statusMessage = `已保存(警告: ${created.warning})`;
      } else {
        this.statusMessage = `已成功创建任务: ${created.name}`;
      }
      this.notify();
      return created;
    } catch (e) {
      if (thisSerial === this.requestSerial && this.isMatchingOwner(conn)) {
        this.actionError = `创建任务失败: ${(e as Error).message || String(e)}`;
        this.statusMessage = this.actionError;
        this.notify();
      }
      return null;
    } finally {
      if (thisSerial === this.requestSerial) {
        this.isOperating = false;
        this.notify();
      }
    }
  }

  public async updateJob(conn: BotConnection, jobId: string, updates: UpdateCronJobPayload): Promise<CronJobItem | null> {
    if (conn.serverVersion === 'legacy-webui') {
      this.actionError = '旧版 WebUI 不支持编辑定时任务';
      this.notify();
      return null;
    }
    if (!this.isMatchingOwner(conn)) {
      this.actionError = '连接状态已变更';
      this.notify();
      return null;
    }

    this.isOperating = true;
    const thisSerial = this.requestSerial;
    this.actionError = null;
    this.notify();

    try {
      const p = conn.activeProfile || 'default';
      const updated = await HermesCronClient.updateCronJob(conn.url, jobId, updates, p, conn.token, conn.cookies);

      if (thisSerial !== this.requestSerial || !this.isMatchingOwner(conn)) {
        return null;
      }

      this.statusMessage = `已成功更新任务: ${updated.name}`;
      await this.loadJobs(conn);
      this.notify();
      return updated;
    } catch (e) {
      if (thisSerial === this.requestSerial && this.isMatchingOwner(conn)) {
        this.actionError = `更新任务失败: ${(e as Error).message || String(e)}`;
        this.statusMessage = this.actionError;
        this.notify();
      }
      return null;
    } finally {
      if (thisSerial === this.requestSerial) {
        this.isOperating = false;
        this.notify();
      }
    }
  }

  public async triggerJob(conn: BotConnection, jobId: string): Promise<boolean> {
    if (conn.serverVersion === 'legacy-webui') {
      this.actionError = '旧版 WebUI 不支持触发定时任务';
      this.notify();
      return false;
    }
    if (!this.isMatchingOwner(conn)) {
      this.actionError = '连接状态已变更';
      this.notify();
      return false;
    }

    this.isOperating = true;
    const thisSerial = this.requestSerial;
    this.actionError = null;
    this.notify();

    try {
      const p = conn.activeProfile || 'default';
      const ok = await HermesCronClient.triggerCronJob(conn.url, jobId, p, conn.token, conn.cookies);

      if (thisSerial !== this.requestSerial || !this.isMatchingOwner(conn)) {
        return false;
      }

      if (ok) {
        this.statusMessage = `任务已成功触发执行`;
        await this.loadJobs(conn);
      }
      this.notify();
      return ok;
    } catch (e) {
      if (thisSerial === this.requestSerial && this.isMatchingOwner(conn)) {
        this.actionError = `触发任务失败: ${(e as Error).message || String(e)}`;
        this.statusMessage = this.actionError;
        this.notify();
      }
      return false;
    } finally {
      if (thisSerial === this.requestSerial) {
        this.isOperating = false;
        this.notify();
      }
    }
  }

  // 兼容别名
  public async runJob(conn: BotConnection, jobId: string): Promise<boolean> {
    return this.triggerJob(conn, jobId);
  }

  public async toggleJob(conn: BotConnection, job: CronJobItem): Promise<boolean> {
    if (conn.serverVersion === 'legacy-webui') {
      this.actionError = '旧版 WebUI 不支持暂停/恢复定时任务';
      this.notify();
      return false;
    }
    if (!this.isMatchingOwner(conn)) {
      this.actionError = '连接状态已变更';
      this.notify();
      return false;
    }

    this.isOperating = true;
    const thisSerial = this.requestSerial;
    this.actionError = null;
    this.notify();

    try {
      const p = conn.activeProfile || 'default';
      let ok = false;
      if (job.enabled) {
        ok = await HermesCronClient.pauseCronJob(conn.url, job.id, p, conn.token, conn.cookies);
      } else {
        ok = await HermesCronClient.resumeCronJob(conn.url, job.id, p, conn.token, conn.cookies);
      }

      if (thisSerial !== this.requestSerial || !this.isMatchingOwner(conn)) {
        return false;
      }

      if (ok) {
        this.statusMessage = job.enabled ? '任务已暂停' : '任务已恢复调度';
        await this.loadJobs(conn);
      }
      this.notify();
      return ok;
    } catch (e) {
      if (thisSerial === this.requestSerial && this.isMatchingOwner(conn)) {
        this.actionError = `操作失败: ${(e as Error).message || String(e)}`;
        this.statusMessage = this.actionError;
        this.notify();
      }
      return false;
    } finally {
      if (thisSerial === this.requestSerial) {
        this.isOperating = false;
        this.notify();
      }
    }
  }

  public async loadRuns(conn: BotConnection, jobId: string): Promise<CronRunItem[]> {
    if (conn.serverVersion === 'legacy-webui') {
      this.actionError = '旧版 WebUI 不支持任务历史';
      this.notify();
      return [];
    }
    if (!this.isMatchingOwner(conn)) {
      this.actionError = '连接状态已变更';
      this.notify();
      return [];
    }

    this.isLoadingRuns = true;
    this.selectedJobId = jobId;
    this.runsRequestSerial++;
    const thisRunsSerial = this.runsRequestSerial;
    this.actionError = null;
    this.notify();

    try {
      const p = conn.activeProfile || 'default';
      const runs = await HermesCronClient.listCronRuns(conn.url, jobId, p, 100, conn.token, conn.cookies);

      if (thisRunsSerial !== this.runsRequestSerial || !this.isMatchingOwner(conn) || this.selectedJobId !== jobId) {
        return [];
      }

      this.runs = runs;
      this.notify();
      return runs;
    } catch (e) {
      if (thisRunsSerial === this.runsRequestSerial && this.isMatchingOwner(conn) && this.selectedJobId === jobId) {
        this.actionError = `拉取历史失败: ${(e as Error).message || String(e)}`;
        this.notify();
      }
      return [];
    } finally {
      if (thisRunsSerial === this.runsRequestSerial) {
        this.isLoadingRuns = false;
        this.notify();
      }
    }
  }
}
