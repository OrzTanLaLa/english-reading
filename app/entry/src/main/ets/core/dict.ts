/**
 * 词典的数据结构与排序规则（纯逻辑，零平台依赖）。
 *
 * 排序规则：**该词性义项越多越靠前**。
 * 依据：WordNet 里常见词的义项数量大致反映常用程度。实测 add（1 名词 / 5 动词）
 * 若按字母序会先返回 ADHD 的义项，按此规则则先返回动词义，blur、trend、radio 同理。
 */

export interface DictSense {
  pos: string;
  definition: string;
  examples: string;
  synonyms: string;
  index: number;
}

export interface DictEntry {
  word: string;
  /** 实际命中的词条（词形还原后可能与查询词不同） */
  matched: string;
  /** 是否经过词形还原 */
  fromMorph: boolean;
  senses: DictSense[];
}

/** 按「该词性义项数多者优先，其次组内原序」重排 */
export function rankSenses(senses: DictSense[]): DictSense[] {
  const counts: Record<string, number> = {};
  for (const sense of senses) {
    const n: number = counts[sense.pos] === undefined ? 0 : counts[sense.pos];
    counts[sense.pos] = n + 1;
  }
  const out: DictSense[] = senses.slice();
  out.sort((a: DictSense, b: DictSense): number => {
    const ca: number = counts[a.pos];
    const cb: number = counts[b.pos];
    if (ca !== cb) {
      return cb - ca;
    }
    if (a.pos !== b.pos) {
      return a.pos < b.pos ? -1 : 1;
    }
    return a.index - b.index;
  });
  return out;
}

/** 取前 n 个义项（工具返回给模型时不至于太长） */
export function topSenses(entry: DictEntry, n: number): DictSense[] {
  const ranked: DictSense[] = rankSenses(entry.senses);
  return ranked.length > n ? ranked.slice(0, n) : ranked;
}
