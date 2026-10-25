# 坑清单（含实测数据，别再踩第二次）

> 每条都标了「症状 / 根因 / 解法 / 证据」。按 **踩坑频率** 排序。

## 构建与部署

### 1. 编译必须完全访问权限
- **症状**：`assembleHap 失败`，或 `ENOENT ...\.hvigor\project_caches\<hash>\workspace\node_modules\@ohos\hvigor\bin\hvigor.js`。
- **根因**：hvigor 要写 `%USERPROFILE%\.hvigor`，并创建 **Junction** 指向 `E:\Tools\DevEco Studio\tools\hvigor\hvigor`。
- **解法**：构建命令用完全访问权限跑。**不要试图改配置绕过**（试过 `HVIGOR_USER_HOME`、重定向 `USERPROFILE`、预建链接，全部无效）。
- **证据**：官方错误码 00308003 的处置是「删掉 `project_caches\<hash>\workspace` 重试」，但下次构建仍要重建。

### 2. 新增 .ets/.ts 后必须全量，否则白屏 401
- **症状**：装机后白屏，`Failed to load the content {"code":401}`。
- **根因**：官方 Hot Reload **不支持「启动应用后新增的代码文件」**（`ide-hot-reload` 文档明确列出）。
- **解法**：`scripts/build-app.ps1` 用「`ets/` 下全部 `.ets`/`.ts` 清单 + `main_pages.json` 哈希」做戳，变了自动 clean。
  **注意早期版本只监控 `pages/*.ets`，新加 `core/*.ts` 会漏**——已修。

### 3. `.ts` 文件不能 import ArkTS 模块
- **症状**：`Importing ArkTS files in JS and TS files is forbidden`。
- **解法**：把文件改成 `.ets`（例：`adapters/tts.ts` → `tts.ets`）。import 路径不变。

### 4. 直接双击/执行 `.js` 会走 Windows Script Host
- **症状**：弹出「Microsoft JScript 编译错误」对话框，或输出莫名其妙的一行错误。
- **解法**：用 DevEco 自带 node 执行：`& 'E:\Tools\DevEco Studio\tools\node\node.exe' <xxx.js>`。

## 音频

### 5. `getAudioTimeSync()` 返回的是**纳秒时间戳**，不是播放时长
- **症状**：位置算出来是天文数字。
- **解法**：用 `getAudioTimestampInfoSync()` → `{framePos, timestamp}`，位置 = `framePos / 16`（16kHz 时 16 帧/毫秒）。
- **别**做 `Date.now() - timestamp/1e6`，`timestamp` 是开机以来的单调时钟。

### 6. 自己 `write()` 喂数据会被饿死
- **症状**：`framePos` 卡在 0，或播放一顿一顿。
- **根因**：限制「领先量 ≤240ms」时缓冲被抽干（80ms 必死）。
- **解法**：改用 `on('writeData')` 回调，由音频线程按需拉数据（官方推荐，API 12+ 支持返回值）。

### 7. `release()` 后立刻 `createAudioRenderer` 会报 6800301
- **解法**：等 250ms 再创建（`seekTo` / `replay` 里都有这个等待）。

### 8. 16kHz 是**必须**的
- TTS 用 `format=pcm, sample_rate=16000`，播放器与 WAV 封装都按 16k 单声道 s16le（32 字节/毫秒）。
- 换成 48k 会让时间戳、字节偏移、seek 全部错位。

## 文本与坐标（最容易返工的一块）

### 9. ArkUI `Text` 没有「字符点击」，但有 `LayoutManager`
- `TextController.getLayoutManager()`（API 12+）提供 `getLineCount` / `getCharacterPositionAtCoordinate` /
  `getRectsForRange` / `getLineMetrics`。
- **`TextController` 和 `LayoutManager` 是全局类型，不是 `@kit.ArkUI` 的导出**，import 会报错。

### 10. 坐标单位与返回值（文档里才有，`.d.ts` 看不出来）
- `getCharacterPositionAtCoordinate(x, y)` 的 **入参是「相对组件的 px」**；
- **返回值是 UTF-8 偏移**（3 参重载可传 `TextEncoding.TEXT_ENCODING_UTF16`）；
- `getRectsForRange` 返回的 `common2D.Rect` **只有 left/top/right/bottom，没有 width/height**。

