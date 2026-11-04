/**
 * 语音提问解析（CQR）：把「用户的一段录音 + 当前句」交给百炼 Omni，
 * 只让它回答一件事——**用户到底在问什么**（一句中文）。
 *
 * 为什么只输出一个问题描述：
 *   - `surface`（问的片段）主 Agent 自己能从课文里判断，让模型复制一遍纯属浪费；
 *   - `intent`（释义/用法/语法…）主 Agent 也能从问题本身判断；
 *   - 所以契约退化成一个字符串，连 JSON 都不需要。
 *
 * 依据 validation/B0C 已验证的请求形态：
 *   POST https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions
 *   model = qwen3.8-omni-flash
 *   content = [ {type:'text', text}, {type:'input_audio', input_audio:{data:'data:audio/wav;base64,...', format:'wav'}} ]
 *   modalities = ['text'], enable_thinking = false（关思考，见 D46）
 */
import { http } from '@kit.NetworkKit';

const ENDPOINT: string = 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';
const MODEL: string = 'qwen3.8-omni-flash';

const SYSTEM: string =
  '你在听一段英语课文朗读中的语音提问。用一句中文说清用户在问什么。';

interface InputAudio {
  data: string;
  format: string;
}

interface AudioPart {
  type: string;
  input_audio?: InputAudio;
}

interface TextPart {
  type: string;
  text: string;
}

interface OmniMessage {
  role: string;
  content: Object[];
}

interface OmniBody {
  model: string;
  messages: OmniMessage[];
  modalities: string[];
  /** 关闭思考（Qwen3.8-Omni-Flash 默认开思考，思考 token 按输出计费，实测一个 3 秒音频能烧 400+ 个） */
  enable_thinking: boolean;
  stream: boolean;
}

interface OmniUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  completion_tokens_details?: ReasoningDetails;
}

interface ReasoningDetails {
  reasoning_tokens?: number;
}

interface OmniMessage2 {
  content?: string;
}

interface OmniChoice {
  message?: OmniMessage2;
}

interface OmniResponse {
  choices?: OmniChoice[];
  usage?: OmniUsage;
}

export class CqrParser {
  private apiKey: string;

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  /**
   * @param wavBase64 不含 data: 前缀的 wav 音频
   * @param currentSentence 用户当前所在句（帮它理解「这个/这句」）
   * @returns 用户问题的一句话描述；听不清时返回空串
   *
   * 不再传「当前词」（D45）：用户可能问这一句里的任何词，给了当前词反而诱导模型
   * 把问题往那个词上靠。句级上下文足够消解「这个/它」这类指代。
   */
  async parse(wavBase64: string, currentSentence: string): Promise<string> {
    const ctx: string = '当前句：' + currentSentence;
    const prompt: string = SYSTEM + '\n\n' + ctx;

    const audio: InputAudio = {
      data: 'data:audio/wav;base64,' + wavBase64,
      format: 'wav'
    };
    const audioPart: AudioPart = { type: 'input_audio', input_audio: audio };
    const textPart: TextPart = { type: 'text', text: prompt };
    const content: Object[] = [textPart, audioPart];

    const body: OmniBody = {
      model: MODEL,
      messages: [{ role: 'user', content: content }],
      modalities: ['text'],
      enable_thinking: false,
      stream: false
    };

    const request = http.createHttp();
    try {
      const resp = await request.request(ENDPOINT, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + this.apiKey
        },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 120000
      });
      if (resp.responseCode !== 200) {
        throw new Error('HTTP ' + resp.responseCode + ': ' + (resp.result as string).substring(0, 200));
      }
      const parsed: OmniResponse = JSON.parse(resp.result as string) as OmniResponse;
      const u: OmniUsage | undefined = parsed.usage;
      if (u !== undefined) {
        const rd: ReasoningDetails | undefined = u.completion_tokens_details;
        const rt: number = rd !== undefined && rd.reasoning_tokens !== undefined ? rd.reasoning_tokens : 0;
        console.info('[cqr] prompt=' + String(u.prompt_tokens) + ' completion=' + String(u.completion_tokens) +
          ' reasoning=' + String(rt));
      }
      const choices: OmniChoice[] = parsed.choices !== undefined ? parsed.choices : [];
      if (choices.length === 0 || choices[0].message === undefined) {
        return '';
      }
      const raw: string = choices[0].message!.content !== undefined ? choices[0].message!.content! : '';
      return raw.trim();
    } finally {
      request.destroy();
    }
  }
}
