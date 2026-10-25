# 接口速查（写调用代码前看这里）

> 只列**用了的**和**踩过坑的**。单位/语义来自官方文档正文，`.d.ts` 里没有。

## 鸿蒙

### 文本与坐标
```ts
const lm: LayoutManager | undefined = textController.getLayoutManager();  // API 12+
lm.getLineCount(): number
lm.getCharacterPositionAtCoordinate(x: number, y: number,
    encoding?: TextEncoding): PositionWithAffinity | undefined   // 入参 px（相对组件）
lm.getRectsForRange(range, RectWidthStyle.TIGHT, RectHeightStyle.TIGHT): TextBox[]
lm.getLineMetrics(line): LineMetrics      // width/topHeight/height/baseline
```
- **返回的 position 是 UTF-8 偏移**；要 UTF-16 就用 3 参重载 `TextEncoding.TEXT_ENCODING_UTF16`。
- `TextBox.rect` 是 `common2D.Rect`：只有 `left/top/right/bottom`。
- `TextController` / `LayoutManager` 是**全局类型**，不在 `@kit.ArkUI` 的导出里。

### 音频播放
```ts
audio.createAudioRenderer(options)
renderer.on('writeData', (buf: ArrayBuffer) => audio.AudioDataCallbackResult.VALID)
renderer.getAudioTimestampInfoSync()   // { framePos, timestamp }  timestamp 是 ns 单调时钟
renderer.getLatency(audio.AudioLatencyType.LATENCY_TYPE_ALL)  // 路由估计值，不要拿来补偿 A/V
```
16kHz 单声道 s16le：**16 帧/毫秒**，**32 字节/毫秒**。

### 音频录制
```ts
audio.createAudioCapturer(options)     // source: SOURCE_TYPE_MIC（需 MICROPHONE 权限）
capturer.on('readData', (buf: ArrayBuffer) => { const copy = buf.slice(0); /* 尽快返回 */ })
capturer.start() / stop() / release()
```
文档警告：回调 buffer 会被复用（必须复制）、回调里别做耗时活、别在回调里调 start/stop/release。

### 端侧 TTS（回答朗读用）
```ts
import { textToSpeech } from '@kit.CoreSpeechKit';
createEngine({ language: 'zh-CN', person: 0, online: 0 })
engine.speak(text, { requestId, extraParams: { ... } })
// onData(requestId, audio: ArrayBuffer, response: { sequence, audioType: 'pcm' })
```
**没有词级时间戳**——所以只能用于回答朗读，不能用于课文高亮。

### 文档扫描控件
```ts
import { DocumentScanner, DocumentScannerConfig, SaveOption, DocType, FilterId,
         ShootingMode, EditTab } from '@kit.VisionKit';
DocumentScanner({ scannerConfig, onResult: (code, saveType, uris) => {} })
// code: 200 成功 / -1 取消 / 1008601001 uris 无效（API 17+）
```
- 不能被其他组件/窗口遮挡；`maxShotCount` ≤ 50；`isGallerySupported` 决定图库入口。
- `ShootingMode.AUTO` 会乱拍；`editTabs: []` 会连删除一起没。

### 权限
- `ohos.permission.INTERNET`（已声明）
- `ohos.permission.MICROPHONE`（已声明 + 运行时 `requestPermissionsFromUser`）
- 相机不需要我们声明（扫描控件自己处理）

## 阿里云（百炼）

**Compatible 端点**：`https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`

### TTS（当前走 SDK，这里留作参考）
```json
{"model":"qwen-audio-3.1-tts-flash",
 "input":{"text":"...","voice":"Emily_v3.1","format":"pcm","sample_rate":16000,
          "word_timestamp_enabled":true,"language_hints":["en"]}}
```
- 音色必须带 `_v3.1` 后缀；`language_hints:["en"]` 不加会把 `1990s` 读成「一千九百九十秒」。
- SDK 的 parameters 同名字段：`model/voice/format/sample_rate/volume/rate/pitch/word_timestamp_enabled/language_hints`。

### 提问解析（Omni）
```json
{"model":"qwen3.8-omni-flash","modalities":["text"],"reasoning_effort":"none","stream":false,
 "messages":[{"role":"user","content":[
   {"type":"text","text":"<系统提示 + 课文 + 上下文>"},
   {"type":"input_audio","input_audio":{"data":"data:audio/wav;base64,...","format":"wav"}}]}]}
```
- `input_audio.data` **可以是 base64，也可以是 URL**（文档示例用 URL）。
- 计费：音频 token = 时长(秒) × 7；不足 1 秒按 1 秒。
- 输出契约见 `decisions.md` D5，数值口径见 D16：
  `{sentence_id, surface, intent, question}`；字符区间 `start/end` 由**代码** `indexOf(surface)` 算，模型不给。
  **不再有 `certainty`**（D17）：面板直接显示 `question`，由用户判断 AI 有没有理解错。