### 11. `ClickEvent` 用 `x`/`y`，别用 `windowX`/`windowY`
- `e.x`/`e.y` 是**组件内 vp**；实测点击物理 (2114,455) 时 `windowX/Y` 报 (914.16, 1621.62)，比例都不对。
- 链路：`vp2px(e.x)` → `getCharacterPositionAtCoordinate` → 字符下标 → 词下标 → `seekTo`。

### 12. 触摸抬起时 `touches` 可能是空的
- 用 `changedTouches`（`onTouch` 的 `TouchType.Up` 分支）。

### 13. 「整句/整词」判错时先怀疑输入错了
- **症状**：CQR 探针返回 surface=""（整句），而基准应是具体单词。
- **根因**：拿错了录音文件（`a01.wav` ≠ `c01.wav`）。
- **教训**：模型输出异常时，先核对**输入是否真的是你以为的那个**。

### 14. 紧贴字形的矩形会让「行间点击」落空
- `getRectsForRange(..., TIGHT, TIGHT)` 的高度只有字形高，点在行间距上匹配不到。
- **解法**：按「同一行（|y - 中心y| ≤ 18）+ 水平最近」匹配，而不是严格包含判断。

## OCR

### 15. 专用 OCR 模型在照片上没有优势（已用数据否决）
- 按页平均 F1：`qwen3-vl-plus` 0.566 > `qwen3.5-122b-a10b` 0.549 > `qwen-vl-ocr` 0.480 > `qwen3.5-ocr` 0.446。
- 干净单页三者持平，差距全在**跨页/残页**（thumb_4：0.68 vs 0.31/0.42）。
- **结论**：继续用 `qwen3-vl-plus`，不要重测（输出已存在 `artifacts/b2-final/model-outputs/`）。

### 16. 上标注释编号（`likely²`）提示词挡不住
- 提示词加了规则仍会漏 → 代码兜底：`normalizeParagraphs()` 里清除 `U+00B9/B2/B3/2070-2079`。

### 17. 图库流程要两步
- 扫描控件里选「图库」→ 选择器点「完成」只是**加入列表**，
  还要点右上角**带角标的保存图标**才触发 `onResult`。

### 18. 扫描控件不能叠浮层
- 文档明确「不允许被其他组件或窗口遮挡」→ 扫描完成跳**另一个页面**（现在是 `pages/Editor`）。
- `ShootingMode.AUTO` 会对着桌面连拍（实测 10 张废图）→ 用 `MANUAL`。
- `editTabs: []` 会连删除按钮一起去掉 → 保留 `DELETE_TAB` + `ROTATE_TAB`。

## TTS

### 19. 音色必须带 `_v3.1` 后缀
- 否则 `[cosyvoice:]Engine error [411]: TTS speak operation failed`（`core/voices.ts` 里有注释）。

### 20. 时间戳要字级就得开 `word_timestamp_enabled`
- 默认 **false**，不开拿到空 words。SDK 与 HTTP 都是这个参数。

## 其它

### 21. `vp2px`/`px2vp` 只在本进程有效，别写死 2.31
- 实测密度 2.31（3000px 宽 / 1297vp），但**代码里一律用 `vp2px()`/`px2vp()`**，不要硬编码。

### 22. 引入 `neonui.har` 后多了个隐私告警
- 构建提示 `ohos.permission.APP_TRACKING_CONSENT`（疑似 SDK 取 OAID 当 device_id）。
- **上架前必须处理**（声明或联系 SDK 方），否则隐私合规过不了。

### 23. HAP 体积从 2.5MB 涨到 11MB
- 原因：`neonui.har` 4.34MB，含多 ABI 原生库。上架前可只保留 arm64。

### 24. ✅ 麦克风权限（2026-10-22 解决：真的没授权，弹框未被我们点到）
- **症状**：`createAudioCapturer` 返回 `6800301 system error`；应用内 `checkAccessTokenSync` 返回 **0（已授权）**，
  但系统日志明确报权限不足：
  ```
  audio_server [VerifyClientPermission]Permission denied ..., [ohos.permission.MICROPHONE] for uid:...
  audio_server [CheckRecorderPermission]Check record permission failed: No permission.
  <应用>: [comm][InitAudioStream]SetAudioStreamInfo failed   ← 这是权限失败的表象，不是参数问题
  ```
