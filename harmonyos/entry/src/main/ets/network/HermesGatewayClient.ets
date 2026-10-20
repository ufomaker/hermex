import webSocket from '@ohos.net.webSocket';
import { ApprovalRequest, ClarifyRequest, ModelOption } from '../model/Approval';
import { ToolCallItem } from '../model/ChatMessage';

export interface GatewayEventCallbacks {
  onConnected?: () => void;
  onDisconnected?: (reason: string) => void;
  onMessageStart?: (sessionId: string) => void;
  onMessageDelta?: (sessionId: string, delta: string) => void;
  onReasoningDelta?: (sessionId: string, delta: string) => void;
  onToolStart?: (sessionId: string, tool: ToolCallItem) => void;
  onToolComplete?: (sessionId: string, tool: ToolCallItem) => void;
  onMessageComplete?: (sessionId: string) => void;
  onSessionInfo?: (sessionId: string, running: boolean, model?: string, title?: string) => void;
  onError?: (sessionId: string, error: string) => void;
  onApprovalRequest?: (request: ApprovalRequest) => void;
  onClarifyRequest?: (request: ClarifyRequest) => void;
}

export interface JsonRpcPayload {
  jsonrpc: string;
  id: number | string;
  method: string;
  params: Record<string, Object>;
}

export interface WebSocketCloseOptions {
  code: number;
  reason: string;
}

interface PendingCall {
  method: string;
  timer: number;
  resolve: (res: Record<string, Object>) => void;
  reject: (err: Error) => void;
}

/**
 * Hermes Gateway WebSocket 客户端
 * 基于 @ohos.net.webSocket 实现实时会话、流式交互、RPC调用与控制
 * 包含连接代次管理、RPC超时与清理机制、心跳静默检测与严格会话事件隔离
 */
export class HermesGatewayClient {
  private ws: webSocket.WebSocket | null = null;
  private callbacks: GatewayEventCallbacks = {};
  private nextRpcId: number = 10;
  private heartbeatSeq: number = 0;
  private heartbeatTimer: number = -1;
  private isConnected: boolean = false;
  private replayEpoch: string = '';
  private pendingCalls: Map<number, PendingCall> = new Map();
  private lastActivityTimestamp: number = 0;
  private activeRuntimeId: string = '';
  private generation: number = 0;

  constructor(callbacks: GatewayEventCallbacks) {
    this.callbacks = callbacks;
  }

  public setActiveRuntime(runtimeId: string): void {
    this.activeRuntimeId = runtimeId;
  }

  public getActiveRuntime(): string {
    return this.activeRuntimeId;
  }

  public getReplayEpoch(): string {
    return this.replayEpoch;
  }

  /**
   * 建立 Gateway 连接
   * @param baseUrl HTTP 或 HTTPS 服务器根地址
   * @param ticket 通过 /api/auth/ws-ticket 换取的单次 ticket
   */
  public async connect(baseUrl: string, ticket: string): Promise<void> {
    this.generation += 1;
    const currentGen = this.generation;
    this.disconnect();

    let cleanUrl = baseUrl.trim();
    if (cleanUrl.endsWith('/')) {
      cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1);
    }

    let wsUrl = cleanUrl.replace(/^http:\/\//, 'ws://').replace(/^https:\/\//, 'wss://');
    wsUrl = `${wsUrl}/api/ws`;

    const subprotocol = `hermes-gateway-v1, hermes-gateway-ticket.${ticket}`;
    this.ws = webSocket.createWebSocket();

    return new Promise<void>((resolve, reject) => {
      if (!this.ws) {
        reject(new Error('WebSocket client creation failed'));
        return;
      }

      let isSettled = false;

      this.ws.on('open', (err, value) => {
        if (err && !isSettled) {
          isSettled = true;
          reject(new Error(`WebSocket open error: ${JSON.stringify(err)}`));
          return;
        }
        this.lastActivityTimestamp = Date.now();
      });

      this.ws.on('message', (err, value) => {
        if (err || !value) {
          return;
        }
        if (this.generation !== currentGen) {
          return; // 丢弃过期连接代次的报文
        }
        this.lastActivityTimestamp = Date.now();
        const text = typeof value === 'string' ? value : '';
        if (!text) {
          return;
        }
        try {
          const frame = JSON.parse(text) as Record<string, Object>;
          this.handleFrame(frame, async () => {
            // 握手就绪：收到 gateway.ready 后必须完成 client.capabilities 协商回执
            try {
              await this.call('client.capabilities', { 'server_requests': true });
              if (!isSettled && this.generation === currentGen) {
                isSettled = true;
                this.isConnected = true;
                this.startHeartbeat(currentGen);
                if (this.callbacks.onConnected) {
                  this.callbacks.onConnected();
                }
                resolve();
              }
            } catch (capErr) {
              if (!isSettled) {
                isSettled = true;
                reject(new Error(`Capabilities handshake failed: ${capErr}`));
              }
            }
          });
        } catch (e) {
          // ignore malformed frame
        }
      });

      this.ws.on('close', (err, value) => {
        if (this.generation !== currentGen) {
          return;
        }
        this.cleanupState('Connection closed by remote');
        if (!isSettled) {
          isSettled = true;
          reject(new Error('Connection closed before handshake completion'));
        }
      });

      this.ws.on('error', (err) => {
        if (this.generation !== currentGen) {
          return;
        }
        this.cleanupState(`Connection error: ${JSON.stringify(err)}`);
        if (!isSettled) {
          isSettled = true;
          reject(new Error(`WebSocket error: ${JSON.stringify(err)}`));
        }
      });

      const connectHeaders: Record<string, string> = {
        'Sec-WebSocket-Protocol': subprotocol
      };

      this.ws.connect(wsUrl, {
        header: connectHeaders
      }, (err, value) => {
        if (err && !isSettled) {
          isSettled = true;
          reject(new Error(`Failed to connect ws: ${JSON.stringify(err)}`));
        }
      });
    });
  }

