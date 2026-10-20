export type DeepLinkRouteType = 'session' | 'new_chat' | 'new_chat_profile' | 'bot';

export interface DeepLinkSessionRoute {
  type: 'session';
  sessionId: string;
  server?: string;
  profile?: string;
}

export interface DeepLinkNewChatRoute {
  type: 'new_chat';
  autoStartsVoice: boolean;
}

export interface DeepLinkNewChatProfileRoute {
  type: 'new_chat_profile';
  profile: string;
  server?: string;
}

export interface DeepLinkBotRoute {
  type: 'bot';
  server: string;
  connection: string;
  profile: string;
}

export type DeepLinkRoute =
  | DeepLinkSessionRoute
  | DeepLinkNewChatRoute
  | DeepLinkNewChatProfileRoute
  | DeepLinkBotRoute;

export interface InboundShareData {
  text?: string;
  uri?: string;
  type?: string;
}

/**
 * 鸿蒙深层链接 (Deep Link) 与跨应用交互路由
 * 严格对齐 upstream HermesDeepLink.swift 规范 (hermex:// 与 hermes-agent://)
 */
export class DeepLinkUtils {
  public static readonly SCHEME_HERMEX = 'hermex';
  public static readonly SCHEME_HERMES_AGENT = 'hermes-agent';

  /**
   * 解析外部拉起 URL
   * 格式覆盖：
   * - hermex://session?id=<id>&server=<srv>&profile=<prof>
   * - hermex://new-chat
   * - hermex://new-chat-voice
   * - hermex://new-chat-profile?profile=<prof>&server=<srv>
   * - hermex://bot?server=<srv>&connection=<conn>&profile=<prof>
   */
  public static parseDeepLink(rawUrl: string): DeepLinkRoute | null {
    if (!rawUrl || typeof rawUrl !== 'string') {
      return null;
    }
    const trimmed = rawUrl.trim();
    const colonSlashIdx = trimmed.indexOf('://');
    if (colonSlashIdx === -1) {
      return null;
    }

    const scheme = trimmed.substring(0, colonSlashIdx).toLowerCase();
    if (scheme !== DeepLinkUtils.SCHEME_HERMEX && scheme !== DeepLinkUtils.SCHEME_HERMES_AGENT) {
      return null;
    }

    const rest = trimmed.substring(colonSlashIdx + 3);
    let host = rest;
    let queryPart = '';
    const qIndex = rest.indexOf('?');
    if (qIndex !== -1) {
      host = rest.substring(0, qIndex);
      queryPart = rest.substring(qIndex + 1);
    }
    host = host.toLowerCase().replace(/\/+$/, '');

    const params: Record<string, string> = {};
    if (queryPart) {
      const pairs = queryPart.split('&');
      for (let i = 0; i < pairs.length; i++) {
        const p = pairs[i];
        const eqIdx = p.indexOf('=');
        if (eqIdx !== -1) {
          const key = decodeURIComponent(p.substring(0, eqIdx));
          const val = decodeURIComponent(p.substring(eqIdx + 1));
          params[key] = val;
        } else if (p.length > 0) {
          params[decodeURIComponent(p)] = '';
        }
      }
    }

    if (host === 'session') {
      const sessionId = params['id'] || params['session_id'];
      if (!sessionId || sessionId.trim().length === 0) {
        return null;
      }
      return {
        type: 'session',
        sessionId: sessionId.trim(),
        server: params['server'] || undefined,
        profile: params['profile'] || undefined
      };
    }

    if (host === 'new-chat') {
      return {
        type: 'new_chat',
        autoStartsVoice: false
      };
    }

    if (host === 'new-chat-voice') {
      return {
        type: 'new_chat',
        autoStartsVoice: true
      };
    }

    if (host === 'new-chat-profile') {
      const profile = params['profile'];
      if (!profile || profile.trim().length === 0) {
        return {
          type: 'new_chat',
          autoStartsVoice: false
        };
      }
      return {
        type: 'new_chat_profile',
        profile: profile.trim(),
        server: params['server'] || undefined
      };
    }

    if (host === 'bot') {
      const server = params['server'] || '';
      const connection = params['connection'] || '';
      const profile = params['profile'] || '';
      return {
        type: 'bot',
        server: server,
        connection: connection,
        profile: profile
      };
    }

    return null;
  }

  public static buildSessionUrl(sessionId: string, server?: string, profile?: string): string {
    let url = `${DeepLinkUtils.SCHEME_HERMEX}://session?id=${encodeURIComponent(sessionId)}`;
    if (server) {
      url += `&server=${encodeURIComponent(server)}`;
    }
    if (profile) {
      url += `&profile=${encodeURIComponent(profile)}`;
    }
    return url;
  }

  public static buildNewChatUrl(): string {
    return `${DeepLinkUtils.SCHEME_HERMEX}://new-chat`;
  }

  public static buildNewChatVoiceUrl(): string {
    return `${DeepLinkUtils.SCHEME_HERMEX}://new-chat-voice`;
  }
}

/**
 * 跨组件与 Ability 深层路由共享单例
 */
export class AppDeepLinkRouter {
  private static instance: AppDeepLinkRouter | null = null;
  private pendingRoute: DeepLinkRoute | null = null;
  private pendingShare: InboundShareData | null = null;
  private listeners: Array<(route: DeepLinkRoute) => void> = [];
  private shareListeners: Array<(share: InboundShareData) => void> = [];

  public static getInstance(): AppDeepLinkRouter {
    if (!AppDeepLinkRouter.instance) {
      AppDeepLinkRouter.instance = new AppDeepLinkRouter();
    }
    return AppDeepLinkRouter.instance;
  }

  public setPendingRoute(route: DeepLinkRoute): void {
    if (this.listeners.length > 0) {
      for (let i = 0; i < this.listeners.length; i++) {
        try {
          this.listeners[i](route);
        } catch (_e) {
          // ignore listener error
        }
      }
      this.pendingRoute = null; // 已向活跃页面派发，清空 pending 避免二次消费
    } else {
      this.pendingRoute = route;
    }
  }

  public consumePendingRoute(): DeepLinkRoute | null {
    const r = this.pendingRoute;
    this.pendingRoute = null;
    return r;
  }

  public setPendingShare(share: InboundShareData): void {
    if (this.shareListeners.length > 0) {
      for (let i = 0; i < this.shareListeners.length; i++) {
        try {
          this.shareListeners[i](share);
        } catch (_e) {
          // ignore listener error
        }
      }
      this.pendingShare = null; // 已向活跃页面派发，清空 pending 避免二次消费
    } else {
      this.pendingShare = share;
    }
  }

  public consumePendingShare(): InboundShareData | null {
    const s = this.pendingShare;
    this.pendingShare = null;
    return s;
  }

  public addRouteListener(listener: (route: DeepLinkRoute) => void): void {
    if (this.listeners.indexOf(listener) === -1) {
      this.listeners.push(listener);
    }
  }

  public removeRouteListener(listener: (route: DeepLinkRoute) => void): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  public addShareListener(listener: (share: InboundShareData) => void): void {
    if (this.shareListeners.indexOf(listener) === -1) {
      this.shareListeners.push(listener);
    }
  }

  public removeShareListener(listener: (share: InboundShareData) => void): void {
    const idx = this.shareListeners.indexOf(listener);
    if (idx >= 0) {
      this.shareListeners.splice(idx, 1);
    }
  }
}
