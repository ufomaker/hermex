import { BotConnection, HermesStatus } from '../model/Connection';
import { HermesRESTClient } from '../network/HermesRESTClient';
import { AuthStore } from '../storage/AuthStore';

export class ConnectionViewModel {
  private authStore = AuthStore.getInstance();

  public async probeStatus(url: string): Promise<HermesStatus> {
    return await HermesRESTClient.getStatus(url);
  }

  public async loginAndSave(
    name: string,
    url: string,
    username?: string,
    password?: string
  ): Promise<BotConnection> {
    const status = await this.probeStatus(url);
    let token = '';

    if (status.auth_required && username && password) {
      token = await HermesRESTClient.login(url, username, password);
    }

    const conn: BotConnection = {
      id: `conn_${Date.now()}`,
      name: name.trim() || '我的 Hermes',
      url: url.trim(),
      username: username,
      password: password,
      token: token,
      activeProfile: status.profiles.length > 0 ? status.profiles[0] : 'default',
      serverVersion: status.version,
      isCurrent: true
    };

    this.authStore.saveConnection(conn);
    return conn;
  }

  public getSavedConnections(): BotConnection[] {
    return this.authStore.getConnections();
  }

  public getCurrentConnection(): BotConnection | null {
    return this.authStore.getCurrentConnection();
  }

  public selectConnection(id: string): void {
    this.authStore.setCurrentConnection(id);
  }
}
