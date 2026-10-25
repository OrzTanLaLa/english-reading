# 交接说明（给新会话）

> 本项目的方案、验证与代码都在这个仓库里。读完这一页就能接手，不需要翻历史对话。

## 1. 项目是什么

鸿蒙平板 App：拍照导入英语课文 → 云端大模型 TTS 朗读并逐词高亮 → 暂停时语音提问 →
Agent 查词典后把生词／短语／句式写进 `filesDir/vocab.txt`。

目标设备 MatePad（HarmonyOS 7.0），开发机 Windows，**没有自建后端**（App 自己写沙箱文件）。

## 2. 已定的决策

| 项 | 决策 | 原因 |
|---|---|---|
| 平台 | 鸿蒙 ArkTS + ArkUI，`runtimeOS: HarmonyOS` | 只有 Windows 开发机，DevEco 支持 |
| TTS | 阿里云 CosyVoice（百炼），**四个英文音色用户自选**，默认 `longbaizhi` | 音色偏好因人而异，实测四个都可用 |
| 合成粒度 | 语义分组，每组 ≤300 字符 | 300 是「普通语音合成」的截断线；分组减少跨请求接缝 |
| 高亮 | 词级时间戳 → 对齐回原文 token | 端侧 TTS 无词级回调，必须走云 |
| 语义分组 | 主 Agent（DeepSeek）给分组，代码校验长度与覆盖 | 模型数不准字符，约束必须放代码里 |
| 提问解析 | Qwen3.8-Omni-Flash（百炼，OpenAI 兼容端点） | 音频直接进模型，比 ASR 多了上下文判断 |
| 主 Agent | DeepSeek（`deepseek-chat`） | tool calling 稳、中文解释自然、便宜 |
| 词典 | ECDICT 本地 SQLite（**未开始**） | 离线、免费、中文释义准 |
| 存储 | `relationalStore` + `filesDir/vocab.txt` | txt 是人看的交付物，DB 只是索引 |
| 分层 | `core/`（纯 TS）+ `adapters/` + `agent/` + `ui/` | core 零平台依赖，可跨端复用 |

**两把 Key**：百炼（TTS + CQR + OCR 复核）、DeepSeek（Agent）。百炼的 Key 不能用于 DeepSeek。

## 3. 已验证的结论

| 验证 | 结果 | 证据文件 |
|---|---|---|
| B0-a 音色 | 四个英文音色均可接受 → 改为用户自选 | `validation/B0A/raw/*.mp3` |
| B0-a 音色×模型 | `longanyang` 只在 **v3-flash** 上可用，其余三个在 v2 | `validation/B0A/raw/_meta.jsonl` |
| B0-a 首包延迟 | v2 **1.67–2.13s**，v3-flash **0.66–0.73s** | 同上 |
| B0-b 时间戳 | 78/79/57 词 **100% 直接对齐**，零插值 | `validation/B0B/out/plan/index.html` |
| B0-b 断句 | 破折号改逗号后，`though` 前停顿 0ms → 569ms | `validation/B0B/out/prosody/` |
| B0-b2 分组 | DeepSeek 三篇均与人工分组一致，0 重试 0 回退 | `validation/B0B/plans/auto_*.json` |
| B0-c 提问解析 | **19/20**（阈值 17）；唯一失败是「最后一句」这类序数指代 | `validation/B0C/results.json` |
| B0-c 暂停词 | 不带：0/10 命中；带上：8/10 | 同上，`--variant` 对比 |
| B1.5 工具调用 | ArkTS 侧一轮命中 `echo`；**空参数错误回喂后模型自行修正**，第 2 次调用写成功，`vocab.txt` 93 字节 | 设备自检页截图 + `filesDir/vocab.txt` |
| B2 OCR 版面 | 双栏页 OCR 会**按行串栏**（L1,R1,L2,R2…）；上下两块顺序正确；`core/layout.ts` 用行坐标 XY-cut + 边缘碎片判定恢复顺序，真机与 Node 输出 **2369 字符逐字一致** | `scripts/test_layout.mjs`、`scripts/compare_device_layout.mjs`、`artifacts/ocr-probe-real.json` |
| B2 对页残片 | 真实照片里对页残留为**贴边、窄、高覆盖**的一列（22 行 / 宽 65px），三条判据可整列丢弃，正文 32 行不受影响 | 同上 |

**成本基准**：TTS ¥2/万字符；一篇 3000 字符课文首次 ≈ ¥0.6，重听 ¥0（缓存）。
CQR ≈ ¥0.01/次，分组 ≈ ¥0.01/篇。

## 4. 踩过的坑（别再踩）

