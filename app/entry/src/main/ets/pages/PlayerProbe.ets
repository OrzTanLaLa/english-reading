/**
 * B3 播放器探针：AudioRenderer 播放 16k/单声道/16bit PCM。
 *
 * 三个关键实现点（都是踩过坑的）：
 *   1. **按实时速率限流**：write() 不会等到缓冲区空才返回，必须自己用 framePos 控制
 *      「已写帧数 - 已播帧数」，否则 24 秒音频会在几秒内全塞进缓冲区，
 *      暂停/恢复的语义就失真了；
 *   2. **播放位置用 framePos**：`getAudioTimeSync()` 返回的是纳秒时间戳，不是播放时长；
 *   3. **跳转要重建 renderer**：framePos 是「自 renderer 创建以来播放的帧数」，
 *      不重建的话跳转后位置无法换算。
 */
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';

const SAMPLE_RATE: number = 16000;
const BYTES_PER_MS: number = SAMPLE_RATE * 2 / 1000;   // 32 字节/毫秒
const FRAMES_PER_MS: number = SAMPLE_RATE / 1000;      // 16 帧/毫秒
const CHUNK: number = 640;                             // 20ms 一片
const MAX_AHEAD_MS: number = 300;                      // 最多领先播放位置 300ms

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), ms);
  });
}

@Entry
@Component
struct PlayerProbe {
  @State log: string = '点「加载并播放」。';
  @State busy: boolean = false;
  @State playing: boolean = false;

  private pcm: ArrayBuffer = new ArrayBuffer(0);
  private renderer: audio.AudioRenderer | undefined = undefined;
  private byteOffset: number = 0;
  private baseMs: number = 0;        // 本次播放的起始毫秒（跳转后不为 0）
  private lastMs: number = 0;        // 最近一次成功读到的位置（暂停时 API 会抛异常，用它兜底）
  private paused: boolean = false;
  private pumpDone: boolean = true;

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private add(text: string): void {
    this.log = this.log + '\n' + text;
  }

  private totalMs(): number {
    return Math.floor(this.pcm.byteLength / BYTES_PER_MS);
  }

  /** 当前播放位置（毫秒） */
  private positionMs(): number {
    if (this.renderer === undefined) {
      return this.baseMs;
    }
    try {
      const info: audio.AudioTimestampInfo = this.renderer.getAudioTimestampInfoSync();
      this.lastMs = this.baseMs + Math.floor(info.framePos / FRAMES_PER_MS);
      return this.lastMs;
    } catch (err) {
      return this.lastMs;
    }
  }

  private async load(): Promise<void> {
    if (this.pcm.byteLength > 0) {
      return;
    }
    const data: Uint8Array = await this.ctx().resourceManager.getRawFileContent('t1.pcm');
    this.pcm = data.buffer as ArrayBuffer;
    this.add('PCM ' + (this.pcm.byteLength / 1024).toFixed(0) + ' KB，' + this.totalMs() + ' ms');
  }

