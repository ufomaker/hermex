/**
 * 会话元数据模型
 */
export interface HermesSession {
  id: string;
  stored_session_id?: string;
  title: string;
  profile: string;
  created_at?: number;
  updated_at?: number;
  running?: boolean;
  model?: string;
  is_pinned?: boolean;
  is_archived?: boolean;
}
