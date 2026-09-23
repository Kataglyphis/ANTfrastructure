# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Installs one of llama.cpp's official Windows releases on the rocm lane: the ROCm/HIP or the Vulkan build.
.DESCRIPTION
    Both zips are the one pinned build (LLAMA_CPP_HIP_BUILD), each SHA256-pinned, plus that tag's LICENSE; each
    gets its own directory, never on PATH. rocm-checks\LlamaCpp.ps1 grades them; docs/windows-builds.md § ROCm layer.
#>
param(
    [ValidateSet('hip', 'vulkan')][string]$Backend,
    [string]$TempDir = 'C:\temp',
    [string]$Build = '',
    # hip only: the Vulkan asset name follows from the build.
    [string]$Asset = '',
    [string]$Sha256 = '',
    [string]$LicenseSha256 = '',
    [string]$RocmRelease = '',
    [string]$InstallDir = ''
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
    What differs per backend: pin env names, asset name, the zip's required and forbidden files, manifest, home.
#>
function Get-LlamaCppBackendSpec {
    param([Parameter(Mandatory)][ValidateSet('hip', 'vulkan')][string]$Backend)
    $common = 'ggml-base.dll', 'ggml.dll', 'llama.dll', 'llama-server.exe'
    if ($Backend -eq 'hip') {
        return @{
            Label = 'HIP'; Home = 'C:\runtime\opt\llama.cpp-hip'; Manifest = 'llama-cpp-hip-manifest.json'
            Env = [ordered]@{ Build = 'LLAMA_CPP_HIP_BUILD'; Asset = 'LLAMA_CPP_HIP_ASSET'; Sha256 = 'LLAMA_CPP_HIP_SHA256'; LicenseSha256 = 'LLAMA_CPP_HIP_LICENSE_SHA256' }
            AssetPattern = '^llama-b(?<build>\d+)-bin-win-rocm-(?<rocm>\d+\.\d+)-x64\.zip$'; AssetFormat = ''
            Required = @('ggml-hip.dll') + $common + @('amdhip64_7.dll', 'amd_comgr.dll', 'rocm_kpack.dll')
            # The HIP runtime the zip may (and must) carry; rocm-checks\LlamaCpp.ps1 proves the copies identical.
            RocmShared = '^(amdhip64_\d+|amd_comgr(_\d+)?|rocm_kpack)\.dll$'; Forbidden = @{}
            RocmNeeds = @('amdhip64_7.dll', 'hipblas.dll', 'rocblas.dll')
        }
    }
    return @{
        Label = 'Vulkan'; Home = 'C:\runtime\opt\llama.cpp-vulkan'; Manifest = 'llama-cpp-vulkan-manifest.json'
        # Same tag as HIP: its build number and LICENSE pin are the HIP keys, so the build stays one pin.
        Env = [ordered]@{ Build = 'LLAMA_CPP_HIP_BUILD'; Sha256 = 'LLAMA_CPP_VULKAN_SHA256'; LicenseSha256 = 'LLAMA_CPP_HIP_LICENSE_SHA256' }
        AssetPattern = '^llama-b(?<build>\d+)-bin-win-vulkan-x64\.zip$'; AssetFormat = 'llama-b{0}-bin-win-vulkan-x64.zip'
        Required = @('ggml-vulkan.dll') + $common
        RocmShared = '(?!)'; Forbidden = @{ 'vulkan-1.dll' = 'the Vulkan loader must come from the image, not a private copy' }
        RocmNeeds = @()
    }
}

<#
.SYNOPSIS
    Refuses every lane but rocm, and (HIP) a ROCm tree without the libraries ggml-hip links. Returns ROCm's bin.
#>
function Assert-LlamaCppLane {
    param([Parameter(Mandatory)][hashtable]$GpuEnvironment, [Parameter(Mandatory)][hashtable]$Spec)
    if (-not $GpuEnvironment['HasRocm']) {
        throw "Install-LlamaCpp: rocm lane only (GPU_TYPE=rocm); this image's GPU_TYPE is '$($GpuEnvironment['GpuType'])'"
    }
    $root = $GpuEnvironment['RocmRoot']
    $bin = if ($root) { Join-Path $root 'bin' } else { '' }
    if (-not $bin -or -not (Test-Path -LiteralPath $bin -PathType Container)) { throw "Install-LlamaCpp: the ROCm tree '$root' has no bin directory" }
    $missing = @($Spec.RocmNeeds | Where-Object { -not (Test-Path -LiteralPath (Join-Path $bin $_)) })
    if ($missing.Count -gt 0) {
        throw "Install-LlamaCpp: the ROCm tree '$root' lacks bin\$($missing -join ', bin\') -- ggml-hip.dll links against them"
    }
    return $bin
}

<#
.SYNOPSIS
    Builds the release asset URL, refusing a pin whose parts disagree with each other or (HIP) with ROCm.
#>
function Get-LlamaCppAssetUrl {
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Build,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Asset,
        [AllowEmptyString()][string]$RocmRelease = ''
    )
    if ($Build -notmatch '^\d+$') { throw "Install-LlamaCpp: LLAMA_CPP_HIP_BUILD must be a build number like 11115; got '$Build'" }
    $assetMatch = [regex]::Match($Asset, $Spec.AssetPattern)
    if (-not $assetMatch.Success) {
        throw "Install-LlamaCpp: $($Spec.Label) asset '$Asset' does not match $($Spec.AssetPattern)"
    }
    if ($assetMatch.Groups['build'].Value -ne $Build) {
        throw "Install-LlamaCpp: the $($Spec.Label) asset names build $($assetMatch.Groups['build'].Value) but LLAMA_CPP_HIP_BUILD is $Build -- bump them together"
    }
    if ($assetMatch.Groups['rocm'].Success) {
        $releaseMatch = [regex]::Match($RocmRelease, '^(?<mm>\d+\.\d+)\.\d+$')
        if (-not $releaseMatch.Success) {
            throw "Install-LlamaCpp: ROCM_WINDOWS_RELEASE must be a full release like 10.0.0; got '$RocmRelease'"
        }
        if ($assetMatch.Groups['rocm'].Value -ne $releaseMatch.Groups['mm'].Value) {
            throw ("Install-LlamaCpp: the asset is built for ROCm $($assetMatch.Groups['rocm'].Value) but the image carries ROCm " +
                "$RocmRelease -- pin a llama.cpp build for $($releaseMatch.Groups['mm'].Value)")
        }
    }
    return "https://github.com/ggml-org/llama.cpp/releases/download/b$Build/$Asset"
}

