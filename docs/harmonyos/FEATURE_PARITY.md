# Hermex 鸿蒙功能移植对照表 (Feature Parity Matrix)

最后更新：2026-10-21 00:15 (Run 12 阶段更新)

> **验收标准分层说明**：
> 1. **代码实现 (Implementation)**：ArkTS 生产代码、网络协议客户端、ViewModel 及原生 ArkUI 入口是否完整实现并接入主界面。
> 2. **本地验证 (Local Verification)**：DevEco Studio SDK API12 真实编译 (`assembleHap` 退出码 0)、28 项全生命周期行为回归测试、以及针对 127.0.0.1:9199 隔离 Hermes 后端的实际调用。
> 3. **真机验收 (Device Verification)**：HarmonyOS 6.1.0 真机由监督者独立执行的安装、交互与回读验证。严禁将本地测试通过夸大为真机验收。

| 编号 | 功能模块 | 上游 iOS 源码位置 | 鸿蒙实现源码与 UI 入口 | 代码实现 | 本地验证 | 真机验收 | 现状与证据说明 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F01 | 连接与认证 | `HermesConnection.swift`, `HermesREST.swift` | `HermesRESTClient.ets`, `AuthStore.ets`, `ConnectionViewModel.ets`, `Index.ets` (服务器弹窗) | ✅ 已实现 | ✅ 28 项回归通过 (测试 1, 2, 11) | ✅ 真机验证通过 | 支持多服务器、版本探测、Cookie Jar携带与 `/api/auth/me` 核验；Preferences 元数据 + `@ohos.security.asset` 硬件密文保管库；真机已验证冷启动与登录 |
| F02 | 会话管理 | `SessionList/`, `HermesSessionActions.swift` | `SessionListViewModel.ets`, `Index.ets` (会话列表抽屉) | ✅ 已实现 | ✅ 本地与9199通过 (测试 2, 5, 6, 24) | ✅ 真机验证通过 | 服务端真实 `session.create` 新建、`session.resume` 恢复、历史消息回填、恢复失败安全门禁拦截 |
| F03 | 原生聊天 | `Chat/`, `ChatTurnCoordinator.swift` | `ChatViewModel.ets`, `MarkdownView.ets`, `MarkdownParser.ets`, `Index.ets` | ✅ 已实现 | ✅ 本地与9199通过 (测试 8, 18, 24, 25) | 🟡 待真机复验 | 中文流式、推理流式折叠展开、Markdown代码块/表格/列表解析；@Watch流式刷新；真机已通过握手，等待最新消息流真机验收 |
| F04 | 实时控制与审批 | `HermesCall.swift` (`approvalRespond`, `sessionInterrupt`, `clarifyLock`) | `HermesGatewayClient.ets`, `ChatViewModel.ets`, `Index.ets` (审批/澄清卡片) | ✅ 已实现 | ✅ 本地与9199通过 (测试 9, 24, 25, 26) | 🟡 待真机复验 | 去除 fixture 命令依赖，严格按请求 ID 与 async 代次处理审批生命周期；`session.interrupt` 停止；真机已通过握手，审批卡片等待真机独立验收 |
| F05 | 模型与参数配置 | `HermesModelCatalog.swift`, `HermesCall.swift` (`modelOptions`, `config.set`) | `ChatViewModel.ets`, `Index.ets` (模型弹窗) | ✅ 已实现 | ✅ 本地与9199通过 (测试 10) | ⚪ 待真机操作 | 真实获取服务端 `model.options`，并通过 `config.set` 写回活跃会话模型配置 |
| F06 | 项目与工作区 | `HermesProjects.swift`, `HermesWorkspaceFileClient.swift` | `HermesWorkspaceClient.ets`, `WorkspaceViewModel.ets`, `GitWorkspaceViewModel.ets`, `Index.ets` | ✅ 已实现 | ✅ 本地回归通过 (测试 12, 13, 21) | ⚪ 待真机操作 | 路径遍历防线（拒绝 `../`, `/`, `~`, `\0`）、目录层级导航、文本查看、Git 分支切换 |
| F07 | 文件与附件 | `HermesREST.swift` (`downloadArtifact`, `uploadImage`), `HermesCall.swift` (`file.attach`) | `HermesFileClient.ets`, `AttachmentUtils.ets`, `WorkspaceViewModel.ets`, `Index.ets` | ✅ 已实现 | ✅ 本地回归通过 (测试 14, 19, 20) | ⚪ 待真机操作 | 系统 PhotoViewPicker / DocumentViewPicker，图片转码 `data_url` 上传，二进制文件沙箱持久化与 DocumentSaveOptions，`file.attach` RPC 文档附加 |
| F08 | 任务与定时 Job | `HermesCronClient.swift` | `HermesCronClient.ets`, `CronViewModel.ets`, `Index.ets` (运维弹窗-任务Tab) | ✅ 已实现 | ✅ 本地回归通过 (测试 15) | ⚪ 待真机操作 | Cron 任务列表查询、手动触发执行 (`/run`)、暂停 (`/pause`)、恢复 (`/resume`) |
| F09 | 记忆与统计分析 | `HermesInsightsClient.ets`, `HermesSkillsClient.ets`, `HermesMemoryClient.ets` | `SkillsViewModel.ets`, `InsightsViewModel.ets`, `Index.ets` (运维弹窗-技能/设定/用量Tab) | ✅ 已实现 | ✅ 本地回归通过 (测试 16, 22) | ⚪ 待真机操作 | 对齐 `analytics.json` 字段，支持 7/30 天用量汇总与模型明细；技能开关；Soul 设定读取与保存 |
| F10 | 平台特性集成 | `HermesLiveActivityWidget/`, `HermesNotificationService/` | `NotificationUtils.ets`, `ChatViewModel.ets`, `EntryAbility.ets` | ✅ 已实现 | ✅ 本地回归通过 (测试 28) | ⚪ 待真机操作 | 封装 `@ohos.notificationManager`，后台与多任务状态下分发审批待办与任务完成提醒，前后台切换与异常平滑降级 |
| F11 | 看板与高级特性 | `HermesKanbanClient.swift`, `Kanban/` | `HermesKanbanClient.ets`, `KanbanViewModel.ets`, `Index.ets` (运维弹窗-看板Tab) | ✅ 已实现 | ✅ 本地回归通过 (测试 23, 27) | ⚪ 待真机操作 | `/api/plugins/kanban` 可用性探测、看板列表、泳道卡片快照、新建任务卡片、卡片状态流转 |
| F12 | Legacy WebUI 兼容 | `Endpoints.swift`, `SSEClient.swift` | `LegacySSEClient.ets`, `ConnectionViewModel.ets` | ✅ 已实现 | ✅ 本地回归通过 (测试 17) | ⚪ 待真机操作 | 对齐 `UPSTREAM_TESTED_SHA: c67fd2dd`，`/health` 探针降级探测与 SSE 事件分包解析 |
| F13 | 国内直连与远程通道 | `docs/agents/hermes-server.md` | `Index.ets` (连接设置) | ✅ 已实现 | ⚪ 待网络验证 | ⚪ 待真机操作 | 无硬编码 127.0.0.1，支持任意公网 HTTPS/WSS 域名直连，待手机蜂窝网络真实连接验证 |
| F14 | 跨 Agent 调度验证 | `MIGRATION_PLAN.md` 74 节 | 独立隔离任务调度协议 | 🟡 联调中 | ⚪ 待验证 | ⚪ 待验证 | 需通过 Hermes 向隔离测试会话分发小型任务并收回产物 |
| F15 | 真机安装与升级 | `MIGRATION_PLAN.md` 75 节 | `harmonyos/entry/build/default/outputs/default/entry-default-signed.hap` | ✅ 已实现 | ✅ hvigor 编译 0 | 🟡 部分通过 | 监督者已在真机成功安装启动最新 signed HAP；覆盖升级后的数据持久性与会话保留仍待独立验证 |
