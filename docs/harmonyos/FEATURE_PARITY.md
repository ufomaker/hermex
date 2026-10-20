# Hermex 鸿蒙功能移植对照表 (Feature Parity Matrix)

最后更新：2026-10-20

| 编号 | 功能模块 | 上游 iOS 源码位置 | 鸿蒙 ArkTS/ArkUI 实现位置 | 状态 | 说明与验证 |
| --- | --- | --- | --- | --- | --- |
| F01 | 连接与认证 | `HermesMobile/Networking/Hermes/HermesConnection.swift`, `HermesREST.swift` | `harmonyos/entry/src/main/ets/network/HermesConnection.ets`, `HermesRESTClient.ets`, `AuthStore.ets` | 已就绪 | 多服务器地址配置、版本探测、登录与凭据安全存储 |
| F02 | 会话管理 | `HermesMobile/Features/SessionList/`, `HermesSessionActions.swift` | `harmonyos/entry/src/main/ets/viewmodel/SessionListViewModel.ets`, `pages/SessionListPage.ets` | 已就绪 | 会话列表拉取、新建、恢复、标题、选择切换 |
| F03 | 原生聊天 | `HermesMobile/Features/Chat/`, `HermesChatTurnCoordinator.swift` | `harmonyos/entry/src/main/ets/pages/ChatPage.ets`, `viewmodel/ChatViewModel.ets`, `components/ChatMessageItem.ets` | 已就绪 | ArkUI 原生聊天渲染、流式消息（message.delta）、推理过程（reasoning.delta）、Markdown/代码块展示 |
| F04 | 实时控制与审批 | `HermesMobile/Networking/Hermes/HermesCall.swift` (`approvalRespond`, `sessionInterrupt`, `clarifyLock`) | `harmonyos/entry/src/main/ets/network/HermesGatewayClient.ets`, `viewmodel/ChatViewModel.ets` | 已就绪 | 停止生成（prompt.interrupt）、审批弹窗卡片（approval.respond）、澄清问题交互（clarify.respond） |
| F05 | 模型与参数配置 | `HermesMobile/Networking/Hermes/HermesModelCatalog.swift`, `HermesCall.swift` (`modelOptions`) | `harmonyos/entry/src/main/ets/viewmodel/ModelCatalogViewModel.ets`, `components/ModelSelectorDialog.ets` | 已就绪 | 读取真实模型列表、切换模型参数 |
| F06 | 项目与工作区 | `HermesMobile/Networking/Hermes/HermesProjects.swift`, `HermesWorkspaceFileClient.swift` | `harmonyos/entry/src/main/ets/network/HermesWorkspaceClient.ets` | 待拓展 | 文件列表与代码浏览 |
| F07 | 文件与附件 | `HermesMobile/Networking/Hermes/HermesREST.swift` (`downloadArtifact`, `uploadImage`) | `harmonyos/entry/src/main/ets/network/HermesFileClient.ets` | 待拓展 | 图片附件上传、产物下载 |
| F08 | 任务与定时 Job | `HermesMobile/Networking/Hermes/HermesCronClient.swift` | `harmonyos/entry/src/main/ets/network/HermesCronClient.ets` | 待拓展 | Cron 列表与触发 |
| F09 | 记忆与统计分析 | `HermesMobile/Networking/Hermes/HermesInsightsClient.swift` | `harmonyos/entry/src/main/ets/network/HermesInsightsClient.ets` | 待拓展 | 用量统计与 SOUL.md 查看 |
| F10 | 平台特性集成 | `HermesLiveActivityWidget/`, `HermesNotificationService/` | `harmonyos/entry/src/main/ets/platform/` | 待拓展 | 鸿蒙实况窗/Live Notification与后台通知 |
| F11 | 看板与高级特性 | `HermesMobile/Networking/Hermes/HermesKanbanClient.swift` | `harmonyos/entry/src/main/ets/network/HermesKanbanClient.ets` | 待拓展 | 看板 Board 任务调度 |
| F12 | Legacy WebUI 兼容 | `HermesMobile/Networking/Endpoints.swift`, `SSEClient.swift` | `harmonyos/entry/src/main/ets/network/legacy/LegacySSEClient.ets` | 待适配 | 针对旧版 SSE 服务的向后兼容适配器 |
| F13 | 国内直连与远程通道 | `docs/agents/hermes-server.md` | `harmonyos/entry/src/main/ets/network/ConnectionProfile.ets` | 待真机验证 | 蜂窝网下无需代理直连服务器 |
| F14 | 跨 Agent 调度验证 | `MIGRATION_PLAN.md` 74 节 | 测试用例与验证脚本 | 待联调验证 | Hermes 隔离调度产物验证 |
| F15 | 真机安装与升级 | `MIGRATION_PLAN.md` 75 节 | HAP 打包产物 | 构建阶段进行 | HAP 生成与签名安装验证 |
