# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    rocm lane only: replaces the app venv's CPU torch with the ROCm torch built from source, and adds ai-edge-litert.
.DESCRIPTION
    Dockerfile.torch's rocm-1 stage runs it on the venv Build-TorchApp.ps1 built. torch and torchvision
    are the torch-rocm-wheels stage's wheels (Build-TorchRocmFromSource.ps1); AMD's rocm[libraries]
    runtime and device wheels are pinned by URL + SHA256 (versions.env TORCH_ROCM_WINDOWS_*, forwarded
    as build-args), cached by hash. All install offline, hash-pinned. The device wheels must cover every
    GPU ROCm's rocBLAS serves. TORCH_ROCM '0' or empty is a no-op, and the cpu/nvidia image never builds
    that stage. docs/windows-rocm.md § PyTorch on the rocm lane.
#>
param(
    [AllowEmptyString()][string]$TorchRocm = "$env:TORCH_ROCM",
    [string]$AppDir = $(if ($env:TORCH_APP_DIR) { $env:TORCH_APP_DIR } else { 'C:\opt\OrchestrANT' }),
    # The torch-rocm-wheels stage's output, mounted: exactly one torch and one torchvision wheel.
    [string]$WheelDir = 'C:\bkmnt\torch-rocm-wheels',
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
.DESCRIPTION
    AMD's runtime only: torch/torchvision come from the source build. One GPU per SDK_DEVICE[_<GFX>]; the first
    (unsuffixed) GPU is the one ROCM_SDK_TARGET_FAMILY names; AMD's rocm sdist takes one there.
#>
function Get-TorchRocmPinMap {
    return [ordered]@{
        ROCM               = 'rocm'
        SDK_CORE           = 'rocm-sdk-core'
        SDK_LIBRARIES      = 'rocm-sdk-libraries'
        SDK_DEVICE         = '*'
        SDK_DEVICE_GFX1200 = '*'
    }
}

<#
.SYNOPSIS
    Pin name -> distribution of the venv's PyPI extras: not AMD's, not tied to ROCM_WINDOWS_RELEASE.
#>
function Get-TorchRocmExtraPinMap {
    return [ordered]@{
        AI_EDGE_LITERT = 'ai-edge-litert'
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
    One TORCH_ROCM_WINDOWS_<Name>_URL/_SHA256 pair -> its parsed file; throws on a malformed pin or another host.
#>
function Get-TorchRocmPinnedFile {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Pins,
        [Parameter(Mandatory)][string]$Name,
        # '*' accepts any distribution (device wheels are checked per GPU afterwards).
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$UrlPrefix
    )
    $urlKey = "TORCH_ROCM_WINDOWS_${Name}_URL"
    $shaKey = "TORCH_ROCM_WINDOWS_${Name}_SHA256"
    $url = "$($Pins[$urlKey])".Trim()
    $sha = "$($Pins[$shaKey])".Trim()
    if (-not $url.StartsWith($UrlPrefix)) { throw "$urlKey must be an $UrlPrefix URL, got '$url'" }
    if ($sha -notmatch '^[0-9a-fA-F]{64}$') { throw "$shaKey must be a 64-hex SHA256, got '$sha'" }
    $file = ConvertFrom-TorchRocmFileName -Url $url
    if ($Distribution -ne '*' -and $file.Distribution -ne $Distribution) { throw "$urlKey names $($file.Distribution), expected $Distribution" }
    if ($file.Platform -and $file.Platform -notin @('win_amd64', 'any')) { throw "$urlKey is a $($file.Platform) wheel, the image is win_amd64" }
    return ($file | Add-Member -NotePropertyMembers @{ Name = $Name; Url = $url; Sha256 = $sha.ToLowerInvariant() } -PassThru)
}

<#
.SYNOPSIS
    The GPUs the device pins cover, in pin order; throws on a device wheel for another GPU or pinned twice.
.DESCRIPTION
    Each SDK_DEVICE[_<GFX>] names one GPU. torch's own kernels are in the source-built wheel, which
    rocm-checks\Torch.ps1 holds to the same GPU set.
#>
function Get-TorchRocmGpuTarget {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$ByName)
    $targets = [System.Collections.Generic.List[string]]::new()
    $used = [System.Collections.Generic.List[string]]::new()
    foreach ($sdkName in @($ByName.Keys | Where-Object { $_ -match '^SDK_DEVICE(_GFX[0-9A-Z]+)?$' })) {
        $suffix = $sdkName.Substring('SDK_DEVICE'.Length)
        $sdk = $ByName[$sdkName]
        if ($sdk.Distribution -notmatch '^rocm-sdk-device-(?<gfx>gfx[0-9a-z]+)$') { throw "TORCH_ROCM_WINDOWS_${sdkName}_URL names no GPU target: $($sdk.FileName)" }
        $gfx = $Matches.gfx
        if ($suffix -and $suffix -ne "_$($gfx.ToUpperInvariant())") {
            throw "TORCH_ROCM_WINDOWS_${sdkName}_URL names $($sdk.Distribution), expected rocm-sdk-device-$($suffix.Substring(1).ToLowerInvariant())"
        }
        if ($targets.Contains($gfx)) { throw "TORCH_ROCM_WINDOWS_${sdkName}_URL pins $gfx a second time" }
        $targets.Add($gfx); $used.Add($sdkName)
    }
    if ($targets.Count -eq 0) { throw 'no TORCH_ROCM_WINDOWS_SDK_DEVICE pin: the venv would carry no GPU kernels for ROCm''s libraries' }
    $orphan = @($ByName.Keys | Where-Object { $_ -match 'DEVICE' -and -not $used.Contains($_) })
    if ($orphan.Count -gt 0) { throw "device pins with no SDK_DEVICE pin for their GPU: $($orphan -join ', ')" }
    return @($targets)
}

<#
.SYNOPSIS
    TORCH_ROCM_WINDOWS_* pins -> the checked file set and its GPU targets (GfxTarget = the first).
.DESCRIPTION
    Throws on a missing or malformed pin, a URL off AMD's repo, a file built for another ROCm than
    ROCM_WINDOWS_RELEASE, and device wheels that disagree on the GPU.
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
        $file = Get-TorchRocmPinnedFile -Pins $Pins -Name $name -Distribution $map[$name] -UrlPrefix 'https://stable.repo.amd.com/rocm/'
        if ($file.Version -ne $Release -and -not $file.Version.EndsWith("+rocm$Release")) {
            throw "TORCH_ROCM_WINDOWS_${name}_URL ($($file.FileName)) is not built for ROCM_WINDOWS_RELEASE=$Release - bump the TORCH_ROCM_WINDOWS_* block with it"
        }
        $byName[$name] = $file
    }
    $targets = @(Get-TorchRocmGpuTarget -ByName $byName)
    return [pscustomobject]@{ Wheels = @($byName.Values); GfxTarget = $targets[0]; GfxTargets = $targets }
}

