/**
 * 阅读器的纯逻辑：词表查找、句子切分、词干拆分、文本清洗。
 *
 * 不碰 UI、不碰文件，方便单测；页面与播放器都复用这里。
 */

export interface WordTiming {
  text: string;
  begin: number;
  end: number;
}

/** 二分查找：最后一个 begin <= ms 的词下标；没有则 -1 */
export function indexAt(words: WordTiming[], ms: number): number {
  let lo: number = 0;
  let hi: number = words.length - 1;
  let ans: number = -1;
  while (lo <= hi) {
    const mid: number = (lo + hi) >> 1;
    if (words[mid].begin <= ms) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

/**
 * 按标点与停顿把词切成句，返回每个词所属的句号（从 0 开始）。
 * 词条里可能连着标点（"persistence.It"），所以用「包含」而不是「结尾」判断。
 */
export function buildSentenceIds(words: WordTiming[]): number[] {
  const ids: number[] = [];
  let cur: number = 0;
  for (let i = 0; i < words.length; i++) {
    ids.push(cur);
    const t: string = words[i].text.trim();
    const ends: boolean = t.indexOf('.') >= 0 || t.indexOf('!') >= 0 || t.indexOf('?') >= 0;
    const gap: number = i + 1 < words.length ? words[i + 1].begin - words[i].end : 0;
    if (ends || gap > 300) {
      cur++;
    }
  }
  return ids;
}

/** 某一句的词区间 [start, end) */
export function sentenceRange(ids: number[], sent: number): number[] {
  let start: number = -1;
  let end: number = -1;
  for (let i = 0; i < ids.length; i++) {
    if (ids[i] === sent) {
      if (start < 0) {
        start = i;
      }
      end = i + 1;
    } else if (start >= 0) {
      break;
    }
  }
  return start < 0 ? [0, 0] : [start, end];
}

export function sentenceCount(ids: number[]): number {
  return ids.length === 0 ? 0 : ids[ids.length - 1] + 1;
}

/** 一句话的纯文本（不带高亮），用于列表里非当前句的渲染 */
export function sentenceText(words: WordTiming[], start: number, end: number): string {
  let out: string = '';
  for (let i = start; i < end; i++) {
    out += (i > start ? ' ' : '') + words[i].text.trim();
  }
  return out;
}

export interface WordParts {
  pre: string;
  core: string;
  post: string;
}

/** 拆成「前缀标点 / 词干 / 后缀标点」，只有词干上底色 */
export function splitWord(text: string): WordParts {
  const m: RegExpMatchArray | null = text.match(/^([^A-Za-z0-9]*)([A-Za-z0-9'’]*)([\s\S]*)$/);
  if (m === null) {
    return { pre: '', core: text, post: '' };
  }
  const core: string = m[2].length > 0 ? m[2] : text;
  return { pre: m[1], core: core, post: m[2].length > 0 ? m[3] : '' };
}

/** 清掉控制字符（OCR 结果里偶尔混进），压缩空白 */
export function sanitize(text: string): string {
  let out: string = '';
  for (let i = 0; i < text.length; i++) {
    const c: number = text.charCodeAt(i);
    if (c === 10 || c === 32 || (c >= 33 && c <= 126) || c > 126) {
      out += text.charAt(i);
    }
  }
  return out.replace(/\s+/g, ' ').trim();
}
/**
 * 把 TTS 的词时间戳对齐到**原文**的字符区间。
 *
 * 朗读页不再分句：直接渲染 OCR 原文（保留原始标点与分段），
 * 高亮时按词在原文里的字符位置定位。做法是贪心匹配：
 * 依次在原文里向后找每个词的「词干」（忽略大小写与首尾标点），
 * 找到就记下区间，找不到就跳过（例如 1820 被读成 eighteen twenty）。
 */
export interface WordSpan {
  start: number;
  end: number;
  /** 对应 words 的下标；-1 表示没有对齐上 */
  index: number;
}

/** 去掉首尾非字母数字，返回词干 */
export function wordCore(text: string): string {
  const m: RegExpMatchArray | null = text.match(/[A-Za-z0-9][A-Za-z0-9'’]*/);
  return m === null ? '' : m[0];
}

export function alignWords(text: string, words: WordTiming[]): WordSpan[] {
  const spans: WordSpan[] = [];
  const lower: string = text.toLowerCase();
  let cursor: number = 0;
  for (let i = 0; i < words.length; i++) {
    const core: string = wordCore(words[i].text);
    if (core.length === 0) {
      spans.push({ start: -1, end: -1, index: i });
      continue;
    }
    const at: number = lower.indexOf(core.toLowerCase(), cursor);
    if (at < 0) {
      spans.push({ start: -1, end: -1, index: i });
      continue;
    }
    spans.push({ start: at, end: at + core.length, index: i });
    cursor = at + core.length;
  }
  return spans;
}

/** 原文段落（按空行切分），记录在全文中的字符区间 */
export interface Paragraph {
  start: number;
  end: number;
}

export function splitParagraphs(text: string): Paragraph[] {
  const out: Paragraph[] = [];
  const re: RegExp = /\n\s*\n/g;
  let last: number = 0;
  let m: RegExpExecArray | null = re.exec(text);
  while (m !== null) {
    const seg: string = text.substring(last, m.index);
    if (seg.trim().length > 0) {
      out.push({ start: last, end: m.index });
    }
    last = m.index + m[0].length;
    m = re.exec(text);
  }
  if (last < text.length && text.substring(last).trim().length > 0) {
    out.push({ start: last, end: text.length });
  }
  if (out.length === 0 && text.trim().length > 0) {
    out.push({ start: 0, end: text.length });
  }
  return out;
}