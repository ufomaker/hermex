# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段九（Run 21 落地）F05 真实模型/Provider目录解析、Reasoning推理参数、安全Token防注入、Profile切换隔离与官方模拟器 6/6 UiTest 全绿通过 (Stage 9 F05 Model & Provider Catalog, Reasoning Effort, Token Injection Guard, Profile Isolation & Official Emulator 6/6 Pass)**
- 当前阶段：Run 21 工作块已全部落实：
  1. **F05 真实模型与 Provider 目录上游契约对齐 (HermesModelCatalog.swift & HermesCall.swift)**：
     - 新建 `ModelCatalog.ets`，严格解析 `providers[].slug/name/authenticated/models/unavailable_models/capabilities` 嵌套报文；
     - 自动过滤 `authenticated === false` 的未认证 provider，过滤 `unavailable_models` 标记不可用模型，过滤同 provider 下重复模型；
     - 无任何可用模型的 provider 自动剔除对应分组（无空 section）；
     - 保留每个模型的 `providerId`，彻底解决同名模型（如 `claude-3-5-sonnet`）跨 provider 冲突碰撞问题；
     - 正确映射并保留模型 capabilities 字典（如 `reasoning: true`, `vision: true`）；
     - 针对单模型/隔离 stub 场景保留顶层 models 容错回退机制。
  2. **Token 安全防注入与 Session 级模型参数构造 (严格对齐 HermesModelCatalog.sessionModelValue)**：
     - 实现 `isSafeToken` 严格校验：拒绝空值、拒绝任何空白字符（`\s`）、拒绝双破折号（`--`）、拒绝 Unicode 破折号（`‒`, `–`, `—`, `―`）；
     - `formatSessionModelValue` 生成安全参数 `${modelId} --provider ${providerId} --session`，阻断任意 flag 注入与 scope 篡改；
     - `HermesGatewayClient.setModelConfig` 与 `setReasoningConfig` 限定 `scope: 'session'`，默认不代确认昂贵模型。
  3. **Reasoning 推理参数配置与合法性门禁**：
     - 支持上游合法推理强度级别：`none, minimal, low, medium, high, xhigh, max, ultra`；
     - `setReasoningConfig` 拦截非法推理参数并安全报错，`ChatViewModel.switchReasoningEffort` 失败时优雅保留原状态并 toast 提示；
     - 原生 UI 提供 `none, low, medium, high, max` 快捷切换胶囊按钮并实时高亮当前档位。
  4. **Profile 列表与切换状态隔离**：
     - `HermesGatewayClient.listProfiles` 调用 `profiles.list` RPC；
     - `ChatViewModel.switchProfile` 升级 `modelFetchGeneration` 与 `sessionAttachGeneration` 异步代次；
     - 切换 Profile 立即清空旧会话 runtimeSessionId、历史消息流与模型目录，彻底阻断跨 Profile / 跨会话旧网络响应污染。
  5. **测试与编译全线通过**：
     - DevEco `assembleHap`（entry 与 entry@ohosTest）双 HAP 编译成功 (退出码 0)；
     - Node 回归测试 `protocol-suite.js` 扩展至 35 项全部通过 (退出码 0)；
     - 官方模拟器（`127.0.0.1:5555`）执行定向 `testModelAndProfileUserFlow` 通过 (1/1, 退出码 0)；
     - 官方模拟器执行 `run-e2e-with-network-test.js` 全量 6 项官方测试全部通过 (Tests run: 6, Failure: 0, Error: 0, Pass: 6, Ignore: 0, 退出码 0，6 阶段有效产物完整捕获)。
- 更新时间：2026-10-21 08:43
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`RESUME_RUN21.md`, `REVIEW_MODELS_NEXT.md`, `REMAINING_SCOPE_QUEUE.md`

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
