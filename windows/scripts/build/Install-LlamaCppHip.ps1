# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Installs llama.cpp's official Windows ROCm release (ggml-hip + llama-server) on the rocm lane.
.DESCRIPTION
    A prebuilt, pinned by build number, asset name and SHA256 in versions.env, plus llama.cpp's
    LICENSE at that tag (the zip carries none). It refuses to run off the rocm lane or without a
    ROCm tree. The zip's own HIP runtime DLLs stay next to the exes; hipBLAS/rocBLAS come from
    ROCm's bin. The directory never goes on PATH. rocm-checks\LlamaCpp.ps1 grades the result.
    docs/windows-builds.md § ROCm layer.
#>
param(
    [string]$TempDir = 'C:\temp',
    [string]$Build = '',
    [string]$Asset = '',
    [string]$Sha256 = '',
    [string]$LicenseSha256 = '',
    [string]$RocmRelease = '',
    [string]$InstallDir = 'C:\runtime\opt\llama.cpp-hip'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
foreach ($name in 'modules\WindowsContainerImage.Common.psm1', 'modules\WindowsSourceBuild.Cuda.psm1') {
    $modulePath = Join-Path $scriptAssetRoot $name
    if (-not (Test-Path $modulePath)) { throw "Required module not found: $modulePath" }
    Import-Module $modulePath -Force
}

<#
.SYNOPSIS
    Refuses every lane but rocm, and a ROCm tree without the libraries ggml-hip links. Returns ROCm's bin.
#>
function Assert-LlamaCppHipLane {
    param([Parameter(Mandatory)][hashtable]$GpuEnvironment)
    if (-not $GpuEnvironment['HasRocm']) {
        throw "Install-LlamaCppHip: rocm lane only (GPU_TYPE=rocm); this image's GPU_TYPE is '$($GpuEnvironment['GpuType'])'"
    }
    $root = $GpuEnvironment['RocmRoot']
    $bin = if ($root) { Join-Path $root 'bin' } else { '' }
    $missing = @('amdhip64_7.dll', 'hipblas.dll', 'rocblas.dll' | Where-Object { -not $bin -or -not (Test-Path -LiteralPath (Join-Path $bin $_)) })
    if ($missing.Count -gt 0) {
        throw "Install-LlamaCppHip: the ROCm tree '$root' lacks bin\$($missing -join ', bin\') -- ggml-hip.dll links against them"
    }
    return $bin
}

<#
.SYNOPSIS
    Builds the release asset URL, refusing a pin whose parts disagree with each other or with ROCm.
#>
function Get-LlamaCppHipAssetUrl {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Build,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Asset,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RocmRelease
    )
    if ($Build -notmatch '^\d+$') { throw "Install-LlamaCppHip: LLAMA_CPP_HIP_BUILD must be a build number like 11115; got '$Build'" }
    $assetMatch = [regex]::Match($Asset, '^llama-b(?<build>\d+)-bin-win-rocm-(?<rocm>\d+\.\d+)-x64\.zip$')
    if (-not $assetMatch.Success) {
        throw "Install-LlamaCppHip: LLAMA_CPP_HIP_ASSET '$Asset' is not a llama-b<N>-bin-win-rocm-<X.Y>-x64.zip name"
    }
    if ($assetMatch.Groups['build'].Value -ne $Build) {
        throw "Install-LlamaCppHip: LLAMA_CPP_HIP_ASSET names build $($assetMatch.Groups['build'].Value) but LLAMA_CPP_HIP_BUILD is $Build -- bump them together"
    }
    $releaseMatch = [regex]::Match($RocmRelease, '^(?<mm>\d+\.\d+)\.\d+$')
    if (-not $releaseMatch.Success) {
        throw "Install-LlamaCppHip: ROCM_WINDOWS_RELEASE must be a full release like 10.0.0; got '$RocmRelease'"
    }
    if ($assetMatch.Groups['rocm'].Value -ne $releaseMatch.Groups['mm'].Value) {
        throw ("Install-LlamaCppHip: the asset is built for ROCm $($assetMatch.Groups['rocm'].Value) but the image carries ROCm " +
            "$RocmRelease -- pin a llama.cpp build for $($releaseMatch.Groups['mm'].Value)")
    }
    return "https://github.com/ggml-org/llama.cpp/releases/download/b$Build/$Asset"
}

<#
.SYNOPSIS
    Refuses a zip that is not flat, lacks a load-bearing file, or shadows ROCm beyond the HIP runtime.
#>
function Assert-LlamaCppHipZipEntry {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$EntryName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RocmBinDllName,
        # The HIP runtime the zip may (and must) carry; rocm-checks\LlamaCpp.ps1 proves the copies identical.
        [string]$RuntimePattern = '^(amdhip64_\d+|amd_comgr(_\d+)?|rocm_kpack)\.dll$'
    )
    $problems = @()
    $nested = @($EntryName | Where-Object { $_ -match '[\\/]' })
    if ($nested.Count -gt 0) { $problems += "not flat (upstream's layout changed): $($nested[0])" }
    $required = 'ggml-hip.dll', 'ggml-base.dll', 'ggml.dll', 'llama.dll', 'llama-server.exe', 'amdhip64_7.dll', 'amd_comgr.dll', 'rocm_kpack.dll'
    foreach ($r in $required) { if ($EntryName -notcontains $r) { $problems += "missing $r" } }
    # An exe-dir copy wins the loader search, so anything else of ROCm's here would replace TheRock's.
    $shadow = @($EntryName | Where-Object { $RocmBinDllName -contains $_ -and $_ -notmatch $RuntimePattern })
    if ($shadow.Count -gt 0) { $problems += "would shadow ROCm's own $($shadow -join ', ')" }
    if ($problems.Count -gt 0) { throw ("Install-LlamaCppHip: refusing the zip:`n  " + ($problems -join "`n  ")) }
}

