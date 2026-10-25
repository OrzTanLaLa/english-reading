# 决策记录（ADR 风格）

> 只记录**已被否决或已拍板**的，避免后来者重复讨论。每条含「理由」与「当初的替代方案」。

## D1 产品形态
- **决定**：拍课本 → 云端 OCR → 云端 TTS 朗读 + 逐词高亮 → 暂停时语音提问 → Agent 回答并写入生语汇。
- **否决**：本地 OCR、本地 TTS、后台播放、倍速、AVSession（用户明确不需要）。

## D2 TTS 用云端（阿里云），不用端侧
- **理由**：端侧 `textToSpeech` 的 `SynthesisResponse` 只有 `sequence`/`audioType`，**没有词级时间戳**，无法驱动高亮。
- **例外**：**回答朗读**（不需要高亮）用端侧 TTS，免费且离线。
- **成本实测**：`qwen-audio-3.1-tts-flash`，446 字符/25.4 秒 → **0.39 分/篇**（CosyVoice 同量约 6.69 分，Qwen 便宜约 17 倍）。

## D3 TTS 接入用官方 HarmonyOS SDK（`neonui.har`）
- **决定**：`NativeNui(MODE_STREAM_INPUT_TTS)` + `asyncPlayStreamInputTts` + `onStreamInputTtsDataCallback`。
- **理由**：同时拿到**流式**与**字级时间戳**；手写 WebSocket 约 280 行被删除。
- **代价**：HAP +8.5MB；多出 `APP_TRACKING_CONSENT` 告警。
- **备选（未采用）**：HTTP 非实时（简单但要等全文 + 再下一跳 URL）、继续用 WS。

## D4 提问解析用 Omni（音频直入），不用「先 ASR 再理解」
- **决定**：`qwen3.8-omni-flash`，`input_audio` 直接传 wav，一次拿结构化 JSON。
- **理由**：音频进模型能结合上下文判断「这个/这句」指代；B0C 基准 19/20。
- **否决**：端侧 `speechRecognizer`（**只支持中文**，且丢掉上下文判断能力）。
- **注意**：端侧识别曾写过一个探针，已废弃删除。

## D5 提问解析的输出是**结构化 JSON**，不是自由文本
- 契约：`{sentence_id, surface, span_start, span_end, intent, question, confidence}`。
- **理由**：`surface`（从课文原样复制的片段）最可靠，后续定位词/句靠它；`intent` 决定回答风格。
- 实现在 `adapters/cqr.ts`，提示词复刻 `validation/B0C/cqr_probe.py`。

## D6 OCR 全权交给视觉模型（不做本地规整）
- **决定**：提示词负责「只转写正文 / 去页眉页脚页码注释 / 段落之间空行 / **段内不换行** / 去上标注释编号」。
- **理由**：本地规则（XY-cut、切边、题号清理）在真实照片上不划算；用户明确要求「不要分行、不要分句」。
- **代码只留兜底**：`normalizeParagraphs()`（合并段内换行 + 清上标数字）。
- **否决**：专用 OCR 模型（见 `pitfalls.md` #15，数据否决）。

## D7 分页标记 `<<<PAGEn>>>` 已废弃
- **原因**：扫描控件按页裁切，一次只出一页；分页逻辑不再需要。
- **遗留**：`adapters/ocr.ts` 的 `splitPages()` 仍兼容标记，但新提示词不再产出。

## D8 高亮 = 画矩形，不改文字样式
- **决定**：`getRectsForRange` 取词矩形，在 `Stack` 里画圆角块。
- **理由**：改样式（`StyledString.replaceStyle` 或重建 `Span`）都会触发重排；画矩形是 O(1)。
- **否决**：`ForEach(Span)` 重建（初始方案，已删）、影子段落（两套排版难保一致）。

## D9 播放器用回调驱动
- **决定**：`on('writeData')` 由音频线程拉数据；`getAudioTimestampInfoSync().framePos` 算位置。
- **否决**：自己 `write()` 轮询 + 领先量限流（会饿死，见 `pitfalls.md` #6）。

## D10 扫描用系统 `DocumentScanner` 控件
- **理由**：自动裁剪/透视/多拍/旋转/删除全自带；自己开相机要重写一遍（且系统限制「应用看不到取景内容」）。
- **代价**：不能叠浮层 → 多了 `ScanConfirm` 页。

