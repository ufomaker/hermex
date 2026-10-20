# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段六（Run 17 完善）F02 会话管理完整生命周期（非破坏性）、历史归一化轮次边界与运行态声明保留、33 项 Node 协议测试与模拟器官方 4/4 UiTest 全线通过 (Stage 6 Full F02 Session Management Lifecycle, Boundary Constraints & Official UiTest Verified)**
- 当前阶段：Run 17 工作块已全部落实：
  1. **历史归一化两大缺陷精准修复（落实 REVIEW_RUN16.md）**：
     - **缺陷 1（轮次 user 边界严格约束）**：`HermesHistoryNormalizer.flushPendingToCurrentTurn` 增加 `lastUserIndex` 边界限制，孤儿工具或中间轮次工具调用严格保持在自身助手上下文，严禁逆向污染前序已完成轮次；
     - **缺陷 2（运行态工具声明保留）**：历史中存在助手工具声明 (`assistant.tool_calls`) 但尚未收到对应 `tool` 结果时，生成 `ToolCallItem` 且赋予 `status: 'running'` 状态机语义，消息状态标记为 `'streaming'`，杜绝丢弃声明；
     - 协议回归测试新增 `TEST 32`，精准断言轮次边界与运行态声明保留。
  2. **协调器防竞态与安全清理升级（落实 REVIEW_RUN16.md 缺陷 3）**：
     - 产物目录移除硬编码，使用相对路径或 `ARTIFACTS_DIR` / `BRAIN_DIR`；
     - `hdcExec` 杜绝吞异常；远端与本地捕获前清理旧文件，防止旧产物残留；
     - 截图严格校验 JPEG 魔数 `[0xFF, 0xD8, 0xFF]`；
     - 引入统一的 `ensureCleanup()`，在 `exit`, `SIGINT`, `SIGTERM`, `uncaughtException` 时必定终止子进程并恢复反向端口 `rport tcp:9199 tcp:9199`。
  3. **F02 会话管理全部非破坏性功能完整实现（严格禁止删除）**：
     - 严格对齐上游 `HermesSessionActions.swift`、`APIClient+Sessions.swift` 与 `SessionListViewModel.swift`：
       - **分页与去重**：`listSessionsPage` (offset, limit, total, hasMore) 支持首屏 20 项与追加加载，Set 去重；
       - **搜索与清空恢复**：输入即时本地模糊匹配 + 联级服务端搜索，一键清除输入框 (`clearSearch`) 瞬间无损恢复全量会话；
       - **分类 Tab 切换**：全部、置顶 📌、已归档 📦 三态隔离，默认视图隔离已归档会话；
       - **改名回显**：`renameSession` 接入原生 `@kit.RemoteCommunicationKit` (`rcp`) HTTP `PATCH /api/sessions/{id}` (`{ title }`)，UI 弹窗支持输入并即时就地回读；
       - **置顶与前置排序**：`togglePinSession` 发送 `PATCH /api/sessions/{id}` (`{ pinned }`)，置顶会话在列表中置顶前置展示；
       - **归档与恢复**：`toggleArchiveSession` 发送 `PATCH /api/sessions/{id}` (`{ archived }`)，全量视图与归档视图严格过滤；
       - **分支克隆 (Duplication)**：`duplicateSession` 实现导出完整 JSON -> 清洗血缘标识、parent_session_id 与消息 row id -> 生成 Hermes 标准 ID -> 导入 -> 重命名为 `<原标题> (copy)` -> 插入列表顶部；
       - **导出**：`exportSession` 对应 `GET /api/sessions/{id}/export?profile={profile}`；
       - **切服与代次竞态保护**：`requestSerial` 自增保护，拦截切服慢请求覆盖快请求；
       - **非破坏性承诺**：严格禁止会话物理删除能力。
  4. **全生命周期测试集扩展至 33 项全绿 (Node)**：
     - `node harmonyos/tests/protocol-suite.js` 扩展至 33 项全量测试，覆盖 35 条会话分页追加 (20+15)、搜索恢复、置顶排序、归档过滤、改名、分支克隆、JSON导出与切服竞态，退出码 0。
  5. **官方模拟器端到端 UI 测试 (4/4 全绿)**：
     - `testCompleteChatAndApprovalFlow`：审批卡片点击允许一次、`python3 -c "print(1)"` 执行、终态回复精确回读、真实生命周期前后台切换、真实端口扰动断线与重连同会话恢复无损；
     - `testRcpNativePatchEcho`：原生 RCP 发送 HTTP `PATCH` 至宿主机 9198 回显服务验证；
     - `testSessionManagementUserFlow` (新增 F02 UI 自动化)：模拟器打开会话抽屉、搜索栏输入过滤、一键清空恢复、Tab切换、改名弹窗输入保存回显、置顶操作与关闭抽屉；
     - 4 个测试全部通过 (`Tests run: 4, Failure: 0, Error: 0, Pass: 4, Ignore: 0`)，退出码 0。
  6. **证据分级明确记录**：
     - **Node 平台回归**：`protocol-suite.js` 33 项业务类单元与契约测试全通过；
     - **官方隔离服务联调**：Hermes 0.21.5 / ca678285（端口 9199，`hermex/hermex-local`）真实握手、会话创建、审批执行与历史回填通过；
     - **官方模拟器 UI 自动化**：OpenHarmony 6.0.1.112 API 21（`127.0.0.1:5555`）通过完整 4 项自动化测试与 6 阶段有效产物捕获，产物留档在 `test-artifacts/`；
     - **真机设备**：待监督者在实际物理设备上验证。
- 更新时间：2026-10-21 06:00
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_RUN16.md`, `RESUME_RUN17.md`, `INCIDENT_IME_14.md`

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
