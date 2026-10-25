> **接手本项目？先读 [`docs/agent/README.md`](docs/agent/README.md)**：
> 里面是给 AI 的交接材料（当前状态、坑清单、决策记录、可迁移经验）。
# 给 AI 协作者的工作约定（本仓库）


## 0.5 每轮回答都要维护 `docs/agent/`（硬性）

**每一轮回答结束前，必须检查并更新交接文档；没有更新就说明理由。**
上下文会被压缩，只有落盘的内容能留下来。

| 这一轮发生了什么 | 更新哪个文件 |
|---|---|
| **设计变更**（UI/流程/规则/成本/不做的） | `docs/应用设计.md`（人机共用，**人也要看**）→ 再同步 `docs/agent/project/implementation.md` |
| **新任务 / 完成 / 取消任务** | `docs/待办清单.md`（人机共用）→ 进度细节进 `state.md` |
| 推进/完成了任务、状态变化 | `docs/agent/project/state.md`（进度、下一步、未决问题） |
| 做了取舍、否决了某方案、方向被更正 | `docs/agent/project/decisions.md`（新增 ADR，写明理由与被否决项） |
| 踩到新坑 / 纠正了旧认知 | `docs/agent/project/pitfalls.md`（症状/根因/解法/证据） |
| 用了新 API、发现单位或版本门槛 | `docs/agent/project/apis.md` |
| 得到可迁移的经验（构建、查文档、协作、排障） | `docs/agent/lessons/*.md` |
| 目录结构、入口、路由变化 | `docs/agent/README.md` 的仓库地图 |

规则：

1. **一个事实只落盘一次**，写在最合适的那个文件里，别到处复制；
2. **宁可短、必须准**：写实测数字，不写「应该可以」；
3. 删除过时内容也是维护——发现文档与代码不符时，**改文档**或**改代码**，不要留着矛盾。

## 0.6 提交时机

- **一轮工作结束前必须提交**，不要把改动留在工作区过夜；
- 一次「可独立验收」的改动 = 一次提交；文档与对应代码**同一次提交**，便于回溯；
- 大改之前先提交当前可运行状态，留一个回退点；
- 提交信息用中文，写「做了什么 + 为什么 + 关键证据」，例如：
  `播放器：改 writeData 回调驱动（实测暂停冻结 16/36s、恢复续播）`。

## 0. 先查文档，再动手

**遇到任何 API / 平台行为不确定的情况，先去查官方文档，不要凭记忆或猜测改代码。**
这条不是建议，是硬性流程。

**查「某个类的属性/方法」也必须查文档，不要读 SDK 的 `.d.ts`。**
用户明确要求：能用的方法一定都在文档里；`.d.ts` 只有声明、没有用法与生效条件，容易导出错误结论。
做法：`searchDocuments("List 组件 ...")` → `getDocumentsById(parent)` → 读「属性/示例」章节。
（实测：`onMove` 在文档示例 12 里是挂在 **ForEach** 上的，不是 `List`；只读 d.ts 会得出相反结论。）

### 0.1 两条铁规矩（用户明确要求，2026-10-22）

**① 不到万不得已，不要翻 SDK 目录。**
SDK 里的 `.d.ts`、资源名表（如 `sysResource.js`）、内部实现文件都**不是**给应用开发者看的资料：
没有语义、没有生效条件、没有版本门槛，看到的往往还不是真实用法。
**先走文档（MCP → llms.txt）**；只有当文档确实查不到、又必须确认一个客观事实
（例如"这个资源名到底存不存在"）时，才允许去 SDK 里**只做存在性核对**，并把结论标注为「SDK 核对，非文档依据」。

**② MCP 搜不到满意结果时，必须转 `llms.txt`，不许据此下"没有"的结论。**
MCP 是**语义召回**，排不进 topK 就等于"看起来没有"（实测反例：`qwen-audio-tts-server-events` 在
`aliyun-model-studio-llms.txt` 里一字不差地存在，MCP 搜不到）。所以顺序是：

```
MCP 语义搜（探索、不知道叫什么时）
   ↓ 结果不满意
llms.txt 索引（确定性目录，全量列标题 + .md 链接）→ 直接 GET 那篇 .md
   ↓ 还没有
按 llms.txt 的路径规律猜 .md 硬抓
   ↓ 仍不行
才考虑 SDK 核对
```

