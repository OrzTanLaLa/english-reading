# 架构与数据流

## 分层

```
pages/        UI（Library / Scan / Editor / Reader / Glossary + Probe 页）
agent/        工具循环（loop.ts）+ 工具实现（tools.ts）
adapters/     平台对接，唯一碰系统 API 的地方
core/         纯逻辑，零平台依赖（可搬到别的端）
```

**规矩**：`core/` 不许 import 任何 `@kit.*`；需要平台能力时由 `adapters/` 注入。

## 一次完整流程

### A. 导入
```
Library(＋) → Scan(DocumentScanner 控件)
   → onResult(200, _, uris) → Editor(标题 + 图片列表 + 识别)
   → addImages(uri → files/course/<id>/images/)
   → CloudOcr.recognize(base64) → 正文
   → 显示全文（用户校对，不立即合成）
   → 「去朗读」→ Reading
```

### B. 朗读
```
Reading.load()
  ├─ meta.textHash == hashText(text, voice) 且 hasAudio  → 读缓存（省一次合成）
  └─ 否则 synthesize()
        └─ QwenTts.synthesize(text)  [neonui.har]
              → 累积 PCM，按 sentence.index 去重拼 WordTiming[]
              → writeAudio(pcm) + writeWords(words)
  → alignWords(text, words)         → WordSpan[]（词在原文里的字符区间）
  → splitParagraphs(text)           → 段落范围
  → splitSentences(text)            → 句子（CQR 用）
  → PcmPlayer.setData(pcm, words, startMs)
```

### C. 播放与高亮
```
AudioRenderer.on('writeData')   ← 音频线程拉 PCM（字节偏移 = baseMs*32 + 已写）
每 200ms: 位置 = baseMs + framePos/16 → 刷新进度条
逐词调度: 每次触发都重读 framePos 再排下一个词（误差不累积）
  → onWord(i) → activeIndex=i → scheduleHighlight(i)
        → controller.getLayoutManager().getRectsForRange(词区间)
        → Stack 里画矩形（不动文字样式）
```

### D. 点词跳转
```
onClick(e) → vp2px(e.x), vp2px(e.y)
  → getCharacterPositionAtCoordinate(...)  → 字符下标（UTF-16）
  → wordAtChar() → 词下标
  → player.seekTo(words[i].begin) → play()
```

### E. 语音提问（已通解析段，未接 UI）
```
Recorder.start()  → AudioCapturer 16k/mono → 累积 PCM
Recorder.stop()   → 封 WAV → base64
  → CqrParser.parse(wavB64, sentences, currentIndex, pauseWord)
        → {sentenceId, surface, spanStart, spanEnd, intent, question, confidence}
  → （待接）AgentRunner.run(...) → 中文回答
  → （待接）端侧 TTS 朗读 + append_vocabulary 落盘
```

## 关键类型

| 类型 | 位置 | 说明 |
|---|---|---|
| `WordTiming {text, begin, end}` | `adapters/tts.ets` | 全局毫秒 |
| `WordSpan {start, end, index}` | `core/reader.ts` | 词 → 原文字符区间 |
| `Paragraph {start, end}` | `core/reader.ts` | 段落区间 |
| `CourseMeta` | `core/course.ts` | id/title/voice/textHash/audioMs/lastPositionMs… |
| `CqrResult` | `adapters/cqr.ts` | 提问解析结果 |
| `OcrPage {index, text}` | `adapters/ocr.ts` | 兼容旧分页标记，现在通常只有一页 |

## 文本处理的顺序（很重要）

1. `sanitize()` 清控制字符 —— **送给 TTS 的必须是这个版本**；
2. `hashText(text, voice)` 做缓存键；
3. `alignWords()` 在**同一份文本**上做对齐（渲染也用这份，避免与 TTS 输入不一致）。

## 缓存规则

- 音频缓存键：`meta.textHash == hashText(currentText, voice)` **且** `audio.pcm` 存在；
- 编辑文本 → `writeText` + `dropAudio` + 重新合成；
- 换音色也会变 hash（同一门课只保留当前音色的音频）。

## 页面/路由

产品页（`main_pages.json` 注册顺序）：Library、Scan、Glossary、Editor、Reader；
另有一次性探针页：ImportProbe、HighlightProbe、PlayerProbe、DictProbe、OcrProbe、Index、TtsSdkProbe、PermProbe。

Probe 页是**一次性验证工具**，别删（排查时好用），但也别当成产品页。
