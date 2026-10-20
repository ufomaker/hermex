# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段二功能闭环与契约严密落实验收通过 (Stage 2 Functional Parity & Contract Strict Alignment Verified)**
- 当前阶段：阶段二全量功能闭环（落实 REVIEW_FEATURE_01 与 DEVICE_REVIEW_01 全部审查项：AuthStore 真实首选项+加密隔离持久化与冷启动恢复、WorkspaceViewModel 目录层级导航与文件预览下载、Index 原生工作区文件弹窗与 📎 附件上传流、HermesFileClient data_url 字段与 ArrayBuffer 二进制接收、HermesWorkspaceClient resolveHostPath 路径遍历严密拦截、HermesInsightsClient analytics.json 字段匹配，全量通过 18 项真实业务代码测试与 DevEco 真实构建 assembleHap 退出码 0）
- 更新时间：2026-10-20 21:44
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_01.md`, `REVIEW_02.md`, `REVIEW_CORE_01.md`, `REVIEW_CORE_02.md`, `REVIEW_FEATURE_01.md`, `DEVICE_REVIEW_01.md`

## 监督意见落实与本次核心重构详单

1. **AuthStore 平台级持久化与冷启动恢复 (落实 REVIEW_FEATURE_01)**：
   - 彻底废除仅内存 Map 的临时实现，引入 `AuthStorageAdapter` 架构；
   - 实现 `HarmonyPreferencesAdapter`（基于 `@ohos.data.preferences`）将非敏感连接元数据（`ConnectionMetadata`）与敏感凭据（`SecureCredential`，含 Token、Cookie、密码）进行物理分流持久化；
   - 在 `EntryAbility.ets` 的 `onCreate` 阶段通过 `AuthStore.getInstance().init(this.context)` 注入真实平台上下文并执行 `restoreFromStorage()`；
   - 包含多服务器切换时自动持久化当前连接指针，移除连接时同步擦除两端敏感记录。

2. **工作区与文件附件完整原生交互链条 (落实 REVIEW_FEATURE_01)**：
   - 创建 `harmonyos/entry/src/main/ets/viewmodel/WorkspaceViewModel.ets`，管理工作区当前路径、目录条目排序（文件夹优先）、层级回退历史、文件文本预览与产物下载；
   - 在 `Index.ets` 顶部导航栏增加“工作区”入口，构建原生 `showWorkspaceDialog` 弹窗：支持进入子目录、返回上一级、刷新、文件源码文本预览、直接调用下载；
   - 在 `Index.ets` 输入栏前增加“📎”原生附件按钮与 `showAttachmentDialog` 弹窗：支持输入或预设图片 Data URL，调用 `HermesFileClient.uploadImage` 上传并自动在输入框插入 Markdown 图片引用。

3. **上游 Swift 契约严格追溯与修复 (落实 REVIEW_FEATURE_01)**：
   - **`uploadImage` 载荷字段**：严格对齐 `HermesREST.swift:379-384`，请求体字段名为 `data_url`，彻底摒弃旧 `data` 字段；
   - **`downloadArtifact` 二进制保护**：请求指定 `expectDataType: http.HttpDataType.ARRAY_BUFFER`，直接返回 `ArrayBuffer`，杜绝因文本替换字符导致的二进制损坏；
   - **`resolveHostPath` 路径遍历严密防线**：严格复刻 `HermesWorkspaceFileClient.swift:117-124`，禁止绝对路径 `/`、禁止家目录 `~`、禁止空字节 `\0`、禁止向上穿越 `..`；
   - **`HermesInsightsClient` 用量分析**：请求携带 `?days=<days>&profile=<profile>`，精准解析 `analytics.json` 真实字段（`total_input`, `total_output`, `total_reasoning`, `total_actual_cost`, `total_api_calls` 等）。

4. **真实生产代码测试覆盖拓展至 18 项**：
   - `harmonyos/tests/protocol-suite.js` 注入 `@ohos.net.http`, `@ohos.net.webSocket`, `@ohos.data.preferences` 适配器，直接加载运行所有真实 `.ets` 业务类；
   - 新增路径遍历注入拒绝、冷启动凭据恢复、`data_url` 字段核对、`ArrayBuffer` 字节流与 PNG 魔数验证、`WorkspaceViewModel` 导航流程等测试，18 项测试全部通过（退出码 0）。

5. **DevEco Studio 真实构建与产物产出**：
   - 执行 `hvigorw --no-daemon assembleHap`；
   - 编译检查通过（修复了 ArkTS `arkts-no-any-unknown` 与严格类型匹配）；
   - 成功生成 `entry-default-signed.hap`（550KB）与 `entry-default-unsigned.hap`（515KB），退出码 0。

## 真实命令与退出码记录

| 命令 | 退出码 | 产物/证据路径 | 说明 |
| --- | --- | --- | --- |
| `node harmonyos/tests/protocol-suite.js` | 0 | `harmonyos/artifacts/protocol_test_report.txt` | 直接驱动生产 .ets 业务类的 18 项端到端全生命周期测试全部通过 |
| `hvigorw --no-daemon assembleHap` | 0 | `harmonyos/entry/build/default/outputs/default/entry-default-signed.hap` | 生成 550KB 真实 HAP 产物，ArkTS 编译成功退出码 0 |

## 剩余任务与后续规划

- [ ] 阶段三：真机 USB 调试与用户签名配置（由监督者 Codex 视真机测试节点统一向用户请求）；
- [ ] 阶段三：鸿蒙实况窗 / Live Notification 与后台通知系统级适配；
- [ ] 阶段三：外网免代理直连与真机全链路验收。

## 人工依赖与门禁说明

- DevEco Studio 真实 HAP 打包构建与 18 项生产代码行为回归测试已在本地环境验证通过；
- 后续真机安装签名由监督者 Codex 协调处理，本 Agent 保持不读取凭据、不动生产、不派子 Agent 约束。
