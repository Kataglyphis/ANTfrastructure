# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Installs llama.cpp on the rocm lane: the HIP build (source-built ggml-hip.dll + the CPU zip) or the Vulkan zip.
.DESCRIPTION
    Both use the one pinned build (LLAMA_CPP_HIP_BUILD): a SHA256-pinned upstream zip plus that tag's LICENSE, each in
    its own directory, never on PATH. HIP adds the ggml-hip.dll Build-LlamaCppHipFromSource.ps1 left in -BuiltDir.
    rocm-checks\LlamaCpp.ps1 grades them; docs/windows-rocm.md § llama.cpp HIP and Vulkan.
#>
param(
    [ValidateSet('hip', 'vulkan')][string]$Backend,
    [string]$TempDir = 'C:\temp',
    [string]$Build = '',
    [string]$Sha256 = '',
    [string]$LicenseSha256 = '',
    [string]$InstallDir = '',
    # hip only: Build-LlamaCppHipFromSource.ps1's -OutputDir.
    [string]$BuiltDir = 'C:\temp\llama-cpp-hip-built'
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
    What differs per backend: pin env names, asset name, the zip's required and forbidden files, built files, manifest, home.
#>
function Get-LlamaCppBackendSpec {
    param([Parameter(Mandatory)][ValidateSet('hip', 'vulkan')][string]$Backend)
    $common = 'ggml-base.dll', 'ggml.dll', 'llama.dll', 'llama-server.exe'
    if ($Backend -eq 'hip') {
        return @{
            Label = 'HIP'; Home = 'C:\runtime\opt\llama.cpp-hip'; Manifest = 'llama-cpp-hip-manifest.json'
            # The tools and CPU backends are upstream's CPU zip, as its own ROCm zip merges them; one build pin, one LICENSE pin.
            Env = [ordered]@{ Build = 'LLAMA_CPP_HIP_BUILD'; Sha256 = 'LLAMA_CPP_CPU_SHA256'; LicenseSha256 = 'LLAMA_CPP_HIP_LICENSE_SHA256' }
            AssetPattern = '^llama-b(?<build>\d+)-bin-win-cpu-x64\.zip$'; AssetFormat = 'llama-b{0}-bin-win-cpu-x64.zip'
            Required = @($common) + 'llama-cli.exe'; Built = @('ggml-hip.dll'); BuildRecord = 'llama-cpp-hip-build.json'
            Forbidden = @{ 'ggml-hip.dll' = 'ggml-hip.dll is built from source here, never taken prebuilt' }
            RocmNeeds = @('amdhip64_7.dll', 'hipblas.dll', 'rocblas.dll')
        }
    }
    return @{
        Label = 'Vulkan'; Home = 'C:\runtime\opt\llama.cpp-vulkan'; Manifest = 'llama-cpp-vulkan-manifest.json'
        # Same tag as HIP: its build number and LICENSE pin are the HIP keys, so the build stays one pin.
        Env = [ordered]@{ Build = 'LLAMA_CPP_HIP_BUILD'; Sha256 = 'LLAMA_CPP_VULKAN_SHA256'; LicenseSha256 = 'LLAMA_CPP_HIP_LICENSE_SHA256' }
        AssetPattern = '^llama-b(?<build>\d+)-bin-win-vulkan-x64\.zip$'; AssetFormat = 'llama-b{0}-bin-win-vulkan-x64.zip'
        Required = @('ggml-vulkan.dll') + $common; Built = @(); BuildRecord = ''
        Forbidden = @{ 'vulkan-1.dll' = 'the Vulkan loader must come from the image, not a private copy' }
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
    The release asset's name and URL for the pinned build.
#>
function Get-LlamaCppAsset {
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Build
    )
    if ($Build -notmatch '^\d+$') { throw "Install-LlamaCpp: LLAMA_CPP_HIP_BUILD must be a build number like 11472; got '$Build'" }
    $asset = $Spec.AssetFormat -f $Build
    if ($asset -notmatch $Spec.AssetPattern) { throw "Install-LlamaCpp: $($Spec.Label) asset '$asset' does not match $($Spec.AssetPattern)" }
    return [pscustomobject]@{ Name = $asset; Url = "https://github.com/ggml-org/llama.cpp/releases/download/b$Build/$asset" }
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
    # An exe-dir copy wins the loader search, so any ROCm name here would replace TheRock's.
    $shadow = @($EntryName | Where-Object { $RocmBinDllName -contains $_ })
    if ($shadow.Count -gt 0) { $problems += "would shadow ROCm's own $($shadow -join ', ')" }
    if ($problems.Count -gt 0) { throw ("Install-LlamaCpp: refusing the $($Spec.Label) zip:`n  " + ($problems -join "`n  ")) }
}

<#
.SYNOPSIS
    The source build's record, refused unless it was built from this build pin against this ROCm release.
#>
function Get-LlamaCppBuiltRecord {
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BuiltDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Build,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RocmRelease
    )
    $missing = @(@($Spec.Built) + $Spec.BuildRecord | Where-Object { -not $BuiltDir -or -not [System.IO.File]::Exists((Join-Path $BuiltDir $_)) })
    if ($missing.Count -gt 0) {
        throw "Install-LlamaCpp: '$BuiltDir' lacks $($missing -join ', ') -- run Build-LlamaCppHipFromSource.ps1 first"
    }
    $record = Get-Content -LiteralPath (Join-Path $BuiltDir $Spec.BuildRecord) -Raw | ConvertFrom-Json
    if ("$($record.build)" -ne $Build) { throw "Install-LlamaCpp: ggml-hip.dll was built from b$($record.build), but LLAMA_CPP_HIP_BUILD is $Build" }
    if ("$($record.rocm_release)" -ne $RocmRelease) {
        throw "Install-LlamaCpp: ggml-hip.dll was built against ROCm '$($record.rocm_release)', but the image carries '$RocmRelease'"
    }
    return $record
}

<#
.SYNOPSIS
    Records every installed file's size and SHA256, so the smoke check can prove the shipped bytes.
#>
function Write-LlamaCppManifest {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Build,
        [Parameter(Mandatory)][string]$Asset,
        [Parameter(Mandatory)][string]$Sha256,
        # HIP: the source build's record (commit, source SHA256, GPU targets, ROCm release).
        $Built = $null
    )
    $files = @(Get-ChildItem -LiteralPath $Dir -File -Recurse | Sort-Object FullName | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($Dir, $_.FullName)
        [ordered]@{ name = $rel; length = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = [ordered]@{ build = $Build; asset = $Asset; sha256 = $Sha256.ToLowerInvariant() }
    if ($null -ne $Built) { $manifest['built'] = $Built }
    $manifest['files'] = $files
    $path = Join-Path $Dir $Name
    [System.IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 4))
    return $path
}

<#
.SYNOPSIS
    The install: lane, pins, the built DLL's record, both downloads verified, the zip vetted before extraction, the manifest last.
#>
function Install-LlamaCpp {
    param(
        [Parameter(Mandatory)][ValidateSet('hip', 'vulkan')][string]$Backend,
        [Parameter(Mandatory)][string]$TempDir,
        [AllowEmptyString()][string]$Build = '',
        [AllowEmptyString()][string]$Sha256 = '',
        [AllowEmptyString()][string]$LicenseSha256 = '',
        [AllowEmptyString()][string]$InstallDir = '',
        [AllowEmptyString()][string]$BuiltDir = ''
    )
    $spec = Get-LlamaCppBackendSpec -Backend $Backend
    $pins = @{ Build = $Build; Sha256 = $Sha256; LicenseSha256 = $LicenseSha256 }
    foreach ($k in @($spec.Env.Keys)) { $pins[$k] = Resolve-ContainerImageValue -Value $pins[$k] -EnvironmentVariable $spec.Env[$k] }
    $Build, $Sha256, $LicenseSha256 = $pins.Build, $pins.Sha256, $pins.LicenseSha256
    if (-not $InstallDir) { $InstallDir = $spec.Home }

    $rocmBin = Assert-LlamaCppLane -GpuEnvironment (Get-GpuEnvironment) -Spec $spec
    $asset = Get-LlamaCppAsset -Spec $spec -Build $Build
    # The digests are the only integrity check a prebuilt has, so an empty one fails closed.
    foreach ($pin in @{ $spec.Env['Sha256'] = $Sha256 }, @{ $spec.Env['LicenseSha256'] = $LicenseSha256 }) {
        $key = @($pin.Keys)[0]
        if ($pin[$key] -notmatch '^[0-9a-fA-F]{64}$') { throw "Install-LlamaCpp: $key must be a 64-hex SHA256 (see versions.env); got '$($pin[$key])'" }
    }
    if ((Test-Path -LiteralPath $InstallDir) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
        throw "Install-LlamaCpp: $InstallDir already has content; refusing to mix two llama.cpp builds"
    }
    $record = $null
    if ($spec.Built.Count -gt 0) {
        $record = Get-LlamaCppBuiltRecord -Spec $spec -BuiltDir $BuiltDir -Build $Build -RocmRelease "$env:ROCM_WINDOWS_RELEASE"
    }

    $TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir
    $zip = Join-Path $TempDir $asset.Name
    Write-Host "Downloading llama.cpp b$Build ($($spec.Label)): $($asset.Url)"
    Invoke-DownloadWithRetry -Url $asset.Url -DestinationPath $zip -Description "llama.cpp b$Build $($asset.Name)" -ExpectSignature 'PK' -ExpectedSha256 $Sha256

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
    foreach ($f in $spec.Built) { Copy-Item -LiteralPath (Join-Path $BuiltDir $f) -Destination $InstallDir }
    $licenseDir = New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'licenses\llama.cpp')
    Move-Item -LiteralPath $license -Destination (Join-Path $licenseDir.FullName 'LICENSE')
    Remove-Item -LiteralPath $zip -Force
    $manifestPath = Write-LlamaCppManifest -Dir $InstallDir -Name $spec.Manifest -Build $Build -Asset $asset.Name -Sha256 $Sha256 -Built $record
    Clear-PendingFileHandle
    Write-Host "llama.cpp b$Build ($($spec.Label)) installed at $InstallDir; manifest $manifestPath"
}

Install-LlamaCpp -Backend $Backend -TempDir $TempDir -Build $Build -Sha256 $Sha256 -LicenseSha256 $LicenseSha256 -InstallDir $InstallDir `
    -BuiltDir $BuiltDir
exit 0
