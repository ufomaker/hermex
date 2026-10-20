# Hermex 上游基线与协议锁定

## 1. 上游与 Fork 信息

- 上游开源仓库：`https://github.com/uzairansaruzi/hermex.git` (master)
- 用户 Fork 仓库：`https://github.com/ufomaker/hermex.git`
- 鸿蒙开发分支：`harmonyos/native-port`
- 上游初始快照提交：`b26d7c564ae5459bffd2f448118b986741f6720f`
- 许可证：MIT

## 2. 后端协议与版本兼容性 Pin 说明

- `HERMES_AGENT_TESTED_SHA`：
  - 说明：后端直连 `hermes-agent` Python 网关测试验证提交与发布版本 Pin。
  - Commit: `ca6782850432927f33df4775cb6dd45bb51460d2`
  - Tested Version: `0.21.5`
- `UPSTREAM_TESTED_SHA`：
  - 说明：legacy `hermes-webui` 后端契约兼容性测试提交 Pin（对应上游 upstream 仓库 `hermes-webui` 的 Git commit）。
  - Commit: `c67fd2dd270a1128c2754200406bca58e9d9a25a`
- `reviewed_upstream_master_sha`：
  - 说明：原作者 `hermex` iOS 客户端源码仓库当前已审查的基线快照 Commit（记录于 `docs/harmonyos/upstream_baseline.json`）。
  - Commit: `b26d7c564ae5459bffd2f448118b986741f6720f`
- `verified_functional_baseline_sha`：
  - 说明：鸿蒙端全量功能已通过端到端验收的稳定基线 Commit（当前为 `null`，待全量功能验收完成后由监督者确认并推进）。
- 最低兼容版本门槛：`0.21.3`（`HermesCompatibility.minimumVersion`）。
- 本机运行服务静态探测实况（仅探测公开版本与状态，不接触密钥及敏感数据）：
  - 端口：`61688`
  - 探针端点：`GET http://127.0.0.1:61688/api/status`
  - 汇报版本：`0.22.2`（release_date: `2026.9.24`）
  - 门槛判断：`0.22.2 >= 0.21.3` 满足客户端准入的最低版本要求。
  - **重要说明**：满足最低版本号仅代表静态准入门槛通过，不代表与 0.22.2 的完整协议兼容性已经验证；实际协议兼容性以 WebSocket 真实握手和隔离测试结果为准。本地 127.0.0.1 仅为开发调试探测，真机不可作为产品默认连接。

## 3. 核心通信协议证据（源码固定核查结果）

### 3.1 状态探针、认证与 Ticket 获取（证据来源：`HermesREST.swift`）
- 状态探针（公开）：
  - `GET /api/status`
- 密码登录（证据：`HermesREST.swift:360-363`）：
  - 路径：`POST /auth/password-login`
  - 载荷：`{ "provider": "basic", "username": "<username>", "password": "<password>" }`
- 原生 Token 换取（证据：`HermesREST.swift:368-371`）：
  - 路径：`POST /auth/native/token`
  - 载荷：`{ "code": "<code>", "code_verifier": "<verifier>" }`
- 原生 Token 刷新（证据：`HermesREST.swift:364-367`）：
  - 路径：`POST /auth/native/refresh`
  - 载荷：`{ "refresh_token": "<token>", "provider": "<provider>" }`
- 用户身份确认（证据：`HermesREST.swift:372`）：
  - 路径：`GET /api/auth/me`
- WebSocket Ticket 换取（证据：`HermesREST.swift:374`）：
  - 路径：`POST /api/auth/ws-ticket`（注意：不是猜造的 `/api/ticket`）
  - 请求体：空 JSON 对象 `{}`
  - 响应：包含可用于网关握手的单次有效 ticket 字符串。

### 3.2 WebSocket Gateway (实时会话与控制，证据来源：`HermesCall.swift`、`HermesGateway.swift`)
- 连接地址：`ws://<host>:<port>/api/ws`（或 `wss://`）
- 子协议头：`Sec-WebSocket-Protocol: hermes-gateway-v1, hermes-gateway-ticket.<ticket>`
- 握手流程：
  1. 连接成功后，网关下发握手首帧事件：
     ```json
     {"method": "event", "params": {"type": "gateway.ready", "payload": {"replay_epoch": "<epoch>"}}}
     ```
  2. 客户端记录 `replay_epoch`，立即发送能力声明请求（必须发送以开启服务端请求接收）：
     ```json
     {"jsonrpc": "2.0", "id": 1, "method": "client.capabilities", "params": {"server_requests": true}}
     ```
  3. 心跳保活机制：客户端每 15 秒向网关发送：
     ```json
     {"jsonrpc": "2.0", "id": "heartbeat-<seq>", "method": "gateway.ping", "params": {}}
     ```
- 核心 RPC 方法与参数精确映射（证据：`HermesCall.swift:275-340`, `400-475`）：
  - 会话列表：`session.list`，参数 `{"profile": "<name>"}`（单数 `session`）
  - 会话创建：`session.create`，参数 `{"profile": "<name>"}` 或含 `cwd`、`model`
  - 会话恢复：`session.resume`，参数 `{"session_id": "<id>", "profile": "<name>", "omit_messages": <bool>}`
  - 会话重命名/标题：`session.title`，参数 `{"session_id": "<id>", "title": "<title>"}`
  - 会话关闭：`session.close`，参数 `{"session_id": "<id>"}`
  - 会话删除：`session.delete`，参数 `{"profile": "<name>", "session_id": "<id>"}`
  - 提示词提交：`prompt.submit`，参数 `{"session_id": "<id>", "text": "<text>", "queued": true}`
  - 中断停止执行：`session.interrupt`，参数 `{"session_id": "<id>"}`（注意：不是猜造的 `prompt.interrupt`）
  - 审批回复：`approval.respond`，参数 `{"session_id": "<id>", "request_id": "<req_id>", "choice": "<choice>"}`
  - 澄清/问答答复：
    - `request.answer`: 参数 `{"id": "<req_id>", "result": {"value": "<val>"}}` 或 `{"answer": "<ans>"}`
    - `clarify.lock`: 参数 `{"request_id": "<req_id>", "question_id": "<q_id>", "answer": "<ans>"}`
  - 连接授权回复：`connection.respond`，参数 `{"op_id": "<id>", "result": ...}`
  - 模型选项获取：`model.options`，参数 `{"session_id": "<id>", "profile": "<name>"}`
- 事件流精确映射（`method == "event"`）：
  - `message.start`: 新一轮模型输出开始
  - `message.delta`: 增量输出文本，字段 `payload.text`
  - `message.interim`: 中间暂存/工具输出文本，字段 `payload.text`
  - `reasoning.delta`: 思考/推理增量文本，字段 `payload.text`
  - `tool.start`, `tool.delta`, `tool.complete`: 工具调用全生命周期事件
  - `session.info`: 会话状态（`running: bool`, `model: str`, `title: str`, `stored_session_id: str` 等）
  - `message.complete`: 消息生成完成
  - `error`: 异常事件，字段 `payload.message`
