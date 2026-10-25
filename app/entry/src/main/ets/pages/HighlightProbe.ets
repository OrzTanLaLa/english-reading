/**
 * B3 高亮探针：播放 PCM 的同时，按词级时间戳高亮当前词。
 *
 * 数据来自 B0 实测产物：
 *   t2.pcm          ← longbaizhi_t2.mp3 转 16k 单声道
 *   words_t2.json   ← [{text,start,end}]，79 词，末词 25609ms
 *
 * 关键点：
 *   - 播放位置用 framePos（getAudioTimeSync 是纳秒时间戳，不能用）
 *   - 写循环按 framePos 限流，否则缓冲区被灌满、位置与声音脱节
 *   - 高亮只在「当前词索引变化」时重建 Span，不是每帧重排
 */
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const SAMPLE_RATE: number = 16000;
const BYTES_PER_MS: number = SAMPLE_RATE * 2 / 1000;
const FRAMES_PER_MS: number = SAMPLE_RATE / 1000;
const CHUNK: number = 640;
const MAX_AHEAD_MS: number = 300;

interface WordTiming {
  text: string;
  start: number;
  end: number;
}

/** 把词拆成「前缀标点 / 词干 / 后缀标点」，只有词干参与高亮 */
interface WordParts {
  pre: string;
  core: string;
  post: string;
}

function splitWord(text: string): WordParts {
  // 词干只含字母、数字、撇号；连字符归到标点（TTS 会把 long-term 拆成 long + -term）
  const m: RegExpMatchArray | null = text.match(/^([^A-Za-z0-9]*)([A-Za-z0-9'’]*)([\s\S]*)$/);
  if (m === null) {
    return { pre: '', core: text, post: '' };
  }
  return { pre: m[1], core: m[2].length > 0 ? m[2] : text, post: m[2].length > 0 ? m[3] : '' };
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), ms);
  });
}

@Entry
@Component
struct HighlightProbe {
  @State log: string = '点「加载并播放」。';
  @State words: WordTiming[] = [];
  @State parts: WordParts[] = [];
  @State activeIndex: number = -1;
  @State positionMs: number = 0;
  @State playing: boolean = false;

  private pcm: ArrayBuffer = new ArrayBuffer(0);
  private renderer: audio.AudioRenderer | undefined = undefined;
  private byteOffset: number = 0;
  private baseMs: number = 0;
  private lastMs: number = 0;
  private paused: boolean = false;
  private pumpDone: boolean = true;
  private timer: number = -1;

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private add(text: string): void {
    this.log = this.log + '\n' + text;
  }

  private async load(): Promise<void> {
    if (this.pcm.byteLength > 0) {
      return;
    }
    const pcmData: Uint8Array = await this.ctx().resourceManager.getRawFileContent('t2.pcm');
    this.pcm = pcmData.buffer as ArrayBuffer;

    const jsonData: Uint8Array = await this.ctx().resourceManager.getRawFileContent('words_t2.json');
    const text: string = util.TextDecoder.create('utf-8').decodeToString(jsonData);
    this.words = JSON.parse(text) as WordTiming[];
    const built: WordParts[] = [];
    for (const w of this.words) {
      built.push(splitWord(w.text));
    }
    this.parts = built;
    this.add('PCM ' + (this.pcm.byteLength / 1024).toFixed(0) + ' KB，词 ' + this.words.length +
      ' 个，末词结束 ' + (this.words.length > 0 ? this.words[this.words.length - 1].end : 0) + ' ms');
  }

  /** 当前播放位置（毫秒） */
  private nowMs(): number {
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

  /** 二分查找位置所在的词 */
  private indexAt(ms: number): number {
    let lo: number = 0;
    let hi: number = this.words.length - 1;
    let ans: number = -1;
    while (lo <= hi) {
      const mid: number = (lo + hi) >> 1;
      if (this.words[mid].start <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  private tick(): void {
    const ms: number = this.nowMs();
    this.positionMs = ms;
    const idx: number = this.indexAt(ms);
    if (idx !== this.activeIndex) {
      this.activeIndex = idx;
    }
  }

  private startTimer(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setInterval(() => {
      this.tick();
    }, 80);
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
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
      rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 }
    };
    return audio.createAudioRenderer(options);
  }

  /** 创建 renderer；release 之后立刻 create 会报 6800301，所以失败等一会儿重试 */
  private async ensureRenderer(): Promise<audio.AudioRenderer> {
    if (this.renderer !== undefined) {
      return this.renderer;
    }
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        this.renderer = await this.createRenderer();
        return this.renderer;
      } catch (err) {
        this.add('创建 renderer 第 ' + attempt + ' 次失败: ' + JSON.stringify(err));
        await sleep(250);
      }
    }
    throw new Error('createAudioRenderer 连续失败');
  }

