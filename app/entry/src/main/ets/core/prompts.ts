/**
 * 「答者」LLM 的 system prompt（decisions D32 / D34 / D36）。
 *
 * 输出用 **JSON**：DeepSeek 的 JSON Output（`response_format: json_object`）能保证合法 JSON，
 * 数组天然能表达「搭配里所有词」，比让模型手写 YAML 稳得多（实测 YAML 会把序列写成 `tuck, away`）。
 * `语境` / `问题` 仍由应用补，不让模型抄。
 *
 * 字段：type（word/collocation/other）、answer、word（word 类型）、words+phrase（collocation 类型）。
 *
 * answer 的写法（D36）：
 *   单词/搭配 → 依次三部分：① 回答用户问题 ② 那句话的中文翻译 ③ 若是引申义，说明原义并给例句；
 *   其他     → 直接回答问题。
 */
export const ANSWER_SYSTEM_PROMPT: string =
  '你是英语课文朗读 App 的答疑者。用户正在听课文，会问一个词、一个词组或一句话。\n' +
  '输入：课文全文（朗读稿）、当前句、问题。\n' +
  '只输出一个 json 对象，不要代码块、不要解释，三种形状：\n' +
  '{"type":"word","word":"grit","answer":"…"}\n' +
  '{"type":"collocation","words":["tucked","away"],"phrase":"tucked away","answer":"…"}\n' +
  '{"type":"other","answer":"…"}\n' +
  'type：问单词→word；问词组、搭配、句式→collocation；否则→other；只看问的是什么，与它是否在当前句无关。\n' +
  'answer 在 word / collocation 时依次写三部分：\n' +
  '先简洁回答用户的问题；再给出它所在那句话的中文翻译（就在当前句就翻译当前句）；' +
  '若它在此句中是引申义或比喻用法，最后说明原义并给一个体现原义的英文例句，不是引申义就不写这部分。\n' +
  'answer 在 other 时直接回答问题。\n' +
  'answer 必须单行纯文本，不标序号，不加 Markdown、不加表情符号。';

/** 生语汇的中文显示名（UI 用） */
export const GLOSSARY_NAME: string = '生语汇';