<#
.SYNOPSIS
    Refuses a zip that is not flat, lacks a load-bearing file, carries a forbidden one, or shadows ROCm.
#>
function Assert-LlamaCppZipEntry {
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$EntryName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RocmBinDllName
    )
    $problems = @()
    $nested = @($EntryName | Where-Object { $_ -match '[\\/]' })
    if ($nested.Count -gt 0) { $problems += "not flat (upstream's layout changed): $($nested[0])" }
    foreach ($r in $Spec.Required) { if ($EntryName -notcontains $r) { $problems += "missing $r" } }
    foreach ($f in @($Spec.Forbidden.Keys)) { if ($EntryName -contains $f) { $problems += "carries ${f}: $($Spec.Forbidden[$f])" } }
    # An exe-dir copy wins the loader search, so anything else of ROCm's here would replace TheRock's.
    $shadow = @($EntryName | Where-Object { $RocmBinDllName -contains $_ -and $_ -notmatch $Spec.RocmShared })
    if ($shadow.Count -gt 0) { $problems += "would shadow ROCm's own $($shadow -join ', ')" }
    if ($problems.Count -gt 0) { throw ("Install-LlamaCpp: refusing the $($Spec.Label) zip:`n  " + ($problems -join "`n  ")) }
}

<#
.SYNOPSIS
    Records every extracted file's size and SHA256, so the smoke check can prove the shipped bytes.
#>
function Write-LlamaCppManifest {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Build,
        [Parameter(Mandatory)][string]$Asset,
        [Parameter(Mandatory)][string]$Sha256
    )
    $files = @(Get-ChildItem -LiteralPath $Dir -File -Recurse | Sort-Object FullName | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($Dir, $_.FullName)
        [ordered]@{ name = $rel; length = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = [ordered]@{ build = $Build; asset = $Asset; sha256 = $Sha256.ToLowerInvariant(); files = $files }
    $path = Join-Path $Dir $Name
    [System.IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 4))
    return $path
}

<#
.SYNOPSIS
    The install: lane, pins, both downloads verified, the zip vetted before extraction, the manifest last.