- **排查过程**（都试过、都无效）：16k→48k 采样率、单声道→双声道、强制 `requestPermissionsFromUser`
  （返回 0 且无弹窗）、`bm dump` 确认 `module.json5` 已声明该权限。
- **判断**：`module.json5` 声明是「声明层」，真正授予的权限集合来自**签名 Profile**。
  HAP 的签名配置没重新生成时，新增的权限不会进入 Profile → token 校验通过、系统服务拒绝。
- **真实根因**：权限确实**从未授予**。探针实测：`checkAccessTokenSync = -1`（未授权），
  调用 `requestPermissionsFromUser` 后系统**弹出授权框**（"允许「英语朗读」访问你的麦克风？"），
  点「允许」后 `req=0 after=0`，随即 `createAudioCapturer` **成功**（48k/双声道）。
- **为什么绕了这么久**：之前的截图总是拍在弹框出现之前，看起来"没有弹框、没有授权却失败"。
  又因为把 `checkAccessTokenSync` 的 0/-1 记反了，误判成「token 已授权但系统拒绝」。
- **教训**：① 探针必须**把三件事分开**（查状态 / 申请 / 建采集器）并打印真实数值；
  ② 截图要等弹框出现（或 dumpLayout 看看有没有 dialog）；
  ③ `.p7b` 的 `permissions:{}` / `acls:[]` 对 `user_grant` 权限是正常的，不要据此判断。
- **证据**：`artifacts/perm-1.jpeg`（弹框 + before=-1）、`artifacts/perm-2.jpeg`（before=-1 req=0 after=0）、
  `artifacts/perm-3.jpeg`（createAudioCapturer 成功）、`artifacts/rec-3.jpeg`（录音→解析成功）。
- **证据**：2026-10-21 23:35 设备日志；`artifacts/ask-9.jpeg`（面板显示 `6800301`）。

### 25. 错误信息要带错误码
- `String(err)` 只得到 `"Error: system error"`，必须 `(err as BusinessError).code + ' ' + message`，
  否则要在 hilog 里翻半天。

### 26. 端侧 TTS `playType:1` 回调正常但没声音（疑似没真播）
- **症状**：`onStart → onComplete` 都能收到，间隔 0.84–1.9 秒，但**用户听不到声音**；
  40 多个汉字的回答不可能 0.84 秒念完，说明播报没真正进行（或极快被截断）。
- **已确认**：音频服务侧有 `AudioRenderSink: Sink[primary] RUNNING → SUSPENDED`，说明系统确实开过流，
  但听到与否不能只凭回调判断。
- **待验证的解法**：改用 `playType: 0`（只合成）→ 在 `onData` 里收 PCM → 交给已有的
  `PcmPlayer`（这条音频通路在课文朗读里已验证可出声）。需要先用日志确认引擎输出的采样率/声道。
- **教训**：**「回调完成」不等于「用户听到了」**；音频功能必须人耳确认，
  或者至少校验「时长 ≈ 字数 ÷ 语速」这个下限。

### 26 补充（已查明）：TTS 走「语音助手音量」，与媒体音量是两条独立的流
- **现象**：朗读时按音量键，图标变成非喇叭状（语音助手音量）；朗读结束又变回喇叭（媒体音量）。
- **原因**（官方文档 `SpeakParams.extraParams.soundChannel`）：播报通道取自 `StreamUsage`，
  **不传默认 3 = 语音助手通道**；我们显式传了 3，所以 TTS 走「语音助手」这条音量流。
  而课文播放器用的是 `STREAM_USAGE_MUSIC`（媒体流）——两者音量互不影响。
- **后果**：媒体音量正常但语音助手音量为 0 时，表现为「课文有声音、回答没声音」，非常容易误判为 bug。
- **可选改法**：把 `soundChannel` 改成媒体通道（1）即可共用媒体音量；
  但文档明确提示「通道 1 或 12 在息屏场景会出现播报截断（进入音频低功耗模式）」，需要权衡。

