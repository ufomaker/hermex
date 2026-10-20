/**
 * 聊天消息与工具调用模型
 */
export type MessageRole = 'user' | 'assistant' | 'system';
export type MessageStatus = 'pending' | 'streaming' | 'complete' | 'error';

export interface ToolCallItem {
  id: string;
  name: string;
  input?: string;
  output?: string;
  status: 'running' | 'completed' | 'failed';
}

export interface ChatMessage {
  id: string;
  role: MessageRole;
  content: string;
  reasoning?: string;
  toolCalls?: ToolCallItem[];
  status: MessageStatus;
  errorMessage?: string;
  createdAt: number;
}
