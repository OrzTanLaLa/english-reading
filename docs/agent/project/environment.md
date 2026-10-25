# 开发环境搭建

> 目标设备：MatePad，HarmonyOS 7.0.0
> 开发机：Windows，E 盘充裕（C 盘只剩 14 GB，一律不放 E 盘以外）

## 目录约定

| 用途 | 路径 | 说明 |
|---|---|---|
| IDE | `E:\Tools\DevEco Studio` | ✅ 已装，版本 26.0.0.851 |
| **HarmonyOS SDK** | `E:\Tools\DevEco Studio\sdk\default` | ✅ 随 IDE 安装，**6.66 GB，API 26**。不占 C 盘，无需外置 |
| 工程 | `app/`（仓库根下） | **路径必须无空格**，所以仓库要迁到 `E:\Project\english-reading` |
| 构建缓存 | `E:\Tools\cache` | `hvigor`、`ohpm` 缓存，装工程时再迁 |

**SDK 不需要再放到 `E:\Tools\HarmonyOS-SDK`。** DevEco 26 把 SDK 直接装在 IDE 目录下，首次启动向导没有路径选择项——这是正常的，不是漏了一步。E 盘 766 GB，没有外置的必要；强行搬出去反而会在 IDE 升级时出问题。

### HarmonyOS SDK 与 OpenHarmony SDK 的区别

目录结构自己说明了：

```
sdk/default/
  openharmony/   ← 开源基线：@ohos.* 系统能力（ets/js/native/toolchains）
  hms/           ← 华为闭源 Kit：Core Vision Kit、Core Speech Kit、Push、Account…
```

- **OpenHarmony SDK** = 只有 `openharmony/` 那部分，任何 OpenHarmony 设备都能用，不含华为服务。
- **HarmonyOS SDK** = `openharmony/` + `hms/`，华为商用发行版。

本项目要用 **Core Vision Kit 的文字识别**和 **Core Speech Kit**，它们都在 `hms/` 里——所以**必须用 HarmonyOS SDK**，纯 OpenHarmony SDK 没有这些能力。

> 因此 `E:\Tools\OpenHarmony-SDK` 这个名字是反的：里面装的是 HarmonyOS SDK。真要外置也请叫 `HarmonyOS-SDK`。

**不需要安装 OpenHarmony SDK。** 它是给 `runtimeOS: OpenHarmony` 的工程用的，默认也装 C 盘，白占 5–6 GB。本项目 `runtimeOS: HarmonyOS`，用 `sdk\default` 即可。IDE 若提示「OpenHarmony SDK 未安装」，忽略。

---

## 步骤 1：下载 DevEco Studio

<https://developer.huawei.com/consumer/cn/deveco-studio/>

需要登录华为账号。下载 Windows 版安装包（约 1.5–2 GB）。

> 选**最新稳定版**。设备是 HarmonyOS 7.0，旧版 IDE 可能不带对应的 SDK。

## 步骤 2：安装

运行安装包，**安装路径手动改成** `E:\Tools\DevEco Studio`。

安装向导里的「创建桌面快捷方式」「关联文件类型」按喜好勾选即可，不影响后续。

## 步骤 3：首次启动

启动后会走一个配置向导：

1. **接受协议**
2. **SDK 目录**：改成 `E:\Tools\HarmonyOS-SDK`（这一步最重要，别跳过）
3. **SDK 组件**：勾选与设备匹配的 API 版本 + `Toolchains`（`hdc` 在里面）

> 不确定勾哪个 API 就先只勾 Toolchains，装完我帮你查设备实际支持的版本再补。

## 步骤 4：交给我

装完告诉我，我接手做这几件事：

1. 确认 `hdc` 可用，连上平板（需在平板上开「开发者模式 + USB 调试」）
2. 用 `hdc shell param get const.product.api.version` 之类的命令查出设备真实 API 级别
3. 把 SDK、`hvigor`、`ohpm` 缓存路径都迁到 E 盘
4. 创建 ArkTS 工程骨架到仓库根下的 `app/`

---

## 验收标准

- `hdc list targets` 能看到平板
- `hdc shell` 能进设备
- 空工程能装到平板上并启动

---

## 已知的坑

