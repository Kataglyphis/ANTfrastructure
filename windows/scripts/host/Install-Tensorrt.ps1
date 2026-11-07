# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$TensorRtVersion = '',
    [string]$TensorRtRoot = '',
    [string]$LocalZipPath = '',
    [string]$ModuleRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

Import-Module (Join-Path $ModuleRoot 'modules\WindowsContainerImage.Bootstrap.psm1') -Force
Import-Module (Resolve-ContainerImageModulePath -ModuleRoot $ModuleRoot -Name 'WindowsContainerImage.Common.psm1') -Force
# For Assert-FileSha256, which WindowsContainerImage.Common does not re-export.
$sharedHelpersPath = Resolve-ContainerImageModulePath -ModuleRoot $ModuleRoot -Name 'WindowsScripts.Shared.psm1'
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

function Find-TensorRtStagedZip {
    param([Parameter(Mandatory)][string]$RepoDir, [string]$PublicDir = 'C:\Users\Public\Downloads')
    foreach ($dir in @($RepoDir, $PublicDir)) {
        $zip = Find-TensorRtZipIn -Dir $dir
        if ($zip) {
            Write-Host "Found TensorRT zip at: $zip"
            return $zip
        }
    }
    return $null
}

function Get-TensorRtZipUrl {
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Cuda)
    $parts = $Version.Split('.')
    $dirVersion = if ($parts.Length -ge 3) { "$($parts[0]).$($parts[1]).$($parts[2])" } else { $Version }
    return "https://developer.nvidia.com/downloads/compute/machine-learning/tensorrt/$dirVersion/zip/TensorRT-Enterprise-$Version-Windows-amd64-cuda-$Cuda-Release-external.zip"
}

function Invoke-TensorRtZipDownload {
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Destination)
    # Only the image's CUDA line: a zip built for another CUDA major links a cudart the image does not carry.
    $cuda = Resolve-ContainerImageValue -EnvironmentVariable 'CUDA_VERSION_MAJOR_MINOR' -DefaultValue '13.4'
    $url = Get-TensorRtZipUrl -Version $Version -Cuda $cuda
    Write-Host "Downloading TensorRT: $url"
    # PK rejects an HTML licence page, so a changed NVIDIA scheme fails here instead of extracting garbage.
    try {
        Invoke-DownloadWithRetry -Url $url -DestinationPath $Destination -MaxAttempts 3 -InitialDelaySeconds 10 -ExpectSignature PK -Description "TensorRT $Version"
        return $true
    } catch {
        Write-Host "  Failed: $($_.Exception.Message)"
        return $false
    }
}

function Resolve-TensorRtZip {
    param([string]$LocalZipPath, [Parameter(Mandatory)][string]$RepoDir, [string]$Version, [Parameter(Mandatory)][string]$Destination)
    if ($LocalZipPath -and (Test-Path -LiteralPath $LocalZipPath)) {
        Write-Host "Using TensorRT zip from: $LocalZipPath"
        return $LocalZipPath
    }
    $staged = Find-TensorRtStagedZip -RepoDir $RepoDir
    if ($staged) { return $staged }
    if (-not $Version) { throw 'TensorRT: TENSORRT_VERSION is empty and no zip is staged; the nvidia lane needs TensorRT.' }
    # A missing TensorRT once shipped silently as a CUDA-only image; see docs/windows-cross-builds.md § TensorRT.
    if (-not (Invoke-TensorRtZipDownload -Version $Version -Destination $Destination)) {
        throw "TensorRT $Version could not be downloaded and no zip is staged in windows\downloads; the nvidia lane needs TensorRT."
    }
    return $Destination
}

$trtZip = Resolve-TensorRtZip -LocalZipPath $LocalZipPath -RepoDir (Join-Path $env:TEMP_DIR 'downloads') -Version $TensorRtVersion -Destination (Join-Path $env:TEMP 'tensorrt.zip')

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

