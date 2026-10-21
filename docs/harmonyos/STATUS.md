# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段八（Run 20 完善）F02 会话精准锁定与系统分享安全关闭、F08 Cron 任务管理全生命周期响应式重构与官方模拟器 5/5 UiTest 全绿通过 (Stage 8 Full F02 & F08 Complete Lifecycle, Reactive VM Notification & Strict UiTest Verified)**
- 当前阶段：Run 19/20 工作块已全部落实：
  1. **F02 会话精准锁定与系统分享后置返回处理**：
     - 在导出点击 `btn_export_session_${targetId}` 唤起系统分享面板后，通过 `driver.pressBack()` 安全退出系统分享层，无缝返回会话列表原生视窗；
     - 搜索清空、会话重命名、置顶/取消置顶无损往返、归档/取消归档双向流转、分支克隆与导出完整无条件断言通过。
  2. **F08 Cron 调度架构与响应式刷新机制重构**：
     - 在 `CronViewModel.ets` 中引入 `CronViewModelListener` 与 `notify()` 通知机制，在 `loadJobs`、`createJob`、`updateJob`、`triggerJob`、`toggleJob`、`loadRuns` 全生命周期关键节点精准触发；
     - `Index.ets` 声明 `@State cronJobs` 等状态，并在 `aboutToAppear` 中接入监听器，将 VM 数据变更直接响应式发布至原生 ArkUI `ForEach`；
     - 任务列表默认按 `createdAt` 倒序排列，最新创建或编辑项置顶呈现，彻底解决列表固定高度虚拟化导致的新项脱离视口不可达问题；
     - 恢复普通用户 UI 纯净标题，移除了 `[ID:...]` 技术性视觉字段；通过独立只读服务回读（`HermesCronClient.listCronJobs`）与行内原生组件 ID 双重强断言锁定 `targetJobId`。
  3. **F08 上游真实契约与容错保障 (对齐 HermesREST.swift:500-516 & HermesCronClient.swift:32-49)**：
     - HTTP 424 警告语义支持（任务已持久化但调度注册失败，保留 warning 并正常拉取更新）；
     - 空字段（name、schedule、prompt）严格前端与 VM 拦截拒绝；
     - 409 运行冲突详情捕获与友好提示，手动触发超时扩展至 30s 且未知状态不盲目重试；
     - 新建测试任务固定使用 `model: 'hermex-stub'`，测试末尾通过 UI 精确暂停本轮任务，严格遵循非删除破坏性安全红线；
     - 任务执行历史实机核验非空，强断言包含真实 `targetJobId` 与 `cron_complete` 终态。
  4. **测试与编译全线通过**：
     - DevEco `assembleHap`（entry 与 entry@ohosTest）双 HAP 编译成功 (退出码 0)；
     - Node 回归测试 `protocol-suite.js` 扩展至 34 项全部通过 (退出码 0)；
     - 官方模拟器（`127.0.0.1:5555`）执行定向 `testCronManagementUserFlow` 通过 (1/1, 退出码 0)；
     - 官方模拟器执行 `run-e2e-with-network-test.js` 全量 5 项测试全部通过 (Tests run: 5, Failure: 0, Error: 0, Pass: 5, 退出码 0，6 阶段有效产物完整捕获)。
- 更新时间：2026-10-21 08:22
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`RESUME_RUN20.md`, `REVIEW_CRON19.md`, `REVIEW_SHARE_TEST19.md`

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

5. **全生命周期测试集扩展 (34 项全通过)**：
   - `protocol-suite.js` 扩展至 34 项测试，全量通过（退出码 0）：
     - TEST 33: SessionListViewModel & HermesRESTClient F02 会话管理全生命周期（分页、即时检索、置顶前置、归档隔离流、改名、分支克隆、导出与切服物理擦除）；
     - TEST 34: HermesCronClient & CronViewModel F08 任务管理全生命周期（列表加载、必填校验、424 调度警告语义、PUT编辑契约、/trigger 手动触发、409 运行冲突捕获、暂停/恢复、执行历史与切服代次隔离）。

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
