/**
 * 生语汇（YAML）：根节点是**序列**，每个元素是**映射**。
 *
 * 键（顺序固定）：类型 / 单词 / 搭配 / 语境 / 问题 / 回答
 *
 * ```yaml
 * - 类型: '搭配'
 *   单词: ['stumble', 'upon']
 *   搭配: 'stumble upon'
 *   语境: '...读法里的当前句...'
 *   问题: 'stumble upon 什么意思'
 *   回答: '...'
 * ```
 *
 * 形状规则（decisions D32 + T7）：
 *   - 单词：`单词` 是**字符串**（这个词本身），没有 `搭配`；
 *   - 搭配：`单词` 是**序列**（搭配里所有词），`搭配` 是搭配本身；
 *   - 其他：两个键都不出现。
 *
 * 分工：**模型只吐 JSON**（`type` / `answer` / `word?` / `words+phrase?`，见 `parseReply`）；
 * `语境` / `问题` 由应用补齐（本来就在手里，让模型抄只会抄错）。
 *
 * 标量一律**单引号**（`'` 转义成 `''`），换行压成空格：人可读、解析简单、不引第三方库。
 */
export const KIND_WORD: string = '单词';
export const KIND_COLLOCATION: string = '搭配';
export const KIND_OTHER: string = '其他';

export interface VocabEntry {
  kind: string;
  words: string[];
  phrase: string;
  context: string;
  question: string;
  answer: string;
}

/** 模型回复解析出来的部分（不含语境/问题） */
export interface AnswerReply {
  kind: string;
  words: string[];
  phrase: string;
  answer: string;
}

const KEY_KIND: string = '类型';
const KEY_WORDS: string = '单词';
const KEY_PHRASE: string = '搭配';
const KEY_CONTEXT: string = '语境';
const KEY_QUESTION: string = '问题';
const KEY_ANSWER: string = '回答';

/** 换行/回车压成空格，去首尾空白 */
function flat(s: string): string {
  return s.replace(/\r/g, ' ').replace(/\n+/g, ' ').trim();
}

