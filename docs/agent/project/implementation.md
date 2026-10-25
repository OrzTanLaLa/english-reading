# 设计 → 实现对照

> 配套 `docs/应用设计.md`：那里写「要什么」，这里写「在哪一行、怎么改」。
> 改设计后，同步改这两份：先改 `应用设计.md`，再改本文件的对应行。

## 4. 页面与交互

| 设计条目 | 实现位置 | 改动要点 |
|---|---|---|
| 4.1 文库页（列表/⋮/＋/空状态） | `pages/Library.ets` | ⋮ 菜单项在 `bindMenu`；新菜单项加在这里 + `onMenuItem` 分支 |
| 4.2 扫描页（系统扫描控件） | `pages/Scan.ets` | `DocumentScannerConfig`：`maxShotCount=10`、`ShootingMode.MANUAL`、`editTabs=[DELETE,ROTATE]`、`isShareable=false`；`onResult` 里 `replaceUrl` 到确认页 |
| 4.3 编辑页（标题/图片/识别/全文/保存） | `pages/Editor.ets` | 识别在 `recognize()`；保存时文本变则 `dropAudio` |
| 4.4 朗读页（正文/高亮/播放/提问） | `pages/Reader.ets` | 左 70% 正文双视图（读法/原文）、右 30% 按钮+对话+输入框；高亮见下 |
| 4.4 图标 | 各页 `SymbolGlyph($r('sys.symbol.*'))` | 返回 `chevron_left`、新增 `plus`；名字查 `sysResource.js`（见 `apis.md`） |
| 4.5 生语汇 | `pages/Glossary.ets` + `adapters/courseStore.glossaryPath/writeGlossary/readGlossary` | **原样显示 `glossary.yaml`**（可复制）；`parseEntries` 只用来数条数 |

## 4.4 朗读页的三个关键实现

**正文渲染**：每段一个 `Text(text, { controller })`，原文整段渲染（不切句、不拆词），
`lineHeight(32)`、`fontSize(19)`。

**逐词高亮**：`scheduleHighlight(wi)` →
`controller.getLayoutManager().getRectsForRange(词区间, TIGHT, TIGHT)` → 在 `Stack` 里画一个
浅蓝圆角块（`#B9D5FA`）。**不改文字样式，所以不触发重排。**

**点词跳转**：`onClick(e)` → `vp2px(e.x), vp2px(e.y)` → `getCharacterPositionAtCoordinate(..., UTF16)`
→ `wordAtChar()` → `player.seekTo(words[wi].begin)` → `play()`。

## 3. 核心流程 ↔ 代码

| 步骤 | 代码 |
|---|---|
| 拍照/选图 | `pages/Scan.ets` → `pages/Editor.ets` 的 `addImages()`（`courseStore.addImages` 负责把 uri 拷进沙箱，媒体 uri 走 open+fd 兜底） |
| OCR | `adapters/ocr.ts` `CloudOcr.recognize(base64)`（提示词 `PROMPT` 在文件顶部；`normalizeParagraphs()` 兜底去段首标号、合并段内折行） |
| 合成 | `adapters/tts.ets` `QwenTts.synthesize()`（走 SDK `neonui.har`），结果写 `audio.pcm` + `words.json` |
| 缓存判定 | `pages/Reading.load()`：`meta.textHash === hashText(text, voice) && hasAudio` |
| 播放与位置 | `adapters/player.ts`：`on('writeData')` 喂数据，`getAudioTimestampInfoSync().framePos` 算位置 |
| 词对齐 | `core/reader.ts` `alignWords(text, words)` → `WordSpan[]`（贪心匹配，已知会偶发偏一个词） |
| 提问解析 | `adapters/cqr.ts` `CqrParser.parse(...)`（Omni + `input_audio`）→ 一句话问题 |
| 回答 + 落盘 | `pages/Reader.ets` 的 `askAgent()`：一次 `DeepSeekClient.complete(..., [], true)`（JSON Output）→ `core/glossary.parseReply` → `buildEntry` → `appendEntry` 写 YAML；当前句由 `currentSentenceRead()` 给 |
| 录音 | `adapters/recorder.ts`（48k/双声道 WAV；16k 会被系统拒） |

## 5. 数据规则 ↔ 实现

| 规则 | 位置 |
|---|---|
| 一门课一个目录 | `adapters/courseStore.ts`：`files/course/<id>/{meta.json,text.txt,images/,audio.pcm,words.json,glossary.txt}` |
| 只保留当前音色音频 | `hashText(text, voice)` 进 `meta.textHash`；不匹配即重新合成 |
| OCR 输出规则 | `adapters/ocr.ts` 的 `PROMPT` + `normalizeParagraphs()`（清上标数字、合并段内换行） |
| 时间戳单位 | TTS 给全局毫秒；播放器按 `framePos/16ms` 推进（16k 时）；当前播放用 16k PCM |

## 6. 提问的规则 ↔ 实现

| 规则 | 位置 |
|---|---|
| 中文提问、中文回答 | `adapters/cqr.ts` 的 `SYSTEM`；Agent 的 system prompt 在 `core/prompts.ts` |
| 以当前播放位置为上下文 | `Reading.sentenceOfWord(activeIndex)` → `CqrParser.parse(..., currentIndex, pauseWord)` |
| 音频直入模型 | `input_audio: { data: 'data:audio/wav;base64,...', format: 'wav' }` |
| 写入方式 | **代码直接写**（D32）：不再有 agent 工具循环；`core/glossary.ts` 负责序列化与幂等 |

## 7. 成本 ↔ 实现

- 缓存命中即 0：`Reading.load()` 的 hash 判定；
- 合成前可先校对：编辑页里识别/改完正文再保存；
- 回答朗读用端侧 TTS：`@kit.CoreSpeechKit` 的 `textToSpeech`（**无词级时间戳**，只能用于不需高亮的场景）。

## 8. 不做的事

已在 `decisions.md` 记录（D1/D2/D4/D6…），实现里**不应出现**这些路径；若发现残留代码，
以 `decisions.md` 为准删除，并同步更新 `应用设计.md` 的「不做的」。
## Agent 工具调用（机制）

主 Agent 走的是模型**原生 function calling**，不是「提示词让它输出 JSON 再解析」：

1. 每轮请求带上 `tools`（名字 + description + 参数 JSON Schema，见 `agent/tools.ts`）；
2. 模型若决定调用，返回 `tool_calls`（`id/name/arguments`），**不返回正文**；
3. `agent/loop.ts` 执行工具，把结果作为 `role: "tool"` 消息用 `tool_call_id` 回填；
4. 循环直到模型给出纯文本回答（上限 6 轮）。

「何时调用」由三样东西共同决定：**工具描述**（什么是这个工具该干的）、**模型训练**（该调还是该说）、
**系统提示的策略**（例如"问词句意思时必须调用 append_vocabulary"）。
客户端还能用 `tool_choice` 强制。

对照：CQR（`adapters/cqr.ts`）**不用** tool calling，而是要求模型直接输出 JSON——
它只做理解、不调工具，所以没有 schema 兜底，这也是 D16 要把它改成「分档 + 代码定位」的原因。