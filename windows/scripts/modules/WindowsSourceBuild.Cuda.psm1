#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# GPU/CUDA detection utilities for Windows container builds.
# Extracted from WindowsSourceBuild.Common.psm1 to reduce module size.
# Single source of truth for all GPU environment detection across
# ONNX Runtime, GenAI, OpenCV, LiteRT, TVM, and GStreamer builds.

Set-StrictMode -Version Latest

# Guarded, WITHOUT -Force (repo-wide nested-import rule): a forced nested
# re-import rebinds Shared into this module's private scope and unloads the
# caller's top-level import (the PS module-scoping trap).
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }
# Arch facts (#176): the CUDA helpers below must resolve the TARGET arch (which
# lib\ dir cuDNN lives in, which cl.exe nvcc drives), and this module must stay
# usable when only it is imported (tests). Guarded, same rule as above.
$targetArchPath = Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1'
if (-not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $targetArchPath }

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
    # 'current' first (backlog #38): Set-TensorrtTree.ps1 renames the
    # extracted TensorRT-<version> tree to a stable name so the Dockerfile's
    # runtime PATH can reference it WITHOUT spelling the pin — deriving that
    # path from TENSORRT_VERSION is what silently killed the EP when the pin
    # and the staged zip disagreed. The versioned glob stays as the fallback so
    # pre-normalization images and host-lane trees keep resolving.
    $stable = Join-Path $trtRoot 'current'
    if (Test-Path $stable) { return $stable }
    $trtVerDir = Get-ChildItem "$trtRoot\TensorRT-*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($trtVerDir) { return $trtVerDir.FullName }
    return $trtRoot
}

