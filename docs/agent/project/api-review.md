# API 复审（2026-10-21）

> 在能读官方文档（`scripts/hsdocs.py`）之后，把整条链路重新对了一遍。
> 每条都标了**出处**和**当前做法**，结论只保留有证据的。

---

## 0. 结论摘要

| 模块 | 现在用的 | 官方有更好的 | 收益 | 成本 |
|---|---|---|---|---|
| **音频播放** | 自己 `write()` + `framePos` 限流 | **`on('writeData')` 回调**（音频线程拉数据） | 去掉限流/饿死/位置推算一堆补丁 | 小 |
| **词级高亮** | `Text` + `ForEach(Span)` 整段重建 | **`MutableStyledString.replaceStyle`** 原地改样式 | 每次切词 O(1)，不再重排整段 | 小 |
| **问答回复朗读** | 云端 TTS | **端侧 `textToSpeech`** | 免费、无网络、低延迟 | 小 |
| **语音提问** | 计划上传音频给云端 | **端侧 `speechRecognizer`** | 不上传音频（隐私）、省一次传输 | 中 |
| **扫描页** | 计划自研相机 + 切边 | **`DocumentScanner` 控件**（自动裁剪/透视/导出 PDF） | 省掉整块自研 | 中 |
| **朗读 TTS** | 云端 qwen-audio-3.1（有词级时间戳） | 端侧 TTS **无时间戳**，不可替代 | — | — |
| **OCR** | 云端 VLM（分页标记） | 端侧 `textRecognition` 有 blocks/lines 但**无阅读顺序** | — | — |
| **点词跳转** | 未实现 | `text.Paragraph` 可做影子排版（需实测行一致） | 字符级命中 | 中 |

---

## 1. 现状依赖

```
@kit.AbilityKit        UIAbility / AbilityConstant / Want / common
@kit.ArkData           preferences（Key）、relationalStore（词典）
@kit.ArkTS             util（TextDecoder / Base64Helper）
@kit.ArkUI             router / promptAction / window
@kit.AudioKit          audio.AudioRenderer
@kit.CoreFileKit       fileIo
@kit.CoreVisionKit     textRecognition（端侧 OCR，已放弃）
@kit.MediaLibraryKit   photoAccessHelper（选图）
@kit.NetworkKit        http（OCR/LLM）、webSocket（TTS）
@kit.ImageKit          image（像素图）
@kit.BasicServicesKit  BusinessError
@kit.PerformanceAnalysisKit hilog
```

---

## 2. 逐块复审

### A. TTS 朗读（保留云端，但补一个端侧用途）

**现状**：`qwen-audio-3.1-tts-flash` WebSocket，`format=pcm, sample_rate=16000, word_timestamp_enabled=true`。

**官方** `@kit.CoreSpeechKit` → `textToSpeech`（`hms-ai-texttospeech`）：
- 流式 PCM：`onData(requestId, audio: ArrayBuffer, response)`
- `SynthesisResponse` **只有两个字段**：`sequence`（音频块序号）、`audioType`（当前仅 `'pcm'`）
- **没有词级时间戳、没有字符区间**

**判断**：朗读高亮必须继续用云端 TTS（端侧给不了词边界）。但**问答回复**不需要高亮——那段可以用端侧 TTS，免费、离线、免鉴权。`CreateEngineParams` 还有 `online: 1` 可切云端增强。

**待查**：端侧 TTS 的音色数量与英文质量（`listVoices()` / `downloadVoice()`）。

---

### B. 音频播放（应当换掉）

**现状**：自己维护 `write()` 循环，用 `getAudioTimestampInfoSync().framePos` 做「领先量 ≤240ms」的限流；踩过「80ms 会饿死、framePos 卡 0」的坑。

**官方**（`using-audiorenderer-for-playback`）：

```ts
audioRenderer.on('writeData', (buffer: ArrayBuffer) => { … });
```

> 订阅音频数据写入回调，**推荐使用** API 12 支持返回回调结果的方式。

即：**音频线程按需向应用要数据**，天然与播放节奏同步，不需要我们限流，也不会一次性灌满缓冲。

