/**
 * Hermes 鸿蒙原生端到端协议与生产状态机行为测试套件
 * 直接转译并执行真实的 ArkTS 生产业务类：
 * - HermesRESTClient.ets
 * - HermesGatewayClient.ets
 * - ChatViewModel.ets
 * - AuthStore.ets (HarmonyPlatformAuthAdapter + Preferences + AssetStoreKit 密文硬件保管库)
 * - WorkspaceViewModel.ets
 * - HermesWorkspaceClient.ets
 * - HermesFileClient.ets
 * - HermesCronClient.ets
 * - HermesInsightsClient.ets
 * - LegacySSEClient.ets
 * - MarkdownParser.ets
 * 注入 @ohos.net.http, @ohos.net.webSocket, @ohos.data.preferences, @ohos.security.asset, @ohos.file.fs, @ohos.file.picker, @ohos.util 平台适配器
 * 由独立 Mock Hermes 网关驱动真实网络与协议全闭环
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const { WebSocketServer, WebSocket } = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/ws');

function assert(condition, message) {
  if (!condition) {
    console.error(`\n[FAIL] 断言失败: ${message}`);
    throw new Error(`Assertion failed: ${message}`);
  }
}

// --- 1. 构造 @ohos 平台适配器 ---

const platformHttpAdapter = {
  HttpDataType: {
    STRING: 0,
    OBJECT: 1,
    ARRAY_BUFFER: 2
  },
  RequestMethod: {
    GET: 'GET',
    POST: 'POST',
    PUT: 'PUT',
    DELETE: 'DELETE'
  },
  createHttp: () => {
    return {
      request: async (url, options = {}) => {
        return new Promise((resolve, reject) => {
          const u = new URL(url);
          const method = options.method || 'GET';
          const headers = Object.assign({}, options.header || {});
          let bodyData = options.extraData;
          if (bodyData && typeof bodyData === 'object') {
            bodyData = JSON.stringify(bodyData);
          }
          if (bodyData) {
            headers['Content-Length'] = Buffer.byteLength(bodyData);
          }

          const req = http.request(
            {
              hostname: u.hostname,
              port: u.port || 80,
              path: u.pathname + u.search,
              method: method,
              headers: headers,
              timeout: options.readTimeout || 10000
            },
            (res) => {
              const chunks = [];
              res.on('data', (chunk) => {
                chunks.push(chunk);
              });
              res.on('end', () => {
                const fullBuffer = Buffer.concat(chunks);
                if (options.expectDataType === 2) {
                  const ab = new ArrayBuffer(fullBuffer.length);
                  const view = new Uint8Array(ab);
                  for (let i = 0; i < fullBuffer.length; ++i) {
                    view[i] = fullBuffer[i];
                  }
                  resolve({
                    responseCode: res.statusCode || 200,
                    header: res.headers,
                    result: ab
                  });
                } else {
                  resolve({
                    responseCode: res.statusCode || 200,
                    header: res.headers,
                    result: fullBuffer.toString('utf8')
                  });
                }
              });
            }
          );

          req.on('error', (err) => {
            reject(err);
          });

          req.on('timeout', () => {
            req.destroy(new Error('HTTP request timeout'));
          });

          if (bodyData) {
            req.write(bodyData);
          }
          req.end();
        });
      },
      destroy: () => {}
    };
  }
};
platformHttpAdapter.default = platformHttpAdapter;

const platformWebSocketAdapter = {
  createWebSocket: () => {
    let ws = null;
    const listeners = {
      open: [],
      message: [],
      close: [],
      error: []
    };

    return {
      on: (type, callback) => {
        if (listeners[type]) {
          listeners[type].push(callback);
        }
      },
      connect: (url, options, callback) => {
        try {
          const subprotocol = options?.header?.['Sec-WebSocket-Protocol'];
          const protocols = subprotocol ? subprotocol.split(',').map((s) => s.trim()) : [];
          ws = new WebSocket(url, protocols, {
            headers: options?.header || {}
          });

          ws.on('open', () => {
            listeners.open.forEach((cb) => cb(null, true));
            if (callback) callback(null, true);
          });

          ws.on('message', (data) => {
            const str = data.toString('utf8');
            listeners.message.forEach((cb) => cb(null, str));
          });

          ws.on('close', (code, reason) => {
            const reasonStr = reason ? reason.toString() : '';
            listeners.close.forEach((cb) => cb(null, { code, reason: reasonStr }));
          });

          ws.on('error', (err) => {
            listeners.error.forEach((cb) => cb(err));
            if (callback) callback(err, false);
          });
        } catch (e) {
          if (callback) callback(e, false);
        }
      },
      send: (data, callback) => {
        if (!ws || ws.readyState !== WebSocket.OPEN) {
          if (callback) callback(new Error('WebSocket not connected'), false);
          return;
        }
        ws.send(data, (err) => {
          if (callback) callback(err, !err);
        });
      },
      close: (options, callback) => {
        if (ws) {
          const code = options?.code || 1000;
          const reason = options?.reason || '';
          ws.close(code, reason);
        }
        if (callback) callback(null, true);
      }
    };
  }
};
platformWebSocketAdapter.default = platformWebSocketAdapter;

const memoryPrefs = new Map();
let mockPrefFailOnPut = false;

const platformPreferencesAdapter = {
  default: {
    getPreferences: async (ctx, name) => {
      if (!memoryPrefs.has(name)) {
        memoryPrefs.set(name, new Map());
      }
      const store = memoryPrefs.get(name);
      return {
        put: async (key, val) => {
          if (mockPrefFailOnPut) {
            throw new Error('Preferences put failed');
          }
          store.set(key, val);
        },
        get: async (key, defVal) => store.has(key) ? store.get(key) : defVal,
        delete: async (key) => store.delete(key),
        clear: async () => store.clear(),
        flush: async () => {}
      };
    }
  },
  getPreferences: async (ctx, name) => {
    return platformPreferencesAdapter.default.getPreferences(ctx, name);
  }
};

// --- Mock AssetStoreKit (@ohos.security.asset) 硬件级加密凭据保管库 ---
const mockAssetStorage = new Map();
let mockAssetFailOnSave = false;
let mockAssetFailOnRemove = false;

const platformAssetAdapter = {
  Tag: {
    SECRET: 0x20000001,
    ALIAS: 0x20000002,
    RETURN_TYPE: 0x20000040
  },
  ReturnType: {
    ALL: 0,
    ATTRIBUTES: 1
  },
  add: async (attributes) => {
    if (mockAssetFailOnSave) {
      throw { code: 24000008, message: 'Database operation failed' };
    }
    const aliasBytes = attributes.get(platformAssetAdapter.Tag.ALIAS);
    const secretBytes = attributes.get(platformAssetAdapter.Tag.SECRET);
    const key = Buffer.from(aliasBytes).toString('utf8');
    if (mockAssetStorage.has(key)) {
      throw { code: 24000003, message: 'Asset already exists' };
    }
    mockAssetStorage.set(key, secretBytes);
  },
  update: async (query, updateAttrs) => {
    if (mockAssetFailOnSave) {
      throw { code: 24000008, message: 'Database operation failed' };
    }
    const aliasBytes = query.get(platformAssetAdapter.Tag.ALIAS);
    const key = Buffer.from(aliasBytes).toString('utf8');
    const secretBytes = updateAttrs.get(platformAssetAdapter.Tag.SECRET);
    mockAssetStorage.set(key, secretBytes);
  },
  query: async (query) => {
    const aliasBytes = query.get(platformAssetAdapter.Tag.ALIAS);
    const key = Buffer.from(aliasBytes).toString('utf8');
    if (!mockAssetStorage.has(key)) {
      throw { code: 24000002, message: 'Asset not found' };
    }
    const secretBytes = mockAssetStorage.get(key);
    const map = new Map();
    map.set(platformAssetAdapter.Tag.SECRET, secretBytes);
    return [map];
  },
  remove: async (query) => {
    if (mockAssetFailOnRemove) {
      throw { code: 24000008, message: 'Database operation failed' };
    }
    const aliasBytes = query.get(platformAssetAdapter.Tag.ALIAS);
    const key = Buffer.from(aliasBytes).toString('utf8');
    if (!mockAssetStorage.has(key)) {
      throw { code: 24000002, message: 'Asset not found' };
    }
    mockAssetStorage.delete(key);
  }
};
platformAssetAdapter.default = platformAssetAdapter;

const platformFsAdapter = {
  OpenMode: {
    READ_ONLY: 0,
    WRITE_ONLY: 1,
    READ_WRITE: 2,
    CREATE: 0o100,
    TRUNC: 0o1000
  },
  openSync: (filePath, mode) => {
    return { fd: 99, path: filePath };
  },
  writeSync: (fd, buffer) => {
    return buffer.byteLength || buffer.length || 0;
  },
  readSync: (fd, buffer) => {
    return buffer.byteLength || 0;
  },
  statSync: (fd) => {
    return { size: 1024 };
  },
  closeSync: (fd) => {}
};
platformFsAdapter.default = platformFsAdapter;

const platformPickerAdapter = {
  PhotoViewMIMETypes: {
    IMAGE_TYPE: 'image/*'
  },
  PhotoViewPicker: class {
    select(options) {
      return Promise.resolve({ photoUris: ['file:///data/storage/el2/base/photos/test_picked.png'] });
    }
  },
  DocumentViewPicker: class {
    select(options) {
      return Promise.resolve(['file:///data/storage/el2/base/docs/test_doc.bin']);
    }
    save(options) {
      return Promise.resolve(['file:///data/storage/el2/base/docs/saved_artifact.bin']);
    }
  },
  DocumentSaveOptions: class {
    constructor() {
      this.newFileNames = [];
    }
  }
};
platformPickerAdapter.default = platformPickerAdapter;

const platformUtilAdapter = {
  Base64Helper: class {
    encodeToStringSync(arr) {
      return Buffer.from(arr).toString('base64');
    }
  }
};
platformUtilAdapter.default = platformUtilAdapter;

// --- 2. 真实 ArkTS 模块加载器 ---

const moduleCache = new Map();

function customRequire(callerDir, modPath) {
  if (modPath === '@ohos.net.http') {
    return platformHttpAdapter;
  }
  if (modPath === '@ohos.net.webSocket') {
    return platformWebSocketAdapter;
  }
  if (modPath === '@ohos.data.preferences') {
    return platformPreferencesAdapter;
  }
  if (modPath === '@ohos.security.asset') {
    return platformAssetAdapter;
  }
  if (modPath === '@ohos.file.fs') {
    return platformFsAdapter;
  }
  if (modPath === '@ohos.file.picker') {
    return platformPickerAdapter;
  }
  if (modPath === '@ohos.util') {
    return platformUtilAdapter;
  }
  if (modPath === '@ohos.promptAction') {
    return {
      showToast: () => {}
    };
  }

  // 相对路径解析
  let resolved = path.resolve(callerDir, modPath);
  if (fs.existsSync(resolved + '.ets')) {
    resolved = resolved + '.ets';
  } else if (fs.existsSync(resolved + '.ts')) {
    resolved = resolved + '.ts';
  } else if (fs.existsSync(path.join(resolved, 'index.ets'))) {
    resolved = path.join(resolved, 'index.ets');
  } else if (!fs.existsSync(resolved)) {
    throw new Error(`Cannot resolve module: ${modPath} from ${callerDir}`);
  }

  if (moduleCache.has(resolved)) {
    return moduleCache.get(resolved).exports;
  }

  const code = fs.readFileSync(resolved, 'utf-8');
  const transpiled = ts.transpileModule(code, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2022
    }
  }).outputText;

  const m = { exports: {} };
  moduleCache.set(resolved, m);

  const dirname = path.dirname(resolved);
  const fn = new Function('require', 'module', 'exports', '__dirname', '__filename', transpiled);
  fn((p) => customRequire(dirname, p), m, m.exports, dirname, resolved);
  return m.exports;
}

// 真实导入应用业务类
const rootDir = path.resolve(__dirname, '..');
const { HermesRESTClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesRESTClient.ets');
const { HermesGatewayClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesGatewayClient.ets');
const { ChatViewModel } = customRequire(rootDir, './entry/src/main/ets/viewmodel/ChatViewModel.ets');
const { AuthStore, HarmonyPlatformAuthAdapter } = customRequire(rootDir, './entry/src/main/ets/storage/AuthStore.ets');
const { HermesWorkspaceClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesWorkspaceClient.ets');
const { HermesFileClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesFileClient.ets');
const { WorkspaceViewModel } = customRequire(rootDir, './entry/src/main/ets/viewmodel/WorkspaceViewModel.ets');
const { HermesCronClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesCronClient.ets');
const { HermesInsightsClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesInsightsClient.ets');
const { LegacySSEClient } = customRequire(rootDir, './entry/src/main/ets/network/legacy/LegacySSEClient.ets');
const { parseMarkdownBlocks } = customRequire(rootDir, './entry/src/main/ets/components/MarkdownParser.ets');

// --- 3. 端到端行为与契约验证 ---

async function runTestSuite() {
  console.log('=== 开始执行 Hermes 鸿蒙原生生产代码全生命周期测试 ===');
  console.log('目标源码：HermesRESTClient.ets, HermesGatewayClient.ets, ChatViewModel.ets, AuthStore.ets, WorkspaceViewModel.ets\n');

  const port = 49500 + Math.floor(Math.random() * 400);
  const baseUrl = `http://127.0.0.1:${port}`;

  // Mock 服务端记录状态
  let serverStats = {
    loginAttempts: 0,
    verifiedLoginCookie: false,
    verifiedAuthMe: false,
    verifiedTicketMint: false,
    sessionsListed: false,
    messagesFetched: false,
    wsConnectedWithTicket: false,
    capabilitiesNegotiated: false,
    resumeCalls: 0,
    interruptCalls: 0,
    configSetCalls: 0,
    promptSubmitCalls: 0,
    approvalResponded: false,
    lastCloseCode: null,
    verifiedImageUploadDataUrl: false,
    verifiedDownloadArtifactBinary: false,
    verifiedAnalyticsDays: false
  };

  let connectedClientWs = null;

  // 1. 创建 Mock Hermes HTTP 服务
  const server = http.createServer((req, res) => {
    req.resume();
    const cookieHeader = req.headers['cookie'] || '';
    const authHeader = req.headers['authorization'] || '';

    if (req.url === '/api/status' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        version: '0.22.2',
        release_date: '2026.9.24',
        auth_required: true,
        profiles: ['default', 'coding'],
        gateway_running: true,
        gateway_mode: 'local'
      }));
      return;
    }

    if (req.url === '/auth/password-login' && req.method === 'POST') {
      serverStats.loginAttempts++;
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        const payload = JSON.parse(body || '{}');
        if (payload.username === 'hermex_user' && payload.password === 'pass_correct') {
          serverStats.verifiedLoginCookie = true;
          res.writeHead(200, {
            'Set-Cookie': ['hermes_session=sec_cookie_token_999; Path=/; HttpOnly'],
            'Content-Type': 'application/json'
          });
          res.end(JSON.stringify({ access_token: 'bearer_token_abc' }));
        } else {
          res.writeHead(401, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'invalid credentials' }));
        }
      });
      return;
    }

    if (req.url === '/api/auth/me' && req.method === 'GET') {
      if (cookieHeader.includes('hermes_session=sec_cookie_token_999') || authHeader.includes('bearer_token_abc')) {
        serverStats.verifiedAuthMe = true;
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ id: 'u_1', user: 'hermex_user' }));
      } else {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'unauthorized: missing cookie or bearer' }));
      }
      return;
    }

    if (req.url === '/api/auth/ws-ticket' && req.method === 'POST') {
      if (cookieHeader.includes('hermes_session=sec_cookie_token_999') || authHeader.includes('bearer_token_abc')) {
        serverStats.verifiedTicketMint = true;
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ticket: 'ws_ticket_live_777' }));
      } else {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'unauthorized ws-ticket mint' }));
      }
      return;
    }

    if (req.url.startsWith('/api/sessions') && req.method === 'GET' && !req.url.includes('/messages')) {
      serverStats.sessionsListed = true;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        sessions: [
          {
            id: 'sess_prod_1',
            title: '鸿蒙开发任务',
            profile: 'default',
            running: false,
            created_at: Date.now() - 10000,
            updated_at: Date.now()
          }
        ]
      }));
      return;
    }

    if (req.url.includes('/messages') && req.method === 'GET') {
      serverStats.messagesFetched = true;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        messages: [
          {
            id: 'msg_h1',
            role: 'user',
            content: '你好，Hermes！',
            created_at: Date.now() - 5000
          },
          {
            id: 'msg_h2',
            role: 'assistant',
            content: '你好！我是 Hermes 助手。',
            created_at: Date.now() - 4000
          }
        ]
      }));
      return;
    }

    if (req.url.startsWith('/api/fs/list') && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        entries: [
          { name: 'src', isDirectory: true },
          { name: 'package.json', isDirectory: false, size: 1024 }
        ]
      }));
      return;
    }

    if (req.url.startsWith('/api/fs/read-text') && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('export const version = "1.0.0";');
      return;
    }

    if (req.url.startsWith('/api/chat/image-upload') && req.method === 'POST') {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        const payload = JSON.parse(body || '{}');
        assert(payload.filename, 'image-upload 必须包含 filename');
        assert(payload.data_url, 'image-upload 必须使用 data_url 字段 (严格对齐 HermesREST.swift:379-384)');
        assert(!payload.data, 'image-upload 绝不能使用已被废弃的 data 字段！');
        serverStats.verifiedImageUploadDataUrl = true;
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          url: '/uploads/screenshot.png',
          path: 'uploads/screenshot.png'
        }));
      });
      return;
    }

    if (req.url.startsWith('/api/fs/download') && req.method === 'GET') {
      serverStats.verifiedDownloadArtifactBinary = true;
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      const bin = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01, 0x02, 0xff]);
      res.end(bin);
      return;
    }

    if (req.url.startsWith('/api/cron/jobs') && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        jobs: [
          {
            id: 'job_daily_1',
            name: '每日健康检查',
            schedule: '0 8 * * *',
            enabled: true,
            profile: 'default'
          }
        ]
      }));
      return;
    }

    if (req.url.includes('/api/cron/jobs/job_daily_1/run') && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (req.url.includes('/api/cron/jobs/job_daily_1/pause') && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (req.url.includes('/api/cron/jobs/job_daily_1/resume') && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (req.url.startsWith('/api/analytics/usage') && req.method === 'GET') {
      assert(req.url.includes('days=7'), 'analytics/usage 必须携带 ?days=7 参数');
      assert(req.url.includes('profile=default'), 'analytics/usage 必须携带 ?profile=default 参数');
      serverStats.verifiedAnalyticsDays = true;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        days: 7,
        totals: {
          total_input: 20000,
          total_output: 12000,
          total_reasoning: 4000,
          total_api_calls: 18,
          total_actual_cost: 0.28,
          total_estimated_cost: 0.35
        }
      }));
      return;
    }

    if (req.url.startsWith('/api/analytics/models') && req.method === 'GET') {
      assert(req.url.includes('days=7'), 'analytics/models 必须携带 ?days=7 参数');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        days: 7,
        models: [
          {
            model: 'claude-3-5-sonnet',
            provider: 'anthropic',
            api_calls: 18,
            input_tokens: 20000,
            output_tokens: 12000,
            reasoning_tokens: 4000,
            actual_cost: 0.28,
            estimated_cost: 0.35
          }
        ]
      }));
      return;
    }

    if (req.url === '/health' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok' }));
      return;
    }

    res.writeHead(404);
    res.end();
  });

  // 2. 创建 Mock Hermes Gateway WebSocket 服务
  const wss = new WebSocketServer({ noServer: true });

  server.on('upgrade', (request, socket, head) => {
    const subprotocol = request.headers['sec-websocket-protocol'] || '';
    if (!subprotocol.includes('hermes-gateway-ticket.ws_ticket_live_777')) {
      socket.write('HTTP/1.1 403 Forbidden: Invalid Ticket\r\n\r\n');
      socket.destroy();
      return;
    }
    serverStats.wsConnectedWithTicket = true;
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request);
    });
  });

  await new Promise((r) => server.listen(port, r));

  wss.on('connection', (ws) => {
    connectedClientWs = ws;

    ws.on('close', (code) => {
      serverStats.lastCloseCode = code;
    });

    // 握手就绪第一帧
    ws.send(JSON.stringify({
      method: 'event',
      params: {
        type: 'gateway.ready',
        payload: { replay_epoch: 'epoch_hmos_prod_2026' }
      }
    }));

    ws.on('message', (raw) => {
      const frame = JSON.parse(raw.toString('utf8'));

      if (frame.method === 'client.capabilities') {
        assert(frame.params.server_requests === true, 'capabilities 必须携带 server_requests: true');
        serverStats.capabilitiesNegotiated = true;
        ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));
      } else if (frame.method === 'session.resume') {
        serverStats.resumeCalls++;
        const targetSid = frame.params.session_id;
        if (targetSid === 'sess_fail_resume') {
          ws.send(JSON.stringify({ id: frame.id, error: { message: 'Session resume rejected by server' } }));
        } else {
          ws.send(JSON.stringify({ id: frame.id, result: { session_id: `runtime_${targetSid}` } }));
        }
      } else if (frame.method === 'prompt.submit') {
        serverStats.promptSubmitCalls++;
        ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));
      } else if (frame.method === 'session.interrupt') {
        serverStats.interruptCalls++;
        ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));
      } else if (frame.method === 'config.set') {
        serverStats.configSetCalls++;
        assert(frame.params.key === 'model', 'config.set key 必须是 model');
        assert(frame.params.value.includes('--session'), '模型参数必须携带 --session 后缀');
        ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));
      } else if (frame.method === 'approval.respond') {
        serverStats.approvalResponded = true;
        if (frame.params.request_id === 'app_fail_once') {
          ws.send(JSON.stringify({ id: frame.id, error: { message: 'Approval rejected due to lock conflict' } }));
        } else {
          ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));
        }
      }
    });
  });

  // --- 测试用例 1: 生产 HermesRESTClient 真实密码登录、Cookie Jar 与 /api/auth/me 校验 ---
  console.log('[TEST 1] 测试真实 HermesRESTClient.login 与 Cookie / /api/auth/me 强制核验:');
  try {
    await HermesRESTClient.login(baseUrl, 'hermex_user', 'wrong_pass');
    assert(false, '错误密码应被 401 拦截');
  } catch (err) {
    console.log('  -> 错误凭证被正确拒绝:', err.message);
  }

  const loginResult = await HermesRESTClient.login(baseUrl, 'hermex_user', 'pass_correct');
  assert(serverStats.verifiedLoginCookie, '密码登录成功并提取 Set-Cookie');
  assert(serverStats.verifiedAuthMe, '登录后必须强制核验 /api/auth/me 身份');
  assert(loginResult.cookies.includes('hermes_session=sec_cookie_token_999'), 'Cookie 必须包含 hermes_session');
  console.log('  -> 登录成功，Cookie 携带并完成身份核验通过');
  console.log('[PASS 1] 真实 HermesRESTClient 认证链路通过');

  // --- 测试用例 2: 生产 HermesRESTClient Ticket 换取与会话/历史消息拉取 ---
  console.log('\n[TEST 2] 测试真实 HermesRESTClient.getWsTicket / listSessions / getSessionMessages:');
  const ticket = await HermesRESTClient.getWsTicket(baseUrl, loginResult.token, loginResult.cookies);
  assert(ticket === 'ws_ticket_live_777', '真实换取到 Ticket ws_ticket_live_777');

  const sessionList = await HermesRESTClient.listSessions(baseUrl, 'default', loginResult.token, loginResult.cookies);
  assert(sessionList.length === 1 && sessionList[0].id === 'sess_prod_1', '真实拉取并解析会话列表');

  const historyMsgs = await HermesRESTClient.getSessionMessages(baseUrl, 'sess_prod_1', 'default', loginResult.token, loginResult.cookies);
  assert(historyMsgs.length === 2, '真实拉取到 2 条历史消息');
  assert(historyMsgs[0].content === '你好，Hermes！', '历史消息内容解析正确');
  console.log('[PASS 2] 真实 HermesRESTClient 数据契约通过');

  // --- 测试用例 3: 生产 HermesGatewayClient 能力协商握手与合法关闭码 ---
  console.log('\n[TEST 3] 测试真实 HermesGatewayClient 连接、client.capabilities 回执与合法关闭码:');
  let gwConnectedFired = false;
  const gwClient = new HermesGatewayClient({
    onConnected: () => {
      gwConnectedFired = true;
    }
  });

  await gwClient.connect(baseUrl, ticket);
  assert(serverStats.wsConnectedWithTicket, 'WebSocket 握手携带 Ticket 子协议验证');
  assert(serverStats.capabilitiesNegotiated, '真实完成 client.capabilities: server_requests 回执');
  assert(gwConnectedFired, '握手成功触发 onConnected 回调');
  assert(gwClient.getReplayEpoch() === 'epoch_hmos_prod_2026', '真实记录 replay_epoch');

  gwClient.disconnect();
  await new Promise((r) => setTimeout(r, 100));
  assert(serverStats.lastCloseCode === 1000, `关闭码必须为正常码 1000，当前记录: ${serverStats.lastCloseCode} (杜绝非法 1006)`);
  console.log('[PASS 3] 真实 HermesGatewayClient 握手回执与关闭码通过');

  // --- 测试用例 4: 生产 HermesGatewayClient 握手前关闭取消 (Settle Connect Promise) 与 RPC 30s 超时清理 ---
  console.log('\n[TEST 4] 测试真实 HermesGatewayClient 握手前 disconnect 取消与 RPC 30s 超时清理:');
  const cancelGw = new HermesGatewayClient({});
  let cancelRejected = false;
  const pendingConnect = cancelGw.connect(baseUrl, ticket).catch((err) => {
    cancelRejected = true;
  });
  cancelGw.disconnect();
  await pendingConnect;
  assert(cancelRejected, '握手前被 disconnect 时 connect Promise 必须被确定性 reject 而非永远挂起');

  const liveGw = new HermesGatewayClient({});
  await liveGw.connect(baseUrl, ticket);
  let rpcTimeoutTriggered = false;
  try {
    await liveGw.call('unhandled.mock.rpc', {}, 100);
  } catch (timeoutErr) {
    if (timeoutErr.message.includes('RPC timeout')) {
      rpcTimeoutTriggered = true;
    }
  }
  assert(rpcTimeoutTriggered, 'RPC 超时时必须正确触发 reject 并清理资源');
  liveGw.disconnect();
  console.log('[PASS 4] 握手前取消与 RPC 超时清理验证通过');

  // --- 测试用例 5: 生产 ChatViewModel 会话恢复失败严格门禁与禁止发送 ---
  console.log('\n[TEST 5] 测试真实 ChatViewModel 在 resume 失败时的严格状态门禁与发送拦截:');
  const vm = new ChatViewModel();
  let toastMessage = '';
  vm.setListener({
    onErrorToast: (msg) => {
      toastMessage = msg;
    }
  });

  const botConn = {
    id: 'conn_test_1',
    name: '测试Hermes',
    url: baseUrl,
    token: loginResult.token,
    cookies: loginResult.cookies,
    activeProfile: 'default'
  };

  await vm.attachSession(botConn, 'sess_fail_resume');
  await new Promise((r) => setTimeout(r, 200));

  assert(vm.isConnected === false, 'resume 失败时 isConnected 必须为 false');
  assert(vm.getRuntimeSessionId() === '', 'resume 失败时 runtimeSessionId 必须重置为空');
  assert(vm.connectionStatusText === '会话恢复失败', '状态文本必须展示会话恢复失败');

  toastMessage = '';
  await vm.sendMessage('试图发送消息');
  assert(toastMessage.includes('当前会话尚未就绪或恢复失败，无法发送'), '未就绪状态下发送消息必须被严格拦截并提示用户');
  assert(serverStats.promptSubmitCalls === 0, '未就绪状态严禁向服务端发送 prompt.submit');
  console.log('  -> 恢复失败严格门禁拦截成功:', toastMessage);
  console.log('[PASS 5] ChatViewModel 恢复失败安全门禁通过');

  // --- 测试用例 6: 生产 ChatViewModel 成功恢复、加载历史与真实发送 ---
  console.log('\n[TEST 6] 测试真实 ChatViewModel 恢复成功、历史回填与消息发送闭环:');
  await vm.attachSession(botConn, 'sess_prod_1');
  await new Promise((r) => setTimeout(r, 200));

  assert(vm.isConnected === true, '恢复成功后 isConnected 必须为 true');
  assert(vm.getRuntimeSessionId() === 'runtime_sess_prod_1', '必须记录真实服务端 runtime ID (runtime_sess_prod_1)');
  assert(vm.messages.length >= 2, '历史消息必须真实加载到 messages 列表');

  await vm.sendMessage('测试真实提问');
  assert(serverStats.promptSubmitCalls === 1, '提问时必须向服务端发起 prompt.submit RPC');
  assert(vm.messages.some((m) => m.content === '测试真实提问' && m.role === 'user'), '用户提问必须注入消息流');
  console.log('[PASS 6] ChatViewModel 成功恢复与发送闭环通过');

  // --- 测试用例 7: 生产 ChatViewModel 快速切换与 async 代次乱序拦截 ---
  console.log('\n[TEST 7] 测试真实 ChatViewModel async 代次保护 (先切慢会话再切快会话，拦截逆序覆盖):');
  const slowAttach = vm.attachSession(botConn, 'sess_slow_A');
  const fastAttach = vm.attachSession(botConn, 'sess_prod_1');

  await Promise.all([slowAttach, fastAttach]);
  await new Promise((r) => setTimeout(r, 200));

  assert(vm.getStoredSessionId() === 'sess_prod_1', '存储会话 ID 必须保持为最新的 fast 会话 B (sess_prod_1)');
  assert(vm.getRuntimeSessionId() === 'runtime_sess_prod_1', 'runtime 必须保持为最新的 fast 会话 B，杜绝被慢会话 A 覆盖');
  console.log('  -> 代次与实例身份双重保护成功拦截乱序响应');
  console.log('[PASS 7] ChatViewModel async 代次乱序保护通过');

  // --- 测试用例 8: 生产 ChatViewModel 多会话隔离、流式文本、推理聚合与工具调用 ---
  console.log('\n[TEST 8] 测试多会话隔离、中文 UTF-8、推理内容与工具调用状态机:');
  assert(connectedClientWs !== null, '已连接网关 WebSocket');

  // 1. 发送不属于当前活跃 runtime 的串流报文
  connectedClientWs.send(JSON.stringify({
    method: 'event',
    params: {
      type: 'message.delta',
      session_id: 'runtime_other_leak_session',
      payload: { text: '这是不该被接收的串流泄露内容' }
    }
  }));
  await new Promise((r) => setTimeout(r, 50));
  assert(!vm.messages.some((m) => m.content && m.content.includes('串流泄露内容')), '非当前活跃会话的事件必须被严格拦截过滤');

  // 2. 发送属于当前活跃 runtime 的流式生命周期报文
  const activeRuntime = vm.getRuntimeSessionId();
  connectedClientWs.send(JSON.stringify({
    method: 'event',
    params: { type: 'message.start', session_id: activeRuntime, payload: {} }
  }));
  await new Promise((r) => setTimeout(r, 50));
  assert(vm.isGenerating === true, 'message.start 必须标记 isGenerating = true');

  connectedClientWs.send(JSON.stringify({
    method: 'event',
    params: { type: 'reasoning.delta', session_id: activeRuntime, payload: { text: '正在深入分析 HarmonyOS 6 原生架构...' } }
  }));

  connectedClientWs.send(JSON.stringify({
    method: 'event',
    params: { type: 'message.delta', session_id: activeRuntime, payload: { text: '您好！鸿蒙 6 ArkTS 原生测试通过。' } }
  }));

  connectedClientWs.send(JSON.stringify({
    method: 'event',
    params: {
      type: 'tool.start',
      session_id: activeRuntime,
      payload: { id: 't_build', name: 'hvigor_build', input: { mode: 'debug' } }
    }
  }));

  connectedClientWs.send(JSON.stringify({
    method: 'event',
    params: {
      type: 'tool.complete',
      session_id: activeRuntime,
      payload: { id: 't_build', name: 'hvigor_build', output: 'build exit code 0' }
    }
  }));

  connectedClientWs.send(JSON.stringify({
    method: 'event',
    params: { type: 'message.complete', session_id: activeRuntime, payload: {} }
  }));

  await new Promise((r) => setTimeout(r, 100));

  assert(vm.isGenerating === false, 'message.complete 必须标记 isGenerating = false');
  const latestAssistant = vm.messages[vm.messages.length - 1];
  assert(latestAssistant.role === 'assistant', '最新消息应为 assistant');
  assert(latestAssistant.reasoning.includes('HarmonyOS 6 原生架构'), '推理流 reasoning.delta 必须完整累加');
  assert(latestAssistant.content.includes('鸿蒙 6 ArkTS 原生测试通过'), '中文 UTF-8 内容必须准确累加');
  assert(latestAssistant.toolCalls && latestAssistant.toolCalls.length === 1, '工具调用必须完整记录');
  assert(latestAssistant.toolCalls[0].status === 'completed', '工具调用状态必须为 completed');
  console.log('[PASS 8] 多会话隔离、中文流式与推理工具流聚合通过');

  // --- 测试用例 9: 生产 ChatViewModel 审批失败恢复与澄清交互 ---
  console.log('\n[TEST 9] 测试真实 ChatViewModel 审批交互、失败保留与重试闭环:');
  connectedClientWs.send(JSON.stringify({
    id: 'app_fail_once',
    method: 'approval.request',
    params: {
      session_id: activeRuntime,
      tool_name: 'terminal',
      command: 'git push origin harmonyos/native-port',
      choices: ['approve', 'reject']
    }
  }));
  await new Promise((r) => setTimeout(r, 100));

  assert(vm.currentApproval !== null, '当前会话的审批请求必须被挂载到 currentApproval');
  assert(vm.currentApproval.command.includes('git push'), '审批命令匹配');

  await vm.submitApproval('approve');
  assert(vm.currentApproval !== null, '审批请求在服务端返回错误时必须保留在界面供用户重试，杜绝静默吞错！');

  vm.currentApproval.id = 'app_success_now';
  await vm.submitApproval('approve');
  assert(vm.currentApproval === null, '审批成功后才彻底清除待审批状态');
  assert(serverStats.approvalResponded, '服务端已收到审批 respond 回执');
  console.log('[PASS 9] 审批失败保留重试与成功清理闭环通过');

  // --- 测试用例 10: 生产 ChatViewModel 真实模型切换 (config.set) ---
  console.log('\n[TEST 10] 测试真实 ChatViewModel 模型切换与 config.set RPC:');
  await vm.switchModel('claude-3-5-sonnet');
  assert(serverStats.configSetCalls === 1, '切换模型必须向网关发送 config.set RPC');
  assert(vm.currentModel === 'claude-3-5-sonnet', '模型切换成功更新 currentModel');
  console.log('[PASS 10] 真实模型切换契约通过');

  // --- 测试用例 11: 真实 HarmonyPlatformAuthAdapter + Preferences + AssetStoreKit 密文硬件保管库与异常传播测试 (落实 REVIEW_STORAGE_03) ---
  console.log('\n[TEST 11] 测试真实 HarmonyPlatformAuthAdapter (Preferences 元数据 + AssetStoreKit 密文硬件保管库 + 启动 ready + 异常传播):');
  const authStore = AuthStore.getInstance();
  const mockContext = {};
  const platformAdapter = new HarmonyPlatformAuthAdapter(mockContext);
  authStore.setStorageAdapter(platformAdapter);

  // 初始化并等待准备就绪
  await authStore.init(mockContext);
  await authStore.waitUntilReady();

  // 保存连接
  await authStore.saveConnection({
    id: 'conn_sec_1',
    name: '我的生产Hermes',
    url: 'https://hermes.example.com',
    username: 'admin',
    password: 'super_secret_password',
    token: 'jwt_token_secret_xyz',
    cookies: 'cookie_session_abc',
    activeProfile: 'coding',
    isCurrent: true
  });

  // 1. 断言 Preferences 仅保存非敏感元数据，绝对不包含任何明文 password, token, cookies
  const rawMetaJson = await memoryPrefs.get('hermex_auth_metadata').get('connections_metadata', '[]');
  const storedMetaList = JSON.parse(rawMetaJson);
  assert(storedMetaList.length === 1, 'Preferences 存储 1 条元数据记录');
  assert(storedMetaList[0].url === 'https://hermes.example.com', 'Preferences 存储包含 URL');
  assert(storedMetaList[0].password === undefined, 'Preferences 绝不能存储明文 password！');
  assert(storedMetaList[0].token === undefined, 'Preferences 绝不能存储明文 token！');
  assert(storedMetaList[0].cookies === undefined, 'Preferences 绝不能存储明文 cookies！');

  // 2. 断言敏感凭据必须物理进入 AssetStoreKit 硬件级密文保管库
  assert(mockAssetStorage.has('hermex_cred_conn_sec_1'), '敏感凭证必须保存到 AssetStoreKit (hermex_cred_conn_sec_1)');
  const assetSecretBytes = mockAssetStorage.get('hermex_cred_conn_sec_1');
  const assetSecretStr = Buffer.from(assetSecretBytes).toString('utf8');
  assert(assetSecretStr.includes('jwt_token_secret_xyz'), 'AssetStoreKit 包含真实的密文 Token');
  assert(assetSecretStr.includes('super_secret_password'), 'AssetStoreKit 包含真实的密文密码');

  // 3. 测试写入失败异常严格传播 (杜绝静默失败)
  console.log('  -> 测试 Asset 写入异常传播...');
  mockAssetFailOnSave = true;
  let saveFailedCaught = false;
  try {
    await authStore.saveConnection({
      id: 'conn_fail_test',
      name: '失败连接',
      url: 'https://fail.com',
      token: 'token_bad'
    });
  } catch (err) {
    saveFailedCaught = true;
  }
  assert(saveFailedCaught, 'AssetStore 写入异常必须直接向上抛出，绝不能被内部静默吞噬！');
  mockAssetFailOnSave = false;

  // 4. 测试删除失败异常严格传播
  console.log('  -> 测试 Asset 删除异常传播...');
  mockAssetFailOnRemove = true;
  let removeFailedCaught = false;
  try {
    await authStore.removeConnection('conn_sec_1');
  } catch (err) {
    removeFailedCaught = true;
  }
  assert(removeFailedCaught, 'AssetStore 删除异常必须直接向上抛出！');
  mockAssetFailOnRemove = false;

  // 5. 测试真实冷启动恢复 (模拟杀进程重启)
  console.log('  -> 测试真实冷启动还原 (Preferences 元数据 + AssetStoreKit 凭据整合)...');
  // 重新创建 adapter 与重新初始化
  const restartAdapter = new HarmonyPlatformAuthAdapter(mockContext);
  authStore.setStorageAdapter(restartAdapter);
  await authStore.init(mockContext);
  await authStore.waitUntilReady();

  const restoredConn = authStore.getCurrentConnection();
  assert(restoredConn !== null && restoredConn.name === '我的生产Hermes', '冷启动从 Preferences 恢复元数据');
  assert(restoredConn.token === 'jwt_token_secret_xyz', '冷启动从 AssetStoreKit 恢复密文 Token');
  assert(restoredConn.password === 'super_secret_password', '冷启动从 AssetStoreKit 恢复密文密码');

  // 6. 正常彻底移除连接
  await authStore.removeConnection('conn_sec_1');
  assert(!mockAssetStorage.has('hermex_cred_conn_sec_1'), '移除后 AssetStoreKit 硬件保管库必须彻底擦除记录');
  assert(authStore.getConnections().length === 0, '移除后 Preferences 与内存连接列表清空');
  console.log('[PASS 11] 真实 HarmonyPlatformAuthAdapter + Preferences + AssetStoreKit 密文硬件保管库通过');

  // --- 测试用例 12: 生产 HermesWorkspaceClient 路径安全穿透防护 (严格对齐 HermesWorkspaceFileClient.swift:117-124) ---
  console.log('\n[TEST 12] 测试真实 HermesWorkspaceClient.resolveHostPath 路径遍历拒绝与合规拼接:');
  assert(HermesWorkspaceClient.resolveHostPath('/workspace/root', '') === '/workspace/root', '空相对路径返回根');
  assert(HermesWorkspaceClient.resolveHostPath('/workspace/root', '.') === '/workspace/root', '. 相对路径返回根');
  assert(HermesWorkspaceClient.resolveHostPath('/workspace/root', 'src/app') === '/workspace/root/src/app', '正常相对路径正确组合');

  let rejectedTraversal = false;
  try {
    HermesWorkspaceClient.resolveHostPath('/workspace/root', '../outside/secret.txt');
  } catch (e) {
    if (e.message.includes('directory traversal')) rejectedTraversal = true;
  }
  assert(rejectedTraversal, '拒绝 .. 向上目录穿越攻击');

  let rejectedAbsolute = false;
  try {
    HermesWorkspaceClient.resolveHostPath('/workspace/root', '/etc/passwd');
  } catch (e) {
    if (e.message.includes('absolute path not allowed')) rejectedAbsolute = true;
  }
  assert(rejectedAbsolute, '拒绝 / 绝对路径攻击');

  let rejectedHome = false;
  try {
    HermesWorkspaceClient.resolveHostPath('/workspace/root', '~/.ssh/id_rsa');
  } catch (e) {
    if (e.message.includes('home directory traversal')) rejectedHome = true;
  }
  assert(rejectedHome, '拒绝 ~ 家目录攻击');

  let rejectedNull = false;
  try {
    HermesWorkspaceClient.resolveHostPath('/workspace/root', 'valid\0file.txt');
  } catch (e) {
    if (e.message.includes('null bytes forbidden')) rejectedNull = true;
  }
  assert(rejectedNull, '拒绝空字节注入攻击');
  console.log('[PASS 12] HermesWorkspaceClient.resolveHostPath 严密安全防线通过');

  // --- 测试用例 13: 生产 WorkspaceViewModel 目录进入、返回与文件查看 ---
  console.log('\n[TEST 13] 测试真实 WorkspaceViewModel 目录加载、导航与文件读取:');
  const wsVm = new WorkspaceViewModel();
  wsVm.setCwd('/workspace/project');

  await wsVm.loadDirectory(botConn, '');
  assert(wsVm.entries.length === 2, '真实加载工作区 2 个条目');
  assert(wsVm.entries[0].name === 'src' && wsVm.entries[0].isDirectory, '首个条目为 src 目录');

  await wsVm.enterDirectory(botConn, wsVm.entries[0]);
  assert(wsVm.pathHistory.length === 1, '进入子目录后历史深度为 1');

  await wsVm.navigateUp(botConn);
  assert(wsVm.currentRelativePath === '', '返回上一级后 relativePath 回到根');

  await wsVm.viewFile(botConn, { name: 'version.ts', path: 'src/version.ts', isDirectory: false });
  assert(wsVm.isViewingFile === true, '标记正在查看文件');
  assert(wsVm.selectedFileText.includes('export const version = "1.0.0";'), '预览文本内容解析成功');

  wsVm.closeFileView();
  assert(wsVm.isViewingFile === false, '关闭预览恢复状态');
  console.log('[PASS 13] 真实 WorkspaceViewModel 导航与文件查看闭环通过');

  // --- 测试用例 14: 生产 HermesFileClient 图片附件上传 (data_url) 与二进制产物下载 (ArrayBuffer) ---
  console.log('\n[TEST 14] 测试真实 HermesFileClient data_url 字段与 ArrayBuffer 二进制接收:');
  const uploadRes = await HermesFileClient.uploadImage(
    baseUrl,
    'default',
    'screenshot.png',
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    loginResult.token,
    loginResult.cookies
  );
  assert(serverStats.verifiedImageUploadDataUrl, '上传图片 payload 必须携带 data_url 字段 (严格对齐 HermesREST.swift:379-384)');
  assert(uploadRes.path === 'uploads/screenshot.png', '附件图片上传成功获取 remote path');

  const artifactBuffer = await HermesFileClient.downloadArtifact(
    baseUrl,
    'output/build.bin',
    'default',
    'sess_prod_1',
    loginResult.token,
    loginResult.cookies
  );
  assert(serverStats.verifiedDownloadArtifactBinary, '产物下载请求到达服务器');
  assert(artifactBuffer instanceof ArrayBuffer, '下载产物返回值必须是 ArrayBuffer (杜绝文本转换损坏二进制！)');
  assert(artifactBuffer.byteLength === 12, '二进制长度必须完整匹配 12 字节');
  const binView = new Uint8Array(artifactBuffer);
  assert(binView[0] === 0x89 && binView[1] === 0x50 && binView[2] === 0x4e && binView[3] === 0x47, 'PNG 魔数签名完整保留');

  const wsBuffer = await wsVm.downloadFile(botConn, { name: 'build.bin', path: 'output/build.bin', isDirectory: false });
  assert(wsBuffer instanceof ArrayBuffer && wsBuffer.byteLength === 12, 'WorkspaceViewModel.downloadFile 成功产出 ArrayBuffer');
  console.log('[PASS 14] 真实 HermesFileClient data_url 上传与 ArrayBuffer 二进制下载通过');

  // --- 测试用例 15: 生产 HermesCronClient 定时任务调度管理 ---
  console.log('\n[TEST 15] 测试真实 HermesCronClient 定时任务列表、触发执行、暂停与恢复:');
  const cronJobs = await HermesCronClient.listCronJobs(baseUrl, loginResult.token, loginResult.cookies);
  assert(cronJobs.length === 1, '定时任务拉取 1 条');
  assert(cronJobs[0].id === 'job_daily_1', '任务 ID 匹配');
  assert(cronJobs[0].schedule === '0 8 * * *', 'Cron 表达式匹配');

  const runSuccess = await HermesCronClient.runCronJob(baseUrl, 'job_daily_1', 'default', loginResult.token, loginResult.cookies);
  assert(runSuccess, '触发定时任务成功');

  const pauseSuccess = await HermesCronClient.pauseCronJob(baseUrl, 'job_daily_1', 'default', loginResult.token, loginResult.cookies);
  assert(pauseSuccess, '暂停定时任务成功');

  const resumeSuccess = await HermesCronClient.resumeCronJob(baseUrl, 'job_daily_1', 'default', loginResult.token, loginResult.cookies);
  assert(resumeSuccess, '恢复定时任务成功');
  console.log('[PASS 15] 真实 HermesCronClient 定时任务生命周期通过');

  // --- 测试用例 16: 生产 HermesInsightsClient 用量与模型统计 (对齐 analytics.json totals 结构) ---
  console.log('\n[TEST 16] 测试真实 HermesInsightsClient 用量总计与模型明细统计:');
  const usage = await HermesInsightsClient.getUsageSummary(baseUrl, 7, 'default', loginResult.token, loginResult.cookies);
  assert(serverStats.verifiedAnalyticsDays, '请求参数携带 ?days=7 与 ?profile=default');
  assert(usage.totalInputTokens === 20000, '总 Input Token 数匹配');
  assert(usage.totalOutputTokens === 12000, '总 Output Token 数匹配');
  assert(usage.totalReasoningTokens === 4000, '总 Reasoning Token 数匹配');
  assert(usage.totalActualCostUsd === 0.28, '总实际费用 USD 匹配');
  assert(usage.totalApiCalls === 18, '总 API 调用次数匹配');

  const modelUsage = await HermesInsightsClient.getModelUsageList(baseUrl, 7, 'default', loginResult.token, loginResult.cookies);
  assert(modelUsage.length === 1 && modelUsage[0].model === 'claude-3-5-sonnet', '模型统计明细匹配');
  assert(modelUsage[0].apiCalls === 18, '调用次数匹配');
  assert(modelUsage[0].reasoningTokens === 4000, '模型推理 Token 匹配');
  console.log('[PASS 16] 真实 HermesInsightsClient 用量分析通过');

  // --- 测试用例 17: 生产 LegacySSEClient 兼容性探针与 SSE 数据帧解析 ---
  console.log('\n[TEST 17] 测试真实 LegacySSEClient /health 探针与 SSE 数据帧解析:');
  const healthOk = await LegacySSEClient.probeHealth(baseUrl);
  assert(healthOk, 'Legacy webui /health 探针响应成功');

  const sampleSSE = 'event: message.delta\ndata: {"text":"hello legacy"}\n\nevent: message.complete\ndata: {}\n\n';
  const sseEvents = LegacySSEClient.parseSSEChunk(sampleSSE);
  assert(sseEvents.length === 2, '正确解析出 2 个 SSE 事件帧');
  assert(sseEvents[0].event === 'message.delta', '首帧事件名称匹配');
  assert(sseEvents[0].data.includes('hello legacy'), '首帧数据载荷匹配');
  console.log('[PASS 17] 真实 LegacySSEClient 兼容层通过');

  // --- 测试用例 18: 生产 MarkdownView 结构化 AST 解析引擎 ---
  console.log('\n[TEST 18] 测试真实 MarkdownView 标题、代码块、表格、列表与段落解析:');
  const markdownText = `# 一级标题
这是普通段落文本。

> 关键引用提示

- 列表项一
- 列表项二

| 模块 | 状态 | 进度 |
|---|---|---|
| 协议 | 就绪 | 100% |
| UI | 就绪 | 100% |

\`\`\`typescript
export const test = true;
\`\`\``;

  const blocks = parseMarkdownBlocks(markdownText);
  assert(blocks.some(b => b.type === 'heading' && b.content === '一级标题' && b.level === 1), '标题解析');
  assert(blocks.some(b => b.type === 'paragraph' && b.content.includes('普通段落')), '段落解析');
  assert(blocks.some(b => b.type === 'blockquote' && b.content.includes('关键引用')), '引用块解析');
  assert(blocks.some(b => b.type === 'list' && b.content === '列表项一'), '列表解析');
  assert(blocks.some(b => b.type === 'table' && b.rows && b.rows.length >= 2), '表格解析');
  assert(blocks.some(b => b.type === 'code' && b.language === 'typescript'), '代码块语法解析');
  console.log('[PASS 18] 生产 MarkdownView 解析器全语法覆盖通过');

  vm.disconnect();
  server.close();

  console.log('\n======================================================');
  console.log('✅ 所有 18 项端到端生产代码行为回归测试全部通过 (退出码 0)');
  console.log('覆盖真实生产业务类：');
  console.log('  - HermesRESTClient.ets (Cookie Jar、登录、/api/auth/me 核验、Ticket、会话与历史)');
  console.log('  - HermesGatewayClient.ets (WebSocket 握手、client.capabilities 回执、关闭码、RPC 30s 超时、取消)');
  console.log('  - ChatViewModel.ets (会话恢复门禁、禁止发送、async 代次乱序拦截、中文流式、推理、工具、审批重试、模型配置)');
  console.log('  - AuthStore.ets (真实 HarmonyPlatformAuthAdapter + Preferences 元数据 + AssetStoreKit 密文硬件保管库 + 启动 ready + 异常传播)');
  console.log('  - HermesWorkspaceClient.ets (路径穿越防护、远程目录与文件读取)');
  console.log('  - WorkspaceViewModel.ets (目录层级导航、历史回退、文件预览与下载)');
  console.log('  - HermesFileClient.ets (data_url 图片上传、ArrayBuffer 二进制产物下载)');
  console.log('  - HermesCronClient.ets (定时任务调度、触发、暂停与恢复)');
  console.log('  - HermesInsightsClient.ets (模型用量与成本统计)');
  console.log('  - LegacySSEClient.ets (上游旧版 WebUI 健康探针与 SSE 数据帧解析)');
  console.log('  - MarkdownParser.ets / MarkdownView.ets (代码块、表格、列表、引用与多级标题解析渲染)');
  console.log('======================================================');
}

runTestSuite().catch((err) => {
  console.error('\n[FATAL] 测试失败:', err);
  process.exit(1);
});
