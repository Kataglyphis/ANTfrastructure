# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\onnx-genai-src',
    [string]$InstallDir = '',
    [string]$OnnxGenAiVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$OnnxGenAiVersion = Get-SourceBuildVersion -Value $OnnxGenAiVersion -EnvironmentVariables @('ONNXRUNTIME_GENAI_VERSION', 'ONNX_GENAI_VERSION') -DefaultValue '0.15.2' -StripVPrefix

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

# cmake/ninja dropped from this pip line 2026-08-03: the image ships both on
# PATH (scoop) and the pip copies were an unused ~50 MB download per build.
Write-Host 'Installing requests, setuptools, wheel via pip...'
Invoke-CpythonPip -Python $py -Arguments @('install', 'requests', 'setuptools', 'wheel', '--no-warn-script-location', '--quiet')

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
if ($gpuEnv.HasCuda) {
    $cudaRoot  = $gpuEnv.CudaRoot
    $cudaArch  = Get-CudaArchitectureList -Decoration '-real'
    # nvcc host = MSVC cl.exe (NOT clang-cl); C++ stays clang-cl. C++20 (std::span in cuda_topk.cu; 17
    # fails). /wd4996 survives the CUDA 13.x curand double4 deprecation-as-error (genai issue #1877);
    # the shared /Zc:preprocessor + CCCL preamble + toolkit root come from Get-NvccCudaCmakeArgs.
    $genaiCudaArgs = @('-DUSE_CUDA=ON') +
        (Get-NvccCudaCmakeArgs -CudaRoot $cudaRoot -CudaStandard '20' -ExtraCudaFlags '-Xcompiler=/wd4996' -IncludeToolkitRoot)
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
    # BUILD_WHEEL=ON: cmake configures build\wheel\setup.py and a POST_BUILD step
    # copies onnxruntime_genai.pyd + embed libs (incl. D3D12Core) into build\wheel;
    # the wheel itself is packed after the build below.
    '-DENABLE_JAVA=OFF', '-DBUILD_WHEEL=ON', '-DUSE_GUIDANCE=OFF'
    # GenAI 0.15 turned Microsoft 1DS telemetry (cpp_client_telemetry) ON by
    # default. OFF for two reasons: (a) its bundled zlib feeds GNU-style
    # `-std=c11` to clang-cl under -Werror -> hard build break; (b) we do not
    # want phone-home telemetry compiled into the shipped image at all.
    '-DENABLE_TELEMETRY=OFF'
    '-DPUBLISH_JAVA_MAVEN_LOCAL=OFF'
    '-DBUILD_EXAMPLES=OFF', '-DBUILD_TESTING=OFF'
    "-DCMAKE_CXX_FLAGS:STRING=/GR /EHsc -D_SILENCE_CLANG_COROUTINE_MESSAGE $(Get-WarningNoiseSuppressionFlags)"
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
# drift across MSVC v143/v145 releases. See docs/windows-builds.md "Source Patch Policy".

# Neutralize MSVC STL's clang-incompatible static_asserts. yvals_core.h defines
#   _EMIT_STL_ERROR(NUMBER, MESSAGE) -> static_assert(false, ...)
# Wrapping that define in `#ifdef __clang__` makes EVERY STL error code a no-op under clang-cl
# (STL1009/1010/1011 in <experimental/coroutine>, etc.). This single edit carries the whole load.
# A former <experimental/coroutine>-specific patch was REMOVED here: it was (a) redundant with this
# (yvals no-ops _EMIT_STL_ERROR for all codes), and (b) permanently broken -- its single-line regex
# `_EMIT_STL_ERROR\(STL1009, ".*?"\)` never matched MSVC's MULTI-line STL1009 macro call, so it was a
# silent no-op while GenAI built fine on the yvals patch alone. Validated vs MSVC 14.51.36231 (VS 18).
$yvalsCore = Join-Path $msvcVersionDir 'include\yvals_core.h'
$yvalsOld = '#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)'
$yvalsNew = '#ifdef __clang__
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)
#else
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)
#endif'
[void](Invoke-InlineRegexPatch -Path $yvalsCore -Guard '#define _EMIT_STL_ERROR' `
        -Pattern ([regex]::Escape($yvalsOld)) -Replacement $yvalsNew `
        -Description 'MSVC yvals_core.h for clang compat')
# Loud drift assertion: this patch is load-bearing, so if the _EMIT_STL_ERROR #define is present but
# our exact target line no longer matches (a future MSVC toolset changed its format), FAIL NOW with a
# clear message instead of letting clang static_asserts resurface mid-compile with a confusing error.
# (An already-patched header contains the `#ifdef __clang__` wrapper, so that is not treated as drift.)
if (Test-Path $yvalsCore) {
    $yvalsText = [System.IO.File]::ReadAllText($yvalsCore)
    if (($yvalsText -match '#define _EMIT_STL_ERROR') -and
        ($yvalsText -notmatch '#ifdef __clang__\r?\n#define _EMIT_STL_ERROR\(NUMBER, MESSAGE\)')) {
        $msvcVer = Split-Path $msvcVersionDir -Leaf
        throw "yvals_core.h: _EMIT_STL_ERROR is present but the exact patch target did not match (MSVC $msvcVer likely changed the macro format). Update `$yvalsOld in build-onnx-genai-from-source.ps1 -- clang static_asserts will otherwise resurface mid-build."
    }
}

# Patch build.ninja to strip MSVC-only flags clang-cl errors on
Update-NinjaFile -NinjaFile (Join-Path $genaiBuildDir 'build.ninja') -StripPatterns @(
    '/Qspectre',
    '(?<=\s)/WX(?=\s)'
)

