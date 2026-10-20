import { ConnectionViewModel } from '../viewmodel/ConnectionViewModel';
import { SessionListViewModel } from '../viewmodel/SessionListViewModel';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { WorkspaceViewModel } from '../viewmodel/WorkspaceViewModel';
import { CronViewModel } from '../viewmodel/CronViewModel';
import { SkillsViewModel } from '../viewmodel/SkillsViewModel';
import { InsightsViewModel } from '../viewmodel/InsightsViewModel';
import { GitWorkspaceViewModel } from '../viewmodel/GitWorkspaceViewModel';
import { BotConnection, HermesStatus } from '../model/Connection';
import { HermesSession } from '../model/Session';
import { ChatMessage, ToolCallItem } from '../model/ChatMessage';
import { ModelOption } from '../model/Approval';
import { WorkspaceFileEntry } from '../network/HermesWorkspaceClient';
import { HermesFileClient } from '../network/HermesFileClient';
import { CronJobItem } from '../network/HermesCronClient';
import { SkillSummary } from '../network/HermesSkillsClient';
import { ModelUsageItem } from '../network/HermesInsightsClient';
import { GitBranchInfo } from '../network/HermesProjectClient';
import { KanbanViewModel } from '../viewmodel/KanbanViewModel';
import { KanbanBoardSnapshot, KanbanColumnItem, KanbanCardItem, KanbanBoardItem } from '../network/HermesKanbanClient';
import { NotificationUtils } from '../utils/NotificationUtils';
import { AuthStore } from '../storage/AuthStore';
import { MarkdownView } from '../components/MarkdownView';
import { getMimeType, isImageFile, sanitizeFilename, generateAttachmentName } from '../utils/AttachmentUtils';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import { DeepLinkUtils, AppDeepLinkRouter, DeepLinkRoute, InboundShareData } from '../utils/DeepLinkUtils';
import { ShareUtils } from '../utils/ShareUtils';
import { VoiceUtils } from '../utils/VoiceUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'HermexIndex';

@Entry
@Component
struct Index {
  @State serverUrl: string = '';
  @State usernameInput: string = '';
  @State passwordInput: string = '';
  @State statusProbeText: string = '';
  @State inputText: string = '';
  @State isRecordingVoice: boolean = false;
  @State isPlayingAudio: boolean = false;
  @State currentlyPlayingAudioUrl: string = '';
  @State currentSessionTitle: string = '未选择会话';
  @State currentSessionId: string = '';
  @State showServerDialog: boolean = false;
  @State showSessionListDialog: boolean = false;
  @State showModelDialog: boolean = false;
  @State showWorkspaceDialog: boolean = false;
  @State showAttachmentDialog: boolean = false;
  @State showToolsDialog: boolean = false;
  @State selectedToolsTab: number = 0; // 0:任务, 1:技能, 2:设定, 3:用量, 4:Git, 5:看板

  // ViewModels
  private connVm: ConnectionViewModel = new ConnectionViewModel();
  private sessionVm: SessionListViewModel = new SessionListViewModel();
  private chatVm: ChatViewModel = new ChatViewModel();
  private workspaceVm: WorkspaceViewModel = new WorkspaceViewModel();
  private cronVm: CronViewModel = new CronViewModel();
  private skillsVm: SkillsViewModel = new SkillsViewModel();
  private insightsVm: InsightsViewModel = new InsightsViewModel();
  private gitVm: GitWorkspaceViewModel = new GitWorkspaceViewModel();
  private kanbanVm: KanbanViewModel = new KanbanViewModel();

  // Kanban States
  @State kanbanBoards: KanbanBoardItem[] = [];
  @State selectedKanbanSlug: string = '';
  @State selectedKanbanName: string = '';
  @State isKanbanReadOnly: boolean = false;
  @State kanbanSnapshot: KanbanBoardSnapshot | null = null;
  @State newCardTitleInput: string = '';

  // App Lifecycle & Platform Listeners
  @StorageProp('appScenePhase') @Watch('onScenePhaseChanged') scenePhase: string = 'active';
  private routeListener: ((route: DeepLinkRoute) => void) | null = null;
  private shareListener: ((share: InboundShareData) => void) | null = null;

  // Observable UI States
  @State isConnected: boolean = false;
  @State connectionStatusText: string = '未连接';
  @State isGenerating: boolean = false;
  @State currentModel: string = '默认模型';
  @State messages: ChatMessage[] = [];
  @State sessions: HermesSession[] = [];
  @State availableModels: ModelOption[] = [];
  @State hasApproval: boolean = false;
  @State approvalDesc: string = '';
  @State approvalChoices: string[] = ['once', 'deny'];
  @State isSubmittingApproval: boolean = false;
  @State hasClarify: boolean = false;
  @State clarifyQuestion: string = '';
  @State clarifyOptions: string[] = [];
  @State isSubmittingClarify: boolean = false;

  // Workspace Observable States
  @State workspaceEntries: WorkspaceFileEntry[] = [];
  @State workspacePath: string = '';
  @State isWorkspaceLoading: boolean = false;
  @State workspaceError: string = '';
  @State viewingFileName: string = '';
  @State viewingFileText: string = '';
  @State isViewingFile: boolean = false;
  @State isDownloadingFile: boolean = false;
  @State lastDownloadedFileName: string = '';
  @State lastDownloadedFilePath: string = '';

  // Tools Observable States
  @State isToolsLoading: boolean = false;
  @State toolsStatusText: string = '';
  @State editingSoulText: string = '';

  // Attachment States
  @State isUploadingAttachment: boolean = false;
  @State attachmentStatusText: string = '';

  async aboutToAppear() {
    this.chatVm.setListener({
      onStateChanged: () => {
        this.syncVmState();
      },
      onErrorToast: (msg: string) => {
        this.showToast(msg);
      }
    });

    this.workspaceVm.setListener({
      onStateChanged: () => {
        this.workspaceEntries = this.workspaceVm.entries.slice();
        this.workspacePath = this.workspaceVm.currentRelativePath;
        this.isWorkspaceLoading = this.workspaceVm.isLoading;
        this.workspaceError = this.workspaceVm.errorMessage;
        this.viewingFileName = this.workspaceVm.selectedFileName;
        this.viewingFileText = this.workspaceVm.selectedFileText;
        this.isViewingFile = this.workspaceVm.isViewingFile;
        this.isDownloadingFile = this.workspaceVm.isDownloading;
      }
    });

    this.kanbanVm.setListener({
      onStateChanged: () => {
        this.kanbanBoards = this.kanbanVm.boards.slice();
        this.selectedKanbanSlug = this.kanbanVm.selectedBoardSlug;
        this.selectedKanbanName = this.kanbanVm.selectedBoardName;
        this.isKanbanReadOnly = this.kanbanVm.isReadOnly;
        this.kanbanSnapshot = this.kanbanVm.currentSnapshot;
      }
    });

    // 严格等待 AuthStore 完成平台安全存储初始化与冷启动数据还原
    await AuthStore.getInstance().waitUntilReady();
    this.initDefaultConnection();

    // 检查并消费外部启动深层链接与系统分享
    this.drainPendingDeepLinkAndShare();
    this.routeListener = (route: DeepLinkRoute) => {
      this.handleDeepLinkRoute(route);
    };
    this.shareListener = (share: InboundShareData) => {
      this.handleInboundShare(share);
    };
    AppDeepLinkRouter.getInstance().addRouteListener(this.routeListener);
    AppDeepLinkRouter.getInstance().addShareListener(this.shareListener);
  }

  private onScenePhaseChanged(): void {
    if (this.scenePhase === 'active') {
      const cur = this.connVm.getCurrentConnection();
      if (cur && this.currentSessionId) {
        if (!this.chatVm.isConnected) {
          this.showToast('应用回到前台，正在恢复会话连接...');
          this.chatVm.attachSession(cur, this.currentSessionId).catch((_e: Object) => {});
        }
      }
    }
  }

  private drainPendingDeepLinkAndShare(): void {
    const route = AppDeepLinkRouter.getInstance().consumePendingRoute();
    if (route) {
      this.handleDeepLinkRoute(route);
    }
    const share = AppDeepLinkRouter.getInstance().consumePendingShare();
    if (share) {
      this.handleInboundShare(share);
    }
  }

  private findMatchingConnection(targetServer: string): BotConnection | null {
    if (!targetServer) return null;
    const allConns = this.connVm.getSavedConnections();
    const cleanTarget = targetServer.trim().toLowerCase().replace(/\/+$/, '');
    // 1. 精确匹配稳定 ID
    const byId = allConns.find((c) => c.id === targetServer);
    if (byId) return byId;
    // 2. 精确匹配规范化 URL
    const byUrl = allConns.find((c) => c.url.trim().toLowerCase().replace(/\/+$/, '') === cleanTarget);
    if (byUrl) return byUrl;
    // 3. 精确匹配名称
    const byName = allConns.find((c) => c.name.trim().toLowerCase() === cleanTarget);
    if (byName) return byName;
    return null;
  }

