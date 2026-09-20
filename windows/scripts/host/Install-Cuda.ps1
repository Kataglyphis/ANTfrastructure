# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$TempDir = 'C:\temp',
    [string]$CudaVersion = '',
    [string]$CudaVersionMajorMinor = '',
    [string]$CudnnVersion = '',
    [string]$CudnnRoot = '',
    [string]$TargetArch = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through WindowsContainerImage.Common's re-export.

$CudaVersion = Resolve-ContainerImageValue -Value $CudaVersion -EnvironmentVariable 'CUDA_VERSION'
$CudaVersionMajorMinor = Resolve-ContainerImageValue -Value $CudaVersionMajorMinor -EnvironmentVariable 'CUDA_VERSION_MAJOR_MINOR'
$CudnnVersion = Resolve-ContainerImageValue -Value $CudnnVersion -EnvironmentVariable 'CUDNN_VERSION'
$CudnnRoot = Resolve-ContainerImageValue -Value $CudnnRoot -EnvironmentVariable 'CUDNN_ROOT' -DefaultValue ('C:\Program Files\NVIDIA\CUDNN\v{0}' -f $CudnnVersion)
$TargetArch = Resolve-ContainerImageValue -Value $TargetArch -EnvironmentVariable 'WINDOWS_TARGET_ARCH' -DefaultValue 'amd64'

<#
.SYNOPSIS
    Stages the Windows-arm64 CUDA payload into an existing CUDA root.
.DESCRIPTION
    NVIDIA publishes the arm64 toolkit ONLY as per-component redist archives (no
    runnable installer), so the cross lane downloads each component by SHA into
    the SAME root the x64 toolkit uses: headers and nvcc stay x64 (host tools),
    the arm64 libs/bin land in lib\arm64 / bin\arm64 -- exactly where
    `nvcc -ccbin <arm64 cl>` and CMake's FindCUDAToolkit look. Probe-proven
    2026-09-19 (out/probe-cuda-cross2: AA64 main.exe). The component set is the
    ORT CUDA EP's link closure plus its runtime dlopens; docs/windows-cross-builds.md
    owns the why, versions.env owns the pins.
