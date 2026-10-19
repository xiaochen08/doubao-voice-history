param(
    [switch]$RemoveData,
    [switch]$KeepApp
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$installRoot = Join-Path $env:LOCALAPPDATA 'DoubaoVoiceHistory'
$appDir = Join-Path $installRoot 'app'
$dataDir = Join-Path $env:APPDATA 'DoubaoVoiceHistory'
$taskName = 'DoubaoVoiceHistory'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'DoubaoVoiceHistory.lnk'
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '豆包语音历史.lnk'
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) '豆包语音历史'

Write-Host '停止程序...' -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'VoiceHistory\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host '移除自启...' -ForegroundColor Cyan
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startupLnk -Force -ErrorAction SilentlyContinue

Write-Host '移除快捷方式...' -ForegroundColor Cyan
Remove-Item -LiteralPath $desktopLnk -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuDir -Recurse -Force -ErrorAction SilentlyContinue

$resolved = [System.IO.Path]::GetFullPath($appDir)
$expectedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'DoubaoVoiceHistory'))
if (-not $KeepApp -and $resolved.StartsWith($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path $resolved)) {
    Write-Host "移除程序目录：$resolved" -ForegroundColor Cyan
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}

if ($RemoveData -and (Test-Path $dataDir)) {
    $resolvedData = [System.IO.Path]::GetFullPath($dataDir)
    $expectedDataRoot = [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA 'DoubaoVoiceHistory'))
    if ($resolvedData.StartsWith($expectedDataRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "移除数据目录：$resolvedData" -ForegroundColor Cyan
        Remove-Item -LiteralPath $resolvedData -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '卸载完成。' -ForegroundColor Green
if (-not $RemoveData) { Write-Host "历史数据保留在：$dataDir" }
Write-Host 'IME 补丁（如果应用过）请单独运行 Patch-Ime.ps1 -Rollback 回滚。'
