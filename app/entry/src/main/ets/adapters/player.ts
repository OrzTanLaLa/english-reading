/**
 * PCM 播放器（回调驱动版）。
 *
 * 相比上一版的关键变化：
 *   1. **数据由音频线程来拉**（`on('writeData')`），不再由我们 write() 轮询；
 *      因此删掉了「领先量 240ms 限流」「写循环饿死」「缓冲深度统计」这些补丁。
 *   2. 位置仍然用 `framePos`（getAudioTimeSync 返回的是纳秒时间戳，不能用）。
 *   3. **支持 seek**：重建 renderer 让 framePos 归零，位置 = baseMs + framePos/16。
 *   4. 词级高亮仍用「每个词触发时重读 framePos」的调度，避免句内累积误差。
 */
import { audio } from '@kit.AudioKit';
import { indexAt, WordTiming } from '../core/reader';

const FRAMES_PER_MS: number = 16;   // 16kHz
const BYTES_PER_MS: number = 32;    // 16kHz × 2 字节

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), ms);
  });
}

export interface PlayerCallbacks {
  onPosition?: (ms: number) => void;
  onWord?: (index: number) => void;
  onEnded?: () => void;
  onError?: (msg: string) => void;
}

export class PcmPlayer {
  private cb: PlayerCallbacks;
  private renderer: audio.AudioRenderer | undefined = undefined;
  private pcm: ArrayBuffer = new ArrayBuffer(0);
  private words: WordTiming[] = [];

  /** 本次播放的起点（毫秒）；seek 之后不为 0 */
  private baseMs: number = 0;
  /** 已写入音频线程的字节数（含 baseMs 偏移） */
  private byteOffset: number = 0;

  private playing: boolean = false;
  private paused: boolean = false;
  private tailSent: boolean = false;

  private posTimer: number = -1;
  private schedTimer: number = -1;
  private anchorPosMs: number = 0;
  private anchorWall: number = 0;
  private anchorValid: boolean = false;
  private activeIndex: number = -1;

  constructor(cb: PlayerCallbacks) {
    this.cb = cb;
  }

  // ---- 数据 ----

  setData(pcm: ArrayBuffer, words: WordTiming[], startMs: number = 0): void {
    this.pcm = pcm;
    this.words = words;
    this.baseMs = Math.max(0, Math.min(startMs, this.totalMs()));
    this.byteOffset = this.baseMs * BYTES_PER_MS;
    this.activeIndex = -1;
    this.anchorValid = false;
    this.emitWordAtPosition();
  }

  hasData(): boolean {
    return this.pcm.byteLength > 0;
  }

  totalMs(): number {
    return Math.floor(this.pcm.byteLength / BYTES_PER_MS);
  }

  isPlaying(): boolean {
    return this.playing && !this.paused;
  }

  isPaused(): boolean {
    return this.paused;
  }

  // ---- 位置 ----

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

  /** 当前位置（毫秒，含 seek 偏移） */
  positionMs(): number {
    if (!this.anchorValid) {
      return this.baseMs;
    }
    return this.baseMs + this.anchorPosMs + (Date.now() - this.anchorWall);
  }

  private emitWordAtPosition(): void {
    if (this.cb.onWord === undefined) {
      return;
    }
    const idx: number = indexAt(this.words, this.positionMs());
    if (idx !== this.activeIndex) {
      this.activeIndex = idx;
      this.cb.onWord(idx);
    }
  }

  // ---- 渲染器 ----

