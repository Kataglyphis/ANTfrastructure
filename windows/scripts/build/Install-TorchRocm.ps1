# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    rocm lane only: replaces the app venv's CPU torch with AMD's pinned ROCm torch wheels.
.DESCRIPTION
    Dockerfile.torch's rocm-1 stage runs it on the venv Build-TorchApp.ps1 built. Every file is
    pinned by URL + SHA256 (versions.env TORCH_ROCM_WINDOWS_*, forwarded as build-args), cached
    by hash and installed offline. TORCH_ROCM '0' or empty is a no-op, and the cpu/nvidia image
    never builds that stage. docs/windows-builds.md § ROCm layer.
#>
param(
    [AllowEmptyString()][string]$TorchRocm = "$env:TORCH_ROCM",
    [string]$AppDir = $(if ($env:TORCH_APP_DIR) { $env:TORCH_APP_DIR } else { 'C:\opt\OrchestrANT' }),
    # Hash-keyed download cache (<cache>\<sha256>\<file>) on the torch stage's uv cache mount.
    [string]$WheelCache = 'C:\uvcache\torch-rocm',
    # The image's rocm-check, dot-sourced: it owns the venv probe and the findings this script applies.
    [string]$CheckScript = (Join-Path $PSScriptRoot 'rocm-checks\Torch.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

<#
.SYNOPSIS
    Pin name -> the distribution its URL must carry; '*' marks a device wheel (checked per GPU).
#>
function Get-TorchRocmPinMap {
    return [ordered]@{
        TORCH               = 'torch'
        TORCHVISION         = 'torchvision'
        TORCH_DEVICE        = '*'
        TORCH_DEVICE_FAMILY = '*'
        TORCHVISION_DEVICE  = '*'
        ROCM                = 'rocm'
        BOOTSTRAP           = 'rocm-bootstrap'
        SDK_CORE            = 'rocm-sdk-core'
        SDK_LIBRARIES       = 'rocm-sdk-libraries'
        SDK_DEVICE          = '*'
    }
}

<#
.SYNOPSIS
    '1' installs; '0' or empty is the cpu/nvidia no-op. TORCH_ROCM=1 needs the rocm sdk layer beneath.
#>
function Test-TorchRocmLane {
    param([AllowEmptyString()][string]$TorchRocm, [AllowEmptyString()][string]$GpuType)
    switch ("$TorchRocm".Trim()) {
        { $_ -in @('', '0') } { return $false }
        '1' {
            if ($GpuType -ne 'rocm') { throw "TORCH_ROCM=1 but GPU_TYPE is '$GpuType': ROCm torch belongs on the rocm lane's sdk layer only" }
            return $true
        }
        default { throw "TORCH_ROCM must be '0' or '1', got '$TorchRocm'" }
    }
}

<#
.SYNOPSIS
    Wheel (PEP 427) or sdist URL -> file name, normalized distribution, version and tags.
#>
function ConvertFrom-TorchRocmFileName {
    param([Parameter(Mandatory)][string]$Url)
    $file = [uri]::UnescapeDataString(([uri]$Url).Segments[-1])
    if ($file -match '^(?<dist>[A-Za-z0-9][A-Za-z0-9_.]*)-(?<ver>[^-]+)-(?<py>[^-]+)-(?<abi>[^-]+)-(?<plat>[^-]+)\.whl$') {
        $py = $Matches.py; $abi = $Matches.abi; $plat = $Matches.plat; $sdist = $false
    } elseif ($file -match '^(?<dist>[A-Za-z0-9][A-Za-z0-9_.-]*?)-(?<ver>\d[^-]*)\.tar\.gz$') {
        $py = ''; $abi = ''; $plat = ''; $sdist = $true
    } else {
        throw "not a wheel or sdist file name: '$file'"
    }
    return [pscustomobject]@{
        FileName     = $file
        Distribution = ($Matches.dist -replace '[-_.]+', '-').ToLowerInvariant()
        Version      = $Matches.ver
        PythonTag    = $py
        AbiTag       = $abi
        Platform     = $plat
        IsSdist      = $sdist
    }
}

<#
.SYNOPSIS
    TORCH_ROCM_WINDOWS_* pins -> the checked file set and its GPU target.
.DESCRIPTION
    Throws on a missing or malformed pin, a URL off AMD's repo, a file built for another ROCm than
    ROCM_WINDOWS_RELEASE (rocm-bootstrap excepted), and device wheels that disagree on the GPU.
#>
function Get-TorchRocmWheelSet {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Pins,
        [AllowEmptyString()][string]$Release
    )
    if ($Release -notmatch '^\d+\.\d+\.\d+$') {
        throw "ROCM_WINDOWS_RELEASE '$Release' is not x.y.z - the rocm sdk layer (Dockerfile.rocm) must be beneath this stage"
    }
    $map = Get-TorchRocmPinMap
    $byName = [ordered]@{}
    foreach ($name in $map.Keys) {
        $urlKey = "TORCH_ROCM_WINDOWS_${name}_URL"
        $shaKey = "TORCH_ROCM_WINDOWS_${name}_SHA256"
        $url = "$($Pins[$urlKey])".Trim()
        $sha = "$($Pins[$shaKey])".Trim()
        if (-not $url.StartsWith('https://stable.repo.amd.com/rocm/')) { throw "$urlKey must be an https://stable.repo.amd.com/rocm/ URL, got '$url'" }
        if ($sha -notmatch '^[0-9a-fA-F]{64}$') { throw "$shaKey must be a 64-hex SHA256, got '$sha'" }
        $file = ConvertFrom-TorchRocmFileName -Url $url
        if ($map[$name] -ne '*' -and $file.Distribution -ne $map[$name]) { throw "$urlKey names $($file.Distribution), expected $($map[$name])" }
        if ($file.Platform -and $file.Platform -notin @('win_amd64', 'any')) { throw "$urlKey is a $($file.Platform) wheel, the image is win_amd64" }
        if ($name -ne 'BOOTSTRAP' -and $file.Version -ne $Release -and -not $file.Version.EndsWith("+rocm$Release")) {
            throw "$urlKey ($($file.FileName)) is not built for ROCM_WINDOWS_RELEASE=$Release - bump the TORCH_ROCM_WINDOWS_* block with it"
        }
        $byName[$name] = $file | Add-Member -NotePropertyMembers @{ Name = $name; Url = $url; Sha256 = $sha.ToLowerInvariant() } -PassThru
    }
    if ($byName.SDK_DEVICE.Distribution -notmatch '^rocm-sdk-device-(?<gfx>gfx[0-9a-z]+)$') {
        throw "TORCH_ROCM_WINDOWS_SDK_DEVICE_URL names no GPU target: $($byName.SDK_DEVICE.FileName)"
    }
    $gfx = $Matches.gfx
    # A device wheel extends one package at its exact version; the family wheel carries no gfx name.
    $devices = @(
        @{ Name = 'TORCH_DEVICE'; Dist = "amd-torch-device-$gfx"; Base = 'TORCH' }
        @{ Name = 'TORCH_DEVICE_FAMILY'; Dist = 'amd-torch-device-*'; Base = 'TORCH' }
        @{ Name = 'TORCHVISION_DEVICE'; Dist = "amd-torchvision-device-$gfx"; Base = 'TORCHVISION' }
    )
    foreach ($d in $devices) {
        $w = $byName[$d.Name]
        if ($w.Distribution -notlike $d.Dist) { throw "TORCH_ROCM_WINDOWS_$($d.Name)_URL names $($w.Distribution), expected $($d.Dist) for $gfx" }
        if ($w.Version -ne $byName[$d.Base].Version) { throw "TORCH_ROCM_WINDOWS_$($d.Name)_URL is $($w.Version), $($d.Base) is $($byName[$d.Base].Version)" }
    }
    return [pscustomobject]@{ Wheels = @($byName.Values); GfxTarget = $gfx }
}

<#
.SYNOPSIS
    The pins must fit the venv uv sync built: its CPython tag and the app lock's torch/torchvision release.
#>
function Assert-TorchRocmVenvMatch {
    param(
        [Parameter(Mandatory)][object[]]$Wheels,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Venv
    )
    foreach ($w in @($Wheels | Where-Object { $_.PythonTag -like 'cp*' })) {
        if ($w.PythonTag -ne $Venv['tag'] -or $w.AbiTag -ne $Venv['tag']) {
            throw "$($w.FileName) is a $($w.PythonTag)-$($w.AbiTag) wheel, the app venv runs $($Venv['tag']) - re-pin TORCH_ROCM_WINDOWS_* for PYTHON_VERSION"
        }
    }
    foreach ($pkg in 'torch', 'torchvision') {
        $have = "$($Venv[$pkg])"
        $pin = @($Wheels | Where-Object { $_.Distribution -eq $pkg })[0].Version
        if (-not $have) { throw "the app venv has no $pkg (PYTORCH_EXTRA=none?) - the ROCm build would add one the app lock never chose" }
        if (($have -split '\+')[0] -ne ($pin -split '\+')[0]) {
            throw "the app lock installed $pkg $have, the ROCm pin is $pin - bump TORCH_ROCM_WINDOWS_* with APP_REF"
        }
    }
    if (-not $Venv['setuptools']) { throw 'the app venv has no setuptools: the rocm sdist builds on it (no build isolation, no index)' }
}

<#
.SYNOPSIS
    Where a pinned file lives in the hash-keyed cache.
#>
function Get-TorchRocmCachedPath {
    param([Parameter(Mandatory)][object]$Wheel, [Parameter(Mandatory)][string]$CacheDir)
    return (Join-Path (Join-Path $CacheDir $Wheel.Sha256) $Wheel.FileName)
}

<#
.SYNOPSIS
    One hash-pinned direct reference per cached file, for uv's --require-hashes.
#>
function Get-TorchRocmRequirement {
    param([Parameter(Mandatory)][object[]]$Wheels, [Parameter(Mandatory)][string]$CacheDir)
    foreach ($w in $Wheels) {
        $uri = ([uri](Get-TorchRocmCachedPath -Wheel $w -CacheDir $CacheDir)).AbsoluteUri
        "$($w.Distribution) @ $uri --hash=sha256:$($w.Sha256)"
    }
}

<#
.SYNOPSIS
    Offline and exact: no index, no resolver, and the rocm sdist builds on the venv's setuptools.
.DESCRIPTION
    cmd's own `set` scopes the env to uv, so nothing leaks into the RUN's later verify. ROCM_SDK_TARGET_FAMILY
    stops the rocm sdist probing offload-arch (no GPU in the build); UV_NO_CACHE keeps uv's unpack off the mount.
#>
function Get-TorchRocmInstallCommand {
    param(
        [Parameter(Mandatory)][string]$VenvPython,
        [Parameter(Mandatory)][string]$RequirementsFile,
        [Parameter(Mandatory)][ValidatePattern('^gfx[0-9a-z]+$')][string]$GfxTarget
    )
    $vars = [ordered]@{ UV_NO_CACHE = '1'; UV_LINK_MODE = 'copy'; ROCM_SDK_TARGET_FAMILY = $GfxTarget; ROCM_BOOTSTRAP_DISABLE_DETECTION = '1' }
    $prefix = -join @($vars.Keys | ForEach-Object { "set ""$_=$($vars[$_])"" && " })
    return ($prefix + "uv pip install --python ""$VenvPython"" --force-reinstall --no-deps --no-index " +
        "--no-build-isolation --require-hashes -r ""$RequirementsFile""")
}

<#
.SYNOPSIS
    Fetches one pinned file into the cache; a cached copy is reused only when it re-verifies.
#>
function Save-TorchRocmWheel {
    param(
        [Parameter(Mandatory)][object]$Wheel,
        [Parameter(Mandatory)][string]$CacheDir,
        [int]$InitialDelaySeconds = 3
    )
    $dest = Get-TorchRocmCachedPath -Wheel $Wheel -CacheDir $CacheDir
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash -eq $Wheel.Sha256) {
            Write-Host "  cached: $($Wheel.FileName)"
            return $dest
        }
        Write-Warning "cached $($Wheel.FileName) fails its SHA256 - fetching it again"
        Remove-Item -LiteralPath $dest -Force
    }
    $part = "$dest.part"
    $signature = if ($Wheel.IsSdist) { '' } else { 'PK' }
    Invoke-DownloadWithRetry -Url $Wheel.Url -DestinationPath $part -ExpectedSha256 $Wheel.Sha256 `
        -ExpectSignature $signature -Description $Wheel.FileName -InitialDelaySeconds $InitialDelaySeconds
    Move-Item -LiteralPath $part -Destination $dest -Force
    return $dest
}

if (-not (Test-TorchRocmLane -TorchRocm $TorchRocm -GpuType "$env:GPU_TYPE")) {
    Write-Host "TORCH_ROCM='$TorchRocm': not the rocm lane, the app venv keeps its torch"
    return
}

# #108 layout: modules sit beside this script in the flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
foreach ($module in 'WindowsScripts.Shared.psm1', 'WindowsNative.Common.psm1') {
    $modulePath = Join-Path $scriptAssetRoot "modules\$module"
    if (-not (Test-Path $modulePath)) { throw "Required module not found: $modulePath" }
    Import-Module $modulePath -Force -DisableNameChecking
}

$release = "$env:ROCM_WINDOWS_RELEASE"
$pins = @{}
foreach ($name in (Get-TorchRocmPinMap).Keys) {
    foreach ($kind in 'URL', 'SHA256') {
        $key = "TORCH_ROCM_WINDOWS_${name}_$kind"
        $pins[$key] = [Environment]::GetEnvironmentVariable($key)
    }
}
$set = Get-TorchRocmWheelSet -Pins $pins -Release $release
Write-Host "=== torch app: ROCm $release torch for $($set.GfxTarget) ($($set.Wheels.Count) pinned files) ==="

$venvPython = Join-Path $AppDir '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) { throw "venv python missing at $venvPython - Build-TorchApp.ps1 builds it first" }
# Definitions only (Get-TorchRocmVenvReport, Get-TorchRocmFinding): the check guards its own body.
. $CheckScript
$venvReport = Get-TorchRocmVenvReport -Python $venvPython
Assert-TorchRocmVenvMatch -Wheels $set.Wheels -Venv $venvReport['venv']

New-Item -ItemType Directory -Force -Path $WheelCache | Out-Null
foreach ($wheel in $set.Wheels) { [void](Save-TorchRocmWheel -Wheel $wheel -CacheDir $WheelCache) }

$requirements = Join-Path ([System.IO.Path]::GetTempPath()) "torch-rocm-$([guid]::NewGuid().ToString('N')).txt"
try {
    Set-Content -LiteralPath $requirements -Value @(Get-TorchRocmRequirement -Wheels $set.Wheels -CacheDir $WheelCache) -Encoding utf8
    [void](Invoke-ShieldedNative -Label 'uv pip install (ROCm torch)' `
            -CommandLine (Get-TorchRocmInstallCommand -VenvPython $venvPython -RequirementsFile $requirements -GfxTarget $set.GfxTarget))
} finally {
    Remove-Item -LiteralPath $requirements -Force -ErrorAction SilentlyContinue
}
# The image's smoke check, on this venv: a bad install fails the build, not the smoke gate.
$installed = Get-TorchRocmVenvReport -Python $venvPython
$findings = @(Get-TorchRocmFinding -Report $installed -Release $release)
if ($findings.Count -gt 0) { throw "ROCm torch install check failed:`n  $($findings -join "`n  ")" }
Write-Host "=== torch app: ROCm torch $($installed['torch']) (hip $($installed['hip'])) installed and checked ($($set.GfxTarget), ROCm $release) ==="
exit 0