| # | 现象 | 原因与修法 |
|---|---|---|
| 1 | `1990s` 被读成「一千九百九十秒」 | 合成时必须传 `language_hints=["en"]`，否则双语音色按中文解析数字 |
| 2 | 时间戳显示 `entirely` 只有 80ms | 只取 `sentence-end` 的最终值；`sentence-synthesis` 是增量暂定值，混用会得到假数据 |
| 3 | `though` 读成句末副词、升调 | 官方明确「破折号暂不支持识别」，合成前把 `—` 换成 `,` |
| 4 | 以为「≤300 字符就不会被切」 | 事件流的 `sentence-begin` 是分句标记，不是音频切块；一次请求内音频是连续生成的 |
| 5 | 引号在句号后（`something." Daniel`）分不开句 | 分句正则要允许 `[.!?]["”’]?` 再接空白 |
| 6 | 整句提问返回 `"You'll` 这种碎片 | `surface` 为空且 span 越界时按整句兜底 |
| 7 | 模型给的下标偏一两位 | 让它**原样复制** `surface`，下标只做兜底并吸附词边界 |
| 8 | 「这里什么意思」全返回整句 | 必须传 `pause_word`（暂停时读到的那个词），0/10 → 8/10 |
| 9 | 真人录音被自测 wav 顶掉 | 同名音频按 mtime 判断，源文件更新就重新转码 |
| 10 | DevEco 工程路径不能带空格 | 工作区迁到 `E:\Project\english-reading`（无空格） |
| 11 | 重复合成结果不一致的担心 | 实测 md5 完全一致，缓存永久有效、重叠裁剪点精确 |
| 12 | 双栏课文 OCR 后读成 `L1,R1,L2,R2` | Core Vision 按行出结果，line 没有「栏」概念。**不要用 `result.value`**，要用行坐标自己做 XY-cut（`core/layout.ts`） |
| 13 | 全宽标题让 XY-cut 找不到栏间沟 | 标题本身横跨栏间沟、把沟「填满」了。先剔除明显全宽的行（宽 > 跨度 80%）再找沟，找到后把标题按 y 插回中间 |
| 14 | 先横切再纵切，双栏永远分不开 | 双栏页每行都有左右两栏文字，横切会把行切成独立段。**必须优先纵切** |

## 5. 代码资产

**`validation/B0A/`** — 音色与密钥
- `synth.py`：多供应商取样（CosyVoice／豆包／MiniMax），带 `--dry-run`
- `blind.py`：音频匿名化 + 评分统计（`pack` / `long` / `rank`）
- `config.example.json`：Key 模板（真实 `config.json` 不入库）

**`validation/B0B/`** — 文本与合成流水线（**这是最有价值的部分**）
- `normalize.py`：标点规范化（破折号→逗号、分号→句号、全角→半角）
- `segment.py`：分句 + 30 条缩写保护
- `ts_probe.py`：词级时间戳 + 对齐（`align_words`）+ 高亮对拍页
- `plan_agent.py`：DeepSeek 语义分组 + 校验 + 修长 + 回退
- `plan_render.py`：按分组计划合成、拼接、生成高亮页
- `prosody_probe.py` / `segment_probe.py` / `continuity_probe.py` / `threshold_probe.py`：四个专项实验，结论已进文档
- `plans/*.json`：人工与模型生成的分组计划

**`validation/B0C/`** — 语音提问解析
- `cqr_probe.py`：音频 + 课文 → `{sentence_id, surface, span, intent}`
- `cases.json`（20 条）+ `cases_anchor.json`（10 条纯指代）
- `录音清单.md`：录制脚本与判分口径

**`scripts/migrate_workspace.py`**：迁移 DSH 工作区（一次性）
**`scripts/build-app.ps1`**：编译 HAP（封装 hvigor 环境变量，见 §6.1）

**`app/`（ArkTS，B1.5 已就位）**
- `core/contracts.ts` 工具调用的结构定义；`core/prompts.ts` 主 Agent system prompt
- `adapters/llm.ts` DeepSeek 兼容端点，解析 `tool_calls`
- `adapters/storage.ts` Key 存 preferences（**明文，待换 HUKS**）+ `vocab.txt` 块式追加
- `agent/loop.ts` 工具循环（≤6 轮，错误以 `ok=false` 回喂）；`agent/tools.ts` `echo` / `append_vocabulary`（校验在工具内）
- `core/layout.ts` 版面分析：边缘碎片判定 + XY-cut 恢复阅读顺序；`scripts/test_layout.mjs` 用真机 JSON 跑黄金对拍（同一份源码复制成 `.mts` 在 Node 里跑，Node 24 类型剥离）
- `pages/OcrProbe.ets` OCR 版面探针（三张 rawfile 测试图 + 相册选图导出 JSON）
- `pages/Index.ets` 三步自检页，B2 起会被真正的扫描/跟读页替换

