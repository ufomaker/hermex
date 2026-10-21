import { hilog } from '@kit.PerformanceAnalysisKit';
import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { Driver, ON, Component, MatchPattern } from '@ohos.UiTest';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { HermesKanbanClient } from '../../../main/ets/network/HermesKanbanClient';
import { HermesCronClient, CronJobItem } from '../../../main/ets/network/HermesCronClient';
import { HermesRESTClient } from '../../../main/ets/network/HermesRESTClient';

const DOMAIN = 0x0000;
const TAG = 'ChatApprovalUiTest';
let currentRunSessionPromptTag: string = '';

export default function chatApprovalUiTest() {
  describe('ChatApprovalUiTest', () => {
    beforeAll(async () => {
      hilog.info(DOMAIN, TAG, 'Starting EntryAbility for UI test...');
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      await delegator.startAbility({
        bundleName: 'com.uzairansaruzi.hermex.harmony',
        abilityName: 'EntryAbility'
      });
      hilog.info(DOMAIN, TAG, 'EntryAbility start request sent');
    });

    it('testCompleteChatAndApprovalFlow', 0, async () => {
      hilog.info(DOMAIN, TAG, 'Beginning end-to-end chat approval journey');
      const driver = Driver.create();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      await driver.delayMs(2500);

      // 1. 打开服务器设置
      hilog.info(DOMAIN, TAG, 'Step 1: Locating server settings button...');
      let btnSettings = await driver.findComponent(ON.id('btn_server_settings'));
      if (!btnSettings) {
        btnSettings = await driver.findComponent(ON.id('btn_configure_server'));
      }
      expect(btnSettings !== null).assertTrue();
      if (btnSettings) {
        await btnSettings.click();
      }
      await driver.delayMs(1000);

      // 2. 填写隔离测试服务地址与固定公开账号
      hilog.info(DOMAIN, TAG, 'Step 2: Entering Hermes 9199 credentials...');
      const inputUrl = await driver.findComponent(ON.id('input_server_url'));
      expect(inputUrl !== null).assertTrue();
      if (inputUrl) {
        await inputUrl.inputText('http://127.0.0.1:9199');
        const urlText = await inputUrl.getText();
        hilog.info(DOMAIN, TAG, 'input_server_url text is now: %{public}s', urlText);
      }
      await driver.delayMs(500);

      const inputUser = await driver.findComponent(ON.id('input_username'));
      expect(inputUser !== null).assertTrue();
      if (inputUser) {
        await inputUser.inputText('hermex');
        const userText = await inputUser.getText();
        hilog.info(DOMAIN, TAG, 'input_username text is now: %{public}s', userText);
      }
      await driver.delayMs(500);

      const inputPass = await driver.findComponent(ON.id('input_password'));
      expect(inputPass !== null).assertTrue();
      if (inputPass) {
        await inputPass.inputText('hermex-local');
        hilog.info(DOMAIN, TAG, 'input_password entered');
      }
      await driver.delayMs(500);
      await driver.pressBack();
      await driver.delayMs(500);

      // 3. 点击连接并保存
      hilog.info(DOMAIN, TAG, 'Step 3: Clicking connect and save...');
      const btnConnect = await driver.findComponent(ON.id('btn_connect_save'));
      expect(btnConnect !== null).assertTrue();
      if (btnConnect) {
        await btnConnect.click();
      }
      await driver.delayMs(3000);

      // 4. 新建独立会话
      hilog.info(DOMAIN, TAG, 'Step 4: Creating new isolated session...');
      let btnNewSession = await driver.findComponent(ON.id('btn_new_session'));
      if (!btnNewSession) {
        const btnSessions = await driver.findComponent(ON.id('btn_sessions_list'));
        if (btnSessions) {
          await btnSessions.click();
          await driver.delayMs(1000);
          btnNewSession = await driver.findComponent(ON.id('btn_new_session'));
        }
      }
      expect(btnNewSession !== null).assertTrue();
      if (btnNewSession) {
        await btnNewSession.click();
      }
      await driver.delayMs(2000);

      // 5. 中文输入并发出（携带唯一标记，防止混淆）
      const testTag = 'RUN16_' + Date.now().toString(36);
      const uniquePrompt = `【${testTag}】请执行命令: python3 -c 'print(1)'`;
      currentRunSessionPromptTag = testTag;
      hilog.info(DOMAIN, TAG, 'PROMPT_TAG: %{public}s', testTag);
      hilog.info(DOMAIN, TAG, 'Step 5: Sending unique command prompt: %{public}s', uniquePrompt);

      const inputChat = await driver.findComponent(ON.id('input_chat_message'));
      expect(inputChat !== null).assertTrue();
      if (inputChat) {
        await inputChat.inputText(uniquePrompt);
        const chatText = await inputChat.getText();
        hilog.info(DOMAIN, TAG, 'input_chat_message text is now: %{public}s', chatText);
      }
      await driver.delayMs(500);
      await driver.pressBack();
      await driver.delayMs(500);

      const btnSend = await driver.findComponent(ON.id('btn_send_message'));
      expect(btnSend !== null).assertTrue();
      if (btnSend) {
        await btnSend.click();
      }
      hilog.info(DOMAIN, TAG, 'Prompt sent. Waiting for real approval card to appear...');

      // 6. 等待真实审批卡片出现并断言，点击【允许一次】
      let btnOnce: Component | null = null;
      let cardContainer: Component | null = null;
      for (let i = 0; i < 30; i++) {
        btnOnce = await driver.findComponent(ON.id('btn_approval_once'));
        cardContainer = await driver.findComponent(ON.id('card_approval_container'));
        if (btnOnce) {
          break;
        }
        await driver.delayMs(1000);
      }
      expect(btnOnce !== null).assertTrue();
      expect(cardContainer !== null).assertTrue();
      hilog.info(DOMAIN, TAG, 'PHASE: CAPTURE_STAGE_01_APPROVAL_CARD');
      await driver.delayMs(2500); // 留出时间让协调器捕获稳定的审批卡片页面
      hilog.info(DOMAIN, TAG, 'Step 6: Real approval card detected. Clicking once...');
      if (btnOnce) {
        await btnOnce.click();
      }

      // 7. 等待执行完成，严密断言完整固定正文与状态恢复
      hilog.info(DOMAIN, TAG, 'Step 7: Waiting for exact agent execution output...');
      let exactReplyComp: Component | null = null;
      let btnStop: Component | null = null;
      let btnOnceAfter: Component | null = null;
      let btnSendAfter: Component | null = null;

      for (let i = 0; i < 35; i++) {
        exactReplyComp = await driver.findComponent(ON.text('The command returned: 1.', MatchPattern.CONTAINS));
        btnStop = await driver.findComponent(ON.id('btn_stop_generating'));
        btnOnceAfter = await driver.findComponent(ON.id('btn_approval_once'));
        btnSendAfter = await driver.findComponent(ON.id('btn_send_message'));

        if (exactReplyComp && !btnStop && !btnOnceAfter && btnSendAfter) {
          break;
        }
        await driver.delayMs(1000);
      }

      // 严格断言：
      // (1) 正文必须为服务端真实终态回复 "The command returned: 1."
      expect(exactReplyComp !== null).assertTrue();
      // (2) 审批卡片必须已彻底消失
      expect(btnOnceAfter === null).assertTrue();
      // (3) 生成状态必须终止 (停止按钮消失)
      expect(btnStop === null).assertTrue();
      // (4) 发送入口已恢复
      expect(btnSendAfter !== null).assertTrue();
      // (5) 助手气泡组件存在
      const assistantBubble = await driver.findComponent(ON.id('msg_bubble_assistant'));
      expect(assistantBubble !== null).assertTrue();
      hilog.info(DOMAIN, TAG, 'PHASE: CAPTURE_STAGE_02_EXACT_REPLY');
      await driver.delayMs(2500); // 留出时间让协调器捕获稳定的终态回复页面
      hilog.info(DOMAIN, TAG, 'Step 7 PASS: Exact reply verified, approval card dismissed, generation ended!');

      // 8. 真实系统生命周期测试 (切换主页后台 -> 恢复前台)
      hilog.info(DOMAIN, TAG, 'Step 8: Performing real OS background transition via driver.pressHome()...');
      await driver.pressHome();
      await driver.delayMs(2000);

      hilog.info(DOMAIN, TAG, 'Step 8: Returning to foreground via delegator.startAbility...');
      await delegator.startAbility({
        bundleName: 'com.uzairansaruzi.hermex.harmony',
        abilityName: 'EntryAbility'
      });
      await driver.delayMs(2500);

      // 验证切回前台后，历史正文依然完整呈现
      const historyAfterFg = await driver.findComponent(ON.text('The command returned: 1.', MatchPattern.CONTAINS));
      expect(historyAfterFg !== null).assertTrue();
      hilog.info(DOMAIN, TAG, 'PHASE: CAPTURE_STAGE_03_AFTER_LIFECYCLE');
      await driver.delayMs(2500); // 留出时间捕获生命周期恢复后的页面
      hilog.info(DOMAIN, TAG, 'Step 8 PASS: Real OS lifecycle foreground/background transition verified!');

      // 9. 真实网络扰动与同会话重连断言
      hilog.info(DOMAIN, TAG, 'PHASE: CAPTURE_STAGE_04_BEFORE_DISCONNECT');
      await driver.delayMs(2000);
      hilog.info(DOMAIN, TAG, 'PHASE: DISCONNECT_TRIGGER_READY');
      // 等待宿主机协调脚本移除 9199 反向端口并断开连接
      let isDisconnected = false;
      for (let i = 0; i < 20; i++) {
        const txtStatus = await driver.findComponent(ON.id('txt_connection_status'));
        if (txtStatus) {
          const sText = await txtStatus.getText();
          if (sText.indexOf('已断开') >= 0 || sText.indexOf('未连接') >= 0 || sText.indexOf('失败') >= 0) {
            isDisconnected = true;
            hilog.info(DOMAIN, TAG, 'Connection status detected as disconnected: %{public}s', sText);
            break;
          }
        }
        await driver.delayMs(1000);
      }
      expect(isDisconnected).assertTrue();
      hilog.info(DOMAIN, TAG, 'PHASE: CAPTURE_STAGE_05_DURING_DISCONNECT');
      await driver.delayMs(2000);
      hilog.info(DOMAIN, TAG, 'Step 9.1 PASS: Real network disconnect verified on UI!');

      // 通知宿主机协调脚本恢复反向端口 9199
      hilog.info(DOMAIN, TAG, 'PHASE: DISCONNECT_VERIFIED_NOW_RECONNECT');
      await driver.delayMs(3000);

      // 点击状态栏重新连接
      const btnReconnect = await driver.findComponent(ON.id('btn_reconnect_status'));
      if (btnReconnect) {
        hilog.info(DOMAIN, TAG, 'Clicking btn_reconnect_status...');
        await btnReconnect.click();
      }
      await driver.delayMs(2000);

      // 等待重新连接完成，并验证同一会话历史消息重新拉取成功
      let isReconnected = false;
      let finalReplyAfterReconnect: Component | null = null;
      let promptAfterReconnect: Component | null = null;
      let toolNameAfterReconnect: Component | null = null;
      let toolStatusAfterReconnect: Component | null = null;
      let rawJsonBubbleOnScreen: Component | null = null;

      for (let i = 0; i < 30; i++) {
        const txtStatus = await driver.findComponent(ON.id('txt_connection_status'));
        finalReplyAfterReconnect = await driver.findComponent(ON.text('The command returned: 1.', MatchPattern.CONTAINS));
        promptAfterReconnect = await driver.findComponent(ON.text(uniquePrompt, MatchPattern.CONTAINS));
        toolNameAfterReconnect = await driver.findComponent(ON.text('工具: terminal', MatchPattern.CONTAINS));
        toolStatusAfterReconnect = await driver.findComponent(ON.text('已完成', MatchPattern.CONTAINS));
        rawJsonBubbleOnScreen = await driver.findComponent(ON.text('"exit_code": 0', MatchPattern.CONTAINS));

        if (txtStatus) {
          const sText = await txtStatus.getText();
          hilog.info(DOMAIN, TAG, 'Polling reconnect [%{public}d]: sText=%{public}s, foundReply=%{public}s, foundPrompt=%{public}s, foundTool=%{public}s',
            i, sText, String(finalReplyAfterReconnect !== null), String(promptAfterReconnect !== null), String(toolNameAfterReconnect !== null));
          if (sText.indexOf('会话已恢复') >= 0 || sText.indexOf('已恢复') >= 0 || sText.indexOf('已就绪') >= 0 || sText.indexOf('已连接') >= 0 || sText.indexOf('在线') >= 0) {
            if (finalReplyAfterReconnect && promptAfterReconnect && toolNameAfterReconnect) {
              isReconnected = true;
              break;
            }
          } else if (sText.indexOf('已断开') >= 0 && i % 4 === 3) {
            hilog.info(DOMAIN, TAG, 'Still disconnected at step %{public}d, retrying reconnect click...', i);
            const retryBtn = await driver.findComponent(ON.id('btn_reconnect_status'));
            if (retryBtn) {
              await retryBtn.click();
            }
          }
        }
        await driver.delayMs(1000);
      }
      expect(isReconnected).assertTrue();
      expect(finalReplyAfterReconnect !== null).assertTrue();
      expect(promptAfterReconnect !== null).assertTrue();
      expect(toolNameAfterReconnect !== null).assertTrue();
      expect(toolStatusAfterReconnect !== null).assertTrue();
      // 绝不可将原始 tool 结果 JSON 渲染为气泡
      expect(rawJsonBubbleOnScreen === null).assertTrue();

      hilog.info(DOMAIN, TAG, 'PHASE: CAPTURE_STAGE_06_RECONNECTED_HISTORY');
      await driver.delayMs(2500); // 留出时间捕获重连历史页面
      hilog.info(DOMAIN, TAG, 'Step 9.2 PASS: Real network reconnection verified with prompt, tool name terminal, and exact reply intact!');
    });

    it('testRcpNativePatchEcho', 0, async () => {
      hilog.info(DOMAIN, TAG, 'Step RCP: Testing native RemoteCommunicationKit HTTP PATCH over reverse port 9198...');
      const ok = await HermesKanbanClient.updateCardStatus(
        'http://127.0.0.1:9198',
        'kanban-board-echo',
        'card-patch-007',
        'done'
      );
      hilog.info(DOMAIN, TAG, 'HermesKanbanClient.updateCardStatus returned: %{public}s', String(ok));
      expect(ok).assertTrue();
    });

    it('testSessionManagementUserFlow', 0, async () => {
      hilog.info(DOMAIN, TAG, 'Beginning testSessionManagementUserFlow (F02)...');
      const driver = Driver.create();
      await driver.delayMs(1500);

      // 1. 打开会话管理列表抽屉
      hilog.info(DOMAIN, TAG, 'Step SM1: Locating and clicking btn_sessions_list...');
      const btnSessions = await driver.findComponent(ON.id('btn_sessions_list'));
      expect(btnSessions !== null).assertTrue();
      if (btnSessions) {
        await btnSessions.click();
      }
      await driver.delayMs(1500);

      // 2. 验证抽屉打开，新建会话与搜索栏可见 (严格无条件断言)
      const btnNew = await driver.findComponent(ON.id('btn_new_session'));
      expect(btnNew !== null).assertTrue();
      const inputSearch = await driver.findComponent(ON.id('input_session_search'));
      expect(inputSearch !== null).assertTrue();

      // 3. 锁定当前运行产生的唯一会话行 ID (通过 promptTag 精确检索当前测试创建的全新会话)
      hilog.info(DOMAIN, TAG, 'Step SM2: Locking exact target session ID using currentRunSessionPromptTag: %{public}s...', currentRunSessionPromptTag);
      if (inputSearch && currentRunSessionPromptTag.length > 0) {
        await inputSearch.inputText(currentRunSessionPromptTag);
        await driver.delayMs(1500);
      }
      const idLabels = await driver.findComponents(ON.text('ID: ', MatchPattern.CONTAINS));
      expect(idLabels !== null && idLabels.length > 0).assertTrue();
      const firstIdLabel = idLabels[0];
      const labelText = await firstIdLabel.getText();
      const idMatch = labelText.match(/ID:\s*([a-zA-Z0-9_-]+)/);
      expect(idMatch !== null && idMatch[1].length > 0).assertTrue();
      const targetId = idMatch![1];
      hilog.info(DOMAIN, TAG, 'Locked exact target session row ID: %{public}s', targetId);

      // 4. 测试精准改名弹窗交互与保存 (严格基于 targetId 的按钮)
      hilog.info(DOMAIN, TAG, 'Step SM3: Testing session rename on targetId %{public}s...', targetId);
      const btnRenameTarget = await driver.findComponent(ON.id(`btn_rename_session_${targetId}`));
      expect(btnRenameTarget !== null).assertTrue();
      if (btnRenameTarget) {
        await btnRenameTarget.click();
        await driver.delayMs(1000);
      }

      const inputRename = await driver.findComponent(ON.id('input_rename_session'));
      expect(inputRename !== null).assertTrue();
      const newTitle = `【F02实测】_${Date.now().toString(36)}`;
      if (inputRename) {
        await inputRename.inputText(newTitle);
        await driver.delayMs(500);
      }

      const btnConfirmRename = await driver.findComponent(ON.id('btn_confirm_rename'));
      expect(btnConfirmRename !== null).assertTrue();
      if (btnConfirmRename) {
        await btnConfirmRename.click();
        await driver.delayMs(1500);
      }

      // 验证改名在界面生效
      const renamedTitleComp = await driver.findComponent(ON.text(newTitle, MatchPattern.CONTAINS));
      expect(renamedTitleComp !== null).assertTrue();
      hilog.info(DOMAIN, TAG, 'Session rename verified on UI for %{public}s: %{public}s', targetId, newTitle);

      // 5. 测试精准置顶操作与置顶 Tab 筛选 (严格基于 targetId 的置顶按钮)
      hilog.info(DOMAIN, TAG, 'Step SM4: Testing pin on targetId %{public}s...', targetId);
      const btnPinTarget = await driver.findComponent(ON.id(`btn_pin_session_${targetId}`));
      expect(btnPinTarget !== null).assertTrue();
      if (btnPinTarget) {
        await btnPinTarget.click();
        await driver.delayMs(1500);
      }

      // 验证该目标行的置顶按钮变为取消置顶
      const unpinBtnTarget = await driver.findComponent(ON.id(`btn_pin_session_${targetId}`));
      expect(unpinBtnTarget !== null).assertTrue();
      const pinBtnText = await unpinBtnTarget.getText();
      expect(pinBtnText === '取消置顶').assertTrue();

      // 切换到置顶 Tab 验证目标项存在
      const tabPinned = await driver.findComponent(ON.id('tab_session_pinned'));
      expect(tabPinned !== null).assertTrue();
      if (tabPinned) {
        await tabPinned.click();
        await driver.delayMs(1000);
      }
      const pinnedTargetInTab = await driver.findComponent(ON.id(`btn_pin_session_${targetId}`));
      expect(pinnedTargetInTab !== null).assertTrue();

      // 切回全部 Tab
      const tabAll = await driver.findComponent(ON.id('tab_session_all'));
      expect(tabAll !== null).assertTrue();
      if (tabAll) {
        await tabAll.click();
        await driver.delayMs(1000);
      }

      // 取消置顶恢复原状 (对齐 Reverse states 规范)
      const btnUnpinRestore = await driver.findComponent(ON.id(`btn_pin_session_${targetId}`));
      expect(btnUnpinRestore !== null).assertTrue();
      if (btnUnpinRestore) {
        await btnUnpinRestore.click();
        await driver.delayMs(1000);
      }
      const restoredPinBtn = await driver.findComponent(ON.id(`btn_pin_session_${targetId}`));
      expect(restoredPinBtn !== null).assertTrue();
      const restoredPinText = await restoredPinBtn.getText();
      expect(restoredPinText === '置顶').assertTrue();
      if (tabAll) {
        await tabAll.click();
        await driver.delayMs(1000);
      }

      // 6. 测试精准归档与解归档闭环 (归档 -> 切换归档Tab -> 验证 -> 恢复 -> 切回全部Tab -> 验证)
      hilog.info(DOMAIN, TAG, 'Step SM5: Testing archive and unarchive roundtrip on targetId %{public}s...', targetId);
      const btnArchiveTarget = await driver.findComponent(ON.id(`btn_archive_session_${targetId}`));
      expect(btnArchiveTarget !== null).assertTrue();
      if (btnArchiveTarget) {
        await btnArchiveTarget.click();
        await driver.delayMs(1500);
      }

      // 验证在全部 Tab 中，已归档目标已被隐藏
      const archivedGoneInAll = await driver.findComponent(ON.id(`btn_archive_session_${targetId}`));
      expect(archivedGoneInAll === null).assertTrue();

      // 切换到已归档 Tab
      const tabArchived = await driver.findComponent(ON.id('tab_session_archived'));
      expect(tabArchived !== null).assertTrue();
      if (tabArchived) {
        await tabArchived.click();
        await driver.delayMs(2000);
      }

      // 验证已归档 Tab 中目标项呈现“恢复”
      const unarchiveTargetBtn = await driver.findComponent(ON.id(`btn_archive_session_${targetId}`));
      expect(unarchiveTargetBtn !== null).assertTrue();
      const archiveBtnText = await unarchiveTargetBtn.getText();
      expect(archiveBtnText === '恢复').assertTrue();

      // 点击恢复 (解归档)
      await unarchiveTargetBtn.click();
      await driver.delayMs(1500);

      // 验证已归档 Tab 中目标项已移除
      const unarchiveGoneInArchived = await driver.findComponent(ON.id(`btn_archive_session_${targetId}`));
      expect(unarchiveGoneInArchived === null).assertTrue();

      // 切回全部 Tab 并验证已恢复项重现
      if (tabAll) {
        await tabAll.click();
        await driver.delayMs(1000);
      }
      const restoredTargetBtn = await driver.findComponent(ON.id(`btn_archive_session_${targetId}`));
      expect(restoredTargetBtn !== null).assertTrue();

      // 7. 测试分支克隆与导出
      hilog.info(DOMAIN, TAG, 'Step SM6: Testing duplicate and export on targetId %{public}s...', targetId);
      const btnDuplicateTarget = await driver.findComponent(ON.id(`btn_duplicate_session_${targetId}`));
      expect(btnDuplicateTarget !== null).assertTrue();
      if (btnDuplicateTarget) {
        await btnDuplicateTarget.click();
        await driver.delayMs(1200);
      }

      const btnExportTarget = await driver.findComponent(ON.id(`btn_export_session_${targetId}`));
      expect(btnExportTarget !== null).assertTrue();
      if (btnExportTarget) {
        await btnExportTarget.click();
        await driver.delayMs(1500);
        // 系统分享面板弹出，先按返回键关闭系统分享面板，恢复会话管理抽屉
        await driver.pressBack();
        await driver.delayMs(1000);
      }

      // 8. 清空搜索框恢复全量会话列表并断言
      hilog.info(DOMAIN, TAG, 'Step SM7: Clearing search input and verifying full session restoration...');
      const btnClearFinal = await driver.findComponent(ON.id('btn_clear_session_search'));
      expect(btnClearFinal !== null).assertTrue();
      if (btnClearFinal) {
        await btnClearFinal.click();
        await driver.delayMs(1000);
      }
      const allRestoredSessions = await driver.findComponents(ON.text('ID: ', MatchPattern.CONTAINS));
      hilog.info(DOMAIN, TAG, 'Found restored session count: %{public}d', allRestoredSessions ? allRestoredSessions.length : 0);
      expect(allRestoredSessions !== null && allRestoredSessions.length >= 1).assertTrue();

      // 9. 关闭会话管理抽屉
      hilog.info(DOMAIN, TAG, 'Step SM8: Closing session list drawer...');
      let btnClose = await driver.findComponent(ON.id('btn_close_sessions'));
      if (!btnClose) {
        await driver.pressBack();
        await driver.delayMs(1000);
        btnClose = await driver.findComponent(ON.id('btn_close_sessions'));
      }
      expect(btnClose !== null).assertTrue();
      if (btnClose) {
        await btnClose.click();
        await driver.delayMs(1000);
      }

      hilog.info(DOMAIN, TAG, 'Step SM PASS: Exact row session management UI flow fully verified on device!');
    });

    it('testCronManagementUserFlow', 0, async () => {
      hilog.info(DOMAIN, TAG, 'Beginning testCronManagementUserFlow (F08)...');
      const driver = Driver.create();
      await driver.delayMs(1500);

      // 1. 打开功能弹窗
      hilog.info(DOMAIN, TAG, 'Step CRON1: Locating and opening tools dialog...');
      const btnTools = await driver.findComponent(ON.id('btn_tools_dialog'));
      expect(btnTools !== null).assertTrue();
      if (btnTools) {
        await btnTools.click();
        await driver.delayMs(1500);
      }

      // 2. 切换至任务 (Cron) 选项卡 (Tab 0)
      hilog.info(DOMAIN, TAG, 'Step CRON2: Selecting cron tab...');
      const tabCron = await driver.findComponent(ON.id('tab_tools_cron'));
      expect(tabCron !== null).assertTrue();
      if (tabCron) {
        await tabCron.click();
        await driver.delayMs(1500);
      }

      // 3. 点击“+ 新建”打开新建 Cron 对话框
      hilog.info(DOMAIN, TAG, 'Step CRON3: Clicking btn_new_cron_job...');
      const btnNewCron = await driver.findComponent(ON.id('btn_new_cron_job'));
      expect(btnNewCron !== null).assertTrue();
      if (btnNewCron) {
        await btnNewCron.click();
        await driver.delayMs(1000);
      }

      // 4. 输入任务名称、表达式和提示词
      hilog.info(DOMAIN, TAG, 'Step CRON4: Filling cron creation inputs...');
      const cronTestName = `巡检任务_${Date.now().toString(36)}`;
      const inputName = await driver.findComponent(ON.id('input_cron_name'));
      expect(inputName !== null).assertTrue();
      if (inputName) {
        await inputName.inputText(cronTestName);
        await driver.delayMs(500);
      }

      const inputSchedule = await driver.findComponent(ON.id('input_cron_schedule'));
      expect(inputSchedule !== null).assertTrue();
      if (inputSchedule) {
        await inputSchedule.inputText('0 3 * * *');
        await driver.delayMs(500);
      }

      const inputPrompt = await driver.findComponent(ON.id('input_cron_prompt'));
      expect(inputPrompt !== null).assertTrue();
      if (inputPrompt) {
        await inputPrompt.inputText('echo "cron e2e check"');
        await driver.delayMs(500);
      }

      // 5. 点击“创建”保存任务
      hilog.info(DOMAIN, TAG, 'Step CRON5: Submitting cron job creation...');
      const btnConfirmCreate = await driver.findComponent(ON.id('btn_confirm_create_cron'));
      expect(btnConfirmCreate !== null).assertTrue();
      if (btnConfirmCreate) {
        await btnConfirmCreate.click();
        await driver.delayMs(2000);
      }

      // 6. 验证新任务在列表中呈现并锁定其唯一 targetJobId (通过只读服务回读与原生UI双重锁定)
      hilog.info(DOMAIN, TAG, 'Step CRON6: Verifying created cron job on UI and locking targetJobId...');
      await driver.delayMs(1500);

      // 通过只读后端服务回读核验锁定该唯一名称对应的真实 ID (RESUME_RUN20: 独立只读服务核验锁job)
      const loginRes = await HermesRESTClient.login('http://127.0.0.1:9199', 'hermex', 'hermex-local');
      const serverJobs = await HermesCronClient.listCronJobs('http://127.0.0.1:9199', 'default', loginRes.token, loginRes.cookies);
      const targetJob = serverJobs.find((j: CronJobItem) => j.name === cronTestName);
      expect(targetJob !== undefined && targetJob !== null).assertTrue();
      const targetJobId = targetJob!.id;
      hilog.info(DOMAIN, TAG, 'Locked exact target cron job ID from server readback: %{public}s', targetJobId);

      // 验证原生 UI 上该任务的稳定组件与排期文本均完整呈现
      const cronList = await driver.findComponent(ON.id('list_cron_jobs'));
      let createdJobText = await driver.findComponent(ON.text(cronTestName));
      if (!createdJobText && cronList) {
        createdJobText = await cronList.scrollSearch(ON.text(cronTestName));
      }
      expect(createdJobText !== null).assertTrue();

      const jobNameComp = await driver.findComponent(ON.id(`txt_cron_name_${targetJobId}`));
      expect(jobNameComp !== null).assertTrue();
      const jobScheduleComp = await driver.findComponent(ON.id(`txt_cron_schedule_${targetJobId}`));
      expect(jobScheduleComp !== null).assertTrue();

      // 7. 测试精准触发执行指定任务 (强断言 targetJobId 运行按钮)
      hilog.info(DOMAIN, TAG, 'Step CRON7: Triggering exact cron job %{public}s...', targetJobId);
      const btnTriggerTarget = await driver.findComponent(ON.id(`btn_trigger_cron_${targetJobId}`));
      expect(btnTriggerTarget !== null).assertTrue();
      if (btnTriggerTarget) {
        await btnTriggerTarget.click();
        await driver.delayMs(2500);
      }

      // 8. 测试精准编辑任务并保存与回读
      hilog.info(DOMAIN, TAG, 'Step CRON8: Editing exact cron job %{public}s...', targetJobId);
      const btnEditTarget = await driver.findComponent(ON.id(`btn_edit_cron_${targetJobId}`));
      expect(btnEditTarget !== null).assertTrue();
      if (btnEditTarget) {
        await btnEditTarget.click();
        await driver.delayMs(1000);
      }
      const updatedCronName = `巡检_${Date.now().toString(36)}`;
      const inputEditName = await driver.findComponent(ON.id('input_edit_cron_name'));
      expect(inputEditName !== null).assertTrue();
      if (inputEditName) {
        await inputEditName.inputText(updatedCronName);
        await driver.delayMs(500);
      }
      const btnConfirmEdit = await driver.findComponent(ON.id('btn_confirm_edit_cron'));
      expect(btnConfirmEdit !== null).assertTrue();
      if (btnConfirmEdit) {
        await btnConfirmEdit.click();
        await driver.delayMs(1500);
      }
      // 验证编辑后名称已在界面呈现
      let editedComp = await driver.findComponent(ON.text(updatedCronName));
      if (!editedComp && cronList) {
        editedComp = await cronList.scrollSearch(ON.text(updatedCronName));
      }
      expect(editedComp !== null).assertTrue();

      // 服务端只读回读确认编辑成功已生效
      const updatedServerJobs = await HermesCronClient.listCronJobs('http://127.0.0.1:9199', 'default', loginRes.token, loginRes.cookies);
      const updatedJobOnServer = updatedServerJobs.find((j: CronJobItem) => j.id === targetJobId);
      expect(updatedJobOnServer !== undefined && updatedJobOnServer!.name === updatedCronName).assertTrue();

      // 9. 测试任务历史弹窗
      hilog.info(DOMAIN, TAG, 'Step CRON9: Opening cron run history for %{public}s...', targetJobId);
      const btnHistoryTarget = await driver.findComponent(ON.id(`btn_history_cron_${targetJobId}`));
      expect(btnHistoryTarget !== null).assertTrue();
      if (btnHistoryTarget) {
        await btnHistoryTarget.click();
        await driver.delayMs(1500);

        const dialogHistory = await driver.findComponent(ON.id('dialog_cron_history'));
        expect(dialogHistory !== null).assertTrue();

        // 强断言：历史记录必须非空且包含本任务的 run ID 或终态 (RESUME_RUN20: 历史必须非空且对应实际run ID/终态)
        const runItemComp = await driver.findComponent(ON.text(targetJobId, MatchPattern.CONTAINS));
        expect(runItemComp !== null).assertTrue();

        const btnCloseHistory = await driver.findComponent(ON.id('btn_close_cron_history'));
        expect(btnCloseHistory !== null).assertTrue();
        if (btnCloseHistory) {
          await btnCloseHistory.click();
          await driver.delayMs(1000);
        }
      }

      // 10. 暂停测试任务避免后续自动运行 (强断言 targetJobId 暂停按钮，严禁删除任务)
      hilog.info(DOMAIN, TAG, 'Step CRON10: Pausing exact cron job %{public}s...', targetJobId);
      let btnToggleTarget = await driver.findComponent(ON.id(`btn_toggle_cron_${targetJobId}`));
      if (!btnToggleTarget && cronList) {
        btnToggleTarget = await cronList.scrollSearch(ON.id(`btn_toggle_cron_${targetJobId}`));
      }
      expect(btnToggleTarget !== null).assertTrue();
      if (btnToggleTarget) {
        const toggleText = await btnToggleTarget.getText();
        if (toggleText === '暂停') {
          await btnToggleTarget.click();
          await driver.delayMs(1500);
        }
      }
      // 服务端只读核验暂停生效
      const pausedServerJobs = await HermesCronClient.listCronJobs('http://127.0.0.1:9199', 'default', loginRes.token, loginRes.cookies);
      const pausedJobOnServer = pausedServerJobs.find((j: CronJobItem) => j.id === targetJobId);
      expect(pausedJobOnServer !== undefined && pausedJobOnServer!.enabled === false).assertTrue();

      // 11. 关闭功能弹窗
      hilog.info(DOMAIN, TAG, 'Step CRON11: Closing tools dialog...');
      const btnCloseTools = await driver.findComponent(ON.id('btn_close_tools_dialog'));
      expect(btnCloseTools !== null).assertTrue();
      if (btnCloseTools) {
        await btnCloseTools.click();
        await driver.delayMs(1000);
      }

      hilog.info(DOMAIN, TAG, 'Step CRON PASS: Cron management UI flow fully verified on device!');
    });
  });
}
