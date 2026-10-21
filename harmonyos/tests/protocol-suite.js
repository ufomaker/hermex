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
    DELETE: 'DELETE',
    PATCH: 'PATCH'
  },
  createHttp: () => {
    const eventListeners = {
      dataReceive: [],
      dataEnd: [],
      headersReceive: []
    };

    return {
      on: (type, callback) => {
        if (!eventListeners[type]) eventListeners[type] = [];
        eventListeners[type].push(callback);
      },
      off: (type, callback) => {
        if (eventListeners[type]) {
          if (!callback) eventListeners[type] = [];
          else eventListeners[type] = eventListeners[type].filter(cb => cb !== callback);
        }
      },
      requestInStream: async (url, options = {}) => {
        return new Promise((resolve, reject) => {
          const u = new URL(url);
          const method = (options.method || 'GET').toUpperCase();
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
              timeout: options.readTimeout || 15000
            },
            (res) => {
              for (const cb of eventListeners.headersReceive) {
                cb(res.headers);
              }
              resolve(res.statusCode || 200);

              res.on('data', (chunk) => {
                const ab = new ArrayBuffer(chunk.length);
                const view = new Uint8Array(ab);
                for (let i = 0; i < chunk.length; ++i) {
                  view[i] = chunk[i];
                }
                for (const cb of eventListeners.dataReceive) {
                  cb(ab);
                }
              });
              res.on('end', () => {
                for (const cb of eventListeners.dataEnd) {
                  cb();
                }
              });
            }
          );
          req.on('error', (err) => {
            reject(err);
          });
          if (bodyData) {
            req.write(bodyData);
          }
          req.end();
        });
      },
      request: async (url, options = {}) => {
        return new Promise((resolve, reject) => {
          const u = new URL(url);
          const method = (options.method || 'GET').toUpperCase();
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
          // 鸿蒙真机 NetStack API12 行为契约：未在 options 中配置 protocol 子协议参数时，握手 HTTP 101 升级抛出 code:200, data:"101"
          if (!options || typeof options.protocol !== 'string' || !options.protocol) {
            const netstackErr = { code: 200, data: '101' };
            setTimeout(() => {
              listeners.error.forEach((cb) => cb(netstackErr));
              if (callback) callback(netstackErr, false);
            }, 10);
            return;
          }

          const subprotocol = options.protocol;
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
    let flag = 'r';
    if ((mode & 0o100) && (mode & 0o1000)) flag = 'w+';
    else if (mode & 0o100) flag = 'a+';
    else if (mode === 0) flag = 'r';
    else flag = 'r+';
    const fd = fs.openSync(filePath, flag);
    return { fd: fd, path: filePath };
  },
  writeSync: (fd, buffer) => {
    return fs.writeSync(fd, Buffer.from(buffer.buffer || buffer));
  },
  readSync: (fd, buffer) => {
    return fs.readSync(fd, Buffer.from(buffer.buffer || buffer));
  },
  statSync: (fileOrPath) => {
    return fs.statSync(fileOrPath);
  },
  unlinkSync: (filePath) => {
    try { fs.unlinkSync(filePath); } catch (_e) {}
  },
  closeSync: (fd) => {
    try { fs.closeSync(fd); } catch (_e) {}
  }
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

const NodeUtil = require('util');

const platformUtilAdapter = {
  Base64Helper: class {
    encodeToStringSync(arr) {
      return Buffer.from(arr).toString('base64');
    }
  },
  TextEncoder: class {
    constructor(enc) {}
    encodeInto(str) {
      return new Uint8Array(Buffer.from(str, 'utf8'));
    }
  },
  TextDecoder: {
    create: (enc) => {
      const dec = new NodeUtil.TextDecoder(enc || 'utf-8');
      return {
        decodeWithStream: (arr, opt) => dec.decode(arr, opt),
        decodeToString: (arr) => dec.decode(arr),
        decode: (arr, opt) => dec.decode(arr, opt)
      };
    }
  }
};
platformUtilAdapter.default = platformUtilAdapter;

const platformNotificationAdapter = {
  isNotificationEnabled: async () => true,
  publish: async (req) => {},
  cancel: async (id) => {},
  ContentType: {
    NOTIFICATION_CONTENT_BASIC_TEXT: 0,
    NOTIFICATION_CONTENT_LONG_TEXT: 1
  }
};
platformNotificationAdapter.default = platformNotificationAdapter;

const platformRcpAdapter = {
  rcp: {
    createSession: () => ({
      fetch: async (req) => {
        const u = new URL(req.url);
        const method = (req.method || 'GET').toUpperCase();
        const headers = Object.assign({}, req.headers || {});
        let bodyData = req.content;
        if (bodyData && typeof bodyData === 'object') {
          bodyData = JSON.stringify(bodyData);
        }
        if (bodyData) {
          headers['content-length'] = Buffer.byteLength(bodyData);
        }
        return new Promise((resolve, reject) => {
          const httpReq = http.request(
            {
              hostname: u.hostname,
              port: u.port || 80,
              path: u.pathname + u.search,
              method: method,
              headers: headers,
              timeout: 10000
            },
            (res) => {
              const chunks = [];
              res.on('data', chunk => chunks.push(chunk));
              res.on('end', () => {
                const bodyStr = Buffer.concat(chunks).toString('utf8');
                resolve({
                  statusCode: res.statusCode || 200,
                  headers: res.headers,
                  body: bodyStr,
                  toString: () => bodyStr,
                  toJSON: () => {
                    try { return JSON.parse(bodyStr); } catch (e) { return null; }
                  }
                });
              });
            }
          );
          httpReq.on('error', reject);
          if (bodyData) httpReq.write(bodyData);
          httpReq.end();
        });
      },
      close: () => {}
    }),
    Request: class {
      constructor(url, method, headers, content) {
        this.url = url;
        this.method = method;
        this.headers = headers;
        this.content = content;
      }
    }
  }
};
platformRcpAdapter.default = platformRcpAdapter;

const platformMediaAdapter = {
  AudioSourceType: { AUDIO_SOURCE_TYPE_DEFAULT: 0, AUDIO_MIC: 1 },
  CodecMimeType: { AUDIO_AAC: 'audio/mp4a-latm' },
  ContainerFormatType: { CFT_MPEG_4A: 'm4a' },
  createAVRecorder: async () => {
    let state = 'idle';
    let config = null;
    return {
      prepare: async (cfg) => {
        config = cfg;
        state = 'prepared';
      },
      start: async () => {
        state = 'started';
        if (config && config.url && config.url.startsWith('fd://')) {
          const fd = parseInt(config.url.substring(5), 10);
          if (fd >= 0) {
            try {
              fs.writeSync(fd, Buffer.from('M4A_TEST_AUDIO_BYTES_HEADER'));
            } catch (_e) {}
          }
        }
      },
      stop: async () => { state = 'stopped'; },
      release: async () => { state = 'released'; }
    };
  },
  createAVPlayer: async () => {
    const listeners = {};
    let _url = '';
    let _fdSrc = null;
    const player = {
      get url() { return _url; },
      set url(val) {
        _url = val;
        player.state = 'initialized';
        if (listeners['stateChange']) {
          listeners['stateChange'].forEach(cb => cb('initialized'));
        }
      },
      get fdSrc() { return _fdSrc; },
      set fdSrc(val) {
        _fdSrc = val;
        player.state = 'initialized';
        if (listeners['stateChange']) {
          listeners['stateChange'].forEach(cb => cb('initialized'));
        }
      },
      state: 'idle',
      on: (type, cb) => {
        if (!listeners[type]) listeners[type] = [];
        listeners[type].push(cb);
      },
      prepare: async () => {
        player.state = 'prepared';
        if (listeners['stateChange']) {
          listeners['stateChange'].forEach(cb => cb('prepared'));
        }
      },
      play: async () => {
        player.state = 'playing';
        if (listeners['stateChange']) {
          listeners['stateChange'].forEach(cb => cb('playing'));
        }
      },
      stop: async () => {
        player.state = 'stopped';
        if (listeners['stateChange']) {
          listeners['stateChange'].forEach(cb => cb('stopped'));
        }
      },
      release: async () => {
        player.state = 'released';
        if (listeners['stateChange']) {
          listeners['stateChange'].forEach(cb => cb('released'));
        }
      }
    };
    return player;
  }
};
platformMediaAdapter.default = platformMediaAdapter;

const platformSystemShareAdapter = {
  SharePreviewMode: { DEFAULT: 0, DETAIL: 1 },
  SelectionMode: { SINGLE: 0, BATCH: 1 },
  SharedRecord: class {},
  SharedData: class {
    constructor(record) { this.record = record; }
  },
  ShareController: class {
    constructor(sharedData) { this.sharedData = sharedData; }
    show(context, options) {
      return Promise.resolve();
    }
  }
};
platformSystemShareAdapter.default = platformSystemShareAdapter;

const platformUtdAdapter = {
  UniformDataType: {
    PLAIN_TEXT: 'general.plain-text',
    FILE: 'general.file'
  }
};
platformUtdAdapter.default = platformUtdAdapter;

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
  if (modPath === '@ohos.notificationManager' || modPath === '@ohos.notification') {
    return platformNotificationAdapter;
  }
  if (modPath === '@kit.PerformanceAnalysisKit') {
    return {
      hilog: {
        info: () => {},
        error: () => {},
        warn: () => {},
        debug: () => {}
      }
    };
  }
  if (modPath === '@kit.RemoteCommunicationKit' || modPath === '@hms.collaboration.rcp') {
    return platformRcpAdapter;
  }
  if (modPath === '@ohos.multimedia.media' || modPath === '@kit.MediaKit') {
    return platformMediaAdapter;
  }
  if (modPath === '@hms.collaboration.systemShare' || modPath === '@kit.ShareKit') {
    return platformSystemShareAdapter;
  }
  if (modPath === '@ohos.data.uniformTypeDescriptor') {
    return platformUtdAdapter;
  }
  if (modPath === '@ohos.abilityAccessCtrl') {
    const atAdapter = {
      GrantStatus: { PERMISSION_GRANTED: 0, PERMISSION_DENIED: -1 },
      createAtManager: () => ({
        checkAccessToken: async () => 0,
        requestPermissionsFromUser: async () => ({ authResults: [0] })
      })
    };
    atAdapter.default = atAdapter;
    return atAdapter;
  }
  if (modPath === '@ohos.app.ability.common' || modPath === '@ohos.app.ability.Want' || modPath === '@kit.AbilityKit') {
    return {};
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
const { LegacySSEClient, LegacySSEParser } = customRequire(rootDir, './entry/src/main/ets/network/legacy/LegacySSEClient.ets');
const { parseMarkdownBlocks } = customRequire(rootDir, './entry/src/main/ets/components/MarkdownParser.ets');
const { getMimeType, isImageFile, sanitizeFilename, generateAttachmentName } = customRequire(rootDir, './entry/src/main/ets/utils/AttachmentUtils.ets');
const { HermesProjectClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesProjectClient.ets');
const { HermesSkillsClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesSkillsClient.ets');
const { HermesMemoryClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesMemoryClient.ets');
const { HermesKanbanClient } = customRequire(rootDir, './entry/src/main/ets/network/HermesKanbanClient.ets');
const { GitWorkspaceViewModel } = customRequire(rootDir, './entry/src/main/ets/viewmodel/GitWorkspaceViewModel.ets');
const { SkillsViewModel } = customRequire(rootDir, './entry/src/main/ets/viewmodel/SkillsViewModel.ets');
const { CronViewModel } = customRequire(rootDir, './entry/src/main/ets/viewmodel/CronViewModel.ets');
const { InsightsViewModel } = customRequire(rootDir, './entry/src/main/ets/viewmodel/InsightsViewModel.ets');
const { KanbanViewModel } = customRequire(rootDir, './entry/src/main/ets/viewmodel/KanbanViewModel.ets');
const { NotificationUtils } = customRequire(rootDir, './entry/src/main/ets/utils/NotificationUtils.ets');
const { DeepLinkUtils, AppDeepLinkRouter } = customRequire(rootDir, './entry/src/main/ets/utils/DeepLinkUtils.ets');
const { ShareUtils } = customRequire(rootDir, './entry/src/main/ets/utils/ShareUtils.ets');
const { VoiceUtils } = customRequire(rootDir, './entry/src/main/ets/utils/VoiceUtils.ets');
const { HermesHistoryNormalizer } = customRequire(rootDir, './entry/src/main/ets/utils/HermesHistoryNormalizer.ets');
const { SessionListViewModel } = customRequire(rootDir, './entry/src/main/ets/viewmodel/SessionListViewModel.ets');

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

    const parsedUrl = new URL(req.url, 'http://127.0.0.1');

    if (parsedUrl.pathname === '/api/sessions/search' && req.method === 'GET') {
      // 严格检查：必须使用 q 参数！若使用 query 参数，直接返回 400 错误
      if (parsedUrl.searchParams.has('query')) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: "Invalid parameter 'query'; upstream HermesREST strictly requires 'q'" }));
        return;
      }
      const rawQ = parsedUrl.searchParams.get('q');
      if (rawQ === null || rawQ === undefined || rawQ.trim() === '') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ results: [] }));
        return;
      }
      const q = rawQ.toLowerCase();
      const p = parsedUrl.searchParams.get('profile') || 'default';
      const results = [];
      for (let i = 1; i <= 35; i++) {
        const title = `会话第 ${i} 课`;
        if (title.toLowerCase().includes(q) || `sess_f02_${i}`.includes(q)) {
          results.push({
            id: `sess_f02_${i}`,
            title: title,
            preview: `这是第 ${i} 条会话预览`,
            profile: p,
            running: false,
            created_at: Date.now() - (35 - i) * 1000,
            updated_at: Date.now() - (35 - i) * 1000
          });
        }
      }
      // 特殊测试用例支持：c++ 编码测试 (检验 + 是否转义为 %2B 成功接收为 c++)
      if (rawQ === 'c++') {
        results.push({
          id: 'sess_cpp_test',
          title: 'C++ 进阶实战',
          preview: 'C++ 高级开发',
          profile: p,
          running: false,
          created_at: Date.now(),
          updated_at: Date.now()
        });
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ results }));
      return;
    }

    if (parsedUrl.pathname === '/api/sessions/import' && req.method === 'POST') {
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        const payload = JSON.parse(body || '{}');
        const importedIds = (payload.sessions || []).map(s => s.id);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, imported: importedIds.length, imported_ids: importedIds, errors: [] }));
      });
      return;
    }

    if (parsedUrl.pathname.startsWith('/api/sessions/') && parsedUrl.pathname.endsWith('/export') && req.method === 'GET') {
      const sid = parsedUrl.pathname.split('/')[3];
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        id: sid,
        profile: parsedUrl.searchParams.get('profile') || 'default',
        title: '导出的会话',
        messages: [{ id: 1, role: 'user', content: 'hello' }]
      }));
      return;
    }

    if (parsedUrl.pathname.startsWith('/api/sessions/') && req.method === 'PATCH') {
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        const payload = JSON.parse(body || '{}');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          title: payload.title,
          pinned: payload.pinned,
          archived: payload.archived
        }));
      });
      return;
    }

    if (parsedUrl.pathname === '/api/sessions' && req.method === 'GET') {
      serverStats.sessionsListed = true;
      const prof = parsedUrl.searchParams.get('profile') || 'default';
      const offset = parseInt(parsedUrl.searchParams.get('offset') || '0', 10);
      const limit = parseInt(parsedUrl.searchParams.get('limit') || '50', 10);
      const archived = parsedUrl.searchParams.get('archived');
      const order = parsedUrl.searchParams.get('order');

      // 严格校验上游 HermesREST.swift:448 契约：archived 必须为 'only' 或 'exclude'，不能是布尔字符串
      if (archived === 'true' || archived === 'false') {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: "archived parameter must be 'only' or 'exclude', got boolean string" }));
        return;
      }

      if (prof === 'fast_profile') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          sessions: [
            { id: 'sess_fast_1', title: 'Fast Profile Session', profile: 'fast_profile', running: false, created_at: Date.now(), updated_at: Date.now() }
          ],
          total: 1
        }));
        return;
      }

      // 归档流测试 (archived=only)
      if (archived === 'only') {
        const mockArchived = [
          {
            id: 'sess_archived_1',
            title: '历史归档会话 1',
            preview: '历史归档资料',
            profile: prof,
            archived: true,
            pinned: false,
            running: false,
            created_at: Date.now() - 50000,
            updated_at: Date.now() - 50000
          },
          {
            id: 'sess_archived_2',
            title: '历史归档会话 2',
            preview: '历史归档记录',
            profile: prof,
            archived: true,
            pinned: false,
            running: false,
            created_at: Date.now() - 60000,
            updated_at: Date.now() - 60000
          },
          // 模拟服务端真实行为：回填未归档的置顶会话！
          {
            id: 'sess_f02_pinned_backfill',
            title: '活跃置顶会话 (服务端回填)',
            preview: '回填置顶项',
            profile: prof,
            archived: false,
            pinned: true,
            running: false,
            created_at: Date.now() - 1000,
            updated_at: Date.now() - 1000
          }
        ];
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          sessions: mockArchived,
          total: 2
        }));
        return;
      }

      // 活跃会话流 (archived=exclude)
      if (limit === 20) {
        const pinnedSession = {
          id: 'sess_f02_pinned_global',
          title: '全局置顶会话 (服务端多页回填)',
          preview: '多页重复置顶项',
          profile: prof,
          running: false,
          archived: false,
          pinned: true,
          created_at: Date.now() - 100000,
          updated_at: Date.now() - 100000
        };

        const mockList = [];
        for (let i = 1; i <= 35; i++) {
          mockList.push({
            id: `sess_f02_${i}`,
            title: `会话第 ${i} 课`,
            preview: `这是第 ${i} 条会话预览`,
            profile: prof,
            running: false,
            archived: false,
            pinned: false,
            created_at: Date.now() - (35 - i) * 1000,
            updated_at: Date.now() - (35 - i) * 1000
          });
        }

        let paged = [];
        if (offset === 0) {
          // 第 1 页：1 条置顶 + 19 条普通 = 20 条
          paged = [pinnedSession, ...mockList.slice(0, 19)];
        } else {
          // 第 2 页 (offset 20)：模拟服务端再次回填置顶项 + 剩余 16 条普通 = 17 条
          paged = [pinnedSession, ...mockList.slice(19)];
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          sessions: paged,
          total: 36
        }));
        return;
      }

      // TEST 2: 保持原样返回单项 sess_prod_1
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
        ],
        total: 1
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

    // Cron 任务执行历史 (GET /api/cron/jobs/:id/runs)
    if (parsedUrl.pathname.match(/\/api\/cron\/jobs\/([^\/]+)\/runs/) && req.method === 'GET') {
      const match = parsedUrl.pathname.match(/\/api\/cron\/jobs\/([^\/]+)\/runs/);
      const jobId = match ? match[1] : 'job_daily_1';
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        runs: [
          {
            id: `run_${jobId}_001`,
            started_at: Date.now() - 3600000,
            ended_at: Date.now() - 3590000,
            is_active: false,
            end_reason: 'ok',
            last_status: 'ok',
            title: '定时任务日常执行'
          }
        ]
      }));
      return;
    }

    // Cron 触发执行 (POST /api/cron/jobs/:id/trigger 或 /run)
    if (parsedUrl.pathname.match(/\/api\/cron\/jobs\/([^\/]+)\/(trigger|run)/) && req.method === 'POST') {
      const match = parsedUrl.pathname.match(/\/api\/cron\/jobs\/([^\/]+)\/(trigger|run)/);
      const jobId = match ? match[1] : '';
      if (jobId === 'job_conflict') {
        res.writeHead(409, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ detail: 'Task already active in background' }));
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, status: 'ok' }));
      return;
    }

    // Cron 暂停 (POST /api/cron/jobs/:id/pause)
    if (parsedUrl.pathname.match(/\/api\/cron\/jobs\/([^\/]+)\/pause/) && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, state: 'paused' }));
      return;
    }

    // Cron 恢复 (POST /api/cron/jobs/:id/resume)
    if (parsedUrl.pathname.match(/\/api\/cron\/jobs\/([^\/]+)\/resume/) && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, state: 'active' }));
      return;
    }

    // Cron 编辑更新 (PUT /api/cron/jobs/:id)
    if (parsedUrl.pathname.startsWith('/api/cron/jobs/') && req.method === 'PUT') {
      const jobId = parsedUrl.pathname.replace('/api/cron/jobs/', '');
      let bodyStr = '';
      req.on('data', chunk => { bodyStr += chunk; });
      req.on('end', () => {
        let updates = {};
        try {
          const parsedBody = JSON.parse(bodyStr);
          updates = parsedBody.updates || parsedBody;
        } catch (_) {}
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          job: {
            id: jobId,
            name: updates.name || '已更新任务',
            schedule: updates.schedule || '0 9 * * *',
            prompt: updates.prompt || '',
            enabled: true,
            state: 'active'
          }
        }));
      });
      return;
    }

    // Cron 创建任务 (POST /api/cron/jobs)
    if (parsedUrl.pathname === '/api/cron/jobs' && req.method === 'POST') {
      let bodyStr = '';
      req.on('data', chunk => { bodyStr += chunk; });
      req.on('end', () => {
        let payload = {};
        try {
          payload = JSON.parse(bodyStr);
        } catch (_) {}
        if (payload.name === 'trigger-424') {
          res.writeHead(424, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ detail: { error: 'Scheduler registration failed' } }));
          return;
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          ok: true,
          job: {
            id: 'job_created_888',
            name: payload.name || '新创建任务',
            schedule: payload.schedule || '* * * * *',
            prompt: payload.prompt || '',
            enabled: true,
            state: 'active',
            profile: parsedUrl.searchParams.get('profile') || 'default'
          }
        }));
      });
      return;
    }

    // Cron 任务列表 (GET /api/cron/jobs)
    if (parsedUrl.pathname === '/api/cron/jobs' && req.method === 'GET') {
      const prof = parsedUrl.searchParams.get('profile') || 'default';
      if (prof === 'fast_profile') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify([
          {
            id: 'job_fast_1',
            name: 'Fast Profile 快速任务',
            schedule: '*/15 * * * *',
            enabled: true,
            profile: 'fast_profile'
          }
        ]));
        return;
      }

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

    if (req.url.startsWith('/api/projects') && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify([
        { id: 'proj_1', name: 'HermexPort', path: '/workspace/hermex', is_default: true }
      ]));
      return;
    }

    if (req.url.startsWith('/api/fs/git-root') && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ root: '/workspace/hermex' }));
      return;
    }

    if (req.url.startsWith('/api/git/status') && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        branch: 'harmonyos/native-port',
        changed: 3,
        untracked: 1,
        ahead: 1,
        behind: 0
      }));
      return;
    }

    if (req.url.startsWith('/api/git/branches') && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify([
        { name: 'master', current: false, remote: false },
        { name: 'harmonyos/native-port', current: true, remote: false }
      ]));
      return;
    }

    if (req.url === '/api/git/branch/switch' && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (req.url.startsWith('/api/skills') && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify([
        { name: 'code_reviewer', description: '代码自动审查', enabled: true },
        { name: 'linter', description: '语法检查器', enabled: false }
      ]));
      return;
    }

    if (req.url.startsWith('/api/skills/set') && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (req.url.startsWith('/api/profiles/') && req.url.includes('/soul')) {
      if (req.method === 'GET') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ soul: 'You are an intelligent ArkTS assistant.' }));
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      }
      return;
    }

    if (req.url === '/api/plugins/kanban/config' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ enabled: true, version: '1.0.0' }));
      return;
    }

    if (req.url === '/api/plugins/kanban/boards' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        boards: [{ slug: 'sprint-board-1', name: 'Sprint Board 1', read_only: false }],
        current: 'sprint-board-1',
        read_only: false
      }));
      return;
    }

    if (req.url.startsWith('/api/plugins/kanban/board') && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        name: 'sprint-board-1',
        columns: [
          {
            name: 'In Progress',
            cards: [
              { id: 'card_101', title: '完成 HarmonyOS 原生移植', status: 'In Progress', assignee: 'antigravity' }
            ]
          }
        ],
        latestEventId: 999
      }));
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
        assert(frame.params.session_id, 'approval.respond 必须包含 session_id');
        assert(frame.params.request_id, 'approval.respond 必须包含 request_id');
        assert(['once', 'session', 'always', 'deny'].includes(frame.params.choice), `choice 必须是 once/session/always/deny，实际为: ${frame.params.choice}`);
        if (frame.params.request_id === 'app_fail_once') {
          ws.send(JSON.stringify({ id: frame.id, error: { message: 'Approval rejected due to lock conflict' } }));
        } else {
          ws.send(JSON.stringify({ id: frame.id, result: { resolved: 1 } }));
        }
      } else if (frame.method === 'file.attach') {
        assert(frame.params.session_id, 'file.attach 必须包含 session_id');
        assert(frame.params.name, 'file.attach 必须包含 name');
        assert(frame.params.data_url, 'file.attach 必须包含 data_url');
        serverStats.verifiedFileAttachRpc = true;
        ws.send(JSON.stringify({ id: frame.id, result: { ok: true } }));
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

  // --- 测试用例 9: 生产 ChatViewModel 审批失败恢复与澄清交互 (严格区分 outer JSONRPC id 与 inner request_id) ---
  console.log('\n[TEST 9] 测试真实 ChatViewModel 审批交互、失败保留与重试闭环:');
  connectedClientWs.send(JSON.stringify({
    jsonrpc: '2.0',
    id: 'srq-mock-fail-001',
    method: 'approval',
    params: {
      session_id: activeRuntime,
      request_id: 'app_fail_once',
      tool_name: 'terminal',
      command: 'git push origin harmonyos/native-port',
      choices: ['once', 'session', 'always', 'deny']
    }
  }));
  await new Promise((r) => setTimeout(r, 100));

  assert(vm.currentApproval !== null, '当前会话的审批请求必须被挂载到 currentApproval');
  assert(vm.currentApproval.id === 'srq-mock-fail-001', '外层 JSON-RPC id 匹配');
  assert(vm.currentApproval.requestId === 'app_fail_once', '内层 params.request_id 匹配');
  assert(vm.currentApproval.command.includes('git push'), '审批命令匹配');
  assert(vm.currentApproval.choices.includes('once'), 'choices 必须包含 once');

  await vm.submitApproval('once');
  assert(vm.currentApproval !== null, '审批请求在服务端返回错误时必须保留在界面供用户重试，杜绝静默吞错！');

  vm.currentApproval.requestId = 'app_success_now';
  await vm.submitApproval('once');
  assert(vm.currentApproval === null, '审批成功后才彻底清除待审批状态');
  assert(serverStats.approvalResponded, '服务端已收到审批 respond 回执');
  console.log('[PASS 9] 审批失败保留重试与成功清理闭环通过');

  // --- 测试用例 10: 生产 ChatViewModel 真实模型切换 (config.set) ---
  console.log('\n[TEST 10] 测试真实 ChatViewModel 模型切换与 config.set RPC:');
  await vm.switchModel('claude-3-5-sonnet');
  assert(serverStats.configSetCalls === 1, '切换模型必须向网关发送 config.set RPC');
  assert(vm.currentModel === 'claude-3-5-sonnet', '模型切换成功更新 currentModel');
  console.log('[PASS 10] 真实模型切换契约通过');

  // --- 测试用例 11: 真实 HarmonyPlatformAuthAdapter + Preferences + AssetStoreKit 密文硬件保管库与异常传播测试 (落实 REVIEW_STORAGE_UTF8) ---
  console.log('\n[TEST 11] 测试真实 HarmonyPlatformAuthAdapter (UTF-8 中文/Emoji、Preferences 元数据 + AssetStoreKit 密文硬件保管库 + 原子回滚 + clearAll 物理擦除):');
  const authStore = AuthStore.getInstance();
  const mockContext = {};
  const platformAdapter = new HarmonyPlatformAuthAdapter(mockContext);
  authStore.setStorageAdapter(platformAdapter);

  // 初始化并等待准备就绪
  await authStore.init(mockContext);
  await authStore.waitUntilReady();

  // 保存连接：测试包含中文与Emoji的高难度敏感身份凭证 (严防 charCodeAt & 0xff 截断 Unicode)
  const unicodePassword = '中文安全密码_🔑2026!';
  const unicodeToken = 'jwt_安全Token_🚀_xyz';
  await authStore.saveConnection({
    id: 'conn_sec_1',
    name: '我的生产Hermes',
    url: 'https://hermes.example.com',
    username: 'admin',
    password: unicodePassword,
    token: unicodeToken,
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

  // 2. 断言敏感凭据必须物理进入 AssetStoreKit 硬件级密文保管库，且完整无损保留中文与 Emoji
  assert(mockAssetStorage.has('hermex_cred_conn_sec_1'), '敏感凭证必须保存到 AssetStoreKit (hermex_cred_conn_sec_1)');
  const assetSecretBytes = mockAssetStorage.get('hermex_cred_conn_sec_1');
  const assetSecretStr = HarmonyPlatformAuthAdapter.uint8ArrayToString(assetSecretBytes);
  assert(assetSecretStr.includes(unicodeToken), 'AssetStoreKit 包含真实的密文 Token (含中文与 Emoji)');
  assert(assetSecretStr.includes(unicodePassword), 'AssetStoreKit 包含真实的密文密码 (含中文与 Emoji)');

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

  // 4. 测试元数据落盘异常时的原子内存回滚保护
  console.log('  -> 测试元数据写入失败时的原子内存回滚...');
  mockPrefFailOnPut = true;
  let metaRollbackCaught = false;
  try {
    await authStore.saveConnection({
      id: 'conn_rollback_test',
      name: '应被回滚的连接',
      url: 'https://rollback.com',
      token: 'token_rb'
    });
  } catch (err) {
    metaRollbackCaught = true;
  }
  assert(metaRollbackCaught, 'Preferences 写入异常必须向上抛出');
  assert(authStore.getConnection('conn_rollback_test') === null, '元数据落盘失败后内存映射必须原子回滚，杜绝幽灵连接！');
  mockPrefFailOnPut = false;

  // 5. 测试真实冷启动恢复 (模拟杀进程重启，验证中文与 Emoji 完美还原)
  console.log('  -> 测试真实冷启动还原 (Preferences 元数据 + AssetStoreKit 凭据整合)...');
  const restartAdapter = new HarmonyPlatformAuthAdapter(mockContext);
  authStore.setStorageAdapter(restartAdapter);
  await authStore.init(mockContext);
  await authStore.waitUntilReady();

  const restoredConn = authStore.getCurrentConnection();
  assert(restoredConn !== null && restoredConn.name === '我的生产Hermes', '冷启动从 Preferences 恢复元数据');
  assert(restoredConn.token === unicodeToken, '冷启动从 AssetStoreKit 完美恢复中文与 Emoji Token');
  assert(restoredConn.password === unicodePassword, '冷启动从 AssetStoreKit 完美恢复中文与 Emoji 密码');

  // 6. 测试 clearAll 彻底物理擦除 Preferences 和 AssetStore
  console.log('  -> 测试 clearAll 彻底清除 Preferences 与 Asset 保管库...');
  await authStore.clearAll();
  assert(mockAssetStorage.size === 0, 'clearAll 后 AssetStoreKit 硬件保管库必须彻底擦除所有凭据！');
  assert(authStore.getConnections().length === 0, 'clearAll 后内存与配置全部清空');
  console.log('[PASS 11] 真实 HarmonyPlatformAuthAdapter UTF-8 (中文/Emoji) 与 AssetStoreKit 密文硬件保管库通过');

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

  // --- 测试用例 19: 生产 AttachmentUtils 动态 MIME 检测、图像识别与路径遍历防御 (落实 REVIEW_DEVICE_01) ---
  console.log('\n[TEST 19] 测试真实 AttachmentUtils 动态 MIME 判别、图像分流与穿越防御:');
  assert(getMimeType('photo.png') === 'image/png', 'PNG MIME 正确解析');
  assert(getMimeType('image.jpg') === 'image/jpeg', 'JPG MIME 正确解析');
  assert(getMimeType('banner.webp') === 'image/webp', 'WEBP MIME 正确解析');
  assert(getMimeType('report.pdf') === 'application/pdf', 'PDF MIME 正确解析');
  assert(getMimeType('main.ts') === 'text/plain', 'TypeScript 源码 MIME 正确解析');
  assert(getMimeType('config.json') === 'application/json', 'JSON MIME 正确解析');

  assert(isImageFile('avatar.png') === true, 'PNG 识别为图片');
  assert(isImageFile('photo.webp') === true, 'WEBP 识别为图片');
  assert(isImageFile('document.pdf') === false, 'PDF 绝不能被误判为图片');
  assert(isImageFile('script.py') === false, '代码文件绝不能被误判为图片');

  const dangerousPath = '../../etc/passwd';
  const cleanName = sanitizeFilename(dangerousPath);
  assert(!cleanName.includes('..') && !cleanName.includes('/'), '路径穿越符 ../ 必须被完全清洗');
  assert(cleanName.includes('passwd'), '基础文件名得以保留');

  const attachUuidName = generateAttachmentName('spec.pdf');
  assert(attachUuidName.endsWith('-spec.pdf'), '附件名称格式符合 UUID-filename 规范');
  assert(attachUuidName.length > 36, '附件名称包含完整的 UUID 随机前缀');
  console.log('[PASS 19] 生产 AttachmentUtils MIME分流与路径清洗通过');

  // --- 测试用例 20: 生产 Gateway RPC file.attach 协议闭环 (落实 REVIEW_DEVICE_01) ---
  console.log('\n[TEST 20] 测试真实 Gateway RPC file.attach 协议发送与 ChatViewModel.attachDocument:');
  assert(liveGw !== null, '活跃网关实例');
  const gw2 = new HermesGatewayClient({});
  await gw2.connect(baseUrl, ticket);
  const fileAttachRes = await gw2.fileAttach(activeRuntime, 'uuid-contract.pdf', 'data:application/pdf;base64,JVBERi0xLjQK');
  assert(serverStats.verifiedFileAttachRpc, '服务端成功收到真实 file.attach RPC 帧');
  assert(fileAttachRes.ok === true, 'file.attach 返回确认回执');

  const vmAttachRes = await vm.attachDocument('uuid-arch.pdf', 'data:application/pdf;base64,JVBERi0xLjQK');
  assert(vmAttachRes.ok === true, 'ChatViewModel.attachDocument 成功通过活跃会话网关附加');
  gw2.disconnect();
  console.log('[PASS 20] 真实 file.attach RPC 契约与 ChatViewModel 集成通过');

  // --- 测试用例 21: 生产 HermesProjectClient 与 GitWorkspaceViewModel (F06) ---
  console.log('\n[TEST 21] 测试真实 HermesProjectClient 与 GitWorkspaceViewModel 项目与 Git 分支操作:');
  const projects = await HermesProjectClient.getProjects(baseUrl, loginResult.token, loginResult.cookies);
  assert(projects.length === 1 && projects[0].name === 'HermexPort', '拉取项目列表成功');

  const gitRoot = await HermesProjectClient.resolveGitRoot(baseUrl, '/workspace/hermex', loginResult.token, loginResult.cookies);
  assert(gitRoot === '/workspace/hermex', 'Git 根目录解析正确');

  const gitStatus = await HermesProjectClient.getGitStatus(baseUrl, gitRoot, loginResult.token, loginResult.cookies);
  assert(gitStatus.branch === 'harmonyos/native-port', 'Git 分支匹配');
  assert(gitStatus.changed === 3, '改动文件数匹配');

  const branches = await HermesProjectClient.getGitBranches(baseUrl, gitRoot, loginResult.token, loginResult.cookies);
  assert(branches.length === 2, '拉取 2 个分支');
  assert(branches.some(b => b.name === 'harmonyos/native-port' && b.isCurrent), '当前分支标明 isCurrent');

  const switchOk = await HermesProjectClient.switchBranch(baseUrl, gitRoot, 'master', loginResult.token, loginResult.cookies);
  assert(switchOk, '切换分支成功');

  const gitVm = new GitWorkspaceViewModel();
  await gitVm.loadProjectsAndGit(botConn, '/workspace/hermex');
  assert(gitVm.projects.length === 1, 'ViewModel 项目加载成功');
  assert(gitVm.gitStatus !== null && gitVm.gitStatus.branch === 'harmonyos/native-port', 'ViewModel Git 状态加载成功');
  console.log('[PASS 21] 真实 HermesProjectClient 与 GitWorkspaceViewModel 通过');

  // --- 测试用例 22: 生产 HermesSkillsClient, HermesMemoryClient 与 SkillsViewModel (F09) ---
  console.log('\n[TEST 22] 测试真实 HermesSkillsClient, HermesMemoryClient 与 SkillsViewModel:');
  const skillsList = await HermesSkillsClient.getSkills(baseUrl, 'default', loginResult.token, loginResult.cookies);
  assert(skillsList.length === 2, '拉取到 2 个技能');
  assert(skillsList[0].name === 'code_reviewer' && skillsList[0].enabled === true, '技能状态匹配');

  const toggleSkillOk = await HermesSkillsClient.toggleSkill(baseUrl, 'default', 'code_reviewer', false, loginResult.token, loginResult.cookies);
  assert(toggleSkillOk, '切换技能状态成功');

  const soulText = await HermesMemoryClient.getSoul(baseUrl, 'default', loginResult.token, loginResult.cookies);
  assert(soulText.includes('ArkTS assistant'), '读取 Soul 成功');

  const saveSoulOk = await HermesMemoryClient.saveSoul(baseUrl, 'default', 'New Soul Text', loginResult.token, loginResult.cookies);
  assert(saveSoulOk, '保存 Soul 成功');

  const skillsVm = new SkillsViewModel();
  await skillsVm.loadSkillsAndMemory(botConn);
  assert(skillsVm.skills.length === 2, 'SkillsViewModel 加载技能成功');
  assert(skillsVm.soulText.length > 0, 'SkillsViewModel 加载 Soul 成功');
  console.log('[PASS 22] 真实 HermesSkillsClient, HermesMemoryClient 与 SkillsViewModel 通过');

  // --- 测试用例 23: 生产 HermesKanbanClient 看板服务契约 (F11) ---
  console.log('\n[TEST 23] 测试真实 HermesKanbanClient 看板配置、看板列表与快照:');
  const kanbanAvailable = await HermesKanbanClient.isAvailable(baseUrl, loginResult.token, loginResult.cookies);
  assert(kanbanAvailable, '看板服务可用性探针通过');

  const kanbanBoards = await HermesKanbanClient.getBoards(baseUrl, loginResult.token, loginResult.cookies);
  assert(kanbanBoards.boards.length === 1 && kanbanBoards.boards[0].slug === 'sprint-board-1', '拉取看板列表成功');

  const boardSnapshot = await HermesKanbanClient.getBoard(baseUrl, 'sprint-board-1', loginResult.token, loginResult.cookies);
  assert(boardSnapshot !== null && boardSnapshot.boardName === 'sprint-board-1', '看板名称匹配');
  assert(boardSnapshot.columns.length === 1, '看板列数匹配');
  assert(boardSnapshot.columns[0].cards.length === 1 && boardSnapshot.columns[0].cards[0].title.includes('HarmonyOS 原生移植'), '卡片标题匹配');
  console.log('[PASS 23] 真实 HermesKanbanClient 看板服务契约通过');

  // --- 测试用例 24: 真实隔离 Hermes 0.21.5 实例 (127.0.0.1:9199) 全链路联调与审批往返闭环 ---
  console.log('\n[TEST 24] 测试真实隔离 Hermes 0.21.5 实例 (127.0.0.1:9199) 生产 ChatViewModel 中文消息→工具审批→执行→终态回复→历史回填:');
  const realUrl = 'http://127.0.0.1:9199';
  try {
    const status = await HermesRESTClient.getStatus(realUrl);
    assert(status.version === '0.21.5', `真实后端版本匹配: ${status.version}`);
    assert(status.auth_required === true, '真实后端要求认证');

    const realLogin = await HermesRESTClient.login(realUrl, 'hermex', 'hermex-local');
    assert(realLogin.cookies && realLogin.cookies.includes('hermes_session_at'), '真实登录成功并提取 Cookie');

    const realConn = {
      id: 'real_conn_9199',
      name: 'Isolated 9199',
      url: realUrl,
      username: 'hermex',
      password: 'hermex-local',
      token: realLogin.token,
      cookies: realLogin.cookies,
      activeProfile: 'default'
    };

    const realVm = new ChatViewModel();
    let stateChangedCount = 0;
    realVm.setListener({
      onStateChanged: () => {
        stateChangedCount++;
      }
    });

    // 1. 初始化并新建真实会话
    await realVm.attachSession(realConn, '');
    assert(realVm.isConnected, '网关握手与认证就绪');

    const createdSessionId = await realVm.createAndAttachNewSession(realConn, '/tmp');
    assert(createdSessionId && createdSessionId.length > 5, `真实服务端会话创建成功: ${createdSessionId}`);
    assert(realVm.getRuntimeSessionId() && realVm.getRuntimeSessionId().length > 0, `运行时 runtime ID 就绪: ${realVm.getRuntimeSessionId()}`);

    // 2. 发送中文测试消息触发 terminal 工具调用
    await realVm.sendMessage('手机验收：请执行固定测试检查');
    assert(realVm.isGenerating === true, '发送后进入生成状态');

    // 3. 等待服务端推流与审批请求
    const approvalStart = Date.now();
    while (!realVm.currentApproval && Date.now() - approvalStart < 15000) {
      await new Promise((r) => setTimeout(r, 100));
    }
    assert(realVm.currentApproval !== null, '必须收到服务端 approval 请求');
    assert(realVm.currentApproval.command && realVm.currentApproval.command.includes('print(1)'), `审批命令匹配: ${realVm.currentApproval.command}`);
    assert(realVm.currentApproval.choices && realVm.currentApproval.choices.includes('once'), '审批选项必须包含 once');
    assert(realVm.currentApproval.requestId && realVm.currentApproval.requestId.length > 0, '审批请求必须包含内部 requestId');

    // 4. 提交允许一次 ('once')
    await realVm.submitApproval('once');
    assert(realVm.currentApproval === null, '审批提交后清除当前审批弹窗');

    // 5. 等待生成完成与工具输出落地
    const completeStart = Date.now();
    while (realVm.isGenerating && Date.now() - completeStart < 15000) {
      await new Promise((r) => setTimeout(r, 100));
    }
    assert(!realVm.isGenerating, '工具执行完成后会话状态恢复空闲 (!isGenerating)');

    const astMsg = realVm.messages.find((m) => m.role === 'assistant');
    assert(astMsg !== undefined, '必须产生 assistant 消息');
    assert(astMsg.content.includes('1'), `终态内容必须包含命令输出结果，当前为: ${astMsg.content}`);
    assert(astMsg.toolCalls && astMsg.toolCalls.length > 0, '必须包含 terminal 工具调用记录');
    assert(astMsg.toolCalls[0].status === 'completed', '工具执行状态必须为 completed');

    // 6. 验证重连历史回填一致性
    realVm.disconnect();
    const reconnectVm = new ChatViewModel();
    await reconnectVm.attachSession(realConn, createdSessionId);
    assert(reconnectVm.isConnected, '重连会话成功');
    assert(reconnectVm.messages.length >= 2, `重连历史回填消息条数一致，当前: ${reconnectVm.messages.length}`);
    assert(reconnectVm.messages.some((m) => m.role === 'user' && m.content.includes('手机验收')), '历史消息包含用户输入');
    reconnectVm.disconnect();

    console.log('[PASS 24] 真实隔离 Hermes 0.21.5 (127.0.0.1:9199) 全链路端到端审批交互与历史重连通过');
  } catch (err) {
    console.error('[FAIL 24] 真实隔离 Hermes 0.21.5 联调失败:', err);
    throw err;
  }

  // --- 测试用例 25: 严格在上游标准录制 Fixture (turn-tool-approval-frames.json) 上验证审批与正文流式状态机 ---
  console.log('\n[TEST 25] 严格在 turn-tool-approval-frames.json 录制帧上验证审批与正文流式状态机:');
  const fixturePath = path.resolve(rootDir, '../HermesMobileTests/Fixtures/HermesAgent/turn-tool-approval-frames.json');
  const fixtureData = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  const frames = fixtureData.frames;

  let fixtureApprovalSent = null;
  const fixtureGwCallbacks = {
    onConnected: () => {},
    onDisconnected: () => {}
  };
  const fixtureGw = new HermesGatewayClient(fixtureGwCallbacks);
  fixtureGw.ws = {
    send: (dataStr, cb) => {
      const parsed = JSON.parse(dataStr);
      if (parsed.method === 'approval.respond') {
        fixtureApprovalSent = parsed;
        setTimeout(() => {
          fixtureGw.handleFrame({ jsonrpc: '2.0', id: parsed.id, result: { resolved: 1 } }, () => {});
        }, 10);
      }
      if (cb) cb(null, true);
    }
  };
  fixtureGw.isConnected = true;
  fixtureGw.activeRuntimeId = '7dd4dff2';

  let approvalReceivedByVm = null;
  let interimReceivedByVm = null;
  let toolCompleteReceivedByVm = false;
  let messageCompleteReceivedByVm = false;

  fixtureGw.callbacks = {
    onApprovalRequest: (req) => {
      approvalReceivedByVm = req;
    },
    onMessageInterim: (sid, text) => {
      interimReceivedByVm = text;
    },
    onToolComplete: (sid, tool) => {
      toolCompleteReceivedByVm = true;
    },
    onMessageComplete: (sid, text) => {
      messageCompleteReceivedByVm = true;
    }
  };

  for (const frame of frames) {
    if (frame.method === 'event') {
      const type = frame.params.type;
      const payload = frame.params.payload || {};
      fixtureGw.dispatchRuntimeEvent(type, frame.params, payload);
    } else if (frame.method === 'approval') {
      fixtureGw.handleServerRequest(frame.id, frame.method, frame.params);
    }
  }

  assert(approvalReceivedByVm !== null, '必须解析 fixture 中的 approval 帧');
  assert(approvalReceivedByVm.id === 'srq-627297cd2bb0', '外层 JSON-RPC id 匹配');
  assert(approvalReceivedByVm.requestId === '850a0a9d32c448c2b4b9bc34503f5812', '内层 params.request_id 匹配');
  assert(approvalReceivedByVm.command === 'python3 -c "print(1)"', 'command 匹配');
  assert(approvalReceivedByVm.choices.includes('once'), 'choices 包含 once');

  await fixtureGw.respondApproval('7dd4dff2', approvalReceivedByVm.requestId, 'once');
  assert(fixtureApprovalSent !== null, '已发出 approval.respond 帧');
  assert(fixtureApprovalSent.params.session_id === '7dd4dff2', 'session_id 匹配');
  assert(fixtureApprovalSent.params.request_id === '850a0a9d32c448c2b4b9bc34503f5812', 'request_id 匹配');
  assert(fixtureApprovalSent.params.choice === 'once', 'choice 匹配 once');
  assert(interimReceivedByVm !== null, 'interim 必须接收正文');
  assert(toolCompleteReceivedByVm, 'tool.complete 必须接收');
  assert(messageCompleteReceivedByVm, 'message.complete 必须接收');
  console.log('[PASS 25] 严格 turn-tool-approval-frames.json 录制帧状态机验证通过');

  // [TEST 26] 测试 ChatViewModel 异步审批竞争、生命周期与会话切换状态隔离
  console.log('\n[TEST 26] 测试 ChatViewModel 异步审批竞争、生命周期与会话切换状态隔离:');
  const isolatedVm = new ChatViewModel();
  let approvalResolve = null;
  const mockGatewayForApproval = {
    respondApproval: async (sessionId, requestId, choice) => {
      return new Promise((resolve) => {
        approvalResolve = () => resolve({ ok: true });
      });
    },
    disconnect: () => {}
  };
  isolatedVm.gateway = mockGatewayForApproval;
  isolatedVm.isConnected = true;
  isolatedVm.runtimeSessionId = 'test-session-1';
  isolatedVm.sessionAttachGeneration = 1;

  // 1. 设置初始审批请求
  isolatedVm.currentApproval = {
    id: 'srq-1',
    requestId: 'req-uuid-1',
    sessionId: 'test-session-1',
    toolName: 'terminal',
    command: 'ls',
    choices: ['once', 'deny']
  };

  // 2. 触发异步提交审批 (RPC 挂起中)
  const submitPromise = isolatedVm.submitApproval('once');
  assert(isolatedVm.isSubmittingApproval === true, '审批提交中标记必须为 true');

  // 3. 在 RPC 在途期间，推入新审批请求 (例如后续并发审批)
  isolatedVm.currentApproval = {
    id: 'srq-2',
    requestId: 'req-uuid-2',
    sessionId: 'test-session-1',
    toolName: 'terminal',
    command: 'git status',
    choices: ['once', 'deny']
  };

  // 4. 前一个 RPC 完成返回
  approvalResolve();
  await submitPromise;

  // 5. 校验：不能冲掉新审批
  assert(isolatedVm.currentApproval !== null, '新到达的审批请求绝不可被前一个 RPC 的完成清除');
  assert(isolatedVm.currentApproval.requestId === 'req-uuid-2', '当前审批必须保留为 req-uuid-2');
  assert(isolatedVm.isSubmittingApproval === false, '审批提交状态恢复为 false');

  // 6. 测试会话切换代次保护：在途提交时切断连接
  const submitPromise2 = isolatedVm.submitApproval('once');
  isolatedVm.disconnect();
  approvalResolve();
  await submitPromise2;
  assert(isolatedVm.currentApproval === null, '断开连接后审批已清空');

  // 7. 测试连续同名工具执行：A 工具晚完成绝不误清 B 工具的新审批 (落实 REVIEW_SCOPE_12)
  console.log('  -> 测试连续同名工具场景: 工具 A 晚到完成不误清工具 B 的审批...');
  isolatedVm.currentApproval = {
    id: 'srq-b',
    requestId: 'req-uuid-b',
    sessionId: 'test-session-1',
    toolName: 'terminal',
    command: 'python3 -c "print(2)"',
    choices: ['once', 'deny']
  };

  // 工具 A (terminal) 滞后完成返回
  const toolAComplete = {
    id: 'tool-a',
    name: 'terminal',
    status: 'completed'
  };
  // 模拟 gateway 回调 onToolComplete
  if (isolatedVm.callbacks && isolatedVm.callbacks.onToolComplete) {
    isolatedVm.callbacks.onToolComplete('test-session-1', toolAComplete);
  }
  assert(isolatedVm.currentApproval !== null, '工具 A 完成绝不可按工具名误清工具 B 的当前审批');
  assert(isolatedVm.currentApproval.requestId === 'req-uuid-b', '当前审批仍严格保留为工具 B (req-uuid-b)');

  console.log('[PASS 26] ChatViewModel 异步审批竞争、代次保护与连续同名工具防误清测试通过');

  // [TEST 27] 测试 HermesKanbanClient 与 KanbanViewModel 看板完整生命周期
  console.log('\n[TEST 27] 测试 HermesKanbanClient 与 KanbanViewModel 看板完整生命周期:');
  let lastTaskCreateMethod = null;
  let lastTaskUpdateMethod = null;
  let lastKanbanUrl = null;
  let lastKanbanBody = null;
  let configStatusToReturn = 200;

  const kanbanServer = http.createServer((req, res) => {
    lastKanbanUrl = req.url;
    const parsed = new URL(req.url, 'http://127.0.0.1');

    if (parsed.pathname === '/api/plugins/kanban/config') {
      if (configStatusToReturn === 401) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Unauthorized' }));
      } else if (configStatusToReturn === 404) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Not Found' }));
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ enabled: true, version: '1.0' }));
      }
    } else if (parsed.pathname === '/api/plugins/kanban/boards') {
      // 严格对齐 upstream Kanban.swift:439: { boards: [{ slug, name, ... }], current, readOnly }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        boards: [
          { slug: 'sprint-1', name: 'Sprint 1', description: 'Main sprint', readOnly: false },
          { slug: 'backlog', name: 'Backlog Archive', description: 'Read only archive', readOnly: true }
        ],
        current: 'sprint-1',
        readOnly: false
      }));
    } else if (parsed.pathname === '/api/plugins/kanban/board') {
      const b = parsed.searchParams.get('board');
      const isBacklog = b === 'backlog';
      res.writeHead(200, { 'Content-Type': 'application/json' });
      // 严格对齐 upstream Kanban.swift:506: latestEventId 驼峰整型
      res.end(JSON.stringify({
        name: isBacklog ? 'Backlog Archive' : 'Sprint 1',
        columns: [
          { name: 'To Do', cards: [{ id: 'card-1', title: 'Task 1', status: 'To Do' }] },
          { name: 'Done', cards: [] }
        ],
        latestEventId: 101,
        readOnly: isBacklog
      }));
    } else if (parsed.pathname === '/api/plugins/kanban/tasks' && req.method === 'POST') {
      lastTaskCreateMethod = req.method;
      let bodyStr = '';
      req.on('data', chunk => { bodyStr += chunk; });
      req.on('end', () => {
        lastKanbanBody = JSON.parse(bodyStr || '{}');
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, id: 'card-2' }));
      });
    } else if (parsed.pathname.startsWith('/api/plugins/kanban/tasks/')) {
      lastTaskUpdateMethod = req.method;
      // 严格断言必须是 PATCH 动词！如果是 POST 或其他方法，直接 405 Method Not Allowed！
      if (req.method !== 'PATCH') {
        res.writeHead(405, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: `Method ${req.method} not allowed, expected PATCH` }));
        return;
      }
      let bodyStr = '';
      req.on('data', chunk => { bodyStr += chunk; });
      req.on('end', () => {
        lastKanbanBody = JSON.parse(bodyStr || '{}');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      });
    } else {
      res.writeHead(404);
      res.end();
    }
  });

  const kanbanPort = await new Promise((r) => kanbanServer.listen(0, '127.0.0.1', () => r(kanbanServer.address().port)));
  const kanbanConn = {
    url: `http://127.0.0.1:${kanbanPort}`,
    token: 'test-token',
    cookies: 'session=abc'
  };

  // 1. 测试 401 鉴权失效与 404 插件未安装的精准区分 (杜绝盲目硬编码 404)
  configStatusToReturn = 401;
  const avail401 = await HermesKanbanClient.checkAvailability(kanbanConn.url, kanbanConn.token);
  assert(avail401.available === false && avail401.status === 'unauthorized', '401 必须准确报告 unauthorized 状态');
  assert(avail401.message.includes('401'), '401 提示信息必须准确展示 HTTP 401');

  configStatusToReturn = 404;
  const avail404 = await HermesKanbanClient.checkAvailability(kanbanConn.url, kanbanConn.token);
  assert(avail404.available === false && avail404.status === 'not_installed', '404 必须准确报告 not_installed 状态');
  assert(avail404.message.includes('404'), '404 提示信息展示未安装');

  // 2. 正常就绪与加载对象包装的看板列表
  configStatusToReturn = 200;
  const kanbanVm = new KanbanViewModel();
  await kanbanVm.loadBoards(kanbanConn);
  assert(kanbanVm.isAvailable === true, '看板插件可用');
  assert(kanbanVm.boards.length === 2, '成功解析对象包装中的 2 个看板条目');
  assert(kanbanVm.boards[0].slug === 'sprint-1' && kanbanVm.boards[0].name === 'Sprint 1', '区分 slug 与 name');
  assert(kanbanVm.selectedBoardSlug === 'sprint-1', '默认选中当前看板 slug');
  assert(kanbanVm.currentSnapshot !== null, '成功加载看板快照');
  assert(kanbanVm.currentSnapshot.latestEventId === 101, 'latestEventId 驼峰整型事件游标正确解析');
  assert(kanbanVm.isReadOnly === false, '当前 sprint-1 为可写看板');

  // 3. 在可写看板创建新卡片 (POST)
  const createOk = await kanbanVm.createCard(kanbanConn, 'New Card', 'Description');
  assert(createOk === true, '卡片创建成功');
  assert(lastTaskCreateMethod === 'POST', '新建卡片发送 POST');

  // 4. 更新卡片状态 (严格断言 PATCH 动词！)
  const updateOk = await kanbanVm.updateCardStatus(kanbanConn, 'card-1', 'Done');
  assert(updateOk === true, '卡片状态更新成功');
  assert(lastTaskUpdateMethod === 'PATCH', `更新卡片状态必须使用 PATCH 动词 (当前实际收到: ${lastTaskUpdateMethod})`);
  assert(lastKanbanBody && lastKanbanBody.status === 'Done', 'PATCH 请求携带 { status: "Done" }');

  // 5. 切换到只读看板并验证只读写保护
  await kanbanVm.loadBoardSnapshot(kanbanConn, 'backlog');
  assert(kanbanVm.isReadOnly === true, 'backlog 看板标记为只读');
  const writeRejectedInRo = await kanbanVm.createCard(kanbanConn, 'Blocked Card');
  assert(writeRejectedInRo === false, '只读看板禁止创建卡片');
  const updateRejectedInRo = await kanbanVm.updateCardStatus(kanbanConn, 'card-1', 'To Do');
  assert(updateRejectedInRo === false, '只读看板禁止更新卡片状态');

  kanbanServer.close();
  console.log('[PASS 27] HermesKanbanClient 与 KanbanViewModel PATCH动词、对象包装、游标与只读保护测试通过');

  // [TEST 28] 测试 NotificationUtils 系统通知分发与跨平台降级
  console.log('\n[TEST 28] 测试 NotificationUtils 系统通知分发与跨平台降级:');
  const notifAvail = await NotificationUtils.isNotificationEnabled();
  assert(typeof notifAvail === 'boolean', '通知可用性检查返回布尔值');

  const pubOk = await NotificationUtils.publishNotification('测试通知', '内容明细');
  assert(pubOk === true, '基础通知分发成功');

  await NotificationUtils.notifyApprovalRequired('python3 -c "print(1)"', 'terminal');
  await NotificationUtils.notifyTurnComplete('任务处理完毕');
  await NotificationUtils.cancelNotification(2001);
  console.log('[PASS 28] NotificationUtils 系统通知与后台提示测试通过');

  // [TEST 29] 测试 LegacySSEClient 完整聊天轮次与跨数据块分帧解析 (F12)
  console.log('\n[TEST 29] 测试 LegacySSEClient 完整聊天轮次、取消与跨网络块 SSE 帧拼接:');
  let legacyCancelReceived = false;
  const legacyServer = http.createServer((req, res) => {
    const parsed = new URL(req.url, 'http://127.0.0.1');
    if (parsed.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok' }));
    } else if (parsed.pathname === '/api/chat/start' && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ stream_id: 'str_legacy_test_1' }));
    } else if (parsed.pathname === '/api/chat/cancel') {
      assert(req.method === 'GET', `cancelChatTurn 必须使用 GET 请求，实际为: ${req.method}`);
      assert(parsed.searchParams.get('stream_id') === 'str_legacy_test_1', '必须携带 stream_id 查询参数');
      legacyCancelReceived = true;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    } else if (parsed.pathname === '/api/chat/stream') {
      const sid = parsed.searchParams.get('stream_id');
      if (sid === 'str_error_401') {
        res.writeHead(401, { 'Content-Type': 'text/plain' });
        res.end('Unauthorized');
        return;
      }
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive'
      });
      // 严格测试持续 TextDecoder 处理跨数据块中文字节拆分：
      // '你好' 字节 [0xe4, 0xbd, 0xa0, 0xe5, 0xa5, 0xbd]
      // 第一块包含到 [0xe5, 0xa5]，第二块以 [0xbd] 开头，验证持续 Decoder 不损坏多字节字符
      const prefix = Buffer.from('event: token\ndata: {"text": "');
      const bNi = Buffer.from('你', 'utf8'); // 3 bytes
      const bHao = Buffer.from('好', 'utf8'); // 3 bytes: e5 a5 bd
      const part1 = Buffer.concat([prefix, bNi, bHao.subarray(0, 2)]);
      const part2 = Buffer.concat([bHao.subarray(2), Buffer.from(' 鸿蒙"}\n\nevent: done\ndata: {}\n\n')]);

      res.write(part1);
      setTimeout(() => {
        res.write(part2);
        res.end();
      }, 30);
    } else if (parsed.pathname === '/api/sessions') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify([
        { id: 'leg_sess_1', title: 'Legacy Conversation 1', updated_at: 1700000000 }
      ]));
    } else if (parsed.pathname === '/api/session') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        id: 'leg_sess_1',
        title: 'Legacy Conversation 1',
        messages: [
          { role: 'user', content: 'hello from legacy' },
          { role: 'assistant', content: 'hello response' }
        ]
      }));
    } else {
      res.writeHead(404);
      res.end();
    }
  });

  const legacyPort = await new Promise((r) => legacyServer.listen(0, '127.0.0.1', () => r(legacyServer.address().port)));
  const legacyBaseUrl = `http://127.0.0.1:${legacyPort}`;

  // 1. 健康探测
  const legHealth = await LegacySSEClient.probeHealth(legacyBaseUrl);
  assert(legHealth === true, 'Legacy /health 探测通过');

  // 2. 开启聊天轮次
  const startTurn = await LegacySSEClient.startChatTurn(legacyBaseUrl, 'leg_sess_1', 'hello from legacy');
  assert(startTurn !== null && startTurn.streamId === 'str_legacy_test_1', '开启聊天轮次获取 streamId');

  // 3. 取消聊天轮次
  const cancelTurn = await LegacySSEClient.cancelChatTurn(legacyBaseUrl, 'str_legacy_test_1');
  assert(cancelTurn === true && legacyCancelReceived, '取消聊天轮次成功');

  // 4. 建立 SSE 流并验证跨块拼帧
  const receivedSseEvents = [];
  await new Promise((resolve) => {
    LegacySSEClient.connectSSEStream(legacyBaseUrl, 'str_legacy_test_1', {
      onEvent: (ev) => {
        receivedSseEvents.push(ev);
      },
      onError: (_err) => {},
      onClose: () => {
        resolve();
      }
    });
  });

  assert(receivedSseEvents.length === 2, `跨分块解析必须精准产出 2 个完整帧，当前: ${receivedSseEvents.length}`);
  assert(receivedSseEvents[0].event === 'token', '第一帧事件为 token');
  assert(receivedSseEvents[0].data.includes('你好 鸿蒙'), '跨网络数据块切割多字节中文字符后经持续解码器拼装无乱码');
  assert(receivedSseEvents[1].event === 'done', '第二帧事件为 done');

  // 5. 验证非 200 HTTP 响应 (如 401/403/500) 触发 onError 与优雅清理
  let sseErrorTriggered = false;
  await new Promise((resolve) => {
    LegacySSEClient.connectSSEStream(legacyBaseUrl, 'str_error_401', {
      onEvent: () => {},
      onError: (err) => {
        sseErrorTriggered = true;
        assert(err.includes('401'), `错误信息必须包含状态码 401: ${err}`);
      },
      onClose: () => {
        resolve();
      }
    });
  });
  assert(sseErrorTriggered === true, 'SSE 遇到 401 必须触发 onError 回调');

  // 6. 拉取会话列表与会话详情
  const legSessions = await LegacySSEClient.listSessions(legacyBaseUrl);
  assert(legSessions.length === 1 && legSessions[0].id === 'leg_sess_1', '拉取 legacy 会话列表成功');

  const legDetail = await LegacySSEClient.getSession(legacyBaseUrl, 'leg_sess_1');
  assert(legDetail !== null && legDetail.messages.length === 2, '拉取 legacy 会话详情成功');
  assert(legDetail.messages[0].role === 'user', '角色映射正确');

  legacyServer.close();
  console.log('[PASS 29] LegacySSEClient 完整轮次、取消、跨块分帧与会话拉取测试通过');

  // [TEST 30] 测试 DeepLinkUtils、AppDeepLinkRouter 与 ShareUtils 平台集成 (F10)
  console.log('\n[TEST 30] 测试 DeepLinkUtils 深链解析、路由分发与 ShareUtils 系统分享 Want 解析:');

  // 1. 测试会话深链解析
  const sRoute = DeepLinkUtils.parseDeepLink('hermex://session?id=s-9988&server=http://127.0.0.1:9199&profile=default');
  assert(sRoute !== null && sRoute.type === 'session', '会话深链类型解析');
  assert(sRoute.sessionId === 's-9988', '会话 ID 提取');
  assert(sRoute.server === 'http://127.0.0.1:9199', '服务器 URL 提取');
  assert(sRoute.profile === 'default', 'Profile 提取');

  // 2. 测试新建会话深链
  const ncRoute = DeepLinkUtils.parseDeepLink('hermes-agent://new-chat');
  assert(ncRoute !== null && ncRoute.type === 'new_chat' && ncRoute.autoStartsVoice === false, '新会话深链解析');

  // 3. 测试语音新会话深链
  const ncvRoute = DeepLinkUtils.parseDeepLink('hermex://new-chat-voice');
  assert(ncvRoute !== null && ncvRoute.type === 'new_chat' && ncvRoute.autoStartsVoice === true, '语音新会话深链解析');

  // 4. 测试特定 Profile 新会话深链
  const ncpRoute = DeepLinkUtils.parseDeepLink('hermex://new-chat-profile?profile=mobile-expert&server=http://127.0.0.1:9199');
  assert(ncpRoute !== null && ncpRoute.type === 'new_chat_profile', 'Profile 新会话深链解析');
  assert(ncpRoute.profile === 'mobile-expert', 'Profile 名称提取');

  // 5. 测试 Bot 深链
  const botRoute = DeepLinkUtils.parseDeepLink('hermex://bot?server=http://srv1&connection=conn1&profile=p1');
  assert(botRoute !== null && botRoute.type === 'bot' && botRoute.connection === 'conn1', 'Bot 深链解析');

  // 6. 测试非法链接安全过滤
  assert(DeepLinkUtils.parseDeepLink('unknown://session?id=123') === null, '非法 scheme 拒绝');
  assert(DeepLinkUtils.parseDeepLink('hermex://invalid-host') === null, '非法 host 拒绝');
  assert(DeepLinkUtils.parseDeepLink('hermex://session') === null, '无 id 的 session 链接拒绝');

  // 7. 测试深链 URL 构建器
  const builtSessionUrl = DeepLinkUtils.buildSessionUrl('sess-xyz', 'http://srv1', 'default');
  assert(builtSessionUrl.startsWith('hermex://session?id=sess-xyz'), '构建会话 URL 格式正确');

  // 8. 测试 AppDeepLinkRouter 单例状态、冷启动挂起消费与热启动监听分发
  const router = AppDeepLinkRouter.getInstance();

  // (a) 冷启动场景：无活跃 UI 监听器，路由进入挂起队列，通过 consumePendingRoute 一次性消费
  router.setPendingRoute(sRoute);
  const consumedRoute = router.consumePendingRoute();
  assert(consumedRoute !== null && consumedRoute.sessionId === 's-9988', '冷启动挂起深链消费成功');
  assert(router.consumePendingRoute() === null, '消费后挂起队列清空，防止二次重复消费');

  // (b) 热启动场景：存在活跃 UI 监听器，路由直接分发至监听器，挂起队列保持清洁
  let routedEvent = null;
  const routeListener = (r) => { routedEvent = r; };
  router.addRouteListener(routeListener);
  router.setPendingRoute(ncRoute);
  assert(routedEvent !== null && routedEvent.type === 'new_chat', '热启动深链即时通知活跃监听器');
  assert(router.consumePendingRoute() === null, '已分发至监听器的路由不滞留于挂起队列');
  router.removeRouteListener(routeListener);

  // (c) 系统分享冷启动与热启动分发
  const testShareData = { text: '冷启动分享', uri: 'file://test.txt' };
  router.setPendingShare(testShareData);
  const consumedShare = router.consumePendingShare();
  assert(consumedShare !== null && consumedShare.text === '冷启动分享', '冷启动挂起系统分享消费成功');
  assert(router.consumePendingShare() === null, '消费后挂起分享清空');

  let liveShareEvent = null;
  const shareListener = (s) => { liveShareEvent = s; };
  router.addShareListener(shareListener);
  router.setPendingShare({ text: '热启动分享' });
  assert(liveShareEvent !== null && liveShareEvent.text === '热启动分享', '热启动系统分享即时通知监听器');
  assert(router.consumePendingShare() === null, '已分发至监听器的分享不滞留于挂起队列');
  router.removeShareListener(shareListener);

  // 9. 测试 ShareUtils 外部传入 Want 解析与外发系统分享
  const platformUiContext = {
    applicationInfo: { accessTokenId: 1001 },
    startAbility: async () => true
  };

  const textShareOk = await ShareUtils.shareText(platformUiContext, '测试分享会话正文', '会话标题');
  assert(textShareOk === true, 'ShareUtils 调起系统分享文本成功');

  const fileShareOk = await ShareUtils.shareFile(platformUiContext, 'file:///data/storage/el2/base/test.png', 'image/png');
  assert(fileShareOk === true, 'ShareUtils 调起系统分享文件成功');

  const textWant = {
    action: 'ohos.want.action.sendData',
    type: 'text/plain',
    parameters: {
      'content': '通过系统分享发送的代码草稿'
    }
  };
  const parsedShareText = ShareUtils.parseShareWant(textWant);
  assert(parsedShareText !== null && parsedShareText.text.includes('代码草稿'), '系统分享文本解析正确');

  const fileWant = {
    action: 'ohos.want.action.sendData',
    type: 'image/png',
    uri: 'file://docs/storage/Users/currentUser/photo.png'
  };
  const parsedShareFile = ShareUtils.parseShareWant(fileWant);
  assert(parsedShareFile !== null && parsedShareFile.uri.includes('photo.png'), '系统分享文件 URI 解析正确');

  assert(ShareUtils.parseShareWant({ action: 'other.action' }) === null, '非系统分享 action 安全忽略');

  // 10. 测试 VoiceUtils 真实 AVRecorder/AVPlayer 状态机、落盘与录音安全门禁
  const micPermOk = await VoiceUtils.checkMicrophonePermission(platformUiContext);
  assert(micPermOk === true, 'VoiceUtils 麦克风权限请求通过');

  assert(VoiceUtils.isRecording() === false, '初始无录音');
  const tempAudioFile = path.join(require('os').tmpdir(), `test_voice_${Date.now()}.m4a`);
  const startRecOk = await VoiceUtils.startRecording(tempAudioFile);
  assert(startRecOk === true && VoiceUtils.isRecording() === true, '录音启动成功并配置 AVRecorder fd 真实绑定');

  const stoppedPath = await VoiceUtils.stopRecording();
  assert(stoppedPath === tempAudioFile && VoiceUtils.isRecording() === false, '录音停止并完成真实文件落盘');
  assert(fs.existsSync(stoppedPath) && fs.statSync(stoppedPath).size > 0, '录制音频文件实际存在且 size > 0');

  // 验证 AVPlayer 播放状态机
  let playStarted = false;
  let playCompleted = false;
  const playOk = await VoiceUtils.playAudio(stoppedPath, {
    onStart: () => { playStarted = true; },
    onComplete: () => { playCompleted = true; }
  });
  assert(playOk === true, 'VoiceUtils 启动 AVPlayer 播放');
  assert(playStarted === true, '触发 onStart 播放回调');
  assert(VoiceUtils.isPlaying() === true, 'isPlaying 标记正在播放');

  await VoiceUtils.stopAudio();
  assert(VoiceUtils.isPlaying() === false, 'stopAudio 后停止播放并释放原生资源');

  console.log('[PASS 30] DeepLinkUtils、AppDeepLinkRouter、ShareUtils 与 VoiceUtils 平台集成测试通过');

  // --- 测试用例 31: 真实服务端证据与通用历史归一化 (HermesHistoryNormalizer) ---
  console.log('\n[TEST 31] 测试真实服务端证据 run15-server-evidence.json 与多工具/乱序/失败/非JSON场景历史归一化:');
  {
    // 1. 读取真实隔离服务证据 fixture: run15-server-evidence.json
    let evidenceFixturePath = path.resolve(__dirname, '../../../hermex-supervision/run15-server-evidence.json');
    if (!fs.existsSync(evidenceFixturePath)) {
      evidenceFixturePath = path.resolve(__dirname, 'fixtures/run15-server-evidence.json');
    }
    assert(fs.existsSync(evidenceFixturePath), 'run15-server-evidence.json 存在');
    const fixtureData = JSON.parse(fs.readFileSync(evidenceFixturePath, 'utf8'));

    const normalizedFromFixture = HermesHistoryNormalizer.normalize(fixtureData.messages);
    console.log(`  -> 真实证据 ${fixtureData.messages.length} 行原始消息归一化为 ${normalizedFromFixture.length} 条结构化消息`);

    // 断言 1: 消息数量与角色
    assert(normalizedFromFixture.length >= 2, '至少包含用户与助手消息');
    const userMsg = normalizedFromFixture.find(m => m.role === 'user');
    assert(userMsg && userMsg.content.includes(fixtureData.prompt_marker), '用户消息包含唯一标记 prompt');

    const astFinalMsg = normalizedFromFixture.find(m => m.role === 'assistant' && m.content.includes('The command returned: 1.'));
    assert(astFinalMsg, '助手终态回复包含 "The command returned: 1."');

    // 断言 2: tool 角色绝不可伪装为助手独立消息气泡，且不能有整段 raw JSON 气泡
    const toolAsMsg = normalizedFromFixture.filter(m => m.role === 'tool');
    assert(toolAsMsg.length === 0, 'tool 角色绝不可作为独立 ChatMessage 呈现');
    const rawJsonBubble = normalizedFromFixture.filter(m => m.content.includes('"exit_code": 0') || m.content.includes('"approval":'));
    assert(rawJsonBubble.length === 0, '原始 tool 输出 JSON 绝不可作为正文消息气泡');

    // 断言 3: 工具名称与调用关联正确
    assert(astFinalMsg.toolCalls && astFinalMsg.toolCalls.length === 1, '助手终态消息附带 1 个工具调用');
    const tool0 = astFinalMsg.toolCalls[0];
    assert(tool0.name === 'terminal', `工具名称应为 terminal，实际为 ${tool0.name}`);
    assert(tool0.status === 'completed', '工具状态应为 completed');
    assert(tool0.output === '1', `工具输出应解析为 1，实际为 ${tool0.output}`);
    assert(tool0.input && tool0.input.includes('python3 -c \\"print(1)\\"'), '工具输入参数保留完整');
    console.log('  -> 真实证据 fixture 归一化验证通过 (工具名: terminal, 结果: 1, 终态正文完整)');

    // 2. 测试场景：多工具并发调用 + 乱序返回
    const multiToolRaw = [
      {
        id: 201,
        role: 'user',
        content: '请同时读取两个文件'
      },
      {
        id: 202,
        role: 'assistant',
        content: '正在读取...',
        tool_calls: [
          { id: 'call_read_a', function: { name: 'file_read', arguments: '{"path":"/a.txt"}' } },
          { id: 'call_read_b', function: { name: 'file_read', arguments: '{"path":"/b.txt"}' } }
        ]
      },
      {
        id: 203,
        role: 'tool',
        tool_call_id: 'call_read_b', // 乱序返回 B
        tool_name: 'file_read',
        content: '{"output":"Content of B","exit_code":0}'
      },
      {
        id: 204,
        role: 'tool',
        tool_call_id: 'call_read_a', // 后返回 A
        tool_name: 'file_read',
        content: '{"output":"Content of A","exit_code":0}'
      },
      {
        id: 205,
        role: 'assistant',
        content: '两个文件均已读取完毕。',
        finish_reason: 'stop'
      }
    ];
    const multiNorm = HermesHistoryNormalizer.normalize(multiToolRaw);
    const multiAst = multiNorm.find(m => m.content.includes('两个文件均已读取完毕'));
    assert(multiAst && multiAst.toolCalls && multiAst.toolCalls.length === 2, '正确收集并发返回的 2 个工具');
    assert(multiAst.toolCalls.some(t => t.id === 'call_read_a' && t.output === 'Content of A'), '工具 A 关联输出正确');
    assert(multiAst.toolCalls.some(t => t.id === 'call_read_b' && t.output === 'Content of B'), '工具 B 关联输出正确');
    console.log('  -> 多工具并发与乱序返回归一化通过');

    // 3. 测试场景：工具执行失败 (exit_code != 0 或 error 字段)
    const failedToolRaw = [
      { id: 301, role: 'user', content: '运行失败命令' },
      {
        id: 302,
        role: 'assistant',
        tool_calls: [{ id: 'call_fail', function: { name: 'bash', arguments: '{"cmd":"exit 1"}' } }]
      },
      {
        id: 303,
        role: 'tool',
        tool_call_id: 'call_fail',
        content: '{"error":"Permission denied","exit_code":1}'
      },
      {
        id: 304,
        role: 'assistant',
        content: '执行遇到权限问题。'
      }
    ];
    const failedNorm = HermesHistoryNormalizer.normalize(failedToolRaw);
    const failedAst = failedNorm.find(m => m.content.includes('执行遇到权限问题'));
    assert(failedAst && failedAst.toolCalls && failedAst.toolCalls.length === 1, '失败工具挂载');
    assert(failedAst.toolCalls[0].status === 'failed', '状态正确标记为 failed');
    assert(failedAst.toolCalls[0].output === 'Permission denied', '输出提取错误内容');
    console.log('  -> 工具执行失败与错误状态捕获通过');

    // 4. 测试场景：非 JSON 纯文本工具输出 + 未关联 tool_call_id 兜底
    const nonJsonRaw = [
      { id: 401, role: 'user', content: '查看状态' },
      {
        id: 402,
        role: 'tool',
        tool_name: 'git_status',
        content: 'On branch main\nnothing to commit'
      },
      {
        id: 403,
        role: 'assistant',
        content: '当前工作区干净。'
      }
    ];
    const nonJsonNorm = HermesHistoryNormalizer.normalize(nonJsonRaw);
    const nonJsonAst = nonJsonNorm.find(m => m.content.includes('当前工作区干净'));
    assert(nonJsonAst && nonJsonAst.toolCalls && nonJsonAst.toolCalls.length === 1, '非 JSON 结果且无 id 工具正确兜底关联');
    assert(nonJsonAst.toolCalls[0].name === 'git_status', '名称正确提取');
    assert(nonJsonAst.toolCalls[0].output.includes('On branch main'), '非 JSON 纯文本原样保留');
    console.log('  -> 非 JSON 纯文本与缺失 ID 兜底容错通过');

    console.log('[PASS 31] HermesHistoryNormalizer 真实证据与通用历史归一化全链路通过');
  }

  // --- 测试用例 32: 历史归一化轮次边界与运行态工具声明保留 (HermesHistoryNormalizer 缺陷修复) ---
  console.log('\n[TEST 32] 测试 HermesHistoryNormalizer 轮次边界约束与运行态声明保留:');
  {
    // 1. 缺陷 1 验证：[user A, assistant A, user B, tool orphan B, user C]
    // 绝不能把 B 轮的孤儿工具挂到前一轮助手 A 上！
    const boundaryRaw = [
      { id: 1, role: 'user', content: 'User A prompt' },
      { id: 2, role: 'assistant', content: 'Assistant A reply' },
      { id: 3, role: 'user', content: 'User B prompt' },
      { id: 4, role: 'tool', tool_name: 'orphan_tool_b', content: '{"output":"tool_b_done"}' },
      { id: 5, role: 'user', content: 'User C prompt' }
    ];

    const boundaryNorm = HermesHistoryNormalizer.normalize(boundaryRaw);
    assert(boundaryNorm.length === 5, `应归一化为 5 条消息 (包含 B 轮独立工具容器)，实际为 ${boundaryNorm.length}`);
    const astA = boundaryNorm.find(m => m.content === 'Assistant A reply');
    assert(astA, '助手 A 消息存在');
    assert(!astA.toolCalls || astA.toolCalls.length === 0, '助手 A 绝不可被污染挂载 B 轮的工具！');

    const containerB = boundaryNorm[3];
    assert(containerB.role === 'assistant', '第 4 条消息为 B 轮生成的独立工具容器');
    assert(containerB.toolCalls && containerB.toolCalls.length === 1, 'B 轮工具容器承载 orphan_tool_b');
    assert(containerB.toolCalls[0].name === 'orphan_tool_b', '工具名正确为 orphan_tool_b');
    assert(containerB.toolCalls[0].output === 'tool_b_done', '工具输出正确保留');

    const usrC = boundaryNorm[4];
    assert(usrC.role === 'user' && usrC.content === 'User C prompt', '用户 C 正常位于末尾');
    console.log('  -> 轮次 user 边界严格约束测试通过 (前序轮次未受孤儿工具污染)');

    // 2. 缺陷 2 验证：只有工具调用声明、尚无 tool 结果的历史保留 running 状态
    const runningToolRaw = [
      { id: 10, role: 'user', content: '运行长任务' },
      {
        id: 11,
        role: 'assistant',
        content: '',
        tool_calls: [
          {
            id: 'call_inflight_1',
            type: 'function',
            function: {
              name: 'terminal',
              arguments: '{"command":"sleep 10"}'
            }
          }
        ],
        finish_reason: 'tool_calls'
      }
    ];

    const runningNorm = HermesHistoryNormalizer.normalize(runningToolRaw);
    assert(runningNorm.length === 2, `运行态消息列表应包含 2 条消息，实际为 ${runningNorm.length}`);
    const runningAst = runningNorm[1];
    assert(runningAst.role === 'assistant', '第 2 条消息为助手消息');
    assert(runningAst.toolCalls && runningAst.toolCalls.length === 1, '运行态工具声明必须生成 ToolCallItem，不可丢弃！');
    const runningTool = runningAst.toolCalls[0];
    assert(runningTool.id === 'call_inflight_1', '工具 ID 正确保留');
    assert(runningTool.name === 'terminal', '工具名正确保留');
    assert(runningTool.status === 'running', `运行态工具状态必须为 running，实际为 ${runningTool.status}`);
    assert(runningTool.output === undefined, '尚未返回结果的工具 output 应为 undefined');
    assert(runningAst.status === 'streaming', '包含运行态工具的助手消息状态为 streaming');
    console.log('  -> 运行态工具调用声明保留与 running 状态语义验证通过');

    console.log('[PASS 32] HermesHistoryNormalizer 缺陷修复验证通过');
  }

  // --- 测试用例 33: F02 会话管理完整生命周期 (分页/去重/搜索/改名/置顶/归档/分支/导出/切服隔离) ---
  console.log('\n[TEST 33] 测试 SessionListViewModel & HermesRESTClient F02 会话管理完整生命周期:');
  {
    // 构造测试连接
    const conn = {
      id: 'conn-f02',
      name: 'F02 Test Server',
      url: baseUrl,
      serverVersion: 'hermes',
      token: 'test-token',
      cookies: 'session_cookie=abc',
      activeProfile: 'default'
    };

    const sessionVm = new SessionListViewModel();

    // 1. 测试首次分页加载 (第 1 页，limit 20)
    await sessionVm.loadSessions(conn);
    assert(sessionVm.getSessions().length === 20, `第 1 页应呈现 20 条会话，实际为 ${sessionVm.getSessions().length}`);
    assert(sessionVm.getTotalCount() === 36, `服务端总数应为 36，实际为 ${sessionVm.getTotalCount()}`);
    assert(sessionVm.getHasMore() === true, '应标记 hasMore 为 true');
    console.log('  -> 第 1 页分页加载与总数核验通过');

    // 2. 测试分页加载更多 (第 2 页，追加至 36，含重复置顶回填去重)
    const loadMoreOk = await sessionVm.loadMoreSessions(conn);
    assert(loadMoreOk === true, 'loadMoreSessions 应返回 true');
    assert(sessionVm.getSessions().length === 36, `追加后应呈现 36 条会话，实际为 ${sessionVm.getSessions().length}`);
    assert(sessionVm.getHasMore() === false, '第 2 页加载完毕后 hasMore 应为 false');
    console.log('  -> 分页加载更多与去重合并通过');

    // 3. 测试搜索与过滤 (本地模糊匹配 + 恢复)
    await sessionVm.setSearchQuery('第 10');
    assert(sessionVm.getSessions().length >= 1, '搜索包含 "第 10" 的会话应有结果');
    assert(sessionVm.getSessions().every(s => (s.title && s.title.includes('第 10')) || (s.preview && s.preview.includes('第 10')) || s.id.includes('10')), '搜索结果匹配');

    sessionVm.clearSearch();
    assert(sessionVm.getSessions().length === 36, '清除搜索后应完整恢复全量 36 条会话');
    console.log('  -> 会话即时检索与搜索清除无损恢复通过');

    // 4. 测试置顶 (togglePinSession)
    const targetSession = sessionVm.getSessions()[15];
    targetSession.updated_at = Date.now();
    const pinOk = await sessionVm.togglePinSession(conn, targetSession);
    assert(pinOk === true, '置顶操作应成功');
    assert(targetSession.is_pinned === true, '会话属性标记为置顶');
    assert(sessionVm.getSessions()[0].id === targetSession.id, '置顶会话应排在列表第一位');

    // 切换到置顶 Tab
    sessionVm.setFilterTab('pinned');
    assert(sessionVm.getSessions().length === 2, `置顶 Tab 应包含 2 个置顶项，实际为: ${sessionVm.getSessions().length}`);
    sessionVm.setFilterTab('all');
    console.log('  -> 会话置顶与置顶前置排序通过');

    // 5. 测试归档 (toggleArchiveSession)
    const archiveTarget = sessionVm.getSessions()[5];
    const archiveOk = await sessionVm.toggleArchiveSession(conn, archiveTarget);
    assert(archiveOk === true, '归档操作应成功');
    assert(archiveTarget.is_archived === true, '标记为已归档');
    // 在 'all' Tab 中，已归档项应被隐藏
    assert(!sessionVm.getSessions().find(s => s.id === archiveTarget.id), 'All Tab 默认应隐藏已归档会话');

    // 切换到已归档 Tab
    sessionVm.setFilterTab('archived');
    assert(sessionVm.getSessions().some(s => s.id === archiveTarget.id), '已归档 Tab 应展示归档项');
    sessionVm.setFilterTab('all');
    console.log('  -> 会话归档与归档隔离隐藏通过');

    // 6. 测试改名 (renameSession)
    const renameTarget = sessionVm.getSessions()[2];
    const renameOk = await sessionVm.renameSession(conn, renameTarget, '已修改的新会话名称');
    assert(renameOk === true, '改名应成功');
    assert(renameTarget.title === '已修改的新会话名称', '会话标题就地更新成功');
    console.log('  -> 会话重命名与本地回读通过');

    // 7. 测试分支克隆 (duplicateSession)
    const dupTarget = sessionVm.getSessions()[0];
    const dupRes = await sessionVm.duplicateSession(conn, dupTarget);
    assert(dupRes && dupRes.id.length > 0, '分支克隆应返回新会话');
    assert(dupRes.title.includes('(copy)'), `新会话标题应包含 (copy)，实际为: ${dupRes.title}`);
    assert(sessionVm.getRawSessions()[0].id === dupRes.id, '新克隆会话应插入全量列表头部');
    assert(sessionVm.getSessions().some(s => s.id === dupRes.id), '新克隆会话应存在于展示列表中');
    console.log('  -> 会话分支克隆 (Duplication) 通过');

    // 8. 测试导出 (exportSession)
    const exportTarget = dupRes;
    const exportedJson = await sessionVm.exportSession(conn, exportTarget);
    assert(typeof exportedJson === 'string' && exportedJson.length > 10, '导出结果应为有效 JSON 文本');
    const parsedExport = JSON.parse(exportedJson);
    assert(parsedExport.id === exportTarget.id, '导出的会话 ID 与目标匹配');
    console.log('  -> 会话 JSON 导出通过');

    // 9. 测试跨服务器切换防竞态 (requestSerial 保护)
    const slowConnA = { id: 'conn-a', name: 'Slow Server A', url: baseUrl, serverVersion: 'hermes', activeProfile: 'default' };
    const fastConnB = { id: 'conn-b', name: 'Fast Server B', url: baseUrl, serverVersion: 'hermes', activeProfile: 'fast_profile' };

    // 连续触发切服
    const loadPromiseA = sessionVm.loadSessions(slowConnA);
    const loadPromiseB = sessionVm.loadSessions(fastConnB);
    await Promise.all([loadPromiseA, loadPromiseB]);
    assert(sessionVm.getRawSessions().every(s => s.profile === 'fast_profile'), '滞后返回的 Server A 数据绝不可覆盖活跃 Server B');
    console.log('  -> 跨服务器切换与竞态代次保护通过');

    // 10. 测试 HermesRESTClient.searchSessions 契约 (q 编码, c++, 包含 exclude_sources, 空检索拦截)
    const emptySearchRes = await HermesRESTClient.searchSessions(baseUrl, 'default', '   ');
    assert(Array.isArray(emptySearchRes) && emptySearchRes.length === 0, '空检索应直接返回空数组 []');
    const cppSearchRes = await HermesRESTClient.searchSessions(baseUrl, 'default', 'c++');
    assert(cppSearchRes.length === 1 && cppSearchRes[0].id === 'sess_cpp_test', 'c++ 检索转义为 %2B 正确匹配服务端响应');
    console.log('  -> searchSessions q 参数与 %2B 转义验证通过');

    // 11. 测试归档流拉取与服务端置顶回填过滤 (archived=only 且过滤未归档置顶项)
    const archivedVm = new SessionListViewModel();
    await archivedVm.setFilterTab('archived', conn);
    assert(archivedVm.getSessions().length === 2, `归档流仅展示 2 条真实归档项，实际为 ${archivedVm.getSessions().length}`);
    assert(!archivedVm.getSessions().some(s => s.id === 'sess_f02_pinned_backfill'), '服务端向归档流回填的未归档置顶项必须被彻底过滤');
    console.log('  -> 归档流独立服务端拉取与置顶回填过滤验证通过');

    // 12. 测试反向解归档 (Unarchive 恢复至活跃流)
    const unarchiveTarget = archivedVm.getSessions()[0];
    const unarchiveOk = await archivedVm.toggleArchiveSession(conn, unarchiveTarget);
    assert(unarchiveOk === true, '解归档操作应成功');
    assert(unarchiveTarget.is_archived === false, '标记为未归档');
    assert(!archivedVm.getSessions().some(s => s.id === unarchiveTarget.id), '已归档 Tab 中该项已移除');
    await archivedVm.setFilterTab('all');
    assert(archivedVm.getSessions().some(s => s.id === unarchiveTarget.id), '切换至 All Tab 后该项已成功恢复呈现');
    console.log('  -> 会话解归档流转与双向无损状态恢复通过');

    // 13. 测试 Legacy WebUI 严格保护 (不支持的操作严禁在内存中伪造成功)
    const legacyConn = {
      id: 'conn-legacy',
      name: 'Legacy Server',
      url: baseUrl,
      serverVersion: 'legacy-webui',
      token: 'leg-token',
      cookies: 'leg_cookie=1'
    };
    const legacySession = {
      id: 'legacy-sess-1',
      title: '旧版原生会话',
      profile: 'default',
      is_pinned: false,
      is_archived: false,
      created_at: Date.now(),
      updated_at: Date.now()
    };
    const legPinOk = await sessionVm.togglePinSession(legacyConn, legacySession);
    assert(legPinOk === false, 'Legacy WebUI 置顶操作必须返回 false');
    assert(legacySession.is_pinned === false, 'Legacy WebUI 置顶绝不可在内存中修改状态');
    assert(sessionVm.getActionError().includes('不支持会话置顶'), '展示明确不支持错误信息');

    const legArchiveOk = await sessionVm.toggleArchiveSession(legacyConn, legacySession);
    assert(legArchiveOk === false, 'Legacy WebUI 归档操作必须返回 false');
    assert(legacySession.is_archived === false, 'Legacy WebUI 归档绝不可在内存中修改状态');

    const legRenameOk = await sessionVm.renameSession(legacyConn, legacySession, '新名');
    assert(legRenameOk === false, 'Legacy WebUI 重命名必须返回 false');
    assert(legacySession.title === '旧版原生会话', 'Legacy WebUI 标题绝不可在内存中被修改');

    try {
      await sessionVm.duplicateSession(legacyConn, legacySession);
      assert(false, 'Legacy WebUI duplicateSession 必须抛出异常');
    } catch (e) {
      assert(e.message.includes('不支持会话分支克隆'), '抛出明确不支持异常');
    }

    try {
      await sessionVm.exportSession(legacyConn, legacySession);
      assert(false, 'Legacy WebUI exportSession 必须抛出异常');
    } catch (e) {
      assert(e.message.includes('不支持会话导出'), '抛出明确不支持异常');
    }
    console.log('  -> Legacy WebUI 操作拒绝与无状态污染保护通过');

    // 14. 测试切服时旧会话池立即物理清空 (即使后续网络失败也不残留脏数据)
    const badConn = {
      id: 'conn-bad',
      name: 'Bad Server',
      url: 'http://127.0.0.1:9999/unreachable',
      serverVersion: 'hermes',
      activeProfile: 'default'
    };
    await sessionVm.loadSessions(badConn);
    assert(sessionVm.getSessions().length === 0, '切换至不可用服务器时，旧服务器会话列表必须立即物理清空！');
    assert(sessionVm.getActionError() !== null, '记录加载失败错误');
    console.log('  -> 切换服务器旧会话物理擦除与脏数据防残留验证通过');

    console.log('[PASS 33] SessionListViewModel & HermesRESTClient F02 会话管理全生命周期通过');
  }

  // --- 测试用例 34: F08 定时任务调度管理完整生命周期 (Client+ViewModel+契约+隔离+历史) ---
  console.log('\n[TEST 34] 测试 HermesCronClient & CronViewModel F08 任务管理完整生命周期:');
  {
    const cronConn = {
      id: 'conn-cron',
      name: 'Cron Test Server',
      url: baseUrl,
      serverVersion: 'hermes',
      token: 'cron-token',
      cookies: 'cron_cookie=1',
      activeProfile: 'default'
    };

    const cronVm = new CronViewModel();

    // 1. 测试 CronViewModel.loadJobs
    await cronVm.loadJobs(cronConn);
    assert(cronVm.jobs.length === 1, `应加载 1 个初始任务，实际为: ${cronVm.jobs.length}`);
    assert(cronVm.jobs[0].id === 'job_daily_1', '任务 ID 匹配');
    assert(cronVm.jobs[0].name === '每日健康检查', '任务名称匹配');
    assert(cronVm.jobs[0].schedule === '0 8 * * *', 'Cron 表达式匹配');
    console.log('  -> 定时任务列表加载与属性解析通过');

    // 2. 测试 CronViewModel.createJob 必填项空值拒绝与正常新建
    const emptyJob = await cronVm.createJob(cronConn, '   ', '', '');
    assert(emptyJob === null, '空字段必须拒绝创建');
    assert(cronVm.actionError && cronVm.actionError.includes('必填'), '必填字段报错提示');

    // 2b. 测试 HTTP 424 警告语义 (任务已持久化但调度注册失败，上游 HermesCronClient.swift:32-49)
    const warnJob = await cronVm.createJob(cronConn, 'trigger-424', '0 3 * * *', 'echo warn');
    assert(warnJob !== null && warnJob.state === 'warning', '424 状态应成功返回并标记 warning 状态');
    assert(cronVm.statusMessage.includes('警告'), '状态消息应展示警告说明');

    const createdJob = await cronVm.createJob(cronConn, '自动化构建与巡检', '0 2 * * *', 'run build-check');
    assert(createdJob !== null && createdJob.id.length > 0, '创建任务应成功返回任务实例');
    assert(createdJob.name === '自动化构建与巡检', '新任务名称匹配');
    assert(createdJob.schedule === '0 2 * * *', '新任务表达式匹配');
    console.log('  -> 定时任务必填校验、424 调度警告语义与正常新建通过');

    // 3. 测试 CronViewModel.updateJob (PUT /api/cron/jobs/:id)
    const updatedJob = await cronVm.updateJob(cronConn, 'job_daily_1', {
      name: '每日健康巡检 (更新)',
      schedule: '0 9 * * *'
    });
    assert(updatedJob !== null, '更新任务应成功');
    assert(updatedJob.name === '每日健康巡检 (更新)', '更新后任务名称匹配');
    assert(updatedJob.schedule === '0 9 * * *', '更新后 Cron 表达式匹配');
    console.log('  -> 定时任务编辑与 PUT 契约通过');

    // 4. 测试 CronViewModel.triggerJob (POST /api/cron/jobs/:id/trigger) 与 409 冲突
    const triggerOk = await cronVm.triggerJob(cronConn, 'job_daily_1');
    assert(triggerOk === true, '手动触发任务应返回 true');

    const conflictOk = await cronVm.triggerJob(cronConn, 'job_conflict');
    assert(conflictOk === false, '409 冲突任务应返回 false');
    assert(cronVm.actionError && cronVm.actionError.includes('Task already active'), '409 冲突详情捕获');
    console.log('  -> 定时任务手动触发 (/trigger) 与 409 运行冲突捕获通过');

    // 5. 测试 CronViewModel.toggleJob (暂停与恢复: POST /pause & POST /resume)
    const toggleTarget = cronVm.jobs[0];
    const pauseOk = await cronVm.toggleJob(cronConn, toggleTarget);
    assert(pauseOk === true, '暂停任务应成功');

    toggleTarget.enabled = false;
    const resumeOk = await cronVm.toggleJob(cronConn, toggleTarget);
    assert(resumeOk === true, '恢复任务应成功');
    console.log('  -> 定时任务状态切换 (暂停/恢复) 通过');

    // 6. 测试 CronViewModel.loadRuns (GET /api/cron/jobs/:id/runs?profile=...&limit=100)
    const runs = await cronVm.loadRuns(cronConn, 'job_daily_1');
    assert(Array.isArray(runs) && runs.length >= 1, '应成功拉取任务执行历史');
    assert(runs[0].id.includes('job_daily_1'), '历史运行 ID 与目标任务关联');
    assert(runs[0].endReason === 'ok', '执行结果状态解析匹配');
    console.log('  -> 定时任务运行历史拉取与解析通过');

    // 7. 测试切服与代次隔离 (requestSerial 保护)
    const slowConn = { id: 'conn-slow', name: 'Slow Server', url: baseUrl, serverVersion: 'hermes', activeProfile: 'default' };
    const fastConn = { id: 'conn-fast', name: 'Fast Server', url: baseUrl, serverVersion: 'hermes', activeProfile: 'fast_profile' };

    const slowPromise = cronVm.loadJobs(slowConn);
    const fastPromise = cronVm.loadJobs(fastConn);
    await Promise.all([slowPromise, fastPromise]);
    assert(cronVm.jobs.every(j => j.profile === 'fast_profile'), '滞后返回的 Slow Server 任务绝不可覆盖活跃 Fast Server');
    console.log('  -> 切服代次隔离与竞态保护通过');

    // 8. 测试 Legacy WebUI 严格保护 (旧版 WebUI 不支持 cron，必须直接拦截并报错)
    const legacyCronConn = {
      id: 'conn-leg-cron',
      name: 'Legacy Server',
      url: baseUrl,
      serverVersion: 'legacy-webui',
      token: 'leg-token'
    };

    await cronVm.loadJobs(legacyCronConn);
    assert(cronVm.jobs.length === 0, 'Legacy WebUI 下任务列表必须清空');
    assert(cronVm.actionError && cronVm.actionError.includes('不支持定时任务'), 'Legacy WebUI loadJobs 应设置错误提示');

    const legCreate = await cronVm.createJob(legacyCronConn, '测试', '* * * * *', 'prompt');
    assert(legCreate === null, 'Legacy WebUI createJob 必须返回 null');

    const legUpdate = await cronVm.updateJob(legacyCronConn, 'job_1', { name: '新' });
    assert(legUpdate === null, 'Legacy WebUI updateJob 必须返回 null');

    const legTrigger = await cronVm.triggerJob(legacyCronConn, 'job_1');
    assert(legTrigger === false, 'Legacy WebUI triggerJob 必须返回 false');

    const legRuns = await cronVm.loadRuns(legacyCronConn, 'job_1');
    assert(legRuns.length === 0, 'Legacy WebUI loadRuns 必须返回空数组');
    console.log('  -> Legacy WebUI 拦截与无副作用保护通过');

    console.log('[PASS 34] HermesCronClient & CronViewModel F08 任务管理全生命周期通过');
  }

  vm.disconnect();
  server.close();

  console.log('\n======================================================');
  console.log('✅ 所有 34 项端到端生产代码行为回归测试全部通过 (退出码 0)');
  console.log('覆盖真实生产业务类：');
  console.log('  - HermesHistoryNormalizer.ets (轮次边界用户隔离、运行态工具声明保留、多工具、乱序、失败、非JSON与证据 fixture 回归)');
  console.log('  - SessionListViewModel.ets (F02 分页加载、去重、检索清除恢复、分类 Tab、置顶、归档、分支克隆、导出与切服竞态隔离)');
  console.log('  - HermesRESTClient.ets (Cookie Jar、登录、/api/auth/me 核验、Ticket、会话分页、PATCH属性、导入、导出与历史)');
  console.log('  - HermesGatewayClient.ets (WebSocket 握手、client.capabilities 回执、关闭码、RPC 30s 超时、取消、file.attach)');
  console.log('  - ChatViewModel.ets (会话恢复门禁、禁止发送、async 代次乱序拦截、中文流式、推理、工具、连续同名工具审批防误清、模型配置、文档附加)');
  console.log('  - AuthStore.ets (真实 HarmonyPlatformAuthAdapter + Preferences 元数据 + AssetStoreKit 密文硬件保管库 + UTF-8 中文/Emoji + 原子回滚 + clearAll 物理擦除)');
  console.log('  - AttachmentUtils.ets (动态 MIME 判定、图片/文档分流、防路径穿越清洗、UUID 附件名)');
  console.log('  - HermesWorkspaceClient.ets (路径穿越防护、远程目录与文件读取)');
  console.log('  - WorkspaceViewModel.ets (目录层级导航、历史回退、文件预览与下载)');
  console.log('  - HermesFileClient.ets (data_url 图片上传、ArrayBuffer 二进制产物下载)');
  console.log('  - HermesProjectClient.ets / GitWorkspaceViewModel.ets (项目列表、Git 根目录、分支列表、切换分支)');
  console.log('  - HermesSkillsClient.ets / HermesMemoryClient.ets / SkillsViewModel.ets (技能开关、Soul读取与保存、长期记忆)');
  console.log('  - HermesKanbanClient.ets / KanbanViewModel.ets (看板401/404可用性区分、对象包装看板列表、最新驼峰事件游标、PATCH卡片状态更新、只读模式保护)');
  console.log('  - HermesCronClient.ets / CronViewModel.ets (定时任务调度、触发、暂停与恢复)');
  console.log('  - HermesInsightsClient.ets / InsightsViewModel.ets (模型用量与成本统计)');
  console.log('  - LegacySSEClient.ets (上游旧版 WebUI 健康探针、/api/chat/start、/api/chat/cancel、/api/chat/stream 跨数据块 SSE 拼帧缓冲与会话详情)');
  console.log('  - NotificationUtils.ets (系统通知管理器、审批待办与任务完成提醒)');
  console.log('  - DeepLinkUtils.ets / ShareUtils.ets / VoiceUtils.ets (深链 hermex:// / hermes-agent:// 解析与分发、系统分享 Want 解析与外发、语音录音/播放状态机)');
  console.log('  - MarkdownParser.ets / MarkdownView.ets (代码块、表格、列表、引用与多级标题解析渲染)');
  console.log('======================================================');
}

runTestSuite().catch((err) => {
  console.error('\n[FATAL] 测试失败:', err);
  process.exit(1);
});
