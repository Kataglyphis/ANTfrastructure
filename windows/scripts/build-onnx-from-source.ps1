# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\onnx-src',
    [string]$InstallDir = '',
    [string]$OnnxVersion = ''
)

# Inline initialization (avoids module-load dependency for the first media build script).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$OnnxVersion = Get-SourceBuildVersion -Value $OnnxVersion -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.27.0'
$OnnxVersion = $OnnxVersion -replace '^v', ''  # versions.env uses v-prefix; this script adds it back for the git tag

Write-Host "=== ONNX Runtime source build (Ninja + clang-cl + GPU: $(if ($env:GPU_TYPE) { $env:GPU_TYPE } else { 'none' })) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime.git' -Tag "v$OnnxVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone ONNX Runtime' }

$cmakeSrc = if (Test-Path "$SourceDir\cmake\CMakeLists.txt") { "$SourceDir\cmake" } else { $SourceDir }
$buildDir = "$SourceDir\build"
$ortInstallDir = "$InstallDir\lib\onnxruntime-source"

# Inline patch (kept inline, NOT a .patch file): llvm-rc rejects non-ASCII bytes in the .rc resource.
# This is a binary byte-filter (`-le 127`), not a textual diff -- not expressible as a unified diff.
$bytes = [System.IO.File]::ReadAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc")
[System.IO.File]::WriteAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc", [byte[]]@($bytes | Where-Object { $_ -le 127 }))

$py = Initialize-ToolchainPythonEnvironment

# ONNX-specific CPU feature flags added on top of the shared SIMD base.
# mwaitpkg is required by spin_pause.cc (_tpause intrinsic); aes/pclmul are
# used by CUDA provider crc64; f16c accelerates float16 on Haswell+.
$cxxFlags = "/WX- $(Get-WindowsX86SimdFlags) /clang:-mwaitpkg /clang:-maes /clang:-mpclmul /clang:-mf16c $(Get-WindowsX86Avx512Flags) /clang:-Wno-invalid-specialization"

# -- GPU detection (single shot via Get-GpuEnvironment; ONNX-specific flag names stay local) --
$gpuEnv = Get-GpuEnvironment
$gpuArgs = @()
# if/elseif/else used in place of `switch ($gpuEnv.GpuType) { ... }` for broad compatibility
# with Windows PowerShell 5.1 (the switch-on-property syntax can trigger parser errors in PS 5.1).
if ($gpuEnv.GpuType -eq 'nvidia') {
    Write-Host 'NVIDIA GPU detected: enabling CUDA + cuDNN'
    $cudaRoot = $gpuEnv.CudaRoot
    $cudnnRoot = $gpuEnv.CudnnRoot
    $cudnnLib = if ($cudnnRoot) { (Get-ChildItem "$cudnnRoot\lib\x64\cudnn*.lib" -ErrorAction SilentlyContinue)[0].FullName } else { $null }

    # CUDA 13.x CCCL breaks clang-cl PCH -- disable via a reviewable .patch (inline regex fallback for context drift).
    try {
        Invoke-SourcePatch -PatchFile (Join-Path $PSScriptRoot 'patches\onnxruntime\002-disable-cuda-pch.patch') -SourceDir $SourceDir -IgnoreWhitespace
    } catch {
        Write-Host "002-disable-cuda-pch.patch did not apply cleanly -- falling back to inline regex"
        $pch = "$SourceDir\cmake\onnxruntime_providers_cuda.cmake"
        if (Test-Path $pch) { [System.IO.File]::WriteAllText($pch, ([System.IO.File]::ReadAllText($pch) -replace 'target_precompile_headers\([^)]+\)', '')) }
    }
        # clang-cl can't handle `and`/`or`/`not` keyword alternatives -- replace via a reviewable .patch.
        # If the .patch context has drifted upstream (common when ONNX rearranges comments), fall back
        # to the generic Replace-CppKeywordAlternatives helper against the two softmax source files.
        try {
            Invoke-SourcePatch -PatchFile (Join-Path $PSScriptRoot 'patches\onnxruntime\001-softmax-clangcl-keywords.patch') -SourceDir $SourceDir -IgnoreWhitespace
        } catch {
            Write-Host "001-softmax-clangcl-keywords.patch did not apply cleanly -- falling back to keyword-alternatives in softmax sources"
            foreach ($sf in @('softmax.cc', 'softmax.h')) {
                $sfp = Join-Path $SourceDir 'onnxruntime\core\providers\cuda\math' $sf
                if (Test-Path $sfp) { Replace-CppKeywordAlternatives -Path $sfp }
            }
        }

    # ONNX-specific CMake flags (names like `onnxruntime_USE_CUDA` are ORT-only -- kept local, not in the generic helper).
    $gpuArgs += '-Donnxruntime_USE_CUDA=ON'
    $trtRoot = $gpuEnv.TensorRtRoot
    if ($trtRoot) {
        Write-Host "TensorRT detected at $trtRoot - enabling TensorRT EP"
        $gpuArgs += '-Donnxruntime_USE_TENSORRT=ON'
        $gpuArgs += '-Donnxruntime_USE_TENSORRT_BUILTIN_PARSER=ON'
        $gpuArgs += "-DTENSORRT_ROOT=$trtRoot"
    } else {
        $gpuArgs += '-Donnxruntime_USE_TENSORRT=OFF'
    }
    $gpuArgs += "-DCMAKE_CUDA_COMPILER:FILEPATH=$cudaRoot\bin\nvcc.exe"
    $gpuArgs += "-DCMAKE_CUDA_HOST_COMPILER:FILEPATH=$((Get-Command cl.exe -ErrorAction Stop).Source)"
    $gpuArgs += '-DCMAKE_CUDA_STANDARD:STRING=17'
    $gpuArgs += "-DCMAKE_CUDA_ARCHITECTURES=$(Get-CudaArchitectureList -Decoration '-real')"
    $gpuArgs += "-DCMAKE_CUDA_FLAGS:STRING=-Xcompiler=/wd4067 -Xcompiler=/Zc:preprocessor --compiler-options /Zc:preprocessor -DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING"
    $gpuArgs += "-DCUDNN_ROOT=$cudnnRoot", "-DCUDNN_INCLUDE_DIR=$cudnnRoot\include"
    $gpuArgs += "-DCMAKE_LIBRARY_PATH=$cudnnRoot\lib\x64", "-DCUDNN_LIBRARY=$cudnnLib"
    $gpuArgs += "-Donnxruntime_CUDNN_HOME=$cudnnRoot", "-Donnxruntime_CUDA_HOME=$cudaRoot"
} elseif ($gpuEnv.GpuType -eq 'amd') {
    Write-Host 'AMD GPU detected: enabling ROCm'
    $gpuArgs += '-Donnxruntime_USE_ROCM=ON'
} else {
    Write-Host 'No GPU layer detected: CPU-only build'
}

