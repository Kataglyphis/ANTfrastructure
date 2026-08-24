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
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

# Cross-target state, resolved once. GenAI is the LAST media-core component (the
# Dockerfile runs it in `media-core-built`, after OpenCV -- deliberately NOT the
# order of the $components array in build-media-core-all.ps1), so by the time it
# runs, ORT itself was already built with USE_DML=OFF on the cross lane.
$genaiTargetArch = Get-WindowsTargetArch
$genaiCross      = Test-WindowsCrossTarget -Arch $genaiTargetArch

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
# Cross lane: force CPU regardless of what the BUILD HOST has. Get-GpuEnvironment
# probes the x64 host's toolkit, so on a GPU-equipped host it would answer "yes"
# and switch on nvcc for an aarch64 target -- there is no CUDA for Windows-on-ARM
# at all, so this must be decided by the TARGET, never by the host. Same guard as
# build-onnx-from-source.ps1.
if ($gpuEnv.HasCuda -and -not $genaiCross) {
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
    $genaiCudaWhy = if ($genaiCross) { "cross-compiling for $genaiTargetArch -- no CUDA exists for Windows-on-ARM" }
                    else { 'CPU-only lane -- no nvidia GPU detected' }
    Write-Host "CUDA disabled for ONNX GenAI build ($genaiCudaWhy)"
}

# -- cross-lane switches, each decided by the TARGET arch --
# USE_DML: OFF here is SEQUENCING, not a platform gap. The claim recorded until
# 2026-08-23 -- "the nuget has no bin/ARM64-win/DirectML.lib" -- was wrong:
# Microsoft.AI.DirectML 1.15.4 does ship bin/arm64-win/DirectML.lib (COFF import
# archive, machine 0xAA64). What actually failed was an upper/lower-case mismatch
# in ONNX Runtime own CMake; backlog #113 patches it and ORT now builds USE_DML=ON
# on this lane too. GenAI stays OFF until that ORT build is proven green, because
# GenAI links ORT and a half-enabled DML produces link errors that read like a
# GenAI bug when they are not. Flip this to ON in the same change that confirms
# ORT arm64 DML, not before.
$genaiDmlArg = if ($genaiCross) { '-DUSE_DML=OFF' } else { '-DUSE_DML=ON' }
# Python: no aarch64 CPython exists in this image (Get-SourceBuildPython is
# host-pinned by design), so anything linking libpython would pull the x64
# import library into an arm64 module. Same reason ORT's own wheel and PyAV are
# skipped on this lane.
#
# ENABLE_PYTHON=OFF is the load-bearing switch, NOT BUILD_WHEEL=OFF. Upstream:
#     option(ENABLE_PYTHON "Build the Python API." ON)
#     cmake_dependent_option(BUILD_WHEEL "Build the python wheel" ON "ENABLE_PYTHON" OFF)
# and CMakeLists.txt gates the module itself on the FORMER:
#     if(ENABLE_PYTHON) add_subdirectory("${SRC_ROOT}/python") endif()
# So BUILD_WHEEL=OFF alone only suppresses the packaging step; src/python still
# built and the link failed (measured 2026-08-23):
#   onnxruntime_genai.cp314-win_amd64.pyd
#   lld-link: error: python314.lib(python314.dll): machine type x64 conflicts with arm64
# BUILD_WHEEL=OFF is kept alongside it purely as documentation of intent -- as a
# dependent option it is already forced OFF once ENABLE_PYTHON is OFF.
$genaiPythonArgs = if ($genaiCross) { @('-DENABLE_PYTHON=OFF', '-DBUILD_WHEEL=OFF') } else { @('-DBUILD_WHEEL=ON') }
# The clang target triple must ride in THIS script's explicit CMAKE_CXX_FLAGS
# string: passing -DCMAKE_CXX_FLAGS on the command line DEFINES the cache
# variable, so CMake never applies the CMAKE_CXX_FLAGS_INIT that
# Get-CMakeCrossArgs sets. Identical trap to build-opencv-from-source.ps1.
$genaiTargetFlag = if ($genaiCross) { " --target=$(Get-ClangTargetTriple -Arch $genaiTargetArch)" } else { '' }
# The host CPython lib dir is x64. On an aarch64 link line it lets lld-link pick
# up x64 import libs and fail with a machine-type conflict; it exists only to
# resolve the python module's python*.lib, which is not built on the cross lane.
#
# -DPYTHON_LIBRARY below still points at the host x64 import library and is left
# in place deliberately: with ENABLE_PYTHON=OFF nothing links it, while removing
# it risks breaking a configure-time find_package(Python...) for no gain. The
# rule this lane enforces is "no host-arch library on a LINK line", not "no
# host-arch path anywhere in the cache".
$genaiPyLinkArgs = if ($genaiCross) { @() } else { @("-DCMAKE_SHARED_LINKER_FLAGS:STRING=/LIBPATH:$($py.LibDir)") }

