import { ChatMessage, ToolCallItem, MessageRole } from '../model/ChatMessage';

/**
 * 声明的工具调用元数据接口
 */
export interface DeclaredCallMeta {
  id: string;
  name: string;
  arguments?: string;
}

/**
 * 工具输出解析结果接口
 */
export interface ParsedToolResult {
  output: string;
  isFailed: boolean;
}

/**
 * Hermes 历史记录通用归一化解析器
 * 严格对齐上游 HermesTranscriptHistory.swift 与 ChatMessage.swift 规范
 */
export class HermesHistoryNormalizer {

  /**
   * 将服务端 /api/sessions/{id}/messages 返回的原始消息列表归一化为规范的 ChatMessage 列表
   */
  public static normalize(rawMsgs: Array<Record<string, Object>>): ChatMessage[] {
    if (!Array.isArray(rawMsgs) || rawMsgs.length === 0) {
      return [];
    }

    const messages: ChatMessage[] = [];
    // tool_call_id -> DeclaredCallMeta 映射表 (跨轮次与多调用关联)
    const declaredCalls = new Map<string, DeclaredCallMeta>();
    // 当前轮次中已声明但尚未返回结果的工具调用 (tool_call_id -> ToolCallItem，初始 status: 'running')
    const turnDeclaredTools = new Map<string, ToolCallItem>();
    // 当前轮次积累的已完成/待绑定的工具结果与推理内容
    let pendingTools: ToolCallItem[] = [];
    let pendingReasoning: string[] = [];
    // 追踪最后一条 user 消息在 messages 数组中的下标，用于严格约束轮次边界
    let lastUserIndex = -1;

    for (let i = 0; i < rawMsgs.length; i++) {
      const row = rawMsgs[i];
      if (!row || typeof row !== 'object') {
        continue;
      }

      const roleStr = String(row['role'] || '').trim().toLowerCase();
      const displayKind = row['display_kind'] ? String(row['display_kind']) : '';

      // 忽略标记为 hidden 的行
      if (displayKind === 'hidden') {
        continue;
      }

      if (roleStr === 'tool') {
        // --- TOOL 角色处理 ---
        // 绝不将 tool 结果伪装为助手独立气泡，提取输出并关联至对应工具声明
        const toolCallId = row['tool_call_id'] ? String(row['tool_call_id']) : '';
        const fallbackName = row['tool_name'] ? String(row['tool_name']) : '';
        const rawContent = row['content'];
        const parsedResult = HermesHistoryNormalizer.parseToolContent(rawContent);

        // 优先匹配已声明的 running 工具调用并就地更新其 output 与 status
        let matchedToolItem: ToolCallItem | undefined = undefined;
        if (toolCallId && turnDeclaredTools.has(toolCallId)) {
          matchedToolItem = turnDeclaredTools.get(toolCallId);
          turnDeclaredTools.delete(toolCallId);
        }

        if (matchedToolItem) {
          matchedToolItem.output = parsedResult.output;
          matchedToolItem.status = parsedResult.isFailed ? 'failed' : 'completed';
          if (fallbackName && (!matchedToolItem.name || matchedToolItem.name === 'tool')) {
            matchedToolItem.name = fallbackName;
          }
          pendingTools.push(matchedToolItem);
        } else {
          // 未预先声明但直接返回结果的孤儿工具
          const matchedCall = toolCallId ? declaredCalls.get(toolCallId) : undefined;
          const toolName = matchedCall?.name || fallbackName || 'tool';
          const toolInput = matchedCall?.arguments;
          const toolItem: ToolCallItem = {
            id: toolCallId || `tool_call_${row['id'] || i}`,
            name: toolName,
            input: toolInput,
            output: parsedResult.output,
            status: parsedResult.isFailed ? 'failed' : 'completed'
          };
          pendingTools.push(toolItem);
        }
      } else if (roleStr === 'assistant') {
        // --- ASSISTANT 角色处理 ---
        // 1. 提取声明的工具调用，保留 running 状态，不丢弃运行态调用
        if (Array.isArray(row['tool_calls'])) {
          const calls = row['tool_calls'] as Array<Record<string, Object>>;
          for (let j = 0; j < calls.length; j++) {
            const call = calls[j];
            if (!call || typeof call !== 'object') continue;
            const cid = String(call['id'] || call['call_id'] || '');
            if (!cid) continue;

            const fn = (call['function'] && typeof call['function'] === 'object') ? (call['function'] as Record<string, Object>) : null;
            let cname = fn && fn['name'] ? String(fn['name']) : (call['name'] ? String(call['name']) : '');
            if (!cname && call['tool_name']) {
              cname = String(call['tool_name']);
            }
            if (!cname) {
              cname = 'tool';
            }

            let cargs = '';
            if (fn && fn['arguments']) {
              cargs = typeof fn['arguments'] === 'string' ? fn['arguments'] : JSON.stringify(fn['arguments']);
            } else if (call['arguments'] || call['input']) {
              const rawA = call['arguments'] || call['input'];
              cargs = typeof rawA === 'string' ? rawA : JSON.stringify(rawA);
            }

            const meta: DeclaredCallMeta = {
              id: cid,
              name: cname,
              arguments: cargs
            };
            declaredCalls.set(cid, meta);

            const toolItem: ToolCallItem = {
              id: cid,
              name: cname,
              input: cargs,
              output: undefined,
              status: 'running' // 初始状态为 running，保留在运行态，不丢弃
            };
            turnDeclaredTools.set(cid, toolItem);
          }
        }

        // 2. 提取推理/思考内容 (display_reasoning, reasoning, reasoning_content)
        const thought = row['display_reasoning'] || row['reasoning'] || row['reasoning_content'];
        if (thought && typeof thought === 'string' && thought.trim().length > 0) {
          pendingReasoning.push(thought.trim());
        }

        // 3. 提取助手文本正文
        const textContent = HermesHistoryNormalizer.extractRowText(row);

        // 如果助手带有正文，或者这是最终停机消息（即使正文为空但带有完成态），生成助手气泡
        const finishReason = row['finish_reason'] ? String(row['finish_reason']) : '';
        const hasContent = textContent.trim().length > 0;
        const isToolDeclarationOnly = !hasContent && finishReason === 'tool_calls';

        if (hasContent || (!isToolDeclarationOnly && (pendingTools.length > 0 || pendingReasoning.length > 0))) {
          // 关联当前积累的工具结果与推理至本助手消息
          const hasRunning = pendingTools.some(t => t.status === 'running');
          const astMsg: ChatMessage = {
            id: String(row['id'] || `msg_ast_${i}_${Date.now()}`),
            role: 'assistant',
            content: textContent,
            reasoning: pendingReasoning.length > 0 ? pendingReasoning.join('\n\n') : undefined,
            toolCalls: pendingTools.length > 0 ? pendingTools.slice() : undefined,
            status: hasRunning ? 'streaming' : 'complete',
            createdAt: HermesHistoryNormalizer.parseTimestamp(row['timestamp'])
          };
          messages.push(astMsg);
          // 清空已绑定的待定工具与思考
          pendingTools = [];
          pendingReasoning = [];
        }
      } else if (roleStr === 'user') {
        // --- USER 角色处理 ---
        // 严格在当前轮次冲洗未落地的工具（包含未完成的 running 声明）与推理，绝不跨越 user 边界向前污染
        const unfulfilledTools: ToolCallItem[] = [];
        turnDeclaredTools.forEach((val) => { unfulfilledTools.push(val); });
        turnDeclaredTools.clear();
        const allPendingTools = pendingTools.concat(unfulfilledTools);

        HermesHistoryNormalizer.flushPendingToCurrentTurn(messages, allPendingTools, pendingReasoning, lastUserIndex);
        pendingTools = [];
        pendingReasoning = [];

        const userText = HermesHistoryNormalizer.extractRowText(row);
        const userMsg: ChatMessage = {
          id: String(row['id'] || `msg_usr_${i}_${Date.now()}`),
          role: 'user',
          content: userText,
          status: 'complete',
          createdAt: HermesHistoryNormalizer.parseTimestamp(row['timestamp'])
        };
        messages.push(userMsg);
        lastUserIndex = messages.length - 1;
      } else {
        // --- 其他/未知角色处理 (system, custom) ---
        // 兼容未知字段，不静默丢弃
        const otherText = HermesHistoryNormalizer.extractRowText(row);
        if (otherText.trim().length > 0) {
          const role: MessageRole = roleStr === 'system' ? 'system' : 'assistant';
          const otherMsg: ChatMessage = {
            id: String(row['id'] || `msg_oth_${i}_${Date.now()}`),
            role: role,
            content: otherText,
            status: 'complete',
            createdAt: HermesHistoryNormalizer.parseTimestamp(row['timestamp'])
          };
          messages.push(otherMsg);
        }
      }
    }

    // 循环结束后若仍有未落地的工具调用（包含尚未返回结果的 running 声明）或推理，补齐附着在当前轮次
    const remainingTools: ToolCallItem[] = [];
    turnDeclaredTools.forEach((val) => { remainingTools.push(val); });
    turnDeclaredTools.clear();
    const finalPendingTools = pendingTools.concat(remainingTools);

    HermesHistoryNormalizer.flushPendingToCurrentTurn(messages, finalPendingTools, pendingReasoning, lastUserIndex);

    return messages;
  }

