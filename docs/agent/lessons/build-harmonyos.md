# 鸿蒙构建与装机（可迁移经验）

> 来自本项目（DevEco + hvigor），换项目同样适用。命令已封装为 `scripts/build-app.ps1`。

## 一条命令构建 + 装机

```powershell
pwsh -File scripts\build-app.ps1 -Install -Page pages/Reading
```

脚本内部做的事：

```powershell
$env:NODE_HOME = 'E:\Tools\DevEco Studio\tools\node'
$env:DEVECO_SDK_HOME = 'E:\Tools\DevEco Studio\sdk'
$env:PATH = "$env:NODE_HOME;$env:PATH"
& 'E:\Tools\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module `
    -p product=default -p buildMode=debug assembleHap
# 然后 hdc install -r <hap> → aa force-stop → aa start --ps page <页>
```

**为什么不用 `hvigorw.js` 直接跑**：PowerShell 会把 `.js` 交给 Windows Script Host，弹 JScript 错误框。
要么用 `.bat`，要么显式 `node.exe`。

## 权限：为什么必须完全访问

hvigor 会：

1. 写 `%USERPROFILE%\.hvigor\project_caches\<hash>\workspace`（工作区外）；
2. 在那里创建 **Junction** 指向 `E:\Tools\DevEco Studio\tools\hvigor\hvigor`。

受限沙箱下两者都失败。**没有配置项能绕开**（试过 `HVIGOR_USER_HOME`、重定向 `USERPROFILE`、预建链接）。

失败时的官方处置（错误码 00308003）：删掉 `project_caches\<hash>\workspace` 重试——但下次构建仍要重建。

## 增量 vs 全量

| 场景 | 耗时（本项目，HAP 11MB） |
|---|---|
| daemon 空转 | 3.3–3.5s |
| 改一个文件 | 15.2s |
| 全量 clean | 42s |
| 冷启动 no-daemon | ~30s |

**关键规则**：新增 `.ets`/`.ts` 文件后**必须全量**，否则白屏 `{"code":401}`。
官方原文：Hot Reload 不支持「启动应用后新增的代码文件」。

自动化：用「`ets/` 下全部源文件清单 + 路由文件哈希」做戳，变了就 clean。
**只监控 `pages/` 是不够的**——新增 `core/xxx.ts` 一样会白屏。

## 常用配置

`app/hvigor/hvigor-config.json5`：

```json5
{
  "execution": { "daemon": true, "incremental": true, "parallel": true,
                 "optimizationStrategy": "performance" },
  "logging": { "level": "error" }   // warn 会刷 300 行 ArkTS 告警
}
```

## HAR 依赖（本地 .har 包）

```json5
// app/entry/oh-package.json5
"dependencies": { "neonui": "file:libs/neonui.har" }
```

装依赖**必须跑一次** `ohpm install`，且 ohpm 需要 node 在 PATH：

```powershell
$env:PATH = 'E:\Tools\DevEco Studio\tools\node;' + $env:PATH
& 'E:\Tools\DevEco Studio\tools\ohpm\bin\ohpm.bat' install
```

否则 ArkTS 报 `Cannot find module 'neonui'`。

## 设备操作（hdc）

```powershell
$hdc = 'E:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
& $hdc shell snapshot_display -f /data/local/tmp/a.jpeg      # 截图
& $hdc file recv /data/local/tmp/a.jpeg .\a.jpeg              # 取回
& $hdc shell uitest dumpLayout -p /data/local/tmp/l.json      # 拿控件 bounds
& $hdc shell uitest uiInput click <x> <y>                     # 点击（坐标用 dump 里的）
& $hdc shell aa start -a EntryAbility -b <bundle> --ps page pages/X
```

**坐标坑**：`uitest click` 用 px；`dumpLayout` 的 bounds 也是 px；但控件的 `onClick` 给的是
**vp**——两者差一个密度（本项目 2.31）。

**点击不生效时**：先 `dumpLayout` 看目标真实 bounds，不要靠截图目测（按钮会因上方文字行数变化而位移）。

## 沙箱文件可以直接读（2026-10-22 更正旧说法）

应用沙箱在 **`/data/app/el2/100/base/<bundle>/haps/entry/files`**，用 `hdc shell` 的 `ls / cat / tail` **可读**：

```powershell
$base = '/data/app/el2/100/base/com.example.englishreading/haps/entry/files/course'
& $hdc shell "ls -lt $base"                      # 找最近改动的课
& $hdc shell "tail -c 900 $base/<id>/glossary.yaml"
```

验证「代码到底写进去什么」时，**直接读文件最快**，不要为了看一眼数据改代码加日志再重编。
（旧笔记里写的 `/data/storage/el2/base/...` 与「shell 读不到」都已过时。）

## 其它
- `getContext()` / `promptAction.showToast` / `router.pushUrl` 在 API 26 已被标记 deprecated，
  当前仍可用；要升级时统一替换为 `UIContext` 版本。
