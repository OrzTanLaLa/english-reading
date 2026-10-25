/**
 * M1 主链路探针：照片 → 云 OCR 分页 → 分句 → 整篇合成 → 边播边高亮。
 *
 * 计时口径按 M1 验收：从「开始识别」到「第一段音频可播放」。
 *
 * 合成用 qwen-audio-3.1-tts-flash：
 *   - 直接要 16k PCM，端侧不用解码；
 *   - 一次请求吃整篇（不再分组），词级时间戳是全局毫秒。
 */
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { audio } from '@kit.AudioKit';
import { SettingsStore } from '../adapters/storage';
import { CloudOcr, OcrPage } from '../adapters/ocr';
import { QwenTts, TtsResult, WordTiming } from '../adapters/tts';
import { splitSentences } from '../core/segment';
import { LOCAL_DASHSCOPE_KEY } from '../adapters/local_secret';
import { DEFAULT_VOICE, EN_VOICES, VoiceInfo, findVoice, voiceLabel } from '../core/voices';

const BYTES_PER_MS: number = 32;
const FRAMES_PER_MS: number = 16;
const CHUNK: number = 640;
const MAX_AHEAD_MS: number = 240;   // 领先量：太小会饿死缓冲区（framePos 卡 0），太大高亮会提前

interface PageView {
  index: number;
  sentences: string[];
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), ms);
  });
}

@Entry
@Component
struct ImportProbe {
  @State apiKey: string = '';
  @State voiceId: string = DEFAULT_VOICE;
  @State log: string = '填百炼 Key，点「内置图」或「选图并识别」。';
  @State pages: PageView[] = [];
  @State busy: boolean = false;
  @State readyMs: number = 0;

  // 播放相关
  @State words: WordTiming[] = [];
  @State activeIndex: number = -1;
  /** 当前句编号：只渲染这一句，Span 重建量从 60 词降到一句话 */
  @State curSent: number = 0;
  /** 校对模式：逐句编辑 OCR 结果 */
  @State editMode: boolean = false;
  @State editList: string[] = [];
  @State editIndex: number = -1;
  @State editBuf: string = '';
  @State positionMs: number = 0;
  @State latencyMs: number = 0;

  @State playing: boolean = false;
  @State paused: boolean = false;

  private fullText: string = '';
  private pcm: ArrayBuffer = new ArrayBuffer(0);
  private renderer: audio.AudioRenderer | undefined = undefined;
  private byteOffset: number = 0;
  private lastMs: number = 0;
  private playStartMs: number = 0;
  private tsErrLogged: boolean = false;
  private leadMs: number = 0;
  private playedFrames: number = 0;
  private pumpDone: boolean = true;
  private timer: number = -1;
  private schedTimer: number = -1;
  private posTimer: number = -1;
  private anchorPosMs: number = 0;
  private anchorWall: number = 0;
  private anchorValid: boolean = false;
  private fireCount: number = 0;
  private lateSum: number = 0;
  private lateMax: number = 0;
  /** 每次切词时「音频已走过的位置 - 该词起点」，这才是高亮真正的迟到量 */
  private audioLate: string[] = [];
  private audioLateSum: number = 0;
  private audioLateMax: number = 0;
  private sentIds: number[] = [];

  aboutToAppear(): void {
    this.loadKey();
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private add(text: string): void {
    this.log = this.log + '\n' + text;
  }

  private voiceOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (const v of EN_VOICES) {
      opts.push({ value: voiceLabel(v) });
    }
    return opts;
  }

  private voiceIndex(): number {
    for (let i = 0; i < EN_VOICES.length; i++) {
      if (EN_VOICES[i].id === this.voiceId) {
        return i;
      }
    }
    return 0;
  }

  private async loadKey(): Promise<void> {
    try {
      const savedVoice: string = await SettingsStore.loadVoice(this.ctx());
      if (savedVoice.length > 0 && findVoice(savedVoice) !== undefined) {
        this.voiceId = savedVoice;
      }
      const saved: string = await SettingsStore.loadDashScopeKey(this.ctx());
      if (saved.length > 0) {
        this.apiKey = saved;
      } else if (LOCAL_DASHSCOPE_KEY.length > 0) {
        this.apiKey = LOCAL_DASHSCOPE_KEY;
      }
    } catch (err) {
      // 忽略
    }
  }

