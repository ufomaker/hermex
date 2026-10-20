/**
 * Hermes 核心协议与状态机引擎 (生产级共享核心)
 * 纯 TypeScript 实现，完全兼容 ArkTS 编译约束与 Node 自动化测试驱动
 */

export interface ToolItem {
  id: string;
  name: string;
  input?: string;
  output?: string;
  status: 'running' | 'completed' | 'failed';
}

export interface StreamState {
  currentContent: string;
  currentReasoning: string;
  toolCalls: ToolItem[];
  isGenerating: boolean;
  isCompleted: boolean;
  errorMessage?: string;
}

export interface PendingRpc {
  method: string;
  timer: any;
  resolve: (res: Record<string, any>) => void;
  reject: (err: Error) => void;
}

export class CookieJar {
  private cookies: Map<string, string> = new Map();

  public parseAndStore(headerObj: any): void {
    if (!headerObj) return;
    const raw = headerObj['set-cookie'] || headerObj['Set-Cookie'];
    if (!raw) return;

    const list = Array.isArray(raw) ? raw : [String(raw)];
    for (let i = 0; i < list.length; i++) {
      const line = String(list[i]).split(';')[0].trim();
      const eqIdx = line.indexOf('=');
      if (eqIdx > 0) {
        const k = line.substring(0, eqIdx).trim();
        const v = line.substring(eqIdx + 1).trim();
        this.cookies.set(k, v);
      }
    }
  }

  public getCookieHeader(): string {
    const parts: string[] = [];
    this.cookies.forEach((v, k) => {
      parts.push(`${k}=${v}`);
    });
    return parts.join('; ');
  }

  public clear(): void {
    this.cookies.clear();
  }
}

export class ProtocolSessionCoordinator {
  public activeRuntimeId: string = '';
  public streamState: StreamState = {
    currentContent: '',
    currentReasoning: '',
    toolCalls: [],
    isGenerating: false,
    isCompleted: false
  };

  public pendingApproval: any = null;
  public pendingClarify: any = null;

  public resetStream(): void {
    this.streamState = {
      currentContent: '',
      currentReasoning: '',
      toolCalls: [],
      isGenerating: false,
      isCompleted: false
    };
  }

  /**
   * 分发并聚合运行时事件流，严格校验会话所属
   */
  public handleEvent(type: string, sessionId: string, payload: any): boolean {
    if (this.activeRuntimeId && sessionId && sessionId !== this.activeRuntimeId) {
      return false; // 严格会话隔离：抛弃非当前会话的报文
    }

    switch (type) {
      case 'message.start':
        this.streamState.isGenerating = true;
        this.streamState.isCompleted = false;
        break;
      case 'message.delta':
        this.streamState.currentContent += String(payload.text || '');
        break;
      case 'reasoning.delta':
        this.streamState.currentReasoning += String(payload.text || '');
        break;
      case 'tool.start':
        this.streamState.toolCalls.push({
          id: String(payload.id || payload.tool_id || ''),
          name: String(payload.name || payload.tool || 'tool'),
          input: payload.input ? JSON.stringify(payload.input) : undefined,
          status: 'running'
        });
        break;
      case 'tool.complete':
        const tid = String(payload.id || payload.tool_id || '');
        const found = this.streamState.toolCalls.find(t => t.id === tid || t.name === payload.name);
        if (found) {
          found.output = payload.output ? String(payload.output) : undefined;
          found.status = 'completed';
        }
        break;
      case 'message.complete':
        this.streamState.isGenerating = false;
        this.streamState.isCompleted = true;
        break;
      case 'error':
        this.streamState.isGenerating = false;
        this.streamState.errorMessage = String(payload.message || 'Error');
        break;
      default:
        break;
    }
    return true;
  }

  public handleServerRequest(id: string, method: string, params: any): void {
    const sid = String(params.session_id || '');
    if (this.activeRuntimeId && sid && sid !== this.activeRuntimeId) {
      return;
    }
    if (method === 'approval.request' || method === 'request.approval') {
      this.pendingApproval = {
        id: id,
        sessionId: sid || this.activeRuntimeId,
        toolName: params.tool_name,
        description: params.description,
        command: params.command,
        choices: params.choices || ['approve', 'reject']
      };
    } else if (method === 'clarify.request' || method === 'request.clarify') {
      this.pendingClarify = {
        id: id,
        sessionId: sid || this.activeRuntimeId,
        questionId: params.question_id,
        question: params.question,
        options: params.options
      };
    }
  }
}

export class JsonRpcManager {
  private nextId: number = 10;
  private pendingCalls: Map<number, PendingRpc> = new Map();

  public createRequest(method: string, params: Record<string, any>): { id: number, frame: any } {
    const id = this.nextId++;
    const frame = {
      jsonrpc: '2.0',
      id: id,
      method: method,
      params: params
    };
    return { id, frame };
  }

  public registerPending(
    id: number,
    method: string,
    timeoutMs: number,
    resolve: (res: any) => void,
    reject: (err: Error) => void
  ): void {
    const timer = setTimeout(() => {
      this.pendingCalls.delete(id);
      reject(new Error(`RPC timeout (${timeoutMs}ms) for ${method}`));
    }, timeoutMs);

    this.pendingCalls.set(id, { method, timer, resolve, reject });
  }

  public handleResponse(frame: any): boolean {
    const id = frame.id;
    if (typeof id === 'number' && this.pendingCalls.has(id)) {
      const entry = this.pendingCalls.get(id)!;
      clearTimeout(entry.timer);
      this.pendingCalls.delete(id);
      if (frame.error) {
        entry.reject(new Error(String(frame.error.message || 'RPC Error')));
      } else {
        entry.resolve(frame.result || {});
      }
      return true;
    }
    return false;
  }

  public cancelAll(reason: string): void {
    this.pendingCalls.forEach(call => {
      clearTimeout(call.timer);
      call.reject(new Error(`RPC canceled: ${reason}`));
    });
    this.pendingCalls.clear();
  }

  public getPendingCount(): number {
    return this.pendingCalls.size;
  }
}