### OCR
```json
{"model":"qwen3-vl-plus","messages":[{"role":"user","content":[
   {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}},
   {"type":"text","text":"<转写提示词>"}]}]}
```
提示词要点（现行版在 `adapters/ocr.ts`）：只转写正文、去页眉页脚页码注释、段落之间空行、**段内不换行**、
去单词后的上标编号、保留标题与段落编号、只输出正文。

## DSH 侧

### 文档检索 MCP（已装）
| server | 工具 | 用途 |
|---|---|---|
| `harmonyos` | `searchDocuments` / `getDocumentsById` | 鸿蒙文档（语义检索 + 全文） |
| `aliyun` | `AlibabaCloud___SearchDocuments` / `GetDocument` / `GetDocumentTree` / `GrepDocuments` | 阿里云文档 |

阿里云那侧还有 `CallCLI` / `RunScript` / `RunIaC` 等**能操作真实云资源**的工具，非必要不用。

### 插件目录
`dsh-plugins/docs-mcp/`，配置型 bundle（无代码）：
`package.json` + `cordis.patch.yml` + `locale/*.json` + `icon.svg`。安装走 Harness 的 `plugin_manager`。

## DeepSeek（主 Agent）

**接口**：OpenAI 兼容 Chat Completions，直接用 `http.createHttp()` 调，不引 SDK。

```
POST https://api.deepseek.com/chat/completions
Authorization: Bearer <DeepSeek API Key>
Content-Type: application/json

{ "model": "deepseek-chat",
  "messages": [...],
  "tools": [ {"type":"function","function":{name,description,parameters}} ],
  "temperature": 0 }
```

- 模型默认 `deepseek-chat`（`DeepSeekClient` 构造参数可换 `deepseek-reasoner`）；
- 响应取 `choices[0].message`：给了工具调用时 `content` 为 `null`、带 `tool_calls`；
- 循环在 `agent/loop.ts`：执行 `tool_calls` → 以 `role:'tool'` + `tool_call_id` 回填 → 再请求，最多 6 轮；
- 超时：连接 15s、读取 90s；未设 `tool_choice`（默认 auto）、未开流式（回答短，不值得）。
- 实现在 `adapters/llm.ts`（`DeepSeekClient.complete(messages, tools)`）。

### List 的「列表操作」能力边界
- **删除项**：`ListItem.swipeAction({ end: { builder, actionAreaDistance, onAction } })` 左滑滑出删除按钮；
  滑过阈值触发 `onAction` 可直接删；`ListScroller.closeAllSwipeActions()` 收起。
- **拖拽排序**：`.onMove(from, to)` 挂在 **ForEach** 上（文档示例 12），不是 List。
- **批量删除**：`enableEditMode` + `editModeOptions`（API 23/26），重量级。
- **没有**「添加项按钮」这类内置 UI：加号要自己放（我们用右下角圆形 ＋）。

### 系统符号图标（已实测可用）
| 用途 | 资源名 | 用法 |
|---|---|---|
| 播放 | `sys.symbol.play_fill` | `SymbolGlyph($r('sys.symbol.play_fill'))` |
| 暂停 | `sys.symbol.pause` | 同上 |
| 停止 | `sys.symbol.stop_circle_fill` | 同上（暂未用） |
| 麦克风 | `sys.symbol.mic_fill` | 同上 |
| 新增 | `sys.symbol.plus` | 同上（文库右上角悬浮） |
| 返回 | `sys.symbol.chevron_left` | 同上（Reader / Editor / Glossary 顶栏） |

**名字从哪来（顺序别搞反）**：
1. 先看设计规范「按钮」「标题栏」页（`docs/vendor/index/docs-ux-design.txt` 里能搜到 `.md` 链接），
   它们会直接告诉你该用哪个控件；
2. 文档里只出现 `$r('sys.symbol.ohos_wifi')` 这类示例，**逐条名单不在开发者文档里**；
3. 实在要确认某个名字存不存在，才去 SDK 做**存在性核对**（`ets-loader/sysResource.js` 的 `symbol:` 段，
   从第 3372 行起），结论必须标注「SDK 核对，非文档依据」——**不到万不得已不要翻 SDK**（见 AGENTS.md §0.1）。

- **坑 1**：`$r()` 只接受**字面量**，不能用三元表达式拼名字 → 用 `if/else` 两个分支各写一个 `SymbolGlyph`。
- **坑 2**：PowerShell 里写 `$r(` 会被当变量插值吞掉 → 用 python/here-string 写文件。
- **坑 3**：`symbol` 段的键不一定带 `ohos_` 前缀（`plus` / `chevron_left` 就没有，`ohos_trash` 有），两种都存在；
  名字写错是**编译期报错**，所以一次编译就能筛掉错误候选。

