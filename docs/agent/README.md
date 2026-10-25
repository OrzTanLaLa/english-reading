# 给 AI 的交接目录（agent/）

> **如果你是接手的 AI：先读完本文件，再按 `project/state.md` 的「下一步」继续。**
> 这里写的都是**压缩上下文后会丢掉、但做错就要返工**的东西。

## 这个目录是什么

给 AI 协作者的可恢复记忆。人类文档（`docs/交接说明.md`、`docs/UI设计.md`）解释「产品是什么」，
这里解释「**为什么这样做、哪里会踩坑、下一步做什么**」。

| 目录 | 内容 | 什么时候看 |
|---|---|---|
| `project/state.md` | 当前进度、下一步、未决问题、当前阻塞 | **每次接手第一件事** |
| `project/implementation.md` | **设计 → 代码** 对照（改哪里） | 动代码前，配合 `docs/应用设计.md` 看 |
| — | UI 细节（每页布局/状态/字号）现在只在 `docs/应用设计.md` §4 | 调界面时看那份 |
| `project/handoff.md` | 历史交接说明（详细背景、验证数据） | 需要查旧细节时 |
| `project/environment.md` | 环境搭建（DevEco/SDK/设备） | 换机器或环境坏了 |
| `project/api-review.md` | API 复审（逐块对照官方文档的结论） | 想换实现方案前 |
| `project/tech-plan.md` | 技术方案（算法、数据流、离线验证结论） | 查算法细节 |
| `project/pipeline.md` | 代码结构、数据流、关键类型 | 改代码之前 |
| `project/pitfalls.md` | 21 条已踩实的坑（含实测数据） | 动手前扫一遍，尤其是构建/播放/坐标 |
| `project/decisions.md` | 关键决策与被否决的方案（ADR 风格） | 想改方案之前，先看它是否已被否决过 |
| `project/apis.md` | 用到的接口速查（单位、语义、版本门槛） | 写调用代码之前 |
| `lessons/build-harmonyos.md` | 鸿蒙构建/装机经验（换项目也能用） | 新项目或构建坏了 |
| `lessons/docs-mcp.md` | 文档 MCP 接入与使用 | 需要查官方文档 |
| `lessons/collaboration.md` | 与人类协作的约定（本项目总结） | 刚开始接手时 |
| `lessons/debugging.md` | 排障方法论（这次学到的） | 卡住时 |

## 三条铁律

1. **先查文档，再动手。** 用 `mcp__harmonyos__*` / `mcp__aliyun__*`（见 `lessons/docs-mcp.md`）。
   凡是我凭记忆写 API 的地方，事后几乎都错了。
2. **花钱的动作先确认有没有缓存/现成产物。** TTS 合成、Omni 解析、OCR 都会计费。
   OCR 的模型对比直接读 `artifacts/b2-final/model-outputs/` 打分，别重跑。
3. **结论写回本目录，别只留在对话里。** 上下文会被压缩，对话会消失。

## 仓库地图（速查）

```
docs/应用设计.md           ★ 人机共用：产品设计（流程/页面/规则/成本/不做的）
docs/待办清单.md           ★ 人机共用：进度与待办
docs/agent/                ← 本目录（AI 的额外记忆）
app/                      鸿蒙工程（entry/src/main/ets/）
  core/                   纯逻辑：course reader segment morph dict contracts prompts voices
  adapters/               平台对接：courseStore player tts(ets) ocr cqr recorder llm storage local_secret
  agent/                  loop.ts（工具循环）+ tools.ts（echo / append_vocabulary）
  pages/                  Library Scan Editor Reader Glossary + 若干 Probe 页
scripts/                  build-app.ps1 hsdocs.py webfetch.py test_aliyun_mcp.py 等
docs/                     人类文档（交接说明 / UI设计 / API复审 / 待办清单）+ vendor/（拉下来的官方文档）
docs/agent/               ← 本目录
validation/               离线验证产物（B0A 文本、B0B TTS、B0C 语音提问录音与基准）
artifacts/                测试照片、模型输出、截图
dsh-plugins/docs-mcp/     DSH 插件：文档检索 MCP 的 bundle
```

## 当前一句话状态

**v1.0.0 已完工（2026-10-23）**：拍照→OCR→编辑→HTTP+SSE 合成→播放/逐词高亮/点词→
打字或语音提问→JSON 答者回答并写入 `glossary.yaml`→语汇录查看→设置（关于/API Key/导出文库数据）。
版本管理（versionCode + schemaVersion + 幂等迁移）已就位；自用不上架。详见 `project/state.md`。

## 维护本目录（每轮都要做）

**每轮回答结束前检查一次**，按情况修改/新增/删除文件：

| 发生了什么 | 改哪个 |
|---|---|
| 进度、下一步变了 | `project/state.md` |
| 做了取舍 / 否决了方案 / 方向被更正 | `project/decisions.md` |
| 踩到新坑或纠正旧认知 | `project/pitfalls.md` |
| 用了新 API、发现单位或版本门槛 | `project/apis.md` |
| 得到可迁移的经验 | `lessons/*.md`（构建 / 查文档 / 协作 / 排障） |
| 目录、路由、入口变化 | 本文件的「仓库地图」 |

三条要求：

1. **一个事实只写一次**，写在最合适的文件里；
2. **写数字不写感觉**（「首包 499ms」而不是「挺快」）；
3. **发现文档与代码不符就立刻消除矛盾**——要么改文档，要么改代码，别留着。

**提交**：一轮工作结束前必须 commit；文档与对应代码同一次提交；
提交信息写「做了什么 + 为什么 + 关键证据」。
