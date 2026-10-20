import { HermesSkillsClient, SkillSummary } from '../network/HermesSkillsClient';
import { HermesMemoryClient } from '../network/HermesMemoryClient';
import { BotConnection } from '../model/Connection';

export class SkillsViewModel {
  public skills: SkillSummary[] = [];
  public soulText: string = '';
  public memoryText: string = '';
  public isLoading: boolean = false;
  public statusMessage: string = '';

  public async loadSkillsAndMemory(conn: BotConnection): Promise<void> {
    this.isLoading = true;
    this.statusMessage = '正在读取技能与记忆...';
    const profile = conn.activeProfile || 'default';

    try {
      this.skills = await HermesSkillsClient.getSkills(conn.url, profile, conn.token, conn.cookies);
      this.soulText = await HermesMemoryClient.getSoul(conn.url, profile, conn.token, conn.cookies);
      this.memoryText = await HermesMemoryClient.getMemory(conn.url, profile, conn.token, conn.cookies);
      this.statusMessage = `技能已就绪 (${this.skills.length} 项)`;
    } catch (e) {
      this.statusMessage = `读取失败: ${e}`;
    } finally {
      this.isLoading = false;
    }
  }

  public async toggleSkill(conn: BotConnection, skill: SkillSummary): Promise<boolean> {
    const profile = conn.activeProfile || 'default';
    const targetState = !skill.enabled;
    try {
      const ok = await HermesSkillsClient.toggleSkill(conn.url, profile, skill.name, targetState, conn.token, conn.cookies);
      if (ok) {
        skill.enabled = targetState;
      }
      return ok;
    } catch (e) {
      this.statusMessage = `切换技能状态失败: ${e}`;
      return false;
    }
  }

  public async saveSoul(conn: BotConnection, newSoul: string): Promise<boolean> {
    const profile = conn.activeProfile || 'default';
    try {
      const ok = await HermesMemoryClient.saveSoul(conn.url, profile, newSoul, conn.token, conn.cookies);
      if (ok) {
        this.soulText = newSoul;
      }
      return ok;
    } catch (e) {
      this.statusMessage = `保存设定失败: ${e}`;
      return false;
    }
  }
}