| 现象 | 原因 | 处理 |
|---|---|---|
| C 盘突然满了 | SDK 默认装到 `AppData\Local\Huawei\Sdk` | 步骤 3 里必须改路径 |
| `hdc` 找不到 | 没勾 Toolchains，或 PATH 没配 | 我用绝对路径调用，不依赖 PATH |
| 平板连不上 | 没开开发者模式，或没点「允许调试」 | 设置 → 系统和更新 → 开发者选项 |
| 签名失败 | 华为账号未实名 | 实名后才可自动签名 |
| 下载很慢 | 华为 CDN 视地区而定 | 换时段重试，别用第三方镜像 |

## 为什么不用 winget

这台机器上没有 winget，且 DevEco 下载需要登录华为账号，无法脚本化。安装包只能手动下载。

## 签名（命令行能力边界）

**能做（全命令行）**：用现有 `.p12/.cer/.p7b` 签名并装机。

```powershell
# 方式 A：hvigorw 自动签名（build-profile.json5 里配了 signingConfigs 时）
pwsh -File scripts\build-app.ps1 -Install -Page pages/Library
# 产物里直接有 entry-default-signed.hap

# 方式 B：手动签未签名包（工具在 sdk/default/openharmony/toolchains/lib 下）
java -jar hap-sign-tool.jar sign-app -mode localSign ^
  -keystoreFile demo.p12 -keystorePwd <pwd> -keyAlias debugKey -keyPwd <pwd> ^
  -signAlg SHA256withECDSA -profileFile demo.p7b -appCertFile demo.cer ^
  -inFile entry-default-unsigned.hap -outFile entry-default-signed.hap
```

还可用命令行生成密钥库与证书请求：`hap-sign-tool generate-keypair`、`generate-csr`。

**不能做（必须一次性网页操作）**：**生成/更新 Profile（`.p7b`）**。

官方流程是「生成 CSR → 去 AppGallery Connect 申请调试证书与调试 Profile → 下载 `.cer`/`.p7b`」。
Profile 里才是真正的**权限清单**与设备清单，`module.json5` 只是声明。

当前项目的签名材料是 **DevEco 自动签名**生成的，路径在用户目录：

```
C:\Users\<user>\.ohos\config\default_app_<hash>.cer
C:\Users\<user>\.ohos\config\default_app_<hash>.p7b
```

`app/build-profile.json5` 的 `signingConfigs.material` 指向它们。

**结论**：`.p7b` 的重新签发**不能命令行完成**（必须 AGC 网页或 DevEco 自动签名）。
但要先说清楚：**普通 `user_grant` 权限（如 MICROPHONE）不写在 `.p7b` 里**——
实测现有 Profile 是 `permissions:{}`、`acls.allowed-acls:[]`，这对 user_grant 权限是正常的。
Profile 里的 `permissions`/`acls` 用于 **restricted / ACL 权限**。所以「加麦克风 → 重签名」这个因果不成立。

**可用命令行做的完整签名链**（自签，仅 OpenHarmony 设备会被信任）：
`generate-keypair` → `generate-ca` → `generate-app-cert` / `generate-profile-cert` → `sign-profile` → `sign-app`。
在华为 HarmonyOS 设备上，自签根不在设备信任列表，安装会被拒。

## 密钥与配置文件都在哪（别再翻仓库找）

| 东西 | 位置 | 说明 |
|---|---|---|
| 百炼 Key（TTS / OCR / Omni） | `app/entry/src/main/ets/adapters/local_secret.ts` 的 `LOCAL_DASHSCOPE_KEY` | **gitignored**；也支持应用内设置存入 Preferences |
| DeepSeek Key（主 Agent） | 同上文件 `LOCAL_DEEPSEEK_KEY`；原始来源 `validation/B0A/config.json` 的 `deepseek.api_key` | 两者都 gitignored |
| 其它模型 Key（cosyvoice/doubao/minimax/tencent） | `validation/B0A/config.json` | 仅离线验证用，App 不读 |
| 阿里云 AK（文档 MCP） | Windows 用户环境变量 `ALIBABA_CLOUD_ACCESS_KEY_ID/SECRET` | 被 `dsh-plugins/docs-mcp/cordis.patch.yml` 以 `!!js process.env.*` 引用 |
| 阿里云 MCP Endpoint | 同上 patch 的 `args` | Core 版 Streamable HTTP 端点 |
| 签名材料 | `C:\Users\<user>\.ohos\config\default_app_*.{cer,p7b}`；`app/build-profile.json5` 引用 | 见本文件「签名」一节 |

规则：**Key 不进仓库**（上述文件均已在 `.gitignore`），代码里只允许引用常量或 Preferences。