  /** 音频线程来要数据 */
  private handleWriteData(buffer: ArrayBuffer): audio.AudioDataCallbackResult {
    const dst: Uint8Array = new Uint8Array(buffer);
    const remain: number = this.pcm.byteLength - this.byteOffset;
    if (remain <= 0) {
      dst.fill(0);
      this.tailSent = true;
      return audio.AudioDataCallbackResult.VALID;
    }
    const n: number = Math.min(buffer.byteLength, remain);
    dst.set(new Uint8Array(this.pcm, this.byteOffset, n), 0);
    if (n < buffer.byteLength) {
      dst.fill(0, n);
      this.tailSent = true;
    }
    this.byteOffset += n;
    return audio.AudioDataCallbackResult.VALID;
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
        const r: audio.AudioRenderer = await audio.createAudioRenderer(options);
        r.on('writeData', (buf: ArrayBuffer) => this.handleWriteData(buf));
        this.renderer = r;
        return r;
      } catch (err) {
        await sleep(250);
      }
    }
    throw new Error('createAudioRenderer 失败');
  }

  private async releaseRenderer(): Promise<void> {
    if (this.renderer !== undefined) {
      try {
        this.renderer.off('writeData');
      } catch (err) {
        // 忽略
      }
      try {
        await this.renderer.stop();
        await this.renderer.release();
      } catch (err) {
        // 已经停/释放过
      }
      this.renderer = undefined;
    }
  }

  // ---- 控制 ----

  async play(): Promise<void> {
    if (!this.hasData()) {
      return;
    }
    try {
      const r: audio.AudioRenderer = await this.ensureRenderer();
      await r.start();
      this.playing = true;
      this.paused = false;
      this.tailSent = false;
      this.reanchor();
      this.emitWordAtPosition();
      this.startTimers();
    } catch (err) {
      if (this.cb.onError !== undefined) {
        this.cb.onError('播放失败: ' + JSON.stringify(err));
      }
    }
  }

  async pause(): Promise<void> {
    if (this.renderer === undefined || this.paused) {
      return;
    }
    await this.renderer.pause();
    this.paused = true;
    this.stopTimers();
  }

  async resume(): Promise<void> {
    if (this.renderer === undefined || !this.paused) {
      return;
    }
    await this.renderer.start();
    this.paused = false;
    this.reanchor();
    this.startTimers();
  }

  async toggle(): Promise<void> {
    if (this.paused) {
      await this.resume();
    } else if (this.playing) {
      await this.pause();
    } else {
      await this.play();
    }
  }

  /** 跳转到指定毫秒；播放中则继续播，否则只更新位置 */
  async seekTo(ms: number): Promise<void> {
    const wasPlaying: boolean = this.playing && !this.paused;
    this.playing = false;
    this.paused = false;
    this.stopTimers();
    await this.releaseRenderer();
    await sleep(250);            // release 后立刻 create 会报 6800301
    this.baseMs = Math.max(0, Math.min(Math.floor(ms), this.totalMs()));
    this.byteOffset = this.baseMs * BYTES_PER_MS;
    this.tailSent = false;
    this.anchorValid = false;
    this.activeIndex = -1;
    this.emitWordAtPosition();
    if (this.cb.onPosition !== undefined) {
      this.cb.onPosition(this.baseMs);
    }
    if (wasPlaying) {
      await this.play();
    }
  }

  /** 重播：从 0 开始 */
  async replay(): Promise<void> {
    this.playing = false;
    this.paused = false;
    this.stopTimers();
    await this.releaseRenderer();
    await sleep(250);
    this.baseMs = 0;
    this.byteOffset = 0;
    this.anchorValid = false;
    this.activeIndex = -1;
    await this.play();
  }

  async release(): Promise<void> {
    this.playing = false;
    this.paused = false;
    this.stopTimers();
    await this.releaseRenderer();
  }

  // ---- 计时器：位置刷新 + 逐词调度 ----

  private startTimers(): void {
    this.stopTimers();
    this.posTimer = setInterval(() => {
      const ms: number = Math.floor(this.positionMs());
      if (this.cb.onPosition !== undefined) {
        this.cb.onPosition(ms);
      }
      // 尾部已送完且位置到达结尾 → 结束
      if (this.tailSent && ms >= this.totalMs() - 30) {
        this.stopTimers();
        this.playing = false;
        this.paused = false;
        if (this.cb.onEnded !== undefined) {
          this.cb.onEnded();
        }
      }
    }, 200);
    this.scheduleNext();
  }

  private stopTimers(): void {
    if (this.posTimer >= 0) {
      clearInterval(this.posTimer);
      this.posTimer = -1;
    }
    if (this.schedTimer >= 0) {
      clearTimeout(this.schedTimer);
      this.schedTimer = -1;
    }
  }

  /** 只给「下一个词」定闹钟；每次触发重读 framePos，误差不累积 */
  private scheduleNext(): void {
    if (this.schedTimer >= 0) {
      clearTimeout(this.schedTimer);
      this.schedTimer = -1;
    }
    if (!this.playing || this.paused || this.cb.onWord === undefined) {
      return;
    }
    this.reanchor();
    const pos: number = this.positionMs();
    const idx: number = indexAt(this.words, pos);
    if (idx !== this.activeIndex) {
      this.activeIndex = idx;
      if (idx >= 0 && this.cb.onWord !== undefined) {
        this.cb.onWord(idx);
      }
    }
    const next: number = idx + 1;
    if (next >= this.words.length) {
      return;
    }
    const delay: number = this.words[next].begin - pos;
    this.schedTimer = setTimeout(() => {
      this.schedTimer = -1;
      this.scheduleNext();
    }, Math.max(3, delay));
  }
}
