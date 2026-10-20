# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段七（Run 18 完善）F02 会话管理真实契约对齐、切服双向隔离与官方模拟器 4/4 UiTest 无条件断言全绿通过 (Stage 7 Full F02 Real Contract Parity, Multi-Stream Isolation & Strict UiTest Verified)**
- 当前阶段：Run 18 工作块已全部落实：
  1. **HermesRESTClient.searchSessions 严格契约修复 (对齐 upstream HermesREST.swift:490)**：
     - 查询参数由 `query` 修正为 `q`，并严格将 `+` 编码转义为 `%2B`；
     - 显式携带 `exclude_sources=cron,kanban,oneshot,subagent,tool`；
     - 空搜索词直接返回 `[]`，杜绝多余无效请求；过滤群聊房间会话。
  2. **listSessionsPage 归档流契约与服务端回填过滤 (对齐 upstream HermesREST.swift:448, HermesSessionPage.swift:204-206)**：
     - `archived` 参数由布尔字符串修正为 `'only'` 或 `'exclude'`，携带 `order=recent` 与 `exclude_sources`，活跃流携带 `min_messages=1`；
     - `SessionStreamState.appendPage` 增加 `Boolean(s.is_archived) === isArchivedTarget` 严格状态门禁，主动过滤服务端向归档流回填的未归档置顶项。
  3. **SessionListViewModel 架构重构与多流隔离**：
     - 划分独立的 `activeStream` 与 `archivedStream`，分别维护独立分页游标、总数与已加载标识；
     - 切换分类 Tab 至 `archived` 时若未加载自动发起服务端异步拉取；
     - 归档/解归档在两个流之间执行无损双向转移；
     - 切换服务器或 Profile 时立即物理清空旧流与展示列表，杜绝脏数据残留；
     - Legacy WebUI 严格拒绝改名、置顶、归档、克隆与导出，绝不在内存中伪造变更。
  4. **UiTest 移除宽容守卫与全流程真机断言**：
     - `ChatApprovalUi.test.ets` 中彻底移除 `if (buttons.length > 0)` 宽容守卫；
     - 无条件断言按钮存在，完整走通搜索 "python3" 匹配、改名弹窗输入保存、置顶与置顶Tab筛选、归档与归档Tab筛选、解归档恢复与全部Tab回显闭环。
  5. **测试与编译全线通过**：
     - DevEco `assembleHap`（entry 与 entry@ohosTest）双 HAP 编译成功 (退出码 0)；
     - Node 回归测试 `protocol-suite.js` 扩展至 33 项全部通过 (退出码 0)；
     - 官方模拟器（`127.0.0.1:5555`）执行 `run-e2e-with-network-test.js` 4 项测试全部通过 (0 Failures, 0 Errors, 6 阶段有效产物完整捕获并镜像至 Brain 目录)。
- 更新时间：2026-10-21 06:48
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_F02_18.md`, `RESUME_RUN18.md`

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
