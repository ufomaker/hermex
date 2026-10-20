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
  public lastErrorDetail: string = '';
  public isConnected: boolean = false;
  public isSubmittingApproval: boolean = false;
  public isSubmittingClarify: boolean = false;

  private gateway: HermesGatewayClient | null = null;
  private storedSessionId: string = '';
  private runtimeSessionId: string = '';
  private currentProfile: string = 'default';
  private listener: ChatUIStateListener | null = null;
  private sessionAttachGeneration: number = 0;

  public setListener(listener: ChatUIStateListener): void {
    this.listener = listener;
  }

  private notify(): void {
    if (this.listener && this.listener.onStateChanged) {
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
   * 初始化并连接到指定会话 (具备严格的 async 代次保护与恢复门禁)
   */
  public async attachSession(conn: BotConnection, targetSessionId: string): Promise<void> {
    this.disconnect();
    const currentAttachGen = ++this.sessionAttachGeneration;
    this.storedSessionId = targetSessionId;
    this.runtimeSessionId = '';
    this.isConnected = false;
    this.currentProfile = conn.activeProfile || 'default';
    this.connectionStatusText = '正在换取 Ticket...';
    this.notify();

    try {
      // 1. 换取单次有效 ticket
      const ticket = await HermesRESTClient.getWsTicket(conn.url, conn.token, conn.cookies);
      if (this.sessionAttachGeneration !== currentAttachGen) {
        return; // 过期调用，立即放弃
      }

      this.connectionStatusText = '正在建立 Gateway 握手...';
      this.notify();

      // 2. 构造回调 (双重绑定代次与实例身份)
      let activeGateway: HermesGatewayClient | null = null;
      const callbacks: GatewayEventCallbacks = {
        onConnected: async () => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) {
            return;
          }

          // 3. 恢复会话上下文并获得真实 runtime ID
          if (this.gateway && this.storedSessionId) {
            try {
              const resumeRes = await this.gateway.resumeSession(this.storedSessionId, this.currentProfile);
              if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) {
                return;
              }
              const runtime = String(resumeRes['session_id'] || '');
              if (!runtime) {
                throw new Error('resume 未返回有效 session_id');
              }
              this.runtimeSessionId = runtime;
              this.gateway.setActiveRuntime(runtime);
              this.isConnected = true;
              this.connectionStatusText = '会话已恢复';
              this.notify();
            } catch (resErr) {
              if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) {
                return;
              }
              this.runtimeSessionId = '';
              this.isConnected = false;
              this.connectionStatusText = '会话恢复失败';
              this.toast(`会话恢复失败: ${resErr}`);
              this.notify();
              return; // 恢复失败严禁宣布已就绪
            }
          } else {
            this.isConnected = true;
            this.connectionStatusText = '网关已连接 (待建会话)';
            this.notify();
          }

          // 4. 拉取该会话真实历史消息并加载到界面
          if (this.storedSessionId) {
            try {
              const history = await HermesRESTClient.getSessionMessages(
                conn.url,
                this.storedSessionId,
                this.currentProfile,
                conn.token,
                conn.cookies
              );
              if (this.sessionAttachGeneration === currentAttachGen && this.gateway === activeGateway && history.length > 0) {
                this.messages = history;
                this.notify();
              }
            } catch (histErr) {
              // 新会话可能暂无历史
            }
          }

          // 5. 刷新模型列表
          if (this.sessionAttachGeneration === currentAttachGen && this.gateway === activeGateway) {
            this.refreshModels();
          }
        },
        onDisconnected: (reason: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) {
            return;
          }
          this.isConnected = false;
          this.isGenerating = false;
          this.runtimeSessionId = '';
          this.connectionStatusText = '已断开';
          this.lastErrorDetail = reason;
          this.notify();
        },
        onMessageStart: (sid: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
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
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          const current = this.getLatestAssistantMessage();
          if (current) {
            current.content += delta;
            this.notify();
          }
        },
        onReasoningDelta: (sid: string, delta: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          const current = this.getLatestAssistantMessage();
          if (current) {
            current.reasoning = (current.reasoning || '') + delta;
            this.notify();
          }
        },
        onToolStart: (sid: string, tool: ToolCallItem) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          const current = this.getLatestAssistantMessage();
          if (current) {
            current.toolCalls = current.toolCalls || [];
            current.toolCalls.push(tool);
            this.notify();
          }
        },
        onToolComplete: (sid: string, tool: ToolCallItem) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
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
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          this.isGenerating = false;
          const current = this.getLatestAssistantMessage();
          if (current) {
            current.status = 'complete';
          }
          this.notify();
        },
        onSessionInfo: (sid: string, running: boolean, model?: string, title?: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          this.isGenerating = running;
          if (model) {
            this.currentModel = model;
          }
          this.notify();
        },
        onError: (sid: string, errText: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
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
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          this.currentApproval = req;
          this.notify();
        },
        onClarifyRequest: (req: ClarifyRequest) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          this.currentClarify = req;
          this.notify();
        }
      };

      const newGateway = new HermesGatewayClient(callbacks);
      activeGateway = newGateway;
      if (this.sessionAttachGeneration !== currentAttachGen) {
        return;
      }
      this.gateway = newGateway;
      await this.gateway.connect(conn.url, ticket);
    } catch (e) {
      if (this.sessionAttachGeneration !== currentAttachGen) {
        return;
      }
      this.isConnected = false;
      this.runtimeSessionId = '';
      this.connectionStatusText = '连接失败';
      this.lastErrorDetail = `${e}`;
      this.toast(`网关握手失败: ${e}`);
      this.notify();
    }
  }

  /**
   * 真实在服务端创建会话并切入
   */
  public async createAndAttachNewSession(conn: BotConnection): Promise<string> {
    if (!this.gateway) {
      throw new Error('网关尚未初始化');
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
    this.isConnected = true;
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
   * 发送聊天文本 (严格校验真实 runtimeSessionId 与连接状态)
   */
  public async sendMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) {
      return;
    }
    if (!this.isConnected || !this.runtimeSessionId || !this.gateway) {
      this.toast('当前会话尚未就绪或恢复失败，无法发送');
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
      this.toast('当前无活跃会话，无法配置模型');
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

  /**
   * 附加普通文档到会话上下文 (file.attach RPC)
   */
  public async attachDocument(filename: string, dataUrl: string): Promise<Record<string, Object>> {
    if (!this.gateway) {
      throw new Error('未连接到活跃会话网关');
    }
    const targetSession = this.runtimeSessionId || this.storedSessionId;
    if (!targetSession) {
      throw new Error('未选择有效会话');
    }
    return await this.gateway.fileAttach(targetSession, filename, dataUrl);
  }

  public disconnect(): void {
    this.sessionAttachGeneration += 1;
    if (this.gateway) {
      this.gateway.disconnect();
      this.gateway = null;
    }
    this.isConnected = false;
    this.isGenerating = false;
    this.runtimeSessionId = '';
  }
}
