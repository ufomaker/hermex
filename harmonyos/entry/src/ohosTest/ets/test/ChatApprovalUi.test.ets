import { hilog } from '@kit.PerformanceAnalysisKit';
import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { Driver, ON, Component, MatchPattern } from '@ohos.UiTest';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { HermesKanbanClient } from '../../../main/ets/network/HermesKanbanClient';

const DOMAIN = 0x0000;
const TAG = 'ChatApprovalUiTest';

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
      const testTag = 'RUN15_' + Date.now().toString(36);
      const uniquePrompt = `【${testTag}】请执行命令: python3 -c 'print(1)'`;
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
      hilog.info(DOMAIN, TAG, 'Step 8 PASS: Real OS lifecycle foreground/background transition verified!');

      // 9. 真实网络扰动与同会话重连断言
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
      for (let i = 0; i < 30; i++) {
        const txtStatus = await driver.findComponent(ON.id('txt_connection_status'));
        finalReplyAfterReconnect = await driver.findComponent(ON.text('The command returned: 1.', MatchPattern.CONTAINS));
        if (txtStatus) {
          const sText = await txtStatus.getText();
          hilog.info(DOMAIN, TAG, 'Polling reconnect [%{public}d]: sText=%{public}s, foundReply=%{public}s', i, sText, String(finalReplyAfterReconnect !== null));
          if (sText.indexOf('会话已恢复') >= 0 || sText.indexOf('已恢复') >= 0 || sText.indexOf('已就绪') >= 0 || sText.indexOf('已连接') >= 0 || sText.indexOf('在线') >= 0) {
            if (finalReplyAfterReconnect) {
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
      hilog.info(DOMAIN, TAG, 'Step 9.2 PASS: Real network reconnection to same session verified with exact reply intact!');
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
  });
}
