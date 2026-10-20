import http from '@ohos.net.http';

export interface UploadImageResult {
  url?: string;
  path?: string;
  filename: string;
}

/**
 * Hermes 附件上传与产物管理客户端
 * 严格对齐 HermesREST.swift: uploadImage 与 downloadArtifact
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
   * @param base64Data Base64 编码的图片或 Data URI
   */
  public static async uploadImage(
    baseUrl: string,
    profile: string,
    filename: string,
    base64Data: string,
    mimeType: string = 'image/jpeg',
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

      let dataUrl = base64Data;
      if (!dataUrl.startsWith('data:')) {
        dataUrl = `data:${mimeType};base64,${base64Data}`;
      }

      const payload: Record<string, string> = {
        'filename': filename,
        'data': dataUrl
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
        url: parsed['url'] ? String(parsed['url']) : undefined,
        path: parsed['path'] ? String(parsed['path']) : undefined,
        filename: filename
      };
    } finally {
      client.destroy();
    }
  }

  /**
   * 下载会话或工作区产物文件：GET /api/fs/download?path=<path>&profile=<profile>&session_id=<sessionId>
   */
  public static async downloadArtifact(
    baseUrl: string,
    path: string,
    profile: string,
    sessionId?: string,
    token?: string,
    cookies?: string
  ): Promise<string> {
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

      let query = `?path=${encodeURIComponent(path)}`;
      if (profile) {
        query += `&profile=${encodeURIComponent(profile)}`;
      }
      if (sessionId) {
        query += `&session_id=${encodeURIComponent(sessionId)}`;
      }

      const res = await client.request(`${cleanUrl}/api/fs/download${query}`, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 15000,
        header: headers
      });

      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`Download artifact failed with HTTP ${res.responseCode}`);
      }

      return typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
    } finally {
      client.destroy();
    }
  }
}