#>
function Install-CudaWindowsArm64Redist {
    param(
        [Parameter(Mandatory)][string]$CudaRoot,
        [Parameter(Mandatory)][string]$TempDir
    )
    $components = @(
        @{ Key = 'CUDART'; Component = 'cuda_cudart' },
        @{ Key = 'CUBLAS'; Component = 'libcublas' },
        @{ Key = 'CUFFT'; Component = 'libcufft' },
        @{ Key = 'CURAND'; Component = 'libcurand' },
        @{ Key = 'NVJITLINK'; Component = 'libnvjitlink' }
    )
    foreach ($c in $components) {
        $verKey = "CUDA_WINDOWS_ARM64_$($c.Key)_VERSION"
        $shaKey = "CUDA_WINDOWS_ARM64_$($c.Key)_SHA256"
        $ver = Resolve-ContainerImageValue -EnvironmentVariable $verKey -DefaultValue ''
        $sha = Resolve-ContainerImageValue -EnvironmentVariable $shaKey -DefaultValue ''
        if (-not $ver) { throw "$verKey is not set -- the arm64 CUDA payload cannot be pinned" }
        $url = 'https://developer.download.nvidia.com/compute/cuda/redist/{0}/windows-arm64/{0}-windows-arm64-{1}-archive.zip' -f $c.Component, $ver
        $zip = Join-Path $TempDir ("{0}-arm64.zip" -f $c.Component)
        $extract = Join-Path $TempDir ("{0}-arm64" -f $c.Component)
        Invoke-DownloadWithRetry -Url $url -DestinationPath $zip -Description ("CUDA arm64 {0}" -f $c.Component) -ExpectSignature PK -ExpectedSha256 $sha
        $dir = Expand-ArchiveSubdirectory -ArchivePath $zip -DestinationPath $extract
        if (-not $dir) { throw "Extracted arm64 component directory not found under $extract" }
        # lib\arm64 + bin\arm64 only: the headers are arch-neutral and already come
        # from the x64 toolkit install above (copying component headers over them
        # could mix per-component versions with the toolkit's).
        foreach ($pair in @(@{ From = 'lib\arm64'; To = 'lib\arm64' }, @{ From = 'bin\arm64'; To = 'bin\arm64' })) {
            $from = Join-Path $dir $pair.From
            if (-not (Test-Path $from)) { continue }
            $to = Join-Path $CudaRoot $pair.To
            New-Item -ItemType Directory -Force $to | Out-Null
            Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
        }
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Assert the exact files the cross link needs: a silently empty copy would
    # otherwise surface hours later as an ORT link error.
    foreach ($must in @('lib\arm64\cudart.lib', 'lib\arm64\cudadevrt.lib', 'lib\arm64\cublas.lib', 'lib\arm64\cublasLt.lib', 'lib\arm64\curand.lib')) {
        if (-not (Test-Path (Join-Path $CudaRoot $must))) {
            throw ("arm64 CUDA payload incomplete: {0} missing under {1}" -f $must, $CudaRoot)
        }
    }
    Write-Host ("arm64 CUDA payload staged into {0} (lib\arm64, bin\arm64)" -f $CudaRoot)
}

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

# Use NVIDIA's full CUDA installer (not Scoop -- Scoop's portable install strips CCCL headers).
# The full installer includes CUB, Thrust, libcudacxx at include/cccl/ and a proper nv/target.h.
Write-Host ('Installing CUDA Toolkit {0} via NVIDIA full installer...' -f $CudaVersion)
# 13.4+ uses the NETWORK installer with a pinned subpackage list: the 3.9 GB
# full installer dies in-container with 0xE0E00064 (self-extraction on the
# wcifs layer; reproduced 2026-09-19, silent, no logs), while the network
# installer installs the same toolkit in ~2 min. Older pins keep the full
# installer. `thrust_*` carries the CCCL headers (include\cccl).
$cudaNetworkInstaller = [version]$CudaVersion -ge [version]'13.4'
if ($cudaNetworkInstaller) {
    $cudaPkgs = @(
        'crt', 'ctadvisor', 'cublas', 'cublas_dev', 'cuda_profiler_api', 'cudart',
        'cufft', 'cufft_dev', 'cuobjdump', 'cupti', 'curand', 'curand_dev',
        'cusolver', 'cusolver_dev', 'cusparse', 'cusparse_dev', 'cuxxfilt',
        'npp', 'npp_dev', 'nvcc', 'nvdisasm', 'nvfatbin', 'nvjitlink', 'nvjpeg',
        'nvjpeg_dev', 'nvml_dev', 'nvprune', 'nvptxcompiler', 'nvrtc', 'nvrtc_dev',
        'nvtx', 'nvvm', 'occupancy_calculator', 'opencl', 'sanitizer', 'thrust', 'tileiras'
    ) | ForEach-Object { "${_}_$($CudaVersionMajorMinor)" }
    $cudaUrl = "https://developer.download.nvidia.com/compute/cuda/$CudaVersion/network_installers/cuda_${CudaVersion}_windows_x86_64_network.exe"
    $cudaArgs = @('-s') + $cudaPkgs
} else {
    $cudaInstallerName = "cuda_${CudaVersion}_windows.exe"
    $cudaUrl = "https://developer.download.nvidia.com/compute/cuda/$CudaVersion/local_installers/$cudaInstallerName"
    $cudaArgs = @('-s', '--no-download-driver')
}
Write-Host "Download URL: $cudaUrl"
$cudaInstaller = Join-Path $TempDir 'cuda_installer.exe'
# SHA256 pin from versions.env (CUDA_INSTALLER_SHA256, baked env); empty skips.
$cudaSha = Resolve-ContainerImageValue -EnvironmentVariable 'CUDA_INSTALLER_SHA256' -DefaultValue ''
Invoke-DownloadWithRetry -Url $cudaUrl -DestinationPath $cudaInstaller -Description "CUDA Toolkit $CudaVersion installer" -ExpectSignature MZ -ExpectedSha256 $cudaSha
Write-Host 'Installing CUDA Toolkit (silent install, no driver)...'
$proc = Start-Process -FilePath $cudaInstaller -ArgumentList $cudaArgs -Wait -PassThru
$proc.WaitForExit()
$exitCode = $proc.ExitCode
$proc.Dispose()
Clear-PendingFileHandle
# Check the exit code BEFORE removing the installer: on failure keep it for
# analysis (same deliberate preservation as Install-Vs.ps1's finally block).
if ($exitCode -ne 0) {
    Write-Host "Installer was not deleted (left for analysis at $cudaInstaller)."
    throw ('CUDA installation failed with exit code: {0}' -f $exitCode)
}
# -ErrorAction SilentlyContinue: the installer occasionally still holds its own
# file handle for a moment after exit; a failed cleanup must not fail the layer.
Remove-Item $cudaInstaller -Force -ErrorAction SilentlyContinue
Write-Host 'CUDA Toolkit installation complete. Waiting for files to settle...'
Start-Sleep -Seconds 5
Clear-PendingFileHandle

# Full installer puts CUDA at Program Files
$cudaInstallRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA"
Write-Host "Listing $cudaInstallRoot ..."
Get-ChildItem $cudaInstallRoot -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  Found: $_" }

$effectiveCudaRoot = "$cudaInstallRoot\v$($CudaVersionMajorMinor -replace '-', '.')"
if (-not (Test-Path (Join-Path $effectiveCudaRoot 'bin\nvcc.exe'))) {
    Write-Host "nvcc.exe not found at $effectiveCudaRoot, searching..."
    $nvcc = Get-ChildItem "$cudaInstallRoot\*\bin\nvcc.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nvcc) {
        $effectiveCudaRoot = $nvcc.Directory.Parent.FullName
        Write-Host "Found nvcc at alternate path: $effectiveCudaRoot"
    } else {
        throw "nvcc.exe not found anywhere under $cudaInstallRoot after full installer"
    }
}
Write-Host "CUDA root: $effectiveCudaRoot"

