# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# The cp313 win-arm64 torch stack ships in the wheel store: upstream builds no cp314 wheel, so it cannot enter the bundle's own venv (docs/windows-cross-builds.md).

param(
    [string]$WheelDir = 'C:\runtime\wheels',
    [string]$ScriptDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
foreach ($m in 'WindowsSourceBuild.Common', 'WindowsScripts.Shared', 'WindowsTargetArch.Common') {
    $modulePath = Join-Path $scriptAssetRoot "modules\$m.psm1"
    if ((Test-Path $modulePath) -and -not (Get-Module -Name $m)) { Import-Module $modulePath }
}

if (-not (Test-WindowsCrossTarget)) {
    Write-Host 'Arm64 torch wheels: native lane -- the app venv carries torch from the lock (smoke section 21 proves it); nothing to stage'
    exit 0
}

# Import-Versions fills the process env from versions.env unless a build-arg already set it.
& (Join-Path $ScriptDir 'Import-Versions.ps1')

# $true = the wheel carries native members and must pass the target-arch check; the rest are universal py3 wheels.
$wheels = [ordered]@{
    TORCH       = $true
    TORCHVISION = $true
    MARKUPSAFE  = $true
    PILLOW      = $true
    FILELOCK    = $false
    SETUPTOOLS  = $false
    SYMPY       = $false
    MPMATH      = $false
    NETWORKX    = $false
    JINJA2      = $false
    FSSPEC      = $false
}

New-Item -ItemType Directory -Force -Path $WheelDir | Out-Null
$count = 0
foreach ($name in $wheels.Keys) {
    $key = "TORCH_WINDOWS_ARM64_${name}"
    $url = "$([Environment]::GetEnvironmentVariable("${key}_URL"))".Trim()
    $sha = "$([Environment]::GetEnvironmentVariable("${key}_SHA256"))".Trim()
    if (-not $url) { throw "${key}_URL is not set -- the win-arm64 torch stack cannot be pinned" }
    if ($sha -notmatch '^[0-9a-f]{64}$') { throw "${key}_SHA256 must be a 64-hex SHA256, got '$sha'" }
    $file = Join-Path $WheelDir ([uri]::UnescapeDataString(([uri]$url).Segments[-1]))
    Invoke-DownloadWithRetry -Url $url -DestinationPath $file -Description "win-arm64 $name wheel" -ExpectedSha256 $sha
    if ($wheels[$name]) { Assert-WheelTargetArch -WheelPath $file }
    $count++
}
Write-Host "Arm64 torch wheels: staged $count wheel(s) into $WheelDir"