### 26 二次更正：0.84 秒「播完」是**合成结束**，不是播报结束
- `CompleteResponse.type`：**0 = 合成结束，1 = 播报结束**。我们之前只看事件没看 `type`，
  把「合成结束」当成了「播报结束」，于是误判「0.84 秒念不完 40 字 → 没真播」。
- 实际：合成很快（<1s），播报按正常语速进行，`AudioRenderSink SUSPENDED` 出现在数秒之后，
  与真实播报时长吻合。**音频有没有出声，仍要人耳确认**，但判断依据应是 `type === 1` 与音频流状态。

### 27. 列表拖拽排序：`onMove` 挂在 **ForEach** 上（文档示例 12），不是 List
- **症状**：给 `List` 挂 `.onMove(...)` 编译报错 `Property 'onMove' does not exist on type 'ListAttribute'`。
- **原因**：文档说的「`onMove` ... 当父容器为 List 或 Grid 时生效」指的是通用属性表，
  但当前 SDK 里 `onMove` 声明在 `common.d.ts` 的 **`DynamicNode<T>`** 上（动态节点用），
  `ListAttribute` 拿到的是 **`onItemMove(event: (from, to) => boolean): ListAttribute`**。
- **正确写法（文档示例 12 抄下来）**：

```ts
List() {
  ForEach(this.arr, (item: string) => {
    ListItem() { Text(item) }
  }, (item: string) => item)
    .onMove((from: number, to: number) => {     // ← 挂在 ForEach 上，不是 List
      const tmp = this.arr.splice(from, 1);
      this.arr.splice(to, 0, tmp[0]);
    })
}
```

- **前提**：`ForEach` 每次迭代必须生成一个 `ListItem`，否则不生效。
- **教训**：只读 `.d.ts` 会看到 `onMove` 在 `DynamicNode<T>` 上，从而误判「List 用不了 onMove」并退而用 `onItemMove`。
  **文档示例才是用法来源**。

### 28. UI 图标状态不要自己记标志位（`PcmPlayer` 才是真源）
- **症状**：点击跳转后没播放，却显示「暂停」图标；再点又变成「播放」但实际在播——图标与实际相反。
- **根因**：页面里用 `this.playing / this.paused` 自己猜状态；而 `seekTo(ms)` 的语义是
  **「原本在播才继续播，否则只改位置」**（源码注释如此），所以跳转后其实停着，标志位却写着在播。
- **解法**：`PcmPlayer` 增加 `isPlaying(): boolean`（返回 `playing && !paused`）；
  页面所有图标状态**只从它同步**（`syncState()`），不再手工赋值。
- **教训**：任何「播放/暂停」类 UI，状态必须来自播放器；想播就显式 `play()`。

### 37. 课程数据被清空，而唯一的完整备份被我删了（2026-10-23）
- **现象**：`files/course/` 变空（目录 mtime 18:08），11 门课的 `text.txt`/`images/`/`audio.pcm`/`words.json`
  全没了。表现为导出时 `[export] courses=0`、zip 只有 **22 字节**（空包）——追了两小时才发现是**没有数据可打包**。
- **能救的**：`files/backup_v0_1792733185891/<id>/{meta.json, glossary.txt}`（10 门：标题/时间戳/旧语汇录）、
  `files/migration.log`（课程 id 清单）。**正文、图片、音频、词级时间戳都没有备份**。
- **我的责任**：18:02 曾导出过一份完整 zip（17.9MB / 48 条目），18:16 我为了清测试目录执行
  `rm -rf '<用户目录>/文库'/*`，把它一起删了；拉到 PC 的临时副本也随手删了。**删之前没确认是否还有别的副本**。
- **教训**：
  1. 删任何「可能是唯一备份」的东西前，先确认还有第二份；
  2. 测试清理只删本次自己新建的文件，**不要用 `rm -rf <目录>/*`**；
  3. 导出/备份**必须在 App 内留一份**（`files/backup/`），不能只落在用户目录——用户和开发者都会去清。
- **待改**：删除课程改为移入 `files/trash/<时间>/<id>`；导出成功后保留最近 2 份 zip；迁移备份改整目录。

