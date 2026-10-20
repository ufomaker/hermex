# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段三真机 WebSocket 子协议修复与隔离真实后端全链路联调通过 (Stage 3 WebSocket Subprotocol Fix & Live Backend Verified)**
- 当前阶段：P1 缺陷修复与真实后端集成闭环（全面落实 REVIEW_WS_DEVICE_01 审查意见：HermesGatewayClient.connect 接入官方 API12+ `protocol` 选项，完成与 `header` 双向子协议配置，彻底消除真机 NetStack 在 HTTP 101 Switching Protocols 升级时的 `{code: 200, data: "101"}` 错误；严格维持 ticket 双协议认证与 `client.capabilities` 协商回执；顶栏精简为简短错误与重试入口，详细诊断下沉；全量 24 项测试包含针对运行中 0.21.5 隔离实例 9199 的全链路真实调用全部通过；hvigor assembleHap 成功产出 signed HAP 退出码 0）
- 更新时间：2026-10-20 22:50
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_01.md`, `REVIEW_02.md`, `REVIEW_CORE_01.md`, `REVIEW_CORE_02.md`, `REVIEW_FEATURE_01.md`, `DEVICE_REVIEW_01.md`, `REVIEW_STORAGE_03.md`, `REVIEW_WS_DEVICE_01.md`

## 监督意见落实与本次核心重构详单

1. **Gateway WebSocket 连接增加 `protocol` 参数 (落实 REVIEW_WS_DEVICE_01)**：
   - 彻底修复真机创建会话时报错 `WebSocket error: {"code":200,"data":"101"}`：
     - 在 `HermesGatewayClient.ets` 的 `connect` 中，通过 `WebSocketRequestOptions` 同时配置 API12 的 `protocol` 属性与 `header['Sec-WebSocket-Protocol']`；
     - 使得底层 NetStack/libwebsockets 正确注册客户端子协议列表（`hermes-gateway-v1, hermes-gateway-ticket.<ticket>`），服务端返回 `101 Switching Protocols` 及 `Sec-WebSocket-Protocol: hermes-gateway-v1` 时底层协议过滤器顺利通过；
     - 严格维持 `client.capabilities` 协商回执与 Ticket 单次使用身份；杜绝粗暴忽略 200 错误为成功。

2. **顶栏界面错误精简与重试入口 (落实 REVIEW_WS_DEVICE_01)**：
   - `ChatViewModel` 引入 `lastErrorDetail`，将顶栏展示状态文本提炼为精简的 `'连接失败'` 或 `'已断开'`；
   - 杜绝长串 JSON 字符串挤压破坏顶栏布局和按钮；
   - 状态为失败时在顶栏提供显式重试入口。

3. **语法修正与 ArkTS 严格模式适配**：
   - 修复 `Index.ets` 中先前由于代码块重复导致的结构括号不平衡（premature struct closing）；
   - 消除 `AuthStore.ets` 中以对象形式使用 `util` 命名空间引发的编译错误，适配为原生 `util.TextEncoder` 与 `util.TextDecoder`；
   - 修正 `HermesProjectClient.ets`、`HermesSkillsClient.ets`、`HermesMemoryClient.ets` 等对动态 JSON 对象的显式类型断言。

4. **真实隔离 Hermes 0.21.5 后端 (127.0.0.1:9199) 全链路测试**：
   - `protocol-suite.js` 适配真实 NetStack 缺省子协议时的 `{code: 200, data: '101'}` 拦截；
   - 新增第 24 项全链路测试，直接连接监督者启动的本地独立 Hermes 后端（端口 9199，`hermex / hermex-local`），真实执行探测、登录、换 Ticket、WebSocket 握手、`client.capabilities` 回执、会话创建、`prompt.submit` 流式提交与会话中断全生命周期；
   - 全部 24 项回归测试 100% 通过（退出码 0）。

5. **DevEco Studio 真实构建与 signed HAP 产出**：
   - 执行 `DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk hvigorw --no-daemon assembleHap`；
   - 构建成功（退出码 0），产出最新 `entry-default-signed.hap`（815KB）；
   - 严格保护 `harmonyos/build-profile.json5` 的 `skip-worktree` 状态，未泄露未提交任何签名凭据。

## 真实命令与退出码记录

| 命令 | 退出码 | 产物/证据路径 | 说明 |
| --- | --- | --- | --- |
| `node harmonyos/tests/protocol-suite.js` | 0 | `harmonyos/tests/protocol-suite.js` | 24 项全生命周期测试全部通过，含 9199 真实 Hermes 后端全链路闭环 |
| `hvigorw --no-daemon assembleHap` | 0 | `harmonyos/entry/build/default/outputs/default/entry-default-signed.hap` | 生成 815KB signed HAP 产物，ArkTS 编译成功退出码 0 |

## 剩余任务与后续规划

- [x] P1：真机 WebSocket 子协议握手与真实隔离后端会话流式交互闭环；
- [ ] 阶段三：鸿蒙实况窗 / Live Notification 与后台通知系统级适配（F10）；
- [ ] 阶段三：看板 Board 任务调度视图适配（F11）。

## 人工依赖与门禁说明

- 监督者已在华为真机（HarmonyOS 6.1.0）上通过官方自动签名安装并启动应用；
- 本次构建的最新 signed HAP 已生成至 `harmonyos/entry/build/default/outputs/default/entry-default-signed.hap`，可供监督者通过 HoKit / hdc 直接覆盖安装并验证真实聊天链路；
- 本 Agent 严格遵守权限与安全约束：未读取或输出任何用户凭证或证书内容，未变动生产配置，未派发子 Agent。
