import common from '@ohos.app.ability.common';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'VoiceUtils';

export interface VoicePlaybackCallbacks {
  onStart?: () => void;
  onComplete?: () => void;
  onError?: (err: string) => void;
}

/**
 * 鸿蒙原生语音录音与播放平台适配层 (F10)
 * 严格基于 @ohos.multimedia.media (AVRecorder / AVPlayer) 实现真实音频落盘、编解码与事件状态机
 */
export class VoiceUtils {
  private static recordingState: boolean = false;
  private static playingState: boolean = false;
  private static currentRecordingPath: string = '';
  private static activeRecorder: media.AVRecorder | null = null;
  private static activeRecorderFd: number = -1;
  private static activePlayer: media.AVPlayer | null = null;
  private static activePlayerFd: number = -1;

  public static isRecording(): boolean {
    return VoiceUtils.recordingState;
  }

  public static isPlaying(): boolean {
    return VoiceUtils.playingState;
  }

  /**
   * 检查或申请麦克风权限
   */
  public static async checkMicrophonePermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const perm: Permissions = 'ohos.permission.MICROPHONE';
      const status = await atManager.checkAccessToken(context.applicationInfo.accessTokenId, perm);
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      const reqRes = await atManager.requestPermissionsFromUser(context, [perm]);
      return reqRes.authResults[0] === 0;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'checkMicrophonePermission warning: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /**
   * 启动原生语音录制
   * 使用 AVRecorder 配置 AAC 编码与 M4A 容器格式，绑定文件描述符 fd://
   */
  public static async startRecording(outputFilePath: string): Promise<boolean> {
    if (VoiceUtils.recordingState) {
      hilog.warn(0x0000, TAG, 'Recording already active');
      return false;
    }

    try {
      // 1. 打开或创建输出文件，获取文件描述符 fd
      const file = fs.openSync(outputFilePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      VoiceUtils.activeRecorderFd = file.fd;

      // 2. 创建真实 AVRecorder 实例
      const recorder = await media.createAVRecorder();
      VoiceUtils.activeRecorder = recorder;

      // 3. 配置音频参数 (对齐 iOS AAC/M4A 规范)
      const config: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_DEFAULT,
        profile: {
          audioBitrate: 96000,
          audioChannels: 1,
          audioCodec: media.CodecMimeType.AUDIO_AAC,
          audioSampleRate: 44100,
          fileFormat: media.ContainerFormatType.CFT_MPEG_4A
        },
        url: `fd://${file.fd}`
      };

      await recorder.prepare(config);
      await recorder.start();

      VoiceUtils.currentRecordingPath = outputFilePath;
      VoiceUtils.recordingState = true;
      hilog.info(0x0000, TAG, 'Real AVRecorder recording started to fd: %{public}d', file.fd);
      return true;
    } catch (err) {
      hilog.error(0x0000, TAG, 'startRecording failed: %{public}s', JSON.stringify(err));
      await VoiceUtils.cleanupRecorder();
      return false;
    }
  }

  /**
   * 停止语音录制并返回录音文件路径
   * 必须落盘且验证文件大小 > 0
   */
  public static async stopRecording(): Promise<string | null> {
    if (!VoiceUtils.recordingState) {
      return null;
    }

    const path = VoiceUtils.currentRecordingPath;
    try {
      if (VoiceUtils.activeRecorder) {
        await VoiceUtils.activeRecorder.stop();
        await VoiceUtils.activeRecorder.release();
        VoiceUtils.activeRecorder = null;
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'stopRecording recorder stop/release warning: %{public}s', JSON.stringify(e));
    } finally {
      if (VoiceUtils.activeRecorderFd >= 0) {
        try {
          fs.closeSync(VoiceUtils.activeRecorderFd);
        } catch (_e) {}
        VoiceUtils.activeRecorderFd = -1;
      }
      VoiceUtils.recordingState = false;
      VoiceUtils.currentRecordingPath = '';
    }

    // 验证实际录制文件大小
    try {
      const stat = fs.statSync(path);
      if (stat.size > 0) {
        hilog.info(0x0000, TAG, 'Real AVRecorder recording stopped successfully, size: %{public}d bytes', stat.size);
        return path;
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'Recorded file stat check failed: %{public}s', JSON.stringify(e));
    }
    return null;
  }