### 打包目录成 zip（`@kit.BasicServicesKit` 的 zlib）
```ts
import { zlib } from '@kit.BasicServicesKit';
const options: zlib.Options = {
  level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
  memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
  strategy: zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY
};
await zlib.compressFile(目录路径, 目标zip路径, options);   // inFile **可以是目录**
```
- 目录内容成为 zip 的**顶层条目**（压 `files/course` → 解压得 `<课程id>/…`）。
- API 13 起 in/out 路径不允许含 `../`（否则 900001/900002）。
- 解压用 `zlib.decompressFile(zip, 目标目录, options)`。
- 实测：11 门课（源约 50MB）→ 17.1MB，48 条目，完整性 OK。

### TTS 文本清洗 / 标点（2026-10-23）
- `qwen-audio-3.1-tts-flash`（非实时 HTTP `SpeechSynthesizer`）**文档没有标点支持清单**；
- 两种兜底：`hot_fix`（数字/缩写/**符号**读法不符预期时用，例：`@` 读成"艾特"）、`language_hints`（目标语言）；
- **SSML** 仅限「复刻音色或支持列表内的系统音色」+ 非流式/单向流式，`<break>` 只能控停顿；
- 实测 `—`(U+2014) 朗读异常 → 已在 `QwenTts.normalizeForTts()` 里统一换成 `, `（含 U+2013/2012/2015/2212）；
- 细节与判据落盘：`docs/vendor/tts-punctuation.md`。

### 导出到用户选的目录（2026-10-23 实测）
```ts
const opt = new picker.DocumentSelectOptions();
opt.selectMode = picker.DocumentSelectMode.FOLDER;   // 目录选择，单次 1 个
opt.maxSelectNumber = 1;
const uris = await new picker.DocumentViewPicker(ctx).select(opt);   // file://docs/storage/Users/...
const dirPath = decodeURIComponent(uris[0].replace('file://docs', ''));  // → /storage/Users/...
// ↑ 一定要 decode：picker 会把中文/特殊字符百分号编码（/文库 → /%E6%96%87%E5%BA%93）
fs.mkdirSync(dirPath + '/' + name);                                  // 只认路径
fs.copyFileSync(srcPath, dirPath + '/' + name + '.bin');             // 只认路径
```
- `fs.copy(uri, uri)`（拷目录）与 `fs.mkdir(uri)` **在本机实测失败**：13900020 / 13900002。
- 授权是**临时**的：退出后台失效；要跨会话保留得用 `fileShare.persistPermission`（未做）。
- 别用 read→write 循环拷大文件（会把文件截断成一块）。

### TextInput 密码样式（查文档：ts-basic-components-textinput）
```ts
TextInput({ text: value, placeholder: 'sk-...' })
  .type(InputType.Password)      // 掩码显示
  .showPasswordIcon(true)        // 末尾「眼睛」图标，点一下切明文（控件自带）
```
- 另有 `.showPassword(boolean)` 可**用代码**控制显隐；`.onSecurityStateChange(cb)` 能收到"用户点了眼睛"的事件。
- 注意：`showPasswordIcon` 只在密码模式下有意义；掩码字符是系统默认圆点，不用自己画。

### 版本号 / 安装升级 / 发布（2026-10-23 查文档，详见 `docs/vendor/harmonyos-version-and-release.md`）
- `app.json5`：`versionCode` **整数、[0, 2147483647]、越大越新**；`versionName` 只是文字描述。
- `bm install -r` = 覆盖安装（缺省即覆盖）；`hdc install -r` 等价。
- `bm uninstall -k` = **卸载时保留数据**（默认不保留）；`bm clean -d` = 清数据目录。
  → **升级只用 install -r，永不 uninstall**。
- `bm install -d`（API 23+）才允许**降级**，且仅 `app_gallery` / debug 签名的三方应用。
- 签名坑：`build-profile.json5` 的 `products.signingConfig` 缺失 → 签名失效（9568320）；
  debug Profile 必须含设备 UDID（9568423）；**app_gallery + release 签名的包不能用 bm 安装**（9568402）。
- 数据迁移兜底：`BackupExtensionAbility`（API 10+）+ `backup_config.json`，单应用迁移上限 **15 分钟**，
  框架在扩展执行完后清空备份目录。
- 发布：AGC 上传 → 审核 → 上架/定时上架；支持**分阶段发布**（7 天内按百分比，可暂停、可提速到全网）与 Publishing API。

### 系统带底板的圆形图标按钮 = 标题栏控件给的（不是自己画圆）
设计规范「标题栏」原文（`docs/vendor/harmonyos-ux-titlebar.md`）：
> **电脑设备**：「在电脑场景下，标题栏使用更小的字体提高界面信息密度，**同时去掉了圆形底板**。」

→ 反证：**手机/平板上的标题栏图标按钮默认就有圆形底板**（返回键、右侧菜单/更多按钮都是），
再叠「沉浸光感」材质就有了阴影/高光。所以"圆形带阴影的新建/返回/侧边栏按钮"是**控件自带的**，不用手写。

**官方预设控件（按推荐度）**：
| 方案 | 模块 | 起始版本 | 说明 |
|---|---|---|---|
| **`HdsNavigation` / `HdsNavDestination`**（HDS 设计系统控件） | `import { HdsNavigation, HdsNavDestination } from '@kit.UIDesignKit'` | **5.1.0(18)** | 系统应用同款；标题栏自带返回键/菜单/圆形底板；`titleBar({content:{title,menu}})`；`systemMaterialEffect` 开材质；`mode(Split)` + `navBarWidth` 可做侧边栏 |
| `Navigation` / `NavDestination`（ArkUI 自带） | `@kit.ArkUI` | 9+ | 同样自带返回键 + menus 底板；材质要 `NavigationTitleOptions.systemMaterial`（API 26 沉浸光感） |
| `SideBarContainer` | `@kit.ArkUI` | 9+ | 只做「打开侧边栏」 |
| `ComposeTitleBarV2` | `@kit.ArkUI` | 26.0.0 | 纯标题栏组件（标题+副标题+右侧菜单项），不含路由 |
| ~~`ToolBar`~~ | `@kit.ArkUI` | 10 | 是**底部**工具栏，不是标题栏，别混 |

- 系统能力：`SystemCapability.UIDesign.HDSComponent.Core`；**只有 Stage 模型可用**。
- 关键点：`HdsNavigation` 是**页面根容器**，子页面必须是 `HdsNavDestination`（路由走 `NavPathStack`）——
  也就是说用它就等于把 `router.pushUrl` 那套换掉，不是加一个按钮那么简单。
- 配套：`hdsMaterial`（材质档位）、`HdsSideBar` / `HdsSideMenu`（侧边栏）。
- 文档：`docs/vendor/harmonyos-hds-navigation.md`、`docs/vendor/harmonyos-ux-titlebar.md`、
  `docs/vendor/harmonyos-ux-button.md`；索引在 `docs/vendor/index/docs-ux-design.txt`（搜「标题栏」「按钮」）。

### 百炼 TTS：HTTP + SSE（现用，实测 2026-10-23）
```
POST https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer   ← 公开域名可用，无需 WorkspaceId
Authorization: Bearer <key>
Content-Type: application/json
X-DashScope-SSE: enable

{"model":"qwen-audio-3.1-tts-flash",
 "input":{"text":"...","voice":"Emily_v3.1","format":"pcm","sample_rate":16000,
          "word_timestamp_enabled":true,"language_hints":["en"]}}
```
- 响应 `text/event-stream`：每帧一行 `data: {json}`，帧间空行。
- 帧内 `output.type`：`sentence-begin` / `sentence-synthesis` / `sentence-end`（最后一帧只带 `usage`）。
- **音频**：`output.audio.data` 是 **base64 PCM**（流式才有；非流式给 `audio.url`，有效期 24h）。
- **时间戳**：`output.sentence.words[]`（`text/begin_time/end_time`）；
  `sentence-begin` 帧里的 words **可能不全，以 `sentence-end` 为准**。
- `sample_rate` **默认 22050**，必须显式传 16000（播放器按 16k 算字节）。
- 实测（5200 字符）：15 个 sentence-end、934 词、329 秒音频、首包 0.7s、总 28.3s。

**ArkTS 侧怎么收 SSE**（`@kit.NetworkKit`）：
```ts
const req = http.createHttp();
const dec = util.TextDecoder.create('utf-8');
let pending = '';
req.on('dataReceive', (data: ArrayBuffer) => {
  pending += dec.decodeWithStream(new Uint8Array(data), { stream: true });  // 多字节跨片
  // 反复切 pending 里的 '

'，取出 data: 行 JSON
});
req.on('dataEnd', () => { pending += dec.decodeWithStream(new Uint8Array(0), {stream:false}); /* 收尾 */ });
await req.requestInStream(url, options);   // readTimeout 是「总时长」，默认 60s，长文本要调大
// base64 → 字节：buffer.from(b64, 'base64').buffer
```

### DeepSeek 单轮调用（无工具）+ JSON Output
```ts
const client = new DeepSeekClient(key);
const msg = await client.complete([
  { role: 'system', content: ANSWER_SYSTEM_PROMPT },
  { role: 'user', content: prompt }
], [], true);   // 第 2 参 tools=[]；第 3 参 jsonMode=true → response_format=json_object
```

- **JSON Output（官方指南 `…/zh-cn/guides/json_mode`）**：`response_format={'type':'json_object'}`，
  **保证输出合法 JSON**；要求 prompt 里有 `json` 字样、并给出期望 JSON 的样例；建议设 `max_tokens` 防截断。
  官方标注**可能返回空 content**，调用方要处理。
- 契约（`core/glossary.ts` 的 `ReplyJson`）：`type`(word/collocation/other) / `answer` / `word?` / `words?`+`phrase?`。
- 一个真实限制：`complete` 的 `content` 是 `string`（空回复为 `''`），不再有 `tool_calls` 分支需要处理。
- 提问链路的 prompt 组装、类型归一、YAML 落盘都在 `core/glossary.ts` + `pages/Reader.ets`。

### HdsNavigation 当"页面外壳"（实测可用，2026-10-22）
```ts
import { HdsNavigation, HdsNavigationTitleMode, TextStyleMode } from '@kit.UIDesignKit';