## D11 词级点击用坐标换算，不用逐词组件
- **决定**：`ClickEvent.x/y`（组件内 vp）→ `vp2px` → `getCharacterPositionAtCoordinate` → 词 → `seekTo`。
- **否决**：每个词一个 `Text` 组件（放弃原生排版）、段落级跳转（已实现但只作兜底）。

## D12 OCR 结果先给用户看，再决定是否合成
- **理由**：合成按字符计费，识别错了不该让用户白花钱。
- `pages/ScanConfirm` 识别后显示全文 + 「去朗读（开始合成）」按钮。

## D13 文档检索做成 DSH 插件（MCP），而不是每次跑脚本
- **决定**：`dsh-plugins/docs-mcp/`（配置型 bundle，无代码），接 `harmonyos` + `aliyun` 两个 server。
- **理由**：工具变成**原生能力**（`mcp__*`），所有会话可用，不必每次手写脚本。
- **否决**：只用 `scripts/hsdocs.py` + llms.txt（能用，但每次要手动跑、且没有语义检索/全文 grep）。

## D14 生语汇去重键 = 词 + 上下文
- **决定**：同一个词在不同句子里出现算**两条**。
- 文件仍是 `files/course/<id>/glossary.txt`（产品名改叫「生语汇」）。

## D15 课程存储用文件，不用数据库
- 结构：`files/course/<id>/{meta.json,text.txt,images/,audio.pcm,words.json,glossary.txt}`。
- **理由**：音频 5–6MB，数据库不合适；列表靠目录扫描已够用（上百课再考虑索引）。
## D16 让模型做分类/判断，不让它做数值估计
- **决定**：凡是「模型给的数」，一律换成**分档枚举**；凡是「需要精确数值」的，一律由**代码确定性地算**。
- **已落地**：
  - CQR 的 `confidence: 0.86` → `certainty: high|medium|low`；
  - CQR 的 `span_start/span_end`（让模型数下标）→ **删除**，改由代码 `sentence.indexOf(surface)` 计算。
- **理由**：模型的数值是「感觉伪装成数字」，既不可校准也无法校验；而 `indexOf` 是确定性的，
  找不到就是找不到（可以明确报错，而不是被一个错位的下标掩盖——B0C 里就出现过 span 越界被截断）。
- **适用范围**：`sentence_id` 这类「从给定列表里选一个」不算数值估计，保留；
  段落/词序号如果模型要给，也应改成「按内容匹配」由代码定位。

## D17 放弃「确定性」自评，改为把 AI 的理解显示给人看
- **决定**：CQR 不再返回 `certainty`（更早的版本是 `confidence` 小数）；面板直接显示模型输出的
  `question`（它对用户问题的理解），由**用户看屏幕自行判断有没有理解错**。
- **理由**：模型的置信度没有标定，高/低都不可信；而「它所理解的提问」是可检验的事实——
  理解错了就在面板上一目了然（实测：环境音被理解成「翻译」，用户立刻能看出不对）。
- **否决**：`confidence: 0.86`（数值估计，D16 已否决）、`high/medium/low` 三档（仍是模型自评）。
- **代价**：用户要瞟一眼屏幕；换来的是不引入假精确。

## D18 生语汇的 kind 只分三类：word / collocation / other
- **决定**：`word`（单词）、`collocation`（搭配/短语/词组）、`other`（句式、整句、分不清的）。
- **理由**：原四类（word/phrase/pattern/sentence）里 **phrase 与 pattern 的界限模糊**
  （"take for granted" 是短语还是句式？），让模型每次纠结分类只会不稳定。
- **未来**：可能要做「按单词归类」——一个单词挂多个搭配（如 `take` → take for granted / take after）。
  那时 `collocation` 条目要能关联到词条，属于数据模型扩展，先记着。

## D19 回答的形状：先答问题，单词/搭配再补一个例句
- **决定**：
  1. 先直接回答用户问的问题（中文，一到两句，结合本句语境）；
  2. 若问的是 **word / collocation**，再给 **1 个英文例句**，例句里该词/搭配的用法必须对应
     你采用的那个词典义项，再用一句中文点明该义项；
  3. 义项来源优先级：`lookup_dictionary`（本地 WordNet/OEWN）→ Wiktionary（注明 [Wiktionary]）
     → 都无合适义项时取最接近的义项，并声明「它常见的意思是……，这里要结合语境理解」。