# Memory-scaled ninja + incremental -j1 retry + install via the shared helper. Replaces
# a hand-rolled -j%NUMBER_OF_PROCESSORS% .bat (full-core, no memory scaling) that could
# OOM / deadlock a memory-capped container; the -j1 retry still yields clean error output.
# -LogFile was MISSING here entirely (backlog #43), so this stage produced no
# ninja log at all - not even the 50-line failure tail, which is gated on it.
# GenAI compiles nvcc CUDA kernels; a failure emitted only whatever stdout
# happened to survive. Persistent path, same as every sibling.
$genaiLog = Get-PersistentBuildLogPath -Name 'onnx-genai-ninja.log' -FallbackDir $genaiBuildDir
# MemGBPerJob 2, not 4 (backlog #74). The 2026-08-15 chain still ran three
# stages at `ninja -j9` because backlog #28 only lowered onnx and opencv; the
# leftover 4 halves the job count for no measured reason. The measurement that
# justified 2 came from the ONNX vertex — 9274 samples, peak per-process
# WorkingSet 998 MB — and genai compiles the same nvcc CUDA workload. The
# strongest local evidence is build-iree, which builds LLVM in-tree, the most
# memory-hungry load in the chain, and has run at 2 all along. Downside is
# bounded: the retry ladder drops to -j1 on an OOM-shaped failure.
Invoke-NinjaBuildWithRetry -BuildDir $genaiBuildDir -RetryJobs 1 -MemGBPerJob 2 -Install -LogFile $genaiLog
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

Write-Host "Installing to $genaiInstallDir..."
# Copy built artifacts (top level only, matching the original non-recursive wildcard copy).
# Reuse $genaiBuildDir (same path) instead of re-deriving it.
if (Test-Path $genaiBuildDir) {
    Copy-BuildArtifact -BuildDir $genaiBuildDir -InstallDir $genaiInstallDir -Map @(
        @{ Filter = '*.h'; Dest = 'include' }
        @{ Filter = @('*.lib', '*.dll', '*.pyd'); Dest = 'lib' }
    )
} else {
    # Should be unreachable (ninja just built there), but a silent skip would
    # ship an empty $genaiInstallDir while the stage reports green.
    Write-Warning "genai build dir missing at $genaiBuildDir -- NO artifacts staged to $genaiInstallDir"
}
# Also check alternate output dirs (optional layout variant -- absence is normal,
# but a FAILED copy from an existing dir must not be silent).
$altOutDir = Join-Path $SourceDir 'build\Windows-ClangCL\Windows\Release'
if (Test-Path $altOutDir) {
    try {
        Copy-Item -Path (Join-Path $altOutDir '*') -Destination "$genaiInstallDir\lib" -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "copy from alternate output dir $altOutDir failed: $_"
    }
}

# DML: the D3D12 Agility SDK core DLL is NOT auto-copied when BUILD_WHEEL=OFF (ortgenai_embed_libs
# is only consumed by the wheel's POST_BUILD step). onnxruntime-genai.dll loads D3D12Core.dll from its
# own module dir at runtime (DmlHelpers -> D3D12SDKConfiguration), so stage it next to the genai DLL.
# Needed whenever USE_DML=ON (independent of CUDA); the D3D12 FetchContent dir name floats, so resolve
# by recursive find and no-op with a warning if absent (e.g. a hypothetical USE_DML=OFF build).
# The Microsoft.Direct3D.D3D12 nuget ships D3D12Core.dll for x64/arm64/win32; MUST pick x64 (its
# immediate parent dir is 'x64') -- an unqualified -Recurse|Select -First 1 grabs arm64 alphabetically,
# which then fails to load on the x64 image at DML device init.
Copy-SidecarDll -SidecarName 'D3D12Core.dll' -SearchDir $genaiBuildDir `
    -SidecarFilter { $_.FullName -match '_deps' -and $_.Directory.Name -eq 'x64' } `
    -Destination (Join-Path $genaiInstallDir 'lib') `
    -Reason 'the DML runtime will fail to init the Agility SDK device. Verify the Microsoft.Direct3D.D3D12 FetchContent'

# -- Python wheel (onnxruntime-genai-cuda / onnxruntime-genai) --
# BUILD_WHEEL=ON assembled build\wheel (configured setup.py + onnxruntime_genai
# package with the .pyd + embed libs). Pack it; --no-build-isolation so the pack
# uses the deps installed above instead of a fresh pip env. Must run BEFORE
# Remove-SourceBuildTree.
$genaiWheelDir = Join-Path $genaiBuildDir 'wheel'
if (Test-Path (Join-Path $genaiWheelDir 'setup.py')) {
    Write-Host 'Building onnxruntime-genai python wheel...'
    # -NoDeps is LOAD-BEARING: genai-cuda's dependency metadata names
    # `onnxruntime-gpu`, and letting pip resolve it pulled PyPI's
    # onnxruntime-gpu whose files OVERWROTE our combined wheel's module -- the
    # base interpreter silently lost its DmlExecutionProvider (caught
    # 2026-07-13). Our onnxruntime is already installed by build-onnx.
    Invoke-PythonWheelBuild -Python $py -WorkingDir $genaiWheelDir `
        -Arguments '-m pip wheel . --no-deps --no-build-isolation -w dist' `
        -ModuleName 'onnxruntime_genai' -NoDeps | Out-Null
} else {
    # Hard gate: BUILD_WHEEL=ON is set above, so a missing configured setup.py
    # means the wheel (and its embed libs) silently vanish from the image.
    throw "genai wheel dir has no setup.py under $genaiWheelDir although BUILD_WHEEL=ON -- BUILD_WHEEL layout changed? Wheel would NOT be staged."
}

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== ONNX Runtime GenAI source build completed ==='
Write-Host "Artifacts at: $genaiInstallDir"

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0