import { BotConnection } from '../model/Connection';
import { ChatMessage, ToolCallItem } from '../model/ChatMessage';
import { ApprovalRequest, ClarifyRequest, ModelOption } from '../model/Approval';
import { HermesRESTClient } from '../network/HermesRESTClient';
import { HermesGatewayClient, GatewayEventCallbacks } from '../network/HermesGatewayClient';

export interface ChatUIStateListener {
  onStateChanged: () => void;
}

export class ChatViewModel {
  public messages: ChatMessage[] = [];
  public isGenerating: boolean = false;
  public currentModel: string = '默认模型';
  public availableModels: ModelOption[] = [];
  public currentApproval: ApprovalRequest | null = null;
  public currentClarify: ClarifyRequest | null = null;
  public connectionStatusText: string = '未连接';
  public isConnected: boolean = false;

  private gateway: HermesGatewayClient | null = null;
  private currentSessionId: string = '';
  private currentProfile: string = 'default';
  private listener: ChatUIStateListener | null = null;

  public setListener(listener: ChatUIStateListener): void {
    this.listener = listener;
  }

  private notify(): void {
    if (this.listener) {
      this.listener.onStateChanged();
    }
  }

  /**
   * 初始化并连接到指定会话
   */
  public async attachSession(conn: BotConnection, sessionId: string): Promise<void> {
    this.currentSessionId = sessionId;
    this.currentProfile = conn.activeProfile || 'default';
    this.connectionStatusText = '正在获取 Ticket...';
    this.notify();

    try {
      // 1. 严格使用 /api/auth/ws-ticket 换取一次性 WebSocket ticket
      const ticket = await HermesRESTClient.getWsTicket(conn.url, conn.token);
      this.connectionStatusText = '正在连接网关...';
      this.notify();

      // 2. 构造 GatewayEvent 回调
      const callbacks: GatewayEventCallbacks = {
        onConnected: () => {
          this.isConnected = true;
          this.connectionStatusText = '已连接';
          this.notify();
          // 恢复会话上下文
          if (this.gateway && this.currentSessionId) {
            this.gateway.resumeSession(this.currentSessionId, this.currentProfile).catch(() => {});
          }
          // 加载模型列表
          this.refreshModels();
        },
        onDisconnected: (reason: string) => {
          this.isConnected = false;
          this.isGenerating = false;
          this.connectionStatusText = `已断开: ${reason}`;
          this.notify();
        },
        onMessageStart: (sid: string) => {
          this.isGenerating = true;
          const newMsg: ChatMessage = {
            id: `msg_ast_${Date.now()}`,
            role: 'assistant',
            content: '',
            reasoning: '',
            toolCalls: [],
            status: 'streaming',
            createdAt: Date.now()
          };
          this.messages.push(newMsg);
          this.notify();
        },
        onMessageDelta: (sid: string, delta: string) => {
          const current = this.getLatestAssistantMessage();
          if (current) {
            current.content += delta;
            this.notify();
          }
        },
        onReasoningDelta: (sid: string, delta: string) => {
          const current = this.getLatestAssistantMessage();
          if (current) {
            current.reasoning = (current.reasoning || '') + delta;
            this.notify();
          }
        },
        onToolStart: (sid: string, tool: ToolCallItem) => {
          const current = this.getLatestAssistantMessage();
          if (current) {
            current.toolCalls = current.toolCalls || [];
            current.toolCalls.push(tool);
            this.notify();
          }
        },
        onToolComplete: (sid: string, tool: ToolCallItem) => {
          const current = this.getLatestAssistantMessage();
          if (current && current.toolCalls) {
            const idx = current.toolCalls.findIndex(t => t.id === tool.id || t.name === tool.name);
            if (idx >= 0) {
              current.toolCalls[idx] = tool;
            } else {
              current.toolCalls.push(tool);
            }
            this.notify();
          }
        },
        onMessageComplete: (sid: string) => {
          this.isGenerating = false;
          const current = this.getLatestAssistantMessage();
          if (current) {
            current.status = 'complete';
          }
          this.notify();
        },
        onSessionInfo: (sid: string, running: boolean, model?: string, title?: string) => {
          this.isGenerating = running;
          if (model) {
            this.currentModel = model;
          }
          this.notify();
        },
        onError: (sid: string, errText: string) => {
          this.isGenerating = false;
          const current = this.getLatestAssistantMessage();
          if (current) {
            current.status = 'error';
            current.errorMessage = errText;
          } else {
            this.messages.push({
              id: `err_${Date.now()}`,
              role: 'system',
              content: `错误: ${errText}`,
              status: 'error',
              createdAt: Date.now()
            });
          }
          this.notify();
        },
        onApprovalRequest: (req: ApprovalRequest) => {
          this.currentApproval = req;
          this.notify();
        },
        onClarifyRequest: (req: ClarifyRequest) => {
          this.currentClarify = req;
          this.notify();
        }
      };

      this.gateway = new HermesGatewayClient(callbacks);
      await this.gateway.connect(conn.url, ticket);
    } catch (e) {
      this.isConnected = false;
      this.connectionStatusText = `连接异常: ${e}`;
      this.notify();
    }
  }

