/**
 * 真机 vs Node 逐字比对：同一份 core/layout.ts、同一份 OCR JSON，输出必须完全一致。
 *
 * 真机侧：OcrProbe 页「选照片跑 OCR」会写 filesDir/ocr_layout.txt
 * 本脚本：读回传的 ocr_probe.json，用 Node 跑同样的算法，和真机输出 diff。
 *
 * 用法：
 *   node scripts/compare_device_layout.mjs
 */
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
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

const jsonPath = resolve(root, 'artifacts/ocr-probe-real.json');
const devicePath = resolve(root, 'artifacts/device-ocr_layout.txt');
if (!existsSync(devicePath)) {
  console.error(`缺少真机输出：${devicePath}`);
  process.exit(2);
}

const dump = JSON.parse(readFileSync(jsonPath, 'utf8'));
const lines = dump.lines.map((l) => ({ text: l.v, x0: l.x0, y0: l.y0, x1: l.x1, y1: l.y1 }));
const layout = analyzeLayout(lines, { imageWidth: dump.w, imageHeight: dump.h });

// 和 App 里一致：行高取保留行的平均高度
let sum = 0;
for (const l of layout.ordered) {
  sum += l.y1 - l.y0;
}
const lineH = layout.ordered.length > 0 ? sum / layout.ordered.length : 20;

const nodeText = joinText(layout.ordered, lineH);
writeFileSync(resolve(tmpDir, 'node-ocr_layout.txt'), nodeText, 'utf8');

const deviceText = readFileSync(devicePath, 'utf8');
const norm = (s) => s.replace(/\r\n/g, '\n').replace(/\n+$/, '');
const a = norm(deviceText);
const b = norm(nodeText);

console.log(`真机 ${a.length} 字符 / Node ${b.length} 字符，行数 ${a.split('\n').length} / ${b.split('\n').length}`);
console.log(`columns=${layout.columnCount} substantial=${layout.substantialColumns} dropped=${layout.dropped.length} kept=${layout.ordered.length}`);

if (a === b) {
  console.log('逐字一致 ✅');
  process.exit(0);
}

console.log('不一致 ❌，第一处差异：');
const al = a.split('\n');
const bl = b.split('\n');
for (let i = 0; i < Math.max(al.length, bl.length); i++) {
  if (al[i] !== bl[i]) {
    console.log(`  行 ${i + 1}`);
    console.log(`    真机: ${JSON.stringify(al[i])}`);
    console.log(`    Node: ${JSON.stringify(bl[i])}`);
    break;
  }
}
process.exit(1);
