# Hermex 鸿蒙功能移植对照表 (Feature Parity Matrix)

最后更新：2026-10-21 02:55 (Run 15 阶段更新)

> **验收标准分层说明**：
> 1. **代码实现 (Implementation)**：ArkTS 生产代码、网络协议客户端、ViewModel 及原生 ArkUI 入口是否完整实现并接入主界面。
> 2. **本地与模拟器端到端验证 (Verification)**：DevEco Studio SDK API12 真实编译 (`assembleHap` 退出码 0)、30 项全生命周期行为回归测试、以及在 OpenHarmony 6 官方模拟器（`127.0.0.1:5555`）上运行官方 `ohosTest` Hypium UiTest 走完完整用户旅程。
> 3. **真机验收 (Device Verification)**：HarmonyOS 6.1.0 真机由监督者独立执行的安装、交互与回读验证。严禁将本地测试通过夸大为真机验收。

| 编号 | 功能模块 | 上游 iOS 源码位置 | 鸿蒙实现源码与 UI 入口 | 代码实现 | 本地与模拟器验证 | 真机验收 | 现状与证据说明 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F01 | 连接与认证 | `HermesConnection.swift`, `HermesREST.swift` | `HermesRESTClient.ets`, `AuthStore.ets`, `ConnectionViewModel.ets`, `Index.ets` (服务器弹窗) | ✅ 已实现 | ✅ 30 项回归 + UiTest 通过 | ✅ 真机验证通过 | 支持多服务器、版本探测、Cookie Jar携带与 `/api/auth/me` 核验；Preferences 元数据 + `@ohos.security.asset` 硬件密文保管库；真机与模拟器UiTest均验证通过 |
| F02 | 会话管理 | `SessionList/`, `HermesSessionActions.swift` | `SessionListViewModel.ets`, `Index.ets` (会话列表抽屉) | ✅ 已实现 | ✅ 本地与UiTest全通过 | ✅ 真机验证通过 | 服务端真实 `session.create` 新建、`session.resume` 恢复、历史消息回填、恢复失败安全门禁拦截；UiTest在模拟器界面点击新建会话并成功接入真实 session |
| F03 | 原生聊天 | `Chat/`, `ChatTurnCoordinator.swift` | `ChatViewModel.ets`, `MarkdownView.ets`, `MarkdownParser.ets`, `Index.ets` | ✅ 已实现 | ✅ 模拟器官方UiTest通过 | 🟡 待真机复验 | 中文流式、推理流式折叠展开、Markdown代码块/表格/列表解析；模拟器UiTest实机输入中文指令发出并回读服务端精确终态回复 `"The command returned: 1."`，断线重连历史无损 |
| F04 | 实时控制与审批 | `HermesCall.swift` (`approvalRespond`, `sessionInterrupt`, `clarifyLock`) | `HermesGatewayClient.ets`, `ChatViewModel.ets`, `Index.ets` (审批/澄清卡片) | ✅ 已实现 | ✅ 模拟器官方UiTest通过 | 🟡 待真机复验 | 严格按请求 ID 与 async 代次处理审批生命周期；模拟器UiTest实机检测到审批卡片，点击【允许一次】(`btn_approval_once`)，服务端执行 `python3 -c "print(1)"`，断言卡片彻底销毁与发送恢复 |
| F05 | 模型与参数配置 | `HermesModelCatalog.swift`, `HermesCall.swift` (`modelOptions`, `config.set`) | `ChatViewModel.ets`, `Index.ets` (模型弹窗) | ✅ 已实现 | ✅ 本地与9199通过 (测试 10) | ⚪ 待真机操作 | 真实获取服务端 `model.options`，并通过 `config.set` 写回活跃会话模型配置 |
| F06 | 项目与工作区 | `HermesProjects.swift`, `HermesWorkspaceFileClient.swift` | `HermesWorkspaceClient.ets`, `WorkspaceViewModel.ets`, `GitWorkspaceViewModel.ets`, `Index.ets` | ✅ 已实现 | ✅ 本地回归通过 (测试 12, 13, 21) | ⚪ 待真机操作 | 路径遍历防线（拒绝 `../`, `/`, `~`, `\0`）、目录层级导航、文本查看、Git 分支切换 |
| F07 | 文件与附件 | `HermesREST.swift` (`downloadArtifact`, `uploadImage`), `HermesCall.swift` (`file.attach`) | `HermesFileClient.ets`, `AttachmentUtils.ets`, `WorkspaceViewModel.ets`, `Index.ets` | ✅ 已实现 | ✅ 本地回归通过 (测试 14, 19, 20) | ⚪ 待真机操作 | 系统 PhotoViewPicker / DocumentViewPicker，图片转码 `data_url` 上传，二进制文件沙箱持久化与 DocumentSaveOptions，`file.attach` RPC 文档附加；外部分享文件与录音消除沙箱裸露路径 |
| F08 | 任务与定时 Job | `HermesCronClient.swift` | `HermesCronClient.ets`, `CronViewModel.ets`, `Index.ets` (运维弹窗-任务Tab) | ✅ 已实现 | ✅ 本地回归通过 (测试 15) | ⚪ 待真机操作 | Cron 任务列表查询、手动触发执行 (`/run`)、暂停 (`/pause`)、恢复 (`/resume`) |
| F09 | 记忆与统计分析 | `HermesInsightsClient.ets`, `HermesSkillsClient.ets`, `HermesMemoryClient.ets` | `SkillsViewModel.ets`, `InsightsViewModel.ets`, `Index.ets` (运维弹窗-技能/设定/用量Tab) | ✅ 已实现 | ✅ 本地回归通过 (测试 16, 22) | ⚪ 待真机操作 | 对齐 `analytics.json` 字段，支持 7/30 天用量汇总与模型明细；技能开关；Soul 设定读取与保存 |
| F10 | 平台特性集成 | `HermesLiveActivityWidget/`, `HermesNotificationService/`, `HermesDeepLink.swift` | `NotificationUtils.ets`, `VoiceUtils.ets`, `ShareUtils.ets`, `DeepLinkUtils.ets`, `Index.ets` | ✅ 已实现 | ✅ 30 项回归 + 真实桌面前后台切换 + 真实网络扰动同会话重连全通过 | 🟡 模拟器通过 | `@ohos.notificationManager` 通知；真实 `@ohos.multimedia.media` (AVRecorder AAC/M4A 录音经Base64/file.attach附加 + AVPlayer 界面播放按钮)；`systemShare` 系统分享；深链三级精确匹配与未知服务器平滑弹窗；`driver.pressHome()` + `delegator.startAbility` 真实系统生命周期与真实端口扰动断线同会话恢复 |
| F11 | 看板与高级特性 | `HermesKanbanClient.swift`, `Kanban/` | `HermesKanbanClient.ets`, `KanbanViewModel.ets`, `Index.ets` (运维弹窗-看板Tab) | ✅ 已实现 | ✅ 30项回归 + 原生RCP实机回环通过 (UiTest 3) | ⚪ 待真机操作 | 使用 `@kit.RemoteCommunicationKit` (`rcp`) 发送真实原生 HTTP `PATCH`；反向端口 9198 宿主机已捕获 `method: "PATCH"`, `user-agent: "libcurl-agent/1.0"` 确定性证据；boards 包装 `{ boards, current, readOnly }`、驼峰游标与只读保护 |
| F12 | Legacy WebUI 兼容 | `Endpoints.swift`, `SSEClient.swift`, `APIClient+Chat.swift` | `LegacySSEClient.ets`, `SessionListViewModel.ets`, `ChatViewModel.ets`, `ConnectionViewModel.ets` | ✅ 已实现 | ✅ 30 项回归通过 (测试 17, 29) | ⚪ 待真机操作 | 对齐 `UPSTREAM_TESTED_SHA: c67fd2dd`；`cancelChatTurn` 严格使用 GET；单例持续 TextDecoder 流式拼包防中文乱码；处理 401/403/5xx 状态；主流程已接入会话拉取与聊天生成中断 |
| F13 | 国内直连与远程通道 | `docs/agents/hermes-server.md` | `Index.ets` (连接设置) | ✅ 已实现 | ⚪ 待网络验证 | ⚪ 待真机操作 | 无硬编码 127.0.0.1，支持任意公网 HTTPS/WSS 域名直连，待手机蜂窝网络真实连接验证 |
| F14 | 跨 Agent 调度验证 | `MIGRATION_PLAN.md` 74 节 | 独立隔离任务调度协议 | 🟡 联调中 | ⚪ 待验证 | ⚪ 待验证 | 需通过 Hermes 向隔离测试会话分发小型任务并收回产物 |
| F15 | 真机安装与升级 | `MIGRATION_PLAN.md` 75 节 | `harmonyos/entry/build/default/outputs/default/entry-default-signed.hap` | ✅ 已实现 | ✅ hvigor 编译 0 | 🟡 部分通过 | 监督者已在真机成功安装启动最新 signed HAP；覆盖升级后的数据持久性与会话保留仍待独立验证 |
