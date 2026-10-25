开发者温馨提示：以下全是AI生成，本人一行代码也没写

# English Reading · 拍课文 → 朗读高亮 → 语音提问 → 语汇录

鸿蒙（HarmonyOS）平板上的英语精读工具：**拍照或从图库导入课文 → OCR 识别 → 编辑排版 →
云端 TTS 朗读并逐词高亮 → 暂停时用语音或打字提问 → 大模型回答并自动记进语汇录**。
自用应用，不上架应用市场。

## 状态

**v1.0.0 已完工**（2026-10-24），在 MatePad（`GEM-W00`，API 26）上逐项验过；构建产物 **2.89 MB**。

| 能力 | 实现 |
|---|---|
| 导入 | 拍照 / 图库多选 → `qwen3-vl-plus` 识别，自动去段首编号、段间空行 |
| 编辑 | 改标题、增删排序图片、重识别、改全文 |
| 朗读 | `qwen-audio-3.1-tts-flash` **HTTP + SSE** 流式合成，PCM 16 kHz 单声道 |
| 高亮 | 词级时间戳逐词高亮；点任意词跳转播放 |
| 提问 | 打字或用 `qwen3.8-omni-flash` 解析录音；语境 = 原文全文 + 读法当前句 |
| 回答 | `deepseek-chat` **JSON Output**，一次调用拿「类型 + 回答」 |
| 语汇录 | 代码写 `glossary.yaml`（类型/单词/搭配/语境/问题/回答），幂等去重 |
| 其他 | 设置（关于 / 修改 Key / 导出）、数据版本迁移、导出 zip |

成本量级：TTS ≈ 0.4 分/篇（5200 字符 ≈ 28 s）、OCR ≈ 0.02 分/页、每次提问 1 次 DeepSeek 调用。

## 仓库里有什么

```
app/            应用源码（ArkTS/ArkUI），HAP 源码全部在这里
scripts/        构建、查文档、测试脚本
docs/           设计文档 + Agent 交接材料（docs/agent/）
AGENTS.md       给 AI 协作者的工作约定
```

**没有入库**（见 `.gitignore`）：`artifacts/`（截图与音频，约 73 MB）、`validation/`（验证探针与词典数据）、
`docs/vendor/`（官方文档缓存）、`app/entry/src/main/ets/adapters/local_secret.ts`（真实 Key）。

## 构建与安装

```powershell
# 一条命令：构建 + 安装 + 打开指定页
pwsh -File scripts\build-app.ps1 -Install -Page pages/Library
```

或者手动：

```powershell
cd app
$env:NODE_HOME='E:\Tools\DevEco Studio\tools\node'; $env:DEVECO_SDK_HOME='E:\Tools\DevEco Studio\sdk'
hvigorw.bat assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
hdc install -r entry\build\default\outputs\default\entry-default-signed.hap
```

- **升级只 `install -r`，绝不卸载**（卸载会清空课程数据）；
- 装到另一台设备要重做签名（debug Profile 里的 UDID 要包含该设备）。

## API Key 怎么配

Keys **不进代码仓库**，两种方式：

1. 应用内：**设置 → 修改 API Key**（密码样式输入，存 Preferences）；
2. 开发调试：复制 `local_secret.example.ts` 为 `local_secret.ts` 填值（该文件已 gitignore）。

需要两个 Key：百炼（DashScope，OCR/TTS/语音解析）、DeepSeek（答题）。

## 数据存放

沙箱 `files/course/<课程id>/`：

```
meta.json      标题/音色/textHash/播放位置/schemaVersion
text.txt       正文          images/     原始照片
audio.pcm      合成音频      words.json  词级时间戳
sentences.json 分块区间      glossary.yaml 语汇录
```

导出：设置 →「导出文库数据」→ 选目录 → 生成 `英语朗读-<时间>.zip`（解开就是上面的目录结构）。

## 文档入口

| 想了解 | 看 |
|---|---|
| 产品设计与交互 | [`docs/应用设计.md`](docs/应用设计.md) |
| 当前状态 / 待办 | [`docs/待办清单.md`](docs/待办清单.md) |
| 接手项目（AI 或人） | [`docs/agent/README.md`](docs/agent/README.md) |
| 踩过的坑 | [`docs/agent/project/pitfalls.md`](docs/agent/project/pitfalls.md) |
| 技术与取舍 | [`docs/agent/project/decisions.md`](docs/agent/project/decisions.md) |

## 已知限制

- 语言以英语为主（TTS `language_hints: ['en']`）；
- 朗读文本会把破折号类字符（`—` 等）替换成逗号后送去合成；
- 提问的“当前句”取自朗读用的读法文本，与原文不逐字相同（全文用原文，模型自行对应）；
- 只在鸿蒙 API 26 平板上验证过，手机需自行改布局。
