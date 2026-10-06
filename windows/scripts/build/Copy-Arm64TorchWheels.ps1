# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Two pinned win-arm64 stacks go into the wheel store: cp313 torch, which has no cp314 wheel upstream, and the cp314 pytest stack (docs/windows-cross-builds.md).

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

# Each stack's prefix names its versions.env keys; its table maps a wheel key to whether it is native.
function Get-Arm64WheelStack {
    # $true = the wheel carries native members and must pass the target-arch check; the rest are universal py3 wheels.
    $torch = [ordered]@{
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
    # The cp314 pytest stack the bundle's own interpreter runs a consumer's suite with (CON67); it shares jinja2 and setuptools with the torch stack.
    [ordered]@{
        TORCH_WINDOWS_ARM64  = $torch
        PYTEST_WINDOWS_ARM64 = [ordered]@{
            CERTIFI            = $false
            CHARDET            = $false
            CHARSET_NORMALIZER = $true
            COLORAMA           = $false
            COVERAGE           = $true
            DATAPROPERTY       = $false
            IDNA               = $false
            INICONFIG          = $false
            MARKUPSAFE         = $true
            MBSTRDECODER       = $false
            PACKAGING          = $false
            PATHVALIDATE       = $false
            PLUGGY             = $false
            PY_CPUINFO         = $false
            PYGMENTS           = $false
            PYTABLEWRITER      = $false
            PYTEST             = $false
            PYTEST_BENCHMARK   = $false
            PYTEST_COV         = $false
            PYTEST_HTML        = $false
            PYTEST_MD          = $false
            PYTEST_MD_REPORT   = $false
            PYTEST_METADATA    = $false
            PYTHON_DATEUTIL    = $false
            PYTZ               = $false
            REQUESTS           = $false
            SIX                = $false
            TABLEDATA          = $false
            TCOLORPY           = $false
            TYPEPY             = $false
            URLLIB3            = $false
        }
    }
}

$stacks = Get-Arm64WheelStack
New-Item -ItemType Directory -Force -Path $WheelDir | Out-Null
foreach ($prefix in $stacks.Keys) {
    $wheels = $stacks[$prefix]
    $count = 0
    foreach ($name in $wheels.Keys) {
        $key = "${prefix}_${name}"
        $url = "$([Environment]::GetEnvironmentVariable("${key}_URL"))".Trim()
        $sha = "$([Environment]::GetEnvironmentVariable("${key}_SHA256"))".Trim()
        if (-not $url) { throw "${key}_URL is not set -- the ${prefix} wheel stack cannot be pinned" }
        if ($sha -notmatch '^[0-9a-f]{64}$') { throw "${key}_SHA256 must be a 64-hex SHA256, got '$sha'" }
        $file = Join-Path $WheelDir ([uri]::UnescapeDataString(([uri]$url).Segments[-1]))
        Invoke-DownloadWithRetry -Url $url -DestinationPath $file -Description "win-arm64 $name wheel" -ExpectedSha256 $sha
        if ($wheels[$name]) { Assert-WheelTargetArch -WheelPath $file }
        $count++
    }
    Write-Host "Arm64 ${prefix} wheels: staged $count wheel(s) into $WheelDir"
}
