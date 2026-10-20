import { ConnectionViewModel } from '../viewmodel/ConnectionViewModel';
import { SessionListViewModel } from '../viewmodel/SessionListViewModel';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { BotConnection, HermesStatus } from '../model/Connection';
import { HermesSession } from '../model/Session';
import { ChatMessage, ToolCallItem } from '../model/ChatMessage';
import { ModelOption } from '../model/Approval';
import { MarkdownView } from '../components/MarkdownView';
import promptAction from '@ohos.promptAction';

@Entry
@Component
struct Index {
  @State serverUrl: string = '';
  @State usernameInput: string = '';
  @State passwordInput: string = '';
  @State statusProbeText: string = '';
  @State inputText: string = '';
  @State currentSessionTitle: string = '未选择会话';
  @State currentSessionId: string = '';
  @State showServerDialog: boolean = false;
  @State showSessionListDialog: boolean = false;
  @State showModelDialog: boolean = false;

  // ViewModels
  private connVm: ConnectionViewModel = new ConnectionViewModel();
  private sessionVm: SessionListViewModel = new SessionListViewModel();
  private chatVm: ChatViewModel = new ChatViewModel();

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
  @State isSubmittingApproval: boolean = false;
  @State hasClarify: boolean = false;
  @State clarifyQuestion: string = '';
  @State clarifyOptions: string[] = [];
  @State isSubmittingClarify: boolean = false;

  aboutToAppear() {
    this.chatVm.setListener({
      onStateChanged: () => {
        this.syncVmState();
      },
      onErrorToast: (msg: string) => {
        try {
          promptAction.showToast({ message: msg, duration: 3000 });
        } catch (e) {
          // ignore prompt error in headless test
        }
      }
    });
    this.initDefaultConnection();
  }

  aboutToDisappear() {
    this.chatVm.disconnect();
  }

