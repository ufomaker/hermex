# Hermex HarmonyOS 移植状态追踪

- 状态：**阶段二安全存储与系统级文件/附件完整闭环 (Stage 2 Secure Storage & File/Attachment Flow Verified)**
- 当前阶段：阶段二全量功能闭环（全面落实 REVIEW_STORAGE_03 审查意见：AuthStore 接入平台级 `@ohos.security.asset` 密文硬件保管库，非敏感元数据与敏感凭据物理隔离，统一启动 ready Promise 并杜绝异常静默吞噬；文件下载通过 `DocumentViewPicker` 与应用沙箱 `fs.writeSync` 真实落盘写入；附件弹窗集成系统相册 `PhotoViewPicker` 与文件管理器 `DocumentViewPicker` 原生选择，全量通过 18 项真实业务代码测试与 DevEco 真实构建 assembleHap 退出码 0）
- 更新时间：2026-10-20 21:56
- 当前分支：`harmonyos/native-port`
- 实施者：AntiGravity
- 监督审查参考：`REVIEW_01.md`, `REVIEW_02.md`, `REVIEW_CORE_01.md`, `REVIEW_CORE_02.md`, `REVIEW_FEATURE_01.md`, `DEVICE_REVIEW_01.md`, `REVIEW_STORAGE_03.md`

## 监督意见落实与本次核心重构详单

1. **AuthStore 接入硬件级 Asset Store 与异常严格传播 (落实 REVIEW_STORAGE_03)**：
   - 彻底废除普通 Preferences 明文存储凭据，实现 `HarmonyPlatformAuthAdapter`：
     - 普通元数据（`ConnectionMetadata`）：存储于 `@ohos.data.preferences`；
     - 敏感身份凭证（`SecureCredential`，含 Token、Cookie、密码）：存储于 `@ohos.security.asset`（AssetStoreKit 硬件级密文保管库）；
   - **杜绝静默失败**：所有写入/删除异常严格向上抛出，不在内部 `catch` 假成功，操作失败时保持原子性；
   - **启动 ready Promise 机制**：`AuthStore.init()` 统一维护 `initPromise` 与 `isReady` 标志，`Index.ets` 在 `aboutToAppear` 阶段必须 `await AuthStore.getInstance().waitUntilReady()`，彻底消除冷启动恢复与页面初次加载的异步竞态；
   - **直接测试平台适配器**：`protocol-suite.js` 直接实例化 `HarmonyPlatformAuthAdapter`，mock Asset/Preferences 边界，严格断言敏感凭证未泄露入 Preferences、Asset 写入/删除失败异常正确向上传播、模拟冷启动还原正常。

2. **系统级照片/文件附件选择与自动转码 (落实 REVIEW_STORAGE_03)**：
   - 彻底废除要求普通用户手动输入 Data URL 或 Base64 的不友好交互；
   - 在 `Index.ets` 中通过 `@ohos.file.picker` 接入原生系统级选择器：
     - **相册选择**：调用 `picker.PhotoViewPicker.select()`，通过 `fs.openSync` 与 `util.Base64Helper` 自动将用户选中的本地图片转码为 `data:image/jpeg;base64,...`，调用 `HermesFileClient.uploadImage` 后自动将 Markdown 图片标签（`![filename](path)`）追加到消息输入框；
     - **文件选择**：调用 `picker.DocumentViewPicker.select()`，选择文档后自动转码上传并插入文件引用；
     - **样例验证**：保留内置 1px 测试图入口，方便在无图库或自动化测试环境中一键验证全链路。

3. **二进制文件下载真实落盘与持久化 (落实 REVIEW_STORAGE_03)**：
   - 废除仅 Toast 字节长度的形式实现；
   - 下载获得 `ArrayBuffer` 后，首先调用 `picker.DocumentViewPicker.save()` 尝试让用户自选保存位置；
   - 若用户未选择或环境受限，自动使用 `@ohos.file.fs` 的 `openSync` 与 `writeSync` 真实写入持久化应用沙箱目录（`${ctx.filesDir}/${entry.name}`）；
   - 弹出真实保存位置通知（`文件已成功保存: ${savedLocation} (${buffer.byteLength} 字节)`），确保数据切实保存在手机本地。

4. **真实生产代码测试覆盖**：
   - `harmonyos/tests/protocol-suite.js` 直接加载编译所有真实 `.ets` 业务类；
   - 新增 AssetStoreKit 密文硬件保管库断言、写入/删除异常传播断言、Preferences 明文隔离断言；
   - 全量 18 项端到端生产代码行为回归测试全部通过（退出码 0）。

5. **DevEco Studio 真实构建与产物产出**：
   - 执行 `hvigorw --no-daemon assembleHap`；
   - 严格修复 ArkTS `arkts-limited-throw`（异常抛出必须为 `Error` 实例）；
   - 成功生成 `entry-default-signed.hap`（550KB）与 `entry-default-unsigned.hap`（515KB），构建成功退出码 0。
   - 严格保护 `harmonyos/build-profile.json5` 的 `skip-worktree` 状态，未读取、未输出、未提交任何签名凭据。

## 真实命令与退出码记录

| 命令 | 退出码 | 产物/证据路径 | 说明 |
| --- | --- | --- | --- |
| `node harmonyos/tests/protocol-suite.js` | 0 | `harmonyos/artifacts/protocol_test_report.txt` | 直接驱动生产 .ets 业务类的 18 项端到端全生命周期测试全部通过 |
| `hvigorw --no-daemon assembleHap` | 0 | `harmonyos/entry/build/default/outputs/default/entry-default-signed.hap` | 生成 550KB signed HAP 产物，ArkTS 编译成功退出码 0 |

## 剩余任务与后续规划

- [ ] 阶段三：外网免代理直连与真机全链路真实 Hermes 会话交互验收；
- [ ] 阶段三：鸿蒙实况窗 / Live Notification 与后台通知系统级适配（F10）；
- [ ] 阶段三：看板 Board 任务调度视图适配（F11）。

## 人工依赖与门禁说明

- 监督者已在华为真机（HarmonyOS 6.1.0）上通过官方自动签名安装并启动应用（见 `SUPERVISION.md` 21:43 记录）；
- 本 Agent 严格遵守权限与安全约束：未读取或输出任何用户凭证或证书内容，未变动生产配置，未派发子 Agent。
