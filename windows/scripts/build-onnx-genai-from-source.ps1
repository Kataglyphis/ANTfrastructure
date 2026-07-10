# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\onnx-genai-src',
    [string]$InstallDir = '',
    [string]$OnnxGenAiVersion = ''
)

$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildEnvironment -InstallDir $InstallDir

$OnnxGenAiVersion = Get-SourceBuildVersion -Value $OnnxGenAiVersion -EnvironmentVariables @('ONNXRUNTIME_GENAI_VERSION', 'ONNX_GENAI_VERSION') -DefaultValue '0.14.0' -StripVPrefix

Write-Host "=== ONNX Runtime GenAI source build (v$OnnxGenAiVersion, Ninja+clang-cl) ==="
Write-Host "SourceDir: $SourceDir"
Write-Host "InstallDir: $InstallDir"

$genaiInstallDir = Join-Path $InstallDir 'lib\onnxruntime-genai-source'

# Use the source-built Python from the toolchain layer
$py = Get-SourceBuildPython
if (-not (Test-Path $py.Exe)) { throw "Python not found at $($py.Exe)" }
Write-Host "Using Python: $($py.Exe)"

# Install pip (source-built Python doesn't include it; idempotent shared helper)
Install-CpythonPip -Python $py

Write-Host 'Installing cmake, ninja, requests via pip...'
Invoke-CpythonPip -Python $py -Arguments @('install', 'cmake', 'ninja', 'requests', '--no-warn-script-location', '--quiet')

# Canonical preamble: VsDevCmd + Copy-CpythonPyConfigHeader in one call (replaces the
# previously duplicated three-line invocation in a different order than build-onnx).
Initialize-ToolchainPythonEnvironment | Out-Null

# Clone onnxruntime-genai
Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime-genai.git' -Tag "v$OnnxGenAiVersion" -SourceDir $SourceDir -Recursive | Out-Null

Set-Location $SourceDir

# DML: the genai CMake wires a RESTORE_PACKAGES target that nuget-restores Microsoft.Direct3D.DXC
# solely to regenerate HLSL shaders -- but src/dml/generated_dml_shaders/*.h ship as checked-in DXIL
# bytecode and nothing consumes dxc.exe at build time. The restore's nuget.config <clear/>s sources to
# an ORT-Nightly-only feed, so on USE_DML=ON it becomes a pointless network dependency that can stall a
# restricted build. Sever the (ALL) hard-dep so ninja never triggers it. No-op when USE_DML=OFF.
$genaiCml = Join-Path $SourceDir 'CMakeLists.txt'
Invoke-InlineRegexPatch -Path $genaiCml -Guard 'add_dependencies\(onnxruntime-genai RESTORE_PACKAGES\)' `
    -Pattern 'add_dependencies\(onnxruntime-genai RESTORE_PACKAGES\)' -Replacement '# [genai DML] RESTORE_PACKAGES dep dropped: shaders are pre-generated, dxc.exe unused' `
    -Description 'genai CMakeLists: drop RESTORE_PACKAGES dependency (pre-generated shaders)' `
    -WarnMessage "genai CMakeLists: add_dependencies(onnxruntime-genai RESTORE_PACKAGES) not found -- genai layout may have changed; a USE_DML build may stall on the DXC nuget restore. Verify $genaiCml." | Out-Null
Invoke-InlineRegexPatch -Path $genaiCml -Guard 'RESTORE_PACKAGES ALL' `
    -Pattern 'RESTORE_PACKAGES ALL' -Replacement 'RESTORE_PACKAGES' `
    -Description 'genai CMakeLists: de-ALL RESTORE_PACKAGES so it is not in the default build' `
    -WarnMessage "genai CMakeLists: 'RESTORE_PACKAGES ALL' not found -- verify the DXC restore target is not force-built. $genaiCml." | Out-Null

