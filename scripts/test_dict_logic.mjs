/**
 * 词典纯逻辑的对拍：词形还原 + 义项排序。
 *
 * 和 test_layout.mjs 一样，把 .ts 原样复制成 .mts 再 import，
 * 保证测的就是 App 编译的那份文件。
 *
 * 用法：node scripts/test_dict_logic.mjs
 */
import { copyFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const tmpDir = resolve(root, '.tmp');
mkdirSync(tmpDir, { recursive: true });

function load(rel, name) {
  const src = resolve(root, 'app/entry/src/main/ets', rel);
  const tmp = resolve(tmpDir, name);
  copyFileSync(src, tmp);
  return import(pathToFileURL(tmp).href);
}

const { morphCandidates } = await load('core/morph.ts', 'morph.mts');
const { rankSenses, topSenses } = await load('core/dict.ts', 'dict.mts');

let failed = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name} -> ${detail}`);
  }
}

console.log('== 1. 词形还原');
const cases = [
  ['became', 'become'],
  ['dictionaries', 'dictionary'],
  ['blurred', 'blur'],
  ['stopped', 'stop'],
  ['happily', 'happy'],
  ['adding', 'add'],
  ['trending', 'trend'],
  ['studies', 'study'],
  ['countries', 'country'],
  ['running', 'run'],
  ['bigger', 'big'],
];
for (const [word, expect] of cases) {
  const cands = morphCandidates(word);
  check(`${word} -> ${expect}`, cands.includes(expect), `实际 ${cands.join(',')}`);
}
check('虚词不还原', morphCandidates('and').length === 0, 'and 应该返回空');
check('原词不在候选里', !morphCandidates('blurred').includes('blurred'), '不该包含自身');

console.log('== 2. 义项排序（该词性义项多者优先）');
function sensesOf(spec) {
  const out = [];
  let i = 0;
  for (const [pos, count] of spec) {
    for (let k = 0; k < count; k++) {
      out.push({ pos, definition: `${pos}-${k}`, examples: '', synonyms: '', index: i++ });
    }
  }
  return out;
}
const addSenses = sensesOf([['noun', 1], ['verb', 5]]);
check('add：动词在前', rankSenses(addSenses)[0].pos === 'verb', rankSenses(addSenses)[0].pos);

const blurSenses = sensesOf([['noun', 1], ['verb', 4]]);
check('blur：动词在前', rankSenses(blurSenses)[0].pos === 'verb', rankSenses(blurSenses)[0].pos);

const trendSenses = sensesOf([['noun', 4], ['verb', 1]]);
check('trend：名词在前', rankSenses(trendSenses)[0].pos === 'noun', rankSenses(trendSenses)[0].pos);

const radioSenses = sensesOf([['adjective', 1], ['noun', 3]]);
check('radio：名词在前（形容词义不该抢）', rankSenses(radioSenses)[0].pos === 'noun', rankSenses(radioSenses)[0].pos);

console.log('== 3. topSenses 截断');
const entry = { word: 'x', matched: 'x', fromMorph: false, senses: addSenses };
check('取前 3 个', topSenses(entry, 3).length === 3, String(topSenses(entry, 3).length));
check('取前 9 个不超过总数', topSenses(entry, 9).length === 6, String(topSenses(entry, 9).length));

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
