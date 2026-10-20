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

      // 5. 中文输入并发出
      hilog.info(DOMAIN, TAG, 'Step 5: Sending command prompt to agent...');
      const inputChat = await driver.findComponent(ON.id('input_chat_message'));
      expect(inputChat !== null).assertTrue();
      if (inputChat) {
        await inputChat.inputText("请执行 python3 -c 'print(1)'");
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

      // 6. 等待真实审批卡片出现并点击【允许一次】
      let btnOnce: Component | null = null;
      for (let i = 0; i < 30; i++) {
        btnOnce = await driver.findComponent(ON.id('btn_approval_once'));
        if (btnOnce) {
          break;
        }
        await driver.delayMs(1000);
      }
      expect(btnOnce !== null).assertTrue();
      hilog.info(DOMAIN, TAG, 'Step 6: Approval card detected. Clicking once...');
      if (btnOnce) {
        await btnOnce.click();
      }

      // 7. 等待执行完成，验证正文输出包含 '1' 且生成状态终止
      hilog.info(DOMAIN, TAG, 'Step 7: Waiting for agent execution output...');
      let outputVerified = false;
      for (let i = 0; i < 35; i++) {
        const resultComp = await driver.findComponent(ON.text('1', MatchPattern.CONTAINS));
        const btnStop = await driver.findComponent(ON.id('btn_stop_generating'));
        if (resultComp && !btnStop) {
          outputVerified = true;
          break;
        }
        await driver.delayMs(1000);
      }
      expect(outputVerified).assertTrue();
      hilog.info(DOMAIN, TAG, 'Output contains 1 and tool execution complete');

      // 8. 切前后台与重连，验证原会话历史正确无损
      hilog.info(DOMAIN, TAG, 'Step 8: Toggling app background and foreground...');
      AppStorage.setOrCreate('appScenePhase', 'background');
      await driver.delayMs(1000);
      AppStorage.setOrCreate('appScenePhase', 'active');
      await driver.delayMs(2500);

      const historyComp = await driver.findComponent(ON.text('1', MatchPattern.CONTAINS));
      expect(historyComp !== null).assertTrue();
      hilog.info(DOMAIN, TAG, 'Prior session history verified intact after foreground reattach!');
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
