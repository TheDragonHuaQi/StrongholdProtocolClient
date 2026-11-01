# 换签名钥匙时的「保存档」切换脚本（Windows / PowerShell 5.1+）
#
# 背景：上游官方发布的 APK 用原作者那把 key（80f08c97…）签名，本 fork 从 0.3.3 起改用自己这把
#       （8152e091…），所以新包装不上装过官方包的手机。要保住存档，就不能直接卸载重装。
#
# 原理：项目发布的 APK 是 *debug* 构建（android:debuggable=true），所以不用 root，
#       用 `adb shell run-as <包名>` 就能把应用私有目录整个打包出来，装完新包再放回去。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\switch-signing-key.ps1            # 只检查环境 + 打印计划（不动手机）
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\switch-signing-key.ps1 -Execute    # 真的执行：备份 → 卸载 → 安装 → 还原
#
# 注意：手机要开「USB 调试」并已授权本机；执行前请确认上面打印的计划。

[CmdletBinding()]
param(
  [string]$Apk = '',
  [string]$Package = 'site.starst.stronghold',
  [string]$BackupDir = '',
  [switch]$Execute,
  [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $BackupDir) { $BackupDir = Join-Path $repoRoot 'out' }
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

function Fail($msg) { Write-Host "错误: $msg" -ForegroundColor Red; exit 1 }

# --- 1. 找 adb ---
$adb = @(
  'E:\spbuild\sdk\platform-tools\adb.exe',
  "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
  "$env:ANDROID_HOME\platform-tools\adb.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $adb) {
  $cmd = Get-Command adb -ErrorAction SilentlyContinue
  if ($cmd) { $adb = $cmd.Source }
}
if (-not $adb) { Fail '找不到 adb.exe（装 Android platform-tools，或用 -Apk 所在的 SDK 里的 platform-tools）' }
Write-Host "adb: $adb"

# --- 2. 设备 ---
$devices = & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' }
if (-not $devices) { Fail '没有已授权的设备。插上 USB、开「USB 调试」，并在手机上点「允许」。' }
if ($devices.Count -gt 1) { Fail "连着多台设备，先只留一台：" + ($devices -join '; ') }
Write-Host "设备: $($devices -join '')"

if (-not $Apk) {
  $Apk = Join-Path (Split-Path $PSScriptRoot -Parent) 'mobile\android\app\build\outputs\apk\debug\app-debug.apk'
}
if (-not (Test-Path $Apk)) {
  Fail "APK 不存在: $Apk —— 先打包（node tools/package-android.mjs）或用 -Apk <路径> 指定一个。"
}
Write-Host ("APK: {0}  ({1:N1} MB)" -f $Apk, ((Get-Item $Apk).Length / 1MB))

# --- 3. 现在装的是什么 ---
$dump = & $adb shell dumpsys package $Package 2>&1
$installed = $dump -match 'versionName='
if ($installed) {
  $vn = ($dump | Select-String -Pattern 'versionName=(\S+)' | Select-Object -First 1).Matches.Groups[1].Value
  $first = ($dump | Select-String -Pattern 'firstInstallTime=(.+)' | Select-Object -First 1).Matches.Groups[1].Value
  $last = ($dump | Select-String -Pattern 'lastUpdateTime=(.+)' | Select-Object -First 1).Matches.Groups[1].Value
  Write-Host "已安装: $Package  versionName=$vn"
  Write-Host "  首次安装 $first / 最后更新 $last"
} else {
  Write-Host "已安装: 无（这台手机没装过 $Package，那就不存在签名冲突，直接安装即可）"
  if ($Execute) {
    & $adb install -r $Apk
    exit $LASTEXITCODE
  }
  Write-Host ''
  Write-Host '计划: 直接安装（无旧版，无存档可丢）'
  exit 0
}

# --- 4. 能不能保数据（debug 构建才有的 run-as） ---
$debuggable = $dump -match 'flags=\[[^\]]*DEBUGGABLE'
$runAsOk = $false
if ($debuggable) {
  $probe = & $adb shell run-as $Package ls 2>&1
  $runAsOk = -not ($probe -match 'not debuggable|unknown package|Permission denied')
}
Write-Host "debuggable=$debuggable  run-as 可用=$runAsOk"

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tar = Join-Path $BackupDir "save-$Package-$stamp.tar"

Write-Host ''
Write-Host '计划:'
if ($runAsOk -and -not $SkipBackup) {
  Write-Host "  1) adb shell run-as $Package tar cf - /data/data/$Package  →  $tar"
  Write-Host "  2) adb uninstall $Package"
  Write-Host "  3) adb install $Apk"
  Write-Host "  4) 把备份写回应用私有目录（存档、设置都回来）"
} elseif ($debuggable -eq $false) {
  Write-Host '  这条 APK 不是 debug 构建，run-as 用不了 → 存档无法备份。' -ForegroundColor Yellow
  Write-Host '  建议：先在游戏里找有没有「导出存档 / 备份」入口，或者接受丢档。' -ForegroundColor Yellow
  Write-Host "  然后: adb uninstall $Package ; adb install $Apk"
  if (-not $Execute) { exit 0 }
} else {
  Write-Host '  跳过备份（-SkipBackup）→ 直接卸载重装，存档会丢。' -ForegroundColor Yellow
}

if (-not $Execute) {
  Write-Host ''
  Write-Host '这只是计划。确认无误后加 -Execute 再跑一次：' -ForegroundColor Cyan
  Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\switch-signing-key.ps1 -Execute -Apk '$Apk'"
  exit 0
}

# --- 5. 执行 ---
if ($runAsOk -and -not $SkipBackup) {
  Write-Host '[1/4] 备份应用数据…'
  $remote = "/data/local/tmp/sp-save-$stamp.tar"
  & $adb shell "run-as $Package tar cf - -C /data/data/$Package . > $remote"
  if ($LASTEXITCODE -ne 0) { Fail '备份失败（run-as tar），已中止，什么都没卸载' }
  & $adb pull $remote $tar
  if (-not (Test-Path $tar)) { Fail "备份没落到本机: $tar" }
  $sz = (Get-Item $tar).Length
  Write-Host ("      备份 {0} 字节 → {1}" -f $sz, $tar)
  if ($sz -lt 1024) { Fail '备份文件太小，可能没抓到东西；已中止' }
  & $adb shell rm -f $remote | Out-Null
}

Write-Host '[2/4] 卸载旧版…'
& $adb uninstall $Package
if ($LASTEXITCODE -ne 0) { Fail '卸载失败，已中止' }

Write-Host '[3/4] 安装新包…'
& $adb install $Apk
if ($LASTEXITCODE -ne 0) { Fail "安装失败（上面有原因）。存档备份在 $tar —— 装回旧版后可以还原" }

if ($runAsOk -and -not $SkipBackup -and (Test-Path $tar)) {
  Write-Host '[4/4] 还原存档…'
  $remote2 = "/data/local/tmp/sp-restore-$stamp.tar"
  & $adb push $tar $remote2
  & $adb shell "run-as $Package tar xf $remote2 -C /data/data/$Package"
  & $adb shell rm -f $remote2 | Out-Null
  Write-Host '完成。打开游戏看存档是否还在；不在的话手上有 tar，可以再来一次。'
} else {
  Write-Host '完成（未还原数据）。'
}