**判断**：这是结构性改进——我们现在那套「限流 + 饿死 + 位置推算」的补丁全都可以删掉，播放位置也更可信（回调驱动的数据流）。

**风险**：改动播放器核心，需重跑同步测试（我们已有缓存和 `音频迟到` 指标，回归成本低）。

---

### C. 词级高亮（应当换掉）

**现状**：`Text() { ForEach(this.segments(i)) { Span(...) } }`，每次切词重建整段；为了避免卡顿，已经缩到「只渲染当前段」。

**官方**（`属性字符串` / `ts-universal-styled-string`）：
- `TextController.setStyledString(styledString)` 把属性字符串绑到 `Text`
- `MutableStyledString.replaceStyle(spanStyle)` **原地替换某区间的样式**
- 文档原文：「适用于富文本编辑、聊天消息显示、**文档标注**等需要灵活设置文本样式的场景，**可动态修改样式内容**」

**这是为我们的场景设计的**：整篇文本只构建一次 `MutableStyledString`，切词时对「上一个词」和「当前词」两个区间各调一次 `replaceStyle`。

| | 现在 | StyledString |
|---|---|---|
| 每次切词 | 重建 15–60 个 Span + 整段文本重排 | 2 次区间样式替换 |
| 文本内容 | 每次从词表拼 | 保持原文（含标点） |
| 复杂度 | 与段落长度成正比 | O(1) |

**顺带解决**：现在「按句/按段渲染」的取舍（为了减少重建量）可以取消——整篇一次渲染，滚动也更自然。

---

### D. 点词跳转（已找到官方接口，更正此前结论）

**此前结论（错误）**：`Text` 没有命中接口，只能用「影子段落」或「逐词组件」。

**更正**：`TextController.getLayoutManager()`（**API 12+**）返回 `LayoutManager`，文档描述为
「用于获取文本布局信息，包括**行数、字形位置、行信息、字符绘制区域**」：

```
getLineCount()
getGlyphPositionAtCoordinate(x, y)                       坐标 → 字形位置
getCharacterPositionAtCoordinate(x, y, encoding?)        坐标 → 字符位置（API 24）
getLineMetrics(line)
getRectsForRange(range, widthStyle, heightStyle)         区间 → 矩形
getGlyphRangeForCharacterRange / getCharacterRangeForGlyphRange
```

要点：
- 坐标单位是 **px、相对组件**（点击事件是 vp，先相减再 `vp2px`）；
- `getLayoutManager()` 在控件未绑定或销毁时返回 `undefined`，必须判空；
- 显示与命中共用同一个 `Text`，**不需要影子段落，也不需要自绘**。

**同时解锁的第二个能力**：`getRectsForRange` 可以拿到任意字符区间的矩形 →
**高亮可以画一个矩形盖上去**，不改文字样式、不触发重排，比 `StyledString.replaceStyle` 更轻。

**结论**：
- 点词 = `getCharacterPositionAtCoordinate` → 字符下标 → 词下标 → `seekTo`；
- 高亮 = `getRectsForRange` + 叠一层矩形（首选），`StyledString` 作为备选。
### E. 扫描页（应当用官方控件）

**现状**：占位页；原计划自己搭 `CameraKit` + `XComponent` 预览 + 自研切边。

**官方** `DocumentScanner`（`vision-document-scanner`）：

> 提供拍摄文档并转换为高清扫描件的服务。仅需使用手机拍摄文档，即可**自动裁剪和优化**，并支持 jpeg、PDF 格式保存和分享；同时支持拍摄**表格**并生成表格文档。

- `onResult` 回调返回扫描结果
- 拍照模式枚举含 `AUTO`（自动拍照）/ `MANUAL`

**判断**：这正是我们需要的「拍课本」能力——**自动裁剪、透视校正、边缘检测都是它做的**，比我们之前试的云 API（腾讯/TextIn）更省事（端侧、免费）。代价是它是一个**控件**（自带界面），我们要评估能否嵌入自己的扫描页（自定义 UI 的程度）。

**待查**：控件是否支持自定义 UI、能否只取「裁剪后的图」而不进它的预览界面。

---