<#
.SYNOPSIS
    The torch-rocm-wheels stage's two wheels -> checked files whose SHA256 is their own, for --require-hashes.
.DESCRIPTION
    Exactly one torch and one torchvision wheel, win_amd64, each a '+rocm<ROCM_WINDOWS_RELEASE>' build;
    anything else in the directory is refused, so a stale second wheel cannot win the install.
#>
function Get-TorchRocmBuiltWheel {
    param([Parameter(Mandatory)][string]$WheelDir, [Parameter(Mandatory)][string]$Release)
    if (-not (Test-Path -LiteralPath $WheelDir -PathType Container)) { throw "no source-built wheels at $WheelDir - the torch-rocm-wheels stage must be mounted there" }
    $files = @(Get-ChildItem -LiteralPath $WheelDir -File | Sort-Object Name)
    $byDist = @{}
    foreach ($f in $files) {
        $w = ConvertFrom-TorchRocmFileName -Url ([uri]$f.FullName).AbsoluteUri
        if ($w.IsSdist -or $w.Distribution -notin @('torch', 'torchvision')) { throw "$WheelDir holds $($f.Name): only the torch and torchvision wheels belong there" }
        if ($byDist.ContainsKey($w.Distribution)) { throw "$WheelDir holds two $($w.Distribution) wheels: $($byDist[$w.Distribution].FileName), $($f.Name)" }
        if ($w.Platform -ne 'win_amd64') { throw "$($f.Name) is a $($w.Platform) wheel, the image is win_amd64" }
        if (-not $w.Version.EndsWith("+rocm$Release")) { throw "$($f.Name) is not a '+rocm$Release' build (ROCM_WINDOWS_RELEASE)" }
        $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLowerInvariant()
        $byDist[$w.Distribution] = $w | Add-Member -NotePropertyMembers @{ Name = $w.Distribution.ToUpperInvariant(); Url = ([uri]$f.FullName).AbsoluteUri; Sha256 = $sha; LocalPath = $f.FullName } -PassThru
    }
    foreach ($dist in 'torch', 'torchvision') { if (-not $byDist.ContainsKey($dist)) { throw "$WheelDir has no $dist wheel" } }
    return @($byDist['torch'], $byDist['torchvision'])
}

