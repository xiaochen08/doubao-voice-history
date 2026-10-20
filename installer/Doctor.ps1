param(
    [switch]$Fix,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$appDir = Join-Path $env:LOCALAPPDATA 'DoubaoVoiceHistory\app'
$dataDir = Join-Path $env:APPDATA 'DoubaoVoiceHistory'
$appScript = Join-Path $appDir 'VoiceHistory.ps1'
$historyFile = Join-Path $dataDir 'history.json'
$logFile = Join-Path $dataDir 'app.log'
$taskName = 'DoubaoVoiceHistory'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'DoubaoVoiceHistory.lnk'
$report = Join-Path ([Environment]::GetFolderPath('Desktop')) ("豆包语音历史-诊断-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$lines = New-Object System.Collections.Generic.List[string]

function Add-Line([string]$text) { $lines.Add($text); Write-Host $text }
function Head([string]$text) { Add-Line ''; Add-Line "=== $text ===" }
function Pass([string]$text) { Add-Line "  [OK]   $text" }
function Warn([string]$text) { Add-Line "  [WARN] $text" }
function Fail([string]$text) { Add-Line "  [FAIL] $text" }

Add-Line ("豆包语音历史诊断报告  {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Add-Line ("Fix 模式：{0}" -f $Fix.IsPresent)

Head '安装文件'
foreach ($f in @($appScript, (Join-Path $appDir 'Doctor.ps1'))) {
    if (Test-Path $f) { Pass $f } else { Fail "缺少文件：$f" }
}

Head '运行状态'
$proc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match [regex]::Escape($appScript) }
if ($proc) {
    Pass ("进程运行中，PID {0}" -f @($proc)[0].ProcessId)
} else {
    Fail '程序未运行'
    if ($Fix -and (Test-Path $appScript)) {
        Start-Process powershell.exe -ArgumentList '-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$appScript -WindowStyle Hidden
        Start-Sleep 3
        $proc2 = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match [regex]::Escape($appScript) }
        if ($proc2) { Pass '已自动启动' } else { Fail '自动启动失败' }
    }
}

Head '自启配置'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Pass ("计划任务存在，状态：{0}" -f $task.State)
} else {
    Warn '计划任务不存在'
    if ($Fix) {
        try {
            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -Argument "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$appScript`""
            $trigger = New-ScheduledTaskTrigger -AtLogOn
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            Pass '已重建计划任务'
        } catch {
            $shell = New-Object -ComObject WScript.Shell
            $sc = $shell.CreateShortcut($startupLnk)
            $sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $sc.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$appScript`""
            $sc.WorkingDirectory = $appDir
            $sc.Save()
            Warn '计划任务失败，已回退启动文件夹'
        }
    }
}
if ((Test-Path $startupLnk) -and $task) { Warn '旧的启动文件夹快捷方式仍存在（可选清理）' }

Head '历史数据'
if (Test-Path $historyFile) {
    try {
        $json = Get-Content $historyFile -Raw | ConvertFrom-Json
        $count = @($json).Count
        Pass "history.json 可解析，记录数：$count"
    } catch {
        Fail "history.json 损坏：$($_.Exception.Message)"
        if ($Fix) {
            $bad = Join-Path $dataDir ("history.corrupt-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $historyFile -Destination $bad -Force
            Set-Content -LiteralPath $historyFile -Value '[]' -Encoding UTF8
            Pass "已备份到 $bad 并重建"
        }
    }
} else {
    Warn 'history.json 不存在'
    if ($Fix) { Set-Content -LiteralPath $historyFile -Value '[]' -Encoding UTF8; Pass '已创建空历史' }
}

Head '日志'
if (Test-Path $logFile) {
    $size = (Get-Item $logFile).Length
    Pass ("app.log 大小 {0:N1} KB" -f ($size / 1KB))
    $errors = Select-String -LiteralPath $logFile -Pattern 'failed|Exception|错误' -ErrorAction SilentlyContinue | Select-Object -Last 8
    if ($errors) {
        Warn '最近错误：'
        foreach ($e in $errors) { Add-Line ("         " + $e.Line) }
    } else { Pass '未发现明显错误行' }
    if ($Fix -and $size -gt 2MB) {
        $old = Join-Path $dataDir ("app.{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $logFile -Destination $old -Force
        Pass "日志已轮转到 $old"
    }
} else { Warn 'app.log 不存在' }

Head '自动更新'
$autoTask = Get-ScheduledTask -TaskName 'DoubaoVoiceHistory-AutoUpdate' -ErrorAction SilentlyContinue
if ($autoTask) {
    Pass ("自动更新任务存在，状态：{0}" -f $autoTask.State)
} else {
    Warn '自动更新任务不存在'
    if ($Fix) {
        $updater = Join-Path $appDir 'Update.ps1'
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$updater`" -Auto"
        & schtasks.exe /Create /SC HOURLY /MO 6 /TN "DoubaoVoiceHistory-AutoUpdate" /TR $cmd /F | Out-Null
        Pass '已重建自动更新任务'
    }
}
$updateLog = Join-Path $dataDir 'update.log'
if (Test-Path $updateLog) {
    $recent = Select-String -LiteralPath $updateLog -Pattern 'ERROR' -ErrorAction SilentlyContinue | Select-Object -Last 3
    if ($recent) { Warn '最近更新错误：'; foreach ($r in $recent) { Add-Line ("         " + $r.Line) } }
    else { Pass 'update.log 无 ERROR' }
} else { Warn 'update.log 不存在（尚未执行过更新）' }

Head '豆包输入法'
$tip = 'HKLM:\SOFTWARE\Microsoft\CTF\TIP\{9D2B2E2B-3C93-4D2F-9D35-6EEB85F0D2B0}'
if (Test-Path $tip) { Pass 'TSF 注册存在' } else { Fail '未检测到豆包 TSF 注册' }
$imeVersionDir = (Get-ItemProperty 'HKLM:\SOFTWARE\DoubaoIme' -ErrorAction SilentlyContinue).VersionDir
if ($imeVersionDir) { Pass "VersionDir：$imeVersionDir" } else { Fail '未读取到 VersionDir' }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DoctorNative {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
}
"@
if ([DoctorNative]::FindWindow('OimeVoiceWaveWindow', $null) -ne [IntPtr]::Zero) {
    Pass '语音条窗口类 OimeVoiceWaveWindow 可用'
} else {
    Warn '未找到语音条窗口'
    if ($Fix) {
        $watchdog = 'C:\Program Files\DoubaoIME\bootstrap\ImeWatchdog.exe'
        if (Test-Path $watchdog) { Start-Process $watchdog -WindowStyle Hidden; Start-Sleep 2; Pass '已尝试拉起 ImeWatchdog' }
    }
}

Head '能力检查'
try { Add-Type -AssemblyName UIAutomationClient; $f = [System.Windows.Automation.AutomationElement]::FocusedElement; Pass 'UI Automation 可用' }
catch { Fail "UI Automation 不可用：$($_.Exception.Message)" }
try {
    Add-Type -AssemblyName System.Drawing
    $fonts = (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
    if ($fonts -contains 'Noto Serif SC') { Pass 'Noto Serif SC 已安装' } else { Warn 'Noto Serif SC 未安装（会回退字体）' }
    $bmp = New-Object System.Drawing.Bitmap 8,8
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0,0,0,0,$bmp.Size)
    $g.Dispose(); $bmp.Dispose()
    Pass '屏幕抓取可用'
} catch { Warn "屏幕抓取不可用：$($_.Exception.Message)" }

Head 'IME 补丁状态'
if ($imeVersionDir -and (Split-Path $imeVersionDir -Leaf) -match 'keyguard$') {
    $core = Join-Path $imeVersionDir 'tsf-oime-core.dll'
    if (Test-Path $core) {
        $b = [System.IO.File]::ReadAllBytes($core)
        $patched = ($b[0x2CDA0] -eq 0xE9 -and $b[0x2CDA1] -eq 0xE7 -and $b[0x2CDA2] -eq 0x60 -and
            $b[0x172E8C] -eq 0x41 -and $b[0x172E8D] -eq 0x81 -and $b[0x172E8E] -eq 0xF8 -and $b[0x172E8F] -eq 0xA5)
        if ($patched) { Pass '仅启动键（右 Alt）打断语音补丁已生效' } else { Warn 'keyguard 目录存在但字节未匹配补丁' }
    }
} else {
    Warn '未启用“仅启动键打断语音”补丁（历史浮条不受影响）'
}

Add-Line ''
Add-Line '报告结束。'
$lines | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "`n报告已保存：$report" -ForegroundColor Cyan
if (-not $NoOpen) { Start-Process notepad.exe -ArgumentList $report }
