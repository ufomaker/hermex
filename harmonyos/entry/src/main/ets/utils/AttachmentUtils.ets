/**
 * 附件媒体类型与安全文件名处理工具
 * 严格对齐 upstream Hermes BotAttachmentUpload.swift 与路径安全规范
 */

export function getMimeType(filename: string): string {
  const parts = filename.split('.');
  const ext = (parts.length > 1 ? parts.pop() : '')?.toLowerCase() || '';

  switch (ext) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'svg':
      return 'image/svg+xml';
    case 'bmp':
      return 'image/bmp';
    case 'heic':
    case 'heif':
      return 'image/heic';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
    case 'log':
      return 'text/plain';
    case 'md':
      return 'text/markdown';
    case 'json':
      return 'application/json';
    case 'csv':
      return 'text/csv';
    case 'xml':
      return 'application/xml';
    case 'yaml':
    case 'yml':
      return 'application/x-yaml';
    case 'html':
    case 'htm':
      return 'text/html';
    case 'js':
    case 'ts':
    case 'ets':
    case 'py':
    case 'sh':
    case 'rs':
    case 'go':
    case 'java':
    case 'c':
    case 'cpp':
      return 'text/plain';
    case 'zip':
      return 'application/zip';
    case 'tar':
      return 'application/x-tar';
    case 'gz':
      return 'application/gzip';
    case 'doc':
      return 'application/msword';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'ppt':
      return 'application/vnd.ms-powerpoint';
    case 'pptx':
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'mp3':
      return 'audio/mpeg';
    case 'wav':
      return 'audio/wav';
    case 'm4a':
      return 'audio/m4a';
    case 'ogg':
      return 'audio/ogg';
    default:
      return 'application/octet-stream';
  }
}

/**
 * 判断是否为图片格式
 */
export function isImageFile(filename: string): boolean {
  const parts = filename.split('.');
  const ext = (parts.length > 1 ? parts.pop() : '')?.toLowerCase() || '';
  return ['png', 'jpg', 'jpeg', 'webp', 'gif', 'svg', 'bmp', 'heic', 'heif'].includes(ext);
}

/**
 * 安全文件名清洗：剔除路径穿越符 (../, ..\\)、非法控制符与空白
 */
export function sanitizeFilename(raw: string): string {
  if (!raw) {
    return 'attachment.bin';
  }
  // 提取纯文件名 (去除一切路径分隔符)
  const base = raw.replace(/\\/g, '/').split('/').pop() || '';
  // 过滤路径遍历字符、控制字符及危险字符
  let sanitized = base.replace(/\.\.+/g, '').replace(/[/?%*:|"<>]/g, '_').trim();
  if (sanitized.startsWith('.')) {
    sanitized = sanitized.substring(1);
  }
  return sanitized.length > 0 ? sanitized : 'attachment.bin';
}

/**
 * 生成符合上游 BotAttachmentUpload.swift 规范的唯一附件名称 (UUID-filename)
 */
export function generateAttachmentName(filename: string): string {
  const safe = sanitizeFilename(filename);
  const chars = '0123456789abcdef';
  let uuid = '';
  for (let i = 0; i < 32; i++) {
    if (i === 8 || i === 12 || i === 16 || i === 20) {
      uuid += '-';
    }
    uuid += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return `${uuid}-${safe}`;
}
