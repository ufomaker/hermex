/**
 * 会话元数据模型
 */
export interface HermesSession {
  id: string; // 存储标识 stored_session_id
  runtime_id?: string; // 活跃执行实例 ID
  title: string;
  profile: string;
  created_at?: number;
  updated_at?: number;
  running?: boolean;
  model?: string;
  is_pinned?: boolean;
  is_archived?: boolean;
}

export function cloneSession(s: HermesSession): HermesSession {
  const result: HermesSession = {
    id: s.id,
    runtime_id: s.runtime_id,
    title: s.title,
    profile: s.profile,
    created_at: s.created_at,
    updated_at: s.updated_at,
    running: s.running,
    model: s.model,
    is_pinned: s.is_pinned,
    is_archived: s.is_archived
  };
  return result;
}
