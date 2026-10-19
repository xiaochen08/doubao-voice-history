$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$dataDir = Join-Path $env:APPDATA 'DoubaoVoiceHistory'
$baselineFile = Join-Path $dataDir 'ime_version.json'
$logFile = Join-Path $dataDir 'version-watch.log'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

function Write-WatchLog([string]$m) {
    Add-Content -LiteralPath $logFile -Value ('{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8
}

$versionDir = (Get-ItemProperty 'HKLM:\SOFTWARE\DoubaoIme' -ErrorAction SilentlyContinue).VersionDir
if (-not $versionDir) { Write-WatchLog 'VersionDir 不存在'; exit }
$leaf = Split-Path $versionDir -Leaf
$baseline = $null
if (Test-Path $baselineFile) {
    try { $baseline = (Get-Content $baselineFile -Raw | ConvertFrom-Json).Version } catch { }
}

if ($baseline -ne $leaf) {
    $message = if ($baseline) { "豆包输入法已更新：$baseline -> $leaf`n请运行 Doctor.ps1 -Fix 体检。" } else { "已记录豆包版本：$leaf" }
    Write-WatchLog $message
    [pscustomobject]@{ Version = $leaf; VersionDir = $versionDir; CheckedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $baselineFile -Encoding UTF8
    if ($baseline) {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        $icon.Visible = $true
        $icon.ShowBalloonTip(8000, '豆包输入法已更新', $message, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 4
        $icon.Visible = $false
        $icon.Dispose()
    }
} else {
    Write-WatchLog "版本未变化：$leaf"
}