<#
.SYNOPSIS
    Records every extracted file's size and SHA256, so the smoke check can prove the shipped bytes.
#>
function Write-LlamaCppHipManifest {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Build,
        [Parameter(Mandatory)][string]$Asset,
        [Parameter(Mandatory)][string]$Sha256
    )
    $files = @(Get-ChildItem -LiteralPath $Dir -File -Recurse | Sort-Object FullName | ForEach-Object {
        $name = [System.IO.Path]::GetRelativePath($Dir, $_.FullName)
        [ordered]@{ name = $name; length = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = [ordered]@{ build = $Build; asset = $Asset; sha256 = $Sha256.ToLowerInvariant(); files = $files }
    $path = Join-Path $Dir 'llama-cpp-hip-manifest.json'
    [System.IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 4))
    return $path
}

<#
.SYNOPSIS
    The install: lane, pins, both downloads verified, the zip vetted before extraction, the manifest last.
#>
function Install-LlamaCppHip {
    param(
        [Parameter(Mandatory)][string]$TempDir,
        [AllowEmptyString()][string]$Build = '',
        [AllowEmptyString()][string]$Asset = '',
        [AllowEmptyString()][string]$Sha256 = '',
        [AllowEmptyString()][string]$LicenseSha256 = '',
        [AllowEmptyString()][string]$RocmRelease = '',
        [Parameter(Mandatory)][string]$InstallDir
    )
    $Build = Resolve-ContainerImageValue -Value $Build -EnvironmentVariable 'LLAMA_CPP_HIP_BUILD'
    $Asset = Resolve-ContainerImageValue -Value $Asset -EnvironmentVariable 'LLAMA_CPP_HIP_ASSET'
    $Sha256 = Resolve-ContainerImageValue -Value $Sha256 -EnvironmentVariable 'LLAMA_CPP_HIP_SHA256'
    $LicenseSha256 = Resolve-ContainerImageValue -Value $LicenseSha256 -EnvironmentVariable 'LLAMA_CPP_HIP_LICENSE_SHA256'
    $RocmRelease = Resolve-ContainerImageValue -Value $RocmRelease -EnvironmentVariable 'ROCM_WINDOWS_RELEASE'

    $rocmBin = Assert-LlamaCppHipLane -GpuEnvironment (Get-GpuEnvironment)
    $url = Get-LlamaCppHipAssetUrl -Build $Build -Asset $Asset -RocmRelease $RocmRelease
    # The digests are the only integrity check a prebuilt has, so an empty one fails closed.
    foreach ($pin in @{ LLAMA_CPP_HIP_SHA256 = $Sha256 }, @{ LLAMA_CPP_HIP_LICENSE_SHA256 = $LicenseSha256 }) {
        $key = @($pin.Keys)[0]
        if ($pin[$key] -notmatch '^[0-9a-fA-F]{64}$') { throw "Install-LlamaCppHip: $key must be a 64-hex SHA256 (see versions.env); got '$($pin[$key])'" }
    }
    if ((Test-Path -LiteralPath $InstallDir) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
        throw "Install-LlamaCppHip: $InstallDir already has content; refusing to mix two llama.cpp builds"
    }

    $TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir
    $zip = Join-Path $TempDir $Asset
    Write-Host "Downloading llama.cpp b$Build (ROCm $RocmRelease): $url"
    Invoke-DownloadWithRetry -Url $url -DestinationPath $zip -Description "llama.cpp b$Build Windows ROCm zip" -ExpectSignature 'PK' -ExpectedSha256 $Sha256

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try { $entries = @($archive.Entries | ForEach-Object { $_.FullName }) } finally { $archive.Dispose() }
    $rocmDlls = @(Get-ChildItem -LiteralPath $rocmBin -Filter '*.dll' -File | ForEach-Object { $_.Name })
    Assert-LlamaCppHipZipEntry -EntryName $entries -RocmBinDllName $rocmDlls

    $license = Join-Path $TempDir "llama.cpp-b$Build-LICENSE"
    Invoke-DownloadWithRetry -Url "https://raw.githubusercontent.com/ggml-org/llama.cpp/b$Build/LICENSE" -DestinationPath $license `
        -Description "llama.cpp b$Build LICENSE" -ExpectedSha256 $LicenseSha256

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Write-Host "Extracting $($entries.Count) files into $InstallDir ..."
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $InstallDir)
    $licenseDir = New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'licenses\llama.cpp')
    Move-Item -LiteralPath $license -Destination (Join-Path $licenseDir.FullName 'LICENSE')
    Remove-Item -LiteralPath $zip -Force
    $manifestPath = Write-LlamaCppHipManifest -Dir $InstallDir -Build $Build -Asset $Asset -Sha256 $Sha256
    Clear-PendingFileHandle
    Write-Host "llama.cpp b$Build (HIP) installed at $InstallDir; manifest $manifestPath"
}

Install-LlamaCppHip -TempDir $TempDir -Build $Build -Asset $Asset -Sha256 $Sha256 -LicenseSha256 $LicenseSha256 `
    -RocmRelease $RocmRelease -InstallDir $InstallDir
exit 0