  /**
   * 取消录音并清理临时文件
   */
  public static async cancelRecording(): Promise<void> {
    const path = VoiceUtils.currentRecordingPath;
    await VoiceUtils.cleanupRecorder();
    if (path) {
      try {
        fs.unlinkSync(path);
      } catch (_e) {}
    }
  }

  private static async cleanupRecorder(): Promise<void> {
    if (VoiceUtils.activeRecorder) {
      try {
        await VoiceUtils.activeRecorder.stop();
      } catch (_e) {}
      try {
        await VoiceUtils.activeRecorder.release();
      } catch (_e) {}
      VoiceUtils.activeRecorder = null;
    }
    if (VoiceUtils.activeRecorderFd >= 0) {
      try {
        fs.closeSync(VoiceUtils.activeRecorderFd);
      } catch (_e) {}
      VoiceUtils.activeRecorderFd = -1;
    }
    VoiceUtils.recordingState = false;
    VoiceUtils.currentRecordingPath = '';
  }

  /**
   * 原生播放语音文件或音频链接
   * 使用 AVPlayer 驱动状态机 (initialized -> prepared -> playing -> completed)
   */
  public static async playAudio(audioPathOrUrl: string, callbacks?: VoicePlaybackCallbacks): Promise<boolean> {
    if (!audioPathOrUrl || audioPathOrUrl.trim().length === 0) {
      if (callbacks && callbacks.onError) callbacks.onError('Invalid audio path');
      return false;
    }

    // 先停止正在播放的实例
    await VoiceUtils.stopAudio();

    try {
      const player = await media.createAVPlayer();
      VoiceUtils.activePlayer = player;

      player.on('stateChange', async (state: media.AVPlayerState) => {
        if (state === 'initialized') {
          await player.prepare();
        } else if (state === 'prepared') {
          await player.play();
          VoiceUtils.playingState = true;
          if (callbacks && callbacks.onStart) {
            callbacks.onStart();
          }
        } else if (state === 'completed') {
          VoiceUtils.playingState = false;
          await VoiceUtils.stopAudio();
          if (callbacks && callbacks.onComplete) {
            callbacks.onComplete();
          }
        } else if (state === 'stopped' || state === 'released') {
          VoiceUtils.playingState = false;
        }
      });

      player.on('error', (err) => {
        hilog.error(0x0000, TAG, 'AVPlayer error event: %{public}s', JSON.stringify(err));
        VoiceUtils.stopAudio();
        if (callbacks && callbacks.onError) {
          callbacks.onError(err.message || 'AVPlayer playback error');
        }
      });

      if (audioPathOrUrl.startsWith('http://') || audioPathOrUrl.startsWith('https://')) {
        player.url = audioPathOrUrl;
      } else {
        const file = fs.openSync(audioPathOrUrl, fs.OpenMode.READ_ONLY);
        VoiceUtils.activePlayerFd = file.fd;
        const stat = fs.statSync(audioPathOrUrl);
        const fdSrc: media.AVFileDescriptor = {
          fd: file.fd,
          offset: 0,
          length: stat.size
        };
        player.fdSrc = fdSrc;
      }

      return true;
    } catch (err) {
      hilog.error(0x0000, TAG, 'playAudio failed: %{public}s', JSON.stringify(err));
      await VoiceUtils.stopAudio();
      if (callbacks && callbacks.onError) {
        callbacks.onError(String(err));
      }
      return false;
    }
  }

  /**
   * 停止当前音频播放并释放原生资源
   */
  public static async stopAudio(): Promise<void> {
    if (VoiceUtils.activePlayer) {
      try {
        await VoiceUtils.activePlayer.stop();
      } catch (_e) {}
      try {
        await VoiceUtils.activePlayer.release();
      } catch (_e) {}
      VoiceUtils.activePlayer = null;
    }
    if (VoiceUtils.activePlayerFd >= 0) {
      try {
        fs.closeSync(VoiceUtils.activePlayerFd);
      } catch (_e) {}
      VoiceUtils.activePlayerFd = -1;
    }
    VoiceUtils.playingState = false;
  }
}
