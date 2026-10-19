#requires -Version 5.1
<#
.SYNOPSIS
  构建、测试并发布 cvMaster Windows 版。
.PARAMETER Configuration
  Debug 或 Release，默认 Release。
.PARAMETER Runtime
  win-x64 或 win-arm64，默认 win-x64。
.PARAMETER FrameworkDependent
  发布依赖系统 .NET 10 Desktop Runtime 的精简产物。
.PARAMETER SingleFile
  发布单文件自包含产物；首次启动会解压原生库。
.PARAMETER SkipTests
  跳过核心冒烟测试。
.PARAMETER SkipPublish
  只构建（并默认运行测试），不生成 dist 产物。
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64',

    [switch]$FrameworkDependent,
    [switch]$SingleFile,
    [switch]$SkipTests,
    [switch]$SkipPublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# dotnet CLI 以 UTF-8 输出，Windows PowerShell 5.1 默认按 OEM 代码页解码。
try {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
}
catch {
    # 某些非交互宿主不允许修改编码；不影响构建结果。
}

$root = $PSScriptRoot
$solution = Join-Path $root 'cvMaster.slnx'
$appProject = Join-Path $root 'src\CvMaster\CvMaster.csproj'
$testProject = Join-Path $root 'src\CvMaster.SmokeTests\CvMaster.SmokeTests.csproj'

function Resolve-DotNet {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe')
    }

    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')
    }

    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'dotnet\dotnet.exe')
    }

    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe')
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw '未找到 dotnet。请安装 .NET SDK 10，或把 dotnet 加入 PATH。'
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host ''
    Write-Host "==> $Title" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Title 失败（退出码 $LASTEXITCODE）。"
    }
}

$dotnet = Resolve-DotNet
$dotnetVersion = & $dotnet --version
Write-Host "dotnet $dotnetVersion"
Write-Host "solution: $solution"

Push-Location $root
try {
    Invoke-Step "还原并构建 $Configuration" {
        & $dotnet build $solution -c $Configuration --nologo
    }

    if (-not $SkipTests) {
        Invoke-Step '运行核心冒烟测试' {
            & $dotnet run --project $testProject -c $Configuration --no-build
        }
    }

    if ($SkipPublish) {
        Write-Host ''
        Write-Host '已跳过发布。' -ForegroundColor Yellow
        return
    }

    $output = Join-Path $root "dist\$Runtime"
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }

    $publishArgs = @(
        'publish', $appProject,
        '-c', $Configuration,
        '-r', $Runtime,
        '-o', $output,
        '--nologo',
        '--self-contained', $(if ($FrameworkDependent) { 'false' } else { 'true' })
    )

    if ($SingleFile) {
        $publishArgs += @(
            '-p:PublishSingleFile=true',
            '-p:IncludeNativeLibrariesForSelfExtract=true',
            '-p:EnableCompressionInSingleFile=true',
            '-p:DebugType=None',
            '-p:DebugSymbols=false'
        )
    }

    Invoke-Step '发布应用' {
        & $dotnet @publishArgs
    }

    $exe = Join-Path $output 'cvMaster.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "发布完成但未找到 $exe。"
    }

    $size = (Get-ChildItem -LiteralPath $output -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host ''
    Write-Host "发布完成：$exe" -ForegroundColor Green
    Write-Host ("输出大小：{0:N1} MB" -f ($size / 1MB))
    if ($FrameworkDependent) {
        Write-Host '该产物需要目标机器安装 .NET 10 Desktop Runtime。' -ForegroundColor Yellow
    }
}
finally {
    Pop-Location
}
