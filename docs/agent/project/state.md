## 交付渠道：GitHub Releases（2026-10-25）

- 仓库：https://github.com/OrzTanLaLa/english-reading（只含 HAP 源码 + 脚本 + 文档；artifacts/validation/vendor/真实 Key 不入库）
- 首个 Release：**v1.0.0**，附 nglish-reading-1.0.0.hap（2.89 MB，debug 签名，Profile 需含目标设备 UDID）
  https://github.com/OrzTanLaLa/english-reading/releases/tag/v1.0.0
- 发版流程：`git add app docs scripts` → commit → push；构建 debug HAP；REST API 建 release + 传资产。
- 网络：直连 github 不通，已给本仓库设 `http.proxy=http://127.0.0.1:7890`。
# 当前状态（每次接手先读）

> ⚠️ **2026-10-23 数据事故**：设备上 `files/course/` 被清空（11 门 → 0），只剩
> `backup_v0_*/<id>/{meta.json,glossary.txt}`（10 门）。18:02 导出的完整 zip 被我在 18:16 清测试目录时删掉
> （pitfalls #37）。正文/图片需重新拍照+OCR，音频需重新合成；标题与语汇录可从 backup 恢复。
> **防再犯待改**：删除课程移入 `files/trash/`、导出后保留 `files/backup/` 副本、迁移备份改整目录。
>
> **v1.0.0 已完工（2026-10-23）**：导入→编辑→朗读→提问→语汇录→设置→导出 全部打通并在设备上验过；
> 待办清单清空。以下内容保留为"为什么这么做 / 踩过什么坑"的底账，接手时按需查。
> 发下一版：`versionCode`+1、`versionName` 改一版、`install -r`（**绝不卸载**）。

> 更新时间：2026-10-22 22:30
> 详细历史进度见 `docs/交接说明.md`；本文件只讲「现在在哪、下一步做什么」。

## 已完成并验证

| 能力 | 状态 | 关键证据 |
|---|---|---|
| 文库页（列表/重命名/删除/生语汇入口） | ✅ | `pages/Library.ets` |
| 扫描页（系统文档扫描控件，手动快门，支持图库） | ✅ | 设备实拍 → 10 张缩略图 → 确认页 |
| OCR（视觉模型全权转写：去注释/页码、段落化、段内不换行） | ✅ | 用户实拍课本页，4 段各一行、底部注释块被剔除 |
| TTS（官方 HarmonyOS SDK `neonui.har`） | ✅ | 探针 首包 499ms、18 词、全局毫秒时间戳 |
| 播放器（`on('writeData')` 回调 + `seekTo`） | ✅ | 暂停冻结 16/36s、恢复从 18s 续播 |
| 逐词高亮（`getRectsForRange` 画矩形，零重排） | ✅ | 4s 高亮 why、6s 高亮 bitter |
| 点词跳转（ClickEvent.x/y → vp2px → 字符 → 词 → seek） | ✅ | 点 distinction 跳到 29/35s |
| 提问解析（百炼 Omni，音频直入模型） | ✅ | 设备上复现 B0C：persistence/0.95、Grit/pronunciation/0.95 |
| 文档检索 MCP（鸿蒙 + 阿里云插件） | ✅ | 两个 server 均实际调用成功 |
| 录音模块 `adapters/recorder.ts` | ✅ 已接页面 | 麦克风授权后录音→Omni 解析成功（pitfalls #24、`artifacts/rec-3.jpeg`） |
| 朗读页 `pages/Reader.ets` | ✅ | 读法/原文双视图、逐词高亮、点词跳转、录音停止/取消、打字提问 |
| 生语汇改为 YAML + 无 Agent 落盘（T6） | ✅ | 一次 LLM 调用，代码解析后写 `glossary.yaml`；见 `artifacts/glossary-list.jpeg` |
| T7：语汇加 单词/搭配 字段 + JSON 输出 + 删词典 | ✅ | 单词=字符串、搭配=序列+搭配本身、其他两键都没有；三种形状实机各验一次；本地词典与 DictProbe 已删（HAP 11.32MB） |
| 编辑页 `pages/Editor.ets` | ✅ | 标题、图片增删排序、识别替换正文、全文编辑、保存 |
| 生语汇页 `pages/Glossary.ets` | ✅ | 只读展示本课 `glossary.txt` |
| 标题栏统一为系统 HDS 标题栏（T1+T1b） | ✅ | `HdsNavigation` 的 `titleBar`：圆形底板返回键、＋菜单图标（圆形底板）、「保存/显示原文」胶囊文字按钮；截图 `artifacts/hds-*.jpeg` |