## 6. 环境状态

| 项 | 值 |
|---|---|
| IDE | `E:\Tools\DevEco Studio`，版本 26.0.0.851 |
| SDK | `E:\Tools\DevEco Studio\sdk\default`，**API 26**，6.66 GB，随 IDE |
| hdc | `<SDK>\openharmony\toolchains\hdc.exe`，3.2.0f（**PATH 未生效，用绝对路径**） |
| 构建链 | IDE 自带 node v24.14.1 + ohpm + hvigor，不依赖系统 node |
| 设备 | **已连接**：`GEM-W00`，HarmonyOS 7.0.0.109，API 26（`hdc list targets` → `6XP0226522000917`） |
| Python | `E:\Program Files\Python314\python.exe`（3.14，需 `compression.zstd`） |
| ffmpeg | `E:\Program Files\ffmpeg\bin\ffmpeg.exe` |

不需要 OpenHarmony SDK（那是 `runtimeOS: OpenHarmony` 用的），**别装**，默认会占 C 盘 5–6 GB。

### 6.1 App 工程（2026-10-20 建成，可编译、已签名、已装机）

| 项 | 值 |
|---|---|
| 工程根 | `app/`（`com.example.englishreading`，`runtimeOS: HarmonyOS`） |
| 版本 | `modelVersion` / `compatibleSdkVersion` / `targetSdkVersion` 都是 **`26.0.0`**（API ≥26 的 compile 版本**不带** `(26)` 后缀，规则在 `@ohos/hvigor-ohos-plugin` 的 `VersionConst`） |
| 构建链 | hvigor 6.26.8 + IDE 自带 node v24.14.1 |
| 编译 | `pwsh -File scripts\build-app.ps1`（封装了 `NODE_HOME` / `DEVECO_SDK_HOME` / `HVIGOR_USER_HOME`） |
| 编译+装机 | `pwsh -File scripts\build-app.ps1 -Install -Page pages/OcrProbe`，实测 **14.4s** |
| 产物 | `app/entry/build/default/outputs/default/entry-default-signed.hap` |
| 缓存 | 仓库根的 `.hvigor/`、`.npm-cache/`（已 gitignore）；hvigor 默认写 `C:\Users\<user>\.hvigor`，受限沙箱会失败，所以必须指到工作区 |

**编译速度**：`--hot-reload-build` + 复用 daemon 后，改一个文件到设备上跑起来 **14.4s**（优化前约 33s）。其中签名固定 5.5s、ArkTS 编译 4–5s，省不掉。真正的秒级热加载是 DevEco IDE 的 Hot Reload（不重新打包，只推增量字节码），**UI 调试走 IDE**，命令行只用于需要装机的验证。

**沙箱限制（每次编译都会遇到）**：hvigor 包装器会在 `.hvigor/project_caches/.../workspace` 里创建**符号链接**指向 IDE 安装目录；DSH 受限沙箱（workspace-write）以低完整性令牌运行，**禁止创建链接、也读不过链接**。所以 `build-app.ps1` 必须以**完全访问权限**执行。这不是工程配置问题，别去改 hvigor 配置。

**历史上的一处沙箱限制（已解决）**：`docs/`、`scripts/`、`validation/` 三个迁移目录曾因缺少「低完整性」标签而无法写入。2026-10-20 通过「复制内容 → 换名 → 删除旧目录」重建解决（新目录自动继承工作区根的授权与标签），现在 shell 可直接读写这三处。注意 `icacls /reset` 只能补 DACL，**补不了完整性标签**，标签必须靠重建继承。


### 6.2 OCR 与版面（2026-10-20 结论）

端侧 `textRecognition` **没有版面能力**：双栏会按行交错（`L1,R1,L2,R2`），对页紧贴时还会把两页文字在字符级粘成一个词（`forondnone`）。自研的 XY-cut、书脊检测、自动裁剪都试过，能救一部分，但会在单页图上误切。

**最终方案：一次 VLM 调用按页分块。**

