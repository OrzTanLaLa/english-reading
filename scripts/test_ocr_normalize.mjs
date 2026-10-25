// normalizeParagraphs / stripLeadingNumber 的离线自测
import { normalizeParagraphs } from '../app/entry/src/main/ets/adapters/ocr.mts';

const cases = [
  ['1 Every year, hundreds of new words are added.', 'Every year, hundreds of new words are added.'],
  ['11 As it turns out, editors look to us.', 'As it turns out, editors look to us.'],
  ['2. Some of them are abbreviations.', 'Some of them are abbreviations.'],
  ['3) Others are words that have been stretched.', 'Others are words that have been stretched.'],
  ['① First item here.', 'First item here.'],
  ['I. The first section.', 'The first section.'],
  ['Two You might notice how many words.', 'You might notice how many words.'],
  ['One day, I went to the market.', 'One day, I went to the market.'],
  ['Two men walked into the room.', 'Two men walked into the room.'],
  ['In 1973, the Oxford English Dictionary added it.', 'In 1973, the Oxford English Dictionary added it.'],
  ['It costs 10,287 dollars in 1990s.', 'It costs 10,287 dollars in 1990s.'],
];

let fail = 0;
for (const [input, want] of cases) {
  const got = normalizeParagraphs(input);
  if (got !== want) { fail++; console.log('FAIL', JSON.stringify(input), '\n  got :', JSON.stringify(got), '\n  want:', JSON.stringify(want)); }
  else console.log('ok  ', JSON.stringify(input).slice(0, 46), '→', JSON.stringify(got).slice(0, 46));
}

// 段落之间要有空行；段内折行要合并
const multi = '1 Every year, hundreds of\nnew words are added.\n\nTwo You might notice\nhow many are new.';
const out = normalizeParagraphs(multi);
console.log('\n--- 多段输入 ---\n' + JSON.stringify(multi));
console.log('--- 输出 ---\n' + JSON.stringify(out));
if (out !== 'Every year, hundreds of new words are added.\n\nYou might notice how many are new.') {
  fail++; console.log('FAIL multi');
} else console.log('ok   multi');

console.log(fail === 0 ? '\nALL PASS' : '\nFAILURES: ' + fail);
process.exit(fail === 0 ? 0 : 1);