  /**
   * 将当前轮次未落地的工具调用或推理挂载至当前轮次的助手消息，或新建当前轮次独立的容器消息
   * 严格受限于 lastUserIndex 边界，绝不跨轮污染更早的轮次
   */
  private static flushPendingToCurrentTurn(
    messages: ChatMessage[],
    pendingTools: ToolCallItem[],
    pendingReasoning: string[],
    lastUserIndex: number
  ): void {
    if (pendingTools.length === 0 && pendingReasoning.length === 0) {
      return;
    }

    // 严格限制在当前轮次（即下标在 lastUserIndex 之后）寻找助手消息进行挂载
    let currentTurnAssistant: ChatMessage | null = null;
    for (let k = messages.length - 1; k > lastUserIndex; k--) {
      if (messages[k].role === 'assistant') {
        currentTurnAssistant = messages[k];
        break;
      }
    }

    if (currentTurnAssistant) {
      if (pendingTools.length > 0) {
        currentTurnAssistant.toolCalls = (currentTurnAssistant.toolCalls || []).concat(pendingTools);
      }
      if (pendingReasoning.length > 0) {
        const prevR = currentTurnAssistant.reasoning ? [currentTurnAssistant.reasoning] : [];
        currentTurnAssistant.reasoning = prevR.concat(pendingReasoning).join('\n\n');
      }
      if (pendingTools.some(t => t.status === 'running')) {
        currentTurnAssistant.status = 'streaming';
      }
    } else {
      // 当前轮次无助手消息，创建属于当前轮次的独立助手容器消息承载孤儿工具/推理
      const hasRunning = pendingTools.some(t => t.status === 'running');
      const pendingMsg: ChatMessage = {
        id: `msg_ast_pending_${Date.now()}_${messages.length}`,
        role: 'assistant',
        content: '',
        reasoning: pendingReasoning.length > 0 ? pendingReasoning.join('\n\n') : undefined,
        toolCalls: pendingTools.slice(),
        status: hasRunning ? 'streaming' : 'complete',
        createdAt: Date.now()
      };
      messages.push(pendingMsg);
    }
  }

