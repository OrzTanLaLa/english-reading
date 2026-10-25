/**
 * 麦克风录音：录成 48kHz / 双声道 / 16bit 的 WAV，直接喂给 Omni（它认 wav）。
 *
 * 为什么是 48k 不是 16k：本机 16k 采集会被 audio_server 拒绝（SetAudioStreamInfo failed，createAudioCapturer 返回 6800301），
 * 文档示例也用 48000。Omni 对 wav 采样率没有 16k 限制，所以按设备原生采样率录。
 *
 * 为什么用 `on('readData')` 而不是自己轮询 read()：
 *   API 11+ 推荐回调方式，音频线程按需推数据，不需要我们维护缓冲区与节流（和播放器那套是同一条经验）。
 *
 * 权限：ohos.permission.MICROPHONE（module.json5 已声明，运行时还要 requestPermissionsFromUser）。
 */
import { audio } from '@kit.AudioKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';

const SAMPLE_RATE: number = 48000;
const CHANNELS: number = 2;
const BITS: number = 16;

export class Recorder {
  private capturer: audio.AudioCapturer | undefined = undefined;
  private chunks: Uint8Array[] = [];
  private total: number = 0;
  private recording: boolean = false;
  /** 最近一次权限诊断，排查用 */
  lastPermDiag: string = '';

  isRecording(): boolean {
    return this.recording;
  }

  /** 已录时长（毫秒） */
  durationMs(): number {
    return Math.floor(this.total * 1000 / (SAMPLE_RATE * CHANNELS * BITS / 8));
  }

  /** 运行时申请麦克风权限；已授权则直接返回 true */
  async ensurePermission(ctx: common.UIAbilityContext): Promise<boolean> {
    const perms: Permissions[] = ['ohos.permission.MICROPHONE'];
    const mgr = abilityAccessCtrl.createAtManager();
    const res = await mgr.requestPermissionsFromUser(ctx, perms);
    return res.authResults.length > 0 && res.authResults[0] === 0;
  }
  async start(): Promise<void> {
    if (this.recording) {
      return;
    }
    this.chunks = [];
    this.total = 0;
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
      channels: audio.AudioChannel.CHANNEL_2,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };
    const cap: audio.AudioCapturer = await audio.createAudioCapturer(options);
    cap.on('readData', (buffer: ArrayBuffer) => {
      if (!this.recording) {
        return;
      }
      const copy: Uint8Array = new Uint8Array(buffer.slice(0));
      this.chunks.push(copy);
      this.total += copy.byteLength;
    });
    this.capturer = cap;
    this.recording = true;
    await cap.start();
  }

  /** 停止并返回 WAV 的 base64（不含 data: 前缀） */
  async stop(): Promise<string> {
    if (this.capturer === undefined) {
      return '';
    }
    this.recording = false;
    const cap: audio.AudioCapturer = this.capturer;
    this.capturer = undefined;
    try {
      cap.off('readData');
    } catch (err) {
      // 忽略
    }
    try {
      await cap.stop();
      await cap.release();
    } catch (err) {
      // 已释放
    }
    const wav: Uint8Array = this.buildWav();
    return new util.Base64Helper().encodeToStringSync(wav);
  }

  /** 取消：丢弃已录内容 */
  async cancel(): Promise<void> {
    this.recording = false;
    this.chunks = [];
    this.total = 0;
    if (this.capturer !== undefined) {
      const cap: audio.AudioCapturer = this.capturer;
      this.capturer = undefined;
      try {
        cap.off('readData');
      } catch (err) {
        // 忽略
      }
      try {
        await cap.stop();
        await cap.release();
      } catch (err) {
        // 忽略
      }
    }
  }

  /** PCM → WAV（44 字节头 + data） */
  private buildWav(): Uint8Array {
    const dataLen: number = this.total;
    const out: Uint8Array = new Uint8Array(44 + dataLen);
    const view: DataView = new DataView(out.buffer);
    const byteRate: number = SAMPLE_RATE * CHANNELS * BITS / 8;
    const blockAlign: number = CHANNELS * BITS / 8;

    Recorder.writeStr(out, 0, 'RIFF');
    view.setUint32(4, 36 + dataLen, true);
    Recorder.writeStr(out, 8, 'WAVE');
    Recorder.writeStr(out, 12, 'fmt ');
    view.setUint32(16, 16, true);          // fmt chunk size
    view.setUint16(20, 1, true);           // PCM
    view.setUint16(22, CHANNELS, true);
    view.setUint32(24, SAMPLE_RATE, true);
    view.setUint32(28, byteRate, true);
    view.setUint16(32, blockAlign, true);
    view.setUint16(34, BITS, true);
    Recorder.writeStr(out, 36, 'data');
    view.setUint32(40, dataLen, true);

    let offset: number = 44;
    for (const c of this.chunks) {
      out.set(c, offset);
      offset += c.byteLength;
    }
    return out;
  }

  private static writeStr(target: Uint8Array, at: number, s: string): void {
    for (let i = 0; i < s.length; i++) {
      target[at + i] = s.charCodeAt(i);
    }
  }
}