# Auto-detect correct Python library (python314.lib for full API, fallback to python3.lib)
$cmakeExtraGenAi = @(
    '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
    '-DUSE_TRT_RTX=OFF', $genaiDmlArg
    # BUILD_WHEEL=ON: cmake configures build\wheel\setup.py and a POST_BUILD step
    # copies onnxruntime_genai.pyd + embed libs (incl. D3D12Core) into build\wheel;
    # the wheel itself is packed after the build below.
    # NB: $genaiPythonArgs is appended with + below, NOT placed inline here.
    # A comma-separated array literal does NOT flatten a nested array, and the
    # [string[]] coercion then space-JOINS it into one argument -- CMake would
    # have received a single "-DENABLE_PYTHON=OFF -DBUILD_WHEEL=OFF" token and
    # silently ignored it. Newline-separated elements and + both flatten; commas
    # do not. Measured, not assumed.
    '-DENABLE_JAVA=OFF', '-DUSE_GUIDANCE=OFF'
    # GenAI 0.15 turned Microsoft 1DS telemetry (cpp_client_telemetry) ON by
    # default. OFF for two reasons: (a) its bundled zlib feeds GNU-style
    # `-std=c11` to clang-cl under -Werror -> hard build break; (b) we do not
    # want phone-home telemetry compiled into the shipped image at all.
    '-DENABLE_TELEMETRY=OFF'
    '-DPUBLISH_JAVA_MAVEN_LOCAL=OFF'
    '-DBUILD_EXAMPLES=OFF', '-DBUILD_TESTING=OFF'
    "-DCMAKE_CXX_FLAGS:STRING=/GR /EHsc -D_SILENCE_CLANG_COROUTINE_MESSAGE $(Get-WarningNoiseSuppressionFlags)$genaiTargetFlag"
    "-DPYTHON_EXECUTABLE=$($py.Exe)"
    "-DPYTHON_LIBRARY=$($py.Lib)"
    "-DPYTHON_INCLUDE_DIR=$($py.Include)"
) + $genaiPythonArgs + $genaiPyLinkArgs + $genaiCudaArgs
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
# The Microsoft.Direct3D.D3D12 nuget ships D3D12Core.dll for x64/arm64/win32, one per immediate
# parent dir, and those dir names ARE the RID arch component ('win-x64' -> 'x64',
# 'win-arm64' -> 'arm64'). Pin the filter to the TARGET's dir: an unqualified
# -Recurse|Select -First 1 grabs arm64 alphabetically and fails to load on an x64 image at DML
# device init -- while hardcoding 'x64' threw away the arm64 payload a DML-enabled arm64 build
# would need. Kept target-derived rather than re-hardcoded to 'x64', so this stays correct if
# the cross lane ever gains DML (see $genaiDmlArg).
# Skipped entirely on the cross lane: USE_DML=OFF means the D3D12 FetchContent never ran, so
# there is no _deps payload to stage and Copy-SidecarDll would only emit a misleading warning.
if (-not $genaiCross) {
    $d3d12ArchDir = (Get-WindowsRuntimeIdentifier) -replace '^win-', ''
    Copy-SidecarDll -SidecarName 'D3D12Core.dll' -SearchDir $genaiBuildDir `
        -SidecarFilter { $_.FullName -match '_deps' -and $_.Directory.Name -eq $d3d12ArchDir } `
        -Destination (Join-Path $genaiInstallDir 'lib') `
        -Reason 'the DML runtime will fail to init the Agility SDK device. Verify the Microsoft.Direct3D.D3D12 FetchContent'
} else {
    Write-Host "D3D12Core.dll staging skipped (USE_DML=OFF on the $genaiTargetArch cross lane)"
}

# -- Python wheel (onnxruntime-genai-cuda / onnxruntime-genai) --
# BUILD_WHEEL=ON assembled build\wheel (configured setup.py + onnxruntime_genai
# package with the .pyd + embed libs). Pack it; --no-build-isolation so the pack
# uses the deps installed above instead of a fresh pip env. Must run BEFORE
# Remove-SourceBuildTree.
$genaiWheelDir = Join-Path $genaiBuildDir 'wheel'
if ($genaiCross) {
    # BUILD_WHEEL=OFF on the cross lane, so cmake configured no setup.py and there
    # is nothing to pack. The hard gate in the final else MUST NOT fire here -- its
    # entire premise is "BUILD_WHEEL=ON is set above", which is no longer true for
    # every lane. Skipping also keeps a host-arch .pyd out of the arm64 bundle,
    # which the PE arch gate would reject anyway.
    Write-Host "genai python wheel skipped (BUILD_WHEEL=OFF on the $genaiTargetArch cross lane -- no aarch64 CPython to link)"
} elseif (Test-Path (Join-Path $genaiWheelDir 'setup.py')) {
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