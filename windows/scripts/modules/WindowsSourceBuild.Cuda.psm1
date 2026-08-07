# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# GPU/CUDA detection utilities for Windows container builds.
# Extracted from WindowsSourceBuild.Common.psm1 to reduce module size.
# Single source of truth for all GPU environment detection across
# ONNX Runtime, GenAI, OpenCV, LiteRT, TVM, and GStreamer builds.

Set-StrictMode -Version Latest
#requires -Version 7.0


# Guarded, WITHOUT -Force (repo-wide nested-import rule): a forced nested
# re-import rebinds Shared into this module's private scope and unloads the
# caller's top-level import (the PS module-scoping trap).
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

function Get-CudaRoot {
    if ($env:CUDA_ROOT -and (Test-Path $env:CUDA_ROOT)) { return $env:CUDA_ROOT }
    if ($env:CUDA_PATH -and (Test-Path $env:CUDA_PATH)) { return $env:CUDA_PATH }
    return $null
}

function Resolve-TensorRtRoot {
    $trtRoot = $env:TENSORRT_ROOT
    if (-not $trtRoot) { return $null }
    if (-not (Test-Path $trtRoot)) { return $null }
    if (-not (Get-ChildItem $trtRoot -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $null }
    $trtVerDir = Get-ChildItem "$trtRoot\TensorRT-*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($trtVerDir) { return $trtVerDir.FullName }
    return $trtRoot
}

function Get-GpuEnvironment {
    param([string]$ForceCpuEnvVar)
    if ($ForceCpuEnvVar -and ([Environment]::GetEnvironmentVariable($ForceCpuEnvVar) -eq '1')) {
        Write-Host "$ForceCpuEnvVar=1 -> CPU-only build (GPU detection overridden; CUDA/TensorRT/cuDNN skipped)"
        return @{ GpuType = 'cpu'; CudaRoot = $null; CudnnRoot = $null; TensorRtRoot = $null; CudaBin = $null }
    }
    $gpuType = if ($env:GPU_TYPE) { $env:GPU_TYPE.ToLowerInvariant() } else { 'cpu' }
    $cudaRoot = Get-CudaRoot
    $cudnnRoot = $env:CUDNN_ROOT
    $trtRoot = Resolve-TensorRtRoot
    $cudaBin = if ($cudaRoot) { Join-Path $cudaRoot 'bin' } else { $null }

    if ($gpuType -eq 'nvidia' -and $cudaRoot -and (Test-Path $cudaRoot)) {
        if ($cudaBin -and (Test-Path $cudaBin) -and ($env:PATH -notlike "*$cudaBin*")) {
            $env:PATH = "$cudaBin;$env:PATH"
        }
        if ($env:CUDA_PATH -ne $cudaRoot) { $env:CUDA_PATH = $cudaRoot }
        if ($env:CUDA_HOME -ne $cudaRoot) { $env:CUDA_HOME = $cudaRoot }
    }

    return @{
        GpuType       = $gpuType
        CudaRoot      = $cudaRoot
        CudnnRoot     = $cudnnRoot
        TensorRtRoot  = $trtRoot
        CudaBin       = $cudaBin
    }
}

function Get-CudaArchitectureList {
    param(
        [string]$Decoration = ''
    )
    $archs = if (-not [string]::IsNullOrWhiteSpace($env:CUDA_ARCHITECTURES)) { $env:CUDA_ARCHITECTURES } else { '80;86;89;90' }
    if ($Decoration) {
        return (($archs -split ';' | Where-Object { $_ } | ForEach-Object { "$_$Decoration" }) -join ';')
    }
    return $archs
}

function Get-CudaToolkitRootArg {
    param(
        [Parameter(Mandatory)]
        [hashtable]$GpuEnv,
        [switch]$ForwardSlash
    )
    if (-not $GpuEnv.CudaRoot) { return @() }
    $root = if ($ForwardSlash) { $GpuEnv.CudaRoot -replace '\\', '/' } else { $GpuEnv.CudaRoot }
    return @("-DCUDA_TOOLKIT_ROOT_DIR=$root")
}

function Get-CudnnLibrary {
    param(
        [string]$CudnnRoot
    )
    if ([string]::IsNullOrWhiteSpace($CudnnRoot)) { return $null }
    $libDir = "$CudnnRoot\lib\x64"
    if (-not (Test-Path -LiteralPath $libDir -ErrorAction SilentlyContinue)) { return $null }
    $lib = Get-ChildItem -LiteralPath $libDir -Filter 'cudnn*.lib' -ErrorAction SilentlyContinue |
        Sort-Object { $_.Name -ne 'cudnn.lib' } | Select-Object -First 1
    if ($lib) { return $lib.FullName }
    return $null
}

function Get-NvccCudaCmakeArgs {
    param(
        [Parameter(Mandatory)][string]$CudaRoot,
        [Parameter(Mandatory)][ValidateSet('17', '20')][string]$CudaStandard,
        [string]$ExtraCudaFlags = '',
        [switch]$IncludeToolkitRoot,
        [string]$ArchDecoration = '-real'
    )
    $clExe = (Get-Command cl.exe -ErrorAction Stop).Source
    $preamble = '-Xcompiler=/Zc:preprocessor --compiler-options /Zc:preprocessor -DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING'
    $cudaFlags = if ($ExtraCudaFlags) { "$ExtraCudaFlags $preamble" } else { $preamble }
    $nvccArgs = @(
        "-DCMAKE_CUDA_COMPILER:FILEPATH=$CudaRoot\bin\nvcc.exe"
        "-DCMAKE_CUDA_HOST_COMPILER:FILEPATH=$clExe"
        "-DCMAKE_CUDA_ARCHITECTURES=$(Get-CudaArchitectureList -Decoration $ArchDecoration)"
        "-DCMAKE_CUDA_STANDARD:STRING=$CudaStandard"
        "-DCMAKE_CUDA_FLAGS:STRING=$cudaFlags"
    )
    if ($IncludeToolkitRoot) { $nvccArgs += "-DCUDA_TOOLKIT_ROOT_DIR=$CudaRoot" }
    return $nvccArgs
}

Export-ModuleMember -Function @(
    'Get-CudaRoot',
    'Resolve-TensorRtRoot',
    'Get-GpuEnvironment',
    'Get-CudaArchitectureList',
    'Get-CudaToolkitRootArg',
    'Get-CudnnLibrary',
    'Get-NvccCudaCmakeArgs',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)