### 36. picker 返回的 URI 里中文被**百分号编码**，直接当路径用就 ENOENT
- **症状**：导出到用户**自建的「文库」文件夹**（中文名）时，11 门全失败、`13900002 No such file or directory`；
  导到纯英文的 `Download` 却成功——所以很容易漏测。
- **根因**：`js-apis-file-picker` 明确写「URI 中的中文及非数字字母的特殊字符会被编码为对应的 ASCII 码」，
  `file://docs/storage/Users/currentUser/Download/文库` 实际返回的是 `.../%E6%96%87%E5%BA%93`；
  我们把它还原成路径（只去掉 `file://docs`）后，路径里还是 `%E6%96%87...`，当然不存在。
- **解法**：还原路径后**必须 `decodeURIComponent`**（含非法转义就按原样用）。
- **教训**：验证「导出到用户目录」这类功能，**至少要试一次中文目录名**。
- **证据**：修前 11/11 失败（`artifacts/exp-r1.jpeg` 显示目标为 `下载 > 文库`），修后 11/11 成功，
  `文库/c_mvjrl9gw_v33/audio.pcm` = 10,534,400 字节。

### 35. 用户目录只认 URI，沙箱接口只认路径——两边要手动换算
- **症状**：`fs.copy(沙箱URI, 文档URI)` 报 **13900020 Invalid argument**；`fs.mkdir(文档URI)` 报 **13900002 No such file**；
  日志里还有 `file_api: Invalid path from JS first argument`。
- **根因**：`copy`/`mkdir` 的参数按文档是**应用沙箱路径**；picker 给的、`fileUri.getUriFromPath` 生成的都是 **URI**。
- **解法**：把文档 URI 按官方格式还原成路径再调用：
  `'file://docs/storage/Users/currentUser/Download/x'` → `'/storage/Users/currentUser/Download/x'`
  （`user-file-uri-intro`）。picker 授权过的目录，**用路径就能建目录、写文件**。
- **另一个坑**：别手写 `read → write` 循环拷文件——实测 `audio.pcm` 只写出 **65536 字节**（一块）就断了；
  用 `fs.copyFileSync(src, dest)`。
- **证据**：`artifacts/export-picker*.jpeg`、导出后 `du -sk` 源与目标同为 10403 KB。

### 34. 课本的段首标号会被 TTS 念进正文
- **症状**：读法里出现 `speak one Every year`、`Two You might notice` —— 段落编号被念成英文数词，粘在上一段末尾。
- **根因**：OCR 保留了段首编号（`1`、`2`、`11`…），TTS 把它当数字读出来。
- **解法**：提示词明确「去掉段首编号」，代码再兜底 `stripLeadingNumber()`：
  数字/罗马数字/圆圈数字直接去；英文数词只有**后接大写字母**才去（避免误删 `One day,`、`Two men`）。
- **证据**：同照片改前读法 `speak one Every year`，改后 5 段、段首无编号。

### 33. WS 版 TTS SDK 在长文本上「偷工」：音频只有 1/3、时间戳被均分
- **症状**：高亮开头几个词正常，随后**匀速**逐词推进；同一处语音缺了一段。
- **识别特征**（拿到 `words.json` 三秒可判）：
  1. 相邻 `begin` 增量**恒定**（这台机器上是 88ms 或 97ms，两段各一个常数）；
  2. 词长与词时长相关系数≈**0**（真实语音应 >0.4）；
  3. 音频时长 ≈ 字符数 ÷ 40（正常是 ÷15）。
- **根因**：`neonui`（WebSocket）通道把 5200 字符切成 **2 块**，只回 **137 秒**音频，
  词时间戳按剩余时长平均分配。同一文本 HTTP 通道给 **15 块 / 329 秒 / 相关性 0.607**。
- **解法**：改用 HTTP + SSE（`X-DashScope-SSE: enable`），见 D35 与 `apis.md`。
- **证据**：`artifacts/tts-dump-1792715269648.json`（WS）、`artifacts/tts-dump-http.json`（HTTP）。

