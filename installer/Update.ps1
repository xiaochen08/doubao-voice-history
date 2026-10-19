param([switch]$Install)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$appDir = $PSScriptRoot
$configPath = Join-Path $appDir 'update.json'
$versionPath = Join-Path $appDir 'VERSION.json'
if (-not (Test-Path $configPath)) { throw 'update.json 不存在，尚未配置 GitHub 仓库。' }
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$repo = $config.repo
if ([string]::IsNullOrWhiteSpace($repo) -or $repo -match 'YOUR_GITHUB_USER') {
    throw 'update.json 里的 repo 还是占位符，请先发布仓库并写入 OWNER/REPO。'
}
$localVersion = (Get-Content $versionPath -Raw | ConvertFrom-Json).version
$headers = @{ 'User-Agent' = 'DoubaoVoiceHistory-Updater'; 'Accept' = 'application/vnd.github+json' }
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers
$tag = $release.tag_name -replace '^v',''
Write-Host "本地版本：$localVersion"
Write-Host "最新版本：$tag"
if ([version]$tag -le [version]$localVersion) { Write-Host '已是最新版本。' -ForegroundColor Green; exit 0 }
if (-not $Install) {
    Write-Host "发现新版本：$tag" -ForegroundColor Yellow
    Write-Host "下载地址：$($release.html_url)"
    [System.Windows.MessageBox]::Show("发现新版本 $tag`n`n$($release.body)", '豆包语音历史更新', 'OK', 'Information') | Out-Null
    exit 0
}

$asset = $release.assets | Where-Object { $_.name -like 'DoubaoVoiceHistory-Setup-*.zip' } | Select-Object -First 1
$sums = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
if (-not $asset) { throw 'Release 中没有找到 Setup ZIP。' }
$tmp = Join-Path $env:TEMP ("DoubaoVoiceHistory-update-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip = Join-Path $tmp $asset.name
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers @{ 'User-Agent' = 'DoubaoVoiceHistory-Updater' }
if ($sums) {
    $sumFile = Join-Path $tmp 'SHA256SUMS.txt'
    Invoke-WebRequest -Uri $sums.browser_download_url -OutFile $sumFile -Headers @{ 'User-Agent' = 'DoubaoVoiceHistory-Updater' }
    $expected = (Get-Content $sumFile | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1).Split(' ')[0]
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($expected -and $expected.ToUpper() -ne $actual.ToUpper()) { throw "SHA256 校验失败：$actual" }
}
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$installer = Join-Path $tmp 'Install.ps1'
if (-not (Test-Path $installer)) { throw '更新包中缺少 Install.ps1。' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Silent
Write-Host '更新完成。' -ForegroundColor Green
