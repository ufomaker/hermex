# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段一 P1 缺陷修复与核心重构完成 (P1 Defects Remediated & Core Engine Verified)**
- 当前阶段：阶段一深化阶段（消除伪造会话、Cookie认证与核验、会话代次隔离、RPC超时与清理、模型真实配置、审批失败恢复、生产核心逻辑回归测试）
- 更新时间：2026-10-20 20:58
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_01.md`, `REVIEW_02.md`, `REVIEW_CORE_01.md`, `REVIEW_NEXT.md`

## 监督意见落实与本次 P1 缺陷修复详单

1. **会话创建真实性与 runtime 恢复 (落实 REVIEW_CORE_01 第 1 项)**：
   - 彻底废除前端 `session_${Date.now()}` 伪造会话行为；
   - 新建会话统一通过 `HermesGatewayClient.createSession` 发起 RPC，由服务端返回真实 `session_id`；
   - 会话恢复通过 `session.resume` 获取服务端 `runtime` ID，明确区分存储 ID（`stored_session_id`）与运行时实例 ID（`runtime_id`）；
   - 进入会话时通过 `HermesRESTClient.getSessionMessages` 真实拉取服务端历史消息并注入聊天视窗。
2. **Cookie Jar 与密码登录身份核验 (落实 REVIEW_CORE_01 第 2 项)**：
   - 在 `HermesRESTClient` 中实现 Cookie 提取与全请求链路携带机制；
   - `login` 流程在调用 `POST /auth/password-login` 提取 Cookie 后，强制调用 `GET /api/auth/me` 核验登录凭据，核验失败不进入系统，杜绝将空 Token/伪登录误判为成功；
   - WebSocket Ticket 换取支持 Cookie 与 Bearer 双通道认证。
3. **连接代次与多会话事件严格隔离 (落实 REVIEW_CORE_01 第 3 项)**：
   - `ChatViewModel` 在 `attachSession` 时主动递增 `generation` 并关闭旧 WebSocket；
   - `HermesGatewayClient` 维护连接代次与 `activeRuntimeId`，所有流式与工具事件必须匹配当前活跃 runtime，跨会话报文严格丢弃，杜绝串流。
4. **RPC 超时清理、断开释放与心跳静默检测 (落实 REVIEW_CORE_01 第 4 项)**：
   - `HermesGatewayClient` 为每个 RPC 请求绑定 30 秒独立超时定时器，超时主动移除并 reject，杜绝悬挂泄漏；
   - 客户端断开连接时，遍历并 reject 所有 pending RPC，立即清理资源；
   - 心跳定时器增加 45 秒静默检测，无报文时主动断开并触发状态回调。
5. **真实模型配置切换 (落实 REVIEW_CORE_01 第 5 项)**：
   - 废除仅修改本地 UI 变量的伪切换；
   - 点击模型时通过 Gateway 发起 `config.set` RPC（参数包含 `key: "model"`, `value: "<model> --session"`），回执成功才更新当前模型，失败展示明确错误。
6. **握手回执严格等待 (落实 REVIEW_CORE_01 第 6 项)**：
   - 收到 `gateway.ready` 后发送 `client.capabilities`，必须 `await` 其 RPC 确认应答后才触发 `onConnected`，保证控制协议协商就绪。
7. **审批与澄清交互可恢复 (落实 REVIEW_CORE_01 第 7 项)**：
   - 用户点击审批或澄清时卡片进入提交中状态，不提前清空；
   - 仅当服务端回执成功后清除卡片；若网络或服务端报错，展示提示并保留卡片供用户重试，杜绝静默吞错。
8. **基线 Pin 语义修正与上游检查重构 (落实 REVIEW_NEXT 第 1、2 项)**：
   - 澄清 `UPSTREAM_TESTED_SHA` 为 legacy webui 契约 pin，`HERMES_AGENT_TESTED_SHA` 为直连后端 pin；
   - 建立机器可读的 `docs/harmonyos/upstream_baseline.json`，独立记录 `reviewed_upstream_master_sha`（`b26d7c564ae5459bffd2f448118b986741f6720f`）；
   - 更新 `scripts/check-upstream-sync`，对比远端真实 master 与已审查基线，杜绝本地分支直接比对导致的虚假报告。
9. **生产核心逻辑行为驱动回归测试 (落实 REVIEW_CORE_01 核验要求)**：
   - 抽取纯 TS 协议核心 `HermesProtocolEngine.ts`；
   - 重构 `harmonyos/tests/protocol-suite.js` 直接导入并执行生产核心代码；
   - 真实断言 CookieJar 提取、JsonRpcManager 100ms 超时与 cancelAll 清理、会话严格隔离、中文 UTF-8 与推理流式累加、审批会话归属、Mock 服务端 401 拦截与真实 RPC 链路，测试全部通过（退出码 0）。

## 真实命令与退出码记录

| 命令 | 退出码 | 产物/证据路径 | 说明 |
| --- | --- | --- | --- |
| `./scripts/check-upstream-sync` | 0 | 终端输出 / 脚本 | 远端与 reviewed 基线一致 (`b26d7c564ae5459bffd2f448118b986741f6720f`) |
| `node harmonyos/tests/protocol-suite.js` | 0 | `harmonyos/artifacts/protocol_test_report.txt` | 直接导入并驱动生产核心逻辑的回归测试，全部通过 |
| `hvigorw --no-daemon assembleHap` | 0 | `harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap` | 生成 347KB 中间编译 HAP (SHA-256: `3373086b41819896735f8263b9e3174266bf4c30656131a146f781dade3bd03d`)，详细日志写至 `harmonyos/artifacts/build_log.txt` |

## 剩余任务与后续规划

- [ ] 阶段二：远程工作区与文件浏览模块 (`HermesWorkspaceClient.ets`)
- [ ] 阶段二：图片/附件上传与产物下载模块 (`HermesFileClient.ets`)
- [ ] 阶段二：定时任务调度模块 (`HermesCronClient.ets`)
- [ ] 阶段三：真机 USB 调试、真机签名配置（当前 unsigned HAP 仅为中间编译产物，非最终可安装交付包）及外网免翻墙直连实测

## 人工依赖与门禁说明

- 当前阶段 DevEco Studio 本地工具链构建与隔离测试已全部通过；
- 真机签名与物理设备接入由监督者 Codex 视真机阶段向用户提出。