  private async handleInboundShare(share: InboundShareData): Promise<void> {
    if (!share) return;
    if (share.text) {
      this.inputText = this.inputText ? `${this.inputText}\n${share.text}` : share.text;
      this.showToast('已载入外部应用分享的文本');
    }
    if (share.uri) {
      const uriStr = share.uri;
      const cur = this.connVm.getCurrentConnection();
      if (!cur) {
        this.showToast('未连接服务器，分享文件未能上传');
        return;
      }

      try {
        const lastSlash = Math.max(uriStr.lastIndexOf('/'), uriStr.lastIndexOf('\\'));
        const rawName = lastSlash >= 0 ? uriStr.substring(lastSlash + 1) : uriStr;
        const cleanName = sanitizeFilename(rawName.split('?')[0] || `share_${Date.now()}`);
        const mime = getMimeType(cleanName);
        const isImg = isImageFile(cleanName);

        const file = fs.openSync(uriStr, fs.OpenMode.READ_ONLY);
        let buf: ArrayBuffer;
        try {
          const stat = fs.statSync(file.fd);
          buf = new ArrayBuffer(stat.size);
          fs.readSync(file.fd, buf);
        } finally {
          fs.closeSync(file.fd);
        }

        const base64Helper = new util.Base64Helper();
        const b64 = base64Helper.encodeToStringSync(new Uint8Array(buf));
        const dataUrl = `data:${mime};base64,${b64}`;

        if (isImg) {
          const profile = cur.activeProfile ? cur.activeProfile : 'default';
          const uploadResult = await HermesFileClient.uploadImage(
            cur.url,
            profile,
            cleanName,
            dataUrl,
            cur.token,
            cur.cookies
          );
          const targetPath = uploadResult.path || uploadResult.url || cleanName;
          const refTag = `![${cleanName}](${targetPath})\n`;
          this.inputText = this.inputText ? `${this.inputText}\n${refTag}` : refTag;
          this.showToast(`已上传外部分享图片: ${cleanName}`);
        } else {
          const attachName = generateAttachmentName(cleanName);
          await this.chatVm.attachDocument(attachName, dataUrl);
          const refTag = `[📎 附件: ${cleanName}](${attachName})\n`;
          this.inputText = this.inputText ? `${this.inputText}\n${refTag}` : refTag;
          this.showToast(`已附加外部分享文件: ${cleanName}`);
        }
      } catch (e) {
        this.showToast(`读取或上传分享文件失败: ${e}`);
      }
    }
  }

  private async handleDeepLinkRoute(route: DeepLinkRoute): Promise<void> {
    if (route.type === 'session') {
      let targetConn: BotConnection | null = null;
      if (route.server) {
        const matched = this.findMatchingConnection(route.server);
        if (!matched) {
          this.showToast(`深层链接指定的服务器未配置: ${route.server}`);
          return;
        }
        targetConn = matched;
        await this.connVm.selectConnection(targetConn.id);
      } else {
        targetConn = this.connVm.getCurrentConnection();
      }

      if (!targetConn) {
        this.showToast('请先配置并连接 Hermes 服务器');
        return;
      }

      if (route.profile) {
        targetConn.activeProfile = route.profile;
      }

      this.currentSessionId = route.sessionId;
      this.currentSessionTitle = `会话: ${route.sessionId.substring(0, 8)}...`;
      this.chatVm.messages = [];
      this.syncVmState();
      await this.chatVm.attachSession(targetConn, route.sessionId);
      this.showToast(`已通过深层链接切入会话: ${route.sessionId}`);
    } else if (route.type === 'new_chat') {
      const sessId = await this.createNewSession();
      if (sessId) {
        if (route.autoStartsVoice) {
          this.showToast('已创建新会话，正在启动语音输入...');
          await this.toggleVoiceRecording();
        } else {
          this.showToast('已通过深层链接创建新会话');
        }
      }
    } else if (route.type === 'new_chat_profile') {
      if (route.server) {
        const matched = this.findMatchingConnection(route.server);
        if (matched) {
          await this.connVm.selectConnection(matched.id);
        } else {
          this.showToast(`未找到指定服务器: ${route.server}`);
          return;
        }
      }
      const sessId = await this.createNewSession(route.profile);
      if (sessId) {
        this.showToast(`已在配置 Profile【${route.profile}】下创建新会话`);
      }
    } else if (route.type === 'bot') {
      let matched: BotConnection | null = null;
      if (route.server) {
        matched = this.findMatchingConnection(route.server);
      } else if (route.connection) {
        matched = this.findMatchingConnection(route.connection);
      }
      if (matched) {
        if (route.profile) {
          matched.activeProfile = route.profile;
        }
        await this.connVm.selectConnection(matched.id);
        const sessId = await this.createNewSession(route.profile);
        if (sessId) {
          this.showToast(`已切换至 Bot【${matched.name}】并创建新会话`);
        }
      } else {
        this.showToast(`深链指定的 Bot 未配置: server=${route.server || '无'}, conn=${route.connection || '无'}`);
      }
    }
  }

  aboutToDisappear() {
    if (this.routeListener) {
      AppDeepLinkRouter.getInstance().removeRouteListener(this.routeListener);
      this.routeListener = null;
    }
    if (this.shareListener) {
      AppDeepLinkRouter.getInstance().removeShareListener(this.shareListener);
      this.shareListener = null;
    }
    this.chatVm.disconnect();
  }

  private async toggleVoiceRecording(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    if (!this.isRecordingVoice) {
      const hasPerm = await VoiceUtils.checkMicrophonePermission(ctx);
      if (!hasPerm) {
        this.showToast('需要麦克风权限才能录制语音');
        return;
      }
      const outPath = `${ctx.filesDir}/voice_${Date.now()}.m4a`;
      const started = await VoiceUtils.startRecording(outPath);
      if (started) {
        this.isRecordingVoice = true;
        this.showToast('正在录音...再次点击停止');
      } else {
        this.showToast('启动录音失败');
      }
    } else {
      const recordedPath = await VoiceUtils.stopRecording();
      this.isRecordingVoice = false;
      if (recordedPath) {
        const cur = this.connVm.getCurrentConnection();
        if (!cur || !this.chatVm.isConnected) {
          this.showToast('未连接服务器，录音已保存但未附加');
          return;
        }
        try {
          const file = fs.openSync(recordedPath, fs.OpenMode.READ_ONLY);
          let buf: ArrayBuffer;
          try {
            const stat = fs.statSync(file.fd);
            buf = new ArrayBuffer(stat.size);
            fs.readSync(file.fd, buf);
          } finally {
            fs.closeSync(file.fd);
          }
          const base64Helper = new util.Base64Helper();
          const b64 = base64Helper.encodeToStringSync(new Uint8Array(buf));
          const dataUrl = `data:audio/m4a;base64,${b64}`;
          const attachName = generateAttachmentName('voice_recording.m4a');
          await this.chatVm.attachDocument(attachName, dataUrl);
          const tag = `[🎤 语音: ${attachName}](${attachName})\n`;
          this.inputText = this.inputText ? `${this.inputText}\n${tag}` : tag;
          this.showToast('录音完成并已附加到会话');
        } catch (err) {
          this.showToast(`语音附加失败: ${err}`);
        }
      } else {
        this.showToast('未录制到有效音频');
      }
    }
  }