- **理由**：学生要的是「这个词在这句里什么意思」，例句只是佐证；例句若不贴着义项，反而误导。
- **注意**：`other`（整句/句式）**不强制**给例句，避免答非所问地堆例句。

## D20 回答必须是「能直接朗读的纯文本」
- **决定**：主 Agent 的最终回复禁止 Markdown（`**`、`#`、`-` 列表、行内代码、表格、链接），
  用完整句子与中文标点；英文词/例句直接写出，不用符号强调。
- **理由**：回答要用端侧 TTS 朗读（9d），符号会被念出来——实测出现过整段 `**译文**` 被读出。
- **兜底**：`core/plain.ts` 的 `toPlainText()` 在显示/朗读前再洗一遍（去粗体、标题、列表符、链接、表格）。
- **连带**：面板里回答是一段自然文字，不追求排版；超长时靠滚动。

## D21 回答朗读用端侧 TTS：online=1 + playType=1
- **决定**：`textToSpeech.createEngine({language:'zh-CN', person:0, online:1, extraParams:{style:'interaction-broadcast', locate:'CN', name:'EngineName'}})`，
  `speak` 时 `playType=1`（引擎自己播），不接 `onData` 的 PCM。
- **实测**：`online:0`（纯离线）创建失败，错误码 **1002300005 create engine error**；改 `online:1` 后
  `onStart → onComplete`（1.9 秒，回答播完）。
- **代价**：`online:1` 走云端合成，但由系统承担、不计我们的账；仍比云 TTS 便宜且无需密钥。
- **限制**：端侧 TTS 无词级时间戳，绝不能用于课文朗读（高亮靠云端 TTS 的 word timestamp）。

## D22 回答朗读改用媒体通道（soundChannel = 1）
- **决定**：`speak` 的 `extraParams.soundChannel` 由默认的 `3`（语音助手通道）改为 **`1`（媒体通道）**。
- **理由**：通道 3 与课文播放的 `STREAM_USAGE_MUSIC` 是两条独立音量流，出现「媒体音量正常、
  回答却没声音」的困惑（实测：语音助手音量 0 时完全无声，用户以为坏了）。
- **代价**：官方提示通道 1/12 在**息屏**场景可能播报截断（进入音频低功耗模式）；本应用朗读都在前台，可接受。

## D23 生语汇按课存放：写入必须走本课路径
- **问题**：`VocabStore` 默认写 `filesDir/vocab.txt`（全局），而生语汇页读本课
  `files/course/<id>/glossary.txt` —— **两处不是同一个文件**，页面上永远看不到 Agent 写的内容。
- **决定**：`VocabStore` 增加可选 `customPath`；朗读页构造时传 `courseStore.glossaryPath(courseId)`。
  全局路径只保留给旧探针页（`pages/Index`）使用。
- **影响面**：`adapters/storage.ts`（构造函数）、`pages/Reading.ets`（装配工具时传路径）。

## D24 用「编辑页」统一替代确认页与原图查看
- **决定**：删掉「查看原图」入口与独立确认页，改成一个编辑页（`pages/Editor.ets`）：
  标题编辑、图片增删排序（＋跳扫描页）、「识别（替换正文）」、逐字可改的全文框、保存。
- **理由**：确认页与原图查看本质都是「看这门课的素材 + 改它」，拆成两处反而要多跳一次；
  识别结果也需要能直接改，而不是只读预览。
- **连带**：朗读页去掉「编辑」按钮（改全文统一去编辑页）；文库页标题由「我的课文」改为「文库」。
- **保存语义**：全文有变 → 写文本并 `dropAudio`（旧音频作废），下次进朗读页重新合成。

## D25 高亮改为「句级」：放弃词级文本对齐
- **背景**：词级依赖「把 TTS 返回的 word 与原文做字符串匹配」，而**模型怎么读我们控制不了**：
  `3` 读 `three`、`1976` 可能读年份也可能读数字、`10,287` 读成一串词、缩写会被拆。
  任何一处不匹配都会让后续整体漂移（实测：第二段段首 `3` → 匹配到别处的 three，高亮跳到段后）。
- **决定**：高亮单位从「词」改为「句」。
- **可用信号**：SDK 有 `SENTENCE_BEGIN` / `SENTENCE_SYNTHESIS` / `SENTENCE_END` 三个事件，
  「时间戳在句内累计、句间增量返回」，**句级时间戳是服务端直接给的**，不需要我们自己对齐。
