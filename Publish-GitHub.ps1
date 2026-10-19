param(
    [string]$RepoName = 'doubao-voice-history',
    [string]$Tag = 'v2.0.0'
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host '未安装 GitHub CLI，正在用 winget 安装...' -ForegroundColor Yellow
    winget install --id GitHub.cli -e --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh 仍不可用，请重开终端后重试。' }

gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host '需要登录 GitHub（浏览器授权）...' -ForegroundColor Yellow
    gh auth login --hostname github.com --git-protocol https --web
}
$owner = (gh api user -q .login).Trim()
Write-Host "GitHub 用户：$owner"

git init | Out-Null
git config user.name $owner
git config user.email "$owner@users.noreply.github.com"

$updateFile = Join-Path $PSScriptRoot 'installer\update.json'
@{ repo = "$owner/$RepoName" } | ConvertTo-Json | Set-Content -LiteralPath $updateFile -Encoding UTF8

git add -A
git commit -m "release: $Tag" | Out-Null
git branch -M main

$exists = gh repo view "$owner/$RepoName" 2>$null
if (-not $exists) {
    gh repo create "$owner/$RepoName" --public --source . --remote origin --push
    gh repo edit "$owner/$RepoName" --description "豆包输入法语音历史伴侣：毛玻璃浮条、历史、版本监控与自检修复" `
        --add-topic powershell,windows,doubao,ime,voice,ui-automation
} else {
    git remote remove origin 2>$null
    git remote add origin "https://github.com/$owner/$RepoName.git"
    git push -u origin main
}

git tag $Tag 2>$null
git push origin $Tag
Write-Host "发布完成：https://github.com/$owner/$RepoName" -ForegroundColor Green
Write-Host "Release 工作流会随后自动打包 $Tag。"
