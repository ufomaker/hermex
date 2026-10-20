# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段五（Run 16 完善）通用历史归一化、真实服务端工具调用与结果结构化恢复、协调器防竞态与严格断言全线通过 (Stage 5 Universal History Normalization, Tool Association & Robust Coordinator Verified)**
- 当前阶段：Run 16 工作块已全部落实：
  1. **生产级历史归一化引擎与工具关联（落实 REVIEW_HISTORY_16.md）**：
     - 新建生产工具类 `HermesHistoryNormalizer.ets`，严格对齐上游 `HermesTranscriptHistory.swift` 与 `ChatMessage.swift` 规范；
     - 准确解析 `assistant.tool_calls` 中的嵌套 `function.name` 与 `function.arguments`，维护跨轮次调用映射表；
     - `role === "tool"` 绝不伪装为助手独立气泡，提取输出结构（解析 JSON `output`/`error`/`exit_code`，或保留纯文本）并正确绑定至对应工具调用声明；
     - 工具执行状态（`completed` / `failed`）根据退出码与错误字段动态判别；
     - 彻底消除恢复历史后全段原始 JSON 覆盖助手正文的缺陷，正常保留 assistant 文本；
     - 兼容未知角色与字段，无丢失数据风险；
     - 生产 `HermesRESTClient.getSessionMessages` 全面接入 `HermesHistoryNormalizer.normalize`。
  2. **协议与行为回归套件扩展至 31 项全绿**：
     - 新增 `TEST 31`，直接驱动真实隔离服务证据 fixture `run15-server-evidence.json`；
     - 覆盖并发多工具、乱序返回、工具执行失败、非 JSON 纯文本、无 ID 工具兜底关联；
     - 31/31 测试全量通过（退出码 0）。
  3. **协调器防竞态与产物有效性增强（落实 REVIEW_UI_15.md）**：
     - 测试用例与协调器引入阶段同步（`PHASE: CAPTURE_STAGE_...`），预留稳定延迟，杜绝异步抢跑导致截图截入系统桌面过度帧；
     - 产物目录改为相对路径 `test-artifacts/` 或由 `ARTIFACTS_DIR` 环境变量指定；
     - `captureArtifacts` 增加严格门禁：截图必须存在且 > 1000 字节，布局树必须为有效 JSON 且子节点非空；
     - 退出核验增加全量检查：必须 3 个用例全部通过、零失败、零错误、断网与恢复两个阶段齐备、且所有 6 个阶段有效产物全部捕获。
  4. **UI 测试多重断言闭环（模拟器 127.0.0.1:5555）**：
     - 带有动态唯一种子 `RUN16_mvh6l6d7` 的 prompt 完整保留；
     - 工具卡片正确显示 `工具: terminal`（非 `tool`）与 `已完成`；
     - 工具输出显示为 `1`；
     - 终态回复 `The command returned: 1.` 完整呈现；
     - 绝对断言：界面绝无 `"exit_code": 0` 等原始 JSON 气泡；
     - 记录会话 ID 为真实 `20261021_051410_b8fe7b`，重连确为同一会话。
  5. **证据分级明确记录**：
     - **Node 平台回归**：`protocol-suite.js` 31 项业务类单元与契约测试全通过；
     - **官方隔离服务联调**：Hermes 0.21.5 / ca678285（端口 9199，`hermex/hermex-local`）通过真实握手、会话创建、审批执行与历史回填；
     - **官方模拟器 UI 自动化**：OpenHarmony 6.0.1.112 API 21（`127.0.0.1:5555`）通过完整 6 阶段自动化测试，产物留档在 `test-artifacts/` 与 Brain 目录；
     - **真机设备**：待监督者在实际物理设备上验证。