  private async handlePlayVoiceMessage(content: string): Promise<void> {
    if (this.isPlayingAudio) {
      await VoiceUtils.stopAudio();
      this.isPlayingAudio = false;
      this.currentlyPlayingAudioUrl = '';
      return;
    }
    const match = content.match(/\[🎤 语音[^\]]*\]\(([^)]+)\)/);
    const audioTarget = match ? match[1] : '';
    if (!audioTarget) {
      this.showToast('未找到有效音频地址');
      return;
    }
    this.isPlayingAudio = true;
    this.currentlyPlayingAudioUrl = audioTarget;
    this.showToast('正在播放音频...');
    const ok = await VoiceUtils.playAudio(audioTarget, {
      onStart: () => {},
      onComplete: () => {
        this.isPlayingAudio = false;
        this.currentlyPlayingAudioUrl = '';
      },
      onError: (err: string) => {
        this.isPlayingAudio = false;
        this.currentlyPlayingAudioUrl = '';
        this.showToast(`播放失败: ${err}`);
      }
    });
    if (!ok) {
      this.isPlayingAudio = false;
      this.currentlyPlayingAudioUrl = '';
      this.showToast('无法启动音频播放');
    }
  }

  private async shareCurrentSession(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    if (this.messages.length === 0) {
      this.showToast('当前会话暂无消息可分享');
      return;
    }
    const lines = this.messages.map((m: ChatMessage) => `${m.role === 'user' ? '用户' : 'Hermes'}: ${m.content}`);
    const textToShare = lines.join('\n\n');
    const ok = await ShareUtils.shareText(ctx, textToShare, this.currentSessionTitle);
    if (!ok) {
      this.showToast('调起系统分享失败');
    }
  }

  private showToast(message: string): void {
    try {
      promptAction.showToast({ message: message, duration: 3000 });
    } catch (e) {
      // ignore
    }
  }

  private syncVmState() {
    this.isConnected = this.chatVm.isConnected;
    this.connectionStatusText = this.chatVm.connectionStatusText;
    this.isGenerating = this.chatVm.isGenerating;
    this.currentModel = this.chatVm.currentModel;
    this.messages = this.chatVm.messages.slice();
    this.availableModels = this.chatVm.availableModels.slice();
    this.isSubmittingApproval = this.chatVm.isSubmittingApproval;
    this.isSubmittingClarify = this.chatVm.isSubmittingClarify;

    if (this.chatVm.currentApproval) {
      this.hasApproval = true;
      const app = this.chatVm.currentApproval;
      this.approvalDesc = `${app.toolName || '工具'}: ${app.command || app.description || '执行请求'}`;
      this.approvalChoices = app.choices && app.choices.length > 0 ? app.choices : ['once', 'deny'];
    } else {
      this.hasApproval = false;
      this.approvalDesc = '';
      this.approvalChoices = [];
    }

    if (this.chatVm.currentClarify) {
      this.hasClarify = true;
      this.clarifyQuestion = this.chatVm.currentClarify.question;
      this.clarifyOptions = this.chatVm.currentClarify.options || ['确认', '跳过'];
    } else {
      this.hasClarify = false;
      this.clarifyQuestion = '';
      this.clarifyOptions = [];
    }
  }

  private initDefaultConnection() {
    const cur = this.connVm.getCurrentConnection();
    if (cur) {
      this.serverUrl = cur.url;
      this.usernameInput = cur.username || '';
      this.passwordInput = cur.password || '';
    }
  }

  private async probeServer() {
    try {
      this.statusProbeText = '正在探测服务...';
      const status: HermesStatus = await this.connVm.probeStatus(this.serverUrl);
      this.statusProbeText = `版本: ${status.version} | 认证: ${status.auth_required ? '需要' : '无需'} | Profiles: ${status.profiles.join(', ')}`;
    } catch (e) {
      this.statusProbeText = `探测失败: ${e}`;
    }
  }

  private async connectAndStart() {
    try {
      hilog.info(DOMAIN, TAG, 'connectAndStart: url=%{public}s user=%{public}s', this.serverUrl, this.usernameInput);
      this.statusProbeText = '正在连接认证并核验 /api/auth/me ...';
      const conn = await this.connVm.loginAndSave('Hermes', this.serverUrl, this.usernameInput, this.passwordInput);
      hilog.info(DOMAIN, TAG, 'connectAndStart: logged in successfully, conn=%{public}s', conn.id);
      this.showServerDialog = false;

      // 拉取会话列表
      this.sessions = await this.sessionVm.loadSessions(conn);
      hilog.info(DOMAIN, TAG, 'connectAndStart: loaded %{public}d sessions', this.sessions.length);
      if (this.sessions.length > 0) {
        // 自动接入最近的一个真实会话
        await this.switchSession(this.sessions[0]);
      } else {
        // 无会话时提示新建
        this.currentSessionTitle = '请新建会话';
        this.showSessionListDialog = true;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'connectAndStart failed: %{public}s', JSON.stringify(e));
      this.statusProbeText = `连接失败: ${e}`;
    }
  }

  private async refreshSessions() {
    const cur = this.connVm.getCurrentConnection();
    if (!cur) return;
    try {
      this.sessions = await this.sessionVm.loadSessions(cur);
    } catch (e) {
      // ignore
    }
  }

  private async switchSession(session: HermesSession) {
    this.currentSessionId = session.id;
    this.currentSessionTitle = session.title || '会话';
    this.showSessionListDialog = false;
    this.chatVm.messages = [];
    this.syncVmState();
    const cur = this.connVm.getCurrentConnection();
    if (cur) {
      // 真实恢复会话与拉取历史
      await this.chatVm.attachSession(cur, this.currentSessionId);
    }
  }

  private async createNewSession(profile?: string): Promise<string | null> {
    hilog.info(DOMAIN, TAG, 'createNewSession requested with profile=%{public}s', profile || 'default');
    const cur = this.connVm.getCurrentConnection();
    if (!cur) {
      hilog.warn(DOMAIN, TAG, 'createNewSession: no active connection!');
      this.showToast('请先配置并连接 Hermes 服务器');
      return null;
    }
    try {
      if (profile) {
        cur.activeProfile = profile;
      }
      if (!this.chatVm.isConnected) {
        hilog.info(DOMAIN, TAG, 'createNewSession: chatVm not connected, attaching...');
        await this.chatVm.attachSession(cur, '');
      }
      const realSessionId = await this.chatVm.createAndAttachNewSession(cur);
      hilog.info(DOMAIN, TAG, 'createNewSession: created and attached real session ID=%{public}s', realSessionId);
      this.currentSessionId = realSessionId;
      this.currentSessionTitle = '新对话';
      this.showSessionListDialog = false;
      this.refreshSessions();
      return realSessionId;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'createNewSession failed: %{public}s', JSON.stringify(e));
      this.showToast(`创建会话失败: ${e}`);
      return null;
    }
  }

  private async loadCurrentToolsData() {
    const cur = this.connVm.getCurrentConnection();
    if (!cur) return;
    this.isToolsLoading = true;
    this.toolsStatusText = '正在加载...';
    try {
      if (this.selectedToolsTab === 0) {
        await this.cronVm.loadJobs(cur);
        this.toolsStatusText = this.cronVm.statusMessage;
      } else if (this.selectedToolsTab === 1 || this.selectedToolsTab === 2) {
        await this.skillsVm.loadSkillsAndMemory(cur);
        this.editingSoulText = this.skillsVm.soulText;
        this.toolsStatusText = this.skillsVm.statusMessage;
      } else if (this.selectedToolsTab === 3) {
        await this.insightsVm.loadInsights(cur, 7);
        this.toolsStatusText = this.insightsVm.statusMessage;
      } else if (this.selectedToolsTab === 4) {
        await this.gitVm.loadProjectsAndGit(cur, this.workspacePath);
        this.toolsStatusText = this.gitVm.statusMessage;
      } else if (this.selectedToolsTab === 5) {
        await this.kanbanVm.loadBoards(cur);
        this.toolsStatusText = this.kanbanVm.statusMessage;
      }
    } catch (e) {
      this.toolsStatusText = `加载异常: ${e}`;
    } finally {
      this.isToolsLoading = false;
    }
  }

  /**
   * 下载文件并实际保存到文件系统或用户选择的存储位置
   * 严格遵循路径安全、用户取消处理、写入完整性校验与文件描述符关闭
   */
  private async handleDownloadFile(entry: WorkspaceFileEntry) {
    const cur = this.connVm.getCurrentConnection();
    if (!cur) return;

    try {
      this.showToast(`正在下载 ${entry.name}...`);
      const buffer = await this.workspaceVm.downloadFile(cur, entry, this.currentSessionId);
      const safeName = sanitizeFilename(entry.name);

      let savedLocation = '';
      let isUserCancelled = false;

      try {
        const docPicker = new picker.DocumentViewPicker();
        const saveOptions = new picker.DocumentSaveOptions();
        saveOptions.newFileNames = [safeName];
        const uris = await docPicker.save(saveOptions);
        if (uris && uris.length > 0) {
          const file = fs.openSync(uris[0], fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
          try {
            const written = fs.writeSync(file.fd, buffer);
            if (written !== buffer.byteLength) {
              throw new Error(`写入不完整: 预期 ${buffer.byteLength} 字节, 实际写入 ${written} 字节`);
            }
          } finally {
            fs.closeSync(file.fd);
          }
          savedLocation = uris[0];
        } else {
          isUserCancelled = true;
        }
      } catch (pickerErr) {
        const errStr = String(pickerErr || '').toLowerCase();
        if (errStr.includes('cancel') || errStr.includes('13900020')) {
          isUserCancelled = true;
        }
      }

      if (isUserCancelled) {
        this.showToast('已取消保存文件');
        return;
      }

      // 若系统选择器未提供返回但非用户主动取消，安全降级写入应用沙箱
      if (!savedLocation) {
        const ctx = getContext(this);
        const targetPath = `${ctx.filesDir}/${safeName}`;
        const file = fs.openSync(targetPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        try {
          const written = fs.writeSync(file.fd, buffer);
          if (written !== buffer.byteLength) {
            throw new Error(`写入不完整: 预期 ${buffer.byteLength} 字节, 实际写入 ${written} 字节`);
          }
        } finally {
          fs.closeSync(file.fd);
        }
        savedLocation = targetPath;
      }

      this.lastDownloadedFileName = safeName;
      this.lastDownloadedFilePath = savedLocation;
      this.showToast(`文件已成功保存: ${safeName} (${buffer.byteLength} 字节)`);
    } catch (e) {
      this.showToast(`下载或保存失败: ${e}`);
    }
  }

  /**
   * 调起系统应用打开或分享已保存的文件
   */
  private openOrShareFile(filePath: string, filename: string) {
    if (!filePath) {
      this.showToast('暂无已保存的文件路径');
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: filePath.startsWith('file://') ? filePath : `file://${filePath}`,
        type: getMimeType(filename)
      };
      ctx.startAbility(want).then(() => {
        this.showToast(`正在打开 ${filename}...`);
      }).catch((err: Object) => {
        this.showToast(`系统无法打开该类型文件: ${JSON.stringify(err)}`);
      });
    } catch (e) {
      this.showToast(`调用系统打开失败: ${e}`);
    }
  }

  /**
   * 从系统相册选择真实图片并上传 (严格检测真实媒体类型)
   */
  private async pickPhotoAndUpload() {
    const cur = this.connVm.getCurrentConnection();
    if (!cur) {
      this.showToast('请先连接服务器');
      return;
    }

    try {
      const photoPicker = new picker.PhotoViewPicker();
      const result = await photoPicker.select({
        MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });

      if (!result || !result.photoUris || result.photoUris.length === 0) {
        return;
      }

      const selectedUri = result.photoUris[0];
      const filename = sanitizeFilename(selectedUri.split('/').pop() || 'photo.jpg');
      const mime = getMimeType(filename);

      this.isUploadingAttachment = true;
      this.attachmentStatusText = `正在读取并上传 ${filename}...`;

      const file = fs.openSync(selectedUri, fs.OpenMode.READ_ONLY);
      let buf: ArrayBuffer;
      try {
        const stat = fs.statSync(file.fd);
        buf = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buf);
      } finally {
        fs.closeSync(file.fd);
      }

      const base64Helper = new util.Base64Helper();
      const b64 = base64Helper.encodeToStringSync(new Uint8Array(buf));
      const dataUrl = `data:${mime};base64,${b64}`;

      const profile = cur.activeProfile ? cur.activeProfile : 'default';
      const uploadResult = await HermesFileClient.uploadImage(
        cur.url,
        profile,
        filename,
        dataUrl,
        cur.token,
        cur.cookies
      );

      const targetPath = uploadResult.path || uploadResult.url || filename;
      const refTag = `![${filename}](${targetPath})\n`;
      this.inputText = this.inputText ? `${this.inputText}\n${refTag}` : refTag;

      this.showToast(`图片已上传: ${filename}`);
      this.showAttachmentDialog = false;
    } catch (e) {
      this.showToast(`选择/上传图片失败: ${e}`);
      this.attachmentStatusText = `上传失败: ${e}`;
    } finally {
      this.isUploadingAttachment = false;
    }
  }

  /**
   * 从系统文件管理器选择文档并上传
   * - 普通文档/代码/PDF/音频等按上游规范走 Gateway RPC file.attach
   * - 图片类型则自动分流至 image-upload 路由
   */
  private async pickDocumentAndUpload() {
    const cur = this.connVm.getCurrentConnection();
    if (!cur) {
      this.showToast('请先连接服务器');
      return;
    }

    try {
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.select();
      if (!uris || uris.length === 0) {
        return;
      }

      const selectedUri = uris[0];
      const filename = sanitizeFilename(selectedUri.split('/').pop() || 'document.bin');
      const mime = getMimeType(filename);
      const isImg = isImageFile(filename);

      this.isUploadingAttachment = true;
      this.attachmentStatusText = `正在读取并上传 ${filename}...`;

      const file = fs.openSync(selectedUri, fs.OpenMode.READ_ONLY);
      let buf: ArrayBuffer;
      try {
        const stat = fs.statSync(file.fd);
        buf = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buf);
      } finally {
        fs.closeSync(file.fd);
      }

      const base64Helper = new util.Base64Helper();
      const b64 = base64Helper.encodeToStringSync(new Uint8Array(buf));
      const dataUrl = `data:${mime};base64,${b64}`;

      if (isImg) {
        // 图片走 image-upload 路由
        const profile = cur.activeProfile ? cur.activeProfile : 'default';
        const uploadResult = await HermesFileClient.uploadImage(
          cur.url,
          profile,
          filename,
          dataUrl,
          cur.token,
          cur.cookies
        );
        const targetPath = uploadResult.path || uploadResult.url || filename;
        const refTag = `![${filename}](${targetPath})\n`;
        this.inputText = this.inputText ? `${this.inputText}\n${refTag}` : refTag;
        this.showToast(`图片已上传: ${filename}`);
      } else {
        // 普通文档/代码/PDF等按上游规范走 Gateway RPC file.attach
        const attachName = generateAttachmentName(filename);
        await this.chatVm.attachDocument(attachName, dataUrl);
        const refTag = `[📎 附件: ${filename}](${attachName})\n`;
        this.inputText = this.inputText ? `${this.inputText}\n${refTag}` : refTag;
        this.showToast(`文档已附加到当前会话: ${filename}`);
      }

      this.showAttachmentDialog = false;
    } catch (e) {
      this.showToast(`选择/上传文件失败: ${e}`);
      this.attachmentStatusText = `上传失败: ${e}`;
    } finally {
      this.isUploadingAttachment = false;
    }
  }

  /**
   * 上传内置测试样例图 (供无图库或自动化测试环境便捷验证)
   */
  private async uploadSampleImage() {
    const cur = this.connVm.getCurrentConnection();
    if (!cur) {
      this.showToast('请先连接服务器');
      return;
    }

    this.isUploadingAttachment = true;
    this.attachmentStatusText = '正在上传测试图...';

    try {
      const filename = 'sample_1px.png';
      const dataUrl = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

      const profile = cur.activeProfile ? cur.activeProfile : 'default';
      const uploadResult = await HermesFileClient.uploadImage(
        cur.url,
        profile,
        filename,
        dataUrl,
        cur.token,
        cur.cookies
      );

      const targetPath = uploadResult.path || uploadResult.url || filename;
      const refTag = `![${filename}](${targetPath})\n`;
      this.inputText = this.inputText ? `${this.inputText}\n${refTag}` : refTag;

      this.showToast(`测试图片已上传并插入输入框`);
      this.showAttachmentDialog = false;
    } catch (e) {
      this.showToast(`上传测试图失败: ${e}`);
      this.attachmentStatusText = `上传失败: ${e}`;
    } finally {
      this.isUploadingAttachment = false;
    }
  }

  build() {
    Column() {
      // 1. 顶部导航与状态栏 (移动端自适应布局，杜绝标题挤压)
      Row() {
        Column() {
          Text(this.currentSessionTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Circle({ width: 7, height: 7 })
              .fill(this.isConnected ? '#34C759' : '#FF3B30')
              .margin({ right: 4 })
            Text(this.connectionStatusText)
              .fontSize(11)
              .fontColor('#8E8E93')
              .maxLines(1)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ right: 6 })

        Button(this.currentModel)
          .fontSize(11)
          .height(32)
          .backgroundColor('#F2F2F7')
          .fontColor('#007AFF')
          .margin({ right: 4 })
          .onClick(() => {
            this.showModelDialog = true;
          })

        Button('会话')
          .id('btn_sessions_list')
          .fontSize(11)
          .height(32)
          .backgroundColor('#E5E5EA')
          .fontColor('#000000')
          .margin({ right: 4 })
          .onClick(() => {
            this.refreshSessions();
            this.showSessionListDialog = true;
          })

        Button('功能')
          .fontSize(11)
          .height(32)
          .backgroundColor('#E5E5EA')
          .fontColor('#000000')
          .margin({ right: 4 })
          .onClick(async () => {
            const cur = this.connVm.getCurrentConnection();
            if (cur) {
              await this.loadCurrentToolsData();
            }
            this.showToolsDialog = true;
          })

        Button('分享')
          .fontSize(11)
          .height(32)
          .backgroundColor('#E5E5EA')
          .fontColor('#000000')
          .margin({ right: 4 })
          .onClick(async () => {
            await this.shareCurrentSession();
          })

        Button('设置')
          .id('btn_server_settings')
          .fontSize(11)
          .height(32)
          .backgroundColor('#007AFF')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.showServerDialog = true;
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor('#FFFFFF')
      .border({ width: { bottom: 1 }, color: '#E5E5EA' })

      // 2. 审批请求悬浮栏 (带加载与重试保护，精确契约 once/session/always/deny)
      if (this.hasApproval) {
        Column() {
          Row() {
            Column() {
              Text('需要授权执行操作')
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor('#D97706')
              Text(this.approvalDesc)
                .fontSize(12)
                .fontColor('#4B5563')
                .maxLines(2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Row() {
            Blank()
            if (this.approvalChoices.includes('deny')) {
              Button(this.isSubmittingApproval ? '提交中...' : '拒绝')
                .id('btn_approval_deny')
                .fontSize(12)
                .backgroundColor('#EF4444')
                .fontColor('#FFFFFF')
                .enabled(!this.isSubmittingApproval)
                .margin({ right: 6 })
                .onClick(() => {
                  this.chatVm.submitApproval('deny');
                })
            }
            if (this.approvalChoices.includes('session')) {
              Button(this.isSubmittingApproval ? '提交中...' : '本次会话')
                .id('btn_approval_session')
                .fontSize(12)
                .backgroundColor('#6366F1')
                .fontColor('#FFFFFF')
                .enabled(!this.isSubmittingApproval)
                .margin({ right: 6 })
                .onClick(() => {
                  this.chatVm.submitApproval('session');
                })
            }
            if (this.approvalChoices.includes('once')) {
              Button(this.isSubmittingApproval ? '提交中...' : '允许一次')
                .id('btn_approval_once')
                .fontSize(12)
                .backgroundColor('#10B981')
                .fontColor('#FFFFFF')
                .enabled(!this.isSubmittingApproval)
                .onClick(() => {
                  this.chatVm.submitApproval('once');
                })
            }
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .width('92%')
        .padding(12)
        .margin({ top: 8 })
        .backgroundColor('#FEF3C7')
        .borderRadius(8)
      }

      // 3. 澄清问题悬浮栏 (带加载与重试保护)
      if (this.hasClarify) {
        Column() {
          Text('Agent 正在等待您的澄清：')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1E40AF')
          Text(this.clarifyQuestion)
            .fontSize(13)
            .fontColor('#1F2937')
            .margin({ top: 4, bottom: 8 })

          Row() {
            ForEach(this.clarifyOptions, (opt: string) => {
              Button(opt)
                .fontSize(12)
                .backgroundColor('#DBEAFE')
                .fontColor('#1D4ED8')
                .enabled(!this.isSubmittingClarify)
                .margin({ right: 6 })
                .onClick(() => {
                  this.chatVm.submitClarify(opt);
                })
            })
          }
        }
        .width('92%')
        .padding(12)
        .margin({ top: 8 })
        .backgroundColor('#EFF6FF')
        .borderRadius(8)
      }

      // 4. 消息列表或空态引导视窗
      if (this.messages.length === 0) {
        Column() {
          if (!this.isConnected) {
            // 未连接服务器的首次引导与空态界面 (对齐 REVIEW_DEVICE_01.md)
            Column() {
              Text('Hermex')
                .fontSize(26)
                .fontWeight(FontWeight.Bold)
                .fontColor('#111827')
                .margin({ bottom: 6 })

              Text('自托管 Hermes Agent 原生鸿蒙客户端')
                .fontSize(13)
                .fontColor('#6B7280')
                .margin({ bottom: 18 })

              Column({ space: 12 }) {
                Row() {
                  Text('🌐').fontSize(18).margin({ right: 10 })
                  Column() {
                    Text('灵活连接').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#1F2937')
                    Text('局域网、Tailscale、Cloudflare 隧道或直连 IP/域名').fontSize(11).fontColor('#8E8E93')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%')

                Row() {
                  Text('🔒').fontSize(18).margin({ right: 10 })
                  Column() {
                    Text('硬件级凭据保护').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#1F2937')
                    Text('通过 AssetStoreKit 密文隔离存储 Token 与密码').fontSize(11).fontColor('#8E8E93')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%')

                Row() {
                  Text('⚡').fontSize(18).margin({ right: 10 })
                  Column() {
                    Text('实时双向交互').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#1F2937')
                    Text('流式 Markdown、思考过程、工具调用与审批控制').fontSize(11).fontColor('#8E8E93')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%')
              }
              .width('100%')
              .padding(14)
              .backgroundColor('#F9FAFB')
              .borderRadius(12)
              .margin({ bottom: 20 })

              Button('立即配置 Hermes 服务器')
                .id('btn_configure_server')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .height(42)
                .width('100%')
                .backgroundColor('#007AFF')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.showServerDialog = true;
                })
            }
            .width('90%')
            .padding(18)
            .backgroundColor('#FFFFFF')
            .borderRadius(16)
            .shadow({ radius: 10, color: '#15000000' })
          } else {
            // 已连接但当前无消息
            Column() {
              Text('💬').fontSize(36).margin({ bottom: 10 })
              Text('会话已准备就绪')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor('#374151')
                .margin({ bottom: 4 })
              Text('在下方输入框发送提示词开始对话，或点击 📎 附加图片与文档')
                .fontSize(12)
                .fontColor('#8E8E93')
                .textAlign(TextAlign.Center)
            }
            .width('85%')
            .padding(20)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 12 }) {
          ForEach(this.messages, (msg: ChatMessage) => {
            ListItem() {
              Column() {
                // 角色标题
                Text(msg.role === 'user' ? '用户' : 'Hermes')
                  .fontSize(11)
                  .fontColor('#8E8E93')
                  .alignSelf(msg.role === 'user' ? ItemAlign.End : ItemAlign.Start)
                  .margin({ bottom: 2 })

                // 思考/推理过程折叠卡片
                if (msg.reasoning && msg.reasoning.length > 0) {
                  Column() {
                    Text('思考过程')
                      .fontSize(11)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#6B7280')
                    Text(msg.reasoning)
                      .fontSize(12)
                      .fontColor('#4B5563')
                      .margin({ top: 2 })
                  }
                  .width('100%')
                  .padding(8)
                  .margin({ bottom: 6 })
                  .backgroundColor('#F3F4F6')
                  .borderRadius(6)
                }

                // 工具调用状态卡片
                if (msg.toolCalls && msg.toolCalls.length > 0) {
                  ForEach(msg.toolCalls, (tool: ToolCallItem) => {
                    Row() {
                      Text(`工具: ${tool.name}`)
                        .fontSize(11)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#374151')
                      Blank()
                      Text(tool.status === 'running' ? '执行中...' : '已完成')
                        .fontSize(11)
                        .fontColor(tool.status === 'running' ? '#D97706' : '#10B981')
                    }
                    .width('100%')
                    .padding(6)
                    .margin({ bottom: 4 })
                    .backgroundColor('#E5E7EB')
                    .borderRadius(4)
                  }, (tool: ToolCallItem) => `${tool.id}_${tool.status}_${tool.name}`)
                }

                // 主文字气泡 (集成 MarkdownView)
                Column() {
                  if (msg.role === 'user') {
                    Text(msg.content)
                      .fontSize(15)
                      .fontColor('#FFFFFF')
                  } else {
                    MarkdownView({ content: msg.content || (msg.status === 'streaming' ? '思考与撰写中...' : '') })
                  }
                  if (msg.content && msg.content.includes('[🎤 语音')) {
                    Button(this.isPlayingAudio && this.currentlyPlayingAudioUrl.length > 0 ? '⏹ 停止播放' : '▶ 播放语音')
                      .fontSize(11)
                      .height(26)
                      .backgroundColor('#E0F2FE')
                      .fontColor('#0284C7')
                      .margin({ top: 6 })
                      .onClick(async () => {
                        await this.handlePlayVoiceMessage(msg.content);
                      })
                  }
                }
                .padding(12)
                .backgroundColor(msg.role === 'user' ? '#007AFF' : '#F2F2F7')
                .borderRadius(12)
                .alignSelf(msg.role === 'user' ? ItemAlign.End : ItemAlign.Start)
              }
              .width('100%')
              .alignItems(msg.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
            }
          }, (msg: ChatMessage) => `${msg.id}_${msg.status}_${msg.content}_${msg.reasoning || ''}_${(msg.toolCalls || []).map((t: ToolCallItem) => `${t.id}:${t.status}`).join(';')}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      }

      // 5. 底部输入栏与控制 (支持原生附件与语音录制)
      Row() {
        Button('📎')
          .fontSize(18)
          .height(40)
          .width(40)
          .backgroundColor('#F2F2F7')
          .margin({ right: 6 })
          .onClick(() => {
            this.showAttachmentDialog = true;
          })

        Button(this.isRecordingVoice ? '⏹' : '🎤')
          .fontSize(16)
          .height(40)
          .width(40)
          .backgroundColor(this.isRecordingVoice ? '#FF3B30' : '#F2F2F7')
          .fontColor(this.isRecordingVoice ? '#FFFFFF' : '#000000')
          .margin({ right: 6 })
          .onClick(async () => {
            await this.toggleVoiceRecording();
          })

        TextInput({ text: $$this.inputText, placeholder: '发送消息给 Hermes...' })
          .id('input_chat_message')
          .layoutWeight(1)
          .height(40)
          .margin({ right: 8 })
          .onChange((val: string) => {
            hilog.info(DOMAIN, TAG, 'input_chat_message onChange: %{public}s', val);
            this.inputText = val;
          })

        if (this.isGenerating) {
          // 停止按钮
          Button('停止')
            .id('btn_stop_generating')
            .fontSize(13)
            .height(40)
            .backgroundColor('#FF3B30')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.chatVm.stopGenerating();
            })
        } else {
          // 发送按钮
          Button('发送')
            .id('btn_send_message')
            .fontSize(13)
            .height(40)
            .backgroundColor('#007AFF')
            .fontColor('#FFFFFF')
            .onClick(() => {
              hilog.info(DOMAIN, TAG, 'Send button clicked, inputText=%{public}s', this.inputText);
              if (this.inputText.trim().length > 0) {
                const text = this.inputText;
                this.inputText = '';
                this.chatVm.sendMessage(text);
              }
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 14 })
      .backgroundColor('#FFFFFF')
      .border({ width: { top: 1 }, color: '#E5E5EA' })

      // 6. 服务器配置弹窗
      if (this.showServerDialog) {
        Column() {
          Text('Hermes 连接设置')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 16 })

          TextInput({ text: $$this.serverUrl, placeholder: '服务器地址 (例如 https://hermes.domain.com 或 http://192.168.1.100:8787)' })
            .id('input_server_url')
            .height(40)
            .margin({ bottom: 4 })
            .onChange((val: string) => {
              hilog.info(DOMAIN, TAG, 'input_server_url onChange: %{public}s', val);
              this.serverUrl = val;
            })

          Text('说明：在真机上 127.0.0.1 指向手机自身，无法直连电脑；请填写电脑的局域网 IP 或外网 HTTPS 域名。')
            .fontSize(11)
            .fontColor('#6B7280')
            .margin({ bottom: 10 })

          TextInput({ text: $$this.usernameInput, placeholder: '用户名 (可选)' })
            .id('input_username')
            .height(40)
            .margin({ bottom: 10 })
            .onChange((val: string) => {
              hilog.info(DOMAIN, TAG, 'input_username onChange: %{public}s', val);
              this.usernameInput = val;
            })

          TextInput({ text: $$this.passwordInput, placeholder: '密码 (可选)' })
            .id('input_password')
            .type(InputType.Password)
            .height(40)
            .margin({ bottom: 12 })
            .onChange((val: string) => {
              hilog.info(DOMAIN, TAG, 'input_password onChange: %{public}s', val ? '***' : '');
              this.passwordInput = val;
            })

          if (this.statusProbeText.length > 0) {
            Text(this.statusProbeText)
              .fontSize(12)
              .fontColor('#4B5563')
              .margin({ bottom: 12 })
          }

          Row() {
            Button('探测状态')
              .id('btn_probe_status')
              .fontSize(13)
              .backgroundColor('#F2F2F7')
              .fontColor('#007AFF')
              .margin({ right: 10 })
              .onClick(() => {
                this.probeServer();
              })

            Button('连接并保存')
              .id('btn_connect_save')
              .fontSize(13)
              .backgroundColor('#007AFF')
              .fontColor('#FFFFFF')
              .margin({ right: 10 })
              .onClick(() => {
                this.connectAndStart();
              })

            Button('取消')
              .id('btn_cancel_server')
              .fontSize(13)
              .backgroundColor('#E5E5EA')
              .fontColor('#374151')
              .onClick(() => {
                this.showServerDialog = false;
              })
          }
        }
        .width('90%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
        .shadow({ radius: 20, color: '#40000000' })
        .position({ x: '5%', y: '15%' })
      }

      // 7. 会话历史列表弹窗
      if (this.showSessionListDialog) {
        Column() {
          Row() {
            Text('会话历史')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Blank()
            Button('+ 新建会话')
              .id('btn_new_session')
              .fontSize(12)
              .backgroundColor('#007AFF')
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.createNewSession();
              })
          }
          .width('100%')
          .margin({ bottom: 12 })

          List({ space: 8 }) {
            ForEach(this.sessions, (s: HermesSession) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(s.title || '会话')
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                    Text(`Profile: ${s.profile || 'default'} | ID: ${s.id}`)
                      .fontSize(11)
                      .fontColor('#8E8E93')
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Button('进入')
                    .fontSize(12)
                    .backgroundColor('#E5E5EA')
                    .fontColor('#007AFF')
                    .onClick(() => {
                      this.switchSession(s);
                    })
                }
                .width('100%')
                .padding(10)
                .backgroundColor('#F9FAFB')
                .borderRadius(8)
              }
            })
          }
          .height(300)
          .width('100%')

          Button('关闭')
            .fontSize(13)
            .backgroundColor('#E5E5EA')
            .fontColor('#374151')
            .margin({ top: 12 })
            .onClick(() => {
              this.showSessionListDialog = false;
            })
        }
        .width('90%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
        .shadow({ radius: 20, color: '#40000000' })
        .position({ x: '5%', y: '15%' })
      }

      // 8. 模型选择列表弹窗
      if (this.showModelDialog) {
        Column() {
          Text('选择会话模型')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 12 })

          List({ space: 8 }) {
            ForEach(this.availableModels, (m: ModelOption) => {
              ListItem() {
                Row() {
                  Text(m.name)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                  Blank()
                  Button('应用')
                    .fontSize(12)
                    .backgroundColor('#007AFF')
                    .fontColor('#FFFFFF')
                    .onClick(async () => {
                      this.showModelDialog = false;
                      await this.chatVm.switchModel(m.name);
                    })
                }
                .width('100%')
                .padding(10)
                .backgroundColor('#F9FAFB')
                .borderRadius(8)
              }
            })
          }
          .height(240)
          .width('100%')

          Button('关闭')
            .fontSize(13)
            .backgroundColor('#E5E5EA')
            .fontColor('#374151')
            .margin({ top: 12 })
            .onClick(() => {
              this.showModelDialog = false;
            })
        }
        .width('85%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
        .shadow({ radius: 20, color: '#40000000' })
        .position({ x: '7.5%', y: '20%' })
      }

      // 9. 工作区文件浏览与下载弹窗
      if (this.showWorkspaceDialog) {
        Column() {
          Row() {
            Column() {
              Text('工作区文件浏览器')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
              Text(`当前路径: /workspace${this.workspacePath ? '/' + this.workspacePath : ''}`)
                .fontSize(11)
                .fontColor('#6B7280')
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button('刷新')
              .fontSize(12)
              .backgroundColor('#F2F2F7')
              .fontColor('#007AFF')
              .margin({ right: 6 })
              .onClick(async () => {
                const cur = this.connVm.getCurrentConnection();
                if (cur) {
                  await this.workspaceVm.loadDirectory(cur, this.workspacePath);
                }
              })

            Button('关闭')
              .fontSize(12)
              .backgroundColor('#E5E5EA')
              .fontColor('#374151')
              .onClick(() => {
                this.showWorkspaceDialog = false;
                this.workspaceVm.closeFileView();
              })
          }
          .width('100%')
          .margin({ bottom: 10 })

          if (this.workspacePath.length > 0) {
            Button('⬆️ 返回上一级目录')
              .fontSize(12)
              .backgroundColor('#E0E7FF')
              .fontColor('#3730A3')
              .width('100%')
              .margin({ bottom: 8 })
              .onClick(async () => {
                const cur = this.connVm.getCurrentConnection();
                if (cur) {
                  await this.workspaceVm.navigateUp(cur);
                }
              })
          }

          if (this.isWorkspaceLoading) {
            Text('正在加载工作区...')
              .fontSize(13)
              .fontColor('#6B7280')
              .margin({ top: 20, bottom: 20 })
          } else if (this.workspaceError.length > 0) {
            Text(`错误: ${this.workspaceError}`)
              .fontSize(12)
              .fontColor('#EF4444')
              .margin({ top: 10, bottom: 10 })
          } else if (this.isViewingFile) {
            // 查看文件文本内容
            Column() {
              Row() {
                Text(`预览: ${this.viewingFileName}`)
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .layoutWeight(1)
                Button('返回列表')
                  .fontSize(12)
                  .backgroundColor('#E5E5EA')
                  .fontColor('#007AFF')
                  .onClick(() => {
                    this.workspaceVm.closeFileView();
                  })
              }
              .width('100%')
              .margin({ bottom: 8 })

              Scroll() {
                Text(this.viewingFileText)
                  .fontSize(12)
                  .fontFamily('monospace')
                  .fontColor('#111827')
              }
              .height(220)
              .width('100%')
              .padding(8)
              .backgroundColor('#F9FAFB')
              .borderRadius(6)
            }
            .width('100%')
          } else {
            if (this.lastDownloadedFileName.length > 0) {
              Row() {
                Text(`已下载: ${this.lastDownloadedFileName}`)
                  .fontSize(11)
                  .fontColor('#059669')
                  .layoutWeight(1)
                  .maxLines(1)
                Button('系统打开/分享')
                  .fontSize(11)
                  .height(26)
                  .backgroundColor('#10B981')
                  .fontColor('#FFFFFF')
                  .onClick(() => {
                    this.openOrShareFile(this.lastDownloadedFilePath, this.lastDownloadedFileName);
                  })
              }
              .width('100%')
              .padding(6)
              .margin({ bottom: 6 })
              .backgroundColor('#ECFDF5')
              .borderRadius(6)
            }

            // 文件与目录列表
            List({ space: 6 }) {
              ForEach(this.workspaceEntries, (entry: WorkspaceFileEntry) => {
                ListItem() {
                  Row() {
                    Text(entry.isDirectory ? '📁 ' : '📄 ')
                      .fontSize(14)
                    Column() {
                      Text(entry.name)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                      if (entry.size !== undefined) {
                        Text(`${entry.size} 字节`)
                          .fontSize(10)
                          .fontColor('#9CA3AF')
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    if (entry.isDirectory) {
                      Button('进入')
                        .fontSize(12)
                        .backgroundColor('#E5E5EA')
                        .fontColor('#007AFF')
                        .onClick(async () => {
                          const cur = this.connVm.getCurrentConnection();
                          if (cur) {
                            await this.workspaceVm.enterDirectory(cur, entry);
                          }
                        })
                    } else {
                      Row() {
                        Button('预览')
                          .fontSize(11)
                          .backgroundColor('#F2F2F7')
                          .fontColor('#007AFF')
                          .margin({ right: 4 })
                          .onClick(async () => {
                            const cur = this.connVm.getCurrentConnection();
                            if (cur) {
                              await this.workspaceVm.viewFile(cur, entry);
                            }
                          })

                        Button('下载')
                          .fontSize(11)
                          .backgroundColor('#E0E7FF')
                          .fontColor('#4338CA')
                          .onClick(async () => {
                            await this.handleDownloadFile(entry);
                          })
                      }
                    }
                  }
                  .width('100%')
                  .padding(8)
                  .backgroundColor('#F9FAFB')
                  .borderRadius(6)
                }
              })
            }
            .height(260)
            .width('100%')
          }
        }
        .width('90%')
        .padding(16)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
        .shadow({ radius: 20, color: '#40000000' })
        .position({ x: '5%', y: '12%' })
      }

      // 10. 原生附件选择与上传弹窗 (真正使用系统相册与文件管理器)
      if (this.showAttachmentDialog) {
        Column() {
          Row() {
            Text('添加附件')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Blank()
            Button('关闭')
              .fontSize(12)
              .backgroundColor('#E5E5EA')
              .fontColor('#374151')
              .onClick(() => {
                this.showAttachmentDialog = false;
              })
          }
          .width('100%')
          .margin({ bottom: 14 })

          if (this.attachmentStatusText.length > 0) {
            Text(this.attachmentStatusText)
              .fontSize(12)
              .fontColor(this.isUploadingAttachment ? '#2563EB' : '#4B5563')
              .margin({ bottom: 12 })
          }

          Column({ space: 10 }) {
            Button('📷 从系统相册选择图片')
              .fontSize(14)
              .width('100%')
              .height(44)
              .backgroundColor('#007AFF')
              .fontColor('#FFFFFF')
              .enabled(!this.isUploadingAttachment)
              .onClick(async () => {
                await this.pickPhotoAndUpload();
              })

            Button('📄 从文件管理器选择文档')
              .fontSize(14)
              .width('100%')
              .height(44)
              .backgroundColor('#F2F2F7')
              .fontColor('#007AFF')
              .enabled(!this.isUploadingAttachment)
              .onClick(async () => {
                await this.pickDocumentAndUpload();
              })

            Button('🧪 上传测试样例图片 (1px PNG)')
              .fontSize(13)
              .width('100%')
              .height(40)
              .backgroundColor('#E5E7EB')
              .fontColor('#374151')
              .enabled(!this.isUploadingAttachment)
              .onClick(async () => {
                await this.uploadSampleImage();
              })
          }
          .width('100%')
        }
        .width('85%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
        .shadow({ radius: 20, color: '#40000000' })
        .position({ x: '7.5%', y: '25%' })
      }

      // 11. 更多功能弹窗 (任务、技能、设定与记忆、用量、Git与工作区)
      if (this.showToolsDialog) {
        Column() {
          Row() {
            Text('扩展功能与运维')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Blank()
            Button('关闭')
              .fontSize(12)
              .backgroundColor('#E5E5EA')
              .fontColor('#374151')
              .onClick(() => {
                this.showToolsDialog = false;
              })
          }
          .width('100%')
          .margin({ bottom: 12 })

          // 选项卡切换
          Row() {
            Button('任务')
              .fontSize(11)
              .height(30)
              .backgroundColor(this.selectedToolsTab === 0 ? '#007AFF' : '#F2F2F7')
              .fontColor(this.selectedToolsTab === 0 ? '#FFFFFF' : '#374151')
              .margin({ right: 4 })
              .onClick(async () => {
                this.selectedToolsTab = 0;
                await this.loadCurrentToolsData();
              })

            Button('技能')
              .fontSize(11)
              .height(30)
              .backgroundColor(this.selectedToolsTab === 1 ? '#007AFF' : '#F2F2F7')
              .fontColor(this.selectedToolsTab === 1 ? '#FFFFFF' : '#374151')
              .margin({ right: 4 })
              .onClick(async () => {
                this.selectedToolsTab = 1;
                await this.loadCurrentToolsData();
              })

            Button('设定')
              .fontSize(11)
              .height(30)
              .backgroundColor(this.selectedToolsTab === 2 ? '#007AFF' : '#F2F2F7')
              .fontColor(this.selectedToolsTab === 2 ? '#FFFFFF' : '#374151')
              .margin({ right: 4 })
              .onClick(async () => {
                this.selectedToolsTab = 2;
                await this.loadCurrentToolsData();
              })

            Button('用量')
              .fontSize(11)
              .height(30)
              .backgroundColor(this.selectedToolsTab === 3 ? '#007AFF' : '#F2F2F7')
              .fontColor(this.selectedToolsTab === 3 ? '#FFFFFF' : '#374151')
              .margin({ right: 4 })
              .onClick(async () => {
                this.selectedToolsTab = 3;
                await this.loadCurrentToolsData();
              })

            Button('Git')
              .fontSize(11)
              .height(30)
              .backgroundColor(this.selectedToolsTab === 4 ? '#007AFF' : '#F2F2F7')
              .fontColor(this.selectedToolsTab === 4 ? '#FFFFFF' : '#374151')
              .margin({ right: 4 })
              .onClick(async () => {
                this.selectedToolsTab = 4;
                await this.loadCurrentToolsData();
              })

            Button('看板')
              .fontSize(11)
              .height(30)
              .backgroundColor(this.selectedToolsTab === 5 ? '#007AFF' : '#F2F2F7')
              .fontColor(this.selectedToolsTab === 5 ? '#FFFFFF' : '#374151')
              .onClick(async () => {
                this.selectedToolsTab = 5;
                await this.loadCurrentToolsData();
              })
          }
          .width('100%')
          .margin({ bottom: 10 })

          if (this.isToolsLoading) {
            Text(this.toolsStatusText || '正在加载数据...')
              .fontSize(12)
              .fontColor('#6B7280')
              .margin({ top: 20, bottom: 20 })
          } else {
            // Tab 0: 定时任务 (F08)
            if (this.selectedToolsTab === 0) {
              Column() {
                Row() {
                  Text(`定时任务列表 (${this.cronVm.jobs.length})`)
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .layoutWeight(1)
                  Button('刷新')
                    .fontSize(11)
                    .height(26)
                    .backgroundColor('#E5E5EA')
                    .fontColor('#007AFF')
                    .onClick(async () => {
                      const cur = this.connVm.getCurrentConnection();
                      if (cur) await this.cronVm.loadJobs(cur);
                    })
                }
                .width('100%')
                .margin({ bottom: 8 })

                if (this.cronVm.jobs.length === 0) {
                  Text('暂无配置的定时任务')
                    .fontSize(12)
                    .fontColor('#9CA3AF')
                    .margin({ top: 20 })
                } else {
                  List({ space: 6 }) {
                    ForEach(this.cronVm.jobs, (job: CronJobItem) => {
                      ListItem() {
                        Row() {
                          Column() {
                            Text(job.name)
                              .fontSize(13)
                              .fontWeight(FontWeight.Medium)
                            Text(`表达式: ${job.schedule || '无'} | 状态: ${job.enabled ? '运行中' : '已暂停'}`)
                              .fontSize(10)
                              .fontColor('#8E8E93')
                              .margin({ top: 2 })
                          }
                          .alignItems(HorizontalAlign.Start)
                          .layoutWeight(1)

                          Button('运行')
                            .fontSize(11)
                            .height(26)
                            .backgroundColor('#E0E7FF')
                            .fontColor('#4338CA')
                            .margin({ right: 4 })
                            .onClick(async () => {
                              const cur = this.connVm.getCurrentConnection();
                              if (cur) {
                                await this.cronVm.runJob(cur, job.id);
                                this.showToast(this.cronVm.statusMessage);
                              }
                            })

                          Button(job.enabled ? '暂停' : '恢复')
                            .fontSize(11)
                            .height(26)
                            .backgroundColor(job.enabled ? '#FEE2E2' : '#DCFCE7')
                            .fontColor(job.enabled ? '#B91C1C' : '#15803D')
                            .onClick(async () => {
                              const cur = this.connVm.getCurrentConnection();
                              if (cur) {
                                await this.cronVm.toggleJob(cur, job);
                              }
                            })
                        }
                        .width('100%')
                        .padding(8)
                        .backgroundColor('#F9FAFB')
                        .borderRadius(6)
                      }
                    })
                  }
                  .height(220)
                  .width('100%')
                }
              }
              .width('100%')
            }

            // Tab 1: 技能扩展 (F09)
            if (this.selectedToolsTab === 1) {
              Column() {
                Row() {
                  Text(`已安装技能 (${this.skillsVm.skills.length})`)
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .layoutWeight(1)
                  Button('刷新')
                    .fontSize(11)
                    .height(26)
                    .backgroundColor('#E5E5EA')
                    .fontColor('#007AFF')
                    .onClick(async () => {
                      const cur = this.connVm.getCurrentConnection();
                      if (cur) await this.skillsVm.loadSkillsAndMemory(cur);
                    })
                }
                .width('100%')
                .margin({ bottom: 8 })

                if (this.skillsVm.skills.length === 0) {
                  Text('当前 Profile 暂无可用技能')
                    .fontSize(12)
                    .fontColor('#9CA3AF')
                    .margin({ top: 20 })
                } else {
                  List({ space: 6 }) {
                    ForEach(this.skillsVm.skills, (s: SkillSummary) => {
                      ListItem() {
                        Row() {
                          Column() {
                            Text(s.name)
                              .fontSize(13)
                              .fontWeight(FontWeight.Medium)
                            if (s.description) {
                              Text(s.description)
                                .fontSize(10)
                                .fontColor('#8E8E93')
                                .maxLines(1)
                                .margin({ top: 2 })
                            }
                          }
                          .alignItems(HorizontalAlign.Start)
                          .layoutWeight(1)

                          Button(s.enabled ? '已启用' : '已禁用')
                            .fontSize(11)
                            .height(26)
                            .backgroundColor(s.enabled ? '#DCFCE7' : '#F3F4F6')
                            .fontColor(s.enabled ? '#15803D' : '#6B7280')
                            .onClick(async () => {
                              const cur = this.connVm.getCurrentConnection();
                              if (cur) {
                                await this.skillsVm.toggleSkill(cur, s);
                              }
                            })
                        }
                        .width('100%')
                        .padding(8)
                        .backgroundColor('#F9FAFB')
                        .borderRadius(6)
                      }
                    })
                  }
                  .height(220)
                  .width('100%')
                }
              }
              .width('100%')
            }

            // Tab 2: 设定与记忆档案 (F09)
            if (this.selectedToolsTab === 2) {
              Column() {
                Text('Profile 设定 (Soul)')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .alignSelf(ItemAlign.Start)
                  .margin({ bottom: 4 })

                TextArea({ text: this.editingSoulText })
                  .height(90)
                  .width('100%')
                  .fontSize(11)
                  .fontFamily('monospace')
                  .margin({ bottom: 6 })
                  .onChange((val: string) => {
                    this.editingSoulText = val;
                  })

                Button('保存设定修改')
                  .fontSize(11)
                  .height(28)
                  .backgroundColor('#007AFF')
                  .fontColor('#FFFFFF')
                  .margin({ bottom: 10 })
                  .onClick(async () => {
                    const cur = this.connVm.getCurrentConnection();
                    if (cur) {
                      const ok = await this.skillsVm.saveSoul(cur, this.editingSoulText);
                      this.showToast(ok ? '设定已更新' : '更新失败');
                    }
                  })

                Text('长期记忆内容 (memories/MEMORY.md)')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .alignSelf(ItemAlign.Start)
                  .margin({ bottom: 4 })

                Scroll() {
                  Text(this.skillsVm.memoryText || '(暂无长期记忆条目)')
                    .fontSize(11)
                    .fontColor('#4B5563')
                    .fontFamily('monospace')
                }
                .height(90)
                .width('100%')
                .padding(6)
                .backgroundColor('#F9FAFB')
                .borderRadius(6)
              }
              .width('100%')
            }

            // Tab 3: 用量分析统计 (F09/F12)
            if (this.selectedToolsTab === 3) {
              Column() {
                Row() {
                  Text('近期用量汇总 (最近 7 天)')
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .layoutWeight(1)
                  Button('刷新')
                    .fontSize(11)
                    .height(26)
                    .backgroundColor('#E5E5EA')
                    .fontColor('#007AFF')
                    .onClick(async () => {
                      const cur = this.connVm.getCurrentConnection();
                      if (cur) await this.insightsVm.loadInsights(cur, 7);
                    })
                }
                .width('100%')
                .margin({ bottom: 8 })

                Row() {
                  Column() {
                    Text('总调用')
                      .fontSize(10)
                      .fontColor('#8E8E93')
                    Text(String(this.insightsVm.usage ? this.insightsVm.usage.totalApiCalls : 0))
                      .fontSize(16)
                      .fontWeight(FontWeight.Bold)
                  }.layoutWeight(1)

                  Column() {
                    Text('总 Tokens')
                      .fontSize(10)
                      .fontColor('#8E8E93')
                    Text(String(this.insightsVm.usage ? (this.insightsVm.usage.totalInputTokens + this.insightsVm.usage.totalOutputTokens) : 0))
                      .fontSize(16)
                      .fontWeight(FontWeight.Bold)
                  }.layoutWeight(1)

                  Column() {
                    Text('输入/输出')
                      .fontSize(10)
                      .fontColor('#8E8E93')
                    Text(`${this.insightsVm.usage ? this.insightsVm.usage.totalInputTokens : 0} / ${this.insightsVm.usage ? this.insightsVm.usage.totalOutputTokens : 0}`)
                      .fontSize(11)
                      .fontColor('#4B5563')
                  }.layoutWeight(1)
                }
                .width('100%')
                .padding(10)
                .backgroundColor('#EFF6FF')
                .borderRadius(8)
                .margin({ bottom: 10 })

                Text('模型消耗明细')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .alignSelf(ItemAlign.Start)
                  .margin({ bottom: 4 })

                if (this.insightsVm.modelStats.length === 0) {
                  Text('暂无模型明细记录')
                    .fontSize(11)
                    .fontColor('#9CA3AF')
                    .margin({ top: 10 })
                } else {
                  List({ space: 4 }) {
                    ForEach(this.insightsVm.modelStats, (item: ModelUsageItem) => {
                      ListItem() {
                        Row() {
                          Text(item.model)
                            .fontSize(11)
                            .fontWeight(FontWeight.Medium)
                            .layoutWeight(1)
                          Text(`${item.inputTokens + item.outputTokens} tokens`)
                            .fontSize(11)
                            .fontColor('#6B7280')
                        }
                        .width('100%')
                        .padding(6)
                        .backgroundColor('#F9FAFB')
                        .borderRadius(4)
                      }
                    })
                  }
                  .height(130)
                  .width('100%')
                }
              }
              .width('100%')
            }

            // Tab 4: 项目与 Git (F06)
            if (this.selectedToolsTab === 4) {
              Column() {
                Row() {
                  Text('项目与 Git 仓库管理')
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .layoutWeight(1)
                  Button('刷新')
                    .fontSize(11)
                    .height(26)
                    .backgroundColor('#E5E5EA')
                    .fontColor('#007AFF')
                    .onClick(async () => {
                      const cur = this.connVm.getCurrentConnection();
                      if (cur) await this.gitVm.loadProjectsAndGit(cur, this.workspacePath);
                    })
                }
                .width('100%')
                .margin({ bottom: 8 })

                if (this.gitVm.gitStatus) {
                  Row() {
                    Column() {
                      Text(`当前分支: ${this.gitVm.gitStatus.branch}`)
                        .fontSize(13)
                        .fontWeight(FontWeight.Bold)
                      Text(`改动文件: ${this.gitVm.gitStatus.changed} | 未跟踪: ${this.gitVm.gitStatus.untracked}`)
                        .fontSize(11)
                        .fontColor('#6B7280')
                        .margin({ top: 2 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                  }
                  .width('100%')
                  .padding(8)
                  .backgroundColor('#F0FDF4')
                  .borderRadius(8)
                  .margin({ bottom: 10 })

                  Text('切换分支')
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .alignSelf(ItemAlign.Start)
                    .margin({ bottom: 4 })

                  List({ space: 4 }) {
                    ForEach(this.gitVm.branches, (b: GitBranchInfo) => {
                      ListItem() {
                        Row() {
                          Text(b.name + (b.isCurrent ? ' (当前)' : ''))
                            .fontSize(12)
                            .fontColor(b.isCurrent ? '#16A34A' : '#1F2937')
                            .layoutWeight(1)

                          if (!b.isCurrent) {
                            Button('切至该分支')
                              .fontSize(11)
                              .height(24)
                              .backgroundColor('#E5E5EA')
                              .fontColor('#007AFF')
                              .onClick(async () => {
                                const cur = this.connVm.getCurrentConnection();
                                if (cur) {
                                  await this.gitVm.switchBranch(cur, b.name);
                                  this.showToast(this.gitVm.statusMessage);
                                }
                              })
                          }
                        }
                        .width('100%')
                        .padding(6)
                        .backgroundColor('#F9FAFB')
                        .borderRadius(4)
                      }
                    })
                  }
                  .height(130)
                  .width('100%')
                } else {
                  Column() {
                    Text('当前工作区未检测到 Git 仓库')
                      .fontSize(12)
                      .fontColor('#9CA3AF')
                      .margin({ top: 10, bottom: 10 })

                    Button('📂 打开工作区文件浏览器')
                      .fontSize(13)
                      .height(36)
                      .backgroundColor('#E0E7FF')
                      .fontColor('#3730A3')
                      .onClick(() => {
                        this.showToolsDialog = false;
                        this.showWorkspaceDialog = true;
                      })
                  }
                  .width('100%')
                }
              }
              .width('100%')
            }

            // Tab 5: 项目看板 (F11)
            if (this.selectedToolsTab === 5) {
              Column() {
                Row() {
                  Text(this.selectedKanbanName ? `看板: ${this.selectedKanbanName}` : '项目看板')
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .layoutWeight(1)

                  if (this.isKanbanReadOnly) {
                    Text('只读模式')
                      .fontSize(10)
                      .fontColor('#D97706')
                      .backgroundColor('#FEF3C7')
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(4)
                      .margin({ right: 6 })
                  }

                  Button('刷新')
                    .fontSize(11)
                    .height(26)
                    .backgroundColor('#E5E5EA')
                    .fontColor('#374151')
                    .onClick(async () => {
                      const cur = this.connVm.getCurrentConnection();
                      if (cur) {
                        await this.kanbanVm.loadBoards(cur);
                      }
                    })
                }
                .width('100%')
                .margin({ bottom: 8 })

                if (!this.kanbanVm.isAvailable) {
                  Column() {
                    Text(this.kanbanVm.statusMessage || '服务端未启用看板插件')
                      .fontSize(12)
                      .fontColor('#EF4444')
                      .margin({ top: 12, bottom: 4 })
                  }
                  .width('100%')
                  .padding(12)
                  .backgroundColor('#FEF2F2')
                  .borderRadius(8)
                } else if (this.kanbanBoards.length === 0) {
                  Text('当前服务端暂无可用看板')
                    .fontSize(12)
                    .fontColor('#6B7280')
                    .margin({ top: 12 })
                } else {
                  // 看板选择器
                  if (this.kanbanBoards.length > 1) {
                    Row() {
                      ForEach(this.kanbanBoards, (b: KanbanBoardItem) => {
                        Button(b.name)
                          .fontSize(10)
                          .height(24)
                          .backgroundColor(this.selectedKanbanSlug === b.slug ? '#007AFF' : '#E5E5EA')
                          .fontColor(this.selectedKanbanSlug === b.slug ? '#FFFFFF' : '#374151')
                          .margin({ right: 4 })
                          .onClick(async () => {
                            const cur = this.connVm.getCurrentConnection();
                            if (cur) {
                              await this.kanbanVm.loadBoardSnapshot(cur, b.slug);
                            }
                          })
                      })
                    }
                    .width('100%')
                    .margin({ bottom: 8 })
                  }

                  // 快速创建卡片 (只读模式下展示提示)
                  if (!this.isKanbanReadOnly) {
                    Row() {
                      TextInput({ placeholder: '输入新任务/卡片标题...', text: this.newCardTitleInput })
                        .height(30)
                        .fontSize(11)
                        .layoutWeight(1)
                        .margin({ right: 6 })
                        .onChange((val: string) => {
                          this.newCardTitleInput = val;
                        })

                      Button('新建卡片')
                        .fontSize(11)
                        .height(30)
                        .backgroundColor('#007AFF')
                        .fontColor('#FFFFFF')
                        .onClick(async () => {
                          const cur = this.connVm.getCurrentConnection();
                          const title = this.newCardTitleInput.trim();
                          if (cur && title) {
                            const ok = await this.kanbanVm.createCard(cur, title);
                            if (ok) {
                              this.newCardTitleInput = '';
                              this.showToast('卡片创建成功');
                            } else {
                              this.showToast(this.kanbanVm.statusMessage);
                            }
                          }
                        })
                    }
                    .width('100%')
                    .margin({ bottom: 8 })
                  } else {
                    Text('当前看板处于只读模式，不支持创建新卡片与流转')
                      .fontSize(11)
                      .fontColor('#9CA3AF')
                      .margin({ bottom: 8 })
                  }

                  // 看板泳道与卡片列表
                  if (this.kanbanSnapshot && this.kanbanSnapshot.columns.length > 0) {
                    List({ space: 8 }) {
                      ForEach(this.kanbanSnapshot.columns, (col: KanbanColumnItem) => {
                        ListItem() {
                          Column() {
                            Row() {
                              Text(`${col.name}`)
                                .fontSize(12)
                                .fontWeight(FontWeight.Bold)
                                .fontColor('#1F2937')
                              Blank()
                              Text(`${col.cards.length}`)
                                .fontSize(11)
                                .fontColor('#6B7280')
                                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                                .backgroundColor('#E5E7EB')
                                .borderRadius(10)
                            }
                            .width('100%')
                            .margin({ bottom: 6 })

                            if (col.cards.length === 0) {
                              Text('暂无卡片')
                                .fontSize(11)
                                .fontColor('#9CA3AF')
                                .margin({ top: 4, bottom: 4 })
                            } else {
                              ForEach(col.cards, (card: KanbanCardItem) => {
                                Column() {
                                  Row() {
                                    Text(card.title)
                                      .fontSize(12)
                                      .fontWeight(FontWeight.Medium)
                                      .layoutWeight(1)

                                    if (card.assignee) {
                                      Text(card.assignee)
                                        .fontSize(10)
                                        .fontColor('#4B5563')
                                        .backgroundColor('#E5E7EB')
                                        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                                        .borderRadius(4)
                                    }
                                  }
                                  .width('100%')

                                  if (card.description) {
                                    Text(card.description)
                                      .fontSize(10)
                                      .fontColor('#6B7280')
                                      .maxLines(2)
                                      .margin({ top: 2 })
                                  }

                                  Row() {
                                    Text(`ID: ${card.id}`)
                                      .fontSize(9)
                                      .fontColor('#9CA3AF')
                                      .layoutWeight(1)

                                    if (!this.isKanbanReadOnly) {
                                      Button('流转')
                                        .fontSize(10)
                                        .height(20)
                                        .backgroundColor('#E5E5EA')
                                        .fontColor('#007AFF')
                                        .onClick(async () => {
                                          const cur = this.connVm.getCurrentConnection();
                                          if (cur) {
                                            const nextStatus = col.name.toLowerCase().includes('done') ? 'todo' : 'done';
                                            await this.kanbanVm.updateCardStatus(cur, card.id, nextStatus);
                                          }
                                        })
                                    }
                                  }
                                  .width('100%')
                                  .margin({ top: 4 })
                                }
                                .width('100%')
                                .padding(6)
                                .backgroundColor('#FFFFFF')
                                .borderRadius(6)
                                .margin({ bottom: 4 })
                                .border({ width: 1, color: '#E5E7EB' })
                              })
                            }
                          }
                          .width('100%')
                          .padding(8)
                          .backgroundColor('#F3F4F6')
                          .borderRadius(8)
                        }
                      })
                    }
                    .height(240)
                    .width('100%')
                  } else {
                    Text('当前看板暂无泳道数据')
                      .fontSize(12)
                      .fontColor('#9CA3AF')
                      .margin({ top: 12 })
                  }
                }
              }
              .width('100%')
            }
          }
        }
        .width('92%')
        .padding(16)
        .backgroundColor('#FFFFFF')
        .borderRadius(16)
        .shadow({ radius: 20, color: '#40000000' })
        .position({ x: '4%', y: '10%' })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F2F7')
  }
}
