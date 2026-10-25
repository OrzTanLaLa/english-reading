/**
 * Qwen-Audio-TTS 适配器 —— **HTTP + SSE 流式**（decisions D29 / D35）。
 *
 * 之前用的是 HarmonyOS 的 `neonui` WebSocket SDK，实测长文本会“偷工”：
 * 5200 字符只回 137 秒音频（正常应 330 秒左右），且词时间戳被均分成每词 ~88ms。
 * 换成官方 HTTP 接口后，短样本 57 字符 → 3.6 秒音频、词时长正常变化。
 *
 * 契约（官方 `model-studio/qwen-audio-tts-http-api`）：
 *   POST https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer
 *   Authorization: Bearer <key>
 *   Content-Type: application/json
 *   X-DashScope-SSE: enable              ← 流式就靠这个头
 *   {"model": ..., "input": {"text","voice","format":"pcm","sample_rate":16000,
 *                            "word_timestamp_enabled":true,"language_hints":["en"]}}
 *
 * SSE 响应（`text/event-stream`）：每帧一行 `data: {json}`，帧之间是空行。
 *   output.type = sentence-begin / sentence-synthesis / sentence-end
 *   output.audio.data = **base64 编码的 PCM**（流式才有；非流式给 audio.url）
 *   output.sentence.words[] = {text, begin_time, end_time}
 *   sentence-end 帧还带 usage{characters, tokens}
 *
 * 注意：`sentence-begin` 帧里的 words 可能只给一部分，**以 `sentence-end` 为准**。
 */
