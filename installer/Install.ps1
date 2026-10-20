param(
    [switch]$Silent,
    [switch]$ApplyImePatch
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:n = 1
function Step([string]$m) { Write-Host ("`n[{0}] {1}" -f $script:n, $m) -ForegroundColor Cyan; $script:n++ }
function Ok([string]$m) { Write-Host "    ✓ $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "    ! $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "    ✗ $m" -ForegroundColor Red }

$installRoot = Join-Path $env:LOCALAPPDATA 'DoubaoVoiceHistory'
$appDir = Join-Path $installRoot 'app'
$dataDir = Join-Path $env:APPDATA 'DoubaoVoiceHistory'
$historyFile = Join-Path $dataDir 'history.json'
$appScript = Join-Path $appDir 'VoiceHistory.ps1'
$doctorScript = Join-Path $appDir 'Doctor.ps1'
$taskName = 'DoubaoVoiceHistory'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'DoubaoVoiceHistory.lnk'
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '豆包语音历史.lnk'
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) '豆包语音历史'
$startMenuLnk = Join-Path $startMenuDir '豆包语音历史.lnk'
$sourceDir = $PSScriptRoot

Write-Host @'

  ╔══════════════════════════════════════════════╗
  ║        豆包语音历史 · 一键安装               ║
  ║        毛玻璃浮条 / 本地历史 / 点击复制      ║
  ╚══════════════════════════════════════════════╝

'@ -ForegroundColor Cyan

Step '检查系统环境'
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -match 'Windows 1[01]') { Ok $os.Caption } else { Warn "系统版本：$($os.Caption)（建议 Windows 10/11）" }
if ([Environment]::Is64BitOperatingSystem) { Ok '64 位系统' } else { Warn '32 位系统，部分功能可能受限' }
try { Add-Type -AssemblyName PresentationFramework; Ok 'WPF 可用' } catch { Fail 'WPF 不可用，安装中止'; exit 1 }
try { Add-Type -AssemblyName UIAutomationClient; Ok 'UI Automation 可用' } catch { Warn 'UI Automation 不可用，文本捕获会失败' }

Step '停止旧实例'
$old = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'VoiceHistory\.ps1' }
foreach ($p in $old) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
if ($old) { Ok ("已停止 {0} 个旧实例" -f @($old).Count) } else { Ok '没有旧实例在运行' }

Step '创建安装目录'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
Ok $appDir

Step '复制程序文件'
if ([System.IO.Path]::GetFullPath($sourceDir) -ne [System.IO.Path]::GetFullPath($appDir)) {
    Copy-Item -LiteralPath (Join-Path $sourceDir 'VoiceHistory.ps1') -Destination $appScript -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir 'Doctor.ps1') -Destination $doctorScript -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir 'Patch-Ime.ps1') -Destination (Join-Path $appDir 'Patch-Ime.ps1') -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $sourceDir 'Uninstall.ps1') -Destination (Join-Path $appDir 'Uninstall.ps1') -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $sourceDir 'VersionWatch.ps1') -Destination (Join-Path $appDir 'VersionWatch.ps1') -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $sourceDir 'Update.ps1') -Destination (Join-Path $appDir 'Update.ps1') -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $sourceDir 'update.json') -Destination (Join-Path $appDir 'update.json') -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $sourceDir 'VERSION.json') -Destination (Join-Path $appDir 'VERSION.json') -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $sourceDir 'voicehook.dll') -Destination (Join-Path $appDir 'voicehook.dll') -Force -ErrorAction SilentlyContinue
} else {
    Ok '程序文件已由安装包放置'
}
if (-not (Test-Path $appScript)) { Fail 'VoiceHistory.ps1 复制失败'; exit 1 }
Ok 'VoiceHistory.ps1 / Doctor.ps1'

