import { BotConnection } from '../model/Connection';
import { ChatMessage, ToolCallItem } from '../model/ChatMessage';
import { ApprovalRequest, ClarifyRequest, ModelOption } from '../model/Approval';
import {
  ModelCatalog,
  ModelCatalogOption,
  ModelCatalogGroup,
  REASONING_EFFORT_LEVELS
} from '../model/ModelCatalog';
import { HermesRESTClient } from '../network/HermesRESTClient';
import { HermesGatewayClient, GatewayEventCallbacks } from '../network/HermesGatewayClient';
import { LegacySSEClient, SSEStreamHandle } from '../network/legacy/LegacySSEClient';
import { NotificationUtils } from '../utils/NotificationUtils';

export interface ChatUIStateListener {
  onStateChanged: () => void;
  onErrorToast?: (msg: string) => void;
}

export class ChatViewModel {
  public messages: ChatMessage[] = [];
  public isGenerating: boolean = false;
  public currentModel: string = '默认模型';
  public currentModelProvider: string = '';
  public currentReasoningEffort: string = 'none';
  public supportedReasoningEfforts: string[] = REASONING_EFFORT_LEVELS;
  public availableModels: ModelOption[] = [];
  public modelCatalog: ModelCatalog | null = null;
  public availableModelGroups: ModelCatalogGroup[] = [];
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
  private modelFetchGeneration: number = 0;
  private baseUrl: string = '';
  private token?: string;
  private cookies?: string;
  private isLegacyMode: boolean = false;
  private activeLegacyStreamHandle: SSEStreamHandle | null = null;
  private activeLegacyStreamId: string = '';

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
    this.baseUrl = conn.url;
    this.token = conn.token;
    this.cookies = conn.cookies;

    // 若当前连接为 legacy-webui 服务，走 Legacy SSE 协议通道
    if (conn.serverVersion === 'legacy-webui') {
      this.isLegacyMode = true;
      this.isConnected = true;
      this.connectionStatusText = 'Legacy WebUI 已连接';
      this.runtimeSessionId = this.storedSessionId;
      this.currentProfile = 'default';
      this.notify();
      if (this.storedSessionId) {
        try {
          const detail = await LegacySSEClient.getSession(conn.url, this.storedSessionId, conn.token, conn.cookies);
          if (this.sessionAttachGeneration === currentAttachGen && detail && detail.messages) {
            this.messages = detail.messages.map((m, idx) => {
              const item: ChatMessage = {
                id: `legacy_${idx}_${Date.now()}`,
                role: m.role,
                content: m.content,
                status: 'complete',
                createdAt: m.timestamp || Date.now()
              };
              return item;
            });
            this.notify();
          }
        } catch (_e) {
          // ignore
        }
      }
      return;
    }

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

