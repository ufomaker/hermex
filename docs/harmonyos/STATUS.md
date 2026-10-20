# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段四平台核心能力接入、Kanban 原生 RCP PATCH、Legacy SSE 轮次生命周期与深链/分享/语音系统集成完成 (Stage 4 Platform Native RCP, Legacy SSE Streaming Lifecycle, Voice AVRecorder/AVPlayer, Share & DeepLink Platform Integration)**
- 当前阶段：Run 13 工作块已全部落实：
  1. **Kanban 原生 RCP PATCH 与契约对齐 (F11)**：
     - 在 `HermesKanbanClient.ets` 中使用华为 HarmonyOS `@kit.RemoteCommunicationKit` (`rcp`) 发送真实 HTTP `PATCH` 动词执行 `updateCardStatus`，彻底解决 `@ohos.net.http` 底层 NAPI 对非标准动词抛出 `code:401 Parameter error` 异常的问题；
     - 对齐 upstream 看板响应包装结构 `{ boards: [{ slug, name, ... }], current, readOnly }`，采用 `slug` 作为唯一标识、`name` 呈现界面；解析驼峰整数 `latestEventId` 游标；
     - 彻底清理 `EntryAbility.ets` 中的临时探针 `runNativeSelfCheck` 与 `testSelfCheck`。
  2. **Legacy WebUI SSE 完整轮次与跨分包流式解码 (F12)**：
     - 将 `LegacySSEClient.cancelChatTurn` 修正为 HTTP `GET /api/chat/cancel?stream_id=...`，严格对齐 upstream `APIClient+Chat.swift:34-35`；
     - 采用跨 TCP 分包持续会话的单例 `util.TextDecoder.create('utf-8')` 并配置 `{ stream: true }`，彻底解决中文字符多字节（如 `'好'` [0xe5, 0xa5, 0xbd]）被网络块切分时损坏的隐患；
     - 严格处理非 200 HTTP 响应（如 401/403/5xx），触发确定性 `onError` 回调与资源销毁；
     - 接入生产 `SessionListViewModel.loadSessions` 与 `ChatViewModel.sendMessage`/`stopGenerating`，实现 legacy-webui 历史查看、消息流式接收与生成中断。
  3. **原生平台级语音录音与播放状态机 (F10 - VoiceUtils.ets)**：
     - 彻底剔除布尔占位符，基于 `@ohos.multimedia.media` (`AVRecorder` 与 `AVPlayer`)、`@ohos.file.fs` 及 `@ohos.abilityAccessCtrl` 完整实现平台能力；
     - 录音使用 AAC 编码、M4A 容器（`CFT_MPEG_4A`）、44100Hz、96kbps，绑定文件描述符 `fd://${file.fd}`，落盘验证真实文件大小 `statSync.size > 0`；
     - 播放使用 AVPlayer 驱动状态机（`initialized` -> `prepared` -> `playing` -> `completed`/`error`）；并在底部输入栏接入录音/停止/附加交互。
  4. **系统分享、深层链接与前后台生命周期集成 (F10 - ShareUtils.ets, DeepLinkUtils.ets, EntryAbility.ets, Index.ets)**：
     - 接入华为官方 ShareKit `@hms.collaboration.systemShare` (`ShareController` + `SharedData` + `SharedRecord`)，并保留 `startAbility` 安全降级；
     - 严格脱敏公共 `hilog` 输出，仅记录事件类型与布尔标记（`hasText=true, hasUri=false`），绝不泄漏私密会话内容或带凭证 URI；
     - `AppDeepLinkRouter` 区分冷启动挂起队列与热启动活跃监听器分发，避免二次重复消费与监听器泄漏；
     - `Index.ets` 观察 `appScenePhase`，在从后台切回前台（`active`）时触发会话连接检查与无感恢复。
  5. **测试与多维验收**：
     - `protocol-suite.js` 扩展至 30 项全生命周期生产业务类测试，全部通过（退出码 0）；
     - `hvigorw --no-daemon assembleHap` 构建成功（退出码 0），生成 1,066,700 字节 signed HAP；
     - 并在 OpenHarmony 6 模拟器（`127.0.0.1:5555`）上通过 `hdc` 安装、启动、热分发深链 want 及外部分享 want，hilog 回读全部成功。
- 更新时间：2026-10-21 01:30
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_01.md` ~ `REVIEW_WS_DEVICE_01.md`, `REVIEW_APPROVAL_DEVICE_01.md`, `RESUME_RUN12.md`, `REVIEW_SCOPE_12.md`, `RESUME_RUN13.md`, `REVIEW_PLATFORM_13.md`

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