  private async start(): Promise<void> {
    try {
      await this.load();
      const r: audio.AudioRenderer = await this.ensureRenderer();
      await r.start();
      this.playing = true;
      this.paused = false;
      this.add('播放中，从 ' + this.nowMs() + ' ms');
      this.startTimer();
      this.kickPump();
    } catch (err) {
      this.add('启动失败: ' + JSON.stringify(err));
    }
  }

  private kickPump(): void {
    if (!this.pumpDone) {
      return;
    }
    this.pumpDone = false;
    this.pump();
  }

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
          if ((framesWritten - played) / FRAMES_PER_MS > MAX_AHEAD_MS) {
            await sleep(20);
            continue;
          }
        }
        const end: number = Math.min(this.byteOffset + CHUNK, this.pcm.byteLength);
        const written: number = await this.renderer!.write(this.pcm.slice(this.byteOffset, end));
        this.byteOffset = end;
        framesWritten += written / 2;
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
      this.add('继续 @ ' + this.nowMs() + ' ms');
    } else {
      await this.renderer.pause();
      this.paused = true;
      this.add('暂停 @ ' + this.nowMs() + ' ms');
    }
  }

  private async seek(ms: number): Promise<void> {
    const wasPlaying: boolean = this.playing && !this.paused;
    this.playing = false;
    this.stopTimer();
    if (this.renderer !== undefined) {
      try {
        await this.renderer.stop();
        await this.renderer.release();
      } catch (err) {
        // 已经停/释放过，忽略
      }
      this.renderer = undefined;
    }
    await sleep(250);
    this.byteOffset = Math.max(0, Math.min(this.pcm.byteLength, Math.round(ms * BYTES_PER_MS)));
    this.baseMs = Math.floor(this.byteOffset / BYTES_PER_MS);
    this.lastMs = this.baseMs;
    this.activeIndex = this.indexAt(this.baseMs);
    this.add('跳到 ' + this.baseMs + ' ms，高亮第 ' + (this.activeIndex + 1) + ' 个词');
    if (wasPlaying) {
      await this.start();
    }
  }

  build() {
    Column({ space: 10 }) {
      Text('B3 词级高亮探针')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .width('100%')

      Row({ space: 10 }) {
        Button(this.paused ? '继续' : '暂停').height(38).onClick(() => {
          this.togglePause();
        })
        Button('播放').height(38).onClick(() => {
          this.start();
        })
        Button('跳 0s').height(38).onClick(() => {
          this.seek(0);
        })
        Button('跳 10s').height(38).onClick(() => {
          this.seek(10000);
        })
      }
      .width('100%')

      Text('位置 ' + this.positionMs + ' ms　当前词 #' + (this.activeIndex + 1) +
        (this.activeIndex >= 0 && this.activeIndex < this.words.length ?
          ' ' + this.words[this.activeIndex].text : ''))
        .fontSize(13)
        .width('100%')
        .fontColor('#666666')

      Scroll() {
        Text() {
          ForEach(this.parts, (p: WordParts, i: number) => {
            Span(p.pre)
              .fontSize(20)
              .fontColor('#222222')
            Span(p.core)
              .fontSize(20)
              .fontColor(i === this.activeIndex ? Color.White : '#222222')
              .textBackgroundStyle(i === this.activeIndex ?
                { color: '#1A6DD9', radius: 3 } : { color: Color.Transparent, radius: 3 })
            Span(p.post + ' ')
              .fontSize(20)
              .fontColor('#222222')
          }, (p: WordParts, i: number) => i.toString() + p.pre + p.core + p.post)
        }
        .lineHeight(34)
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .padding(12)
      .backgroundColor('#FFFFFF')
      .borderRadius(8)

      Scroll() {
        Text(this.log)
          .fontSize(11)
          .fontFamily('monospace')
          .width('100%')
      }
      .height(140)
      .width('100%')
      .padding(8)
      .backgroundColor('#F5F5F5')
      .borderRadius(8)
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }
}
