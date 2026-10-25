/**
 * core/layout.ts 的黄金对拍：同一份源码在 Node 里跑，验证真机数据的结论可复现。
 *
 * Node 24 能直接跑 .mts（类型剥离），所以把 .ts 原样复制成 .mts 再 import，
 * 保证测的就是 App 编译的那份文件，不是另抄一遍。
 *
 * 用法：node scripts/test_layout.mjs
 */
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const src = resolve(root, 'app/entry/src/main/ets/core/layout.ts');
const tmpDir = resolve(root, '.tmp');
const tmp = resolve(tmpDir, 'layout.mts');

mkdirSync(tmpDir, { recursive: true });
copyFileSync(src, tmp);

const { analyzeLayout, joinText } = await import(pathToFileURL(tmp).href);

const toLayoutLines = (raw) => raw.map((l) => ({ text: l.v, x0: l.x0, y0: l.y0, x1: l.x1, y1: l.y1 }));

let failed = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name} -> ${detail}`);
  }
}

console.log('== 1. 真实照片（1280x1707，含对页残片）');
const dump = JSON.parse(readFileSync(resolve(root, 'artifacts/ocr-probe-real.json'), 'utf8'));
const real = analyzeLayout(toLayoutLines(dump.lines), { imageWidth: dump.w, imageHeight: dump.h });
check('聚类出 2 列', real.columnCount === 2, `columnCount=${real.columnCount}`);
check('丢弃 22 行残片', real.dropped.length === 22, `dropped=${real.dropped.length}`);
check('保留 32 行', real.ordered.length === 32, `kept=${real.ordered.length}`);
check('单列，无需选页', real.substantialColumns === 1 && real.needsPageChoice === false,
  `substantial=${real.substantialColumns} needs=${real.needsPageChoice}`);
check('首行是段落 10', (real.ordered[0]?.text ?? '').startsWith('10 Most people'), real.ordered[0]?.text ?? '');
check('末行是 Notes 例句', (real.ordered[real.ordered.length - 1]?.text ?? '').includes('deceive me'),
  real.ordered[real.ordered.length - 1]?.text ?? '');
const orderedNames = real.ordered.map((l) => l.text).join('\n');
check('段落编号递增且不回头',
  /10 Most[\s\S]*11 I've[\s\S]*12 I like[\s\S]*13 Last October[\s\S]*14 And I[\s\S]*15 I didn't/.test(orderedNames),
  '段落顺序不对');
check('残片关键词不在结果里', !orderedNames.includes('S,we') && !orderedNames.includes('lookat'), '仍有碎片');

console.log('== 2. 合成：左右两个「大列」（模拟对页拍进一半）');
const bigCols = [
  { text: 'L1 left page line one', x0: 40, y0: 100, x1: 540, y1: 140 },
  { text: 'L2 left page line two', x0: 40, y0: 150, x1: 540, y1: 190 },
  { text: 'L3 left page line three', x0: 40, y0: 200, x1: 540, y1: 240 },
  { text: 'R1 right page line one', x0: 700, y0: 100, x1: 1180, y1: 140 },
  { text: 'R2 right page line two', x0: 700, y0: 150, x1: 1180, y1: 190 },
  { text: 'R3 right page line three', x0: 700, y0: 200, x1: 1180, y1: 240 }
];
const spread = analyzeLayout(bigCols, { imageWidth: 1280, imageHeight: 1707 });
check('识别为 2 个实质列', spread.substantialColumns === 2, `substantial=${spread.substantialColumns}`);
check('要求用户选页', spread.needsPageChoice === true, `needs=${spread.needsPageChoice}`);
check('左列整体在前', spread.ordered[0].text.startsWith('L1'), spread.ordered[0].text);
check('不丢大列', spread.dropped.length === 0, `dropped=${spread.dropped.length}`);

console.log('== 3. 两栏单页（左右栏都必须保留，顺序为先左后右）');
const twoCol = [
  { text: 'H1', x0: 80, y0: 60, x1: 1100, y1: 100 },
  { text: 'L1', x0: 80, y0: 200, x1: 520, y1: 240 },
  { text: 'L2', x0: 80, y0: 250, x1: 520, y1: 290 },
  { text: 'R1', x0: 660, y0: 200, x1: 1100, y1: 240 },
  { text: 'R2', x0: 660, y0: 250, x1: 1100, y1: 290 }
];
const cols = analyzeLayout(twoCol, { imageWidth: 1240, imageHeight: 1700 });
const seq = cols.ordered.map((l) => l.text).join(',');
check('顺序为 H1,L1,L2,R1,R2', seq === 'H1,L1,L2,R1,R2', `实际 ${seq}`);
// 全宽标题把两栏「桥接」成一列区域：这是同一页的信号，不该提示选页
check('两栏页不提示选页', cols.substantialColumns === 1 && cols.needsPageChoice === false,
  `substantial=${cols.substantialColumns} needs=${cols.needsPageChoice}`);

console.log('== 6. 双栏 8 行/栏 + 全宽标题（贴近 rawfile 的 two_col 测试图）');
const body = [];
for (let i = 0; i < 8; i++) {
  body.push({ text: `L${i + 1} left`, x0: 80, y0: 240 + i * 48, x1: 520, y1: 270 + i * 48 });
  body.push({ text: `R${i + 1} right`, x0: 660, y0: 240 + i * 48, x1: 1100, y1: 270 + i * 48 });
}
const pageLike = [{ text: 'H1 header', x0: 80, y0: 60, x1: 1010, y1: 100 }].concat(body);
const pageOrder = analyzeLayout(pageLike, { imageWidth: 1240, imageHeight: 1754 }).ordered.map((l) => l.text);
const expected = ['H1 header', ...Array.from({ length: 8 }, (_, i) => `L${i + 1} left`),
  ...Array.from({ length: 8 }, (_, i) => `R${i + 1} right`)];
check('标题在首、左栏整段在前、右栏在后', pageOrder.join(',') === expected.join(','),
  `实际 ${pageOrder.slice(0, 5).join(',')} …`);

console.log('== 7. 跨栏元素在中间（如跨栏图注）');
const midCross = [
  { text: 'H1', x0: 80, y0: 60, x1: 1100, y1: 100 },
  { text: 'L1', x0: 80, y0: 200, x1: 520, y1: 240 },
  { text: 'R1', x0: 660, y0: 200, x1: 1100, y1: 240 },
  { text: 'CAPTION wide', x0: 80, y0: 400, x1: 1100, y1: 440 },
  { text: 'L2', x0: 80, y0: 560, x1: 520, y1: 600 },
  { text: 'R2', x0: 660, y0: 560, x1: 1100, y1: 600 }
];
const midOrder = analyzeLayout(midCross, { imageWidth: 1240, imageHeight: 1754 }).ordered.map((l) => l.text);
check('跨栏图注夹在两段之间', midOrder.join(',') === 'H1,L1,R1,CAPTION wide,L2,R2', `实际 ${midOrder.join(',')}`);

console.log('== 8. 书脊沟很窄的跨页（实测只有 15px）');
const narrow = [];
for (let i = 0; i < 6; i++) {
  narrow.push({ text: `L${i + 1}`, x0: 81, y0: 240 + i * 50, x1: 808, y1: 280 + i * 50 });
  narrow.push({ text: `R${i + 1}`, x0: 823, y0: 250 + i * 50, x1: 1279, y1: 290 + i * 50 });
}
const narrowPage = analyzeLayout(narrow, { imageWidth: 1280, imageHeight: 1707 });
const narrowOrder = narrowPage.ordered.map((l) => l.text).join(',');
check('两列分开且左列在前', narrowOrder === 'L1,L2,L3,L4,L5,L6,R1,R2,R3,R4,R5,R6', `实际 ${narrowOrder}`);
check('提示需要选页', narrowPage.needsPageChoice === true, `needs=${narrowPage.needsPageChoice}`);
check('不丢大列', narrowPage.dropped.length === 0, `dropped=${narrowPage.dropped.length}`);

console.log('== 4. 边界');
const empty = analyzeLayout([], { imageWidth: 100, imageHeight: 100 });
check('空输入不崩', empty.ordered.length === 0 && empty.columnCount === 0, 'empty 结果异常');
const one = analyzeLayout([{ text: 'only', x0: 0, y0: 0, x1: 10, y1: 10 }], { imageWidth: 100, imageHeight: 100 });
check('单行原样返回', one.ordered.length === 1 && one.ordered[0].text === 'only', '单行异常');

console.log('== 5. joinText 段落合并');
const joined = joinText(real.ordered, 26);
check('段落之间有空行', joined.includes('\n\n'), '没有段落分隔');

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