  private syncVmState() {
    this.isConnected = this.chatVm.isConnected;
    this.connectionStatusText = this.chatVm.connectionStatusText;
    this.isGenerating = this.chatVm.isGenerating;
    this.currentModel = this.chatVm.currentModel;
    this.messages = [...this.chatVm.messages];
    this.availableModels = [...this.chatVm.availableModels];
    this.isSubmittingApproval = this.chatVm.isSubmittingApproval;
    this.isSubmittingClarify = this.chatVm.isSubmittingClarify;

    if (this.chatVm.currentApproval) {
      this.hasApproval = true;
      const app = this.chatVm.currentApproval;
      this.approvalDesc = `${app.toolName || '工具'}: ${app.command || app.description || '执行请求'}`;
    } else {
      this.hasApproval = false;
      this.approvalDesc = '';
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
      this.statusProbeText = '正在连接认证并核验 /api/auth/me ...';
      const conn = await this.connVm.loginAndSave('Hermes', this.serverUrl, this.usernameInput, this.passwordInput);
      this.showServerDialog = false;

      // 拉取会话列表
      this.sessions = await this.sessionVm.loadSessions(conn);
      if (this.sessions.length > 0) {
        // 自动接入最近的一个真实会话
        await this.switchSession(this.sessions[0]);
      } else {
        // 无会话时提示新建
        this.currentSessionTitle = '请新建会话';
        this.showSessionListDialog = true;
      }
    } catch (e) {
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

  private async createNewSession() {
    const cur = this.connVm.getCurrentConnection();
    if (!cur) return;
    try {
      // 必须通过 Gateway 真实调用 session.create，杜绝伪造本地 ID！
      if (!this.chatVm.isConnected) {
        // 若未连接先以临时标识建立握手再创建
        await this.chatVm.attachSession(cur, '');
      }
      const realSessionId = await this.chatVm.createAndAttachNewSession(cur);
      this.currentSessionId = realSessionId;
      this.currentSessionTitle = '新对话';
      this.showSessionListDialog = false;
      this.refreshSessions();
    } catch (e) {
      try {
        promptAction.showToast({ message: `创建会话失败: ${e}`, duration: 3000 });
      } catch (err) {}
    }
  }

  build() {
    Column() {
      // 1. 顶部导航与状态栏
      Row() {
        Column() {
          Text(this.currentSessionTitle)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Circle({ width: 8, height: 8 })
              .fill(this.isConnected ? '#34C759' : '#FF3B30')
              .margin({ right: 4 })
            Text(this.connectionStatusText)
              .fontSize(12)
              .fontColor('#8E8E93')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.currentModel)
          .fontSize(12)
          .backgroundColor('#F2F2F7')
          .fontColor('#007AFF')
          .margin({ right: 8 })
          .onClick(() => {
            this.showModelDialog = true;
          })

        Button('会话')
          .fontSize(12)
          .backgroundColor('#E5E5EA')
          .fontColor('#000000')
          .margin({ right: 6 })
          .onClick(() => {
            this.refreshSessions();
            this.showSessionListDialog = true;
          })

        Button('设置')
          .fontSize(12)
          .backgroundColor('#007AFF')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.showServerDialog = true;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#FFFFFF')
      .border({ width: { bottom: 1 }, color: '#E5E5EA' })

      // 2. 审批请求悬浮栏 (带加载与重试保护)
      if (this.hasApproval) {
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

          Button(this.isSubmittingApproval ? '提交中...' : '拒绝')
            .fontSize(12)
            .backgroundColor('#EF4444')
            .fontColor('#FFFFFF')
            .enabled(!this.isSubmittingApproval)
            .margin({ right: 8 })
            .onClick(() => {
              this.chatVm.submitApproval('reject');
            })

          Button(this.isSubmittingApproval ? '提交中...' : '批准')
            .fontSize(12)
            .backgroundColor('#10B981')
            .fontColor('#FFFFFF')
            .enabled(!this.isSubmittingApproval)
            .onClick(() => {
              this.chatVm.submitApproval('approve');
            })
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

      // 4. 消息列表主视窗
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
                })
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
              }
              .padding(12)
              .backgroundColor(msg.role === 'user' ? '#007AFF' : '#F2F2F7')
              .borderRadius(12)
              .alignSelf(msg.role === 'user' ? ItemAlign.End : ItemAlign.Start)
            }
            .width('100%')
            .alignItems(msg.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
          }
        }, (msg: ChatMessage) => msg.id)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      // 5. 底部输入栏与控制
      Row() {
        TextInput({ text: this.inputText, placeholder: '发送消息给 Hermes...' })
          .layoutWeight(1)
          .height(40)
          .margin({ right: 8 })
          .onChange((val: string) => {
            this.inputText = val;
          })

        if (this.isGenerating) {
          // 停止按钮
          Button('停止')
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
            .fontSize(13)
            .height(40)
            .backgroundColor('#007AFF')
            .fontColor('#FFFFFF')
            .onClick(() => {
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

          TextInput({ text: this.serverUrl, placeholder: '服务器地址 (例如 https://hermes.domain.com 或 http://192.168.1.100:8787)' })
            .height(40)
            .margin({ bottom: 4 })
            .onChange((val: string) => {
              this.serverUrl = val;
            })

          Text('说明：在真机上 127.0.0.1 指向手机自身，无法直连电脑；请填写电脑的局域网 IP 或外网 HTTPS 域名。')
            .fontSize(11)
            .fontColor('#6B7280')
            .margin({ bottom: 10 })

          TextInput({ text: this.usernameInput, placeholder: '用户名 (可选)' })
            .height(40)
            .margin({ bottom: 10 })
            .onChange((val: string) => {
              this.usernameInput = val;
            })

          TextInput({ text: this.passwordInput, placeholder: '密码 (可选)' })
            .type(InputType.Password)
            .height(40)
            .margin({ bottom: 12 })
            .onChange((val: string) => {
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
              .fontSize(13)
              .backgroundColor('#F2F2F7')
              .fontColor('#007AFF')
              .margin({ right: 10 })
              .onClick(() => {
                this.probeServer();
              })

            Button('连接并保存')
              .fontSize(13)
              .backgroundColor('#007AFF')
              .fontColor('#FFFFFF')
              .margin({ right: 10 })
              .onClick(() => {
                this.connectAndStart();
              })

            Button('取消')
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

      // 8. 模型选择列表弹窗 (真实触发 config.set)
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F2F7')
  }
}
