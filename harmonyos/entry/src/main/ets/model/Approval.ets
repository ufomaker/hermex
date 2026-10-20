/**
 * 审批请求、澄清提问及模型配置模型
 */
export interface ApprovalRequest {
  id: string; // 外层 JSON-RPC 报文 id (如 srq-...)
  requestId: string; // 内层 params.request_id (用于 approval.respond)
  sessionId: string;
  toolName?: string;
  description?: string;
  command?: string;
  choices?: string[]; // 上游预计算选项: ['once', 'session', 'always', 'deny']
}

export interface ClarifyRequest {
  id: string; // 外层 JSON-RPC 报文 id (如 srq-...)
  requestId: string; // 内层 params.request_id 或 outer id
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