- 模型：`qwen3-vl-plus`（百炼），提示词要求用 `<<<PAGE1>>>` / `<<<PAGE2>>>` 标记分页；
- 实测 5 张真实照片：单页图输出 1 页（精确率 1.000）、跨页图输出 2 页（目标页 0.853 / 对页 0.605，内容互不混入）、横竖反的照片也能正确分页（0.877 / 0.728）；
- **必须明确指定左/右**；让模型「自己判断哪页是主体」无效（仍输出两页）；
- **旋转不能交给 VLM**：180° 能判对，90°/270° 一律判成 0（它能读竖排文字，感知不到方向）。旋转交给端侧行角点（`estimateSkew`，实测可靠）；
- **「段落完整」判断可用**：页3 的对页残片判为不完整、页5 的左页判为不完整（顶部缺第 4 段前半），依据正是「句子是否自然收尾」，与页边距无关；
- 取舍规则：舍去 `paragraph_complete=false` 的页；两页都不完整 → 提示重拍；都完整 → 都保留。

**2026-10-21 提示词定版（视觉模型全权负责转写）**：去掉了旧的分页标记（扫描控件已按页裁切），改为强调「只转写正文 + 段落之间空行 + 段内不换行」。实测一张带页边注释的课本页：标题保留、4 段各占一行、底部注释块被剔除、弯引号保留、无幻觉；用户用另一张照片复测同样正常。**上标注释编号（likely²）**由提示词 + `normalizeParagraphs()` 双重清除。

**2026-10-21 复核（不花钱，用已存输出打分）**：专用 OCR 模型在照片上没有优势。按页平均 F1：`qwen3-vl-plus` 0.566 > `qwen3.5-122b-a10b` 0.549 > `qwen-vl-ocr` 0.480 > `qwen3.5-ocr` 0.446。差距全在跨页/残页（thumb_4：0.68 vs 0.31/0.42），干净单页三者持平。**结论：继续用 `qwen3-vl-plus`。**：分页问题已在提示词层解决。若将来要提升清晰度再引入，注意它们都只做外轮廓、不拆跨页。

### 6.3 词典（2026-10-20 建成）

用 **Open English WordNet 2025**（CC BY 4.0，需署名 Princeton WordNet + OEWN team）做英英释义，中文解释交给主 Agent。

| 项 | 值 |
|---|---|
| 规模 | 128,009 词条 / 185,129 义项 / SQLite **25.8 MB** |
| 构建 | `python scripts/build_dict.py`（OEWN JSON → words.db，4 秒） |
| 课文覆盖率 | 精确命中 71.3% → 加词形还原 **85.4%** |
| 设备端 | 写入 89 ms、`relationalStore` 打开 **33 ms**、查询 **0.40 ms/次** |
| 未命中 | 虚词（and/because）、新词（wurfing/selfie/ttfn）→ 后续用 Wiktionary 补 |

**三个必记的坑**：
1. `relationalStore` 的库文件在 **`databaseDir/rdb/`**，不是 `databaseDir/` 根目录；写错位置会「打开成功」但查到空库；
2. ResultSet 列索引**从 0 开始**，用错报 `14800013`（列索引越界）；
3. 空结果集上取列报 `14800012`，不是返回 null。

**牛津 mdx 为什么没用**：`validation/dict/oaldpe.mdx` 是 `Encrypted="2"` + `RegisterBy="EMail"` 的加密包，key block info 不是 zlib 流，需要注册邮箱才能解密（词条数 622,808，结构已解析）。拿不到注册码就换开源方案。

**下载策略**：不裁、安装后下载。核心包 OEWN 25.8 MB；Wiktionary 全量另作可选包。**下载源必须公网可达**——实测平板 ping 通电脑但 TCP 被拦（校园网/防火墙），`hdc rport` 反向转发也无效。

### 6.4 生语汇（2026-10-20 建成）

产品名叫**生语汇**（不叫「生词本」）：收的是用户在阅读中**问过意思/用法的语言单位**——单词、短语、句式、整句，不只是「没见过的词」。**文件名仍叫 `vocab.txt`**（英文文件名，人可读的交付物），不要因为改名而改文件名。

| 项 | 值 |
|---|---|
| 工具 | `append_vocabulary(kind, surface, meaning, phonetic?, context?, question?)` |
| kind | `word` / `phrase` / `pattern` / `sentence` |
| 触发规则 | 用户只要在问词句「什么意思 / 怎么用 / 怎么读 / 为什么这么写」，就要收录 |
| 幂等 | **键是「词 + 语境」**：`hasEntry(surface, context)`。同一个词换个句子就是新的一条；只有「词相同且 context 相同」才跳过 |
| 格式 | 块式 + `---` 分隔，UTF-8 BOM + CRLF |
| 纪律 | `question` 只填用户原话，**禁止编造**；释义优先来自 `lookup_dictionary` |

