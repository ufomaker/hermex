import { BotConnection, HermesStatus } from '../model/Connection';
import { HermesRESTClient } from '../network/HermesRESTClient';
import { LegacySSEClient } from '../network/legacy/LegacySSEClient';
import { AuthStore } from '../storage/AuthStore';

export class ConnectionViewModel {
  private authStore = AuthStore.getInstance();

  public async probeStatus(url: string): Promise<HermesStatus> {
    try {
      return await HermesRESTClient.getStatus(url);
    } catch (e) {
      // 容错降级探测 legacy webui /health
      const isLegacy = await LegacySSEClient.probeHealth(url);
      if (isLegacy) {
        return {
          version: 'legacy-webui',
          auth_required: true,
          gateway_running: false,
          profiles: ['default']
        };
      }
      throw new Error(String(e));
    }
  }

  public async loginAndSave(
    name: string,
    url: string,
    username?: string,
    password?: string
  ): Promise<BotConnection> {
    const status = await this.probeStatus(url);
    let token = '';
    let cookies = '';

    if (status.auth_required && username && password) {
      const loginRes = await HermesRESTClient.login(url, username, password);
      token = loginRes.token || '';
      cookies = loginRes.cookies || '';
    }

    const conn: BotConnection = {
      id: `conn_${Date.now()}`,
      name: name.trim() || '我的 Hermes',
      url: url.trim(),
      username: username,
      password: password,
      token: token,
      cookies: cookies,
      activeProfile: status.profiles.length > 0 ? status.profiles[0] : 'default',
      serverVersion: status.version,
      isCurrent: true
    };

    await this.authStore.saveConnection(conn);
    return conn;
  }

  public getSavedConnections(): BotConnection[] {
    return this.authStore.getConnections();
  }

  public getCurrentConnection(): BotConnection | null {
    return this.authStore.getCurrentConnection();
  }

  public async selectConnection(id: string): Promise<void> {
    await this.authStore.setCurrentConnection(id);
  }
}