<#
.SYNOPSIS
    The venv's PyPI extras (TORCH_ROCM_WINDOWS_AI_EDGE_LITERT_*) -> checked files, PyPI only.
#>
function Get-TorchRocmExtraWheel {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Pins)
    $map = Get-TorchRocmExtraPinMap
    foreach ($name in $map.Keys) {
        Get-TorchRocmPinnedFile -Pins $Pins -Name $name -Distribution $map[$name] -UrlPrefix 'https://files.pythonhosted.org/packages/'
    }
}

<#
.SYNOPSIS
    Every GPU ROCm's rocBLAS serves (rocm-checks\Torch.ps1 reads that set) must have its device wheels pinned.
#>
function Assert-TorchRocmGpuCoverage {
    param([string[]]$GfxTarget = @(), [string[]]$RocmGpu = @())
    if (-not $RocmGpu) { throw "ROCm's rocBLAS names no GPU (no TensileLibrary_lazy_gfx*.dat): cannot tell which device wheels torch needs" }
    $uncovered = [System.Linq.Enumerable]::ToArray([System.Linq.Enumerable]::Except($RocmGpu, [string[]]@($GfxTarget)))
    if ($uncovered) {
        throw "ROCm's rocBLAS serves $($uncovered -join ', '), the device pins cover only $($GfxTarget -join ', ') - add TORCH_ROCM_WINDOWS_*_DEVICE_<GFX> pins"
    }
}

<#
.SYNOPSIS
    The install must leave the chain's onnxruntime alone (same RECORD digest before and after): owner rule, chain ORT only.
#>
function Assert-TorchRocmOrtUnchanged {
    param([AllowEmptyString()][string]$Before, [AllowEmptyString()][string]$After)
    if (-not $Before) { throw 'the app venv has no onnxruntime: Build-TorchApp.ps1 installs the chain wheel before this stage' }
    if ($After -ne $Before) { throw "the install replaced the venv's onnxruntime (RECORD $Before -> $After): the chain's CPU+DML wheel must stay" }
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
            throw "the app lock installed $pkg $have, the ROCm build is $pin - move PYTORCH_VERSION/TORCHVISION_VERSION with the app's lock (APP_REF)"
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
        # A source-built wheel installs from where the stage mounted it; a pinned one from the cache.
        $path = if ($w.PSObject.Properties['LocalPath']) { $w.LocalPath } else { Get-TorchRocmCachedPath -Wheel $w -CacheDir $CacheDir }
        "$($w.Distribution) @ $(([uri]$path).AbsoluteUri) --hash=sha256:$($w.Sha256)"
    }
}

<#
.SYNOPSIS
    Offline and exact: no index, no resolver, and the rocm sdist builds on the venv's setuptools.