**实测（三轮）**：
1. 问 `She remained resilient in the face of failure.` 里的 resilient → 记一条，`context` 是该句，释义「（人）有韧性的」；
2. 问 `The material is resilient to heat and pressure.` 里的 resilient → **再记一条**（同词不同语境），释义「（材料）能耐受的」；
3. 重复第 1 轮的句子 → 返回「在这个语境下已在生语汇里，未重复写入」，文件仍是 2 条。

> 关键设计：**语境是去重键的一部分**。同一个词在不同句子里意思可能不同，即使相近，用户既然问了，这次语境就值得留。

> 早期版本会让模型把「整句 + 单词 + 短语」一次性记 3 条，还会编造用户没问过的问题；收紧提示词后只记用户实际问的那一条。

### 6.5 播放器与词级高亮（2026-10-20 部分验证）

`AudioRenderer` 播 16k 单声道 16bit PCM，`framePos` 驱动高亮。

| 项 | 结果 |
|---|---|
| 播放 | ✅ 24–26 秒素材正常 |
| 暂停/继续 10 次 | ✅ **位置零漂移**，恢复跳变 10–50ms（JS 调度开销） |
| 跳句 | ✅ 毫秒→字节零误差（5000ms = 160000 字节） |
| 词级高亮 | ✅ 跟到第 13→79 词；跳 10s 精确落到第 29 词，4 秒后第 40 词 |

**四个坑**：
1. `write()` **不会等缓冲区空**，必须自己用 `framePos` 限流（保持领先 ≤300ms），否则几十秒音频几秒灌完，位置与声音脱节；
2. `getAudioTimeSync()` 返回**纳秒级 Unix 时间戳**，不是播放时长；播放位置要用 `getAudioTimestampInfoSync().framePos` 换算；
3. `offset` 是 ArkUI 组件保留属性名（`.offset()`），字段同名会编译报错；
4. 跳转需重建 renderer（`framePos` 才能归零），但 `release()` 后立刻 `createAudioRenderer` 会报 `6800301`，要等 ~250ms 并重试。

**高亮只覆盖词干**：B0 的词表保留原文标点（`persistence.`、`in,`），且渲染时如果写成 `Span(word + ' ')`，空格也会被背景盖住。做法是 `splitWord` 拆成 `pre/core/post`，只有 `core` 上 `textBackgroundStyle`，标点与空格用无样式 Span 渲染。

**尚未做**：倍速、后台播放（`ContinuousTask` + `KEEP_BACKGROUND_RUNNING`）、AVSession 锁屏控件。

### 6.6 M1 主链路（进行中，2026-10-20）

**M1a 已跑通：照片 → 云 OCR 分页 → 分句 → 可朗读文本**

| 项 | 结果 |
|---|---|
| 端到端耗时（内置跨页图） | **19,995 ms**（验收线 60 秒） |
| 分页 | 2 页（17 句 + 12 句），无串页 |
| 分句 | 移植 `core/segment.ts`，与 Python 版逐句一致（12 项断言） |

**实现**：`adapters/ocr.ts` 走 `qwen3-vl-plus` + `<<<PAGEn>>>` 标记；`core/segment.ts` 纯 TS 分句；`pages/ImportProbe.ets` 串起来并计时。

**踩坑**：
- `uitest uiInput inputText` 需要 `<x> <y> <text>` 三个参数，少了坐标不会报错但什么也不做；
- 平板输入法在 `inputText` 后会卡死界面（窗口在前台但全黑），探针改用 `local_secret.ts` 预填（已 gitignore，仓库里只有 `local_secret.example.ts`）。

**M1c/M1d 已跑通（2026-10-21）**：照片 → OCR → 分句 → **整篇一次合成** → 边播边高亮。

| 环节 | 实测 |
|---|---|
| OCR（2 页跨页图） | 18.8 s |
| 分句 | 10 ms（28 句 / 3318 字符） |
| TTS 合成（qwen-audio-3.1，PCM 16k） | 23.0 s / 首包 977 ms / 608 个词时间戳 |
| 音频 | 6712 KB = 214.8 秒 |
| **从开始识别到可播放** | **41.8 秒**（验收线 60 秒） |
| 成本 | 697 in + 2684 out tokens ≈ 3.3 分/篇 |

**两个必记的坑**：
1. 服务端词时间戳字段是 **`begin_time` / `end_time`**，按 `begin` / `end` 取会得到 `undefined`，`indexAt` 恒返回 -1，高亮永远不亮（现象是播放正常但没有任何词被选中）；
2. 600+ 词 × 3 个 Span，每次切词全量重建会把 UI 线程压住（位置在走但高亮不刷新）。改成**窗口化渲染**（只渲染当前词附近 120 词）。

**剩余**：校对页（OCR 文本有 `[?]`、句间粘连、`Five`/`Six` 之类的段落编号残留）、边合成边播（把首音从 41.8 s 压到 ~20 s）、PCM 缓存。

