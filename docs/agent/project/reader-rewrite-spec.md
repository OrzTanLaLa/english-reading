# 朗读页重写方案（新文件 pages/Reader.ets）

> 现有 `pages/Reading.ets` ~1000 行、改动多次、结构已乱。**重写而不是继续打补丁**。
> 旧页保留不动（可随时回退），新页跑通后再切路由。

## 布局（应用设计 §4.4）

```
Row
├─ 左 70%：正文区（读法/原文两种视图）
└─ 右 30%：Column
   ├─ Row: [播放/暂停] [麦克风]
   ├─ 对话区（Text，可滚动，一问一答追加）
   └─ 输入框（矮）+ 发送
```

## 两种视图

| 视图 | 内容 | 高亮 |
|---|---|---|
| **读法**（默认） | `words[].text` 拼接出的文本 | **逐词高亮**（偏移构造时算好，精确） |
| **原文** | `store.readText(id)`，按段落渲染 | **不高亮** |

顶栏一个按钮：`显示原文` ↔ `显示读法`（当前视图的反向动作）。

## 状态机

```
loading → 无缓存 → synthesizing → ready
              └ 有缓存 ──────────→ ready
synthesizing 失败 → synthError(可重试)
```

## 依赖（都已存在，直接复用）

- `CourseStore`：`meta/readText/readAudio/readWords/readSentences/writeX/dropAudio/glossaryPath/readGlossary`
- `PcmPlayer`：`setData(pcm, words, startMs)` / `play/pause/toggle/seekTo/positionMs/release`
- `QwenTts`：`synthesize(text, {})` → `{pcm, words, sentences}`
- `Recorder`：`ensurePermission(ctx)/start()/stop()/cancel()`
- `CqrParser`：`parse(wavB64, sentences, currentIndex, pauseWord)`
- `AgentRunner` + `ToolRegistry` + `EchoTool/VocabularyTool/DictionaryTool`
- `AnswerVoice`：`speak(text)` 回答朗读
- `hashText`/`splitParagraphs`/`splitSentences`/`sanitize`

## 关键实现点（吸取教训）

1. **只保留一个渲染分支入口**：正文区用 `if (this.showWords) { A } else { B }`，**不嵌在别的 if 链里**；
   播放/提问按钮、对话区、输入框放在分支**之外**，三种状态共用。
2. **高亮只有两种来源**：读法视图 `highlightWord(wi)`（用 `wordOffsets`）；原文视图**恒为空**。
   不要同时存在"句级/词级"两套逻辑。
3. **偏移在拼接时算好**（`displayText` + `wordOffsets`），不做任何文本匹配。
4. **每次改完立刻 build + 截图**，一次只改一件事。
