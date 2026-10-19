param(
    [switch]$Install,
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
Add-Type -AssemblyName PresentationFramework

$appDir = $PSScriptRoot
$configPath = Join-Path $appDir 'update.json'
$versionPath = Join-Path $appDir 'VERSION.json'
$dataDir = Join-Path $env:APPDATA 'DoubaoVoiceHistory'
$logFile = Join-Path $dataDir 'update.log'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

function ULog([string]$m) {
    Add-Content -LiteralPath $logFile -Value ('{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8
}

$mutex = New-Object System.Threading.Mutex($false, 'Global\DoubaoVoiceHistoryUpdate')
if (-not $mutex.WaitOne(0)) {
    ULog '另一个更新进程正在运行，跳过'
    exit 0
}

try {
    if (-not (Test-Path $configPath)) { throw 'update.json 不存在，尚未配置 GitHub 仓库。' }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $repo = $config.repo
    if ([string]::IsNullOrWhiteSpace($repo) -or $repo -match 'YOUR_GITHUB_USER') {
        throw 'update.json 里的 repo 还是占位符。'
    }
    $localVersion = (Get-Content $versionPath -Raw | ConvertFrom-Json).version
    $headers = @{ 'User-Agent' = 'DoubaoVoiceHistory-Updater'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers
    $tag = ($release.tag_name -replace '^v','') -replace '-.*$',''
    if ([version]$tag -le [version]$localVersion) {
        ULog "已是最新版本 $localVersion"
        if (-not $Auto) { Write-Host "已是最新版本：$localVersion" -ForegroundColor Green }
        exit 0
    }
    ULog "发现新版本 $localVersion -> $tag"
    if (-not ($Install -or $Auto)) {
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
    if ($LASTEXITCODE -ne 0) { throw "安装器退出码 $LASTEXITCODE" }
    ULog "更新完成：$tag"
    if (-not $Auto) { Write-Host "更新完成：$tag" -ForegroundColor Green }
}
catch {
    ULog "ERROR: $($_.Exception.Message)"
    if (-not $Auto) { throw }
    exit 1
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
}
