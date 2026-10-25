/**
 * 英文分句：合成粒度必须落到句。
 *
 * 为什么不能交给 TTS 按长度切：实测 CosyVoice 会按 ~380 字符切 chunk，
 * 切点会落在从句中间（"... more reliably than talent does," | "which is why ..."），
 * 或者把词压成 80ms（"entirely"）。所以先自己分句，每句一次请求。
 *
 * 纯函数、零平台依赖；与 validation/B0B/segment.py 行为一致，
 * 由 scripts/test_segment.mjs 用 Python 产出的 fixture 对拍。
 */

/** 这些缩写里的点是词的一部分，不是句号 */
const PROTECT: string[] = [
  'Mr.', 'Mrs.', 'Ms.', 'Dr.', 'Prof.', 'St.', 'Jr.', 'Sr.', 'vs.', 'etc.',
  'e.g.', 'i.e.', 'cf.', 'al.', 'U.S.', 'U.K.', 'E.U.', 'a.m.', 'p.m.',
  'No.', 'Fig.', 'Inc.', 'Ltd.', 'Jan.', 'Feb.', 'Mar.', 'Apr.', 'Jun.',
  'Jul.', 'Aug.', 'Sep.', 'Oct.', 'Nov.', 'Dec.'
];

const MARK: string = '\u0001';

/** 返回句子列表，保留句末标点 */
export function splitSentences(text: string): string[] {
  const parts: string[] = text.split(/\s+/);
  const kept: string[] = [];
  for (const p of parts) {
    if (p.length > 0) {
      kept.push(p);
    }
  }
  let t: string = kept.join(' ');

  for (const p of PROTECT) {
    t = t.split(p).join(p.replace('.', MARK));
  }

  // 句末标点后可以跟一个引号（something." Daniel），再接空白 + 大写开头
  const pattern: RegExp = /[.!?]+["'”’]?(?=\s+["'“”(]?[A-Z0-9])/g;
  const out: string[] = [];
  let last: number = 0;
  let m: RegExpExecArray | null = pattern.exec(t);
  while (m !== null) {
    const end: number = m.index + m[0].length;
    const piece: string = t.substring(last, end).trim();
    if (piece.length > 0) {
      out.push(piece);
    }
    last = end;
    m = pattern.exec(t);
  }
  const tail: string = t.substring(last).trim();
  if (tail.length > 0) {
    out.push(tail);
  }

  const result: string[] = [];
  for (const s of out) {
    result.push(s.split(MARK).join('.'));
  }
  return result;
}

/** 超长句按分号/冒号/逗号切成块，避免单次请求过长 */
export function splitLong(sentence: string, limit: number = 220): string[] {
  if (sentence.length <= limit) {
    return [sentence];
  }
  const seps: string[] = ['; ', ': ', ', '];
  for (const sep of seps) {
    const pieces: string[] = [];
    let buf: string = '';
    for (const chunk of sentence.split(sep)) {
      if (buf.length + chunk.length > limit && buf.length > 0) {
        const tailSep: string = sep === ', ' ? ',' : sep.trim();
        pieces.push(buf + tailSep);
        buf = chunk;
      } else {
        buf = buf.length > 0 ? buf + sep + chunk : chunk;
      }
    }
    if (buf.length > 0) {
      pieces.push(buf);
    }
    if (pieces.length > 1) {
      return pieces;
    }
  }
  return [sentence];
}