- **未定**：句界精确到句号还是逗号——服务端分句规则文档未写明，需实测（一句带逗号的话看 `SENTENCE_END` 次数）。
- **两个方案**：
  - **A（改动小）**：整篇一次合成，按 SDK 句事件的**序号**对齐原文句（顺序一致，但若服务端把长句按逗号拆开、或把两句并一句，序号会错位）。
  - **B（完全可控）**：**我们自己分句**（按 `.?!;`，可选加 `,`），**逐句调用 TTS**，每句记录起止毫秒。
    句界 100% 由我们决定，可精确到逗号；代价是请求数变多（合成是一次性的，可接受）。
- **倾向**：B —— 用户的诉求是「不依赖猜测 TTS 怎么读」，只有 B 能做到。

## D26 句级高亮用 TTS 返回的 `original_text` 定位（不再猜）
- **依据**（百炼 `qwen-audio-3.1-tts-flash` 服务端事件文档，本地副本 `docs/vendor/qwen-tts-server-events.md`）：
  - `sentence-begin` / `sentence-end` 事件都带 **`original_text`：分句后的句子文本内容**；
  - 同时有 `sentence.index`（从 0 开始）与 `sentence.words[]`（`text / begin_index / end_index / begin_time / end_time`）。
- **做法**：
  1. 逐句取 `original_text` + 该句 words 的 `min(begin_time)` / `max(end_time)`；
  2. `original_text` 在原文里 `indexOf` → 得到**该句的字符区间**（trim/空白差异做容错，失败才退回顺序映射）；
  3. 播放位置落在某句区间 → 高亮该句（矩形按行画）。
- **为什么可行**：`original_text` 是**原文**（不是读音），整句匹配远比词级可靠；`1976` 读成什么完全不影响。
- **对比 D25**：D25 的「按比例兜底」只在 `indexOf` 失败时作为最后手段。
- **实现要点**：SDK 回调的 `all_response` 是完整 JSON，目前我们只解析了 `output.sentence.words`，
  **需要补取 `payload.output.original_text`**。

## D27 词级高亮的失败原因（记录，不再用）
- 我们词级用的是 `words[].text`（**字级时间戳的文本**），它是**读音单元**：`3` → `three`、`10,287` → 一串词。
- 所以词级必然对不上原文——不是实现 bug，是数据本身不含原文对应关系。
- 结论：词级时间戳**只用于 seek（点词跳转）**，不再用于决定高亮谁。

## D28 去掉 TTS 输入的 sanitize
- **sanitize 做了什么**：只保留 `\n`、空格、可打印 ASCII（33–126）与所有非 ASCII（>126），
  丢掉其余控制字符（`\t`、`\r` 等），然后把**连续空白压成一个空格**，最后 `trim()`。
  结果：**段落换行被抹平**，整篇变成一行。
- **为什么当初加**：词级对齐需要规整空白；也怕控制字符干扰合成。
- **为什么现在去掉**：大模型 TTS 自己会处理换行与空白，**保留段落结构反而有助于它断句/停顿**；
  去掉后 `original_text` 与原文一致，`indexOf` 直接可用，不需要位置映射。
- **实现**：合成直接用 `this.text.trim()`。
- **注意**：文本没变时 `textHash` 不变 → 已有缓存不会被自动替换；想听新效果需改文本或清缓存。

## D29 合成改用「百炼 HTTP 非实时」：一次传整篇，按句返回 original_text
- **决定**：TTS 从 `neonui` WebSocket 流式 SDK 换成 **百炼 HTTP**（`/api/v1/services/audio/tts/SpeechSynthesizer`），
  **一次请求传整篇文本**（多句连续，上下文连贯，语气不断裂）。
- **为什么可行**：`input.text` 就是一个字符串，可包含多句乃至整篇；模型一次性合成，句子之间自然连贯。
- **为什么能高亮**：响应按句返回 `output.sentence`（`index` + `words[]`），并带 **`original_text`（分句后的原文句子）**
  → 用 `indexOf` 定位原文区间，句级高亮精确。
- **注意**：端点不是 `dashscope.aliyuncs.com`，是 `{WorkspaceId}.<region>.maas.aliyuncs.com`；
  非流式返回 `audio.url`（24h），`audio.data` 为空；**`word_timestamp_enabled` 仅流式可用**，
  若非流式拿不到 `words` 就用 SSE 流式（同为一次请求、上下文连贯、明确支持时间戳）。