### 32. 别让模型手写 YAML —— 用 JSON Output
- **症状**：让模型"只输出一个 YAML 映射"，它把序列写成 `单词: tuck, away`（没有方括号），
  应用解析成**一个**词 `tuck, away`；换句问又出现别的写法。
- **根因**：YAML 的序列/引号/冒号规则对模型是"隐性知识"，写错也不报错——只是含义悄悄变了。
- **解法**：输出改 **JSON** + `response_format: {'type':'json_object'}`（DeepSeek 官方保证合法 JSON）；
  prompt 里必须有 `json` 字样并给 2~3 个形状样例；文件仍由应用序列化成 YAML。
- **实测**：改 JSON 后 单词 / 搭配 / 其他 三种形状各一次全部正确
  （`单词: 'devoured'`、`单词: ['casual','glance'] + 搭配: 'casual glance'`、其他两键都不出现）。
- **注意**：官方写明 JSON Output **有概率返回空 content** → 保留「回答为空，再问一次」的提示。

### 31. 读法文本里句号后常常**没有空格** → 按「句号+空格」判句界会得到整篇
- **症状**：`glossary.yaml` 里的「语境」是**整篇课文**；模型回答里冒出「这个词没有出现在当前句里」。
- **根因**：读法（TTS `words[].text` 拼接）里 `travel.One`、`create.Three` 这类**句号后直接接词**；
  用「句号 + 空格」当句界，一个边界都找不到 → 返回整段。
- **解法**（用户定的规则，故意做笨）：左端「当前词首字符是句号就取后一位，否则**向左找第一个句号**」，
  右端「**向右找第一个句号**（含句号）」；感叹号/问号不管——多圈一点无害，漏半句才麻烦。
- **别用**：`splitSentences` 的结果去累加长度推字符偏移——分句丢了分隔空白，累加会**累积漂移**，
  越往后越偏，最后定位到文末（踩过）。
- **证据**：同一门课 `glossary.yaml` 前后对比（整篇 → `'The secret to remembering travel.'`）；
  跳词后再问，语境变成含该词的那一句。

### 30. `HdsNavigation` 默认 `Auto` 模式：平板会走分栏、标题栏还是浮层
- **症状**：加上 `HdsNavigation` 后，内容被压到右侧、左边多出一块 240vp 的导航栏；
  另一次是标题栏和第一行内容**重叠**、＋ 按钮压在 ⋮ 上。
- **根因**：
  1. `mode` 默认 `NavigationMode.Auto` → **窗口 ≥600vp 走 Split**（平板必然触发）；
  2. 标题栏是**浮层**，官方所有示例都在内容里先放 `Blank().height(56)` 预留高度，框架**不替你让位**。
- **解法**：`.mode(NavigationMode.Stack)` + 内容加 `.padding({ top: 56 })`（`titleMode(MINI)` 时标题栏高 56vp）。
- **证据**：`artifacts/hds-gloss.jpeg`（分栏挤压）→ `hds-gloss2.jpeg`（Stack 修好）；
  `hds-lib.jpeg`（重叠）→ `hds-lib2.jpeg`（留 56vp 修好）。

### 29. `uitest uiInput click` 打不中 `bindMenu` 弹层（自动化不了）
- **症状**：文库页 ⋮ 菜单弹出后，按截图量出的坐标点「生语汇」/「删除」，结果**菜单只是关掉**，
  页面没有跳转、也没有弹二次确认。
- **证据**：2026-10-22 两次实测（生语汇、删除各一次），坐标都落在菜单项中心；`No Error` 但无动作。
  同时 `uitest dumpLayout` 里**根本看不到菜单节点**（只有主窗口的组件树）。
- **判断**：`bindMenu` 弹层是独立 popup 窗口，注入的触摸事件没有送达它，或 item 的点击需要窗口级路由。
- **影响**：凡是「菜单项 / 弹层里的按钮」都**无法用命令行自动化验证**，只能人手动点。
- **绕法**：想自动化就先改成页内浮层（同一 `Stack` 里画一个遮罩 + 面板，如 Library 的重命名浮层），
  再不行就接受人工验证，别在坐标上反复试。
- **误判风险**：别把它当「点击坐标不对」——坐标是对的，事件压根没进那个窗口。