  public disconnect(): void {
    this.generation += 1;
    this.cleanupState('Client explicitly disconnected');
    if (this.ws) {
      try {
        const closeOpt: WebSocketCloseOptions = {
          code: 1000,
          reason: 'Client disconnect'
        };
        this.ws.close(closeOpt);
      } catch (e) {
        // ignore
      }
      this.ws = null;
    }
  }

  private cleanupState(reason: string): void {
    this.stopHeartbeat();
    this.isConnected = false;
    // 清理并拒绝所有等待中的 RPC，杜绝内存泄漏与挂起
    this.pendingCalls.forEach((call) => {
      clearTimeout(call.timer);
      call.reject(new Error(`RPC canceled: ${reason}`));
    });
    this.pendingCalls.clear();
    if (this.callbacks.onDisconnected) {
      this.callbacks.onDisconnected(reason);
    }
  }

  private startHeartbeat(gen: number): void {
    this.stopHeartbeat();
    this.lastActivityTimestamp = Date.now();

    this.heartbeatTimer = setInterval(() => {
      if (!this.isConnected || !this.ws || this.generation !== gen) {
        return;
      }

      // 静默超时检查 (45秒无任何上行或下行报文)
      if (Date.now() - this.lastActivityTimestamp > 45000) {
        this.cleanupState('Heartbeat silent timeout (45s without frame)');
        if (this.ws) {
          try {
            this.ws.close({ code: 1006, reason: 'Silent timeout' });
          } catch (e) {}
        }
        return;
      }

      this.heartbeatSeq += 1;
      const pingParams: Record<string, Object> = {};
      const pingFrame: JsonRpcPayload = {
        jsonrpc: '2.0',
        id: `heartbeat-${this.heartbeatSeq}`,
        method: 'gateway.ping',
        params: pingParams
      };
      this.ws.send(JSON.stringify(pingFrame), (err, value) => {});
    }, 15000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  private handleFrame(frame: Record<string, Object>, onGatewayReady: () => void): void {
    const method = String(frame['method'] || '');
    const id = frame['id'];

    // 1. 事件帧处理 (method === 'event')
    if (method === 'event') {
      const params = (frame['params'] as Record<string, Object>) || {};
      const type = String(params['type'] || '');
      const payload = (params['payload'] as Record<string, Object>) || {};

      if (type === 'gateway.ready') {
        this.replayEpoch = String(payload['replay_epoch'] || '');
        onGatewayReady();
        return;
      }

      this.dispatchRuntimeEvent(type, params, payload);
      return;
    }

    // 2. 服务端请求处理 (包含 string id 与 method)
    if (typeof id === 'string' && method) {
      this.handleServerRequest(id, method, (frame['params'] as Record<string, Object>) || {});
      return;
    }

    // 3. 客户端 RPC 响应处理 (包含数字 id)
    if (typeof id === 'number') {
      const call = this.pendingCalls.get(id);
      if (call) {
        clearTimeout(call.timer);
        this.pendingCalls.delete(id);
        if (frame['error']) {
          const errObj = frame['error'] as Record<string, Object>;
          call.reject(new Error(String(errObj['message'] || 'RPC Error')));
        } else {
          call.resolve((frame['result'] as Record<string, Object>) || {});
        }
      }
    }
  }

  private dispatchRuntimeEvent(type: string, params: Record<string, Object>, payload: Record<string, Object>): void {
    const sessionId = String(params['session_id'] || payload['session_id'] || '');

    // 严格会话隔离：只有当当前活跃会话与事件所属会话一致时才分发，杜绝跨会话串流
    if (this.activeRuntimeId && sessionId && sessionId !== this.activeRuntimeId) {
      return;
    }

    switch (type) {
      case 'message.start':
        if (this.callbacks.onMessageStart) {
          this.callbacks.onMessageStart(sessionId);
        }
        break;
      case 'message.delta':
        const delta = String(payload['text'] || '');
        if (delta && this.callbacks.onMessageDelta) {
          this.callbacks.onMessageDelta(sessionId, delta);
        }
        break;
      case 'message.interim':
        const interim = String(payload['text'] || '');
        if (interim && this.callbacks.onMessageDelta) {
          this.callbacks.onMessageDelta(sessionId, interim);
        }
        break;
      case 'reasoning.delta':
        const reasoning = String(payload['text'] || '');
        if (reasoning && this.callbacks.onReasoningDelta) {
          this.callbacks.onReasoningDelta(sessionId, reasoning);
        }
        break;
      case 'tool.start':
        if (this.callbacks.onToolStart) {
          const tool: ToolCallItem = {
            id: String(payload['id'] || payload['tool_id'] || ''),
            name: String(payload['name'] || payload['tool'] || 'tool'),
            input: payload['input'] ? JSON.stringify(payload['input']) : undefined,
            status: 'running'
          };
          this.callbacks.onToolStart(sessionId, tool);
        }
        break;
      case 'tool.complete':
        if (this.callbacks.onToolComplete) {
          const tool: ToolCallItem = {
            id: String(payload['id'] || payload['tool_id'] || ''),
            name: String(payload['name'] || payload['tool'] || 'tool'),
            output: payload['output'] ? String(payload['output']) : undefined,
            status: 'completed'
          };
          this.callbacks.onToolComplete(sessionId, tool);
        }
        break;
      case 'session.info':
        const running = Boolean(payload['running']);
        const model = payload['model'] ? String(payload['model']) : undefined;
        const title = payload['title'] ? String(payload['title']) : undefined;
        if (this.callbacks.onSessionInfo) {
          this.callbacks.onSessionInfo(sessionId, running, model, title);
        }
        break;
      case 'message.complete':
        if (this.callbacks.onMessageComplete) {
          this.callbacks.onMessageComplete(sessionId);
        }
        break;
      case 'error':
        const errMessage = String(payload['message'] || '未知服务错误');
        if (this.callbacks.onError) {
          this.callbacks.onError(sessionId, errMessage);
        }
        break;
      default:
        break;
    }
  }

  private handleServerRequest(id: string, method: string, params: Record<string, Object>): void {
    const sessionId = String(params['session_id'] || '');

    // 审批与澄清请求会话归属校验
    if (this.activeRuntimeId && sessionId && sessionId !== this.activeRuntimeId) {
      return;
    }

    if (method === 'approval.request' || method === 'request.approval') {
      if (this.callbacks.onApprovalRequest) {
        const req: ApprovalRequest = {
          id: id,
          sessionId: sessionId || this.activeRuntimeId,
          toolName: params['tool_name'] ? String(params['tool_name']) : undefined,
          description: params['description'] ? String(params['description']) : undefined,
          command: params['command'] ? String(params['command']) : undefined,
          choices: Array.isArray(params['choices']) ? (params['choices'] as string[]) : ['approve', 'reject']
        };
        this.callbacks.onApprovalRequest(req);
      }
    } else if (method === 'clarify.request' || method === 'request.clarify') {
      if (this.callbacks.onClarifyRequest) {
        const req: ClarifyRequest = {
          id: id,
          sessionId: sessionId || this.activeRuntimeId,
          questionId: String(params['question_id'] || ''),
          question: String(params['question'] || ''),
          options: Array.isArray(params['options']) ? (params['options'] as string[]) : undefined
        };
        this.callbacks.onClarifyRequest(req);
      }
    }
  }

  /**
   * 通用 JSON-RPC 发送方法 (带 30 秒超时与自动清理)
   */
  public async call(method: string, params: Record<string, Object>, timeoutMs: number = 30000): Promise<Record<string, Object>> {
    if (!this.isConnected && method !== 'client.capabilities') {
      throw new Error('Gateway not connected');
    }
    if (!this.ws) {
      throw new Error('WebSocket is null');
    }

    const id = this.nextRpcId++;
    const frame: JsonRpcPayload = {
      jsonrpc: '2.0',
      id: id,
      method: method,
      params: params
    };

    return new Promise<Record<string, Object>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingCalls.delete(id);
        reject(new Error(`RPC timeout (${timeoutMs}ms) for method: ${method}`));
      }, timeoutMs);

      const entry: PendingCall = {
        method: method,
        timer: timer,
        resolve: resolve,
        reject: reject
      };
      this.pendingCalls.set(id, entry);

      this.ws?.send(JSON.stringify(frame), (err, value) => {
        if (err) {
          clearTimeout(timer);
          this.pendingCalls.delete(id);
          reject(new Error(`Failed to send RPC ${method}: ${JSON.stringify(err)}`));
        }
      });
    });
  }

  // --- 确切契约方法映射 ---

  /**
   * 恢复会话：session.resume (HermesCall.swift:284)
   * 返回包含真实 runtime session_id 的对象
   */
  public async resumeSession(sessionId: string, profile: string): Promise<Record<string, Object>> {
    const params: Record<string, Object> = {
      'session_id': sessionId,
      'profile': profile,
      'omit_messages': false
    };
    const res = await this.call('session.resume', params);
    const runtime = String(res['session_id'] || sessionId);
    this.setActiveRuntime(runtime);
    return res;
  }

  /**
   * 创建新会话：session.create (HermesCall.swift:282)
   * 真实在服务端创建并获取服务端返回的 session_id
   */
  public async createSession(profile: string): Promise<Record<string, Object>> {
    const params: Record<string, Object> = {
      'profile': profile
    };
    const res = await this.call('session.create', params);
    const runtime = String(res['session_id'] || res['id'] || '');
    if (runtime) {
      this.setActiveRuntime(runtime);
    }
    return res;
  }

  /**
   * 提交提示词：prompt.submit (HermesCall.swift:295, 411)
   */
  public async submitPrompt(sessionId: string, text: string): Promise<Record<string, Object>> {
    const params: Record<string, Object> = {
      'session_id': sessionId,
      'text': text,
      'queued': true
    };
    return this.call('prompt.submit', params);
  }

  /**
   * 中断停止生成：session.interrupt (HermesCall.swift:298, 419)
   */
  public async interruptSession(sessionId: string): Promise<Record<string, Object>> {
    const params: Record<string, Object> = {
      'session_id': sessionId
    };
    return this.call('session.interrupt', params);
  }

  /**
   * 响应审批：approval.respond (HermesCall.swift:302, 422)
   */
  public async respondApproval(sessionId: string, requestId: string, choice: string): Promise<Record<string, Object>> {
    const params: Record<string, Object> = {
      'session_id': sessionId,
      'request_id': requestId,
      'choice': choice
    };
    return this.call('approval.respond', params);
  }

  /**
   * 答复澄清问题：request.answer (HermesCall.swift:303, 424-426)
   */
  public async answerClarify(requestId: string, answer: string): Promise<Record<string, Object>> {
    const answerResult: Record<string, Object> = {
      'answer': answer
    };
    const params: Record<string, Object> = {
      'id': requestId,
      'result': answerResult
    };
    return this.call('request.answer', params);
  }

  /**
   * 锁定澄清问题：clarify.lock (HermesCall.swift:304, 427)
   */
  public async lockClarify(requestId: string, questionId: string, answer: string): Promise<Record<string, Object>> {
    const params: Record<string, Object> = {
      'request_id': requestId,
      'question_id': questionId,
      'answer': answer
    };
    return this.call('clarify.lock', params);
  }

  /**
   * 真实切换会话配置（如模型）：config.set (HermesCall.swift:307, 445)
   */
  public async setModelConfig(sessionId: string, profile: string, modelName: string): Promise<Record<string, Object>> {
    const params: Record<string, Object> = {
      'session_id': sessionId,
      'profile': profile,
      'scope': 'session',
      'key': 'model',
      'value': `${modelName} --session`,
      'confirm_expensive_model': false
    };
    return this.call('config.set', params);
  }

  /**
   * 获取模型列表：model.options (HermesCall.swift:306, 434)
   */
  public async getModelOptions(sessionId: string, profile: string): Promise<ModelOption[]> {
    try {
      const params: Record<string, Object> = {
        'session_id': sessionId,
        'profile': profile
      };
      const res = await this.call('model.options', params);
      const rawModels = Array.isArray(res['models']) ? (res['models'] as Array<Record<string, Object>>) : [];
      const list: ModelOption[] = [];
      for (let i = 0; i < rawModels.length; i++) {
        const m = rawModels[i];
        const opt: ModelOption = {
          id: String(m['id'] || m['name'] || ''),
          name: String(m['name'] || m['id'] || ''),
          provider: m['provider'] ? String(m['provider']) : undefined,
          isDefault: Boolean(m['is_default'])
        };
        list.push(opt);
      }
      return list;
    } catch (e) {
      return [];
    }
  }
}