- **收益**：绕开 SDK 无 `commit` 的限制；同模型、同 Key、同计费口径（按 token）。

## D45 「当前词」不进任何模型提示词
- **决定**：听者（语音提问解析 `CqrParser.parse`）只传**当前句**，不再传「当前词」；
  答者（`ANSWER_SYSTEM_PROMPT` + `askAgent` 拼的 prompt）本来就没有当前词，保持不变。
- **理由**：目标是「问所在句相关的任何问题」，给当前词会让模型把问题**往那个词上靠**，
  而用户说的「这个/它」多半指整句语境；句级上下文足够消歧。
- **实现**：`CqrParser.parse(wavBase64, currentSentence)`（去掉第三个参数）；
  `Reader.currentSentenceInfo()` 改成 `currentSentenceIndex(): number`——内部仍用当前词做**定位**，
  但只返回句子序号（1 起），词不再外传。
- **代价**：像「这个词什么意思」但播放位置还没走到目标词时，模型只能猜"句中的某个词"；
  可接受——用户点词提问走的是文字路径，不经过 CQR。

## D44 提问提示词：全文用**原文**，当前句用**读法**
- **决定**：`askAgent()` 里
  - `课文全文` = `this.text`（`text.txt` 原文，保留括号/破折号，数字原样）；
  - `当前句` = `currentSentenceRead()`（在 `displayText` 词时间戳坐标系里按句号截取）；
  - `问题` 不变。
- **理由**：读法由 TTS 词表逐词拼接，**没有词级时间戳的符号（括号、破折号、引号）会丢**；
  回答里可能需要引用原文的括号内容。而「当前句」必须留在读法坐标系——高亮位置、点击的词都用它。
- **为什么可以直接换**：两份文本句子顺序一致，模型自己能把「当前句」对到「全文」里；
  不需要做“读法位置 → 原文句子”的映射（那才麻烦且易错）。
- **否决**：全文也用读法（会丢符号，D32 的旧行为）；当前句改原文（要重做坐标系映射）。
- **前提澄清**：解析用户问题的音频模型（ASR）只返回**问题文本**；TTS 返回**词级时间戳**（不含句子）。

## D40 导出改回**打包成一个 zip**（`zlib.compressFile` 支持目录）
- **决定**：导出 = `zlib.compressFile(files/course, cacheDir/<名>.zip)` → 把**一个文件**拷到用户选的目录
  （另写一份 `README.txt`）。**不再递归复制目录**。
- **理由**：D39 的递归复制要自己建目录、逐文件拷，还要处理「URI/路径」「中文百分号编码」两套坑，代码长、出错面大；
  而 `zlib.compressFile` 的 `inFile` **可以是目录**（官方最佳实践 `bpta-file-upload-and-download-performance`
  就是这么把临时文件夹打成 zip 的），一次压缩 + 一次 `copyFileSync` 就完事。
- **产出**：`<选中目录>/英语朗读-<yyyyMMdd-HHmm>.zip`（解压即 `<课程id>/…`，与 App 内结构一致）＋ `README.txt`。
- **实测**：11 门课 → zip **17.1 MB**（源约 50 MB），48 个条目，`unzip` 完整性 OK，
  `c_mvjrl9gw_v33/audio.pcm` 解压后 **10,534,400 字节**（与源一致，压缩后 8,897,052）。
  导出后临时 zip 从 `cacheDir` 删除。
- **保留的知识**：D39 里那两条坑（用户目录要 URI→路径 + `decodeURIComponent`）**仍然适用**——
  往用户目录写任何文件都要这么写；只是现在只写 2 个文件。

## D39 导出：把课程目录**原样**拷到用户选的目录（不打包）
- **决定**：设置 →「导出文库数据」→ 用户选目录（`DocumentViewPicker` + `DocumentSelectMode.FOLDER`）
  → 每份文本一个目录（目录名 = 课程 id），内容与 `files/course/<id>/` 完全一致；另外写一份 `README.txt`。
- **实现路径（踩出来的）**：
  1. `fileIo.copy(srcUri, destUri)` 拷目录 → **13900020 Invalid argument**（不接受用户目录 URI）；
  2. `fileIo.mkdir(destUri)` → **13900002 No such file**（mkdir 只认**沙箱路径**）；
  3. **把 docs URI 还原成路径**（`file://docs/storage/Users/...` → `/storage/Users/...`，见 `user-file-uri-intro`），
     再 `mkdirSync(路径)` + `copyFileSync(路径, 路径)` → **成功**（11/11，`audio.pcm` 与源同为 10,534,400 字节）。
