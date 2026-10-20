# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段一核心生产路径统一验收通过 & 阶段二全量功能推进完成 (Core Engine Directly Verified & Stage 2 Functional Parity Implemented)**
- 当前阶段：阶段一/二完整闭环（直接驱动实际生产 .ets 业务代码测试、修复代次与连接生命周期缺陷、实现安全持久化隔离、落地工作区/文件产物/定时任务/统计/Legacy/Markdown 原生组件，完成 DevEco 真实构建）
- 更新时间：2026-10-20 21:28
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_01.md`, `REVIEW_02.md`, `REVIEW_CORE_01.md`, `REVIEW_CORE_02.md`, `REVIEW_NEXT.md`

## 监督意见落实与本次核心重构详单

1. **废除测试替身，生产类统一路径与直接测试 (落实 REVIEW_CORE_02 P1 首项)**：
   - 彻底删除孤立的 `HermesProtocolEngine.ts`；
   - 重构 `harmonyos/tests/protocol-suite.js`，通过 TypeScript 编译器直接动态转译加载实际应用生产类：
     - `HermesRESTClient.ets`
     - `HermesGatewayClient.ets`
     - `ChatViewModel.ets`
     - `AuthStore.ets`
     - `HermesWorkspaceClient.ets`
     - `HermesFileClient.ets`
     - `HermesCronClient.ets`
     - `HermesInsightsClient.ets`
     - `LegacySSEClient.ets`
     - `MarkdownParser.ets`
   - 注入平台 `@ohos.net.http` 和 `@ohos.net.webSocket` 适配器，由独立 Mock Hermes 网关驱动真实网络协议与状态机，完成全部 17 项行为断言。

2. **修复代次与实例身份双重保护 (落实 REVIEW_CORE_02 第 1 项)**：
   - 修复 `attachSession` 内 `this.disconnect()` 导致自身代次被误增过期的严重隐蔽缺陷；
   - `ChatViewModel` 在所有异步回调前后校验 `currentAttachGen === this.sessionAttachGeneration` 与 `this.gateway === activeGateway`；
   - 在测试用例中模拟 Session A 延迟返回、Session B 快速先达的乱序场景，验证 A 的过期回调被严格丢弃，B 的状态与历史未被污染。

3. **恢复失败严格状态门禁与操作拦截 (落实 REVIEW_CORE_02 第 2 项)**：
   - `resumeSession` 失败时严格将 `isConnected` 置为 `false`、`runtimeSessionId` 置为空，连接状态标记为 `会话恢复失败`；
   - 用户尝试 `sendMessage` 时进行前置门禁拦截，展示 Toast 提示，严禁向服务端发出 `prompt.submit` RPC。

4. **握手前取消 Settle 与合法关闭码 (落实 REVIEW_CORE_02 第 3 项)**：
   - `HermesGatewayClient.connect` 绑定 `pendingConnectReject` 钩子，握手完成前若调用 `disconnect()` 或连接中断，`connect` Promise 保证被确定性 reject，杜绝无限挂起；
   - 心跳静默超时主动断开改用应用自定义合法代码 `3001`，客户端主动断开使用正常代码 `1000`，杜绝非法保留码 `1006`。

5. **AuthStore 配置与凭据物理隔离持久化 (落实 REVIEW_CORE_02 第 4 项)**：
   - 定义非敏感连接元数据 `ConnectionMetadata`（URL、名称、Profile、用户名）与敏感身份凭据 `SecureCredential`（Token、Cookie、密码）；
   - 元数据导出不含任何密钥/Token；敏感凭据单独隔离存储；移除连接时同步擦除两端。

6. **基线 Pin 语义修正、时间规范与上游检查 (落实 REVIEW_CORE_02 第 6 项 & REVIEW_NEXT 第 1、2 项)**：
   - 准确区分 `HERMES_AGENT_TESTED_SHA`（直连后端 `hermes-agent` Pin: `ca678285...`）、`UPSTREAM_TESTED_SHA`（legacy webui 后端契约 Pin: `c67fd2dd...`）与 `reviewed_upstream_master_sha`（iOS 源码快照: `b26d7c56...`）；
   - `upstream_baseline.json` 采用真实带时区 ISO 8601 时间戳（`+08:00`），将验收状态单列为 `in_progress`，待全量功能端到端验收前不预填功能基线；
   - `scripts/check-upstream-sync` 支持 `--mock-remote` 与 `--mock-fail`，全量通过“无更新/有更新/网络错误”三场景自测。

7. **默认服务器地址修正 (落实 REVIEW_NEXT 第 4 项)**：
   - 移除 `Index.ets` 硬编码的临时端口 `http://127.0.0.1:61688`，改为用户可配置，提供提示信息说明 127.0.0.1 在真机指向手机自身，需使用局域网 IP 或公网 HTTPS。

8. **全量阶段二功能推进 (落实 REVIEW_CORE_02 第 5 项)**：
   - **工作区与代码阅读 (`HermesWorkspaceClient.ets`)**：防路径跨越安全路径计算，实现 `/api/fs/list` 目录树与 `/api/fs/read-text` 源码读取；
   - **文件与附件 (`HermesFileClient.ets`)**：实现 `/api/chat/image-upload` 图片 Base64 上传与 `/api/fs/download` 会话产物下载；
   - **定时任务 (`HermesCronClient.ets`)**：实现 `/api/cron/jobs` 任务列表、`/run` 触发、`/pause` 暂停与 `/resume` 恢复；
   - **用量统计 (`HermesInsightsClient.ets`)**：实现 `/api/analytics/usage` 总 Token/费用统计与 `/api/analytics/models` 各模型明细；
   - **Legacy WebUI 兼容 (`LegacySSEClient.ets`)**：实现 `/health` 探针与多行 SSE 数据块解析器；
   - **Markdown 渲染 (`MarkdownParser.ets` & `MarkdownView.ets`)**：实现原生多级标题、代码块（Monospace+语言标识）、表格、引用块、列表与段落渲染。

## 真实命令与退出码记录

| 命令 | 退出码 | 产物/证据路径 | 说明 |
| --- | --- | --- | --- |
| `./scripts/check-upstream-sync` | 0 | 终端输出 / 脚本 | 远端与 reviewed 基线一致 (`b26d7c564ae5459bffd2f448118b986741f6720f`) |
| `node harmonyos/tests/protocol-suite.js` | 0 | `harmonyos/artifacts/protocol_test_report.txt` | 直接驱动生产 .ets 业务类的 17 项端到端全生命周期测试全部通过 |
| `hvigorw --no-daemon assembleHap` | 0 | `harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap` | 生成 398KB 中间编译 HAP，ArkTS 编译成功退出码 0 |

## 剩余任务与后续规划

- [ ] 阶段三：真机 USB 调试与合法证书签名配置（当前 398KB unsigned HAP 仅为编译中间产物，非最终可安装交付包）；
- [ ] 阶段三：鸿蒙实况窗 / Live Notification 与后台通知系统级适配；
- [ ] 阶段三：外网免代理直连实测与端到端功能验收。

## 人工依赖与门禁说明

- DevEco Studio API 12 编译器与 Node.js 17 项真实代码回归测试全部在本地自闭环通过；
- 真机安装签名需由监督者 Codex 视后续真机测试节点向用户请求配置。