  private readBase64(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(uri);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      const helper: util.Base64Helper = new util.Base64Helper();
      return helper.encodeToStringSync(new Uint8Array(buf));
    } finally {
      fs.closeSync(file);
    }
  }

  /** OCR 结果 → 页面列表 + 全文 */
  private applyOcr(ocrPages: OcrPage[]): number {
    const views: PageView[] = [];
    const texts: string[] = [];
    let sentenceCount: number = 0;
    for (const p of ocrPages) {
      const sentences = splitSentences(p.text);
      sentenceCount += sentences.length;
      views.push({ index: p.index, sentences: sentences });
      texts.push(p.text);
    }
    this.pages = views;
    this.fullText = texts.join('\n\n');
    const flat: string[] = [];
    for (const v of views) {
      for (const s of v.sentences) {
        flat.push(s);
      }
    }
    this.editList = flat;
    this.editIndex = -1;
    this.editBuf = '';
    return sentenceCount;
  }

  private async importFromBundle(): Promise<void> {
    if (this.busy) {
      return;
    }
    const key: string = this.apiKey.trim();
    if (key.length === 0) {
      this.log = '先填百炼 API Key（DashScope）';
      return;
    }
    this.busy = true;
    this.pages = [];
    this.readyMs = 0;
    this.log = '开始识别内置图…';
    try {
      await SettingsStore.saveDashScopeKey(this.ctx(), key);
      const t0: number = Date.now();
      const data: Uint8Array = await this.ctx().resourceManager.getRawFileContent('test_page.jpg');
      const helper: util.Base64Helper = new util.Base64Helper();
      const base64: string = helper.encodeToStringSync(data);

      const ocr = new CloudOcr(key);
      const ocrPages: OcrPage[] = await ocr.recognize(base64);
      this.add('OCR ' + ocrPages.length + ' 页，' + (Date.now() - t0) + ' ms');

      const t2: number = Date.now();
      const n: number = this.applyOcr(ocrPages);
      this.pages = this.pages.slice();
      this.readyMs = Date.now() - t0;
      this.add('分句 ' + n + ' 句，' + (Date.now() - t2) + ' ms');
      this.add('=== 文本可朗读: ' + this.readyMs + ' ms（' + this.fullText.length + ' 字符）===');
    } catch (err) {
      this.add('失败: ' + JSON.stringify(err));
    } finally {
      this.busy = false;
    }
  }

  private async importFromPhoto(): Promise<void> {
    if (this.busy) {
      return;
    }
    const key: string = this.apiKey.trim();
    if (key.length === 0) {
      this.log = '先填百炼 API Key（DashScope）';
      return;
    }
    this.busy = true;
    this.pages = [];
    this.readyMs = 0;
    this.log = '开始导入…';
    try {
      await SettingsStore.saveDashScopeKey(this.ctx(), key);
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const picked = await picker.select(options);
      if (picked.photoUris.length === 0) {
        this.add('没有选图');
        return;
      }

      const t0: number = Date.now();
      const base64: string = this.readBase64(picked.photoUris[0]);
      const ocr = new CloudOcr(key);
      const ocrPages: OcrPage[] = await ocr.recognize(base64);
      this.add('OCR ' + ocrPages.length + ' 页，' + (Date.now() - t0) + ' ms');

      const t2: number = Date.now();
      const n: number = this.applyOcr(ocrPages);
      this.pages = this.pages.slice();
      this.readyMs = Date.now() - t0;
      this.add('分句 ' + n + ' 句，' + (Date.now() - t2) + ' ms');
      this.add('=== 文本可朗读: ' + this.readyMs + ' ms（' + this.fullText.length + ' 字符）===');
    } catch (err) {
      this.add('失败: ' + JSON.stringify(err));
    } finally {
      this.busy = false;
    }
  }

  /** 清掉控制字符与不可见字符；OCR 结果里偶尔混进这些，会让服务端判定文本非法 */
  private sanitize(s: string): string {
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c === 10 || c === 32 || (c >= 33 && c <= 126)) {
        out += s.charAt(i);
      } else if (c > 126) {
        out += s.charAt(i);   // 保留中文标点、破折号等可见字符
      }
    }
    return out.replace(/\s+/g, ' ').trim();
  }

  /** 整篇合成：拿到 PCM 和全局词时间戳 */
  private async synthesize(): Promise<void> {
    if (this.busy) {
      return;
    }
    const key: string = this.apiKey.trim();
    if (key.length === 0 || this.fullText.length === 0) {
      this.add('先识别出文本');
      return;
    }
    this.busy = true;
    this.words = [];
    this.pcm = new ArrayBuffer(0);
    this.activeIndex = -1;
    this.add('=== 开始合成（' + this.voiceId + '）===');
    try {
      const t0: number = Date.now();
      const source: string = this.editList.length > 0 ? this.editList.join(' ') : this.fullText;
      const clean: string = this.sanitize(source);
      this.add('发送 ' + clean.length + ' 字符，开头: ' + clean.substring(0, 60));
      const tts = new QwenTts(key, this.voiceId);
      const r: TtsResult = await tts.synthesize(clean, {});
      this.pcm = r.pcm;
      this.words = r.words;
      this.buildSentIds();
      this.byteOffset = 0;
      this.lastMs = 0;
      this.positionMs = 0;
      this.playing = false;
      this.paused = false;
      const durMs: number = Math.round(r.pcm.byteLength / BYTES_PER_MS);
      this.add('PCM ' + (r.pcm.byteLength / 1024).toFixed(0) + ' KB / ' + (durMs / 1000).toFixed(1) +
        ' 秒 / ' + r.words.length + ' 词');
      this.add('首包 ' + r.firstPacketMs + ' ms，合成总耗时 ' + r.totalMs + ' ms');
      this.add('token ' + r.inputTokens + ' in + ' + r.outputTokens + ' out');
      this.add('=== 从开始识别到可播放: ' + (this.readyMs + (Date.now() - t0)) + ' ms ===');
      this.saveCache();
    } catch (err) {
      this.add('合成失败: ' + String(err));
    } finally {
      this.busy = false;
    }
  }

  private cacheDir(): string {
    return this.ctx().filesDir;
  }

  private saveCache(): void {
    try {
      const pcmPath: string = this.cacheDir() + '/m1.pcm';
      const f = fs.openSync(pcmPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, this.pcm);
      } finally {
        fs.closeSync(f);
      }
      const jsonPath: string = this.cacheDir() + '/m1_words.json';
      const j = fs.openSync(jsonPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(j.fd, JSON.stringify(this.words));
      } finally {
        fs.closeSync(j);
      }
      this.add('已缓存 PCM + 时间戳（省下次的合成费）');
    } catch (err) {
      this.add('缓存失败: ' + JSON.stringify(err));
    }
  }

  private loadCache(): void {
    try {
      const pcmPath: string = this.cacheDir() + '/m1.pcm';
      if (!fs.accessSync(pcmPath)) {
        this.add('没有缓存');
        return;
      }
      const stat = fs.statSync(pcmPath);
      const buf = new ArrayBuffer(stat.size);
      const f = fs.openSync(pcmPath, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(f.fd, buf);
      } finally {
        fs.closeSync(f);
      }
      this.pcm = buf;
      const jsonPath: string = this.cacheDir() + '/m1_words.json';
      const text: string = fs.readTextSync(jsonPath);
      this.words = JSON.parse(text) as WordTiming[];
      this.buildSentIds();
      this.byteOffset = 0;
      this.lastMs = 0;
      this.positionMs = 0;
      this.activeIndex = -1;
      this.curSent = 0;
      this.playing = false;
      this.paused = false;
      this.add('已载入缓存: ' + (buf.byteLength / 1024).toFixed(0) + ' KB / ' +
        this.words.length + ' 词 / ' + (buf.byteLength / BYTES_PER_MS / 1000).toFixed(1) + ' 秒');
    } catch (err) {
      this.add('载入失败: ' + JSON.stringify(err));
    }
  }

  private loadSample(file: string): void {
    try {
      const data: Uint8Array = this.ctx().resourceManager.getRawFileContentSync(file);
      this.fullText = util.TextDecoder.create('utf-8').decodeToString(data);
      this.add('示例文本(' + file + ') ' + this.fullText.length + ' 字符');
    } catch (err) {
      this.add('读取示例失败: ' + JSON.stringify(err));
    }
  }

  private totalMs(): number {
    return Math.floor(this.pcm.byteLength / BYTES_PER_MS);
  }

  private nowMs(): number {
    if (this.renderer === undefined) {
      return this.lastMs;
    }
    try {
      const info: audio.AudioTimestampInfo = this.renderer.getAudioTimestampInfoSync();
      this.lastMs = Math.floor(info.framePos / FRAMES_PER_MS);
      if (this.renderer !== undefined) {
        try {
          const all: number = this.renderer.getLatency(audio.AudioLatencyType.LATENCY_TYPE_ALL);
          this.latencyMs = all;
        } catch (e) {
          this.latencyMs = -1;
        }
      }
      return this.lastMs;
    } catch (err) {
      if (!this.tsErrLogged) {
        this.tsErrLogged = true;
        this.add('getAudioTimestampInfoSync 异常: ' + JSON.stringify(err));
      }
      return this.lastMs;
    }
  }

  private indexAt(ms: number): number {
    let lo: number = 0;
    let hi: number = this.words.length - 1;
    let ans: number = -1;
    while (lo <= hi) {
      const mid: number = (lo + hi) >> 1;
      if (this.words[mid].begin <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /** 用 (framePos, timestamp) 建立锚点：之后的位置 = 锚点位置 + 墙钟增量 */
  private reanchor(): boolean {
    if (this.renderer === undefined) {
      return false;
    }
    try {
      const info: audio.AudioTimestampInfo = this.renderer.getAudioTimestampInfoSync();
      this.anchorPosMs = info.framePos / FRAMES_PER_MS;
      this.anchorWall = Date.now();
      this.anchorValid = true;
      return true;
    } catch (err) {
      return false;
    }
  }

  private posNow(): number {
    if (!this.anchorValid) {
      return this.lastMs;
    }
    return this.anchorPosMs + (Date.now() - this.anchorWall);
  }

  private sentOf(index: number): number {
    if (index < 0 || index >= this.sentIds.length) {
      return 0;
    }
    return this.sentIds[index];
  }

  /** 按标点与停顿把词切成句，供「只高亮当前句」用 */
  private buildSentIds(): void {
    const ids: number[] = [];
    let cur: number = 0;
    for (let i = 0; i < this.words.length; i++) {
      ids.push(cur);
      const t: string = this.words[i].text.trim();
      // 词条里可能连着标点（如 "persistence.It"），用包含判断
      const ends: boolean = t.indexOf('.') >= 0 || t.indexOf('!') >= 0 || t.indexOf('?') >= 0;
      const gap: number = i + 1 < this.words.length ? this.words[i + 1].begin - this.words[i].end : 0;
      if (ends || gap > 300) {
        cur++;
      }
    }
    this.sentIds = ids;
  }

  private startSchedule(): void {
    this.stopSchedule();
    this.fireCount = 0;
    this.lateSum = 0;
    this.lateMax = 0;
    this.audioLate = [];
    this.audioLateSum = 0;
    this.audioLateMax = 0;
    this.reanchor();
    const idx: number = this.indexAt(this.posNow());
    this.activeIndex = idx;
    this.curSent = this.sentOf(idx);
    this.positionMs = Math.floor(Math.max(0, this.posNow()));
    this.posTimer = setInterval(() => {
      this.positionMs = Math.floor(Math.max(0, this.posNow()));
    }, 250);
    this.scheduleNext();
  }

  private stopSchedule(): void {
    if (this.schedTimer >= 0) {
      clearTimeout(this.schedTimer);
      this.schedTimer = -1;
    }
    if (this.posTimer >= 0) {
      clearInterval(this.posTimer);
      this.posTimer = -1;
    }
  }

  /**
   * 只调度「下一个词的开始时刻」，触发后**重读 framePos 校准**再排下一个。
   *
   * 为什么每次都要重读：靠「锚点 + 墙钟」外推时，定时器每迟到几十毫秒就会累积成
   * 句内的渐进滞后——实测就是一句里越往后越慢、句末最明显，遇到句子停顿又追回来。
   * 每次重读把误差压成「单次迟到」，不再累积。
   */
  private scheduleNext(): void {
    if (this.schedTimer >= 0) {
      clearTimeout(this.schedTimer);
      this.schedTimer = -1;
    }
    if (!this.playing || this.paused) {
      return;
    }
    this.reanchor();                    // 每次都用真实播放位置
    const pos: number = this.posNow();
    const idx: number = this.indexAt(pos);
    if (idx !== this.activeIndex) {
      this.activeIndex = idx;
      const s: number = this.sentOf(idx);
      if (s !== this.curSent) {
        this.curSent = s;
      }
      if (idx >= 0 && idx < this.words.length) {
        const d: number = Math.round(pos - this.words[idx].begin);
        this.audioLate.push((idx + 1) + ':' + d);
        this.audioLateSum += d;
        this.audioLateMax = Math.max(this.audioLateMax, d);
        if (this.audioLate.length % 20 === 0) {
          this.add('音频迟到(词:ms) 均值 ' + Math.round(this.audioLateSum / this.audioLate.length) +
            ' 最大 ' + this.audioLateMax + ' | ' + this.audioLate.slice(-20).join(' '));
        }
      }
    }
    const next: number = idx + 1;
    if (next >= this.words.length) {
      return;
    }
    const delay: number = this.words[next].begin - pos;
    const plannedAt: number = Date.now() + Math.max(3, delay);
    this.schedTimer = setTimeout(() => {
      this.schedTimer = -1;
      this.fireCount++;
      // 迟到 = 定时器抖动 + UI 线程被占住的时间
      const late: number = Date.now() - plannedAt;
      this.lateSum += late;
      this.lateMax = Math.max(this.lateMax, late);
      if (this.fireCount % 10 === 0) {
        this.add('调度 ' + this.fireCount + ' 次，平均迟到 ' +
          Math.round(this.lateSum / this.fireCount) + 'ms，最大 ' + Math.round(this.lateMax) + 'ms');
      }
      this.scheduleNext();
    }, Math.max(3, delay));
  }
  private async ensureRenderer(): Promise<audio.AudioRenderer> {
    if (this.renderer !== undefined) {
      return this.renderer;
    }
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
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        this.renderer = await audio.createAudioRenderer(options);
        return this.renderer;
      } catch (err) {
        await sleep(250);
      }
    }
    throw new Error('createAudioRenderer 失败');
  }

  private async play(): Promise<void> {
    if (this.pcm.byteLength === 0) {
      this.add('先合成');
      return;
    }
    try {
      const r: audio.AudioRenderer = await this.ensureRenderer();
      await r.start();
      this.playStartMs = Date.now();
      this.tsErrLogged = false;
      try {
        const all: number = r.getLatency(audio.AudioLatencyType.LATENCY_TYPE_ALL);
        const sw: number = r.getLatency(audio.AudioLatencyType.LATENCY_TYPE_SOFTWARE);
        this.add('getLatency: all=' + all + 'ms software=' + sw + 'ms');
      } catch (err) {
        this.add('getLatency 不可用: ' + JSON.stringify(err));
      }
      this.add('renderer state=' + r.state);
      this.playing = true;
      this.paused = false;
      this.startSchedule();
      this.kickPump();
    } catch (err) {
      this.add('播放失败: ' + JSON.stringify(err));
    }
  }

  /** 重播：停掉写循环与调度，释放 renderer，从 0 重新开始 */
  private async replay(): Promise<void> {
    if (this.pcm.byteLength === 0) {
      this.add('先合成或载入缓存');
      return;
    }
    this.playing = false;
    this.paused = false;
    this.stopSchedule();
    for (let i = 0; i < 60 && !this.pumpDone; i++) {
      await sleep(20);
    }
    if (this.renderer !== undefined) {
      try {
        await this.renderer.stop();
        await this.renderer.release();
      } catch (err) {
        // 忽略：可能已经停/释放
      }
      this.renderer = undefined;
    }
    await sleep(250);   // release 后立刻 create 会报 6800301
    this.byteOffset = 0;
    this.lastMs = 0;
    this.positionMs = 0;
    this.activeIndex = -1;
    this.curSent = 0;
    this.anchorValid = false;
    this.add('重播');
    await this.play();
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
          this.playedFrames = played;
          if ((framesWritten - played) / FRAMES_PER_MS > MAX_AHEAD_MS) {
            await sleep(20);
            continue;
          }
        }
        const end: number = Math.min(this.byteOffset + CHUNK, this.pcm.byteLength);
        const written: number = await this.renderer!.write(this.pcm.slice(this.byteOffset, end));
        this.byteOffset = end;
        framesWritten += written / 2;
        this.leadMs = Math.round((framesWritten - this.playedFrames) / FRAMES_PER_MS);
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
      this.startSchedule();
    } else {
      await this.renderer.pause();
      this.paused = true;
      this.stopSchedule();
    }
  }

  /** 当前句的词（只渲染这一句，Span 重建量从几十词降到一句） */
  private sentWords(): WordTiming[] {
    const out: WordTiming[] = [];
    if (this.words.length === 0 || this.sentIds.length === 0) {
      return out;
    }
    for (let i = 0; i < this.words.length; i++) {
      if (this.sentIds[i] === this.curSent) {
        out.push(this.words[i]);
      }
    }
    return out;
  }

  /** 当前句第一个词在全文中的下标 */
  private sentBase(): number {
    for (let i = 0; i < this.sentIds.length; i++) {
      if (this.sentIds[i] === this.curSent) {
        return i;
      }
    }
    return 0;
  }
  private splitWord(text: string): string[] {
    const m: RegExpMatchArray | null = text.match(/^([^A-Za-z0-9]*)([A-Za-z0-9'’]*)([\s\S]*)$/);
    if (m === null) {
      return ['', text, ''];
    }
    return [m[1], m[2].length > 0 ? m[2] : text, m[2].length > 0 ? m[3] : ''];
  }

  build() {
    Column({ space: 8 }) {
      Text('M1 主链路')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .width('100%')

      TextInput({ text: this.apiKey, placeholder: '百炼 DashScope API Key' })
        .type(InputType.Password)
        .width('100%')
        .height(40)
        .onChange((v: string) => {
          this.apiKey = v;
        })

      Row({ space: 10 }) {
        Text('音色').fontSize(13).fontColor('#666666')
        Select(this.voiceOptions())
          .selected(this.voiceIndex())
          .value(voiceLabel(EN_VOICES[this.voiceIndex()]))
          .font({ size: 13 })
          .layoutWeight(1)
          .onSelect((index: number) => {
            const v: VoiceInfo = EN_VOICES[index];
            this.voiceId = v.id;
            SettingsStore.saveVoice(this.ctx(), v.id);
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Button(this.editMode ? '完成' : '校对').height(36).fontSize(13).onClick(() => {
          this.editMode = !this.editMode;
          this.editIndex = -1;
          if (this.editMode && this.editList.length === 0 && this.fullText.length > 0) {
            this.editList = [this.fullText];
          }
        })
        Button('示例1').height(36).fontSize(13).onClick(() => {
          this.loadSample('sample.txt');
        })
        Button('示例2').height(36).fontSize(13).onClick(() => {
          this.loadSample('sample2.txt');
        })
        Button('缓存').height(36).fontSize(13).onClick(() => {
          this.loadCache();
        })
        Button('内置图').height(36).fontSize(13).enabled(!this.busy).onClick(() => {
          this.importFromBundle();
        })
        Button('选图').height(36).fontSize(13).enabled(!this.busy).onClick(() => {
          this.importFromPhoto();
        })
        Button('合成').height(36).fontSize(13).enabled(!this.busy).onClick(() => {
          this.synthesize();
        })
        Button('重播').height(36).fontSize(13).onClick(() => {
          this.replay();
        })
        Button(this.paused ? '继续' : '播放').height(36).fontSize(13).onClick(() => {
          if (this.playing && !this.paused) {
            this.togglePause();
          } else if (this.paused) {
            this.togglePause();
          } else {
            this.play();
          }
        })
        Text(this.positionMs > 0 ? (this.positionMs + '/' + this.totalMs() + ' 延迟' + this.latencyMs) : '')
          .fontSize(11)
          .fontColor('#666666')
      }
      .width('100%')


      if (this.editMode) {
        Scroll() {
          Column({ space: 6 }) {
            ForEach(this.editList, (s: string, i: number) => {
              Text((i + 1) + '. ' + s)
                .fontSize(15)
                .width('100%')
                .padding(6)
                .backgroundColor(i === this.editIndex ? '#DCE9FB' : '#FFFFFF')
                .borderRadius(4)
                .onClick(() => {
                  this.editIndex = i;
                  this.editBuf = s;
                })
            }, (s: string, i: number) => i.toString() + s.substring(0, 12))
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .padding(8)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .align(Alignment.TopStart)

        if (this.editIndex >= 0) {
          Column({ space: 6 }) {
            Text('编辑第 ' + (this.editIndex + 1) + ' 句（清空=删除）')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .width('100%')
            TextArea({ text: this.editBuf })
              .width('100%')
              .height(80)
              .fontSize(15)
              .onChange((v: string) => {
                this.editBuf = v;
              })
            Row({ space: 10 }) {
              Button('保存').height(32).fontSize(12).onClick(() => {
                const list: string[] = this.editList.slice();
                const v: string = this.editBuf.trim();
                if (v.length > 0) {
                  list[this.editIndex] = v;
                } else {
                  list.splice(this.editIndex, 1);
                }
                this.editList = list;
                this.editIndex = -1;
                this.editBuf = '';
              })
              Button('删除').height(32).fontSize(12).onClick(() => {
                const list: string[] = this.editList.slice();
                list.splice(this.editIndex, 1);
                this.editList = list;
                this.editIndex = -1;
                this.editBuf = '';
              })
              Button('取消').height(32).fontSize(12).onClick(() => {
                this.editIndex = -1;
                this.editBuf = '';
              })
            }
            .width('100%')
          }
          .width('100%')
          .padding(8)
          .backgroundColor('#F0F4FA')
          .borderRadius(6)
        }
      } else {
        Scroll() {
          Text() {
            ForEach(this.sentWords(), (w: WordTiming, i: number) => {
              Span(this.splitWord(w.text)[0]).fontSize(17).fontColor('#222222')
              Span(this.splitWord(w.text)[1])
                .fontSize(17)
                .fontColor((i + this.sentBase()) === this.activeIndex ? Color.White : '#222222')
                .textBackgroundStyle((i + this.sentBase()) === this.activeIndex ?
                  { color: '#1A6DD9', radius: 3 } : { color: Color.Transparent, radius: 3 })
              Span(this.splitWord(w.text)[2] + ' ').fontSize(17).fontColor('#222222')
            }, (w: WordTiming, i: number) => (i + this.sentBase()).toString() + w.text)
          }
          .lineHeight(30)
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .padding(10)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
      }

      Scroll() {
        Text(this.log).fontSize(11).fontFamily('monospace').width('100%')
      }
      .height(150)
      .width('100%')
      .padding(8)
      .backgroundColor('#F5F5F5')
      .borderRadius(8)
    }
    .padding(14)
    .width('100%')
    .height('100%')
  }
}
