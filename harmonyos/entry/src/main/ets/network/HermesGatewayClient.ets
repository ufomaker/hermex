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

export interface ClientCapabilities {
  server_requests: boolean;
}

export interface ClarifyAnswerBody {
  answer: string;
}

export interface ClarifyResultEnvelope {
  answer: string;
}

/**
 * Hermes Gateway WebSocket 客户端
 * 基于 @ohos.net.webSocket 实现实时会话、流式交互、RPC调用与控制
 */
export class HermesGatewayClient {
  private ws: webSocket.WebSocket | null = null;
  private callbacks: GatewayEventCallbacks = {};
  private nextRpcId: number = 10;
  private heartbeatSeq: number = 0;
  private heartbeatTimer: number = -1;
  private isConnected: boolean = false;
  private replayEpoch: string = '';
  private pendingCalls: Map<number, (res: Record<string, Object>) => void> = new Map();

  constructor(callbacks: GatewayEventCallbacks) {
    this.callbacks = callbacks;
  }

  /**
   * 建立 Gateway 连接
   * @param baseUrl HTTP 或 HTTPS 服务器根地址
   * @param ticket 通过 /api/auth/ws-ticket 换取的单次 ticket
   */
  public async connect(baseUrl: string, ticket: string): Promise<void> {
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

      let hasHandshaked = false;

      this.ws.on('open', (err, value) => {
        if (err) {
          if (!hasHandshaked) {
            reject(new Error(`WebSocket open error: ${JSON.stringify(err)}`));
          }
          return;
        }
      });

      this.ws.on('message', (err, value) => {
        if (err || !value) {
          return;
        }
        const text = typeof value === 'string' ? value : '';
        if (!text) {
          return;
        }
        try {
          const frame = JSON.parse(text) as Record<string, Object>;
          this.handleFrame(frame, () => {
            if (!hasHandshaked) {
              hasHandshaked = true;
              this.isConnected = true;
              this.startHeartbeat();
              if (this.callbacks.onConnected) {
                this.callbacks.onConnected();
              }
              resolve();
            }
          });
        } catch (e) {
          // ignore parse error
        }
      });

      this.ws.on('close', (err, value) => {
        this.stopHeartbeat();
        this.isConnected = false;
        if (this.callbacks.onDisconnected) {
          this.callbacks.onDisconnected(value ? String(value.reason || '') : 'Connection closed');
        }
      });

      this.ws.on('error', (err) => {
        this.stopHeartbeat();
        this.isConnected = false;
        if (!hasHandshaked) {
          reject(new Error(`WebSocket connection failed: ${JSON.stringify(err)}`));
        } else if (this.callbacks.onDisconnected) {
          this.callbacks.onDisconnected(JSON.stringify(err));
        }
      });

      const connectHeaders: Record<string, string> = {
        'Sec-WebSocket-Protocol': subprotocol
      };

      this.ws.connect(wsUrl, {
        header: connectHeaders
      }, (err, value) => {
        if (err) {
          reject(new Error(`Failed to connect ws: ${JSON.stringify(err)}`));
        }
      });
    });
  }

  public disconnect(): void {
    this.stopHeartbeat();
    this.isConnected = false;
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
    this.pendingCalls.clear();
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (!this.isConnected || !this.ws) {
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

  private handleFrame(frame: Record<string, Object>, onHandshakeReady: () => void): void {
    const method = String(frame['method'] || '');
    const id = frame['id'];

    // 1. 握手首帧事件 gateway.ready
    if (method === 'event') {
      const params = (frame['params'] as Record<string, Object>) || {};
      const type = String(params['type'] || '');
      const payload = (params['payload'] as Record<string, Object>) || {};

      if (type === 'gateway.ready') {
        this.replayEpoch = String(payload['replay_epoch'] || '');
        // 发送能力声明 client.capabilities (HermesCall.swift:293)
        this.sendCapabilities();
        onHandshakeReady();
        return;
      }

      this.dispatchRuntimeEvent(type, params, payload);
      return;
    }

    // 2. 服务端主动推送的 Request (具备 string id 与 method，如 approval.request, clarify.request)
    if (typeof id === 'string' && method) {
      this.handleServerRequest(id, method, (frame['params'] as Record<string, Object>) || {});
      return;
    }

    // 3. 客户端 RPC 响应 (数字 id)
    if (typeof id === 'number') {
      const callback = this.pendingCalls.get(id);
      if (callback) {
        this.pendingCalls.delete(id);
        callback(frame);
      }
    }
  }

  private sendCapabilities(): void {
    if (!this.ws) {
      return;
    }
    const capParams: Record<string, Object> = {
      'server_requests': true
    };
    const capFrame: JsonRpcPayload = {
      jsonrpc: '2.0',
      id: 1,
      method: 'client.capabilities',
      params: capParams
    };
    this.ws.send(JSON.stringify(capFrame), (err, value) => {});
  }

  private dispatchRuntimeEvent(type: string, params: Record<string, Object>, payload: Record<string, Object>): void {
    const sessionId = String(params['session_id'] || payload['session_id'] || '');

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
    if (method === 'approval.request' || method === 'request.approval') {
      if (this.callbacks.onApprovalRequest) {
        const req: ApprovalRequest = {
          id: id,
          sessionId: sessionId,
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
          sessionId: sessionId,
          questionId: String(params['question_id'] || ''),
          question: String(params['question'] || ''),
          options: Array.isArray(params['options']) ? (params['options'] as string[]) : undefined
        };
        this.callbacks.onClarifyRequest(req);
      }
    }
  }

  /**
   * 通用 JSON-RPC 调用发送
   */
  public async call(method: string, params: Record<string, Object>): Promise<Record<string, Object>> {
    if (!this.isConnected || !this.ws) {
      throw new Error('Gateway not connected');
    }
    const id = this.nextRpcId++;
    const frame: JsonRpcPayload = {
      jsonrpc: '2.0',
      id: id,
      method: method,
      params: params
    };

    return new Promise<Record<string, Object>>((resolve, reject) => {
      this.pendingCalls.set(id, (resFrame) => {
        if (resFrame['error']) {
          const errObj = resFrame['error'] as Record<string, Object>;
          reject(new Error(String(errObj['message'] || 'RPC Error')));
          return;
        }
        resolve((resFrame['result'] as Record<string, Object>) || {});
      });

      this.ws?.send(JSON.stringify(frame), (err, value) => {
        if (err) {
          this.pendingCalls.delete(id);
          reject(new Error(`Failed to send RPC: ${JSON.stringify(err)}`));
        }
      });
    });
  }

  // --- 确切方法映射 (严守 HermesCall.swift 契约) ---

  /**
   * 恢复会话：session.resume (HermesCall.swift:284)
   */
  public async resumeSession(sessionId: string, profile: string): Promise<Record<string, Object>> {
    const params: Record<string, Object> = {
      'session_id': sessionId,
      'profile': profile,
      'omit_messages': false
    };
    return this.call('session.resume', params);
  }

  /**
   * 创建新会话：session.create (HermesCall.swift:282)
   */
  public async createSession(profile: string): Promise<Record<string, Object>> {
    const params: Record<string, Object> = {
      'profile': profile
    };
    return this.call('session.create', params);
  }

  /**
   * 发送用户输入：prompt.submit (HermesCall.swift:295, 411)
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
   * 严格核实：方法为 session.interrupt，不是 prompt.interrupt
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
   * 锁定问题选择：clarify.lock (HermesCall.swift:304, 427)
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
   * 获取模型选项：model.options (HermesCall.swift:306, 434)
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
