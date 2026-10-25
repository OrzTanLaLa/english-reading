/**
 * 词形还原（简化版 WordNet morphy）：把 added / became / dictionaries 映射回原形。
 *
 * 纯函数、零平台依赖 —— App 里编译，Node 里跑单测。
 * Python 原型见 scripts/morph.py，两边规则保持一致。
 */

const IRREGULAR: Record<string, string> = {
  'was': 'be', 'were': 'be', 'been': 'be', 'am': 'be', 'is': 'be', 'are': 'be',
  'went': 'go', 'gone': 'go', 'did': 'do', 'done': 'do', 'does': 'do',
  'had': 'have', 'has': 'have', 'made': 'make', 'said': 'say', 'saw': 'see',
  'seen': 'see', 'took': 'take', 'taken': 'take', 'came': 'come', 'got': 'get',
  'gave': 'give', 'given': 'give', 'found': 'find', 'thought': 'think',
  'became': 'become', 'began': 'begin', 'begun': 'begin', 'brought': 'bring',
  'kept': 'keep', 'knew': 'know', 'known': 'know', 'left': 'leave',
  'lost': 'lose', 'meant': 'mean', 'met': 'meet', 'paid': 'pay', 'ran': 'run',
  'sold': 'sell', 'sent': 'send', 'spent': 'spend', 'stood': 'stand',
  'taught': 'teach', 'told': 'tell', 'understood': 'understand', 'won': 'win',
  'wrote': 'write', 'written': 'write', 'children': 'child', 'men': 'man',
  'women': 'woman', 'people': 'person', 'feet': 'foot', 'teeth': 'tooth',
  'mice': 'mouse', 'geese': 'goose', 'better': 'good', 'best': 'good',
  'worse': 'bad', 'worst': 'bad', 'more': 'much', 'most': 'much'
};

/** 这些词不需要还原，直接返回空列表（避免规则误伤） */
const KEEP_AS_IS: string[] = [
  'and', 'or', 'but', 'if', 'the', 'a', 'an', 'of', 'to', 'in', 'on',
  'at', 'for', 'with', 'as', 'by', 'from', 'that', 'this', 'it', 'is'
];

/** 按可能性从高到低给出候选原形（不含原词本身） */
export function morphCandidates(word: string): string[] {
  const w: string = word.toLowerCase();
  if (KEEP_AS_IS.indexOf(w) >= 0) {
    return [];
  }
  const out: string[] = [];
  const add = (x: string): void => {
    if (x.length >= 2 && x !== w && out.indexOf(x) < 0) {
      out.push(x);
    }
  };

  const irregular: string | undefined = IRREGULAR[w];
  if (irregular !== undefined) {
    add(irregular);
  }

  if (w.endsWith("'s")) {
    add(w.substring(0, w.length - 2));
  }
  if (w.endsWith('s') && !w.endsWith('ss')) {
    add(w.substring(0, w.length - 1));
    if (w.endsWith('ies')) {
      add(w.substring(0, w.length - 3) + 'y');
    }
    if (w.endsWith('es')) {
      add(w.substring(0, w.length - 2));
    }
  }
  if (w.endsWith('ed')) {
    add(w.substring(0, w.length - 2));
    add(w.substring(0, w.length - 1));
    if (w.endsWith('ied')) {
      add(w.substring(0, w.length - 3) + 'y');
    }
    if (w.length > 4 && w.charAt(w.length - 3) === w.charAt(w.length - 4)) {
      add(w.substring(0, w.length - 3));
    }
  }
  if (w.endsWith('ing')) {
    add(w.substring(0, w.length - 3));
    add(w.substring(0, w.length - 3) + 'e');
    if (w.length > 5 && w.charAt(w.length - 4) === w.charAt(w.length - 5)) {
      add(w.substring(0, w.length - 4));
    }
  }
  if (w.endsWith('ly')) {
    add(w.substring(0, w.length - 2));
    if (w.endsWith('ily')) {
      add(w.substring(0, w.length - 3) + 'y');
    }
  }
  if (w.endsWith('er')) {
    add(w.substring(0, w.length - 2));
    add(w.substring(0, w.length - 1));
    // bigger -> big（双写辅音 + er）
    if (w.length > 4 && w.charAt(w.length - 3) === w.charAt(w.length - 4)) {
      add(w.substring(0, w.length - 3));
    }
  }
  if (w.endsWith('est')) {
    add(w.substring(0, w.length - 3));
    add(w.substring(0, w.length - 2));
    // biggest -> big（双写辅音 + est）
    if (w.length > 5 && w.charAt(w.length - 4) === w.charAt(w.length - 5)) {
      add(w.substring(0, w.length - 4));
    }
  }
  return out;
}