Step '校验历史数据'
if (Test-Path $historyFile) {
    try {
        $raw = Get-Content $historyFile -Raw
        $null = $raw | ConvertFrom-Json
        Ok 'history.json 正常'
    } catch {
        $bad = Join-Path $dataDir ("history.corrupt-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $historyFile -Destination $bad -Force
        Set-Content -LiteralPath $historyFile -Value '[]' -Encoding UTF8
        Warn "历史文件损坏，已备份到 $bad 并重建"
    }
} else {
    Set-Content -LiteralPath $historyFile -Value '[]' -Encoding UTF8
    Ok '已创建空历史'
}

Step '配置登录自启与崩溃重启'
Remove-Item -LiteralPath $startupLnk -Force -ErrorAction SilentlyContinue
$taskOk = $false
try {
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$appScript`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    $taskOk = $true
    Ok '计划任务已创建（登录启动 + 失败重启 3 次）'
} catch {
    Warn "计划任务创建失败：$($_.Exception.Message)"
}
if (-not $taskOk) {
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($startupLnk)
    $sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $sc.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$appScript`""
    $sc.WorkingDirectory = $appDir
    $sc.Save()
    Ok '已回退到启动文件夹快捷方式'
}

try {
    $watchScript = Join-Path $appDir 'VersionWatch.ps1'
    $watchCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchScript`""
    & schtasks.exe /Create /SC MINUTE /MO 30 /TN "DoubaoVoiceHistory-VersionWatch" /TR $watchCmd /F | Out-Null
    Ok '版本监控任务已创建（每 30 分钟检查豆包版本）'
} catch {
    Warn "版本监控任务创建失败：$($_.Exception.Message)"
}

$settingsFile = Join-Path $dataDir 'settings.json'
if (-not (Test-Path $settingsFile)) {
    @{ autoUpdate = $true } | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
}
try {
    $updateScript = Join-Path $appDir 'Update.ps1'
    $updateCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$updateScript`" -Auto"
    & schtasks.exe /Create /SC HOURLY /MO 6 /TN "DoubaoVoiceHistory-AutoUpdate" /TR $updateCmd /F | Out-Null
    Ok '自动更新任务已创建（每 6 小时检查 GitHub Release）'
} catch {
    Warn "自动更新任务创建失败：$($_.Exception.Message)"
}

Step '创建桌面与开始菜单快捷方式'
$shell = New-Object -ComObject WScript.Shell
foreach ($lnk in @($desktopLnk, $startMenuLnk)) {
    $parent = Split-Path $lnk -Parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $sc.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$appScript`""
    $sc.WorkingDirectory = $appDir
    $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
    $sc.Save()
}
Ok '桌面 / 开始菜单'

Step '启动程序'
Start-Process powershell.exe -ArgumentList '-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$appScript -WindowStyle Hidden
Start-Sleep -Seconds 3
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match [regex]::Escape($appScript) }
if ($running) { Ok ("程序已启动，PID {0}" -f @($running)[0].ProcessId) } else { Fail '程序未启动，请查看 Doctor 诊断报告'; }

Step '检查豆包输入法'
$tip = 'HKLM:\SOFTWARE\Microsoft\CTF\TIP\{9D2B2E2B-3C93-4D2F-9D35-6EEB85F0D2B0}'
$imeVersionDir = (Get-ItemProperty 'HKLM:\SOFTWARE\DoubaoIme' -ErrorAction SilentlyContinue).VersionDir
if (Test-Path $tip) { Ok '豆包输入法已注册' } else { Warn '未检测到豆包输入法 TSF 注册' }
if ($imeVersionDir) {
    $imeVersion = Split-Path $imeVersionDir -Leaf
    Ok "当前版本目录：$imeVersion"
} else { Warn '未读取到 VersionDir' }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class InstallerNative {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
}
"@
if ([InstallerNative]::FindWindow('OimeVoiceWaveWindow', $null) -ne [IntPtr]::Zero) {
    Ok '语音条窗口类可用'
} else {
    Warn '未找到 OimeVoiceWaveWindow，尝试拉起 ImeWatchdog'
    $watchdog = 'C:\Program Files\DoubaoIME\bootstrap\ImeWatchdog.exe'
    if (Test-Path $watchdog) { Start-Process $watchdog -WindowStyle Hidden; Start-Sleep 2 }
}

Step '检查字体与截图能力'
try {
    Add-Type -AssemblyName System.Drawing
    $fonts = (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
    if ($fonts -contains 'Noto Serif SC') { Ok 'Noto Serif SC 已安装' } else { Warn '未安装 Noto Serif SC，界面会回退到系统中文字体' }
    $bmp = New-Object System.Drawing.Bitmap 8,8
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0,0,0,0,$bmp.Size)
    $g.Dispose(); $bmp.Dispose()
    Ok '屏幕抓取可用（毛玻璃背景）'
} catch { Warn "屏幕抓取不可用：$($_.Exception.Message)" }

Step '可选：录音中仅启动键（右 Alt）打断语音'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$currentImeLeaf = if ($imeVersionDir) { Split-Path $imeVersionDir -Leaf } else { '' }
$imeLeaf = $currentImeLeaf -replace '-(mod|voicefix|keyguard)$',''
$alreadyPatched = $currentImeLeaf -match '-keyguard$'
$wasPatched = $currentImeLeaf -match '-(mod|voicefix)$'
$canPatch = $imeLeaf -eq 'v0.9.2.7'
if ($alreadyPatched) {
    Ok '仅启动键（右 Alt）打断语音补丁已生效，跳过'
} elseif (-not $canPatch) {
    Warn "当前豆包版本 $imeLeaf 不支持自动补丁，跳过（历史浮条不受影响）"
} elseif (-not $ApplyImePatch -and $Silent -and -not $wasPatched) {
    Warn '静默安装未指定 -ApplyImePatch，跳过'
} else {
    $answer = if ($ApplyImePatch -or ($Silent -and $wasPatched)) { 'Y' } else { Read-Host '是否启用“录音中仅启动键打断”？需要管理员权限 (Y/N)' }
    if ($answer -match '^[Yy]') {
        $patchScript = Join-Path $appDir 'Patch-Ime.ps1'
        if (Test-Path $patchScript) {
            if ($isAdmin) {
                & $patchScript
            } else {
                Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$patchScript
            }
        } else { Warn 'Patch-Ime.ps1 不存在，跳过' }
    } else { Ok '跳过 IME 补丁' }
}

Write-Host "`n安装完成。" -ForegroundColor Green
Write-Host "  程序目录：$appDir"
Write-Host "  数据目录：$dataDir"
Write-Host "  诊断修复：$doctorScript -Fix"
Write-Host "  卸载：$appDir\Uninstall.ps1"
if (-not $Silent) { Write-Host "`n按 Enter 退出..." -ForegroundColor DarkGray; Read-Host | Out-Null }