### F. OCR（继续用云端）

**现状**：云端 `qwen3-vl-plus` + `<<<PAGEn>>>` 分页标记。

**官方** `textRecognition`（`core-vision-text-recognition-api`）：
- `blocks → lines → words`，每个都有 `cornerPoints`（顺时针外框）
- 但**没有阅读顺序、没有分栏信息**，这正是我们当初放弃它的原因

**判断**：不变。端侧只适合「单栏、规整」的页面；课本对页/分栏必须靠 VLM。**可考虑混合**：端侧先跑一遍，如果检测到多栏（块的水平重叠）再走云端——省一半费用，但增加复杂度，暂不做。

---

### G. 语音提问（改用端侧识别）

**现状**：计划录音后整段上传云端 ASR。

**官方** `speechRecognizer`（`hms-ai-speechrecognizer`）：端侧实时识别，`createEngine` + `startListening`，支持 PCM 流式回调。

**判断**：改成**端侧识别出文本后再交给 LLM**。好处：
- 不上传音频（隐私）；
- 省一次大文件上传（录音 10 秒 ≈ 320 KB PCM）；
- 可以边录边出字，交互更跟手。

代价：端侧识别英文的准确率需实测（我们问的是中文「这个词什么意思」，中文识别应该没问题）。

---

### H. 存储

**现状**：`preferences` 存 Key/音色；`fileIo` 存课程（meta/text/audio/words/glossary）；`relationalStore` 存词典。

**判断**：够用，不改。注意点：
- 音频文件大（一篇 3 分钟 ≈ 5.7 MB），`fileIo` 读写用 `readSync/writeSync` 一次搬完没问题，但**应加流式**（分块）以避免长文章峰值内存；
- 课程元数据现在是每门课一个 `meta.json`，列表靠目录扫描——上百门课时可考虑加一个索引文件，先不做。

---

### I. 网络

**现状**：`http`（OCR/LLM）+ `webSocket`（TTS），超时手写，无重试。

**判断**：建议抽一个 `adapters/net.ts`：
- 统一超时、重试（指数退避）、错误码归一；
- 记录耗时（首包、总时长），便于定位；
- 现在 OCR 偶发 `WinError 10060` 类超时（PC 侧观察），端侧也要有重试。

---

### J. 权限与系统能力

| 能力 | 权限 | 现状 |
|---|---|---|
| 相机（扫描） | `ohos.permission.CAMERA` | 待加 |
| 麦克风（提问） | `ohos.permission.MICROPHONE` | 待加 |
| 网络 | `ohos.permission.INTERNET` | 已有？需确认 |
| 相册选图 | 免权限（Picker） | 已用 |

---

## 3. 建议路线

**P0（低风险、直接收益）**
1. 播放器改 `writeData` 回调 —— 删掉限流与位置补丁；
2. 高亮改 `MutableStyledString.replaceStyle` —— 每次切词 O(1)，取消「只渲染当前段」的妥协；
3. 问答回复用端侧 `textToSpeech`。

**P1（功能补全）**
4. 扫描页用 `DocumentScanner`（先确认能否自定义 UI）；
5. 语音提问用端侧 `speechRecognizer`。

**P2（体验增强）**
6. 点词跳转（影子段落，先做一致性实测）；
7. 网络层统一封装（重试/耗时）。

---

## 4. 待实测清单

| # | 要验证什么 | 方法 | 影响 |
|---|---|---|---|
| 1 | `Text` 与 `text.Paragraph` 行数/行区间是否一致 | 同一段长文本，两边取 `getLineCount` 与 `getActualTextRange` 对比 | 决定点词方案 |
| 2 | `DocumentScanner` 能否自定义界面 | 看控件文档的 API 面 + 真机试 | 决定扫描页形态 |
| 3 | 端侧 TTS 英文质量 | `listVoices` 听几个音色 | 决定问答朗读方案 |
| 4 | 端侧 ASR 中文短句准确率 | 录三句「这个词什么意思」 | 决定提问链路 |
| 5 | `writeData` 回调下 `framePos` 的行为 | 改造后重跑「音频迟到」指标 | 决定播放器实现 |