import { http } from '@kit.NetworkKit';
import { buffer, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const TTS_URL: string = 'https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer';
const MODEL: string = 'qwen-audio-3.1-tts-flash';
const SAMPLE_RATE: number = 16000;
/** 整篇一次合成，长课文要等；readTimeout 是「从请求开始到结束」的总时长 */
const READ_TIMEOUT_MS: number = 300000;

export interface WordTiming {
  text: string;
  begin: number;
  end: number;
}

/** 一个服务端分块的区间与原文文本 */
export interface SentenceTiming {
  index: number;
  text: string;
  begin: number;
  end: number;
}

export interface TtsResult {
  pcm: ArrayBuffer;
  words: WordTiming[];
  /** 调试：每个 SSE 帧的摘要（不含 base64 音频，避免文件过大） */
  rawEvents: string[];
  /** 调试：每帧音频的字节数 */
  chunkSizes: number[];
  sentences: SentenceTiming[];
  firstPacketMs: number;
  totalMs: number;
  inputTokens: number;
  outputTokens: number;
}

export interface TtsCallbacks {
  onAudio?: (chunk: ArrayBuffer) => void;
  onWords?: (words: WordTiming[]) => void;
}

// ---- SSE 帧里的 JSON 结构（只声明用得到的字段） ----

interface SseWord {
  text: string;
  begin_time: number;
  end_time: number;
}

interface SseSentence {
  index?: number;
  words?: SseWord[];
}

interface SseAudio {
  data?: string;
  url?: string;
}

interface SseOutput {
  type?: string;
  sentence?: SseSentence;
  original_text?: string;
  audio?: SseAudio;
}

interface SseUsage {
  characters?: number;
  input_tokens?: number;
  output_tokens?: number;
}

interface SseFrame {
  output?: SseOutput;
  usage?: SseUsage;
  code?: string;
  message?: string;
}

interface TtsInput {
  text: string;
  voice: string;
  format: string;
  sample_rate: number;
  word_timestamp_enabled: boolean;
  language_hints: string[];
}

interface TtsRequestBody {
  model: string;
  input: TtsInput;
}

export class QwenTts {
  private apiKey: string;
  private voice: string;

  constructor(apiKey: string, voice: string) {
    this.apiKey = apiKey;
    this.voice = voice;
  }

  /**
   * 合成前的文本清洗：**把破折号类字符换成逗号**。
   *
   * 依据：官方 `qwen-audio-tts-http-api` 没有给出「支持哪些标点」的清单，只给了两条兜底手段：
   *   - `hot_fix`：当数字、缩写、**符号**读法不符合预期时（文档例子是 "@" 读成"艾特"而非 "at"）；
   *   - `language_hints`：指定合成目标语言。
   * 实测 em dash `—`（U+2014）会被吞掉/断句异常，所以统一在发请求前换成 `, `。
   * 覆盖：em dash、en dash、figure dash、horizontal bar、minus sign（不含单词内的连字符 `-`）。
   */
  static normalizeForTts(text: string): string {
    return text
      .replace(/[\u2014\u2013\u2012\u2015\u2212]+/g, ', ')
      .replace(/,\s*,/g, ',')          // 连续破折号只留一个逗号
      .replace(/[ \t]{2,}/g, ' ')      // 收拾多余空格
      .replace(/\s+([,.;:!?])/g, '$1') // 标点前不留空格
      .trim();
  }

  synthesize(rawText: string, cb: TtsCallbacks): Promise<TtsResult> {
    const text: string = QwenTts.normalizeForTts(rawText);
    return new Promise<TtsResult>((resolve: (r: TtsResult) => void, reject: (e: Error) => void) => {
      const t0: number = Date.now();
      const req: http.HttpRequest = http.createHttp();
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const body: TtsRequestBody = {
        model: MODEL,
        input: {
          text: text,
          voice: this.voice,
          format: 'pcm',
          sample_rate: SAMPLE_RATE,
          word_timestamp_enabled: true,
          language_hints: ['en']
        }
      };

      let pending: string = '';
      const audioChunks: ArrayBuffer[] = [];
      const chunkSizes: number[] = [];
      const rawEvents: string[] = [];
      /** 分块序号 → 词表（后来者覆盖；sentence-end 是最终值） */
      const wordsByIndex: Map<number, WordTiming[]> = new Map<number, WordTiming[]>();
      const textByIndex: Map<number, string> = new Map<number, string>();
      let firstPacketMs: number = -1;
      let finished: boolean = false;

      const cleanup = (): void => {
        try {
          req.off('dataReceive');
          req.off('dataEnd');
          req.destroy();
        } catch (e) {
          // 忽略
        }
      };

      const finish = (failMsg: string): void => {
        if (finished) {
          return;
        }
        finished = true;
        cleanup();
        if (failMsg.length > 0) {
          reject(new Error(failMsg));
          return;
        }
        const words: WordTiming[] = QwenTts.flattenWords(wordsByIndex);
        const pcm: ArrayBuffer = QwenTts.concat(audioChunks);
        if (words.length === 0 || pcm.byteLength === 0) {
          reject(new Error('合成返回为空（词 ' + words.length + ' 个，音频 ' + pcm.byteLength + ' 字节）'));
          return;
        }
        if (cb.onWords !== undefined) {
          cb.onWords(words);
        }
        resolve({
          pcm: pcm,
          words: words,
          rawEvents: rawEvents,
          chunkSizes: chunkSizes,
          sentences: QwenTts.spans(wordsByIndex, textByIndex),
          firstPacketMs: firstPacketMs,
          totalMs: Date.now() - t0,
          inputTokens: 0,
          outputTokens: 0
        });
      };

      /** 处理一帧 SSE 的 data 负载 */
      const handlePayload = (payload: string): void => {
        let frame: SseFrame;
        try {
          frame = JSON.parse(payload) as SseFrame;
        } catch (e) {
          return;
        }
        if (frame.code !== undefined && frame.code !== '') {
          return;
        }
        const out: SseOutput | undefined = frame.output;
        if (out === undefined) {
          return;
        }
        const type: string = out.type === undefined ? '' : out.type;
        const sentence: SseSentence | undefined = out.sentence;
        const index: number = sentence !== undefined && sentence.index !== undefined
          ? sentence.index : wordsByIndex.size;
        const ws: SseWord[] = sentence !== undefined && sentence.words !== undefined ? sentence.words : [];
        const words: WordTiming[] = [];
        for (let i = 0; i < ws.length; i++) {
          words.push({ text: ws[i].text, begin: ws[i].begin_time, end: ws[i].end_time });
        }
        if (words.length > 0) {
          wordsByIndex.set(index, words);
        }
        if (out.original_text !== undefined && out.original_text.length > 0) {
          textByIndex.set(index, out.original_text);
        }
        // 音频：base64 → 字节
        let audioLen: number = 0;
        const b64: string | undefined = out.audio !== undefined ? out.audio.data : undefined;
        if (b64 !== undefined && b64.length > 0) {
          const chunk: ArrayBuffer = buffer.from(b64, 'base64').buffer;
          audioChunks.push(chunk);
          audioLen = chunk.byteLength;
          chunkSizes.push(audioLen);
          if (firstPacketMs < 0) {
            firstPacketMs = Date.now() - t0;
          }
          if (cb.onAudio !== undefined) {
            cb.onAudio(chunk);
          }
        }
        if (rawEvents.length < 2000) {
          rawEvents.push(type + '|idx=' + index + '|words=' + words.length + '|audio=' + audioLen);
        }
      };

      /** 从累积文本里切出完整的 SSE 帧 */
      const drainFrames = (): void => {
        while (true) {
          const cut: number = pending.indexOf('\n\n');
          if (cut < 0) {
            return;
          }
          const block: string = pending.substring(0, cut);
          pending = pending.substring(cut + 2);
          const lines: string[] = block.split('\n');
          let payload: string = '';
          for (let i = 0; i < lines.length; i++) {
            const line: string = lines[i];
            if (line.startsWith('data:')) {
              payload += line.substring(5).trim();
            }
          }
          if (payload.length > 0) {
            handlePayload(payload);
          }
        }
      };

      req.on('dataReceive', (data: ArrayBuffer) => {
        // 多字节字符可能被切在两个分片之间，用流式解码
        pending += decoder.decodeWithStream(new Uint8Array(data), { stream: true });
        drainFrames();
      });

      req.on('dataEnd', () => {
        pending += decoder.decodeWithStream(new Uint8Array(0), { stream: false });
        drainFrames();
        finish('');
      });

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': 'Bearer ' + this.apiKey,
          'Content-Type': 'application/json',
          'X-DashScope-SSE': 'enable'
        },
        extraData: JSON.stringify(body),
        connectTimeout: 15000,
        readTimeout: READ_TIMEOUT_MS
      };

      req.requestInStream(TTS_URL, options).then((code: number) => {
        if (code !== 200) {
          finish('HTTP ' + code);
        }
      }).catch((err: BusinessError) => {
        finish('请求失败: ' + (err.message === undefined ? String(err) : err.message));
      });
    });
  }

  /** 按块序拼词表；若某块时间戳从 0 重新计时，则整体平移到上一块之后 */
  private static flattenWords(byIndex: Map<number, WordTiming[]>): WordTiming[] {
    const keys: number[] = Array.from(byIndex.keys()).sort((a: number, b: number) => a - b);
    const out: WordTiming[] = [];
    let lastEnd: number = 0;
    for (let k = 0; k < keys.length; k++) {
      const list: WordTiming[] | undefined = byIndex.get(keys[k]);
      if (list === undefined || list.length === 0) {
        continue;
      }
      let shift: number = 0;
      if (list[0].begin < lastEnd - 200) {
        shift = lastEnd - list[0].begin;
      }
      for (let i = 0; i < list.length; i++) {
        out.push({ text: list[i].text, begin: list[i].begin + shift, end: list[i].end + shift });
      }
      lastEnd = out[out.length - 1].end;
    }
    return out;
  }

  private static spans(byIndex: Map<number, WordTiming[]>, texts: Map<number, string>): SentenceTiming[] {
    const keys: number[] = Array.from(byIndex.keys()).sort((a: number, b: number) => a - b);
    const out: SentenceTiming[] = [];
    for (let k = 0; k < keys.length; k++) {
      const list: WordTiming[] | undefined = byIndex.get(keys[k]);
      if (list === undefined || list.length === 0) {
        continue;
      }
      const text: string | undefined = texts.get(keys[k]);
      out.push({
        index: keys[k],
        text: text === undefined ? '' : text,
        begin: list[0].begin,
        end: list[list.length - 1].end
      });
    }
    return out;
  }

  private static concat(chunks: ArrayBuffer[]): ArrayBuffer {
    let total: number = 0;
    for (let i = 0; i < chunks.length; i++) {
      total += chunks[i].byteLength;
    }
    const out: ArrayBuffer = new ArrayBuffer(total);
    const view: Uint8Array = new Uint8Array(out);
    let at: number = 0;
    for (let i = 0; i < chunks.length; i++) {
      view.set(new Uint8Array(chunks[i]), at);
      at += chunks[i].byteLength;
    }
    return out;
  }
}