- **不要手写 read→write 循环**：第一版这么写，`audio.pcm` 只剩 **65536 字节**（一块就断了）；`copyFileSync` 一步到位。
- **中文目录名**：picker 返回的 URI 里中文是百分号编码（`%E6%96%87%E5%BA%93`），
  还原路径后必须 `decodeURIComponent`，否则建目录报 13900002（pitfalls #36）。
- **代价 / 前提**：路径形式能写，是因为 picker 已对该目录授权；授权是**临时**的（退出后台失效），
  所以导出必须"选完立刻拷"，不能存 URI 下次再用（要持久授权得另做 `fileShare.persistPermission`）。
- **否决**：zip 打包（用户明确不要）；`BackupExtensionAbility`（换机迁移才用，见 D37/T3）；分享（ShareKit）给别的 App。

## D38 设置做成三层页面（不弹窗、不用内嵌面板）
- **结构**（入口：文库标题栏 `gearshape` 图标）：

```
文库 ──设置──► 设置（列表：关于 / 修改 API Key）
                 ├─► 关于（纯文本页）
                 └─► API Key（列表：百炼 / DeepSeek）
                        └─► 编辑页（一个输入框 + 标题栏「保存」）
```

- **决定**：每一层都是**独立页面**（`router.pushUrl`），不用 AlertDialog、也不用页内浮层。
- **理由**：改 Key 要输入、要看当前值、要能取消/返回，弹窗一叠就难用；分层后每一屏只做一件事，
  返回路径也由系统标题栏统一承担（和现有四个页面一致）。
- **控件**：列表用 `List` + `ListItemGroup({ style: ListItemGroupStyle.CARD })` +
  `ListItem({ style: ListItemStyle.CARD })`（官方 `ts-container-listitemgroup` 示例 2：
  卡片样式默认左右外边距 12vp、内边距 4vp，行间用 `.divider()` 画分割线）——这就是系统设置那种
  「一项一项紧挨着的分组卡片」。
- **关于页**：纯文本（版本、课程数、数据结构版本、数据存放说明），不做交互。
- **否决**：① 一屏 + 浮层（当前临时实现，输入框塞在弹层里体验差）；② `AlertDialog`（放不下输入框）；
  ③ 用 `ComposeListItem` 高级组件（功能更重，我们只需要"标题 + 值 + 箭头"三件套）。

## D37 应用**不发布**，但版本管理照做（双轨版本号）
- **决定**：不上架应用市场，保持 debug 签名、`hdc install -r` 自用安装；
  版本管理由两条独立的线承担：
  1. **`versionCode` / `versionName`（app.json5）**——只管"装的是哪一版"，给人和系统看，
     也决定覆盖安装是升级还是（需要 `-d` 的）降级；
  2. **`schemaVersion`（meta.json）**——只管"数据结构是第几版"，迁移逻辑**只认它**。
- **理由**：两者不是一一对应。可能升了 versionCode 但数据没变（不该迁移），
  也可能同一版里修了迁移 bug 需要重跑（schemaVersion 递增而 versionCode 不动）。混用迟早出错。
- **自用放弃的东西**（都是分发能力，与版本管理无关）：应用市场自动更新、分阶段发布、Publishing API、
  从商店下载安装（`app_gallery`+release 签名的包反而不能用 bm/hdc 装，9568402）。
- **代价**：没有商店兜底，升坏了只能自己 `install -r` 回退——
  所以迁移前必须备份，且**只迁移不删除**。
- 文档依据：`docs/vendor/harmonyos-version-and-release.md`。

## D36 单词/搭配的回答按三部分写，且**不标序号**
- **决定**（`ANSWER_SYSTEM_PROMPT`）：
  - `word` / `collocation` 的 `answer` 依次写三部分：**先简洁回答用户的问题** → **那句话的中文翻译** →
    **若是引申义/比喻用法，说明原义并给一个体现原义的英文例句**（不是引申义就不写这段）；
  - `other` 直接回答问题；
  - 全文**单行纯文本**：不标序号、不加 Markdown、不加表情符号。
- **为什么先写「① 简洁回答」而不是罗列语境义/释义/翻译**：用户是听朗读时随口发问，
  要的是"这词在这句里什么意思"，一次答清比给一堆义项有用；翻译放在后面兼作语境确认。