## 当前阻塞

无。

## 朗读页顶栏加「语汇录」（2026-10-23）

- 标题栏右侧两个文字按钮：「显示原文/显示读法」+「语汇录」；后者带 `id`/`title` 直接进本课生语汇页。
- 实测：点「语汇录」进入生语汇页（12 条），见 `artifacts/reader-to-glossary.jpeg`。

## 答者提示词：回答分三部分、不标序号（2026-10-23）

- `word`/`collocation` 的 answer：先简洁回答 → 那句话的中文翻译 → 引申义时补原义+例句；
- 全文单行纯文本，**不标 ①②③**（标号会被 TTS 念出来）；
- 实测（"casual glance"）：释义 + 当前句翻译一气读下来，无标号，见 `artifacts/answer-plain.jpeg`。

## 导出改成 zip（2026-10-23，D40）

- `adapters/exporter.ts`：`zlib.compressFile(files/course, cacheDir/<名>.zip)` → `copyFileSync` 到用户目录
  → 写 `README.txt` → 删缓存 zip。递归复制已删除。
- 实测：`英语朗读-20261023-1802.zip` = 17,906,821 字节（11 门 / 48 条目），
  `audio.pcm` 解压后 10,534,400 字节（与源一致），`zipfile.testzip()` 无损坏。

## 导出（T3 收尾，2026-10-23）

- 设置 →「导出文库数据」→ 选目录 → 每份文本一个子目录，结构与 `files/course/<id>/` 一致 + `README.txt`。
- 实现：`adapters/exporter.ts`；关键点是 **URI 还原成路径**（`file://docs` → `/storage/Users/...`）后再
  `mkdirSync` + `copyFileSync`——`copy`/`mkdir` 直接吃 URI 会 13900020 / 13900002（D39、pitfalls #35）。
- **中文目录名坑**：picker 返回 URI 里中文是百分号编码，须 `decodeURIComponent`（pitfalls #36）。
- 实测：11/11 成功（含中文目录 `下载/文库`），`audio.pcm` 与源同为 10,534,400 字节，`du -sk` 源/目标同为 10403 KB，图片（923,715 字节）在位。
- 截图：`artifacts/export-picker*.jpeg`。

## 设置页 + 版本管理/迁移落地（2026-10-23）

**设置（三层，D38）**：文库标题栏 `gearshape` → 设置（卡片分组：关于 / 修改 API Key）
→ 关于（纯文本：版本 v1.0.0 / 数据结构 v1 / 课程数 / 数据说明）
→ API Key 列表（百炼、DeepSeek，右侧「已设置/未设置」）
→ 编辑页（**密码样式**，圆点 + 眼睛图标可看明文，标题栏「保存」）。
- 列表控件：`List` + `ListItemGroup({style: CARD})` + `ListItem({style: CARD})`；
  卡片默认居中、左右留白较大（**这是 CARD 样式的默认行为，未改**）。
- 截图：`artifacts/settings.jpeg`、`settings-about.jpeg`、`settings-apikeys2.jpeg`、`settings-apikey-pwd.jpeg`。

**版本管理 / 迁移（D37，T3 前半）**：
- `app.json5` 版本 1.0.0 / versionCode 1000000；文库标题栏副标题显示 `v1.0.0`（`bundleManager.getBundleInfoForSelf`）。
- `meta.json` 增 `schemaVersion`；`EntryAbility.onCreate` 调 `CourseStore.migrateAll()`（幂等）。
- 实机首启迁移成功：10 门课 `schema 0→1`，其中 1 门把旧 `glossary.txt` 迁成 YAML（2 条）；
  备份在 `files/backup_v0_<ts>/<课程id>/`（只备份 `meta.json` + `glossary.txt`），
  日志 `files/migration.log`。

## 文库 ＋ 改为进编辑页（2026-10-23）

- 之前 ＋ → 扫描页（先拍后建课）；现在 ＋ → **编辑页（新建）**，扫描只在编辑页的「添加图片」里进入。
- 空状态文案同步改为「点右上角 ＋ 新建课文」。
- 实测：点 ＋ 进到「编辑课文」页，标题自动填「未命名 YYYY-MM-DD hh:mm」，见 `artifacts/new-to-editor.jpeg`。

