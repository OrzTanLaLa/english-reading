/**
 * core/segment.ts 的黄金对拍：与 Python 版 segment.py 的输出逐字符一致。
 *
 * fixture 由 Python 生成（validation/B0B/golden/*.sentences.json），
 * 这份 TS 必须产出完全相同的结果，否则移植会引入「看起来一样、边界差一个字符」的 bug。
 *
 * 用法：node scripts/test_segment.mjs
 */
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const tmpDir = resolve(root, '.tmp');
mkdirSync(tmpDir, { recursive: true });

const src = resolve(root, 'app/entry/src/main/ets/core/segment.ts');
const tmp = resolve(tmpDir, 'segment.mts');
copyFileSync(src, tmp);
const { splitSentences, splitLong } = await import(pathToFileURL(tmp).href);

let failed = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name} -> ${detail}`);
  }
}

console.log('== 1. 与 Python fixture 逐句对拍');
for (const name of ['t1', 't2', 't3']) {
  const expected = JSON.parse(readFileSync(resolve(root, `validation/B0B/golden/${name}.sentences.json`), 'utf8'));
  const text = readFileSync(resolve(root, `validation/B0A/texts/${name}.txt`), 'utf8');
  const actual = splitSentences(text);
  check(`${name} 句数 (${expected.length})`, actual.length === expected.length,
    `实际 ${actual.length}`);
  let diff = -1;
  for (let i = 0; i < Math.min(actual.length, expected.length); i++) {
    if (actual[i] !== expected[i]) {
      diff = i;
      break;
    }
  }
  check(`${name} 逐句一致`, diff < 0,
    diff >= 0 ? `第 ${diff + 1} 句不同：\n     TS: ${actual[diff]}\n     PY: ${expected[diff]}` : '');
}

console.log('== 2. 缩写保护');
const cases = [
  ['Mr. Smith went home. He was tired.', 2],
  ['It cost $1.2 billion in the U.S. last year. That is a lot.', 2],
  ['Use e.g. this one. It works.', 2],
  ['She said, "I am fine." He nodded.', 2],
  ['No. 5 was late. We waited.', 2],
];
for (const [text, expectedCount] of cases) {
  const got = splitSentences(text);
  check(`「${text.slice(0, 28)}…」→ ${expectedCount} 句`, got.length === expectedCount,
    `实际 ${got.length}：${got.join(' | ')}`);
}

console.log('== 3. 超长句切块');
const long = 'A very long sentence that keeps going with commas, and more clauses, and still more clauses, until it is definitely longer than the limit.';
const pieces = splitLong(long, 80);
check('切出多块', pieces.length > 1, `实际 ${pieces.length}`);
check('每块不超限 + 分隔符', pieces.every((p) => p.length <= 90), pieces.map((p) => p.length).join(','));
const short = 'Short one.';
check('短句原样返回', splitLong(short, 220).length === 1, '应返回 1 块');

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
