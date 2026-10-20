import http from '@ohos.net.http';
import util from '@ohos.util';

export interface LegacySSEEvent {
  event?: string;
  data: string;
  id?: string;
}

export interface LegacySessionItem {
  id: string;
  title: string;
  updatedAt?: number;
  createdAt?: number;
  preview?: string;
}

export interface LegacyChatMessageItem {
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp?: number;
}

export interface LegacySessionDetail {
  id: string;
  title: string;
  messages: LegacyChatMessageItem[];
}

export interface LegacyStartTurnResult {
  streamId: string;
}

export interface LegacySSECallbacks {
  onEvent: (event: LegacySSEEvent) => void;
  onError: (error: string) => void;
  onClose: () => void;
}

export interface SSEStreamHandle {
  cancel: () => void;
}

/**
 * 跨网络数据块边界的增量 SSE 帧解析器
 * 确保单个事件跨 TCP/网络数据块到达时，正确累加并等待帧定界符 \n\n，绝不丢弃或截断数据
 */
export class LegacySSEParser {
  private buffer: string = '';

  public feed(chunk: string): LegacySSEEvent[] {
    this.buffer += chunk;
    // 统一换行符
    this.buffer = this.buffer.replace(/\r\n/g, '\n');

    const events: LegacySSEEvent[] = [];
    let boundaryIndex: number;

    while ((boundaryIndex = this.buffer.indexOf('\n\n')) !== -1) {
      const frameStr = this.buffer.substring(0, boundaryIndex);
      this.buffer = this.buffer.substring(boundaryIndex + 2);

      const parsed = this.parseFrame(frameStr);
      if (parsed) {
        events.push(parsed);
      }
    }
    return events;
  }

  public finish(): LegacySSEEvent[] {
    const events: LegacySSEEvent[] = [];
    if (this.buffer.trim().length > 0) {
      const parsed = this.parseFrame(this.buffer);
      if (parsed) {
        events.push(parsed);
      }
      this.buffer = '';
    }
    return events;
  }

  private parseFrame(frameStr: string): LegacySSEEvent | null {
    const lines = frameStr.split('\n');
    let eventName: string | undefined = undefined;
    let eventId: string | undefined = undefined;
    const dataLines: string[] = [];

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        let val = line.substring(5);
        if (val.startsWith(' ')) {
          val = val.substring(1);
        }
        dataLines.push(val);
      } else if (line.startsWith('id:')) {
        eventId = line.substring(3).trim();
      }
    }

    if (dataLines.length > 0 || eventName || eventId) {
      return {
        event: eventName,
        data: dataLines.join('\n'),
        id: eventId
      };
    }
    return null;
  }
}

/**
 * 针对上游 legacy hermes-webui (UPSTREAM_TESTED_SHA: c67fd2dd) 的向后兼容 SSE 客户端
 * 严格支持 /health 探针、/api/chat/start、/api/chat/cancel、/api/chat/stream 持续流式消息与会话列表
 */
export class LegacySSEClient {
  public static sanitizeUrl(base: string): string {
    let url = base.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /**
   * legacy webui 健康探测接口：GET /health
   */
  public static async probeHealth(baseUrl: string): Promise<boolean> {
    const cleanUrl = LegacySSEClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();

    try {
      const res = await client.request(`${cleanUrl}/health`, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000
      });
      return res.responseCode === 200;
    } catch (_e) {
      return false;
    } finally {
      client.destroy();
    }
  }

  /**
   * 开启聊天轮次：POST /api/chat/start
   * 载荷：{ session_id, message }
   * 返回：{ streamId }
   */
  public static async startChatTurn(
    baseUrl: string,
    sessionId: string,
    message: string,
    token?: string,
    cookies?: string
  ): Promise<LegacyStartTurnResult | null> {
    const cleanUrl = LegacySSEClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();
    const headers: Record<string, string> = {
      'Content-Type': 'application/json'
    };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const res = await client.request(`${cleanUrl}/api/chat/start`, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify({
          session_id: sessionId,
          message: message
        }),
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (res.responseCode >= 200 && res.responseCode < 300) {
        const body = JSON.parse(String(res.result || '{}')) as Record<string, Object>;
        const streamId = String(body['stream_id'] || body['streamId'] || '');
        if (streamId) {
          const ret: LegacyStartTurnResult = { streamId: streamId };
          return ret;
        }
      }
      return null;
    } catch (_e) {
      return null;
    } finally {
      client.destroy();
    }
  }