# Build ONNX GenAI directly with cmake (bypass build.py which always builds examples)
$genaiBuildDir = Join-Path $SourceDir 'build\Windows-ClangCL\Release'
# GPU: build GenAI's own CUDA kernels (-> onnxruntime-genai-cuda.dll) on the nvidia lane.
# GenAI compiles real .cu kernels (sampling / beam-search / top-k), so USE_CUDA=ON is REQUIRED
# for GPU inference -- a CPU build compiles USE_CUDA=0 and strips the entire CUDA device layer;
# it does NOT silently fall back to ORT's CUDA EP. nvcc's host compiler MUST be MSVC cl.exe
# (nvcc rejects clang-cl on Windows -- the reason this was long left OFF); the C++ TUs still
# compile with clang-cl + lld. Recipe proven in an isolated lab build against the toolchain.
# GENAI_FORCE_CPU=1 forces a CPU-only GenAI (skips the slow nvcc kernel compiles) so the DirectML
# path (USE_DML=ON) can be iterated fast -- DML is D3D12 host C++, unaffected by CUDA. Dev knob only
# (mirrors ONNX_FORCE_CPU in build-onnx); the media-core build never sets it.
$gpuEnv = Get-GpuEnvironment -ForceCpuEnvVar 'GENAI_FORCE_CPU'
if ($gpuEnv.GpuType -eq 'nvidia' -and $gpuEnv.CudaRoot) {
    $cudaRoot  = $gpuEnv.CudaRoot
    $clExe     = (Get-Command cl.exe -ErrorAction Stop).Source
    $cudaArch  = Get-CudaArchitectureList -Decoration '-real'
    $genaiCudaArgs = @(
        '-DUSE_CUDA=ON'
        "-DCMAKE_CUDA_COMPILER:FILEPATH=$cudaRoot\bin\nvcc.exe"
        "-DCUDA_TOOLKIT_ROOT_DIR=$cudaRoot"
        "-DCMAKE_CUDA_HOST_COMPILER:FILEPATH=$clExe"   # nvcc host = MSVC cl.exe (NOT clang-cl); C++ stays clang-cl
        "-DCMAKE_CUDA_ARCHITECTURES=$cudaArch"
        '-DCMAKE_CUDA_STANDARD=20'                     # genai C++ is C++20 (std::span in cuda_topk.cu); 17 fails to compile
        # /Zc:preprocessor: nvcc-with-cl needs it; CCCL_IGNORE silences the MSVC traditional-preprocessor
        # warning; /wd4996 survives CUDA 13.x curand double4 deprecation-as-error (genai issue #1877).
        '-DCMAKE_CUDA_FLAGS:STRING=-Xcompiler=/Zc:preprocessor --compiler-options /Zc:preprocessor -DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING -Xcompiler=/wd4996'
    )
    # genai's Python .pyd is a MODULE target, which the CMAKE_SHARED_LINKER_FLAGS /LIBPATH below
    # does NOT reach; put the CPython lib dir on LIB so lld-link resolves the auto-linked python*.lib.
    $env:LIB = "$($py.LibDir);$env:LIB"
    Write-Host "CUDA ENABLED for ONNX GenAI (arch $cudaArch; nvcc host = cl.exe; C++ = clang-cl)"
} else {
    $genaiCudaArgs = @('-DUSE_CUDA=OFF')
    Write-Host 'CUDA disabled for ONNX GenAI build (CPU-only lane -- no nvidia GPU detected)'
}

# Auto-detect correct Python library (python314.lib for full API, fallback to python3.lib)
$cmakeExtraGenAi = @(
    '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
    '-DUSE_TRT_RTX=OFF', '-DUSE_DML=ON'
    '-DENABLE_JAVA=OFF', '-DBUILD_WHEEL=OFF', '-DUSE_GUIDANCE=OFF'
    '-DPUBLISH_JAVA_MAVEN_LOCAL=OFF'
    '-DBUILD_EXAMPLES=OFF', '-DBUILD_TESTING=OFF'
    "-DCMAKE_CXX_FLAGS:STRING=/GR /EHsc -D_SILENCE_CLANG_COROUTINE_MESSAGE"
    "-DPYTHON_EXECUTABLE=$($py.Exe)"
    "-DPYTHON_LIBRARY=$($py.Lib)"
    "-DPYTHON_INCLUDE_DIR=$($py.Include)"
    "-DCMAKE_SHARED_LINKER_FLAGS:STRING=/LIBPATH:$($py.LibDir)"
) + $genaiCudaArgs
Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $genaiBuildDir -InstallPrefix $genaiInstallDir -ExtraArgs $cmakeExtraGenAi | Out-Null

# Resolve MSVC tools path dynamically (avoid hardcoded version)
$msvcVersionDir = Get-MsvcToolsRoot
Write-Host "Using MSVC tools: $msvcVersionDir"

# Inline patches (kept inline, NOT .patch files): these target MSVC STL headers
# under the installed MSVC tools directory (C:\Program Files...\VC\Tools\MSVC\...),
# not the cloned source tree. The MSVC tools version floats (resolved via
# Get-MsvcToolsRoot), so a static .patch against a pinned MSVC build would only
# work for one toolset version. The `-replace` form tolerates surrounding-text
# drift across MSVC v143/v145 releases. See docs/windows-builds.md ?Patches.

