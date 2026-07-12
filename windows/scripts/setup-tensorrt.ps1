# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$TensorRtVersion = '',
    [string]$TensorRtRoot = '',
    [string]$LocalZipPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) { throw "Required module not found: $sharedModulePath" }
Import-Module $sharedModulePath -Force
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through WindowsContainerImage.Common's re-export.

$TensorRtVersion = Resolve-ContainerImageValue -Value $TensorRtVersion -EnvironmentVariable 'TENSORRT_VERSION' -DefaultValue ''
$TensorRtRoot = Resolve-ContainerImageValue -Value $TensorRtRoot -EnvironmentVariable 'TENSORRT_ROOT' -DefaultValue 'C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT'

# Returns the first *TensorRT*.zip in $Dir (or $null if the dir is absent / has none).
function Find-TensorRtZipIn {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $found = Get-ChildItem (Join-Path $Dir '*TensorRT*.zip') -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

# Find a TensorRT zip: local path arg > repo downloads dir > download from NVIDIA
$trtZip = $null

# 1. Check explicit local path
if ($LocalZipPath -and (Test-Path $LocalZipPath)) {
    $trtZip = $LocalZipPath
    Write-Host "Using TensorRT zip from: $LocalZipPath"
}

# 2. Check repo downloads dir (mounted in container at C:\temp\downloads)
if (-not $trtZip) {
    $trtZip = Find-TensorRtZipIn -Dir (Join-Path $env:TEMP_DIR 'downloads')
    if ($trtZip) { Write-Host "Found TensorRT zip at: $trtZip" }
}

# 3. Try C:\Users\Public\Downloads (mapped from host)
if (-not $trtZip) {
    $trtZip = Find-TensorRtZipIn -Dir 'C:\Users\Public\Downloads'
    if ($trtZip) { Write-Host "Found TensorRT zip at: $trtZip" }
}

# 4. Download from NVIDIA (fallback, may fail without auth)
if (-not $trtZip -and $TensorRtVersion) {
    $parts = $TensorRtVersion.Split('.')
    $dirVersion = if ($parts.Length -ge 3) { "$($parts[0]).$($parts[1]).$($parts[2])" } else { $TensorRtVersion }
    $trtZip = Join-Path $env:TEMP 'tensorrt.zip'
    # First candidate derives its cuda suffix from CUDA_VERSION_MAJOR_MINOR (baked by the
    # nvidia stage) so a CUDA bump moves this fallback automatically; the fixed alternates
    # cover NVIDIA's usual per-major zip names. Auth-gated: any of these may 404/redirect.
    $cudaSuffix = Resolve-ContainerImageValue -EnvironmentVariable 'CUDA_VERSION_MAJOR_MINOR' -DefaultValue '13.3'
    $urls = @(
        "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-$cudaSuffix.zip",
        "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-13.0.zip",
        "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-12.8.zip"
    ) | Select-Object -Unique
    $downloaded = $false
    foreach ($url in $urls) {
        Write-Host "Trying download: $url"
        # -ExpectSignature PK rejects NVIDIA's login/auth HTML page (served when unauthenticated)
        # so we fall through to the next URL / disable the EP instead of extracting a garbage zip.
        # One attempt per URL (the alternates are version-suffix guesses; most 404).
        try { Invoke-DownloadWithRetry -Url $url -DestinationPath $trtZip -MaxAttempts 1 -InitialDelaySeconds 0 -ExpectSignature PK -Description "TensorRT $TensorRtVersion"; $downloaded = $true; break }
        catch { Write-Host "  Failed: $($_.Exception.Message)" }
    }
    if (-not $downloaded) {
        Write-Host 'WARNING: Could not download TensorRT. TensorRT EP will be disabled.'
        return
    }
}

if (-not $trtZip -or -not (Test-Path $trtZip)) {
    Write-Host 'WARNING: No TensorRT zip found. TensorRT EP will be disabled.'
    Write-Host 'Place tensorrt-*.zip in: windows/downloads/ or set TENSORRT_ZIP_PATH env var.'
    return
}

Write-Host "Extracting TensorRT to $TensorRtRoot..."
# $null result = flat-layout zip (no TensorRT-* subdir), a legitimate NVIDIA packaging.
$trtDir = Expand-ArchiveSubdirectory -ArchivePath $trtZip -DestinationPath $TensorRtRoot -Filter 'TensorRT-*'
if ($trtZip -ne $LocalZipPath -and $trtZip -notlike (Join-Path $env:TEMP_DIR 'downloads\*')) { Remove-Item $trtZip -Force -ErrorAction SilentlyContinue }

if ($trtDir) {
    Write-Host "TensorRT installed at: $trtDir"
    [Environment]::SetEnvironmentVariable('TENSORRT_ROOT', $trtDir, 'Process')
    # Also expose via MSBuild/CMake convention
    [Environment]::SetEnvironmentVariable('TENSORRT_ROOT_DIR', $trtDir, 'Process')
} else {
    Write-Host "TensorRT installed at: $TensorRtRoot"
    [Environment]::SetEnvironmentVariable('TENSORRT_ROOT', $TensorRtRoot, 'Process')
}

Write-Host 'TensorRT installation complete.'
