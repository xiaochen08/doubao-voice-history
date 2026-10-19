param(
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '需要管理员权限，正在提升...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath
    exit
}

$installRoot = 'C:\Program Files\DoubaoIME'
$versionDir = (Get-ItemProperty 'HKLM:\SOFTWARE\DoubaoIme' -ErrorAction SilentlyContinue).VersionDir
$backupFile = Join-Path $env:APPDATA 'DoubaoVoiceHistory\ime_versiondir_backup.json'

if ($Rollback) {
    if (-not (Test-Path $backupFile)) { throw "找不到备份文件：$backupFile" }
    $backup = Get-Content $backupFile -Raw | ConvertFrom-Json
    Set-ItemProperty 'HKLM:\SOFTWARE\DoubaoIme' -Name VersionDir -Value $backup.VersionDir
    Get-Process ImeWatchdog, ImeService -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
    Start-Process (Join-Path $installRoot 'bootstrap\ImeWatchdog.exe') -WindowStyle Hidden
    Write-Host "已回滚到：$($backup.VersionDir)" -ForegroundColor Green
    exit
}

if (-not $versionDir) { throw '未读取到豆包 VersionDir。' }
$leaf = Split-Path $versionDir -Leaf
$baseLeaf = $leaf -replace '-mod$',''
if ($baseLeaf -ne 'v0.9.2.7') {
    throw "当前版本 $leaf 不是 v0.9.2.7，补丁偏移不匹配，已中止。"
}

$parentDir = Split-Path $versionDir -Parent
$sourceDir = Join-Path $parentDir 'v0.9.2.7'
$modDir = Join-Path $parentDir 'v0.9.2.7-mod'
if (-not (Test-Path $sourceDir)) { throw "找不到原版目录：$sourceDir" }
if (-not (Test-Path $modDir)) {
    Write-Host '复制版本目录（约 250 MB，首次较慢）...' -ForegroundColor Cyan
    Copy-Item -LiteralPath $sourceDir -Destination $modDir -Recurse -Force
}

function Patch-File([string]$path, [int]$offset, [byte[]]$expected, [byte[]]$replacement) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $current = $bytes[$offset..($offset + $expected.Length - 1)]
    if (($current -join ',') -eq ($replacement -join ',')) { Write-Host "已打过补丁：$path"; return }
    if (($current -join ',') -ne ($expected -join ',')) {
        throw ("字节不匹配：{0} @0x{1:X}" -f $path, $offset)
    }
    for ($i = 0; $i -lt $replacement.Length; $i++) { $bytes[$offset + $i] = $replacement[$i] }
    [System.IO.File]::WriteAllBytes($path, $bytes)
    Write-Host "已打补丁：$path" -ForegroundColor Green
}

$x64 = Join-Path $modDir 'tsf-oime-core.dll'
$x86 = Join-Path $modDir 'x86\tsf-oime-core.dll'
Patch-File $x64 0x161FA ([byte[]](0x84,0xC0,0x74,0x69)) ([byte[]](0x83,0xFE,0x1B,0x75,0x17))
Patch-File $x64 0x1CCE7 ([byte[]](0x75,0x2C)) ([byte[]](0xEB,0x2C))
if (Test-Path $x86) {
    $nops = [byte[]](1..20 | ForEach-Object { 0x90 })
    Patch-File $x86 0x1481F ([byte[]](0xFF,0xB5,0x88,0xDE,0xFF,0xFF,0x8B,0xCE,0x57,0xFF,0xB5,0x80,0xDE,0xFF,0xFF,0xE8,0x6D,0x4E,0x01,0x00)) $nops
}

New-Item -ItemType Directory -Force -Path (Split-Path $backupFile -Parent) | Out-Null
[pscustomobject]@{ VersionDir = $versionDir; SavedAt = (Get-Date).ToString('o') } |
    ConvertTo-Json | Set-Content -LiteralPath $backupFile -Encoding UTF8
Set-ItemProperty 'HKLM:\SOFTWARE\DoubaoIme' -Name VersionDir -Value $modDir
Get-Process ImeWatchdog, ImeService -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
Start-Process (Join-Path $installRoot 'bootstrap\ImeWatchdog.exe') -WindowStyle Hidden

Write-Host "补丁完成，VersionDir -> $modDir" -ForegroundColor Green
Write-Host '回滚：Patch-Ime.ps1 -Rollback'
