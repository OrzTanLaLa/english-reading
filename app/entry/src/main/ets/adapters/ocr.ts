/**
 * 云 OCR 适配层：把整页照片交给多模态模型，按 <<<PAGE1>>>/<<<PAGE2>>> 标记分页。
 *
 * 为什么不用端侧 Core Vision：
 *   - 双栏会按行交错（L1,R1,L2,R2），对页紧贴时还会在字符级粘成一个词；
 *   - 实测 qwen3-vl-plus 在正对页上精确率 1.000，跨页/横竖反也能正确分页。
 *
 * 提示词里必须写死三件事：只输出文字、不要坐标、按页用标记分隔。
 */
import { http } from '@kit.NetworkKit';

const ENDPOINT: string = 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';
const MODEL: string = 'qwen3-vl-plus';

export const PROMPT: string =
  '逐字转写这张页面照片里的英文正文，只输出图片中真实存在的字符。\n' +
  '严禁改写、补全、翻译或猜测：看不清的字符用 [?] 表示。\n' +
  '\n' +
  '【只转写正文】跳过这些内容：页眉、页脚、页码、水印、扫描阴影；\n' +
  '页面边缘与空白处的注释、批注、生词表、词汇注记、图注与图片说明；\n' +
  '出版社、版权、网址、二维码周围的文字。\n' +
  '单词后面表示「注释出处」的上标编号（如 likely²、travel¹）一律删掉，只留单词本身；\n' +
  '正文里的普通数字（如 1990s、1820）保持不变。\n' +
  '去掉段首的段落编号/序号：数字（1、2、11、1.、2)）、英文数词（One、Two、Three…）、罗马数字（I.、II.）\n' +
  '以及圆圈数字（①、②）都不要输出；只保留段落正文的第一个词。\n' +
  '注意：段内的普通数字（1990s、1973、10,287）照原样保留，不要动。\n' +
  '若页面正文区有文章标题，保留标题作为第一段。\n' +
  '\n' +
  '【输出格式，严格】\n' +
  '1) 按语义段落输出：一个段落一段，段落之间必须空一行（不要把几段连成一段）；\n' +
  '2) 段落内部不要换行——把画面里的折行连起来，行与行之间用一个空格连接；\n' +
  '3) 保留原文的大小写、标点与引号，不要加粗、不要标题标记、不要 Markdown；\n' +
  '4) 不要输出任何说明文字、坐标、编号框或结构化标记。\n' +
  '\n' +
  '只输出正文本身。';


/**
 * 去掉段首的段落编号。
 *
 * 课本的段落常写成「1 Every year…」「Two You might notice…」，编号会跟着正文进 TTS（读成 "one"/"two"）。
 * 规则故意保守：
 *   - 阿拉伯数字 / 罗马数字 / 圆圈数字：直接去；
 *   - 英文数词（One…Twelve）：**只有当后面紧跟大写字母**才算编号——
 *     「One day, …」（day 小写）保留，「Two You might…」（You 大写）去掉。
 */
function stripLeadingNumber(text: string): string {
  let t: string = text.replace(/^[\s\u00b7\u2022\-\u2013]*/, '');
  // 圆圈数字 ①-⑳
  t = t.replace(/^[\u2460-\u2473]\s*/, '');
  // 阿拉伯数字：1 / 1. / 1) / 1、 / 11 （后面必须跟空白）
  t = t.replace(/^\d{1,3}\s*[.)\u3001\uff09]?\s+/, '');
  // 罗马数字 I. II. III. IV. V. VI.
  t = t.replace(/^(?:I{1,3}|IV|V|VI)\s*[.)]\s+/, '');
  // 英文数词 + 紧跟大写字母
  t = t.replace(/^(?:One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten|Eleven|Twelve)\s+([A-Z])/,
    '$1');
  return t.trim();
}

/** 段内换行合并成空格；段落之间保留一个空行 */
export function normalizeParagraphs(raw: string): string {
  // 兜底：清除上标注释编号（¹²³⁴⁵⁶⁷⁸⁹⁰ 及 U+2070..2079）——英文正文里几乎不会出现
  const withoutSup: string = raw.replace(/[\u00b9\u00b2\u00b3\u2070-\u2079]/g, '');
  const paras: string[] = withoutSup.split(/\n\s*\n/);
  const out: string[] = [];
  for (const p of paras) {
    const one: string = stripLeadingNumber(p.replace(/\s*\n\s*/g, ' ').trim());
    if (one.length > 0) {
      out.push(one);
    }
  }
  return out.join('\n\n');
}
export interface OcrPage {
  /** 从 1 开始 */
  index: number;
  text: string;
}

interface LlmMessageContent {
  type: string;
  image_url?: ImageUrl;
  text?: string;
}

interface ImageUrl {
  url: string;
}

interface LlmMessage {
  role: string;
  content: LlmMessageContent[];
}

interface LlmRequestBody {
  model: string;
  messages: LlmMessage[];
}

interface LlmResponseContent {
  message: ResponseMessage;
}

interface ResponseMessage {
  content: string;
}

interface LlmResponse {
  choices: LlmResponseContent[];
}

export class CloudOcr {
  private apiKey: string;

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  /** 传入 base64（不含 data: 前缀），返回按页拆好的文本 */
  async recognize(imageBase64: string, mime: string = 'image/jpeg'): Promise<OcrPage[]> {
    const image: ImageUrl = { url: 'data:' + mime + ';base64,' + imageBase64 };
    const parts: LlmMessageContent[] = [
      { type: 'image_url', image_url: image },
      { type: 'text', text: PROMPT }
    ];
    const body: LlmRequestBody = {
      model: MODEL,
      messages: [{ role: 'user', content: parts }]
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
      const parsed: LlmResponse = JSON.parse(resp.result as string) as LlmResponse;
      const text: string = parsed.choices[0].message.content;
      return this.splitPages(text);
    } finally {
      request.destroy();
    }
  }

/** 按 <<<PAGEn>>> 标记拆页；没有标记就当一页 */
  splitPages(raw: string): OcrPage[] {
    const pattern: RegExp = /<<<PAGE(\d+)>>>/g;
    const markerStarts: number[] = [];
    const contentStarts: number[] = [];
    let m: RegExpExecArray | null = pattern.exec(raw);
    while (m !== null) {
      markerStarts.push(m.index);
      contentStarts.push(m.index + m[0].length);
      m = pattern.exec(raw);
    }

    if (markerStarts.length === 0) {
      const only: string = normalizeParagraphs(raw);
      return only.length > 0 ? [{ index: 1, text: only }] : [];
    }

    const pages: OcrPage[] = [];
    for (let i = 0; i < markerStarts.length; i++) {
      const start: number = contentStarts[i];
      const end: number = i + 1 < markerStarts.length ? markerStarts[i + 1] : raw.length;
      const slice: string = normalizeParagraphs(raw.substring(start, end));
      if (slice.length > 0) {
        pages.push({ index: pages.length + 1, text: slice });
      }
    }
    return pages;
  }
}