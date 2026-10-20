# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段五官方模拟器 Hypium 端到端 UI 审批流与原生 RCP 实机验证全线闭环 (Stage 5 Official Hypium UiTest End-to-End Chat Approval & Native RCP Device Verified)**
- 当前阶段：Run 14 工作块已全部落实：
  1. **官方 Hypium UiTest 真机端到端全旅程页面测试 (F01/F03/F04/F10)**：
     - 在 `harmonyos/entry/src/ohosTest/ets/test/ChatApprovalUi.test.ets` 中建立标准 stageMode 测试套件；
     - 在 OpenHarmony 6 官方模拟器（`127.0.0.1:5555`）上运行真实 `aa test`，通过 `@ohos.UiTest` 的 `Driver` 真实驱动应用界面组件（包含 `btn_server_settings`, `input_server_url`, `input_username`, `input_password`, `btn_connect_save`, `btn_new_session`, `input_chat_message`, `btn_send_message`, `btn_approval_once`）；
     - 完整闭环走完：输入服务器与公开测试账号凭据 -> 连接保存认证成功 -> 新建独立真实会话 -> 中文输入命令发出 -> 界面捕捉到审批卡片并点击【允许一次】 -> 服务端执行 `python3 -c "print(1)"` -> 界面回显包含 `'1'` 且生成停止 -> 切前后台（`appScenePhase`）断线重连 -> 会话历史回填验证完好无损；
     - 测试退出码：0，`Tests run: 3, Failure: 0, Error: 0, Pass: 3, Ignore: 0`。
  2. **官方 RemoteCommunicationKit 原生 RCP PATCH 动词主机实机证据 (F11 - REVIEW_DEVICE_14 审查项 3)**：
     - 在 `ChatApprovalUi.test.ets` 中加入 `testRcpNativePatchEcho`，通过真实业务类 `HermesKanbanClient.updateCardStatus` 触发 HarmonyOS 原生 `@kit.RemoteCommunicationKit` (`rcp.Request`)；
     - 经由设备反向映射端口 9198，在宿主机回显服务中捕获到确定性的请求凭证：
       `{"timestamp":"2026-10-20T18:27:49.553Z","method":"PATCH","url":"/api/plugins/kanban/tasks/card-patch-007?board=kanban-board-echo","headers":{"host":"127.0.0.1:9198","user-agent":"libcurl-agent/1.0",...},"body":"{\"status\":\"done\"}"}`；
     - 证实 HarmonyOS 官方 RCP 确实完整支持 HTTP `PATCH` 动词，无临时探针滞留生产 `EntryAbility`。
  3. **手机附件与语音录音真实网络管道对齐 (REVIEW_DEVICE_14 审查项 1)**：
     - `toggleVoiceRecording` 录音完成后读取二进制转为 Base64 dataURL，经由真实 Gateway RPC `file.attach` 附加到会话中，杜绝手机沙箱 `/data/...` 裸露路径；
     - 消息列表增加交互式语音播放按钮（`▶ 播放语音` / `⏹ 停止播放`），驱动 `VoiceUtils.playAudio`；
     - `handleInboundShare` 区分图片与文件，分别经由 `HermesFileClient.uploadImage` 或 `chatVm.attachDocument` 上传与附加，失败保留重试提示，取消不发假链接。
  4. **深链连接归一化与待认证平滑恢复 (REVIEW_DEVICE_14 审查项 2)**：
     - `findMatchingConnection` 实现稳定 ID、规范化 URL、名称三级递进精确匹配；
     - 当深链指定的服务器未预置时，自动为用户填入待配置服务器地址并打开连接设置弹窗，实现平滑待认证恢复。
  5. **环境与依赖纯净化**：
     - 恢复 `harmonyos/entry/oh-package.json5` 中 `@ohos/hypium` 为标准语义版本 `"1.0.19"`，消除本机绝对文件依赖；
     - 保持 `harmonyos/build-profile.json5` 的 `skip-worktree` 状态，严禁签名字段泄漏与修改。
- 更新时间：2026-10-21 02:30
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_DEVICE_14.md`, `RESUME_RUN14.md`

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
