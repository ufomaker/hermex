/**
 * 审批请求、澄清提问及模型配置模型
 */
export interface ApprovalRequest {
  id: string; // server request id
  sessionId: string;
  toolName?: string;
  description?: string;
  command?: string;
  choices?: string[]; // 例如 ['approve', 'reject', 'always']
}

export interface ClarifyRequest {
  id: string; // server request id
  sessionId: string;
  questionId: string;
  question: string;
  options?: string[];
}

export interface ModelOption {
  id: string;
  name: string;
  provider?: string;
  isDefault?: boolean;
}