function Get-GpuEnvironment {
    param([string]$ForceCpuEnvVar)
    if ($ForceCpuEnvVar -and ([Environment]::GetEnvironmentVariable($ForceCpuEnvVar) -eq '1')) {
        Write-Host "$ForceCpuEnvVar=1 -> CPU-only build (GPU detection overridden; CUDA/TensorRT/cuDNN skipped)"
        return @{ GpuType = 'cpu'; CudaRoot = $null; CudnnRoot = $null; TensorRtRoot = $null; CudaBin = $null; HasCuda = $false }
    }
    $gpuType = if ($env:GPU_TYPE) { $env:GPU_TYPE.ToLowerInvariant() } else { 'cpu' }
    $cudaRoot = Get-CudaRoot
    $cudnnRoot = $env:CUDNN_ROOT
    $trtRoot = Resolve-TensorRtRoot
    $cudaBin = if ($cudaRoot) { Join-Path $cudaRoot 'bin' } else { $null }

    # FAIL CLOSED on the nvidia lane (#45): GPU_TYPE=nvidia is BAKED into the
    # image (Dockerfile.nvidia), so "lane says nvidia but no CUDA root" is
    # never legitimate - it is a mis-plumbed path, and every consumer would
    # take its quiet CPU-only else-branch (onnx "CPU-only build", opencv
    # WITH_CUDA=OFF, tvm silently), yielding ~2.5 h of green-and-useless
    # stages. Deliberate CPU builds go through the ForceCpuEnvVar opt-outs
    # (ONNX_FORCE_CPU & friends), which return above and never reach this.
    if ($gpuType -eq 'nvidia' -and (-not $cudaRoot -or -not (Test-Path $cudaRoot))) {
        throw ("GPU_TYPE=nvidia but no CUDA toolkit found (CudaRoot='$cudaRoot') - " +
            'a mis-plumbed CUDA path would silently produce a CPU-only image (backlog #45). ' +
            'For a deliberate CPU build use the per-component FORCE_CPU env instead.')
    }

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
        # THE lane predicate (#121): the fail-closed gate above already
        # guarantees a valid CudaRoot whenever GpuType is nvidia, so consumers
        # need no defensive '-and CudaRoot -and Test-Path' tails — six
        # divergent spellings of this condition existed before 2026-08-21.
        HasCuda       = ($gpuType -eq 'nvidia')
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

function Get-CudnnLibraryDir {
    # cuDNN's redist lays the import libs under lib\<archdir>: x64 natively,
    # arm64 on the cross lane (#176). Returned so -DCMAKE_LIBRARY_PATH can point
    # at the SAME directory the import lib was found in.
    param(
        [string]$CudnnRoot,
        [string]$Arch = ''
    )
    if ([string]::IsNullOrWhiteSpace($CudnnRoot)) { return $null }
    $archDir = if ((Get-WindowsTargetArch -Arch $Arch) -eq 'amd64') { 'x64' } else { 'arm64' }
    $libDir = Join-Path $CudnnRoot "lib\$archDir"
    if (-not (Test-Path -LiteralPath $libDir -ErrorAction SilentlyContinue)) { return $null }
    return $libDir
}

function Get-CudnnLibrary {
    param(
        [string]$CudnnRoot,
        [string]$Arch = ''
    )
    $libDir = Get-CudnnLibraryDir -CudnnRoot $CudnnRoot -Arch $Arch
    if (-not $libDir) { return $null }
    $lib = Get-ChildItem -LiteralPath $libDir -Filter 'cudnn*.lib' -ErrorAction SilentlyContinue |
        Sort-Object { $_.Name -ne 'cudnn.lib' } | Select-Object -First 1
    if ($lib) { return $lib.FullName }
    return $null
}

function Test-CudaWindowsArm64Payload {
    <#
    .SYNOPSIS
        True when the CUDA root carries the Windows-arm64 device payload.
    .DESCRIPTION
        The cross lane's POSITIVE signal (#176): Install-Cuda.ps1 -TargetArch arm64
        stages lib\arm64 (cudart.lib + cudadevrt.lib). Its presence -- never a host
        GPU probe -- is what may enable CUDA on an arm64 build; absent means the
        arm64 lane stays CPU + DirectML.
    #>
    param([string]$CudaRoot = '')
    if ([string]::IsNullOrWhiteSpace($CudaRoot)) { $CudaRoot = Get-CudaRoot }
    if ([string]::IsNullOrWhiteSpace($CudaRoot)) { return $false }
    return (Test-Path (Join-Path $CudaRoot 'lib\arm64\cudart.lib')) -and (Test-Path (Join-Path $CudaRoot 'lib\arm64\cudadevrt.lib'))
}

function Get-NvccHostCompilerPath {
    <#
    .SYNOPSIS
        The MSVC cl.exe nvcc must use as its host compiler for the TARGET arch.
    .DESCRIPTION
        nvcc rejects clang-cl, and the host compiler must TARGET the build's arch:
        natively the VsDevCmd x64 cl; on the cross lane the x64-HOSTED
        arm64-targeting cl (Hostx64\arm64) -- the one `vcvarsall x64_arm64` puts on
        PATH. Get-Command would hand back the x64 one, and nvcc would then emit x64
        host objects into an arm64 link. One owner for every nvcc-driven build
        (ORT, GenAI, OpenCV, TVM).
    #>
    param([string]$Arch = '')
    $targetArch = Get-WindowsTargetArch -Arch $Arch
    if ($targetArch -eq 'amd64') { return (Get-Command cl.exe -ErrorAction Stop).Source }
    $crossCl = Join-Path $env:VCToolsInstallDir "bin\Hostx64\$targetArch\cl.exe"
    if (Test-Path $crossCl) { return $crossCl }
    return (Get-Command cl.exe -ErrorAction Stop).Source
}

function Get-NvccCudaCmakeArgs {
    param(
        [Parameter(Mandatory)][string]$CudaRoot,
        [Parameter(Mandatory)][ValidateSet('17', '20')][string]$CudaStandard,
        [string]$ExtraCudaFlags = '',
        [switch]$IncludeToolkitRoot,
        [string]$ArchDecoration = '-real',
        [string]$Arch = ''
    )
    $targetArch = Get-WindowsTargetArch -Arch $Arch
    $clExe = Get-NvccHostCompilerPath -Arch $targetArch
    $preamble = '-Xcompiler=/Zc:preprocessor --compiler-options /Zc:preprocessor -DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING'
    # Cross: NVIDIA's Windows-on-Arm porting guide documents `vcvarsall x64_arm64`
    # + `nvcc --use-local-env`; without it nvcc bootstraps its own MSVC env and
    # can pick the wrong arch (verified in out/probe-cuda-cross2, 2026-09-19).
    if ($targetArch -ne 'amd64') { $preamble = "--use-local-env $preamble" }
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
    'Get-CudnnLibraryDir',
    'Get-CudnnLibrary',
    'Test-CudaWindowsArm64Payload',
    'Get-NvccHostCompilerPath',
    'Get-NvccCudaCmakeArgs',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)

