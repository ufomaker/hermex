# Hermex 鸿蒙功能移植对照表 (Feature Parity Matrix)

最后更新：2026-10-20 21:26

| 编号 | 功能模块 | 上游 iOS 源码位置 | 鸿蒙 ArkTS/ArkUI 实现位置 | 状态 | 说明与验证 |
| --- | --- | --- | --- | --- | --- |
| F01 | 连接与认证 | `HermesMobile/Networking/Hermes/HermesConnection.swift`, `HermesREST.swift` | `harmonyos/entry/src/main/ets/network/HermesConnection.ets`, `HermesRESTClient.ets`, `AuthStore.ets` | 已就绪 | 多服务器地址配置、版本探测、Cookie Jar提取携带、强制 /api/auth/me 核验、普通配置与敏感凭据物理隔离存储 |
| F02 | 会话管理 | `HermesMobile/Features/SessionList/`, `HermesSessionActions.swift` | `harmonyos/entry/src/main/ets/viewmodel/SessionListViewModel.ets`, `pages/SessionListPage.ets` | 已就绪 | 会话列表拉取、服务端真实 session.create 新建、session.resume 恢复、真实历史回填 |
| F03 | 原生聊天 | `HermesMobile/Features/Chat/`, `HermesChatTurnCoordinator.swift` | `harmonyos/entry/src/main/ets/pages/ChatPage.ets`, `viewmodel/ChatViewModel.ets`, `components/MarkdownView.ets`, `components/MarkdownParser.ets` | 已就绪 | ArkUI 原生聊天渲染、流式消息（message.delta）、推理过程（reasoning.delta）、Markdown多级标题/表格/代码块高亮/列表/引用渲染 |
| F04 | 实时控制与审批 | `HermesMobile/Networking/Hermes/HermesCall.swift` (`approvalRespond`, `sessionInterrupt`, `clarifyLock`) | `harmonyos/entry/src/main/ets/network/HermesGatewayClient.ets`, `viewmodel/ChatViewModel.ets` | 已就绪 | 停止生成（session.interrupt）、审批弹窗卡片（approval.respond，失败重试保护）、澄清问题交互（request.answer/clarify.lock） |
| F05 | 模型与参数配置 | `HermesMobile/Networking/Hermes/HermesModelCatalog.swift`, `HermesCall.swift` (`modelOptions`, `config.set`) | `harmonyos/entry/src/main/ets/viewmodel/ModelCatalogViewModel.ets`, `components/ModelSelectorDialog.ets` | 已就绪 | 读取模型列表（model.options）、真实切换模型参数（config.set key=model value="<model> --session"） |
| F06 | 项目与工作区 | `HermesMobile/Networking/Hermes/HermesProjects.swift`, `HermesWorkspaceFileClient.swift` | `harmonyos/entry/src/main/ets/network/HermesWorkspaceClient.ets` | 已就绪 | 远程工作区路径跨越防护、目录树浏览（/api/fs/list）、代码源码文本读取（/api/fs/read-text） |
| F07 | 文件与附件 | `HermesMobile/Networking/Hermes/HermesREST.swift` (`downloadArtifact`, `uploadImage`) | `harmonyos/entry/src/main/ets/network/HermesFileClient.ets` | 已就绪 | 图片 Base64 上传（/api/chat/image-upload）、会话与工作区产物下载（/api/fs/download） |
| F08 | 任务与定时 Job | `HermesMobile/Networking/Hermes/HermesCronClient.swift` | `harmonyos/entry/src/main/ets/network/HermesCronClient.ets` | 已就绪 | 定时 Cron 列表拉取（/api/cron/jobs）、触发执行（/run）、暂停（/pause）与恢复（/resume） |
| F09 | 记忆与统计分析 | `HermesMobile/Networking/Hermes/HermesInsightsClient.swift` | `harmonyos/entry/src/main/ets/network/HermesInsightsClient.ets` | 已就绪 | 用量统计汇总（/api/analytics/usage）、各模型调用次数与成本明细（/api/analytics/models） |
| F10 | 平台特性集成 | `HermesLiveActivityWidget/`, `HermesNotificationService/` | `harmonyos/entry/src/main/ets/platform/` | 待拓展 | 鸿蒙实况窗/Live Notification与后台通知集成（需真机权限与系统证书支持） |
| F11 | 看板与高级特性 | `HermesMobile/Networking/Hermes/HermesKanbanClient.swift` | `harmonyos/entry/src/main/ets/network/HermesKanbanClient.ets` | 待拓展 | 看板 Board 任务调度 |
| F12 | Legacy WebUI 兼容 | `HermesMobile/Networking/Endpoints.swift`, `SSEClient.swift` | `harmonyos/entry/src/main/ets/network/legacy/LegacySSEClient.ets` | 已就绪 | 针对旧版 SSE 服务的向后兼容探针（/health）与 SSE 数据块解析器（对齐 UPSTREAM_TESTED_SHA: c67fd2dd） |
| F13 | 国内直连与远程通道 | `docs/agents/hermes-server.md` | `harmonyos/entry/src/main/ets/network/ConnectionProfile.ets` | 待真机验证 | 蜂窝网下无需代理直连服务器（已移除 127.0.0.1 硬编码，支持任意可达 IP/域名与 HTTPS） |
| F14 | 跨 Agent 调度验证 | `MIGRATION_PLAN.md` 74 节 | 测试用例与验证脚本 | 待联调验证 | Hermes 隔离调度产物验证 |
| F15 | 真机安装与升级 | `MIGRATION_PLAN.md` 75 节 | HAP 打包产物 (`entry-default-unsigned.hap`) | 待签名安装 | 真实构建输出 398KB HAP 产物；真机安装需配置用户合法调试证书 |