---

## 5. 补充：阿里云侧复审（2026-10-21，接入 llms.txt 之后）

阿里云的文档索引同样可达：`help.aliyun.com/zh/llms.txt` → `…/model-studio/llms.txt`（**2573 条 `.md`**），
正文是 `text/markdown`，可直接读。已缓存到 `docs/vendor/index/`。

### 5.1 TTS 有三种接入方式（我们用的是最原始的那种）

| 方式 | 文档 | 字级时间戳 | 特点 |
|---|---|---|---|
| **WebSocket 裸协议**（现状） | `qwen-audio-tts-websocket-api` | ✅ | 自己拼 `run-task/continue-task/finish-task`，处理二进制帧 |
| **HTTP 非实时** | `qwen-audio-tts-http-api` | ✅（`words[]`） | 一条 POST，返回 `output.audio.url` + `output.words`；流式模式返回 Base64 |
| **官方 HarmonyOS SDK** | `qwen-audio-tts-harmonyos-sdk` | ✅（`word_timestamp_enabled`） | 引入 `entry/libs/neonui.har`，`startStreamInputTts` + `onStreamInputTtsDataCallback` |

**判断**：我们手写的 WS 客户端不是唯一解。短期可以把后端换成 **HTTP**（代码量降一个量级，播放层不用改），
中期换 **官方 SDK**（拿到流式 + 官方维护）。

### 5.2 OCR 有更专门的模型

| 模型 | 文档描述 | 对我们的意义 |
|---|---|---|
| `qwen3-vl-plus`（现状） | 通用视觉理解 | 分页提示词效果好，但**没有字/行位置** |
| **`qwen3.5-ocr`** | 「文档解析、**文字定位**、关键信息提取全面升级；支持多轮对话、PDF 解析」 | 若给出行框，可自己重建阅读顺序 |
| `qwen-vl-ocr` | 「文档解析、文字定位（高精识别）、表格、公式、**图像旋转矫正**」 | 专攻 OCR |
| `vanchin/deepseek-ocr` | 0.216 元/M tokens | 便宜，之前因未开通没测 |

**判断**：我们当初用 VLM 是为了「分页 + 段落完整判断」，这部分仍然需要 VLM；但**文字质量**可能 `qwen3.5-ocr` 更好。
建议用已有的 5 张图 + `reference.txt` + `compare_ocr_models.py` 跑一次 A/B，模型名一换即可。

### 5.3 语音识别（CQR 用）

`qwen-audio-3.1-asr-flash`：短语音识别，多语种 + 中文方言，上下文增强、标点预测。
按音频时长计费。比「录制上传整段」更合适的是它的**流式**版本（边说边出字）。

### 5.4 一个可能的产品简化：**只保留一个 Key**

百炼同样托管 DeepSeek（`deepseek-v4-pro-0813`、`deepseek-v4.1-flash` 在 `models.md` 里）。

也就是说：**OCR + TTS + ASR + Agent 可以全用百炼一个 Key**，引导页从两个输入框减到一个。

**收益**：引导页更简单、Key 管理更少、计费集中。
**风险**：DashScope 托管版 DeepSeek 的 tool calling 行为/价格可能与官方 API 有差异，需实测。

### 5.5 成本小结（已实测/估算）

| 项 | 量级 |
|---|---|
| TTS（qwen-audio-3.1，446 字符 / 25 秒） | **0.39 分/篇**（实测 tokens） |
| OCR（qwen3-vl-plus，一页） | 约 0.02 分/页（估算） |
| ASR（一分钟） | 按秒计费，量级与 OCR 相当 |
| LLM（Agent 一轮） | 忽略不计 |

结论不变：**TTS 是唯一有成本压力的环节**，OCR/ASR/LLM 都很便宜。

### 5.6 对优先级的影响

- P1 增加：**OCR 模型 A/B（qwen3.5-ocr）**——只换模型名，成本极低；
- P2 增加：**单 Key 可行性验证**（用百炼的 DeepSeek 跑一轮 tool calling）；
- P0 不变：播放 `writeData`、高亮 `StyledString`、问答用端侧 TTS。