/** YAML 单引号标量 */
function quote(s: string): string {
  return "'" + flat(s).replace(/'/g, "''") + "'";
}

function unquote(s: string): string {
  let t: string = s.trim();
  if (t.length >= 2 && t.charAt(0) === '\'' && t.charAt(t.length - 1) === '\'') {
    return t.substring(1, t.length - 1).replace(/''/g, '\'');
  }
  if (t.length >= 2 && t.charAt(0) === '"' && t.charAt(t.length - 1) === '"') {
    return t.substring(1, t.length - 1).replace(/\\"/g, '"');
  }
  return t;
}

/** 找「键: 值」的分隔位置（全角半角冒号都认），返回 [键, 值] */
function splitKeyValue(line: string): string[] | undefined {
  let idx: number = line.indexOf(': ');
  if (idx < 0) {
    idx = line.indexOf('：');
    if (idx < 0) {
      idx = line.indexOf(':');
    }
  }
  if (idx <= 0) {
    return undefined;
  }
  return [line.substring(0, idx).trim(), line.substring(idx + 1).trim()];
}

/** 认识的键 → 统一名 */
function normalizeKey(raw: string): string {
  const k: string = raw.trim();
  const low: string = k.toLowerCase();
  if (k === KEY_KIND || low === 'kind' || low === 'type') {
    return KEY_KIND;
  }
  if (k === KEY_WORDS || low === 'word' || low === 'words') {
    return KEY_WORDS;
  }
  if (k === KEY_PHRASE || low === 'phrase' || low === 'collocation') {
    return KEY_PHRASE;
  }
  if (k === KEY_CONTEXT || low === 'context') {
    return KEY_CONTEXT;
  }
  if (k === KEY_QUESTION || low === 'question') {
    return KEY_QUESTION;
  }
  if (k === KEY_ANSWER || low === 'answer') {
    return KEY_ANSWER;
  }
  return '';
}

/** 把模型可能写的各种类型说法归一到三种 */
export function normalizeKind(raw: string): string {
  const s: string = raw.trim();
  if (s.length === 0) {
    return KIND_OTHER;
  }
  if (s.indexOf('单词') >= 0 || s === '词' || s.toLowerCase() === 'word') {
    return KIND_WORD;
  }
  if (s.indexOf('搭配') >= 0 || s.indexOf('短语') >= 0 || s.indexOf('词组') >= 0 ||
    s.toLowerCase() === 'collocation' || s.toLowerCase() === 'phrase') {
    return KIND_COLLOCATION;
  }
  return KIND_OTHER;
}

/** 流式序列 `[a, b]` → 数组；不是流式就返回 undefined */
function parseFlowSeq(value: string): string[] | undefined {
  const t: string = value.trim();
  if (t.length < 2 || t.charAt(0) !== '[' || t.charAt(t.length - 1) !== ']') {
    return undefined;
  }
  const inner: string = t.substring(1, t.length - 1).trim();
  const out: string[] = [];
  if (inner.length === 0) {
    return out;
  }
  const parts: string[] = inner.split(',');
  for (let i = 0; i < parts.length; i++) {
    const w: string = unquote(parts[i]);
    if (w.length > 0) {
      out.push(w);
    }
  }
  return out;
}

/** 一条记录 → YAML 块（含行首 "- "） */
export function entryBlock(e: VocabEntry): string {
  let out: string = '- ' + KEY_KIND + ': ' + quote(e.kind) + '\n';
  if (e.words.length > 1) {
    // 搭配：序列
    let seq: string = '[';
    for (let i = 0; i < e.words.length; i++) {
      seq += (i > 0 ? ', ' : '') + quote(e.words[i]);
    }
    seq += ']';
    out += '  ' + KEY_WORDS + ': ' + seq + '\n';
  } else if (e.words.length === 1) {
    out += '  ' + KEY_WORDS + ': ' + quote(e.words[0]) + '\n';
  }
  if (e.phrase.length > 0) {
    out += '  ' + KEY_PHRASE + ': ' + quote(e.phrase) + '\n';
  }
  out += '  ' + KEY_CONTEXT + ': ' + quote(e.context) + '\n';
  out += '  ' + KEY_QUESTION + ': ' + quote(e.question) + '\n';
  out += '  ' + KEY_ANSWER + ': ' + quote(e.answer) + '\n';
  return out;
}

/** 解析我们自己的文件（序列 of 映射） */
export function parseEntries(yaml: string): VocabEntry[] {
  const out: VocabEntry[] = [];
  if (yaml.trim().length === 0) {
    return out;
  }
  const lines: string[] = yaml.split('\n');
  let cur: VocabEntry | undefined = undefined;
  let lastKey: string = '';
  for (let i = 0; i < lines.length; i++) {
    const raw: string = lines[i];
    const t: string = raw.trim();
    if (t.length === 0) {
      continue;
    }
    // 只有**顶格**的 "- " 才是新记录；块式序列项是缩进的
    const indent: number = raw.length - raw.trimStart().length;
    const isNew: boolean = indent === 0 && t.charAt(0) === '-';
    const body: string = isNew ? t.substring(1).trim() : t;
    // 块式序列项：单词 的后续行
    if (!isNew && t.charAt(0) === '-' && lastKey === KEY_WORDS && cur !== undefined) {
      const w: string = unquote(t.substring(1).trim());
      if (w.length > 0) {
        cur.words.push(w);
      }
      continue;
    }
    const kv: string[] | undefined = splitKeyValue(body);
    if (kv === undefined) {
      continue;
    }
    const key: string = normalizeKey(kv[0]);
    if (isNew) {
      cur = { kind: '', words: [], phrase: '', context: '', question: '', answer: '' };
      out.push(cur);
    }
    if (cur === undefined) {
      continue;
    }
    if (key.length === 0) {
      continue;
    }
    lastKey = key;
    const v: string = kv[1];
    if (key === KEY_KIND) {
      cur.kind = normalizeKind(unquote(v));
    } else if (key === KEY_WORDS) {
      const flow: string[] | undefined = parseFlowSeq(v);
      if (flow !== undefined) {
        cur.words = flow;
      } else if (v.length > 0) {
        cur.words = [unquote(v)];
      }
    } else if (key === KEY_PHRASE) {
      cur.phrase = unquote(v);
    } else if (key === KEY_CONTEXT) {
      cur.context = unquote(v);
    } else if (key === KEY_QUESTION) {
      cur.question = unquote(v);
    } else if (key === KEY_ANSWER) {
      cur.answer = unquote(v);
    }
  }
  return out;
}

/** 追加一条；已存在「问题 + 语境」相同的记录则原样返回（幂等） */
export function appendEntry(existing: string, e: VocabEntry): string {
  const list: VocabEntry[] = parseEntries(existing);
  for (let i = 0; i < list.length; i++) {
    if (list[i].question === e.question && list[i].context === e.context) {
      return existing;
    }
  }
  const head: string = existing.trim().length > 0 ? existing.trimEnd() + '\n' : '';
  return head + entryBlock(e);
}

/** 模型回复的 JSON 形状（英文键，避免中文标识符） */
interface ReplyJson {
  type?: string;
  word?: string;
  words?: string[];
  phrase?: string;
  answer?: string;
}

/**
 * 解析模型回复。
 *
 * 约定是 **JSON**（`response_format=json_object`，官方保证合法）：
 * `{"type":"collocation","words":["tuck","away"],"phrase":"tucked away","answer":"…"}`
 *
 * 仍然兜底：去掉 ```json 围栏、只截取第一个 `{` 到最后一个 `}`；解析失败 → 「其他」+ 空回答。
 */
export function parseReply(raw: string): AnswerReply {
  const text: string = raw.replace(/```json/gi, '').replace(/```/g, '').trim();
  let body: string = text;
  const l: number = text.indexOf('{');
  const r: number = text.lastIndexOf('}');
  if (l >= 0 && r > l) {
    body = text.substring(l, r + 1);
  }
  let obj: ReplyJson | undefined = undefined;
  try {
    obj = JSON.parse(body) as ReplyJson;
  } catch (err) {
    obj = undefined;
  }
  if (obj === undefined) {
    return { kind: KIND_OTHER, words: [], phrase: '', answer: '' };
  }
  let words: string[] = [];
  if (obj.words !== undefined && obj.words.length > 0) {
    for (let i = 0; i < obj.words.length; i++) {
      const w: string = String(obj.words[i]).trim();
      if (w.length > 0) {
        words.push(w);
      }
    }
  } else if (obj.word !== undefined && String(obj.word).trim().length > 0) {
    words = [String(obj.word).trim()];
  }
  return {
    kind: normalizeKind(obj.type === undefined ? '' : String(obj.type)),
    words: words,
    phrase: obj.phrase === undefined ? '' : String(obj.phrase).trim(),
    answer: obj.answer === undefined ? '' : flat(String(obj.answer))
  };
}

/**
 * 解析**旧格式** `glossary.txt`（迁移用）。格式来自已废弃的 append_vocabulary：
 *
 * ```
 * ===== tucked away =====
 * kind: collocation
 * phonetic: /.../        （可选）
 * meaning: 收起来、塞在（某处）
 * context: Whenever I look through ...
 * question: tuck什么意思
 * ---
 * ```
 *
 * 映射到新结构：surface→单词/搭配、meaning→回答、context→语境、question→问题；
 * `phonetic` 新结构没有槽位，**丢弃**（调用方把它记进迁移日志）。
 */
export function parseLegacyTxt(raw: string): VocabEntry[] {
  const out: VocabEntry[] = [];
  if (raw.trim().length === 0) {
    return out;
  }
  const text: string = raw.replace(/\uFEFF/g, '').replace(/\r/g, '');
  const blocks: string[] = text.split(/^---\s*$/m);
  for (let b = 0; b < blocks.length; b++) {
    const lines: string[] = blocks[b].split('\n');
    let surface: string = '';
    let kind: string = '';
    let meaning: string = '';
    let context: string = '';
    let question: string = '';
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const head: RegExpMatchArray | null = line.match(/^=+\s*(.+?)\s*=+$/);
      if (head !== null) {
        surface = head[1].trim();
        continue;
      }
      const kv: string[] | undefined = splitKeyValue(line);
      if (kv === undefined) {
        continue;
      }
      if (kv[0] === 'kind') {
        kind = kv[1];
      } else if (kv[0] === 'meaning') {
        meaning = kv[1];
      } else if (kv[0] === 'context') {
        context = kv[1];
      } else if (kv[0] === 'question') {
        question = kv[1];
      }
    }
    if (surface.length === 0 && meaning.length === 0) {
      continue;
    }
    let normalized: string = KIND_OTHER;
    const lower: string = kind.toLowerCase();
    if (lower === 'word' || kind.indexOf('单词') >= 0) {
      normalized = KIND_WORD;
    } else if (lower === 'collocation' || lower === 'phrase' || kind.indexOf('搭配') >= 0) {
      normalized = KIND_COLLOCATION;
    }
    let words: string[] = [];
    let phrase: string = '';
    if (normalized === KIND_WORD) {
      words = surface.length > 0 ? [surface] : [];
    } else if (normalized === KIND_COLLOCATION) {
      phrase = surface;
      words = surface.split(/\s+/).filter((w: string) => w.length > 0);
    }
    out.push({
      kind: normalized,
      words: words,
      phrase: phrase,
      context: context,
      question: question,
      answer: meaning
    });
  }
  return out;
}

/** 用「模型给的部分 + 应用手里的语境/问题」拼一条完整记录 */
export function buildEntry(reply: AnswerReply, context: string, question: string): VocabEntry {
  let words: string[] = reply.words;
  let phrase: string = reply.phrase;
  if (reply.kind === KIND_WORD) {
    words = words.length > 0 ? [words[0]] : (phrase.length > 0 ? [phrase] : []);
    phrase = '';
  } else if (reply.kind === KIND_COLLOCATION) {
    // 模型可能把序列写成 `tuck, away` 或 `tuck away`，而不是 `[tuck, away]`：
    // 单词本身不含逗号/空格，所以这里直接拆。
    if (words.length === 1) {
      const parts: string[] = words[0].split(/[,，、\s]+/);
      const split: string[] = [];
      for (let i = 0; i < parts.length; i++) {
        const w: string = parts[i].trim();
        if (w.length > 0) {
          split.push(w);
        }
      }
      if (split.length > 0) {
        words = split;
      }
    }
    if (phrase.length === 0) {
      phrase = words.join(' ');
    }
    if (words.length === 0 && phrase.length > 0) {
      words = phrase.split(' ');
    }
  } else {
    words = [];
    phrase = '';
  }
  return {
    kind: reply.kind,
    words: words,
    phrase: phrase,
    context: context,
    question: question,
    answer: reply.answer
  };
}
