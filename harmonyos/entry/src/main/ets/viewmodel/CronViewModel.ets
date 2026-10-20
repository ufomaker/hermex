import { HermesCronClient, CronJobItem } from '../network/HermesCronClient';
import { BotConnection } from '../model/Connection';

export class CronViewModel {
  public jobs: CronJobItem[] = [];
  public isLoading: boolean = false;
  public statusMessage: string = '';

  public async loadJobs(conn: BotConnection): Promise<void> {
    this.isLoading = true;
    this.statusMessage = '正在拉取定时任务...';
    try {
      this.jobs = await HermesCronClient.listCronJobs(conn.url, conn.token, conn.cookies);
      this.statusMessage = `成功加载 ${this.jobs.length} 个任务`;
    } catch (e) {
      this.statusMessage = `拉取任务失败: ${e}`;
    } finally {
      this.isLoading = false;
    }
  }

  public async runJob(conn: BotConnection, jobId: string): Promise<boolean> {
    try {
      const ok = await HermesCronClient.runCronJob(conn.url, jobId, conn.activeProfile, conn.token, conn.cookies);
      if (ok) {
        this.statusMessage = `任务 ${jobId} 已触发执行`;
        await this.loadJobs(conn);
      }
      return ok;
    } catch (e) {
      this.statusMessage = `触发任务失败: ${e}`;
      return false;
    }
  }

  public async toggleJob(conn: BotConnection, job: CronJobItem): Promise<boolean> {
    try {
      let ok = false;
      if (job.enabled) {
        ok = await HermesCronClient.pauseCronJob(conn.url, job.id, conn.activeProfile, conn.token, conn.cookies);
      } else {
        ok = await HermesCronClient.resumeCronJob(conn.url, job.id, conn.activeProfile, conn.token, conn.cookies);
      }
      if (ok) {
        await this.loadJobs(conn);
      }
      return ok;
    } catch (e) {
      this.statusMessage = `操作失败: ${e}`;
      return false;
    }
  }
}
