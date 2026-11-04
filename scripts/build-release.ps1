# 构建**上架用**的 release .app
#
# 为什么需要临时改 signingConfig：
#   DevEco 只把 release 签名写成 signingConfigs 里的一项，product 仍指向 debug 的 default；
#   直接给模块加 applyToProducts 会被 schema 拒绝（实测 00303038），所以这里「临时切换 + 构建 + 还原」。
#
# 用法：pwsh -File scripts\build-release.ps1
param(
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repo 'app'
$profile = Join-Path $app 'build-profile.json5'
$deveco = 'E:\Tools\DevEco Studio'
$hvigor = Join-Path $deveco 'tools\hvigor\bin\hvigorw.bat'

if (-not (Test-Path $profile)) { throw "找不到 $profile" }

$original = Get-Content $profile -Raw
$pattern = '"name": "default",\s*\r?\n\s*"signingConfig": "default"'
$replacement = '"name": "default",' + "`r`n        " + '"signingConfig": "release"'
$switched = $original -replace $pattern, $replacement
if ($switched -eq $original) {
    throw "没找到 product default 的 signingConfig 字段，请检查 build-profile.json5"
}

try {
    Set-Content -Path $profile -Value $switched -NoNewline
    Write-Host '→ 临时切换到 release 签名，开始构建…'

    $env:NODE_HOME = Join-Path $deveco 'tools\node'
    $env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk'
    $env:PATH = "$env:NODE_HOME;$env:PATH"

    Push-Location $app
    & $hvigor assembleApp --mode project -p product=default -p buildMode=release --no-daemon
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -ne 0) { throw "构建失败，退出码 $code" }
} finally {
    Set-Content -Path $profile -Value $original -NoNewline
    Write-Host '→ 已还原 build-profile.json5（debug 签名配置）'
}

$appFile = Join-Path $app 'build\outputs\default\app-default-signed.app'
if (-not (Test-Path $appFile)) { throw "没有找到签名产物 $appFile" }

if ($Out) {
    Copy-Item $appFile $Out -Force
    $appFile = $Out
}
$size = [math]::Round((Get-Item $appFile).Length / 1MB, 2)
Write-Host "✔ 上架包：$appFile（$size MB）"
Write-Host '  上传到 AGC → 版本管理 → 软件包'
