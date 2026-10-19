#requires -Version 5.1
<#
.SYNOPSIS
  构建并部署 cvMaster 到当前用户的本地程序目录。
.DESCRIPTION
  默认部署到 %LOCALAPPDATA%\Programs\cvMaster，并创建当前用户开始菜单快捷方式。
  不写入开机启动项，不请求管理员权限，不修改 %LOCALAPPDATA%\cvMaster 中的用户数据。
.PARAMETER Runtime
  win-x64 或 win-arm64，默认 win-x64。
.PARAMETER InstallDirectory
  安装目录，默认 %LOCALAPPDATA%\Programs\cvMaster。
.PARAMETER SkipBuild
  跳过构建、测试和发布，直接部署 dist 中已有产物。
.PARAMETER NoLaunch
  部署完成后不自动启动。
.PARAMETER NoShortcut
  不创建开始菜单快捷方式。
#>
[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64',

    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\cvMaster'),

    [switch]$SkipBuild,
    [switch]$NoLaunch,
    [switch]$NoShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
}
catch {
    # 非交互宿主可能不允许修改编码。
}

$root = $PSScriptRoot
$source = Join-Path $root "dist\$Runtime"
$sourceExe = Join-Path $source 'cvMaster.exe'

if (-not $SkipBuild) {
    Write-Host '==> 构建、测试并发布' -ForegroundColor Cyan
    & (Join-Path $root 'build.ps1') -Runtime $Runtime
}

if (-not (Test-Path -LiteralPath $sourceExe)) {
    throw "未找到发布产物：$sourceExe。请先执行 build.ps1。"
}

$installDir = [System.IO.Path]::GetFullPath($InstallDirectory)
if ([string]::IsNullOrWhiteSpace($installDir) -or $installDir -eq [System.IO.Path]::GetPathRoot($installDir)) {
    throw "安装目录不合法：$InstallDirectory"
}

Write-Host ''
Write-Host "==> 停止正在运行的 cvMaster" -ForegroundColor Cyan
Get-Process -Name cvMaster -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Stop-Process -Id $_.Id -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "无法停止进程 $($_.Id)：$($_.Exception.Message)"
    }
}
Start-Sleep -Milliseconds 500

Write-Host "==> 部署到 $installDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $installDir -Recurse -Force

$installedExe = Join-Path $installDir 'cvMaster.exe'
if (-not (Test-Path -LiteralPath $installedExe)) {
    throw "部署后未找到 $installedExe。"
}

if (-not $NoShortcut) {
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Path $startMenu -Force | Out-Null
    $shortcutPath = Join-Path $startMenu 'cvMaster.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $installedExe
    $shortcut.WorkingDirectory = $installDir
    $shortcut.IconLocation = "$installedExe,0"
    $shortcut.Description = 'cvMaster 剪贴板管理工具'
    $shortcut.Save()
    Write-Host "开始菜单快捷方式：$shortcutPath"
}

if (-not $NoLaunch) {
    Write-Host '==> 启动 cvMaster' -ForegroundColor Cyan
    Start-Process -FilePath $installedExe -WorkingDirectory $installDir | Out-Null
    Start-Sleep -Milliseconds 1200
    $process = Get-Process -Name cvMaster -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $process) {
        throw 'cvMaster 启动后未保持运行，请检查 %LOCALAPPDATA%\cvMaster\logs\cvmaster.log。'
    }

    Write-Host "正在运行：PID $($process.Id)" -ForegroundColor Green
}

$size = (Get-ChildItem -LiteralPath $installDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ''
Write-Host "部署完成：$installedExe" -ForegroundColor Green
Write-Host ("安装大小：{0:N1} MB" -f ($size / 1MB))
Write-Host '用户数据仍位于 %LOCALAPPDATA%\cvMaster（部署不会覆盖或删除）。'