# Patch MSVC STL experimental/coroutine header to disable clang static_assert
$coroHeader = Join-Path $msvcVersionDir 'include\experimental\coroutine'
Invoke-InlineRegexPatch -Path $coroHeader -Guard '_EMIT_STL_ERROR\(STL1009' `
    -Pattern '_EMIT_STL_ERROR\(STL1009, ".*?"\)' `
    -Description 'MSVC experimental/coroutine header' `
    -WarnMessage "experimental/coroutine: STL1009 macro matched the guard but not the replace pattern; MSVC layout may have changed. Verify $coroHeader (clang static_assert errors may resurface later)." | Out-Null
# Also patch yvals_core.h to make _EMIT_STL_ERROR a no-op when __clang__
# NOTE: This _EMIT_STL_ERROR regex patch is MSVC version-specific (v143/v145 toolset).
# The exact #define line format changes between MSVC releases. When the MSVC toolset is
# updated, verify the macro signature still matches before blindly applying this patch.
$yvalsCore = Join-Path $msvcVersionDir 'include\yvals_core.h'
$yvalsOld = '#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)'
$yvalsNew = '#ifdef __clang__
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)
#else
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)
#endif'
Invoke-InlineRegexPatch -Path $yvalsCore -Guard '#define _EMIT_STL_ERROR' `
    -Pattern ([regex]::Escape($yvalsOld)) -Replacement $yvalsNew `
    -Description 'MSVC yvals_core.h for clang compat' `
    -WarnMessage "yvals_core.h: _EMIT_STL_ERROR is present but its exact signature did not match the patch target. The MSVC toolset likely changed the #define format; clang static_assert errors may resurface mid-build. Update the yvalsOld string in $yvalsCore." | Out-Null

# Patch build.ninja to strip MSVC-only flags clang-cl errors on
Update-NinjaFile -NinjaFile (Join-Path $genaiBuildDir 'build.ninja') -StripPatterns @(
    '/Qspectre',
    '(?<=\s)/WX(?=\s)'
)

# Memory-scaled ninja + incremental -j1 retry + install via the shared helper. Replaces
# a hand-rolled -j%NUMBER_OF_PROCESSORS% .bat (full-core, no memory scaling) that could
# OOM / deadlock a memory-capped container; the -j1 retry still yields clean error output.
Invoke-NinjaBuildWithRetry -BuildDir $genaiBuildDir -RetryJobs 1 -MemGBPerJob 4 -Install

Write-Host "Installing to $genaiInstallDir..."
# Copy built artifacts (top level only, matching the original non-recursive wildcard copy).
# Reuse $genaiBuildDir (same path) instead of re-deriving it.
if (Test-Path $genaiBuildDir) {
    Copy-BuildArtifact -BuildDir $genaiBuildDir -InstallDir $genaiInstallDir -Map @(
        @{ Filter = '*.h'; Dest = 'include' }
        @{ Filter = @('*.lib', '*.dll', '*.pyd'); Dest = 'lib' }
    )
}
# Also check alternate output dirs
$altOutDir = Join-Path $SourceDir 'build\Windows-ClangCL\Windows\Release'
if (Test-Path $altOutDir) {
    Copy-Item -Path (Join-Path $altOutDir '*') -Destination "$genaiInstallDir\lib" -Recurse -Force -ErrorAction SilentlyContinue
}

# DML: the D3D12 Agility SDK core DLL is NOT auto-copied when BUILD_WHEEL=OFF (ortgenai_embed_libs
# is only consumed by the wheel's POST_BUILD step). onnxruntime-genai.dll loads D3D12Core.dll from its
# own module dir at runtime (DmlHelpers -> D3D12SDKConfiguration), so stage it next to the genai DLL.
# Needed whenever USE_DML=ON (independent of CUDA); the D3D12 FetchContent dir name floats, so resolve
# by recursive find and no-op with a warning if absent (e.g. a hypothetical USE_DML=OFF build).
# The Microsoft.Direct3D.D3D12 nuget ships D3D12Core.dll for x64/arm64/win32; MUST pick x64 (its
# immediate parent dir is 'x64') -- an unqualified -Recurse|Select -First 1 grabs arm64 alphabetically,
# which then fails to load on the x64 image at DML device init.
$d3d12Core = Get-ChildItem -Path $genaiBuildDir -Filter 'D3D12Core.dll' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '_deps' -and $_.Directory.Name -eq 'x64' } | Select-Object -First 1
if ($d3d12Core) {
    Copy-Item -LiteralPath $d3d12Core.FullName -Destination (Join-Path $genaiInstallDir 'lib') -Force
    Write-Host "Staged D3D12Core.dll ($($d3d12Core.FullName)) -> $genaiInstallDir\lib"
} else {
    Write-Warning "D3D12Core.dll not found under $genaiBuildDir\_deps -- DML runtime will fail to init the Agility SDK device. Verify the Microsoft.Direct3D.D3D12 FetchContent."
}

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== ONNX Runtime GenAI source build completed ==='
Write-Host "Artifacts at: $genaiInstallDir"