  /**
   * 取消聊天轮次：GET /api/chat/cancel?stream_id=<id>
   * 严格对齐 upstream HermesMobile/Networking/APIClient+Chat.swift:34-35 (GET)
   */
  public static async cancelChatTurn(
    baseUrl: string,
    streamId: string,
    token?: string,
    cookies?: string
  ): Promise<boolean> {
    const cleanUrl = LegacySSEClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const res = await client.request(`${cleanUrl}/api/chat/cancel?stream_id=${encodeURIComponent(streamId)}`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 5000,
        readTimeout: 5000
      });
      return res.responseCode >= 200 && res.responseCode < 300;
    } catch (_e) {
      return false;
    } finally {
      client.destroy();
    }
  }

  /**
   * 建立长连接 SSE 数据流：GET /api/chat/stream?stream_id=<id>
   * 使用持续 Decoder 会话与增量 LegacySSEParser 消费流式数据块，完美防御中文字节跨 TCP 分包损坏
   */
  public static connectSSEStream(
    baseUrl: string,
    streamId: string,
    callbacks: LegacySSECallbacks,
    token?: string,
    cookies?: string
  ): SSEStreamHandle {
    const cleanUrl = LegacySSEClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();
    const parser = new LegacySSEParser();
    const decoder = util.TextDecoder.create('utf-8');
    let isClosed = false;
    let hasHttpError = false;

    const headers: Record<string, string> = {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      'Accept-Encoding': 'identity'
    };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    client.on('dataReceive', (chunk: ArrayBuffer) => {
      if (isClosed || hasHttpError) return;
      try {
        let chunkStr = '';
        if (typeof chunk === 'string') {
          chunkStr = chunk;
        } else if (chunk instanceof ArrayBuffer) {
          chunkStr = decoder.decodeWithStream(new Uint8Array(chunk), { stream: true });
        }
        const events = parser.feed(chunkStr);
        for (let i = 0; i < events.length; i++) {
          callbacks.onEvent(events[i]);
        }
      } catch (e) {
        callbacks.onError(String(e));
      }
    });

    const statusPromise = client.requestInStream(`${cleanUrl}/api/chat/stream?stream_id=${encodeURIComponent(streamId)}`, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 10000,
      readTimeout: 60000
    });

    statusPromise.then((statusCode: number) => {
      if (statusCode < 200 || statusCode >= 300) {
        hasHttpError = true;
        callbacks.onError(`SSE connection failed with HTTP status ${statusCode}`);
        if (!isClosed) {
          isClosed = true;
          callbacks.onClose();
          client.destroy();
        }
      }
    }).catch((err: Object) => {
      if (!isClosed) {
        callbacks.onError(String(err));
        isClosed = true;
        callbacks.onClose();
        client.destroy();
      }
    });

    client.on('dataEnd', () => {
      statusPromise.then((statusCode: number) => {
        if (isClosed) return;
        if (statusCode >= 200 && statusCode < 300) {
          try {
            const finalChunk = decoder.decodeWithStream(new Uint8Array(0), { stream: false });
            if (finalChunk.length > 0) {
              const finalEvents = parser.feed(finalChunk);
              for (let i = 0; i < finalEvents.length; i++) {
                callbacks.onEvent(finalEvents[i]);
              }
            }
          } catch (_e) {}
          const leftovers = parser.finish();
          for (let i = 0; i < leftovers.length; i++) {
            callbacks.onEvent(leftovers[i]);
          }
          isClosed = true;
          callbacks.onClose();
          client.destroy();
        }
      }).catch((_e: Object) => {});
    });

    return {
      cancel: () => {
        if (!isClosed) {
          isClosed = true;
          callbacks.onClose();
          client.destroy();
        }
      }
    };
  }

  /**
   * 拉取历史会话列表：GET /api/sessions
   */
  public static async listSessions(
    baseUrl: string,
    token?: string,
    cookies?: string
  ): Promise<LegacySessionItem[]> {
    const cleanUrl = LegacySSEClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const res = await client.request(`${cleanUrl}/api/sessions`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (res.responseCode === 200) {
        const data = JSON.parse(String(res.result || '[]')) as Array<Record<string, Object>>;
        const list: LegacySessionItem[] = [];
        if (Array.isArray(data)) {
          for (let i = 0; i < data.length; i++) {
            const item = data[i];
            list.push({
              id: String(item['id'] || `session-${i}`),
              title: String(item['title'] || 'Untitled'),
              updatedAt: typeof item['updated_at'] === 'number' ? item['updated_at'] : undefined,
              createdAt: typeof item['created_at'] === 'number' ? item['created_at'] : undefined,
              preview: item['preview'] ? String(item['preview']) : undefined
            });
          }
        }
        return list;
      }
      return [];
    } catch (_e) {
      return [];
    } finally {
      client.destroy();
    }
  }

  /**
   * 拉取会话详情与消息：GET /api/session?id=<id>
   */
  public static async getSession(
    baseUrl: string,
    sessionId: string,
    token?: string,
    cookies?: string
  ): Promise<LegacySessionDetail | null> {
    const cleanUrl = LegacySSEClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (cookies) headers['Cookie'] = cookies;

    try {
      const res = await client.request(`${cleanUrl}/api/session?id=${encodeURIComponent(sessionId)}`, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000
      });
      if (res.responseCode === 200) {
        const data = JSON.parse(String(res.result || '{}')) as Record<string, Object>;
        const rawMsgs = (data['messages'] as Array<Record<string, Object>>) || [];
        const msgs: LegacyChatMessageItem[] = [];
        for (let i = 0; i < rawMsgs.length; i++) {
          const m = rawMsgs[i];
          const roleStr = String(m['role'] || 'user');
          const role: 'user' | 'assistant' | 'system' = (roleStr === 'assistant' || roleStr === 'system') ? roleStr : 'user';
          msgs.push({
            role: role,
            content: String(m['content'] || ''),
            timestamp: typeof m['timestamp'] === 'number' ? m['timestamp'] : undefined
          });
        }
        return {
          id: String(data['id'] || sessionId),
          title: String(data['title'] || 'Untitled'),
          messages: msgs
        };
      }
      return null;
    } catch (_e) {
      return null;
    } finally {
      client.destroy();
    }
  }

  /**
   * 静态单块解析工具 (兼容旧版调用)
   */
  public static parseSSEChunk(chunk: string): LegacySSEEvent[] {
    const parser = new LegacySSEParser();
    const ev1 = parser.feed(chunk);
    const ev2 = parser.finish();
    return ev1.concat(ev2);
  }
}