索引地址：`https://developer.huawei.com/llms.txt`（→ `…/llms/docs-<类目>.txt`）、
`https://help.aliyun.com/zh/llms.txt`（→ `…/<产品>/llms.txt`）。本仓库已缓存到 `docs/vendor/index/`。


### 首选：MCP 原生工具（已接入，直接用）

| 场景 | 工具 |
|---|---|
| 鸿蒙文档 | `mcp__harmonyos__searchDocuments` → `mcp__harmonyos__getDocumentsById` |
| 阿里云文档 | `mcp__aliyun__AlibabaCloud___SearchDocuments` → `GetDocument` / `GetDocumentTree` / `GrepDocuments` |

它们返回**官方 Markdown 正文**，与官网准实时同步。**不要**再用脚本或网页抓取去重复这件事。

**抓到的正文要落盘**：存到 `docs/vendor/<有意义的文件名>.md`，并在 `docs/agent/project/apis.md`
对应条目旁写上本地路径；新文件登记进 `docs/vendor/INDEX.md`。
理由：省一次网络请求、断网可查、也便于我 grep 复查。

### 备用：脚本（MCP 不可用时）

本仓库也备好两条不依赖插件的查询通道：

### 鸿蒙（HarmonyOS）

```powershell
python scripts/hsdocs.py search "关键词" --top 5     # 语义检索，返回 parent 标识
python scripts/hsdocs.py get <parent> [<parent>...]  # 取全文，落到 docs/vendor/
```

- 源自「鸿蒙开发者知识 MCP」，返回 Markdown 正文，官方称与官网同步延迟 ≤30 分钟；
- PowerShell 直连会 TLS 失败（schannel `SEC_E_NO_CREDENTIALS`），必须用 Python；
- JSON-RPC 参数要包一层：`{"SearchDocumentsReq":{"query":…}}` / `{"GetDocumentsByIdRequest":{"names":[…]}}`。

### 阿里云

- 一级索引 `https://help.aliyun.com/zh/llms.txt` → 二级 `…/<产品>/llms.txt` → 逐篇 `.md`；
- 索引已缓存：`docs/vendor/index/aliyun-llms.txt`、`docs/vendor/index/aliyun-model-studio-llms.txt`（2573 条）；
- 正文直接 GET 即可，返回 `text/markdown`；用 `grep` 在缓存索引里定位更省事。

### 已知的坑（都踩过）

1. 文档中心是前端渲染，`web_fetch` 拿不到正文 → 必须走 llms.txt / MCP 里的 `.md`；
2. `.d.ts` 只有签名，**没有单位、取值范围、语义**（例如 `getCharacterPositionAtCoordinate` 入参是 px、
   返回值是 UTF-8 偏移），这些只在文档正文里；
3. 文档里的示例可能滞后（例如某接口示例仍用旧参数名），以「参数表」为准。

## 1. 构建

```powershell
pwsh -File scripts\build-app.ps1 -Install -Page pages/XXX
```

- hvigor 要写 `%USERPROFILE%\.hvigor` 并创建 Junction 指向 IDE 安装目录 → **必须完全访问权限**；
- 新增 `.ets`/`.ts` 文件后必须全量（官方：Hot Reload 不支持「启动应用后新增的代码文件」，否则白屏 401）；
  脚本已按「`ets/` 全量清单 + 路由哈希」自动判定。

## 2. 省钱

- 任何会触发云端计费的动作（TTS 合成、Omni 解析、OCR）在验证前先确认「有没有缓存 / 已有产物可用」；
- OCR 的模型 A/B 直接用 `artifacts/b2-final/model-outputs/` 里已有的输出打分，不要重跑；
- 朗读页已有音频缓存（`meta.json` 的 `textHash` 命中就不重新合成）。

## 3. 改动前先看

1. `docs/应用设计.md`（要做什么）
2. `docs/待办清单.md`（做到哪了）
3. `docs/agent/README.md` → `project/state.md`（当前状态与阻塞）
4. `docs/agent/project/implementation.md`（改哪个文件）
5. 需要背景时：`project/handoff.md`、`project/decisions.md`、`project/pitfalls.md`

结论性的东西写在 `docs/` 里，不要只留在对话里。
