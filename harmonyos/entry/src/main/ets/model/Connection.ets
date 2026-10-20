/**
 * Hermes 服务器连接配置数据模型
 */
export interface BotConnection {
  id: string;
  name: string;
  url: string;
  username?: string;
  password?: string;
  token?: string;
  cookies?: string; // 保存由 Set-Cookie 解析的 Cookie 串
  activeProfile?: string;
  serverVersion?: string;
  isCurrent?: boolean;
}

export function cloneConnection(c: BotConnection): BotConnection {
  const result: BotConnection = {
    id: c.id,
    name: c.name,
    url: c.url,
    username: c.username,
    password: c.password,
    token: c.token,
    cookies: c.cookies,
    activeProfile: c.activeProfile,
    serverVersion: c.serverVersion,
    isCurrent: c.isCurrent
  };
  return result;
}

export interface HermesStatus {
  version: string;
  release_date?: string;
  auth_required: boolean;
  profiles: string[];
  gateway_running: boolean;
  gateway_mode?: string;
  overall?: string;
}