              // 检查 open_requests 与 pending_approval，恢复等待中审批
              if (Array.isArray(resumeRes['open_requests'])) {
                const openReqs = resumeRes['open_requests'] as Array<Record<string, Object>>;
                for (let i = 0; i < openReqs.length; i++) {
                  const oReq = openReqs[i];
                  const oId = String(oReq['id'] || '');
                  const oMethod = String(oReq['method'] || '');
                  const oParams = (oReq['params'] as Record<string, Object>) || {};
                  this.gateway.handleServerRequest(oId, oMethod, oParams);
                }
              }
              if (!this.currentApproval && resumeRes['pending_approval']) {
                const pa = resumeRes['pending_approval'] as Record<string, Object>;
                this.currentApproval = {
                  id: `pa_${Date.now()}`,
                  requestId: String(pa['request_id'] || ''),
                  sessionId: this.runtimeSessionId,
                  toolName: 'terminal',
                  command: pa['command'] ? String(pa['command']) : undefined,
                  description: pa['description'] ? String(pa['description']) : undefined,
                  choices: Array.isArray(pa['choices']) ? (pa['choices'] as string[]) : ['once', 'session', 'always', 'deny']
                };
              }

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
          this.getOrCreateActiveAssistantMessage();
          this.notify();
        },
        onMessageDelta: (sid: string, delta: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          const current = this.getOrCreateActiveAssistantMessage();
          current.content += delta;
          this.notify();
        },
        onMessageInterim: (sid: string, text: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          const current = this.getOrCreateActiveAssistantMessage();
          current.content = text;
          this.notify();
        },
        onThinkingDelta: (sid: string, text: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          const current = this.getOrCreateActiveAssistantMessage();
          if (text) {
            current.reasoning = text;
            this.notify();
          }
        },
        onReasoningDelta: (sid: string, delta: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          const current = this.getOrCreateActiveAssistantMessage();
          current.reasoning = (current.reasoning || '') + delta;
          this.notify();
        },
        onToolStart: (sid: string, tool: ToolCallItem) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          const current = this.getOrCreateActiveAssistantMessage();
          current.toolCalls = current.toolCalls || [];
          const idx = current.toolCalls.findIndex(t => t.id === tool.id || (t.name === tool.name && t.status === 'running'));
          if (idx >= 0) {
            current.toolCalls[idx] = tool;
          } else {
            current.toolCalls.push(tool);
          }
          this.notify();
        },
        onToolComplete: (sid: string, tool: ToolCallItem) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          const current = this.getOrCreateActiveAssistantMessage();
          if (current && current.toolCalls) {
            const idx = current.toolCalls.findIndex(t => t.id === tool.id || t.name === tool.name);
            if (idx >= 0) {
              current.toolCalls[idx] = tool;
            } else {
              current.toolCalls.push(tool);
            }
          }
          this.notify();
        },
        onMessageComplete: (sid: string, text?: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          this.isGenerating = false;
          const current = this.getLatestAssistantMessage();
          if (current) {
            if (text) {
              current.content = text;
            }
            current.status = 'complete';
          }
          if (this.currentApproval && (!this.currentApproval.sessionId || this.currentApproval.sessionId === sid)) {
            this.currentApproval = null;
          }
          if (this.currentClarify && (!this.currentClarify.sessionId || this.currentClarify.sessionId === sid)) {
            this.currentClarify = null;
          }
          this.notify();
          NotificationUtils.notifyTurnComplete(text ? text.slice(0, 100) : '任务已执行完成');
        },
        onSessionInfo: (sid: string, running: boolean, model?: string, title?: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          this.isGenerating = running;
          if (model) {
            this.currentModel = model;
          }
          if (!running) {
            const current = this.getLatestAssistantMessage();
            if (current && current.status === 'streaming') {
              current.status = 'complete';
            }
            if (this.currentApproval && (!this.currentApproval.sessionId || this.currentApproval.sessionId === sid)) {
              this.currentApproval = null;
            }
            if (this.currentClarify && (!this.currentClarify.sessionId || this.currentClarify.sessionId === sid)) {
              this.currentClarify = null;
            }
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
          NotificationUtils.notifyApprovalRequired(req.command, req.toolName);
        },
        onClarifyRequest: (req: ClarifyRequest) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          this.currentClarify = req;
          this.notify();
        },
        onRequestCancel: (sid: string, id: string, method: string) => {
          if (this.sessionAttachGeneration !== currentAttachGen || this.gateway !== activeGateway) return;
          if (this.currentApproval && (this.currentApproval.id === id || this.currentApproval.requestId === id || !id)) {
            this.currentApproval = null;
            this.notify();
          }
          if (this.currentClarify && (this.currentClarify.id === id || this.currentClarify.requestId === id || !id)) {
            this.currentClarify = null;
            this.notify();
          }
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
  public async createAndAttachNewSession(conn: BotConnection, cwd?: string): Promise<string> {
    if (!this.gateway) {
      throw new Error('网关尚未初始化');
    }
    const profile = conn.activeProfile || 'default';
    const res = await this.gateway.createSession(profile, cwd);
    const newSessionId = String(res['session_id'] || res['id'] || '');
    if (!newSessionId) {
      throw new Error('服务端未返回有效 session_id');
    }
    const storedId = String(res['stored_session_id'] || newSessionId);
    this.storedSessionId = storedId;
    this.runtimeSessionId = newSessionId;
    this.gateway.setActiveRuntime(newSessionId);
    this.isConnected = true;
    this.messages = [];
    this.currentApproval = null;
    this.currentClarify = null;
    this.isSubmittingApproval = false;
    this.isSubmittingClarify = false;
    this.notify();
    return storedId;
  }

  public getOrCreateActiveAssistantMessage(): ChatMessage {
    let current = this.getLatestAssistantMessage();
    if (!current || current.status === 'complete') {
      current = {
        id: `msg_ast_${Date.now()}`,
        role: 'assistant',
        content: '',
        reasoning: '',
        toolCalls: [],
        status: 'streaming',
        createdAt: Date.now()
      };
      this.messages.push(current);
    }
    return current;
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
   * 发送聊天文本 (严格校验真实 runtimeSessionId 与连接状态，支持 Hermes Gateway 与 Legacy SSE)
   */
  public async sendMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) {
      return;
    }

    // 针对 Legacy WebUI 走 startChatTurn + connectSSEStream
    if (this.isLegacyMode) {
      if (!this.storedSessionId) {
        this.toast('未选择有效会话');
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

      const assistantMsg: ChatMessage = {
        id: `msg_ast_${Date.now()}`,
        role: 'assistant',
        content: '',
        status: 'streaming',
        createdAt: Date.now()
      };
      this.messages.push(assistantMsg);
      this.notify();

      try {
        const turn = await LegacySSEClient.startChatTurn(
          this.baseUrl,
          this.storedSessionId,
          trimmed,
          this.token,
          this.cookies
        );
        if (!turn || !turn.streamId) {
          throw new Error('Legacy WebUI 未返回有效 streamId');
        }
        this.activeLegacyStreamId = turn.streamId;
        this.activeLegacyStreamHandle = LegacySSEClient.connectSSEStream(
          this.baseUrl,
          turn.streamId,
          {
            onEvent: (ev) => {
              if (ev.data) {
                try {
                  const dataObj = JSON.parse(ev.data) as Record<string, Object>;
                  if (typeof dataObj['chunk'] === 'string') {
                    assistantMsg.content += dataObj['chunk'] as string;
                  } else if (typeof dataObj['content'] === 'string') {
                    assistantMsg.content += dataObj['content'] as string;
                  } else if (typeof dataObj['text'] === 'string') {
                    assistantMsg.content += dataObj['text'] as string;
                  }
                } catch (_e) {
                  assistantMsg.content += ev.data;
                }
              }
              this.notify();
            },
            onError: (err) => {
              this.isGenerating = false;
              assistantMsg.status = 'error';
              assistantMsg.errorMessage = err;
              this.toast(err);
              this.notify();
            },
            onClose: () => {
              this.isGenerating = false;
              assistantMsg.status = 'complete';
              this.activeLegacyStreamHandle = null;
              this.activeLegacyStreamId = '';
              this.notify();
              NotificationUtils.notifyTurnComplete(assistantMsg.content.slice(0, 100) || '任务已完成');
            }
          },
          this.token,
          this.cookies
        );
      } catch (err) {
        this.isGenerating = false;
        assistantMsg.status = 'error';
        assistantMsg.errorMessage = String(err);
        this.toast(`发送失败: ${err}`);
        this.notify();
      }
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
   * 中断停止生成 (真实发送 session.interrupt 或 Legacy chatCancel)
   */
  public async stopGenerating(): Promise<void> {
    if (this.isLegacyMode) {
      if (this.activeLegacyStreamId) {
        LegacySSEClient.cancelChatTurn(
          this.baseUrl,
          this.activeLegacyStreamId,
          this.token,
          this.cookies
        );
      }
      if (this.activeLegacyStreamHandle) {
        this.activeLegacyStreamHandle.cancel();
        this.activeLegacyStreamHandle = null;
      }
      this.isGenerating = false;
      const cur = this.getLatestAssistantMessage();
      if (cur && cur.status === 'streaming') {
        cur.status = 'complete';
      }
      this.notify();
      return;
    }

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
   * 提交审批决定 (严格契约：使用内部 requestId，传递 'once' | 'session' | 'always' | 'deny'，失败保留重试)
   */
  public async submitApproval(choice: string): Promise<void> {
    if (!this.gateway || !this.currentApproval || this.isSubmittingApproval) {
      return;
    }
    const currentAttachGen = this.sessionAttachGeneration;
    const activeGateway = this.gateway;
    const req = this.currentApproval;
    const targetSessionId = req.sessionId || this.runtimeSessionId;
    const targetRequestId = req.requestId || req.id;

    this.isSubmittingApproval = true;
    this.notify();

    try {
      await this.gateway.respondApproval(targetSessionId, targetRequestId, choice);
      if (this.sessionAttachGeneration === currentAttachGen && this.gateway === activeGateway) {
        // 严格比对请求 ID，防止异步返回时冲掉在此期间到达的后续审批
        if (this.currentApproval && (this.currentApproval.requestId === targetRequestId || this.currentApproval.id === targetRequestId)) {
          this.currentApproval = null;
        }
      }
    } catch (e) {
      if (this.sessionAttachGeneration === currentAttachGen && this.gateway === activeGateway) {
        this.toast(`审批提交失败，请重试: ${e}`);
      }
    } finally {
      if (this.sessionAttachGeneration === currentAttachGen && this.gateway === activeGateway) {
        this.isSubmittingApproval = false;
        this.notify();
      }
    }
  }

  /**
   * 提交澄清回答 (可恢复，失败不吞错)
   */
  public async submitClarify(answer: string): Promise<void> {
    if (!this.gateway || !this.currentClarify || this.isSubmittingClarify) {
      return;
    }
    const currentAttachGen = this.sessionAttachGeneration;
    const activeGateway = this.gateway;
    const req = this.currentClarify;
    const targetId = req.id || req.requestId;

    this.isSubmittingClarify = true;
    this.notify();

    try {
      await this.gateway.answerClarify(req.id, answer);
      if (this.sessionAttachGeneration === currentAttachGen && this.gateway === activeGateway) {
        if (this.currentClarify && (this.currentClarify.id === targetId || this.currentClarify.requestId === targetId)) {
          this.currentClarify = null;
        }
      }
    } catch (e) {
      if (this.sessionAttachGeneration === currentAttachGen && this.gateway === activeGateway) {
        this.toast(`澄清答复提交失败，请重试: ${e}`);
      }
    } finally {
      if (this.sessionAttachGeneration === currentAttachGen && this.gateway === activeGateway) {
        this.isSubmittingClarify = false;
        this.notify();
      }
    }
  }

  /**
   * 真实切换模型并向服务端写回配置 (config.set)
   * 支持指定 providerId，并更新当前会话状态
   */
  public async switchModel(modelId: string, providerId?: string): Promise<void> {
    if (!this.gateway || !this.runtimeSessionId) {
      this.toast('当前无活跃会话，无法配置模型');
      return;
    }
    const oldModel = this.currentModel;
    const oldProvider = this.currentModelProvider;
    try {
      let targetProvider = providerId;
      if (!targetProvider && this.modelCatalog) {
        for (let i = 0; i < this.modelCatalog.groups.length; i++) {
          const g = this.modelCatalog.groups[i];
          for (let j = 0; j < g.models.length; j++) {
            if (g.models[j].id === modelId) {
              targetProvider = g.models[j].providerId;
              break;
            }
          }
          if (targetProvider) {
            break;
          }
        }
      }
      await this.gateway.setModelConfig(this.runtimeSessionId, this.currentProfile, modelId, targetProvider, false);
      this.currentModel = modelId;
      if (targetProvider) {
        this.currentModelProvider = targetProvider;
      }
      this.toast(`模型已切换为: ${modelId}${targetProvider ? ' (' + targetProvider + ')' : ''}`);
      this.notify();
    } catch (e) {
      this.currentModel = oldModel;
      this.currentModelProvider = oldProvider;
      this.toast(`切换模型失败: ${e}`);
      this.notify();
    }
  }

  /**
   * 设置当前会话的推理强度 (config.set reasoning)
   */
  public async switchReasoningEffort(effort: string): Promise<void> {
    if (!this.gateway || !this.runtimeSessionId) {
      this.toast('当前无活跃会话，无法配置推理参数');
      return;
    }
    const oldEffort = this.currentReasoningEffort;
    try {
      await this.gateway.setReasoningConfig(this.runtimeSessionId, this.currentProfile, effort);
      this.currentReasoningEffort = effort;
      this.toast(`推理强度已更新为: ${effort}`);
      this.notify();
    } catch (e) {
      this.currentReasoningEffort = oldEffort;
      this.toast(`配置推理参数失败: ${e}`);
      this.notify();
    }
  }

  /**
   * 刷新模型列表及结构化目录 (具备严格的 server/profile/session 代次隔离)
   */
  public async refreshModels(): Promise<void> {
    if (!this.gateway || !this.runtimeSessionId) {
      return;
    }
    const currentGen = ++this.modelFetchGeneration;
    const currentSid = this.runtimeSessionId;
    const currentProf = this.currentProfile;
    try {
      const catalog = await this.gateway.getModelCatalog(currentSid, currentProf);
      // 拦截代次乱序与跨会话/Profile响应
      if (this.modelFetchGeneration !== currentGen || this.runtimeSessionId !== currentSid || this.currentProfile !== currentProf) {
        return;
      }
      this.modelCatalog = catalog;
      this.availableModelGroups = catalog.groups;
      if (catalog.activeModel) {
        this.currentModel = catalog.activeModel.id;
        this.currentModelProvider = catalog.activeModel.providerId;
      }
      // 同步平铺列表供旧组件兼容
      const flatList: ModelOption[] = [];
      for (let i = 0; i < catalog.groups.length; i++) {
        const g = catalog.groups[i];
        for (let j = 0; j < g.models.length; j++) {
          const m = g.models[j];
          flatList.push({
            id: m.id,
            name: m.displayName,
            provider: m.providerId,
            isDefault: m.isDefault
          });
        }
      }
      this.availableModels = flatList;
      this.notify();
    } catch (_e) {
      // ignore
    }
  }

  /**
   * 切换 Profile 并严格隔离状态：
   * 升级代次阻止旧异步响应、清空当前消息与模型目录
   */
  public switchProfile(newProfile: string): void {
    if (this.currentProfile === newProfile) {
      return;
    }
    this.modelFetchGeneration++;
    this.sessionAttachGeneration++;
    this.currentProfile = newProfile;
    this.runtimeSessionId = '';
    this.storedSessionId = '';
    this.messages = [];
    this.currentModel = '';
    this.currentModelProvider = '';
    this.currentReasoningEffort = 'none';
    this.modelCatalog = null;
    this.availableModelGroups = [];
    this.availableModels = [];
    this.notify();
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
    if (this.activeLegacyStreamHandle) {
      this.activeLegacyStreamHandle.cancel();
      this.activeLegacyStreamHandle = null;
    }
    this.activeLegacyStreamId = '';
    this.isLegacyMode = false;
    if (this.gateway) {
      this.gateway.disconnect();
      this.gateway = null;
    }
    this.isConnected = false;
    this.isGenerating = false;
    this.runtimeSessionId = '';
    this.currentApproval = null;
    this.currentClarify = null;
    this.isSubmittingApproval = false;
    this.isSubmittingClarify = false;
  }
}