  /**
   * 解析 tool 角色的原始 content，提取结构化输出与失败状态
   */
  public static parseToolContent(raw: Object | null | undefined): ParsedToolResult {
    if (raw === null || raw === undefined) {
      const emptyRes: ParsedToolResult = { output: '', isFailed: false };
      return emptyRes;
    }

    if (typeof raw === 'string') {
      const trimmed = (raw as string).trim();
      // 尝试解析 JSON 包装（如 {"output": "1", "exit_code": 0, "error": null}）
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        try {
          const parsed = JSON.parse(trimmed) as Record<string, Object>;
          let out = '';
          let isFailed = false;

          if (parsed['error'] !== undefined && parsed['error'] !== null && String(parsed['error']).length > 0) {
            out = String(parsed['error']);
            isFailed = true;
          } else if (parsed['output'] !== undefined && parsed['output'] !== null) {
            out = String(parsed['output']);
          } else if (parsed['result'] !== undefined && parsed['result'] !== null) {
            out = String(parsed['result']);
          } else {
            out = trimmed;
          }

          if (parsed['exit_code'] !== undefined && parsed['exit_code'] !== null) {
            const code = Number(parsed['exit_code']);
            if (!isNaN(code) && code !== 0) {
              isFailed = true;
            }
          }

          const jsonRes: ParsedToolResult = { output: out, isFailed: isFailed };
          return jsonRes;
        } catch (_e) {
          // 不是合法 JSON，按纯文本处理
        }
      }
      const strRes: ParsedToolResult = {
        output: trimmed,
        isFailed: trimmed.startsWith('Error:') || trimmed.startsWith('Traceback')
      };
      return strRes;
    }

    if (typeof raw === 'object') {
      const obj = raw as Record<string, Object>;
      let out = '';
      let isFailed = false;
      if (obj['error']) {
        out = String(obj['error']);
        isFailed = true;
      } else if (obj['output'] !== undefined && obj['output'] !== null) {
        out = String(obj['output']);
      } else if (obj['result'] !== undefined && obj['result'] !== null) {
        out = String(obj['result']);
      } else {
        out = JSON.stringify(obj);
      }
      if (obj['exit_code'] !== undefined && obj['exit_code'] !== null && Number(obj['exit_code']) !== 0) {
        isFailed = true;
      }
      const objRes: ParsedToolResult = { output: out, isFailed: isFailed };
      return objRes;
    }

    const defaultRes: ParsedToolResult = { output: String(raw), isFailed: false };
    return defaultRes;
  }

  /**
   * 提取消息行的可见文本内容 (优先 display_content，兼容 parts 列表与 content 字符串)
   */
  public static extractRowText(row: Record<string, Object>): string {
    if (row['display_content'] && typeof row['display_content'] === 'string') {
      return row['display_content'] as string;
    }

    const content = row['content'];
    if (typeof content === 'string') {
      return content as string;
    }

    if (Array.isArray(content)) {
      const parts: string[] = [];
      const contentList = content as Array<Object>;
      for (let i = 0; i < contentList.length; i++) {
        const p = contentList[i];
        if (typeof p === 'string') {
          parts.push(p as string);
        } else if (p && typeof p === 'object') {
          const rec = p as Record<string, Object>;
          if (rec['text'] && typeof rec['text'] === 'string') {
            parts.push(rec['text'] as string);
          }
        }
      }
      return parts.join('');
    }

    if (content !== null && content !== undefined) {
      return String(content);
    }

    return '';
  }

  /**
   * 解析时间戳为毫秒数值
   */
  private static parseTimestamp(ts: Object | null | undefined): number {
    if (typeof ts === 'number') {
      // 若时间戳为秒级（例如 1792522278.526），转为毫秒
      const numTs = ts as number;
      return numTs < 10000000000 ? Math.floor(numTs * 1000) : numTs;
    }
    return Date.now();
  }
}
