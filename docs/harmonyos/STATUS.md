# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段三审批契约治理、Kanban实际路径、系统通知接入与多维验收矩阵更新完成 (Stage 3 Approval Lifecycle, Kanban UI, Notification Integration & Parity Matrix Updated)**
- 当前阶段：Run 12 工作块已全部落实：
  1. 消除 `ChatViewModel.onToolComplete` 中出现的测试命令特定依赖（`tool.input.includes('print(1)')`），严格按真实请求 ID（`requestId`）与工具生命周期进行审批消除与流转；
  2. 修复 `submitApproval` 与 `submitClarify` 异步在途状态保护：严格比对目标请求 ID 与 `sessionAttachGeneration` 代次，杜绝异步完成后误清除在途到达的新审批请求，杜绝会话切换/服务器断开后写回脏状态；
  3. 完成 F11 看板实际用户路径：实现 `HermesKanbanClient` 卡片创建 (`POST /tasks`) 与状态流转 (`PATCH /tasks/:id`)，实现 `KanbanViewModel`，并在 `Index.ets` 运维弹窗提供专属「看板」Tab，具备多看板切换、泳道卡片展示、快速新建与状态流转；
  4. 完成 F10 平台系统通知接入：实现 `NotificationUtils.ets`（基于 `@ohos.notificationManager`），实现审批待办与任务完成提醒分发，提供跨平台与无权限环境安全降级；
  5. 完成 F12 Legacy WebUI 探测降级：在 `ConnectionViewModel.probeStatus` 遇阻时主动探测 `/health` 探针；
  6. 更新严重陈旧的 `STATUS.md` 与 `FEATURE_PARITY.md`，将状态精确区分为「代码实现」、「本地验证」、「真机验收」三个独立维度，绝不将 28 项 Node 平台适配测试夸大为真机端到端通过；
  7. 持续保持 `harmonyos/build-profile.json5` 的 `skip-worktree` 状态，未读取、未输出、未提交任何签名密钥；DevEco SDK `assembleHap` 编译构建成功（退出码 0），产出最新 `entry-default-signed.hap`（913KB）。
- 更新时间：2026-10-21 00:15
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_01.md` ~ `REVIEW_WS_DEVICE_01.md`, `REVIEW_APPROVAL_DEVICE_01.md`, `RESUME_RUN12.md`

## 监督意见落实与本次核心重构详单

1. **消除生产代码对 fixture 命令的依赖 (落实 RESUME_RUN12.md)**：
   - 彻底删除 `ChatViewModel.onToolComplete` 中的 `(this.currentApproval.command && tool.input && tool.input.includes('print(1)'))` 特定测试 hack；
   - 审批状态清理严格依赖：
     - `submitApproval` 成功调用服务端 `approval.respond` 之后，仅当且仅当当前持有的审批与刚刚响应的目标请求 ID 完全一致时才置空；
     - 服务端 `request.cancel` 明确针对指定 request ID 或当前会话时置空；
     - 会话转入非运行态 (`session.info` running=false) 或消息完成时置空当前会话审批；
     - 工具完成 (`onToolComplete`) 时仅当审批工具名与完成工具名一致时清理。

2. **异步在途竞争与会话切换状态隔离 (落实 RESUME_RUN12.md)**：
   - 在 `submitApproval` 与 `submitClarify` 中引入快照变量与双重校验：
     - 记录发起时的 `currentAttachGen` 与 `targetRequestId`；
     - 若在 RPC 在途期间有后续审批请求到达（例如并发工具请求），RPC 返回后不会冲掉新的审批；
     - 若在 RPC 在途期间用户切换了会话或断开了连接，代次不匹配直接放弃状态写回，杜绝跨会话污染。

3. **F11 看板真实用户界面与交互闭环 (落实 RESUME_RUN12.md)**：
   - 在 `HermesKanbanClient.ets` 中对齐 upstream 实现 `createCard` 与 `updateCardStatus`；
   - 新建 `KanbanViewModel.ets`，负责看板可用性检测、看板列表管理、泳道卡片快照以及新建卡片/流转卡片状态机；
   - 在 `Index.ets` 运维弹窗中加入专属「看板」Tab，提供多看板切换、泳道与卡片分组显示、卡片快速推进流转与新建卡片输入。

4. **F10 系统通知与后台提示接入 (落实 RESUME_RUN12.md)**：
   - 新建 `NotificationUtils.ets`，封装 `@ohos.notificationManager` 原生能力；
   - 在收到需要审批的工具调用（`onApprovalRequest`）以及单轮任务生成完毕（`onMessageComplete`）时分发通知；
   - 提供严密的异常捕获与无权限环境安全降级，不阻断正常业务流。

5. **全生命周期测试集扩展 (28 项全通过)**：
   - `protocol-suite.js` 扩展至 28 项测试，全量通过（退出码 0）：
     - TEST 26: 真实测试 `ChatViewModel` 审批竞争与代次切换隔离；
     - TEST 27: 真实测试 `HermesKanbanClient` 与 `KanbanViewModel` 看板完整生命周期；
     - TEST 28: 真实测试 `NotificationUtils` 系统通知分发与平台降级。

6. **真实命令与退出码记录**：

| 命令 | 退出码 | 产物/证据路径 | 说明 |
| --- | --- | --- | --- |
| `node harmonyos/tests/protocol-suite.js` | 0 | `harmonyos/tests/protocol-suite.js` | 28 项全生命周期生产业务类测试全部通过 (退出码 0) |
| `cd harmonyos && hvigorw --no-daemon assembleHap` | 0 | `harmonyos/entry/build/default/outputs/default/entry-default-signed.hap` | ArkTS 编译通过，生成 913KB signed HAP 产物 (退出码 0) |

## 验收分层与后续规划

- [x] **P1 代码重构**：消除 fixture 命令依赖，治理审批竞争与生命周期；
- [x] **F11 真实接入**：看板客户端、ViewModel 及 Index 界面 Tab 闭环；
- [x] **F10 真实接入**：NotificationUtils 系统通知分发与降级防护；
- [x] **F12 真实接入**：ConnectionViewModel 对 `/health` 探针的降级探测；
- [x] **状态文档规范化**：分离实现、本地验证、真机验收，纠正夸大表述；
- [ ] **真机独立验收（由监督者执行）**：
  - 真机审批卡片交互（发送消息 -> 触发审批 -> 界面点击允许一次 -> 终态输出）；
  - 覆盖升级数据保留与会话保留；
- [ ] **F13/F14 真实链路**：国内公网直连验证与跨 Agent 调度产物验证。

## 权限与安全门禁

- 本 Agent 严格遵守权限与操作边界：
  - 未读取、未记录、未提交任何签名密钥或证书，`harmonyos/build-profile.json5` 保持 `skip-worktree`；
  - 未动用、未重启 `:61688` 生产服务，未读取 `~/.hermes` 生产配置与历史会话；
  - 未创建任何子 Agent，全流程保持 Flash High 单一进程执行；
  - 所有改动仅限当前项目源码与文档，并已完成向用户 Fork 分支推送。