.DESCRIPTION
    cmd's own `set` scopes the env to uv, so nothing leaks into the RUN's later verify. ROCM_SDK_TARGET_FAMILY (one GPU:
    it only fills the sdist's generic `device` extra) stops it probing offload-arch; UV_NO_CACHE keeps uv's unpack off the mount.
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
.DESCRIPTION
    Straight to the cache path, never a .part renamed into place: on the BuildKit cache mount that rename
    failed ERROR_PATH_NOT_FOUND on the third wheel (2026-09-25), the create-then-rename class of
    docs/windows-build-lanes.md § Run-side wcifs symptoms. A partial file is never used either way: a
    failed download deletes what it wrote, and every reuse re-checks the SHA256.
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
    $signature = if ($Wheel.IsSdist) { '' } else { 'PK' }
    Invoke-DownloadWithRetry -Url $Wheel.Url -DestinationPath $dest -ExpectedSha256 $Wheel.Sha256 `
        -ExpectSignature $signature -Description $Wheel.FileName -InitialDelaySeconds $InitialDelaySeconds
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
foreach ($name in @((Get-TorchRocmPinMap).Keys) + @((Get-TorchRocmExtraPinMap).Keys)) {
    foreach ($kind in 'URL', 'SHA256') {
        $key = "TORCH_ROCM_WINDOWS_${name}_$kind"
        $pins[$key] = [Environment]::GetEnvironmentVariable($key)
    }
}
$set = Get-TorchRocmWheelSet -Pins $pins -Release $release
$built = @(Get-TorchRocmBuiltWheel -WheelDir $WheelDir -Release $release)
$pinned = @($set.Wheels) + @(Get-TorchRocmExtraWheel -Pins $pins)
$wheels = @($built) + $pinned
Write-Host "=== torch app: source-built $($built.FileName -join ', ') + ROCm $release runtime for $($set.GfxTargets -join ', ') + LiteRT ($($pinned.Count) pinned files) ==="

$venvPython = Join-Path $AppDir '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) { throw "venv python missing at $venvPython - Build-TorchApp.ps1 builds it first" }
# Definitions only (Get-TorchRocmVenvReport, Get-TorchRocmFinding, Get-TorchRocmRocblasGpu): the check guards its own body.
. $CheckScript
$venvReport = Get-TorchRocmVenvReport -Python $venvPython
Assert-TorchRocmVenvMatch -Wheels $wheels -Venv $venvReport['venv']
$rocmRoot = if ($env:HIP_PATH) { $env:HIP_PATH } else { "$env:ROCM_PATH" }
if (-not $rocmRoot) { throw 'neither HIP_PATH nor ROCM_PATH is set - the rocm sdk layer (Dockerfile.rocm) must be beneath this stage' }
$rocmGpu = @(Get-TorchRocmRocblasGpu -RocblasLibraryDir (Join-Path $rocmRoot 'bin\rocblas\library'))
Assert-TorchRocmGpuCoverage -GfxTarget $set.GfxTargets -RocmGpu $rocmGpu

New-Item -ItemType Directory -Force -Path $WheelCache | Out-Null
foreach ($wheel in $pinned) { [void](Save-TorchRocmWheel -Wheel $wheel -CacheDir $WheelCache) }

$requirements = Join-Path ([System.IO.Path]::GetTempPath()) "torch-rocm-$([guid]::NewGuid().ToString('N')).txt"
try {
    Set-Content -LiteralPath $requirements -Value @(Get-TorchRocmRequirement -Wheels $wheels -CacheDir $WheelCache) -Encoding utf8
    [void](Invoke-ShieldedNative -Label 'uv pip install (ROCm torch + LiteRT)' `
            -CommandLine (Get-TorchRocmInstallCommand -VenvPython $venvPython -RequirementsFile $requirements -GfxTarget $set.GfxTarget))
} finally {
    Remove-Item -LiteralPath $requirements -Force -ErrorAction SilentlyContinue
}
# The image's smoke check, on this venv: a bad install fails the build, not the smoke gate.
$installed = Get-TorchRocmVenvReport -Python $venvPython
Assert-TorchRocmOrtUnchanged -Before "$($venvReport['venv']['onnxruntime_record'])" -After "$($installed['venv']['onnxruntime_record'])"
$findings = @(Get-TorchRocmFinding -Report $installed -Release $release -RocmGpu $rocmGpu)
if ($findings.Count -gt 0) { throw "ROCm torch install check failed:`n  $($findings -join "`n  ")" }
Write-Host "=== torch app: ROCm torch $($installed['torch']) (hip $($installed['hip'])) installed and checked ($($set.GfxTargets -join ', '), ROCm $release) ==="
exit 0