- 更新时间：2026-10-21 05:16
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_HISTORY_16.md`, `REVIEW_UI_15.md`, `INCIDENT_IME_14.md`, `RESUME_RUN16.md`

## 监督意见落实与本次核心重构详单

1. **Kanban 原生 RCP PATCH 与对象包装契约 (落实 REVIEW_PLATFORM_13.md & REVIEW_SCOPE_12.md)**：
   - 解决 OpenHarmony 原生 `@ohos.net.http` 栈在底层 C++ 拒绝非标准动词抛出 401 Parameter error 的缺陷，全面改用 `@kit.RemoteCommunicationKit` (`rcp`) 的 `new rcp.Request(targetUrl, 'PATCH', headers, JSON.stringify(payload))` 执行状态流转；
   - 严格解析 boards 响应包装对象 `{ boards: [{ slug, name, ... }], current, readOnly }`，以 `slug` 为唯一标识，`name` 为展示名；
   - 解析驼峰整数 `latestEventId` 并落实只读保护；移除临时探针代码。

2. **Legacy SSE 规范对齐与中文防截断 (落实 REVIEW_PLATFORM_13.md)**：
   - `cancelChatTurn` 对齐 upstream 契约发送 HTTP `GET /api/chat/cancel?stream_id=...`；
   - 在流式连接中保持单实例持续 `util.TextDecoder.create('utf-8')` 与 `{ stream: true }`，解决中文字节跨数据包损坏问题；
   - 处理非 200 HTTP 响应，触发 `onError` 并安全销毁客户端；
   - 接入 ViewModel 消息收发与中断主流程。

3. **原生语音录音与播放 (落实 REVIEW_PLATFORM_13.md)**：
   - `VoiceUtils.ets` 真实接入 `@ohos.multimedia.media`，录音落盘校验文件大小 `> 0`；
   - 播放接通 `AVPlayer` 状态回调；
   - `Index.ets` 底部工具栏接入麦克风权限请求、录音、停止与语音标签附加。

4. **系统分享、深链与前后台恢复 (落实 REVIEW_PLATFORM_13.md)**：
   - `ShareUtils.ets` 接入 `systemShare.ShareController`；
   - `DeepLinkUtils.ets` 优化冷/热启动派发状态机；
   - `Index.ets` 观察 `appScenePhase` 并在回到前台时自动尝试恢复未就绪的连接与会话。

5. **全生命周期测试集扩展 (30 项全通过)**：
   - `protocol-suite.js` 扩展至 30 项测试，全量通过（退出码 0）：
     - TEST 29: 真实测试 `LegacySSEClient` 完整聊天轮次、GET 取消、跨块分包中文解码与 401 错误拦截；
     - TEST 30: 真实测试 `DeepLinkUtils` 冷/热启动派发、`ShareUtils` 文本/文件系统分享与 Want 解析、`VoiceUtils` 真实权限/录音落盘/AVPlayer 播放状态机。

6. **真实命令与退出码记录**：

| 命令 | 退出码 | 产物/证据路径 | 说明 |
| --- | --- | --- | --- |
| `node harmonyos/tests/protocol-suite.js` | 0 | `harmonyos/tests/protocol-suite.js` | 30 项全生命周期生产业务类测试全部通过 (退出码 0) |
| `cd harmonyos && hvigorw --no-daemon assembleHap` | 0 | `harmonyos/entry/build/default/outputs/default/entry-default-signed.hap` | ArkTS 编译通过，生成 1,066,700 字节 signed HAP 产物 (退出码 0) |
| `hdc -t 127.0.0.1:5555 install -r ...hap` | 0 | 模拟器 `127.0.0.1:5555` | 覆盖安装 signed HAP 成功 (`install bundle successfully`) |
| `hdc -t 127.0.0.1:5555 shell "aa start ..."` | 0 | 模拟器 `127.0.0.1:5555` (PID 12064) | 启动 EntryAbility 成功，Index 原生 UI 加载完成 |
| `hdc -t 127.0.0.1:5555 shell "aa start ... -U 'hermex://new-chat'"` | 0 | hilog `EntryAbility` | 热启动深链接收与路由解析成功，日志脱敏验证无密钥泄漏 |
| `hdc -t 127.0.0.1:5555 shell "aa start ... -A 'ohos.want.action.sendData' ..."` | 0 | hilog `EntryAbility` | 系统分享 Want 接收与解析成功 (`hasText=true, hasUri=false`) |

## 权限与安全门禁

- 本 Agent 严格遵守权限与操作边界：
  - 未读取、未记录、未提交任何签名密钥或证书，`harmonyos/build-profile.json5` 保持 `skip-worktree` (`S`)；
  - 未动用、未重启 `:61688` 生产服务，未读取 `~/.hermes` 生产配置与历史会话；
  - 未创建任何子 Agent，全流程保持 Flash High 单一进程执行；
  - 所有改动仅限当前项目源码与文档，向用户 Fork 分支推送。