- **为什么不标 ①②③**：标号会被端侧 TTS 念成"①②"，也影响朗读连贯；三部分本来就是按顺序读下来通顺的。
- **已知瑕疵**：若该词不在当前句，模型的"那句翻译"可能退化成翻译当前句（会自己说明"不在当前句中"）——
  已在提示词里要求「就在当前句就翻译当前句」，暂不追加"到全文里找那一句"的要求，避免与"简洁"冲突。
- **证据**：`artifacts/answer-plain.jpeg`（"casual glance" 的回答：释义 + 当前句翻译，无标号）。

## D35 TTS 改走 **HTTP + SSE**（真做了，D29 当初只写了文档）
- **症状（用户报）**：高亮开头几个词正常，之后**匀速**逐词推进；同一时刻语音**缺了一段**。
- **排查证据**（`artifacts/tts-dump-*.json`，原始返回体）：
  | | neonui（WS） | HTTP + SSE |
  |---|---|---|
  | 音频时长（5200 字符） | **137 秒** | **329 秒** |
  | 句子/分块数 | **2** | **15** |
  | 词数 | 932 | 934 |
  | 词增量 | 每词恒 88 或 97 ms（两段各一个常数） | 最小 80 / 中位 320 / 最大 1600 ms |
  | 词长-时长相关系数 | **0.023** | **0.607** |
  | 首包 / 总耗时 | 1.3s / 11.4s | 0.7s / 28.3s |
- **根因**：WS 通道（HarmonyOS `neonui.har` SDK）在长文本上"偷工"——
  只返回约 1/3 的音频，并把整篇词表按剩余时长**均分**，于是高亮匀速、听感跳读。
- **决定**：`adapters/tts.ets` 重写为 **HTTP + SSE**（`X-DashScope-SSE: enable`），
  整篇一次请求（不分块，用户明确要求），`sentence-end` 的词表为准。
- **端点**：`https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer`
  实测可用，**不需要 WorkspaceId 子域名**。
- **遗留**：`neonui.har` 仍在依赖里（-8.5MB、`APP_TRACKING_CONSENT` 告警），见待办 T8。
- **教训**：文档写了"决定改"不等于代码改了；`import` 一眼就能证伪（WS 的 `header.task_id` 信封是铁证）。

## D34 模型输出用 **JSON**（`response_format=json_object`），文件仍写 YAML
- **决定**：答者 LLM 的输出契约用 JSON，字段 `type` / `answer` / `word?` / `words?+phrase?`；
  请求带 `response_format: {type: 'json_object'}`。
- **理由（实测）**：先试过"让模型直接吐 YAML"——同一天就出问题：
  模型把序列写成 `tuck, away`（没有方括号），被解析成**一个**词；
  回答里出现全角/半角冒号、`#`、行首 `-` 都会破坏 YAML 结构，要模型自己负责加引号不可靠。
  而 DeepSeek 官方文档明说 JSON Output **能保证输出合法 JSON**（只需 prompt 含 `json` 字样并给样例），
  数组天然表达"搭配里所有词"，客户端 `JSON.parse` 一行。
