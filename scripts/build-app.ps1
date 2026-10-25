# 编译（+ 可选装机）鸿蒙工程，调用 DevEco 自带 node / hvigor。
#
# 用法：
#   pwsh -File scripts\build-app.ps1                  # debug 包（默认走热重载构建 + daemon）
#   pwsh -File scripts\build-app.ps1 -Install         # 编译 + 装到平板 + 启动指定页
#   pwsh -File scripts\build-app.ps1 -Install -Page pages/DictProbe
#   pwsh -File scripts\build-app.ps1 -Release         # release 包
#   pwsh -File scripts\build-app.ps1 -Clean           # 先 clean（会退化成全量）
#   pwsh -File scripts\build-app.ps1 -Cold            # 不用 daemon、不用热重载构建
#
# 速度参考（本机实测）：
#   冷启动 no-daemon        ~30s
#   daemon + 热重载构建      ~14s（其中签名固定 5.5s）
#   daemon 空转（无改动）    ~3s
#
# ── 为什么必须在「完全访问权限」下运行（2026-10-21 查清）────────────────────
# hvigor 会把自身插件包硬链接/软链到用户目录的工程缓存里：
#   %USERPROFILE%\.hvigor\project_caches\<hash>\workspace\node_modules\@ohos\hvigor
#   → 指向  E:\Tools\DevEco Studio\tools\hvigor\hvigor（Junction）
# 受限沙箱下有两处必然失败：
#   1) 写 %USERPROFILE%\.hvigor（在工作区之外）；
#   2) 创建 Junction。
# 官方错误码文档 00308003 的处置是「删掉 project_caches\<hash>\workspace 重试」，
# 但下次构建仍要重建链接，所以这是结构性的，配置绕不过去。
# 试过的无效办法：HVIGOR_USER_HOME / 重定向 USERPROFILE / 重定向 npm cache
#   —— 前两者 hvigor 不认，重定向 USERPROFILE 后 npm 仍写死 AppData 缓存。
#
# ── 增量构建的坑（官方文档核实）───────────────────────────────────────────
# 「Hot Reload 不支持启动应用后新增的代码文件」(harmonyos-guides/ide-hot-reload)。
# 所以新增 .ets 文件后必须全量，否则装到设备上启动报
#   Failed to load the content {"code":401}
# 本脚本用「.ets 文件清单 + 路由文件哈希」做戳，变了就自动全量。

param(
    [switch]$Release,
    [switch]$Clean,
    [switch]$Cold,
    [switch]$Install,
    [string]$Page = ''
)

$ErrorActionPreference = 'Stop'

$deveco = 'E:\Tools\DevEco Studio'
$repo = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repo 'app'
$hdc = Join-Path $deveco 'sdk\default\openharmony\toolchains\hdc.exe'
$bundle = 'com.example.englishreading'

if (-not (Test-Path (Join-Path $app 'build-profile.json5'))) {
    throw "找不到工程：$app"
}

$env:NODE_HOME = Join-Path $deveco 'tools\node'
$env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk'
$env:PATH = "$env:NODE_HOME;$env:PATH"

$hvigorw = Join-Path $deveco 'tools\hvigor\bin\hvigorw.bat'
if (-not (Test-Path $hvigorw)) {
    throw "找不到 hvigorw：$hvigorw"
}

$buildMode = if ($Release) { 'release' } else { 'debug' }

# 自动判定是否需要全量：新增/删除 .ets 文件、或路由清单变化时必须全量。
$etsDir = Join-Path $app 'entry\src\main\ets'
$pagesJson = Join-Path $app 'entry\src\main\resources\base\profile\main_pages.json'
$stampFile = Join-Path $repo '.hvigor\files.stamp'
$currentStamp = ''
if (Test-Path $etsDir) {
    $base = (Resolve-Path $etsDir).Path
    $items = Get-ChildItem $etsDir -Recurse -Include *.ets,*.ts |
        ForEach-Object { $_.FullName.Substring($base.Length) } | Sort-Object
    $currentStamp = ($items -join '|')
    if (Test-Path $pagesJson) {
        $currentStamp += '#' + (Get-FileHash $pagesJson -Algorithm SHA1).Hash
    }
}
$lastStamp = if (Test-Path $stampFile) { (Get-Content $stampFile -Raw).Trim() } else { '' }

if (-not $Clean -and $currentStamp -ne '' -and $currentStamp -ne $lastStamp) {
    if ($lastStamp -ne '') {
        Write-Host '源文件清单有变化（新增/删除）→ 自动改为全量构建'
    }
    $Clean = $true
}
if ($currentStamp -ne '') {
    New-Item -ItemType Directory -Force (Split-Path $stampFile) | Out-Null
    Set-Content $stampFile $currentStamp -NoNewline
}

$hvigorArgs = @('--mode', 'module', '-p', 'product=default', '-p', "buildMode=$buildMode")
if ($Cold) {
    $hvigorArgs += '--no-daemon'
} elseif (-not $Clean) {
    # 热重载构建：只编译改动部分，实测比全量快一倍
    $hvigorArgs += '--hot-reload-build'
}

Push-Location $app
try {
    if ($Clean) {
        & $hvigorw @hvigorArgs clean
        if ($LASTEXITCODE -ne 0) { throw "clean 失败（exit $LASTEXITCODE）" }
    }
    $buildLog = & $hvigorw @hvigorArgs assembleHap 2>&1
    $buildLog | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        $joined = ($buildLog | Out-String)
        if ($joined -match 'project_caches' -and $joined -match 'ENOENT|EPERM') {
            Write-Host ''
            Write-Host '构建失败：当前命令缺少完全访问权限（hvigor 要写用户目录缓存并建 Junction）。' -ForegroundColor Yellow
            Write-Host '处理：删掉 %USERPROFILE%\.hvigor\project_caches\<hash>\workspace 后用完全权限重跑。' -ForegroundColor Yellow
        }
        throw "assembleHap 失败（exit $LASTEXITCODE）"
    }
}
finally {
    Pop-Location
}

$hap = Join-Path $app 'entry\build\default\outputs\default\entry-default-signed.hap'
if (-not (Test-Path $hap)) {
    $hap = Join-Path $app 'entry\build\default\outputs\default\entry-default-unsigned.hap'
}
"HAP: $hap  ($([math]::Round((Get-Item $hap).Length / 1KB, 1)) KB)"

if ($Install) {
    if (-not (Test-Path $hdc)) { throw "找不到 hdc：$hdc" }
    & $hdc install -r $hap | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "安装失败" }
    & $hdc shell aa force-stop $bundle | Out-Null
    if ($Page) {
        & $hdc shell aa start -a EntryAbility -b $bundle --ps page $Page | Out-Null
    } else {
        & $hdc shell aa start -a EntryAbility -b $bundle | Out-Null
    }
    "已启动 $bundle$(if ($Page) { " → $Page" })"
}