  private getLatestAssistantMessage(): ChatMessage | null {
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === 'assistant') {
        return this.messages[i];
      }
    }
    return null;
  }

  /**
   * 发送聊天文本
   */
  public async sendMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed || !this.currentSessionId || !this.gateway) {
      return;
    }

    // 1. 本地立即追加 User 消息
    const userMsg: ChatMessage = {
      id: `msg_usr_${Date.now()}`,
      role: 'user',
      content: trimmed,
      status: 'complete',
      createdAt: Date.now()
    };
    this.messages.push(userMsg);
    this.isGenerating = true;
    this.notify();

    // 2. 通过 Gateway 发送 prompt.submit
    try {
      await this.gateway.submitPrompt(this.currentSessionId, trimmed);
    } catch (e) {
      this.isGenerating = false;
      this.messages.push({
        id: `err_send_${Date.now()}`,
        role: 'system',
        content: `发送失败: ${e}`,
        status: 'error',
        createdAt: Date.now()
      });
      this.notify();
    }
  }

  /**
   * 中断停止生成
   * 严格核实契约：session.interrupt
   */
  public async stopGenerating(): Promise<void> {
    if (!this.gateway || !this.currentSessionId) {
      return;
    }
    try {
      await this.gateway.interruptSession(this.currentSessionId);
      this.isGenerating = false;
      this.notify();
    } catch (e) {
      // ignore
    }
  }

  /**
   * 提交审批决定
   */
  public async submitApproval(choice: string): Promise<void> {
    if (!this.gateway || !this.currentApproval) {
      return;
    }
    const req = this.currentApproval;
    this.currentApproval = null;
    this.notify();
    try {
      await this.gateway.respondApproval(req.sessionId, req.id, choice);
    } catch (e) {
      // ignore
    }
  }

  /**
   * 提交澄清回答
   */
  public async submitClarify(answer: string): Promise<void> {
    if (!this.gateway || !this.currentClarify) {
      return;
    }
    const req = this.currentClarify;
    this.currentClarify = null;
    this.notify();
    try {
      await this.gateway.answerClarify(req.id, answer);
    } catch (e) {
      // ignore
    }
  }

  /**
   * 刷新模型列表
   */
  public async refreshModels(): Promise<void> {
    if (!this.gateway || !this.currentSessionId) {
      return;
    }
    try {
      const models = await this.gateway.getModelOptions(this.currentSessionId, this.currentProfile);
      this.availableModels = models;
      this.notify();
    } catch (e) {
      // ignore
    }
  }

  public disconnect(): void {
    if (this.gateway) {
      this.gateway.disconnect();
      this.gateway = null;
    }
    this.isConnected = false;
    this.isGenerating = false;
  }
}
