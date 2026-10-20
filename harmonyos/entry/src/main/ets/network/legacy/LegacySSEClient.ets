import http from '@ohos.net.http';

export interface LegacySSEEvent {
  event?: string;
  data: string;
  id?: string;
}

/**
 * 针对上游 legacy hermes-webui (UPSTREAM_TESTED_SHA: c67fd2dd) 的向后兼容 SSE 客户端
 * 严格支持 /health 探针与 SSE 数据帧解析
 */
export class LegacySSEClient {
  private static sanitizeUrl(base: string): string {
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
    } catch (e) {
      return false;
    } finally {
      client.destroy();
    }
  }

  /**
   * 解析 SSE 数据块字符串
   */
  public static parseSSEChunk(chunk: string): LegacySSEEvent[] {
    const lines = chunk.split('\n');
    const events: LegacySSEEvent[] = [];
    let currentEvent = '';
    let currentDataParts: string[] = [];
    let currentId = '';

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) {
        if (currentDataParts.length > 0) {
          events.push({
            event: currentEvent || undefined,
            data: currentDataParts.join('\n'),
            id: currentId || undefined
          });
          currentEvent = '';
          currentDataParts = [];
          currentId = '';
        }
        continue;
      }

      if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        currentDataParts.push(line.substring(5).trim());
      } else if (line.startsWith('id:')) {
        currentId = line.substring(3).trim();
      }
    }

    if (currentDataParts.length > 0) {
      events.push({
        event: currentEvent || undefined,
        data: currentDataParts.join('\n'),
        id: currentId || undefined
      });
    }

    return events;
  }
}
