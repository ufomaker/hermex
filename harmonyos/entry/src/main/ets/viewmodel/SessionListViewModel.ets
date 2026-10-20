import { HermesSession } from '../model/Session';
import { HermesRESTClient } from '../network/HermesRESTClient';
import { HermesGatewayClient } from '../network/HermesGatewayClient';
import { BotConnection } from '../model/Connection';

export class SessionListViewModel {
  public async loadSessions(conn: BotConnection): Promise<HermesSession[]> {
    const profile = conn.activeProfile || 'default';
    return await HermesRESTClient.listSessions(conn.url, profile, conn.token);
  }

  public async createSession(gateway: HermesGatewayClient, profile: string): Promise<string> {
    const res = await gateway.createSession(profile);
    return String(res['session_id'] || res['id'] || '');
  }
}