- **分工**：模型只给 `type/answer/word?/words?+phrase?`；`语境`/`问题` 仍由应用补齐。
- **文件格式不变**：仍是 YAML（人可读），由 `core/glossary.ts` 序列化；只有"模型→应用"这一跳是 JSON。
- **兜底**：去 ```json 围栏、截取第一个 `{`…最后一个 `}`；解析失败 → 类型「其他」+ 空回答（调用方报错，不写脏数据）。
- **已知坑**：官方注明 JSON Output「有概率返回空 content」；我们已有"回答为空，再问一次"的提示。

## D33 删除本地词典，释义完全依赖 LLM
- **决定**：不再内置/安装 WordNet（`adapters/dictionary.ts`、25.8MB `words.db`、`lookup_dictionary` 工具）——
  释义与语境义一律由 LLM 给出。`pages/DictProbe.ets` 随之删除。
- **理由**：
  1. T6 之后提问链路已经没有任何工具调用，词典**没有调用者**了；
  2. LLM 直接给「语境义 + 准确释义 + 常见翻译」比"先查 WordNet 英文释义再让模型翻译"更短、更准；
  3. 省掉 25MB 词库、首次安装耗时与 `relationalStore` 三个坑（见 pitfalls 6.3）。
- **代价**：释义不可离线、不可复现（同一词两次问可能措辞不同）；已知虚词/新词 LLM 反而更全。
- **否决**：保留词典作为"可校验来源"（要额外维护词库、收益只剩可复现，用户不要求）。

## D32 生语汇：取消 Agent 工具闭环，改「答者 LLM + 代码落盘」，文件改 YAML
- **决定**：
  1. 提问只做**一次** LLM 调用：`system = ANSWER_SYSTEM_PROMPT`，`user = 课文全文(读法) + 当前句 + 问题`；
  2. 模型**只回一段 YAML 映射**（`类型` / `回答` / `单词?` / `搭配?`），不调工具、不输出 JSON
     （最初是「键：值」文本行，2026-10-23 改为直接吐 YAML，见 T7）；
  3. **写文件由代码做**：`core/glossary.ts` 的 `parseAnswerReply` + `appendEntry`；
  4. 语汇文件改 **YAML**（`glossary.yaml`）：根节点序列，元素映射，四键 `类型/语境/问题/回答`。
- **理由**：原方案要跑工具循环（≤6 轮）+ 首次还要装 25MB 本地词典 + 靠模型自己决定调 `append_vocabulary`
  并拼对参数；实际需求只有「答一句 + 归个类」，用代码落盘更短、更快、更可靠。
- **语境取值**：**读法**里的当前句（不是原文）——原文与读法难以逐字对应（`1976`→`nineteen seventy-six`），
  这是有意识的妥协。
- **去重**：`问题 + 语境` 相同则跳过（`appendEntry` 内部判断，幂等）。
- **连带删除**：`pages/Index.ets`（B1.5 自检页，测的正是被取消的 Agent 循环）、`agent/`（`loop.ts` / `tools.ts`）。
- **遗留**：`adapters/storage.ts` 的 `VocabStore`、`adapters/dictionary.ts`（含 25MB 词库）已无人使用，
  随 T3/清理再删；旧格式 `glossary.txt` 暂不迁移（T3 负责）。
- **证据**：`artifacts/glossary-list.jpeg`（类型 chip + 问题 + 回答 + 语境）、`artifacts/vocab-ask2.jpeg`（问答）。

## D31 标题栏用 HDS 的 `HdsNavigation`，**不重做路由**
- **决定**：每个页面用 `HdsNavigation` 当**页面外壳**，内容放它的子组件里，标题栏用 `.titleBar({content:{title, backIcon, menu}})`；
  导航仍然是 `router.pushUrl/back`（返回键用 `backIcon.action` 自己接），**不引入 `NavPathStack`**。
- **理由**：
  1. 系统应用（备忘录那种）的"圆形带底板图标按钮"**是标题栏控件自带的**——设计规范「标题栏」在电脑一段写
     "同时**去掉了圆形底板**"，反证手机/平板默认有底板；`HdsNavigationIconItemStyle` 里
     `backIconStyle/menuStyle.backgroundColor` 默认就是 `sys.color.comp_background_tertiary`；
  2. `content.backIcon` 的类型是 `HdsNavigationIconOptions`，**带 `action` 回调** → 可以只换皮不换路由，
     改动面从"5 页重写路由"降到"4 页换顶栏"。
- **代价**：拿不到真正的导航语义（转场动画、页面栈恢复、侧边栏）；标题栏是浮层，内容要自己留 56vp。
- **否决**：
  - 全量重构成 `HdsNavigation + HdsNavDestination + NavPathStack`（视觉一样，但要重写 5 页路由、且 `Mode` 分栏要额外关）；
  - 手写圆形 `Button` + `shadow()`（不是系统材质，光感/反色/暗色都没有）。
- **证据**：`artifacts/hds-lib2.jpeg`、`hds-reader.jpeg`、`hds-editor.jpeg`、`hds-gloss2.jpeg`；点返回真的回到文库（`hds-back2.jpeg`）。

## D30 主 Agent 用「读法」文本，不用原文
- **决定**：`Reader.askAgent()` 拼 prompt 时用 `displayText`（TTS 实际念的文本），不是 `this.text`（原文）。
- **理由**：用户听到的是读法；Agent 若按原文解释，会和「念的是什么」对不上
  （例如 `1976` 被念成 `nineteen seventy-six`、`10,287` 被念成一串英文词）。
  音频模型（Omni）看到的也应与此一致，所以两者用同一份读法文本。
- **保底**：`displayText` 为空（未合成）时退回原文。
