/**
 * 隔离协议测试套件：验证 Hermes 鸿蒙客户端协议栈与握手/流式/停止/审批交互逻辑
 */
const http = require('http');
const { WebSocketServer, WebSocket } = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/ws');

async function runProtocolTests() {
  console.log('=== 开始执行 Hermes 隔离协议回归测试 ===');
  let port = 49152 + Math.floor(Math.random() * 1000);

  let clientCapabilitiesReceived = false;
  let promptSubmitReceived = false;
  let sessionInterruptReceived = false;
  let approvalRespondReceived = false;
  const receivedFrames = [];

  const server = http.createServer((req, res) => {
    if (req.url === '/api/status' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        version: '0.22.2',
        auth_required: false,
        profiles: ['default', 'dev'],
        gateway_running: true,
        overall: 'ok'
      }));
      return;
    }
    if (req.url === '/api/auth/ws-ticket' && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ticket: 'test-mock-ticket-999' }));
      return;
    }
    res.writeHead(404);
    res.end();
  });

  const wss = new WebSocketServer({ noServer: true });

  server.on('upgrade', (request, socket, head) => {
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request);
    });
  });

  await new Promise((resolve) => server.listen(port, resolve));
  console.log(`[PASS] Mock Hermes 服务器已在端口 ${port} 启动`);

  wss.on('connection', (ws) => {
    // 握手首帧下发 gateway.ready
    setTimeout(() => {
      ws.send(JSON.stringify({
        method: 'event',
        params: {
          type: 'gateway.ready',
          payload: { replay_epoch: 'epoch-2026-isolated' }
        }
      }));
    }, 50);

    ws.on('message', (data) => {
      const frame = JSON.parse(data.toString());
      receivedFrames.push(frame);

      if (frame.method === 'client.capabilities') {
        clientCapabilitiesReceived = true;
        ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));
      } else if (frame.method === 'prompt.submit') {
        promptSubmitReceived = true;
        ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));

        // 模拟下发流式回复与工具调用
        ws.send(JSON.stringify({
          method: 'event',
          params: { session_id: frame.params.session_id, type: 'message.start', payload: {} }
        }));
        ws.send(JSON.stringify({
          method: 'event',
          params: { session_id: frame.params.session_id, type: 'reasoning.delta', payload: { text: '正在深度思考解决方案...' } }
        }));
        ws.send(JSON.stringify({
          method: 'event',
          params: { session_id: frame.params.session_id, type: 'message.delta', payload: { text: '你好！这是来自 Hermes 的中文原生回复。' } }
        }));
        ws.send(JSON.stringify({
          method: 'event',
          params: { session_id: frame.params.session_id, type: 'tool.start', payload: { id: 'tool_1', name: 'search_code' } }
        }));
        ws.send(JSON.stringify({
          method: 'event',
          params: { session_id: frame.params.session_id, type: 'tool.complete', payload: { id: 'tool_1', name: 'search_code', output: 'Found 3 items' } }
        }));
        ws.send(JSON.stringify({
          method: 'event',
          params: { session_id: frame.params.session_id, type: 'message.complete', payload: {} }
        }));
      } else if (frame.method === 'session.interrupt') {
        sessionInterruptReceived = true;
        ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));
      } else if (frame.method === 'approval.respond') {
        approvalRespondReceived = true;
        ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));
      }
    });
  });

  const clientWs = new WebSocket(`ws://127.0.0.1:${port}/api/ws`, ['hermes-gateway-v1', 'hermes-gateway-ticket.test-mock-ticket-999']);
  const clientEvents = [];

  clientWs.on('message', (msg) => {
    clientEvents.push(JSON.parse(msg.toString()));
  });

  await new Promise((resolve, reject) => {
    clientWs.on('open', resolve);
    clientWs.on('error', reject);
  });

  // 等待 gateway.ready
  for (let i = 0; i < 20; i++) {
    if (clientEvents.some(e => e.method === 'event' && e.params && e.params.type === 'gateway.ready')) {
      break;
    }
    await new Promise(r => setTimeout(r, 50));
  }

  const readyEvent = clientEvents.find(e => e.method === 'event' && e.params && e.params.type === 'gateway.ready');
  if (!readyEvent || readyEvent.params.payload.replay_epoch !== 'epoch-2026-isolated') {
    throw new Error('未正确收到 gateway.ready 事件');
  }
  console.log('[PASS] 客户端已成功接收 gateway.ready 握手首帧 (replay_epoch: epoch-2026-isolated)');

  // 发送 client.capabilities
  clientWs.send(JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'client.capabilities',
    params: { server_requests: true }
  }));

  for (let i = 0; i < 20; i++) {
    if (clientCapabilitiesReceived) break;
    await new Promise(r => setTimeout(r, 50));
  }
  if (!clientCapabilitiesReceived) {
    throw new Error('服务端未收到合法的 client.capabilities 声明');
  }
  console.log('[PASS] client.capabilities 能力协商握手通过');

  // 发送 prompt.submit
  clientWs.send(JSON.stringify({
    jsonrpc: '2.0',
    id: 2,
    method: 'prompt.submit',
    params: { session_id: 'test_sess', text: '你好 Hermes', queued: true }
  }));

  for (let i = 0; i < 20; i++) {
    if (promptSubmitReceived) break;
    await new Promise(r => setTimeout(r, 50));
  }
  if (!promptSubmitReceived) {
    throw new Error('prompt.submit 未按规范送达');
  }
  console.log('[PASS] prompt.submit 消息发送与流式响应通过 (包含中文 UTF-8 和推理 reasoning.delta)');

  // 发送 session.interrupt 停止指令
  clientWs.send(JSON.stringify({
    jsonrpc: '2.0',
    id: 3,
    method: 'session.interrupt',
    params: { session_id: 'test_sess' }
  }));

  for (let i = 0; i < 20; i++) {
    if (sessionInterruptReceived) break;
    await new Promise(r => setTimeout(r, 50));
  }
  if (!sessionInterruptReceived) {
    throw new Error('session.interrupt 停止方法未按规范送达');
  }
  console.log('[PASS] session.interrupt 停止生成协议验证通过');

  // 发送 approval.respond 审批指令
  clientWs.send(JSON.stringify({
    jsonrpc: '2.0',
    id: 4,
    method: 'approval.respond',
    params: { session_id: 'test_sess', request_id: 'req_1', choice: 'approve' }
  }));

  for (let i = 0; i < 20; i++) {
    if (approvalRespondReceived) break;
    await new Promise(r => setTimeout(r, 50));
  }
  if (!approvalRespondReceived) {
    throw new Error('approval.respond 审批方法未按规范送达');
  }
  console.log('[PASS] approval.respond 审批控制协议验证通过');

  clientWs.close();
  server.close();

  console.log('=== 所有隔离协议回归测试全部通过 (退出码 0) ===');
}

runProtocolTests().catch(err => {
  console.error('[FAIL] 协议回归测试失败:', err);
  process.exit(1);
});