[Environment]::SetEnvironmentVariable('CUDA_ROOT', $effectiveCudaRoot, 'Process')
[Environment]::SetEnvironmentVariable('CUDA_PATH', $effectiveCudaRoot, 'Process')
$cudaBinDir = Join-Path $effectiveCudaRoot 'bin'
$env:PATH = "$cudaBinDir;$env:PATH"
Write-Host "Set CUDA_ROOT to: $effectiveCudaRoot"
Get-ChildItem -Path "$effectiveCudaRoot\bin" -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { Write-Host "  CUDA bin: $_" }

# Full installer includes CCCL headers (cub, thrust, libcudacxx) at include/cccl/.
# Just verify they're present.
$cudaIncludeDir = "$effectiveCudaRoot\include"
$ccclDir = Join-Path $cudaIncludeDir 'cccl'
if (Test-Path (Join-Path $ccclDir 'cub\cub.cuh')) {
    Write-Host 'CCCL headers verified present (cub/cub.cuh found).'
} else {
    # CCCL presence is the whole reason the full installer is used over Scoop
    # (see the comment at the top of this script) -- missing CCCL is fatal.
    throw "CCCL cub/cub.cuh not found under $ccclDir -- the full CUDA installer did not deliver CCCL; downstream CUB/Thrust builds would fail hours later."
}

# nv/target.h: the full installer provides a proper version that handles both
# host and device compilation (selects device branch when __CUDA_ARCH__ is defined).
# Only create a stub if the file is completely missing.
$nvDir = Join-Path $cudaIncludeDir 'nv'
if (-not (Test-Path $nvDir)) { New-Item -Path $nvDir -ItemType Directory -Force | Out-Null }
$nvTargetLines = @(
    '#pragma once',
    '#define NV_IS_DEVICE 0',
    '#define NV_IS_HOST 1',
    '#define NV_IF_ELSE_TARGET(cond,t,f) f',
    '#define NV_IF_TARGET(arch, ...) _NV_IF_TARGET_HOST(__VA_ARGS__)',
    '#define _NV_IF_TARGET_HOST(device, ...) __VA_ARGS__',
    '#define NV_PROVIDES_SM_70 0',
    '#define NV_PROVIDES_SM_80 0',
    '#define NV_PROVIDES_SM_90 0',
    '#define NV_PROVIDES_SM_61 0'
)
foreach ($targetFile in @((Join-Path $nvDir 'target.h'), (Join-Path $nvDir 'target'))) {
    if (-not (Test-Path $targetFile)) {
        Set-Content -Path $targetFile -Value $nvTargetLines -Encoding ASCII
        Write-Host "Created stub: $targetFile (host-only fallback)"
    } else {
        Write-Host "Using installer-provided: $targetFile"
    }
}

# CRT stubs (only if missing -- full installer should have them)
if (-not (Test-Path (Join-Path $cudaIncludeDir 'crt\host_config.h'))) {
    $crtDir = Join-Path $cudaIncludeDir 'crt'
    if (-not (Test-Path $crtDir)) { New-Item -Path $crtDir -ItemType Directory -Force | Out-Null }
    Set-Content -Path (Join-Path $crtDir 'host_config.h') -Value '#pragma once' -Encoding ASCII
    Write-Host 'Created stub: crt/host_config.h'
}

