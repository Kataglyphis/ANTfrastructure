# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$TensorRtVersion = '',
    [string]$TensorRtRoot = '',
    [string]$LocalZipPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) { throw "Required module not found: $sharedModulePath" }
Import-Module $sharedModulePath -Force
# For Assert-FileSha256, which WindowsContainerImage.Common does not re-export.
$sharedHelpersPath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedHelpersPath }
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through WindowsContainerImage.Common's re-export.

$TensorRtVersion = Resolve-ContainerImageValue -Value $TensorRtVersion -EnvironmentVariable 'TENSORRT_VERSION' -DefaultValue ''
$TensorRtRoot = Resolve-ContainerImageValue -Value $TensorRtRoot -EnvironmentVariable 'TENSORRT_ROOT' -DefaultValue 'C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT'

# The newest *TensorRT*.zip by filename version, or $null: drift is resolved forward, never to an older zip.
function Find-TensorRtZipIn {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $found = Get-ChildItem (Join-Path $Dir '*TensorRT*.zip') -ErrorAction SilentlyContinue |
        Sort-Object -Property @{ Expression = {
                if ($_.Name -match 'TensorRT-(?:[A-Za-z]+-)?(\d+(?:\.\d+)+)') { [version]$Matches[1] } else { [version]'0.0' }
            } } -Descending |
        Select-Object -First 1
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
    # The first URL follows the CUDA pin; all are auth-gated guesses that may 404.
    $cudaSuffix = Resolve-ContainerImageValue -EnvironmentVariable 'CUDA_VERSION_MAJOR_MINOR' -DefaultValue '13.4'
    $urls = @(
        "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-$cudaSuffix.zip",
        "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-13.0.zip",
        "https://developer.download.nvidia.com/compute/tensorrt/$dirVersion/tensorrt-$TensorRtVersion.Windows10.x86_64.cuda-12.8.zip"
    ) | Select-Object -Unique
    $downloaded = $false
    foreach ($url in $urls) {
        Write-Host "Trying download: $url"
        # PK rejects NVIDIA's login HTML page, so a guess falls through instead of extracting garbage.
        try { Invoke-DownloadWithRetry -Url $url -DestinationPath $trtZip -MaxAttempts 1 -InitialDelaySeconds 0 -ExpectSignature PK -Description "TensorRT $TensorRtVersion"; $downloaded = $true; break }
        catch { Write-Host "  Failed: $($_.Exception.Message)" }
    }
    if (-not $downloaded) {
        # Graceful skip: no zip is a supported configuration, and ORT skips the TensorRT EP on an empty root.
        Write-Warning ('TensorRT {0} not available (EULA-gated download; no zip staged in windows\downloads). Continuing WITHOUT TensorRT — CUDA + cuDNN still work, the ORT TensorRT EP stays disabled. To include it: place tensorrt-*.zip in windows\downloads\ or pass -LocalZipPath / set TENSORRT_ZIP_PATH.' -f $TensorRtVersion)
        return
    }
}

if (-not $trtZip -or -not (Test-Path $trtZip)) {
    # Same graceful-skip contract as above.
    Write-Warning 'No TensorRT zip found -- continuing WITHOUT TensorRT (CUDA + cuDNN still work). Stage the EULA-gated tensorrt-*.zip in windows\downloads\ to include it.'
    return
}

# Whichever tier found the zip, it must match the pin; an empty pin warns, a mismatch throws.
$trtSha = Resolve-ContainerImageValue -EnvironmentVariable 'TENSORRT_ZIP_SHA256' -DefaultValue ''
Assert-FileSha256 -Path $trtZip -Expected $trtSha -Label 'TensorRT zip' -PinName 'TENSORRT_ZIP_SHA256'

Write-Host "Extracting TensorRT to $TensorRtRoot..."
# $null result = flat-layout zip (no TensorRT-* subdir), a legitimate NVIDIA packaging.
$trtDir = Expand-ArchiveSubdirectory -ArchivePath $trtZip -DestinationPath $TensorRtRoot -Filter 'TensorRT-*'
if ($trtZip -ne $LocalZipPath -and $trtZip -notlike (Join-Path $env:TEMP_DIR 'downloads\*')) { Remove-Item $trtZip -Force -ErrorAction SilentlyContinue }

# Process scope only; the image's TENSORRT_ROOT is the Dockerfile ENV, which must match this layout.
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

