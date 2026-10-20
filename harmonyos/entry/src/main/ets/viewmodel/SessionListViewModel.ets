import { HermesSession } from '../model/Session';
import { HermesRESTClient } from '../network/HermesRESTClient';
import { HermesGatewayClient } from '../network/HermesGatewayClient';
import { BotConnection } from '../model/Connection';

export class SessionListViewModel {
  public async loadSessions(conn: BotConnection): Promise<HermesSession[]> {
    const profile = conn.activeProfile || 'default';
    return await HermesRESTClient.listSessions(conn.url, profile, conn.token, conn.cookies);
  }

  /**
   * 真实在服务端创建会话并拿回真实会话身份
   */
  public async createSession(gateway: HermesGatewayClient, profile: string): Promise<HermesSession> {
    const res = await gateway.createSession(profile);
    const sid = String(res['session_id'] || res['id'] || '');
    if (!sid) {
      throw new Error('服务端未返回有效 session_id');
    }
    const session: HermesSession = {
      id: sid,
      runtime_id: sid,
      title: '新对话',
      profile: profile,
      created_at: Date.now(),
      updated_at: Date.now(),
      running: false
    };
    return session;
  }
}
