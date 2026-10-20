import { BotConnection } from '../model/Connection';
import { ChatMessage, ToolCallItem } from '../model/ChatMessage';
import { ApprovalRequest, ClarifyRequest, ModelOption } from '../model/Approval';
import { HermesRESTClient } from '../network/HermesRESTClient';
import { HermesGatewayClient, GatewayEventCallbacks } from '../network/HermesGatewayClient';

export interface ChatUIStateListener {
  onStateChanged: () => void;
  onErrorToast?: (msg: string) => void;
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
  public isSubmittingApproval: boolean = false;
  public isSubmittingClarify: boolean = false;

  private gateway: HermesGatewayClient | null = null;
  private storedSessionId: string = '';
  private runtimeSessionId: string = '';
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

  private toast(msg: string): void {
    if (this.listener && this.listener.onErrorToast) {
      this.listener.onErrorToast(msg);
    }
  }

  public getStoredSessionId(): string {
    return this.storedSessionId;
  }

  public getRuntimeSessionId(): string {
    return this.runtimeSessionId;
  }

  public getGateway(): HermesGatewayClient | null {
    return this.gateway;
  }

  /**
   * 初始化并连接到指定会话
   */
  public async attachSession(conn: BotConnection, targetSessionId: string): Promise<void> {
    this.disconnect();
    this.storedSessionId = targetSessionId;
    this.runtimeSessionId = targetSessionId;
    this.currentProfile = conn.activeProfile || 'default';
    this.connectionStatusText = '正在换取 Ticket...';
    this.notify();

    try {
      // 1. 换取单次有效 ticket (支持 Cookie 与 Token)
      const ticket = await HermesRESTClient.getWsTicket(conn.url, conn.token, conn.cookies);
      this.connectionStatusText = '正在建立 Gateway 握手...';
      this.notify();

      // 2. 构造回调
      const callbacks: GatewayEventCallbacks = {
        onConnected: async () => {
          this.isConnected = true;
          this.connectionStatusText = '已连接网关';
          this.notify();

          // 3. 恢复会话上下文并获得真实 runtime ID
          if (this.gateway && this.storedSessionId) {
            try {
              const resumeRes = await this.gateway.resumeSession(this.storedSessionId, this.currentProfile);
              const runtime = String(resumeRes['session_id'] || this.storedSessionId);
              this.runtimeSessionId = runtime;
              this.gateway.setActiveRuntime(runtime);
            } catch (resErr) {
              this.toast(`恢复会话失败: ${resErr}`);
            }
          }

          // 4. 拉取该会话真实历史消息并加载到界面
          try {
            const history = await HermesRESTClient.getSessionMessages(
              conn.url,
              this.storedSessionId,
              this.currentProfile,
              conn.token,
              conn.cookies
            );
            if (history.length > 0) {
              this.messages = history;
              this.notify();
            }
          } catch (histErr) {
            // 新会话可能暂无历史，不阻断
          }

          // 5. 刷新模型列表
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
          this.toast(errText);
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
      this.gateway.setActiveRuntime(this.runtimeSessionId);
      await this.gateway.connect(conn.url, ticket);
    } catch (e) {
      this.isConnected = false;
      this.connectionStatusText = `连接失败: ${e}`;
      this.toast(`网关握手失败: ${e}`);
      this.notify();
    }
  }

  /**
   * 真实在服务端创建会话并切入
   */
  public async createAndAttachNewSession(conn: BotConnection): Promise<string> {
    if (!this.gateway || !this.isConnected) {
      throw new Error('网关尚未连接');
    }
    const profile = conn.activeProfile || 'default';
    const res = await this.gateway.createSession(profile);
    const newSessionId = String(res['session_id'] || res['id'] || '');
    if (!newSessionId) {
      throw new Error('服务端未返回有效 session_id');
    }
    this.storedSessionId = newSessionId;
    this.runtimeSessionId = newSessionId;
    this.gateway.setActiveRuntime(newSessionId);
    this.messages = [];
    this.notify();
    return newSessionId;
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
   * 发送聊天文本 (使用真实 runtimeSessionId)
   */
  public async sendMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed || !this.runtimeSessionId || !this.gateway) {
      return;
    }

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

    try {
      await this.gateway.submitPrompt(this.runtimeSessionId, trimmed);
    } catch (e) {
      this.isGenerating = false;
      this.messages.push({
        id: `err_send_${Date.now()}`,
        role: 'system',
        content: `发送失败: ${e}`,
        status: 'error',
        createdAt: Date.now()
      });
      this.toast(`发送失败: ${e}`);
      this.notify();
    }
  }

  /**
   * 中断停止生成 (真实发送 session.interrupt)
   */
  public async stopGenerating(): Promise<void> {
    if (!this.gateway || !this.runtimeSessionId) {
      return;
    }
    try {
      await this.gateway.interruptSession(this.runtimeSessionId);
      this.isGenerating = false;
      this.notify();
    } catch (e) {
      this.toast(`停止生成失败: ${e}`);
    }
  }

  /**
   * 提交审批决定 (可恢复，失败不吞错)
   */
  public async submitApproval(choice: string): Promise<void> {
    if (!this.gateway || !this.currentApproval || this.isSubmittingApproval) {
      return;
    }
    this.isSubmittingApproval = true;
    this.notify();

    const req = this.currentApproval;
    try {
      await this.gateway.respondApproval(this.runtimeSessionId, req.id, choice);
      this.currentApproval = null;
    } catch (e) {
      this.toast(`审批提交失败，请重试: ${e}`);
      // 保持 currentApproval 不清除，供用户重试
    } finally {
      this.isSubmittingApproval = false;
      this.notify();
    }
  }

  /**
   * 提交澄清回答 (可恢复，失败不吞错)
   */
  public async submitClarify(answer: string): Promise<void> {
    if (!this.gateway || !this.currentClarify || this.isSubmittingClarify) {
      return;
    }
    this.isSubmittingClarify = true;
    this.notify();

    const req = this.currentClarify;
    try {
      await this.gateway.answerClarify(req.id, answer);
      this.currentClarify = null;
    } catch (e) {
      this.toast(`澄清答复提交失败，请重试: ${e}`);
    } finally {
      this.isSubmittingClarify = false;
      this.notify();
    }
  }

  /**
   * 真实切换模型并向服务端写回配置 (config.set)
   */
  public async switchModel(modelName: string): Promise<void> {
    if (!this.gateway || !this.runtimeSessionId) {
      return;
    }
    const oldModel = this.currentModel;
    try {
      await this.gateway.setModelConfig(this.runtimeSessionId, this.currentProfile, modelName);
      this.currentModel = modelName;
      this.notify();
    } catch (e) {
      this.currentModel = oldModel;
      this.toast(`切换模型失败: ${e}`);
      this.notify();
    }
  }

  /**
   * 刷新模型列表
   */
  public async refreshModels(): Promise<void> {
    if (!this.gateway || !this.runtimeSessionId) {
      return;
    }
    try {
      const models = await this.gateway.getModelOptions(this.runtimeSessionId, this.currentProfile);
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