  private async createRenderer(): Promise<audio.AudioRenderer> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const options: audio.AudioRendererOptions = {
      streamInfo: streamInfo,
      rendererInfo: {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      }
    };
    return audio.createAudioRenderer(options);
  }

  private async start(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await this.load();
      if (this.renderer === undefined) {
        this.renderer = await this.createRenderer();
        this.add('AudioRenderer 创建，buffer=' + (await this.renderer.getBufferSize()) + ' 字节');
      }
      await this.renderer.start();
      this.playing = true;
      this.paused = false;
      this.add('开始播放：baseMs=' + this.baseMs + '，字节偏移 ' + this.byteOffset);
      this.kickPump();
    } catch (err) {
      this.add('启动失败: ' + JSON.stringify(err));
    } finally {
      this.busy = false;
    }
  }

  private kickPump(): void {
    if (!this.pumpDone) {
      return;
    }
    this.pumpDone = false;
    this.pump();
  }

  /** 写循环：按 framePos 限流，保证「已写 - 已播」不超过 MAX_AHEAD_MS */
  private async pump(): Promise<void> {
    let framesWritten: number = 0;
    try {
      while (this.playing && this.byteOffset < this.pcm.byteLength) {
        if (this.paused) {
          await sleep(20);
          continue;
        }
        if (this.renderer !== undefined) {
          let played: number = 0;
          try {
            played = this.renderer.getAudioTimestampInfoSync().framePos;
          } catch (err) {
            played = 0;
          }
          const aheadMs: number = (framesWritten - played) / FRAMES_PER_MS;
          if (aheadMs > MAX_AHEAD_MS) {
            await sleep(20);
            continue;
          }
        }
        const end: number = Math.min(this.byteOffset + CHUNK, this.pcm.byteLength);
        const chunk: ArrayBuffer = this.pcm.slice(this.byteOffset, end);
        const written: number = await this.renderer!.write(chunk);
        this.byteOffset = end;
        framesWritten += written / 2;
      }
      if (this.byteOffset >= this.pcm.byteLength) {
        this.add('数据写完，等待播完（位置 ' + this.positionMs() + ' ms）');
      }
    } catch (err) {
      this.add('写入失败: ' + JSON.stringify(err));
    } finally {
      this.pumpDone = true;
    }
  }

  private async togglePause(): Promise<void> {
    if (this.renderer === undefined) {
      return;
    }
    if (this.paused) {
      await this.renderer.start();
      this.paused = false;
      this.add('继续，位置 ' + this.positionMs() + ' ms');
    } else {
      await this.renderer.pause();
      this.paused = true;
      this.add('暂停，位置 ' + this.positionMs() + ' ms');
    }
  }

  /** 暂停 10 次：看暂停期间位置是否冻结、恢复后是否连续 */
  private async pauseTenTimes(): Promise<void> {
    if (this.renderer === undefined || !this.playing) {
      this.add('先点「加载并播放」');
      return;
    }
    this.busy = true;
    try {
      this.add('=== 暂停 10 次 ===');
      for (let i = 1; i <= 10; i++) {
        await sleep(600);
        const before: number = this.positionMs();
        await this.renderer.pause();
        this.paused = true;
        await sleep(250);
        const during: number = this.positionMs();
        await this.renderer.start();
        this.paused = false;
        await sleep(250);
        const after: number = this.positionMs();
        this.add(`#${i} 暂停前=${before} 暂停中=${during} 恢复后=${after} ` +
          `暂停漂移=${during - before}ms 恢复跳变=${after - during - 250}ms`);
      }
      this.add('=== 结束，最终位置 ' + this.positionMs() + ' / ' + this.totalMs() + ' ms ===');
    } catch (err) {
      this.add('测试失败: ' + JSON.stringify(err));
    } finally {
      this.busy = false;
    }
  }

  /** 跳转：重建 renderer，让 framePos 从 0 重新计 */
  private async seek(ms: number): Promise<void> {
    this.busy = true;
    try {
      const wasPlaying: boolean = this.playing && !this.paused;
      this.playing = false;
      this.paused = false;
      if (this.renderer !== undefined) {
        await this.renderer.stop();
        await this.renderer.release();
        this.renderer = undefined;
      }
      await sleep(50);
      this.byteOffset = Math.max(0, Math.min(this.pcm.byteLength, Math.round(ms * BYTES_PER_MS)));
      this.baseMs = Math.floor(this.byteOffset / BYTES_PER_MS);
      this.lastMs = this.baseMs;
      this.add('跳转到 ' + this.baseMs + ' ms（字节 ' + this.byteOffset + '）');
      if (wasPlaying) {
        this.busy = false;
        await this.start();
      }
    } catch (err) {
      this.add('跳转失败: ' + JSON.stringify(err));
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column({ space: 10 }) {
      Text('B3 播放器探针')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .width('100%')

      Row({ space: 10 }) {
        Button('加载并播放').height(40).onClick(() => {
          this.start();
        })
        Button(this.paused ? '继续' : '暂停').height(40).onClick(() => {
          this.togglePause();
        })
        Button('暂停 10 次').height(40).onClick(() => {
          this.pauseTenTimes();
        })
      }
      .width('100%')

      Row({ space: 10 }) {
        Button('跳 0s').height(36).onClick(() => {
          this.seek(0);
        })
        Button('跳 5s').height(36).onClick(() => {
          this.seek(5000);
        })
        Button('跳 15s').height(36).onClick(() => {
          this.seek(15000);
        })
        Button('位置').height(36).onClick(() => {
          this.add('当前位置 ' + this.positionMs() + ' ms');
        })
      }
      .width('100%')

      Scroll() {
        Text(this.log)
          .fontSize(12)
          .fontFamily('monospace')
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .padding(10)
      .backgroundColor('#F5F5F5')
      .borderRadius(8)
      .align(Alignment.TopStart)
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }
}