HdsNavigation() {
  Column() { /* 页面内容，记得 padding({ top: 56 }) */ }
}
.titleBar({
  content: {
    title: { mainTitle: '文库', subTitle: '可选' },
    backIcon: { icon: $r('sys.symbol.chevron_left'), label: '返回', action: () => router.back() },
    menu: { value: [{ content: { label: '保存', type: TextStyleMode.NORMAL, action: () => this.save() } }] }
  }
})
.titleMode(HdsNavigationTitleMode.MINI)   // 固定 56vp 标题栏
.mode(NavigationMode.Stack)               // ★ 必须，否则平板走 Split
.hideBackButton(true)                     // 首页（文库）隐藏返回键
.hideToolBar(true)
```

- **它给的东西**：标题栏（左返回/中标题/右菜单）的**圆形底板**、系统字重与间距、
  菜单图标 `IconStyleMode` / 文字菜单 `TextStyleMode.NORMAL`（胶囊文字按钮）、沉浸光感材质。
- **不给的东西**：路由。`backIcon.action` 自己接，所以可以继续用 `router`（见 decisions D31）。
- **必须注意**：`mode(Stack)`；内容自己留 `top: 56`；`hideBackButton` 只管返回键显隐。
- 依赖：`SystemCapability.UIDesign.HDSComponent.Core`，起始 **5.1.0(18)**，仅 Stage 模型。
- 文档：`docs/vendor/harmonyos-hds-navigation.md`（HdsNavigation）、`harmonyos-ux-titlebar.md`（设计规范标题栏）。

### 流式 TTS 的「句级」能力（HarmonyOS Next SDK，官方文档原文）
回调：

```ts
onStreamInputTtsEventCallback(event, task_id, session_id, ret_code, error_msg, timestamp, all_response)
```

| 事件 | 说明（文档原文） |
|---|---|
| `SYNTHESIS_STARTED` | 合成开始，可以准备播放 |
| `SENTENCE_BEGIN` | 服务端检测到**一句话的开始** |
| `SENTENCE_SYNTHESIS` | 增量返回合成结果，含最新音频和时间戳；**句内全量、句间增量** |
| `SENTENCE_END` | 服务端检测到**一句话结束，返回该句的全量时间戳** |
| `SYNTHESIS_COMPLETE` | 全部音频已回调；**不表示播放器已播放完毕** |
| `TASK_FAILED` | 失败，看 `ret_code` / `error_msg` |

- `timestamp`：该次事件的时间戳信息（字符串）；`all_response`：完整返回 JSON，可自行解析。
- **对高亮的意义**：不需要做词级对齐——`SENTENCE_BEGIN` 可以立刻切到新句，
  `SENTENCE_END` 给出该句**全量时间戳**（起止毫秒），按序累积即可得到每句的播放区间。
- **文档没写**：分句所用的标点是句号还是逗号 → 只能实测（一句带逗号的话数 `SENTENCE_END` 次数）。
- 缓存文档：`docs/vendor/aliyun-tts-harmonyos-sdk.md`、`docs/vendor/tts-harmonyos-sdk.md`
- **能不能返回「原文里第几句/第几个字」？——不能。**
  - `timestamp` / `all_response` 只给**时间**与**发音单元**信息；
  - 智能语音交互的 `subtitles` 虽有 `begin_index/end_index`，但官方明确：**「不是原始字符串的字符偏移」**，
    而是「文本单元的起始索引」（"Hello world!" 两个词 → `0,1` / `1,2`）；
  - 所以句与原文的对应只能**自己按顺序映射**（TTS 第 k 句 ↔ 原文第 k 句），并对"多切/合并"做兜底。
- 本地文档见 `docs/vendor/INDEX.md`

### 百炼 TTS 服务端事件（qwen-audio-3.1-tts-flash/plus）
本地副本：`docs/vendor/qwen-tts-server-events.md`、`docs/vendor/qwen-realtime-tts-guide.md`

| 子事件 | 关键字段 |
|---|---|
| `sentence-begin` | `sentence.index`、**`original_text`（分句后的原文句子）** |
| `sentence-synthesis` | 音频帧标识（每个事件后紧跟一帧 binary 音频） |
| `sentence-end` | `sentence.words[]`（`text/begin_index/end_index/begin_time/end_time`）、**`original_text`**、`usage.characters` |
| `task-finished` | 任务结束，可复用连接 |

- `begin_index/end_index`：**字在句子中的位置索引**（句内），不是全文偏移；
- **`original_text` 是原文句子**——句级定位靠它，不靠猜。
- 计费：`-flash` 按 token，`-plus` 按字符（`usage.characters` 在 `sentence-end` 返回）。

**逐条核对后补充（2026-10-22，全部来自本地 docs/vendor 原文）**：

1. `original_text` 定义原文：「对用户输入文本进行**分句后的句内容**」→ 就是原文句子，可直接 `indexOf` 定位。
2. ⚠️ **「最后一个句子可能没有此字段」** → 必须兜底（用上一句的 end、或句序列顺序）。
3. `begin_index/end_index` 是「字在**句子中**的位置索引」→ **句内**偏移，不是全文偏移。
4. `sentence-synthesis` 事件**与其后的音频数据帧一一对应，不会错位** → 可按句切分 PCM，
   句高亮区间用「该句 PCM 的字节区间」算比用时间戳更硬（字节 / 32 字节每毫秒）。
5. HTTP 接口（`tts-http-api.md` / `non-realtime-tts-user-guide.md`）**也有同样的事件与 `original_text`**，不只 WebSocket。
6. **文档没有写分句用的标点规则**（全文搜「标点」只在 CosyVoice `instruction` 计数字数处出现）→ 只能实测。
7. 智能语音交互 RESTful：`data.sentences[].text` 也是句子文本 + `begin_time/end_time`（毫秒）。

### 能否「一句一句上传」并拿到每句的时间戳？——能（实时接口）
依据：`docs/vendor/realtime-tts-user-guide.md`

- 实时（WebSocket）支持**分段输入文本、逐段返回音频**；
- 客户端发 `input_text_buffer.append` 追加上文；**发 `input_text_buffer.commit` 可主动提交合成**；
  全部发完再 `session.finish`；
- 所以「一句 append + 一句 commit」→ 服务端按**我们提交的单位**合成，`sentence` 事件与 `original_text`
  就是这一句 → **天然句级**，且**不破坏上下文**（前面 append 的内容仍在同一会话里）。

对比：
- 非实时（HTTP）：一次提交完整文本、SSE 流式输出，**分句由服务端决定**，不可控；
- 我们现在的做法（整篇一次流式合成）：TTS 自己分句，1384 字符只分 2 句 → 粒度太粗。

**HarmonyOS SDK 的实际能力（查文档确认）**：只有三个方法 ——
`startStreamInputTts`（建连）→ **`sendStreamInputTts(text)` 可多次发送文本片段** → `stopStreamInputTts`（发完调用）。
文档原文：「按业务需要多次发送文本」，但**没有 commit / flush**，所以**无法强制"一句一合成"**，
分句权仍在服务端。

**"一次性请求、拿到多个分句"的正解 = 非实时 HTTP 接口**（`non-realtime-tts-user-guide.md` / `tts-http-api.md`）：
一次 POST 提交整篇，返回 `sentences[]`（每句 text + begin/end 毫秒），无需频繁传输。
`docs/vendor/aliyun-tts-restful-api.md`（智能语音交互）也是同一形态：`data.sentences[].text/begin_time/end_time`。

### HarmonyOS SDK 也有「非实时」语音合成（我之前漏查了）
本地副本：`docs/vendor/aliyun-tts-nui-harmonyos-sdk.md`（从 isi 的 llms.txt 索引找到）

- 模式：`new NativeNui(Constants.ModeType.MODE_TTS, ''`（对比流式是 `MODE_STREAM_INPUT_TTS`）；
- 流程：`tts_initialize` → `setParamTts`（合成参数）→ **`startTts`** → `onTtsDataCallback` 收音频 → `TTS_EVENT_END` → `tts_release`；
- **`enable_subtitle: "1"`** 开启后：「数据回调**交替返回时间戳信息和音频**；`info` 为 JSON 时间戳，`buffer` 为音频」；
- ⚠️ 文档提示：「**长文本语音合成需另行开通，计费也与短文本不同**」。

**意义**：这是「一次请求合成整篇 + 拿时间戳」的路径，和 RESTful API 同源；
其 `info` JSON 的字段（是否含句子/词文本、是否 `original_text`）**需要实测**。

### 智能语音交互的 TTS 计费（本地文档：docs/vendor/aliyun-isi-pricing.md、aliyun-isi-billing.md）
| 服务 | 计费方式 | 单价 | 备注 |
|---|---|---|---|
| 语音合成（短文本） | **按调用次数** | **3.50 元/千次**（梯度降到 1.20） | **100 字符记 1 次**；单次请求最多 **300 字符** |
| 长文本语音合成 | **按合成字数** | **3 元/万字**（示例：1000 字 = 0.30 元） | 需另行开通 |
| CosyVoice 大模型 | 按字符 | **2.00 元/万字符** | 1 个汉字按 2 字符 |

- 规则原文：「语音合成的计费调用次数按每次请求传入的 **UTF-8 编码字符数**计算」。
- 换算（500 字符的一篇课文）：
  - 短文本：2 次 ≈ **0.7 分**（且天然按 300 字符切分 → 分句更细）；
  - 长文本：≈ **15 分**（贵约 20 倍）；
  - 对比我们现在用的百炼 `qwen-audio-3.1-tts-flash`：**≈0.39 分/篇**（按 token）。
- **结论**：若走「非实时 + 时间戳」，优先用**短文本接口**（≤300 字/次），既便宜、切分又更细；
  长文本接口除非必要不要用。

### 百炼也有「非实时」HTTP 接口（同模型同价）
本地文档：`docs/vendor/tts-http-api.md`

```
POST https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer
Authorization: Bearer $DASHSCOPE_API_KEY
{ "model": "qwen-audio-3.1-tts-flash", "input": { "text": "..." , ... } }
```

- **同模型、同计费口径**（按 token），不是换产品；注意端点是 `{WorkspaceId}.<region>.maas.aliyuncs.com`，
  不是 `dashscope.aliyuncs.com`；
- 支持**非流式**与**流式（SSE）**两种输出；
- 响应含 `output.sentence`（`index` / `words[text, begin_index, end_index, begin_time, end_time]`）
  与 `output.audio`（非流式时 `data` 为空，给 `url`，**有效期 24 小时**）；
- ⚠️ **`word_timestamp_enabled`「仅在流式输出模式下可用」** → 非流式可能拿不到字级时间戳，
  句级字段是否仍在需实测；
- 另有 `hot_fix`（自定义发音/文本替换）等参数。

**⚠️ 别混淆两个产品（重要）**
| | 百炼 Model Studio（我们在用） | 智能语音交互 ISI |
|---|---|---|
| 端点 | `dashscope.aliyuncs.com` | `nls-gateway-cn-shanghai.aliyuncs.com` |
| 计费 | **按 token / 字符**（qwen-audio-3.1-tts-flash ≈0.39 分/篇） | **按次数或字数**（短文本 3.5 元/千次、长文本 3 元/万字） |
| 模型/音色 | qwen 大模型音色 | ISI 自有音色（xiaoyun 等）+ CosyVoice 大模型 |
| 时间戳 | 句子级 `original_text`（我们已用） | 短文本 `sentences[]` / `enable_subtitle` 的 `info` |

所以「0.39 分/篇」与「0.7 分/篇」**不是同一个模型的两个接口**，而是**两个产品、两套模型**。
同一产品内部的 HTTP / WebSocket / SDK 调用，计费项与单价是**一致的**（同口径计费）。
**换到 ISI 意味着换音色**，不只是换接口——音质会变，要先听再决定。

### 「百炼有没有 HarmonyOS SDK」与「neonui 支持哪些服务」
- **百炼没有 HarmonyOS 专用 SDK**。它的接入方式是 HTTP：
  - OpenAI 兼容（`/compatible-mode/v1/...`）
  - DashScope 原生（`/api/v1/services/...`）
  - 官方 SDK 只有 Python/Java/Node/Go 等；**在 HarmonyOS 上用 `@kit.NetworkKit` 的 `http` 直接发请求**即可
    （我们的 OCR / Omni 就是这么做的）。
  - → 所以「非实时 TTS」不需要 SDK，HTTP 一把梭。
- **neonui（智能语音交互 HarmonyOS SDK）支持的服务**（本地文档 `aliyun-tts-nui-harmonyos-sdk.md`）：
  一句话识别、实时语音识别、**语音合成（短文本）**、**实时长文本语音合成** 均「是」；
  另有语音唤醒、语音对话等能力（同一 SDK 其他页面）。
  - 它连的是 `nls-gateway`（ISI 产品），不是百炼。

### 实测：百炼 TTS 到底怎么分句（2026-10-22，真实 SSE 调用）
测试文本（125 字符，含破折号/感叹号/千分位/年份/序数缩写）：
`On the 1st of May — a sunny day! — we counted 1,250 visitors in 2024. Wasn't that surprising? The 3rd attempt finally worked.`

结果：**只返回 1 个 sentence**（`index=0`，`original_text` = 整段 125 字符，28 个 words，80–11600ms）。
而之前 1384 字符的课文被分成 2 块（≈1200 + 180）——**分句只按长度上限（≈1200 字符），不按标点**。

另一个关键发现：`words[].text` 是**规范化后的读音单元**（含前导空格）：
- `1st` → `' first'`；`1,250` → `' one' / ' thousand' / ' two' / ' hundred'`；
- `, a`、`! , we` 这种把标点黏在词上的形态；
- `begin_index/end_index` 是**单元序号**（0-1、1-2…），不是字符偏移。

→ **词级高亮彻底不可行**；句级也只能靠「我们自己控制每次请求的文本（每次 1 句）」来实现。
计费按 token/字符，**多分几次请求不改变总价**，只增加延迟。

### 语音提问（CQR）的上下文怎么给模型
- **调用**：`CqrParser.parse(wavBase64, sentences, currentIndex, pauseWord)`，内部组装成一条 prompt：
  `SYSTEM`（分句规则+JSON 契约）+ **全文句子列表（带编号）** + 「用户正读到第 N 句：<该句原文>」+ 「在读到「某词」时暂停」+ 「请解析这段语音里的提问」。
  音频以 `input_audio`（wav base64）一起送入，模型既能听音频、又能看全文句子表 → 指代（"这个/这句"）靠 `currentIndex` 定位。
- **曾经的缺陷（已修）**：页面把 `currentIndex` 写死成 `1`，于是不管读到哪都按第 1 句解析。
- **现在的定位**：先用**当前词**在原文里 `indexOf`（**顺序游标 `posCursor`**，整体 O(n)）拿字符位置 →
  落到第几句；命中不了（数字/缩写被规范化）才退回按播放比例估算。
- **提示词已瘦身**：不再给整篇句子列表、也不再出现「第 N 句」这种数字，只给
  `当前句：<一句原文>` + `当前词：<词>` —— 模型不可能去数第 N 句，数字只会浪费 token。
- **输出契约最终只剩一个字符串**：模型直接用一句中文说清「用户在问什么」。
  不再要 `surface`（主 Agent 自己能从课文判断）、不再要 `intent`（主 Agent 能从问题判断）、
  连 JSON 都不要（纯文本是默认行为，不必写进提示词）。
- **实际 prompt**：`你在听一段英语课文朗读中的语音提问。用一句中文说清用户在问什么。\n\n当前句：…\n当前词：…`
- **成本**：每次提问 = 一段音频（约 2–4 秒）× 7 token/秒 + 全文 prompt 的文本 token。
- **可改进**：比例估算是近似；更准的做法是用 TTS 的句级区间（`sentences.json` 里已有 begin/end）反查当前句。

### 主 Agent 的「上下文」是什么
- **大模型是无状态的**：没有服务端会话，也不「保存记忆」。所谓上下文，就是**每次请求里 `messages` 数组的文本**。
- 我们的实现（`agent/loop.ts`）：`run(userText, systemPrompt)` 每次**新建** `[system, user]` →
  **每一问都是独立的，不携带上一轮问答**；右侧对话区只是 UI 上累积的字符串，**不参与推理**。
- 代价对比：带上历史会让每次请求的 token 线性增长（历史越长越贵）；
  若要支持追问（「那它和 persist 有什么区别？」），应只带**最近 2–3 轮**。
- 结论：需要「连续对话」时必须由**客户端**把历史拼进 messages，模型侧不会自动记住。

### DeepSeek 的「上下文压缩」是什么（2026-10-22 查文档）
结论：**DeepSeek API 没有「压缩上下文」这种能力**，它提供的是**上下文硬盘缓存（前缀缓存）**。
- 对所有用户默认开启，无需改代码；每个请求都会触发缓存构建；
- 后续请求若与之前请求在**前缀上完全匹配某个「缓存前缀单元」**，该部分从缓存读取，计入「缓存命中」；
- 落盘时机有三种：请求的**用户输入结束位置**与**模型输出结束位置**各产生一个前缀单元、
  系统检测到**公共前缀**时单独落盘、长输入/输出按**固定 token 间隔**切分落盘（受 Sliding Window Attention 影响）；
- 例：第一轮 `A+B`，第二轮 `A+B+C` → 第二轮能完整匹配 `A+B` 这个单元，命中缓存。

**关键区别**：
| | 缓存 | 压缩 |
|---|---|---|
| 做什么 | 复用相同前缀的 KV，**省 token 钱/加速** | 把旧对话换成摘要，**上下文变短** |
| 上下文长度 | 不变 | 变短（**有损**） |
| 谁实现 | DeepSeek 服务端 | **客户端**（如 Harness 的 checkpoint 摘要） |

**对我们的意义**：
1. `AGENT_SYSTEM_PROMPT` 固定 + 课文前缀固定 → 连续提问**大概率命中缓存**，实际花费低于名义 token；
2. 想要「压缩」只能自己在客户端做：只带最近 N 轮（见待办 P8）。
