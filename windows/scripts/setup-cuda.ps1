# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

param(
    [string]$TempDir = 'C:\temp',
    [string]$CudaVersion = '',
    [string]$CudaVersionMajorMinor = '',
    [string]$CudnnVersion = '',
    [string]$CudnnRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through WindowsContainerImage.Common's re-export.

$CudaVersion = Resolve-ContainerImageValue -Value $CudaVersion -EnvironmentVariable 'CUDA_VERSION'
$CudaVersionMajorMinor = Resolve-ContainerImageValue -Value $CudaVersionMajorMinor -EnvironmentVariable 'CUDA_VERSION_MAJOR_MINOR'
$CudnnVersion = Resolve-ContainerImageValue -Value $CudnnVersion -EnvironmentVariable 'CUDNN_VERSION'
$CudnnRoot = Resolve-ContainerImageValue -Value $CudnnRoot -EnvironmentVariable 'CUDNN_ROOT' -DefaultValue ('C:\Program Files\NVIDIA\CUDNN\v{0}' -f $CudnnVersion)

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

# Use NVIDIA's full CUDA installer (not Scoop -- Scoop's portable install strips CCCL headers).
# The full installer includes CUB, Thrust, libcudacxx at include/cccl/ and a proper nv/target.h.
Write-Host ('Installing CUDA Toolkit {0} via NVIDIA full installer...' -f $CudaVersion)
$cudaUrl = "https://developer.download.nvidia.com/compute/cuda/$CudaVersion/local_installers/cuda_$CudaVersion`_windows.exe"
Write-Host "Download URL: $cudaUrl"
$cudaInstaller = Join-Path $TempDir 'cuda_installer.exe'
Invoke-DownloadWithRetry -Url $cudaUrl -DestinationPath $cudaInstaller -Description "CUDA Toolkit $CudaVersion installer" -ExpectSignature MZ
Write-Host 'Installing CUDA Toolkit (full silent install, no driver)...'
$proc = Start-Process -FilePath $cudaInstaller -ArgumentList '-s', '--no-download-driver' -Wait -PassThru
$proc.WaitForExit()
$exitCode = $proc.ExitCode
$proc.Dispose()
Clear-PendingFileHandle
Remove-Item $cudaInstaller -Force
if ($exitCode -ne 0) {
    throw ('CUDA installation failed with exit code: {0}' -f $exitCode)
}
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
    Write-Host 'WARNING: CCCL cub/cub.cuh not found -- CUDA installer may not have included CCCL.'
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

Write-Host ('Downloading cuDNN {0}...' -f $CudnnVersion)
$cudaMajorVersion = $CudaVersionMajorMinor -replace '[^0-9].*', ''
$cudnnUrl = 'https://developer.download.nvidia.com/compute/cudnn/redist/cudnn/windows-x86_64/cudnn-windows-x86_64-{0}_cuda{1}-archive.zip' -f $CudnnVersion, $cudaMajorVersion
Write-Host ('Download URL: {0}' -f $cudnnUrl)
$cudnnArchive = Join-Path $TempDir 'cudnn.zip'
$cudnnExtracted = Join-Path $TempDir 'cudnn_extracted'
Invoke-DownloadWithRetry -Url $cudnnUrl -DestinationPath $cudnnArchive -Description "cuDNN $CudnnVersion archive" -ExpectSignature PK
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
$cudnnHeaders = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn.h' -Recurse -ErrorAction SilentlyContinue
$cudnnLibs = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.lib' -Recurse -ErrorAction SilentlyContinue
$cudnnDlls = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue
if (-not $cudnnHeaders) { throw "cuDNN headers (cudnn.h) not found under $CudnnRoot" }
if (-not $cudnnLibs) { throw "cuDNN import libs (cudnn*.lib) not found under $CudnnRoot" }
if (-not $cudnnDlls) { throw "cuDNN DLLs (cudnn*.dll) not found under $CudnnRoot" }
Write-Host ('cuDNN verified: {0} headers, {1} libs, {2} DLLs' -f $cudnnHeaders.Count, $cudnnLibs.Count, $cudnnDlls.Count)
Write-Host 'cuDNN installation complete.'

# Final push to release any lingering file handles before layer commit.
# (The installer/archive files themselves were already removed right after use above.)
Clear-PendingFileHandle