### 6.7 TTS 选型：改用 Qwen-Audio-3.1-TTS-Flash（2026-10-20 定）

**结论：TTS 用 `qwen-audio-3.1-tts-flash`，不用 CosyVoice。** 成本差 17 倍，且它直接输出 PCM。

| | Qwen-Audio-3.1-TTS-Flash | CosyVoice-v3-Flash |
|---|---|---|
| 计费 | 1.5 元/M 输入 token + 12 元/M **输出** token | 1.5 元/**万字符** |
| 同一篇（446 字符 / 25.4 秒） | 87 in + 317 out = **0.39 分** | **6.69 分** |
| 每分钟音频 | **0.93 分** | 15.8 分 |
| 音频输出 | 可 `format=pcm, sample_rate=16000`，端侧免解码 | mp3/pcm |
| 词级时间戳 | ✅ `word_timestamp_enabled=true`（**默认 false，不开会拿到空 words**） | ✅ `word_timestamp_enabled` |
| 首包 | 513–990 ms | 同量级 |

**记账要点**：TTS 的钱几乎全在**输出** token（占 96%+），按输入单价判断会得出相反结论。实测 **746 output tokens / 分钟音频**，即 `746 × 12/100万 ≈ 0.9 分/分钟`。

**单位陷阱**：CosyVoice 是「1.5 元/**万字符**」，不是「1.5 元/M 字符」，两者差 100 倍。我第一次把常数写成 1 元/M 字符，把结论算反了；后来又按 1 元/万字符算过一遍，最终以 1.5 元/万字符为准。

**协议**：`run-task` → `task-started` → `continue-task`（可多次，自动分句）→ `finish-task` → `result-generated`（含 `sentence.words[]` 的 begin/end_time）→ 音频走 binary 通道。端点 `wss://dashscope.aliyuncs.com/api-ws/v1/inference`。

**探针**：`validation/B0B/qwen_tts_probe.py --text t2 --format pcm --rate 16000`，一次跑出音频、时间戳、token 用量和三方成本对比。

### 6.8 分组约束取消（2026-10-20 验证）

B0 当年为 CosyVoice 设计的「语义分组 ≤300 字符 + 组间静音拼接」**在 Qwen-Audio-3.1 上不需要了**。

| 验证 | 结果 |
|---|---|
| 单次 `continue-task` 上限 | 20000 字符（累计 200000），一篇文章绰绰有余 |
| 实测 4807 字符一次提交 | ✅ 音频 180 秒、**916 个词级时间戳**、句间间隙 0–130 ms、尾部差 400 ms |
| 时间戳基准 | **全局**（0–179650 ms 贯穿整个任务），不是每句从 0 开始 |
| 吞吐 | 4807 字符 → 180 秒音频，合成只用 24.2 秒（7.4× 实时） |
| 首包 | 446 字符 513 ms；1201 字符 732 ms；4807 字符 1483 ms |
| 成本 | 4807 字符 = 2.86 分（CosyVoice 同量 72 分，25×） |

**架构简化**：
- ❌ 不再需要 DeepSeek 语义分组（少一次 LLM 调用、少一份延迟和费用）；
- ❌ 不再需要「组起点偏移 + 组间静音」的全局位置换算；
- ❌ 不再需要自己插静音，服务端按句自然停顿；
- ✅ 整篇一次提交 → 边收 PCM 边播放 → 词级高亮直接用全局时间戳。

**注意**：服务端的 `sentence.index` 只是**分块**（长文只切 2 块），不是句子级；但 `words[]` 是词级的且时间连续，高亮只依赖它。

### 6.9 界面骨架（2026-10-21）

按 `docs/UI设计.md` 落地，入口页已改为 **`pages/Library`**。

| 页面 | 状态 |
|---|---|
| `pages/Library` | ✅ 列表、空状态、＋、⋮ 菜单（查看原图/编辑标题/生语汇/重新生成音频/删除）、重命名浮层、删除确认 |
| `pages/Reading` | ✅ 原文渲染 + 后台合成 + 播放 + 词级高亮 + 编辑重合成；🚧 语音提问、从上次位置续播 |
| `pages/Scan` | 🚧 占位（相机、快门、图库、缩略图 ✕、完成） |
| 探针页 | 保留：ImportProbe / HighlightProbe / PlayerProbe / DictProbe / OcrProbe / Index |

**朗读页的渲染原则（2026-10-21 确认）**
- **不分句**：直接渲染 OCR 原文，按空行分段，**标点与大小写原样保留**；
- 高亮只给「词干」上底色，标点不动；
- 词在原文里的字符区间由 `alignWords()` 贪心匹配得到（TTS 的 token 与原文可能不一致，
  例如 `1820` 被读成 `eighteen twenty`，这类词对齐不上就不高亮）。

**数据层**
- `core/course.ts`：`CourseMeta`、默认标题、`hashText(text,voice)`、副标题/相对时间（纯函数）
- `adapters/courseStore.ts`：`files/course/<id>/` 读写（meta/text/images/audio/words/glossary）
- `core/reader.ts`：`indexAt` / `alignWords` / `splitParagraphs` / `splitWord` / `sanitize`（纯函数）
- `adapters/player.ts`：`PcmPlayer` —— AudioRenderer + 限流写入 + 逐词重锚调度（从探针里抽出来的）

**坑（重要）**
1. **新增页面/改路由必须全量构建**，否则装到设备启动报 `Failed to load the content. Cause: {"code":401}` 白屏。
   `scripts/build-app.ps1` 已自动检测 `pages/*.ets` 与 `main_pages.json` 的变化并强制 `-Clean`。
2. 用词条里的标点切句会把句子切碎（`mystery` + `.Nobody`），所以**不要用 TTS token 的标点做分句**。

### 6.10 怎么读鸿蒙官方文档（2026-10-21 解决）

文档中心是**前端渲染**的，`web_fetch` 只能拿到空壳。华为提供了两条给 AI 用的通道：

| 通道 | 地址 | 用法 |
|---|---|---|
| **开发者知识 MCP**（推荐） | `https://connect-api.cloud.huawei.com/api/developerknowledge/mcp` | 远程 MCP，工具 `searchDocuments` / `getDocumentsById`，返回 **Markdown 正文**，官方称与官网准实时同步（≤30 分钟） |
| llms.txt 索引 | `https://developer.huawei.com/config/llms.txt` → 二级 `docs-{alias}.txt` | 静态 Markdown 索引，适合批量采集/建知识库 |

**实测对比（2026-10-21）**

| | 开发者知识 MCP | llms.txt + 直接取 `.md` |
|---|---|---|
| 发现方式 | **语义检索**（不知道文档名也能找到） | 关键词 grep 索引（API 参考 9512 条、指南 9536 条） |
| 内容 | 一次 `getDocumentsById` 给全文 | 索引给链接，再 GET 一次 `.md`（返回 `text/markdown`，实测 188 KB） |
| 新鲜度 | 官方称 ≤30 分钟 | 索引 `update_time` 可能滞后，但 `.md` 正文是现取的 |
| 调用方式 | POST JSON-RPC，参数要包一层 | 纯 GET，可缓存、可离线 grep |
| 依赖 | Python（PS 的 TLS 不通） | 同样用 Python |

**结论：两条路都要留**——知道文档名时走 llms.txt（可缓存、可离线），不知道时用 MCP 做语义检索。
索引已缓存到 `docs/vendor/index/`（gitignore）：`llms.txt` + `docs-references.txt`(2.3 MB) + `docs-capabilities.txt`(2.5 MB) + `docs-ux-design.txt`。

**本仓库的封装**：`scripts/hsdocs.py`

```powershell
python scripts/hsdocs.py search "ArkGraphics2D 文本 Paragraph 坐标" --top 5
python scripts/hsdocs.py get alliance/document/cn/harmonyos-references/js-apis-graphics-text
```

- 落盘到 `docs/vendor/<标题>.md`（已 gitignore）
- JSON-RPC 参数必须**包一层**：`{"SearchDocumentsReq":{"query":…}}` / `{"GetDocumentsByIdRequest":{"names":[…]}}`，否则服务端报 400 "No content to map"
- **PowerShell 直连会 TLS 失败**（schannel `SEC_E_NO_CREDENTIALS`），必须走 Python

用这个拉到的两条事实（此前从 `.d.ts` 看不出来）：
1. 文本引擎所有尺寸/坐标单位都是**物理像素 px**，而 ArkUI 的 `fontSize` 是 fp、布局是 vp —— 做影子排版必须 `vp2px` 转换；
2. `Text` 有 `setTextSelection`（API 23，需 `copyOption`），但没有「坐标 → 字符」的命中接口；命中要么走 `text.Paragraph`（影子排版），要么把词拆成独立组件。


### 6.11 构建链路的三个坑（2026-10-21 查清）

**① 为什么编译必须给「完全访问权限」**

不是符号链接本身，而是 hvigor 的工程缓存：

```
%USERPROFILE%\.hvigor\project_caches\<hash>\workspace\node_modules\@ohos\hvigor
  → Junction → E:\Tools\DevEco Studio\tools\hvigor\hvigor
```

受限沙箱下两处必然失败：写 `%USERPROFILE%\.hvigor`（工作区外）、创建 Junction。
官方错误码 `00308003`（找不到 Hvigor 入口文件）的处置是「删掉 `project_caches\<hash>\workspace` 重试」，
但下次构建仍要重建，所以是**结构性的**，配置绕不过去。

试过无效：`HVIGOR_USER_HOME`（hvigor 不认）、重定向 `USERPROFILE`（npm 仍写死 `AppData\Local\npm-cache`）、
预建 Junction（hvigor 每次重写）。**结论：构建命令固定用完全权限跑，脚本失败时会打印排查提示。**

**② 新增文件后必须全量（否则白屏 401）**

官方 Hot Reload 文档明确列出不支持项：**「启动应用后新增的代码文件」**。
所以新加页面/新加 `core/*.ts` 之后，增量构建会漏掉它，装到设备上启动就是
`Failed to load the content {"code":401}`。

`scripts/build-app.ps1` 现在用「`ets/` 下全部 `.ets`/`.ts` 清单 + `main_pages.json` 哈希」做戳，
清单变了自动 `clean`（以前只看 `pages/*.ets`，新加 `core/` 文件会漏）。

**③ 增量构建提速配置**

`app/hvigor/hvigor-config.json5` 显式打开：

```json5
"execution": { "daemon": true, "incremental": true, "parallel": true, "optimizationStrategy": "performance" },
"logging": { "level": "warn" }
```

实测（含引入 neonui.har 后 HAP 11 MB）：空转 3.3–3.5s；改一个文件 15.2s；全量 42s。

**④ 一个新出现的告警**

加 HAR 后构建会提示 `To use this API, you need to apply for the permissions: ohos.permission.APP_TRACKING_CONSENT`。
来源待查（可能是 SDK 取 OAID 做 device_id）。上架前必须处理，否则隐私合规过不了。

## 7. 待办
| 批次 | 内容 | 验收 |
|---|---|---|
| **B1** 工程基线 | ✅ **已过**：空工程装上平板并启动（GEM-W00 / API 26 / 签名已配） | — |
| **B1.5** 工具调用 | ✅ **已过**：echo 单轮往返；错误回喂后模型自行修正并写成功（2 次调用，未超 3 轮） | — |
| **B2** OCR | 版面结论已定（见 §6.2）：单次调用按页分块 + 段落完整性判断；端侧几何负责旋转 | 待接进 App 后复测 5 页 |
| **B2** 字符准确率 | 需与原文对齐测量（原文已存 `artifacts/b2-final/reference.txt`） | ≥95% |
| **B3** 播放器 | `AudioRenderer` 播 PCM，暂停/续播、跳句、后台、AVSession | 暂停 10 次不漂移，跳句误差 <200ms |
| **词典** | OEWN 建库 ✅、设备端查询 ✅（见 §6.3）；待接 `lookup_dictionary` 工具 | Agent 查词 5 秒内出中文解释 |
| **M1** | 扫描 → OCR → 校对 → 分句 → 分组 → 合成 → 高亮 | 一篇课文 60 秒内开始朗读 |

**建工程时的注意事项**
- 路径必须无空格：`E:\Project\english-reading\app`
- 工程已按 DevEco 自带模板（`plugins\openharmony\lib\templates`）生成，**不要再手改版本号**；升级 IDE 后比对 §6.1 的版本值
- `core/ adapters/ agent/ ui/` 目录已建好，把 Python 版的算法照 `docs/TECH_PLAN.md §2.5` 移植

## 8. 移植到 ArkTS 的三个坑

| Python | ArkTS |
|---|---|
| `difflib.SequenceMatcher` | 没有，要自己写 LCS（约 50 行） |
| `json` 随便用 | ArkTS 禁 `any`，所有结构和请求都要先写 interface |
| `re` | 语法子集，分句正则要重测 |

**黄金测试**：Python 已产出 t1/t2/t3 的分句、分组、对齐结果，TS 版 core 必须逐字符一致。

## 9. 给新会话的建议

1. 先读 `docs/TECH_PLAN.md` 的 §0（结论）、§3.4（TTS）、§3.5（CQR）、§9（验证路线）
2. 不要重新验证 B0 的四项——结论和数据都在，重复只是烧钱
3. B1/B1.5 已完成，别重做；下一步是 **B2 OCR**（需真机拍课本）或 **B3 播放器**（用 B0 缓存好的 PCM，不接 TTS）
4. 任何「听起来对不对」的判断交给用户，不要用时长/事件数去推断音质
