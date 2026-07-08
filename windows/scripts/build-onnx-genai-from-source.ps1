# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\onnx-genai-src',
    [string]$InstallDir = '',
    [string]$OnnxGenAiVersion = ''
)

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

# Build ONNX GenAI directly with cmake (bypass build.py which always builds examples)
$genaiBuildDir = Join-Path $SourceDir 'build\Windows-ClangCL\Release'
# GenAI keeps CUDA OFF at build time (clang-cl + nvcc host-compiler interplay issue with CUDA
# 13.x headers); it uses ONNX Runtime's CUDA execution provider at runtime instead.
$genaiCudaArgs = @('-DUSE_CUDA=OFF')
Write-Host 'CUDA disabled for ONNX GenAI build (uses ONNX Runtime CUDA EP at runtime)'

# Auto-detect correct Python library (python314.lib for full API, fallback to python3.lib)
$cmakeExtraGenAi = @(
    '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
    '-DUSE_TRT_RTX=OFF', '-DUSE_DML=OFF'
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

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== ONNX Runtime GenAI source build completed ==='
Write-Host "Artifacts at: $genaiInstallDir"


