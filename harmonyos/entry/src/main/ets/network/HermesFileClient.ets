import http from '@ohos.net.http';

export interface UploadImageResult {
  success: boolean;
  url?: string;
  path?: string;
  error?: string;
}

/**
 * 文件与图片附件客户端
 * 严格对齐 HermesREST.swift:379-400 (/api/chat/image-upload 与 /api/fs/download)
 */
export class HermesFileClient {
  private static sanitizeUrl(base: string): string {
    let url = base.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /**
   * 上传图片附件：POST /api/chat/image-upload?profile=<profile>
   * 严格匹配 HermesREST.swift:379-384
   * 请求体必须包含: { "filename": filename, "data_url": dataUrl }
   */
  public static async uploadImage(
    baseUrl: string,
    profile: string,
    filename: string,
    base64OrDataUrl: string,
    token?: string,
    cookies?: string
  ): Promise<UploadImageResult> {
    const cleanUrl = HermesFileClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();

    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      if (cookies && cookies.length > 0) {
        headers['Cookie'] = cookies;
      }

      let dataUrl = base64OrDataUrl;
      if (!dataUrl.startsWith('data:')) {
        dataUrl = `data:image/jpeg;base64,${base64OrDataUrl}`;
      }

      const payload: Record<string, string> = {
        'filename': filename,
        'data_url': dataUrl
      };

      const query = profile ? `?profile=${encodeURIComponent(profile)}` : '';
      const res = await client.request(`${cleanUrl}/api/chat/image-upload${query}`, {
        method: http.RequestMethod.POST,
        connectTimeout: 15000,
        readTimeout: 15000,
        header: headers,
        extraData: JSON.stringify(payload)
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`Upload image failed with HTTP ${res.responseCode}`);
      }

      const dataStr = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const parsed = JSON.parse(dataStr) as Record<string, Object>;

      return {
        success: true,
        path: String(parsed['path'] || parsed['url'] || parsed['filename'] || ''),
        url: parsed['url'] ? String(parsed['url']) : undefined
      };
    } finally {
      client.destroy();
    }
  }

  /**
   * 下载会话或工作区产物二进制文件：GET /api/fs/download?path=<path>&profile=<profile>&session_id=<sessionId>
   * 使用 ArrayBuffer 二进制接收，杜绝文本替换字符损坏二进制附件 (对齐 HermesREST.swift:388-400)
   */
  public static async downloadArtifact(
    baseUrl: string,
    path: string,
    profile: string,
    sessionId?: string,
    token?: string,
    cookies?: string
  ): Promise<ArrayBuffer> {
    const cleanUrl = HermesFileClient.sanitizeUrl(baseUrl);
    const client = http.createHttp();

    try {
      const headers: Record<string, string> = {
        'Accept': '*/*'
      };
      if (token && token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      if (cookies && cookies.length > 0) {
        headers['Cookie'] = cookies;
      }

      let query = `?path=${encodeURIComponent(path)}&profile=${encodeURIComponent(profile)}`;
      if (sessionId && sessionId.length > 0) {
        query += `&session_id=${encodeURIComponent(sessionId)}`;
      }

      const res = await client.request(`${cleanUrl}/api/fs/download${query}`, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 15000,
        header: headers
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`Download artifact failed with HTTP ${res.responseCode}`);
      }

      if (res.result instanceof ArrayBuffer) {
        return res.result;
      }
      if (typeof res.result === 'string') {
        const str = res.result as string;
        const buf = new ArrayBuffer(str.length);
        const view = new Uint8Array(buf);
        for (let i = 0; i < str.length; i++) {
          view[i] = str.charCodeAt(i) & 0xff;
        }
        return buf;
      }
      return new ArrayBuffer(0);
    } finally {
      client.destroy();
    }
  }
}
