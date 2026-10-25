# 查官方文档（本项目已接 MCP）

> 这是本项目最重要的一条经验：**不确定就查文档，别靠记忆写 API**。

## 三条通道，按优先级

### 0.0 为什么 MCP 有时「查不到」——两种检索要分清

| | MCP `searchDocuments` | `llms.txt` 索引 |
|---|---|---|
| 本质 | **语义检索（向量召回）**，返回 topK 片段 | **确定性目录**，全量列出标题 + `.md` 链接 |
| 适合 | 知道大意、不知道文档叫什么的**探索** | 找「某产品有哪些文档」、**精确标题** |
| 失败方式 | 召回排序被带偏 / topK 截断 → **看起来"没有这篇"** | 只有索引没收录才会漏 |

**实测反例（2026-10-22）**：`qwen-audio-tts-server-events`（百炼 TTS 服务端事件，含 `original_text` 字段）
用 MCP 搜 `qwen audio tts 服务端事件 sentence-end original_text words` → **返回的全是「智能语音交互」的 SDK 文档**，没有目标页；
但在 `docs/vendor/index/aliyun-model-studio-llms.txt` 里，它**一字不差地存在**：

```
- [Qwen-Audio-TTS服务端事件](https://help.aliyun.com/zh/model-studio/qwen-audio-tts-server-events.md)
```

→ 说明 MCP **并非没收录**，而是语义召回没把它排进前 3。

**正确顺序**（2026-10-22 用户再次强调，已升为 AGENTS.md §0.1 铁规矩）：
1. 找"某类有哪些文档"→ 先查 llms.txt（阿里云一级/二级；华为 `developer.huawei.com/llms.txt`）；
2. 知道大概概念 → MCP 语义搜；
3. **MCP 结果不满意时不许下"没有"的结论，必须转 llms.txt**，再按路径规律直接取 `.md`；
4. 都不行才去 SDK 核对存在性（**不到万不得已不翻 SDK**）。

### 0. MCP 返回什么（含链接）

- `searchDocuments(query, topK)` → 每项 `{parent, content}`：**只有片段，没有链接**；
- `getDocumentsById([parent, ...])` → 每项 `{name, title, uri, content}`：
  - `uri` 就是官网链接，例如 `https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-container-list`
  - `content` 是整篇 Markdown，**内含大量内联链接**（别的类、示例、指南），可以直接顺着跳。
- 所以「想看某个类有哪些方法」= search 找到 parent → get 拿全文 → 读「属性 / 示例」章节。

### 1. MCP 原生工具（首选，已装）

| 场景 | 工具 |
|---|---|
| 鸿蒙 | `mcp__harmonyos__searchDocuments` → `mcp__harmonyos__getDocumentsById` |
| 阿里云 | `mcp__aliyun__AlibabaCloud___SearchDocuments` → `GetDocument` / `GetDocumentTree` / `GrepDocuments` |

返回官方 Markdown 正文，准实时同步。**不知道文档叫什么时，用 `SearchDocuments`（语义检索）最省事。**

### 2. 脚本（MCP 不可用时）

```powershell
python scripts\hsdocs.py search "关键词" --top 5      # 鸿蒙
python scripts\hsdocs.py get <parent>                # 取全文
```

### 2.5 华为开发者站也有 llms.txt（2026-10-22 发现）

- 一级索引：`https://developer.huawei.com/llms.txt`（6.8 KB，58 行，按 Doc Center 目录分类）
- 二级索引：`https://developer.huawei.com/consumer/cn/llms/docs-<类目>.txt`
  例：`docs-ux-design.txt`（50 KB / 322 行）、`docs-deveco-studio.txt`、`docs-release-notes.txt`
- 条目形如 `- [标题](https://developer.huawei.com/consumer/cn/doc/.../xxx.md): 摘要`，**直接给 .md 链接**，
  GET 即可拿正文（无需登录、无需渲染）。