if ($TargetArch -ne 'amd64') {
    if ($TargetArch -ne 'arm64') { throw "Install-Cuda: no CUDA payload mapping for -TargetArch $TargetArch (amd64 and arm64 only)" }
    Write-Host 'Cross lane: staging the Windows-arm64 CUDA redist payload (lib\arm64, bin\arm64)...'
    Install-CudaWindowsArm64Redist -CudaRoot $effectiveCudaRoot -TempDir $TempDir
}

Write-Host ('Downloading cuDNN {0}...' -f $CudnnVersion)
$cudaMajorVersion = $CudaVersionMajorMinor -replace '[^0-9].*', ''
# NVIDIA's redist naming is NOT uniform: x64 is `..._cuda13-archive.zip`, arm64 is
# `..._cuda13.4-archive.zip` (verified in redistrib_9.26.0.json, 2026-09-20).
if ($TargetArch -eq 'amd64') {
    $cudnnPlatform = 'windows-x86_64'
    $cudnnUrl = 'https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/{0}/cudnn-{0}-{1}_cuda{2}-archive.zip' -f $cudnnPlatform, $CudnnVersion, $cudaMajorVersion
    $cudnnShaKey = 'CUDNN_ZIP_SHA256'
} else {
    $cudnnPlatform = 'windows-arm64'
    $cudnnUrl = 'https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/{0}/cudnn-{0}-{1}_cuda{2}-archive.zip' -f $cudnnPlatform, $CudnnVersion, $CudaVersionMajorMinor
    $cudnnShaKey = 'CUDNN_WINDOWS_ARM64_ZIP_SHA256'
}
Write-Host ('Download URL: {0}' -f $cudnnUrl)
$cudnnArchive = Join-Path $TempDir 'cudnn.zip'
$cudnnExtracted = Join-Path $TempDir 'cudnn_extracted'
# SHA256 from NVIDIA's redist manifest, pinned in versions.env (CUDNN_ZIP_SHA256,
# CUDNN_WINDOWS_ARM64_ZIP_SHA256 on the cross lane).
$cudnnSha = Resolve-ContainerImageValue -EnvironmentVariable $cudnnShaKey -DefaultValue ''
Invoke-DownloadWithRetry -Url $cudnnUrl -DestinationPath $cudnnArchive -Description "cuDNN $CudnnVersion archive" -ExpectSignature PK -ExpectedSha256 $cudnnSha
Write-Host 'Extracting cuDNN...'
$cudnnDir = Expand-ArchiveSubdirectory -ArchivePath $cudnnArchive -DestinationPath $cudnnExtracted
if (-not $cudnnDir) {
    throw ('Extracted cuDNN directory not found under {0}' -f $cudnnExtracted)
}
New-Item -Path $CudnnRoot -ItemType Directory -Force | Out-Null
Copy-Item -Path (Join-Path $cudnnDir '*') -Destination $CudnnRoot -Recurse -Force
Remove-Item $cudnnArchive -Force
Remove-Item $cudnnExtracted -Recurse -Force

# Verify cuDNN installation
Write-Host 'Verifying cuDNN installation...'
# @(...) so a single FileInfo result still exposes .Count (scalar trap).
$cudnnHeaders = @(Get-ChildItem -Path $CudnnRoot -Filter 'cudnn.h' -Recurse -ErrorAction SilentlyContinue)
$cudnnLibs = @(Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.lib' -Recurse -ErrorAction SilentlyContinue)
$cudnnDlls = @(Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue)
if (-not $cudnnHeaders) { throw "cuDNN headers (cudnn.h) not found under $CudnnRoot" }
if (-not $cudnnLibs) { throw "cuDNN import libs (cudnn*.lib) not found under $CudnnRoot" }
if (-not $cudnnDlls) { throw "cuDNN DLLs (cudnn*.dll) not found under $CudnnRoot" }
Write-Host ('cuDNN verified: {0} headers, {1} libs, {2} DLLs' -f $cudnnHeaders.Count, $cudnnLibs.Count, $cudnnDlls.Count)
Write-Host 'cuDNN installation complete.'

# Final push to release any lingering file handles before layer commit.
# (The installer/archive files themselves were already removed right after use above.)
Clear-PendingFileHandle