## 生语汇页改为显示原文（2026-10-23）

- 从「解析后结构化列表」改回**直接显示 `glossary.yaml` 原文**（滚动 + 复制），副标题显示「共 N 条」。
- 理由：这份文件本身就是给人看的交付物，排版反而看不到真实格式。
- 截图：`artifacts/glossary-yaml.jpeg`。

## OCR 提示词调整（2026-10-23）

- 去掉**段首标号**（`1` / `11` / `One` / `Two` / `I.` / `①`）：之前编号被 TTS 念成 "one"/"two" 粘进正文
  （读法里出现 `speak one Every year`）。
- 强调**段落之间必须空一行**。
- 代码兜底 `stripLeadingNumber()`：阿拉伯数字/罗马数字/圆圈数字直接去；
  英文数词（One…Twelve）**只有后面紧跟大写字母**才去（`One day,` 保留、`Two You might` 去掉）。
- 实拍页实测（qwen3-vl-plus，`artifacts/b2-final` 同源照片）：5 段、段首编号全无、段间有空行，2584 tokens ≈ 0.02 元。
- 离线用例：`scripts/test_ocr_normalize.mjs`（12 条，含「One day,」这类反例）。

## TTS 通道换成 HTTP+SSE（2026-10-23）

用户报「高亮匀速 + 语音缺一段」。查到根因是 **WS（neonui）通道在长文本上偷工**：

| 5200 字符 | WS | HTTP+SSE |
|---|---|---|
| 音频 | 137 s | **329 s** |
| 分块 | 2 | **15** |
| 词增量 | 恒 88/97 ms | 80–1600 ms（中位 320） |
| 词长-时长相关 | 0.023 | **0.607** |

`adapters/tts.ets` 已重写为 HTTP + SSE（整篇一次请求，未分块），装机实测通过。证据见
`artifacts/tts-dump-1792715269648.json`（WS）与 `artifacts/tts-dump-http.json`（HTTP）。（麦克风权限曾长期卡住，真实原因是**从未授予**、授权框没被点到；已在 2026-10-22 解决，见 pitfalls #24。）

## 朗读页已重写（2026-10-22）

**旧页已删除**：`pages/Reading.ets`、`pages/VoiceProbe.ets`（探针）已移除，路由同步清理；
`ScanConfirm` 曾指向 `pages/Reader`，后于 T5 整体删除（扫描完成现在直接进 `pages/Editor`）。

新页 `pages/Reader.ets`（约 660 行）替代旧的 `Reading.ets`（已删除）：
- 左 70% 正文、右 30%（按钮 / 对话 / 输入框）；
- 默认「读法」视图 = `words[].text` 拼接 + **逐词精确高亮**（偏移构造时算好）；
- 「显示原文」视图 = 段落渲染、**不高亮**；
- 提问：键盘输入或麦克风 → 主 Agent → 对话区追加 + 端侧 TTS 朗读。

## 历史：句级高亮尝试（D26，已被读法视图取代）

**已完成（数据层）**
- `adapters/tts.ets`：新增 `SentenceTiming{index,text,begin,end}`；从回调 `payload.output.original_text`
  收集**原文句子**；`sentenceSpans()` 按句序产出区间（起止取该句首尾词时间）；`TtsResult.sentences` 已带上。

**已完成（2026-10-22）**
- `courseStore`：`sentences.json` + `writeSentences/readSentences`（缺文件返回空数组）；
- `Reading`：
  - `locateSentences()`：用 `indexOf(text, cursor)` 顺序定位，游标前移，整体 O(n)；末句无 `original_text` 时兜底；
  - `sentenceAt(ms)`：时间 → 句序号；**只有换句时才重算矩形**（同一句直接返回）；
  - 高亮改为 `HlRect[]`（每行一个块），渲染用 `ForEach(this.hlRects.filter(...))`；
- 旧课程迁移：`sentences.json` 不存在时**自动重新合成一次**（拿到 `original_text`），一次性成本。

**实测进展（2026-10-22）**
- ✅ 定位成功（须用 **sanitize 后文本**检索；现已改为**不 sanitize**，见下）
- ✅ 矩形算出（`rects=54`）
- ✅ **渲染已修好**：旧代码没有真正替换成 `ForEach`，`hlW` 永远为 0 → 从不绘制。
  现改为 `ForEach(this.hlRects.filter(...))`，截图确认大块高亮可见。
