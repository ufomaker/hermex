# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段五（Run 15 完善）官方模拟器 Hypium 端到端 UI 审批流、精确终态回复、真实系统生命周期与真实网络扰动断线同会话重连全线通过 (Stage 5 Full Official Hypium E2E UiTest, Exact Reply, Real Lifecycle & Real Network Drop/Reconnect Verified)**
- 当前阶段：Run 15 工作块已全部落实：
  1. **核心 UI 精确正文与状态机断言 (落实 REVIEW_UI_14.md 审查项 1)**：
     - 在 `harmonyos/entry/src/ohosTest/ets/test/ChatApprovalUi.test.ets` 中，将弱断言 `ON.text('1')` 彻底替换为对 stub 模型真实终态回复 `"The command returned: 1."` 的精确文本断言；
     - 指令输入引入毫秒级动态唯一标识 `【RUN15_${timestamp}】请执行命令: python3 -c 'print(1)'`，严密防范多轮测试历史消息脏数据污染；
     - 严格断言审批卡片（`btn_approval_once`）彻底销毁、生成状态（`btn_stop_generating`）彻底终止、发送入口（`btn_send_message`）恢复可用、助手消息气泡（`msg_bubble_assistant`）成功渲染。
  2. **真实系统生命周期前后台切换 (落实 REVIEW_UI_14.md 审查项 2)**：
     - 废除单测内部篡改 `AppStorage.setOrCreate('appScenePhase', ...)` 的假前后台逻辑；
     - 改用真实系统级操作：通过 `driver.pressHome()` 真实退出至系统桌面，触发 EntryAbility 真实 `onBackground`，随后通过 `delegator.startAbility({ bundleName, abilityName: 'EntryAbility' })` 真实唤醒应用触发 `onForeground`；
     - 切回前台后严格验证同一会话历史记录与精确正文无损回填。
  3. **真实网络扰动与同会话重连 (落实 REVIEW_UI_14.md 审查项 3)**：
     - 编写宿主机协调器脚本 `harmonyos/tests/run-e2e-with-network-test.js`，通过实时监听 hilog 事件阶段：
       - 在测试发出 `PHASE: DISCONNECT_TRIGGER_READY` 时，宿主机执行 `hdc fport rm tcp:9199 tcp:9199` 真实切断端口；
       - UI 状态栏组件 `txt_connection_status` 真实感知网络中断并显示为 `"已断开"`（红灯）；
       - 在测试发出 `PHASE: DISCONNECT_VERIFIED_NOW_RECONNECT` 时，宿主机执行 `hdc rport tcp:9199 tcp:9199` 恢复反向端口；
       - 点击状态栏重新连接按钮 `btn_reconnect_status`，触发 `chatVm.attachSession` 经由 `session.resume` 恢复到同一会话 (`storedSessionId`)；
       - 状态栏正确变为 `"会话已恢复"`，历史消息完整保留，终态回复 `"The command returned: 1."` 完好无损。
  4. **六大阶段真实屏幕与布局树快照留档**：
     - `snap_01_approval_card.jpeg` / `layout_01_approval_card.json`
     - `snap_02_exact_reply.jpeg` / `layout_02_exact_reply.json`
     - `snap_03_after_real_lifecycle.jpeg` / `layout_03_after_real_lifecycle.json`
     - `snap_04_before_disconnect.jpeg` / `layout_04_before_disconnect.json`
     - `snap_05_during_disconnect.jpeg` / `layout_05_during_disconnect.json`
     - `snap_06_reconnected_history.jpeg` / `layout_06_reconnected_history.json`
  5. **官方 Hypium UiTest + RCP PATCH 全量通过**：
     - `Tests run: 3, Failure: 0, Error: 0, Pass: 3, Ignore: 0` (退出码 0)
  6. **安全与协议合规（落实 INCIDENT_IME_14.md）**：
     - 严禁且无任何自动勾选、自动同意隐私协议或输入法协议的违规行为；
     - 严禁且未通过 shell 命令预先绕过授权或授予敏感系统权限；
     - `harmonyos/build-profile.json5` 持续保持 `skip-worktree` (`S`)，签名字段安全无泄漏。
- 更新时间：2026-10-21 02:55
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_UI_14.md`, `INCIDENT_IME_14.md`, `RESUME_RUN15.md`

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
