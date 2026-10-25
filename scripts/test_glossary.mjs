// 生语汇 YAML/JSON 的离线自测（Node 24 类型剥离）
import { parseReply, buildEntry, appendEntry, parseEntries, entryBlock } from '../app/entry/src/main/ets/core/glossary.mts';

let fail = 0;
function eq(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) { fail++; console.log('FAIL', name, '\n  got :', JSON.stringify(got), '\n  want:', JSON.stringify(want)); }
  else console.log('ok  ', name);
}

// 1. 单词：字符串
const r1 = parseReply('{"type":"word","word":"serendipity","answer":"机缘巧合的运气"}');
eq('word', [r1.kind, r1.words, r1.phrase, r1.answer], ['单词', ['serendipity'], '', '机缘巧合的运气']);

// 2. 搭配：序列
const r2 = parseReply('{"type":"collocation","words":["tucked","away"],"phrase":"tucked away","answer":"收起来"}');
eq('colloc', [r2.kind, r2.words, r2.phrase], ['搭配', ['tucked', 'away'], 'tucked away']);

// 3. 其他
const r3 = parseReply('{"type":"other","answer":"这段在讲旅行记忆"}');
eq('other', [r3.kind, r3.words, r3.phrase], ['其他', [], '']);

// 4. 代码块围栏 + 前后废话
const r4 = parseReply('好的：\n```json\n{"type":"word","word":"grit","answer":"毅力"}\n```');
eq('fence+prose', [r4.kind, r4.words, r4.answer], ['单词', ['grit'], '毅力']);

// 5. 坏 JSON → 其他 + 空回答
eq('bad json', [parseReply('{"type":').kind, parseReply('{"type":').answer], ['其他', '']);

// 6. 中文类型值也认
eq('cn type', parseReply('{"type":"搭配","words":["win","out"],"answer":"胜出"}').kind, '搭配');

// 7. buildEntry 三种形状
const eWord = buildEntry(r1, 'CTX', 'Q1');
eq('build word', [eWord.kind, eWord.words, eWord.phrase], ['单词', ['serendipity'], '']);
const eCol = buildEntry(r2, 'CTX', 'Q2');
eq('build colloc', [eCol.kind, eCol.words, eCol.phrase], ['搭配', ['tucked', 'away'], 'tucked away']);
const eOther = buildEntry(r3, 'CTX', 'Q3');
eq('build other', [eOther.words, eOther.phrase], [[], '']);

// 8. 只给了 words 没给 phrase → phrase 由应用拼
const r5 = parseReply('{"type":"collocation","words":["take","for","granted"],"answer":"视为理所当然"}');
eq('phrase fallback', buildEntry(r5, 'C', 'Q').phrase, 'take for granted');

// 9. 落盘往返
const all = appendEntry(appendEntry(appendEntry('', eWord), eCol), eOther);
const back = parseEntries(all);
console.log('--- file ---\n' + all + '------------');
eq('roundtrip count', back.length, 3);
eq('roundtrip word', [back[0].kind, back[0].words, back[0].phrase], ['单词', ['serendipity'], '']);
eq('roundtrip colloc', [back[1].kind, back[1].words, back[1].phrase], ['搭配', ['tucked', 'away'], 'tucked away']);
eq('roundtrip other', [back[2].kind, back[2].words, back[2].phrase], ['其他', [], '']);
eq('roundtrip q/c/a', [back[1].context, back[1].question, back[1].answer], ['CTX', 'Q2', '收起来']);

// 10. 幂等
eq('idempotent', appendEntry(all, eCol), all);

console.log(fail === 0 ? '\nALL PASS' : '\nFAILURES: ' + fail);
process.exit(fail === 0 ? 0 : 1);
