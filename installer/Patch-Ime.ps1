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
$originalDir = Join-Path $installRoot 'versions\v0.9.2.7'

function Restart-Ime {
    Get-Process ImeWatchdog, ImeService -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
    Start-Process (Join-Path $installRoot 'bootstrap\ImeWatchdog.exe') -WindowStyle Hidden
}

function Test-Bytes([byte[]]$left, [byte[]]$right) {
    return (($left -join ',') -eq ($right -join ','))
}

function Patch-File([string]$path, [int]$offset, [byte[]]$expected, [byte[]]$replacement) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $current = $bytes[$offset..($offset + $expected.Length - 1)]
    if (Test-Bytes $current $replacement) {
        Write-Host "已打过补丁：$path"
        return
    }
    if (-not (Test-Bytes $current $expected)) {
        throw ("字节不匹配：{0} @0x{1:X}" -f $path, $offset)
    }
    for ($i = 0; $i -lt $replacement.Length; $i++) {
        $bytes[$offset + $i] = $replacement[$i]
    }
    [System.IO.File]::WriteAllBytes($path, $bytes)
    Write-Host "已打补丁：$path" -ForegroundColor Green
}

if ($Rollback) {
    if (Test-Path $backupFile) {
        $backup = Get-Content $backupFile -Raw | ConvertFrom-Json
        $rollbackDir = $backup.VersionDir
    } elseif (Test-Path $originalDir) {
        $rollbackDir = $originalDir
    } else {
        throw '找不到原始版本目录，无法回滚。'
    }
    if ((Split-Path $rollbackDir -Leaf) -match '-(mod|voicefix|keyguard)$' -and (Test-Path $originalDir)) {
        $rollbackDir = $originalDir
    }
    if (-not (Test-Path $rollbackDir) -and (Test-Path $originalDir)) {
        $rollbackDir = $originalDir
    }
    Set-ItemProperty 'HKLM:\SOFTWARE\DoubaoIme' -Name VersionDir -Value $rollbackDir
    Restart-Ime
    Write-Host "已回滚到：$rollbackDir" -ForegroundColor Green
    exit
}

if (-not $versionDir) { throw '未读取到豆包 VersionDir。' }
$leaf = Split-Path $versionDir -Leaf
$baseLeaf = $leaf -replace '-(mod|voicefix|keyguard)$',''
if ($baseLeaf -ne 'v0.9.2.7') {
    throw "当前版本 $leaf 不是 v0.9.2.7，补丁偏移不匹配，已中止。"
}

$parentDir = Split-Path $versionDir -Parent
$guardDir = Join-Path $parentDir 'v0.9.2.7-keyguard'
if (-not (Test-Path $originalDir)) { throw "找不到原版目录：$originalDir" }
if (-not (Test-Path $guardDir)) {
    Write-Host '复制版本目录（约 250 MB，首次较慢）...' -ForegroundColor Cyan
    Copy-Item -LiteralPath $originalDir -Destination $guardDir -Recurse -Force
}

$x64 = Join-Path $guardDir 'tsf-oime-core.dll'
$x86 = Join-Path $guardDir 'x86\tsf-oime-core.dll'
$origX64 = Join-Path $originalDir 'tsf-oime-core.dll'
$origX86 = Join-Path $originalDir 'x86\tsf-oime-core.dll'

$entry64Original = [byte[]](0x40,0x55,0x53,0x56,0x57)
$entry64Patched = [byte[]](0xE9,0xE7,0x60,0x14,0x00)
$entry86Original = [byte[]](0x55,0x8B,0xEC,0x6A,0xFF)
$entry86Patched = [byte[]](0xE9,0x1E,0xDD,0x0E,0x00)
$cave64Original = [byte[]](1..71 | ForEach-Object { 0x00 })
$cave64Patched = [byte[]](
    0x41,0x81,0xF8,0xA5,0x00,0x00,0x00,0x75,0x3B,
    0x40,0x55,0x53,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57,
    0x48,0x8D,0xAC,0x24,0x68,0xFF,0xFF,0xFF,
    0x48,0x81,0xEC,0x98,0x01,0x00,0x00,
    0x48,0xC7,0x44,0x24,0x48,0xFE,0xFF,0xFF,0xFF,
    0x48,0x8B,0x05,0x07,0x97,0x06,0x00,
    0x48,0x33,0xC4,
    0x48,0x89,0x85,0x80,0x00,0x00,0x00,
    0xE9,0x06,0x9F,0xEB,0xFF,
    0x31,0xC0,0xC3)
$cave86Original = [byte[]](1..23 | ForEach-Object { 0xCC })
$cave86Patched = [byte[]](
    0x81,0x7C,0x24,0x08,0xA5,0x00,0x00,0x00,0x74,0x03,0x31,0xC0,0xC3,
    0x55,0x8B,0xEC,0x6A,0xFF,0xE9,0xCB,0x22,0xF1,0xFF)

if ($cave64Patched.Length -ne 71 -or $cave86Patched.Length -ne 23) {
    throw '内部错误：补丁跳板长度不正确。'
}

Get-Process ImeWatchdog, ImeService -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1

try {
    $coreBytes = [System.IO.File]::ReadAllBytes($x64)
    $currentEntry = $coreBytes[0x2CDA0..0x2CDA4]
    if (-not (Test-Bytes $currentEntry $entry64Original) -and -not (Test-Bytes $currentEntry $entry64Patched)) {
        Write-Host '检测到旧版 keyguard 补丁，正在从原版重建核心 DLL...' -ForegroundColor Yellow
        Copy-Item -LiteralPath $origX64 -Destination $x64 -Force
        if (Test-Path $origX86) { Copy-Item -LiteralPath $origX86 -Destination $x86 -Force }
    }

    Patch-File $x64 0x2CDA0 $entry64Original $entry64Patched
    Patch-File $x64 0x172E8C $cave64Original $cave64Patched
    Patch-File $x64 0x1CCE7 ([byte[]](0x75,0x2C)) ([byte[]](0xEB,0x2C))

    if (Test-Path $x86) {
        Patch-File $x86 0x296A0 $entry86Original $entry86Patched
        Patch-File $x86 0x1173C3 $cave86Original $cave86Patched
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $backupFile -Parent) | Out-Null
    [pscustomobject]@{ VersionDir = $originalDir; SavedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $backupFile -Encoding UTF8
    Set-ItemProperty 'HKLM:\SOFTWARE\DoubaoIme' -Name VersionDir -Value $guardDir
}
finally {
    Restart-Ime
}

Write-Host "补丁完成：录音中仅右 Alt 启动键可结束，VersionDir -> $guardDir" -ForegroundColor Green
Write-Host '回滚：Patch-Ime.ps1 -Rollback'