- 已缓存：`docs/vendor/index/harmonyos-llms.txt`
- **覆盖边界**：只包含「开发者文档」，**不包括**设计站（design/harmonyos-icon）与云社区博客（bbs.huaweicloud.com）。

### 3. 直接抓 .md（阿里云/其它支持 llms.txt 的站）

```
https://help.aliyun.com/zh/llms.txt                    # 一级索引
https://help.aliyun.com/zh/<产品>/llms.txt             # 二级索引（含逐篇 .md 链接）
```

正文 GET 即可，返回 `text/markdown`。

### 4. 没有 llms.txt 的站（如 DeepSeek）

`api-docs.deepseek.com` 是 Docusaurus **服务端渲染**，`/llms.txt` 返回的是 SPA 壳页（和 404 一样）。
用 `scripts/webfetch.py` 剥 HTML：

```powershell
python scripts\webfetch.py https://api-docs.deepseek.com/zh-cn/api/create-chat-completion --grep max_tokens
```

## 踩过的坑

1. **文档中心多数是前端渲染**，`web_fetch` 拿到的是空壳 → 必须走 `.md` 或 MCP。
2. **`.d.ts` 只有签名，没有语义**。例：`getCharacterPositionAtCoordinate` 的入参是 px、
   返回值是 UTF-8 偏移——这两条只在文档正文里。
3. **文档示例可能滞后**，以「参数表」为准。
4. **PowerShell 直连 HTTPS 可能 TLS 失败**（`schannel SEC_E_NO_CREDENTIALS`），用 Python。
5. **MCP 的 JSON-RPC 参数可能要包一层**（华为：`{"SearchDocumentsReq":{...}}`），照 `tools/list` 的 schema 写。

## DSH 插件怎么接的（复现步骤）

1. DSH 自带技能 `cordis-plugin-development`（在 `app.asar` 里），MCP 接入用**配置型 bundle**，不写代码；
2. bundle 三件套：`package.json`（`dsh.bundle.patch`）+ `cordis.patch.yml` + `locale/icon`；
3. patch 里 insert `@deepseek-ai/dsh-mcp-client`，`transport: streamable-http`（远程）或 `stdio`（本地代理）；
4. 安装：Harness 的 `plugin_manager`，`action: install_bundle`，`target` 是包目录**绝对路径**；
5. **秘钥不要写进 patch**，用 `!!js process.env.X` 引用；改了环境变量要**重启 Harness** 才生效。

阿里云那条走静态凭证：本地代理 `alibabacloud.mcp-proxy`（uvx 跑），AK 从环境变量读。
uv 的缓存目录要指到工作区，否则 `AppData\Local\uv\cache` 会「拒绝访问」：

```powershell
$env:UV_CACHE_DIR = 'E:\Project\english-reading\.tools\uv-cache'
```

自检脚本：`python scripts\test_aliyun_mcp.py`（起代理 → initialize → tools/list，不用重启 Harness）。

## 成本：MCP Server 本身不收费（2026-10-22 查）

- **OpenAPI MCP Server（我们用的 Core 版，api.aliyun.com/mcp）**：官方使用指南**没有计费章节**，
  它本身不产生费用；成本只来自**它替你调用的云 API**。
  - 查文档的 4 个工具（SearchDocuments / GetDocument / GetDocumentTree / GrepDocuments）= 纯检索，**不花钱**；
  - `CallCLI` / `RunScript` / `RunIaC` 若真的建资源（如 ECS），**按那个资源的正常价格计费**。
- 易混淆的两种（都不是我们用的）：
  - 百炼「云部署 MCP 服务」：限时免部署费，调用第三方 API 的费用由第三方收；
  - 百炼「联网搜索 MCP」：免费 2000 次，之后 29 元/千次；
  - PrivateLink 私网接入：按用量（终端节点小时费 + 数据处理费）。