$cmakeArgs = @(
    '-Donnxruntime_BUILD_SHARED_LIB=ON', '-Donnxruntime_BUILD_UNIT_TESTS=OFF', '-Donnxruntime_BUILD_BENCHMARKS=OFF'
    '-Donnxruntime_USE_DML=OFF', '-Donnxruntime_ENABLE_PYTHON=OFF', '-Dprotobuf_MSVC_STATIC_RUNTIME=OFF'
    "-DPython3_EXECUTABLE=$($py.Exe)", "-DPython3_INCLUDE_DIR=$($py.Include)", "-DPython3_LIBRARY=$($py.Lib)"
    "-DCMAKE_CXX_FLAGS:STRING=$cxxFlags"
) + $gpuArgs
$ok = Invoke-CmakeConfigure -SourceDir $cmakeSrc -BuildDir $buildDir -InstallPrefix $ortInstallDir -ExtraArgs $cmakeArgs
if (-not $ok) { throw 'CMake configure failed' }

# -- Post-configure patches (NVIDIA CUDA + CUTLASS) --
# Inline patches (kept inline, NOT .patch files):
#   * CUTLASS is a CMake-fetched third-party dep; the fetched version's SHA varies
#     with onnxruntime's `cutlass-src` ExternalProject pointer. A static .patch
#     against a pinned tag would silently rot when the pinned SHA changes, so
#     the `Replace-CppKeywordAlternatives` helper walks the fetched tree and
#     the `_udiv128->udiv128` substitution targets `cutlass/uint128.h` directly.
if ($env:GPU_TYPE -eq 'nvidia') {
    # CUTLASS headers: clang-cl can't handle `not`/`and`/`or` keyword alternatives.
    $cutlassInclude = "$buildDir\_deps\cutlass-src\include"
    if (Test-Path $cutlassInclude) {
        Get-ChildItem $cutlassInclude -Recurse -Filter '*.hpp' | ForEach-Object { Replace-CppKeywordAlternatives -Path $_.FullName }
    }
    # CUTLASS uint128: clang-cl lacks the MSVC-only `_udiv128` intrinsic.
    $cut = "$buildDir\_deps\cutlass-src\include\cutlass\uint128.h"
    if (Test-Path $cut) { [System.IO.File]::WriteAllText($cut, ([System.IO.File]::ReadAllText($cut) -replace '_udiv128', 'udiv128')) }
    # CUTLASS cute/array_subbyte: suppressed via -Wno-invalid-specialization above
}

# Strip MSVC-only flags from build.ninja
Update-NinjaFile -NinjaFile "$buildDir\build.ninja" -StripPatterns @(
    '--compiler-options /experimental:external\s*',
    '(?<=\s)/experimental:external(?=\s)',
    '(?<=\s)-WX(?=\s)',
    '/arch:\S+',
    '(?<!-Xcompiler\s)/bigobj',
    '--threads \d+'
)

$env:NINJA_STATUS = "[%f/%t] "
# Memory-scaled parallelism: AVX-512/CUDA TUs under clang-cl peak at several GB each,
# so full -j<cores> can OOM the container. jobs = min(cores, memGB/8), floor 2
# (override with BUILD_JOBS). Ninja is incremental, so the -j2 retry after an
# OOM-style failure only redoes the jobs that died.
$jobs = Get-BuildJobCount -MemGBPerJob 8
Write-Host "Building with ninja -j$jobs..."
ninja -j $jobs -C $buildDir 2>&1
if ($LASTEXITCODE -ne 0 -and $jobs -gt 2) {
    Write-Host "ninja -j$jobs failed (exit $LASTEXITCODE) - retrying incrementally with -j2..."
    ninja -j2 -C $buildDir 2>&1
}
if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)" }
cmake --install $buildDir --config Release; if ($LASTEXITCODE -ne 0) { throw "Install failed" }
Remove-SourceBuildTree -Path $SourceDir
Write-Host '=== ONNX Runtime source build completed ==='