- ✅ 续播从半个词开始的问题：`adoptAudio` 里把 `lastPositionMs` **吸附到所在词的开头**。
- ⚠️ **粒度太粗**：这篇 1384 字符的课文，TTS 只分 **2 句**（0–1204 / 1205–1384），
  高亮实际是"两大块"，不是句子级。

**要不要升级到方案 C**
- C = 我们自己按 `.?!` 切句，**逐句调用 TTS**，每句天然对应原文 → 真正的句子级。
- 代价：请求数 1→N（合成一次性+缓存，可接受），首包更早、进度可以按句递增。
- 不做 C 的话，句级高亮就只能是"TTS 的大块"。

## 下一步（推荐顺序）

1. **T7 语汇加「单词/搭配」两字段 + 精简提示词 + 删本地词典**（**只加了待办，未开工**）。详见 `docs/待办清单.md` T7。
2. **T3 正式发布 + 版本更新机制**（防丢数据）：`versionCode` 递增、只 `install -r`、
   `meta.json` 加 `schemaVersion`、迁移前备份、迁移幂等；**并把旧 `glossary.txt` 迁成 `glossary.yaml`**。
3. **提问链路端到端实机验证**：打字已通（4 条实测）；**语音**还没完整跑过。
4. **点「取消」丢弃录音**未在设备上验证。
5. ~~清理 ScanConfirm 死路由~~ —— 已完成（T5）。
6. ~~生语汇改造（T6）~~ —— 已完成：无 Agent、YAML、类型/语境/问题/回答四字段；已删 `pages/Index.ets` 与 `agent/`。
8. ~~T7~~ —— 已完成：新增 `单词`（字符串）/`搭配`（序列 + 搭配本身）两键；模型输出改 **JSON**（D34）；
   删 `adapters/dictionary.ts`、`pages/DictProbe.ets`、`VocabStore`（D33）。
7. ~~图标/T1b~~ —— 已完成（HDS 标题栏）。

## 未决问题（需要拍板或实测）

| 问题 | 现状 | 建议 |
|---|---|---|
| 长课文性能（600 词） | 未压测 | 有真实长课文时再测，别为省事凭空合成（费钱） |
| `alignWords` 词对齐误差 | 已被「读法视图」绕开（不再靠对齐） | 只影响旧原文视图，不再投入 |
| 阿里云 MCP 的 `CallCLI/RunScript/RunIaC` | 能真实操作云资源、能花钱 | 非用户明确要求不要用 |
| 上架用的 `APP_TRACKING_CONSENT` 告警 | 引入 neonui.har 后出现（现 TTS 已改 HTTP，har 是否还必要待查） | 上架前必须处理，见 `pitfalls.md` |

## 当前可跑的验证入口

```powershell
# 构建 + 装机（必须完全访问权限）
pwsh -File scripts\build-app.ps1 -Install -Page pages/Library
```

设备：MatePad `GEM-W00`，HarmonyOS 7.0.0.109 / API 26，序列号 `6XP0226522000917`，
hdc 在 `E:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe`。

## 已完成事项归档（2026-10-22 清理待办时归并）
- 朗读页重写（Reader.ets）：读法/原文双视图、逐词高亮、点词跳转、录音停止/取消、打字提问、对话区。
- CQR 契约退化为「一句话问题描述」（无 JSON/surface/intent），提示词只含当前句+当前词。
- 编辑页（Editor.ets）：标题、图片增删排序（拖拽/左滑删除）、识别替换正文、全文编辑、保存。
- 生语汇页（Glossary.ets）：只读展示本课 glossary.txt，可滚动。
- 高亮：词级页内偏移（words 拼接）+ 原文视图不高亮；TTS 分句按长度（≈1200 字）而非标点。
- 已删除旧 `Reading.ets` / `VoiceProbe.ets`、`ScanConfirm` 路由改指 Reader。
- 删除死页面 `pages/ScanConfirm.ets` + 路由（T5）：扫描完成直接进 `pages/Editor`，全量重建后装机正常。
- DeepSeek API 只有前缀缓存，没有上下文压缩（压缩是客户端的事）。
- 图标统一（2026-10-22）：先用裸 `SymbolGlyph`（plus / chevron_left），随后判定"不系统"，
  改为 **HDS 标题栏**（`@kit.UIDesignKit` 的 `HdsNavigation`）：圆形底板 + 文字胶囊按钮都是控件自带的；
  **不重做路由**（`backIcon.action` 里继续 `router.back()`），理由见 decisions D31。
