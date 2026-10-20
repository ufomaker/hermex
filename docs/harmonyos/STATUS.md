# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段一完成 (Milestone 1 Completed)**
- 当前阶段：阶段一（鸿蒙原生工程建立、上游基线与协议精确核查、核心原生交互闭环实现、DevEco 真实构建 HAP 成功与隔离协议回归验证）
- 更新时间：2026-10-20 20:48
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_01.md`, `REVIEW_02.md`

## 本阶段实际完成工作

1. **协议基线与准确方法核实 (锁定至 `UPSTREAM_BASELINE.md`)**：
   - 依据 `HermesREST.swift:374` 将 WebSocket ticket 换取接口严格修正为 `POST /api/auth/ws-ticket`（空载荷 `{}`）；
   - 依据 `HermesREST.swift:360-363` 将密码登录核实为 `POST /auth/password-login`；
   - 依据 `HermesCall.swift:275-340, 400-475` 精准核实并实现核心 RPC 方法：
     - 会话方法：`session.list`、`session.create`、`session.resume`
     - 停止中断方法：`session.interrupt`（纠正之前草案中的 `prompt.interrupt`）
     - 消息发送方法：`prompt.submit`（携带 `queued: true`）
     - 审批控制方法：`approval.respond`（携带 `request_id`, `choice`）
     - 澄清问答方法：`request.answer` / `clarify.lock`
     - 模型能力方法：`model.options`
     - 客户端协商握手：`client.capabilities`（携带 `server_requests: true`）
   - 澄清版本兼容性：本地探测 `0.22.2 >= 0.21.3` 满足最低静态门槛，协议有效性经由真实 WebSocket 握手验证。
2. **上游变更只读检查工具 (`scripts/check-upstream-sync`)**：
   - 采用 `git ls-remote` 获取远端真实最新 SHA，杜绝使用 `--dry-run` 与隐藏错误；
   - 独立清晰标识 `HERMES_AGENT_TESTED_SHA`（后端网关测试提交）与 `UPSTREAM_TESTED_SHA`（原作者 iOS 客户端提交）。
3. **鸿蒙原生工程与构建配置 (`harmonyos/`)**：
   - 清理所有模板占位页面（如 `generated/Index.ets`）与无用依赖；
   - 规范配置 `module.json5`（添加 `ohos.permission.INTERNET` 权限，主页面指向 `pages/Index`）；
   - 配置兼容性 `compatibleSdkVersion: "5.0.0(12)"`、`targetSdkVersion: "5.0.0(12)"`，匹配用户鸿蒙 6 及以上手机；
   - 严格遵循 ArkTS 强类型约束，解决字面量声明与 spread 约束，完成 `model/`、`network/`、`storage/`、`viewmodel/` 及 `pages/Index.ets` 的完整实现。
4. **真实构建与打包产物**：
   - 运行 DevEco 工具链执行真实 `assembleHap` 构建，退出码为 0，成功生成 HAP 安装包。
5. **隔离协议回归自动化测试 (`harmonyos/tests/protocol-suite.js`)**：
   - 覆盖子协议头、握手首帧 `gateway.ready`、能力协商 `client.capabilities`、中文 UTF-8 实时流式分包、推理 `reasoning.delta`、工具调用全生命周期、停止中断 `session.interrupt`、审批 `approval.respond`，测试 100% 通过（退出码 0）。

## 真实命令、退出码与证据记录

| 命令 | 退出码 | 产物/证据路径 | 说明 |
| --- | --- | --- | --- |
| `./scripts/check-upstream-sync` | 0 | 终端输出 / 脚本 | 远端 SHA 获取：`b26d7c564ae5459bffd2f448118b986741f6720f` |
| `hvigorw --no-daemon assembleHap` | 0 | `harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap` | 生成 318KB 原生 HAP 包 (SHA256: `89bacfdbe092a8c52aca579f9758c0c8eb2494017296f284515be1b88efaf97b`)，详细日志存至 `harmonyos/artifacts/build_log.txt` |
| `node harmonyos/tests/protocol-suite.js` | 0 | `harmonyos/artifacts/protocol_test_report.txt` | 隔离协议回归套件全部通过 (包含中文流式、停止、审批控制) |

## 剩余任务与下一阶段计划

- [ ] 阶段二：实现项目与远程工作区文件浏览与预览 (`HermesWorkspaceClient.ets`)
- [ ] 阶段二：实现文件/图片附件上传与产物下载 (`HermesFileClient.ets`)
- [ ] 阶段二：实现定时任务管理 (`HermesCronClient.ets`)
- [ ] 阶段三：真机 USB 连接调试、签名配置与蜂窝网络直连测试

## 人工依赖与门禁说明

- 当前阶段 DevEco Studio 本地工具链构建及隔离协议测试均在无设备阻塞下圆满完成；
- 后续真机安装签名需要用户提供开发者证书/设备授权时，将提前写入 STATUS 提请确认。