#>
function Install-LlamaCpp {
    param(
        [Parameter(Mandatory)][ValidateSet('hip', 'vulkan')][string]$Backend,
        [Parameter(Mandatory)][string]$TempDir,
        [AllowEmptyString()][string]$Build = '',
        [AllowEmptyString()][string]$Asset = '',
        [AllowEmptyString()][string]$Sha256 = '',
        [AllowEmptyString()][string]$LicenseSha256 = '',
        [AllowEmptyString()][string]$RocmRelease = '',
        [AllowEmptyString()][string]$InstallDir = ''
    )
    $spec = Get-LlamaCppBackendSpec -Backend $Backend
    $pins = @{ Build = $Build; Asset = $Asset; Sha256 = $Sha256; LicenseSha256 = $LicenseSha256 }
    foreach ($k in @($spec.Env.Keys)) { $pins[$k] = Resolve-ContainerImageValue -Value $pins[$k] -EnvironmentVariable $spec.Env[$k] }
    if ($spec.AssetFormat -and -not $pins.Asset) { $pins.Asset = $spec.AssetFormat -f $pins.Build }
    $Build, $Asset, $Sha256, $LicenseSha256 = $pins.Build, $pins.Asset, $pins.Sha256, $pins.LicenseSha256
    $RocmRelease = Resolve-ContainerImageValue -Value $RocmRelease -EnvironmentVariable 'ROCM_WINDOWS_RELEASE'
    if (-not $InstallDir) { $InstallDir = $spec.Home }

    $rocmBin = Assert-LlamaCppLane -GpuEnvironment (Get-GpuEnvironment) -Spec $spec
    $url = Get-LlamaCppAssetUrl -Spec $spec -Build $Build -Asset $Asset -RocmRelease $RocmRelease
    # The digests are the only integrity check a prebuilt has, so an empty one fails closed.
    foreach ($pin in @{ $spec.Env['Sha256'] = $Sha256 }, @{ $spec.Env['LicenseSha256'] = $LicenseSha256 }) {
        $key = @($pin.Keys)[0]
        if ($pin[$key] -notmatch '^[0-9a-fA-F]{64}$') { throw "Install-LlamaCpp: $key must be a 64-hex SHA256 (see versions.env); got '$($pin[$key])'" }
    }
    if ((Test-Path -LiteralPath $InstallDir) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
        throw "Install-LlamaCpp: $InstallDir already has content; refusing to mix two llama.cpp builds"
    }

    $TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir
    $zip = Join-Path $TempDir $Asset
    Write-Host "Downloading llama.cpp b$Build ($($spec.Label)): $url"
    Invoke-DownloadWithRetry -Url $url -DestinationPath $zip -Description "llama.cpp b$Build Windows $($spec.Label) zip" -ExpectSignature 'PK' -ExpectedSha256 $Sha256

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try { $entries = @($archive.Entries | ForEach-Object { $_.FullName }) } finally { $archive.Dispose() }
    $rocmDlls = @(Get-ChildItem -LiteralPath $rocmBin -Filter '*.dll' -File | ForEach-Object { $_.Name })
    Assert-LlamaCppZipEntry -Spec $spec -EntryName $entries -RocmBinDllName $rocmDlls

    $license = Join-Path $TempDir "llama.cpp-b$Build-LICENSE"
    Invoke-DownloadWithRetry -Url "https://raw.githubusercontent.com/ggml-org/llama.cpp/b$Build/LICENSE" -DestinationPath $license `
        -Description "llama.cpp b$Build LICENSE" -ExpectedSha256 $LicenseSha256

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Write-Host "Extracting $($entries.Count) files into $InstallDir ..."
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $InstallDir)
    $licenseDir = New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'licenses\llama.cpp')
    Move-Item -LiteralPath $license -Destination (Join-Path $licenseDir.FullName 'LICENSE')
    Remove-Item -LiteralPath $zip -Force
    $manifestPath = Write-LlamaCppManifest -Dir $InstallDir -Name $spec.Manifest -Build $Build -Asset $Asset -Sha256 $Sha256
    Clear-PendingFileHandle
    Write-Host "llama.cpp b$Build ($($spec.Label)) installed at $InstallDir; manifest $manifestPath"
}

Install-LlamaCpp -Backend $Backend -TempDir $TempDir -Build $Build -Asset $Asset -Sha256 $Sha256 -LicenseSha256 $LicenseSha256 `
    -RocmRelease $RocmRelease -InstallDir $InstallDir
exit 0
