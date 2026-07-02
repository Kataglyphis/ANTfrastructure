# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\onnx-genai-src',
    [string]$InstallDir = '',
    [string]$OnnxGenAiVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$OnnxGenAiVersion = Get-SourceBuildVersion -Value $OnnxGenAiVersion -EnvironmentVariables @('ONNXRUNTIME_GENAI_VERSION', 'ONNX_GENAI_VERSION') -DefaultValue '0.14.0'
$OnnxGenAiVersion = $OnnxGenAiVersion -replace '^v', ''  # versions.env uses v-prefix; this script adds it back for the git tag

Write-Host "=== ONNX Runtime GenAI source build (v$OnnxGenAiVersion, Ninja+clang-cl) ==="
Write-Host "SourceDir: $SourceDir"
Write-Host "InstallDir: $InstallDir"

$genaiInstallDir = Join-Path $InstallDir 'lib\onnxruntime-genai-source'

# Use the source-built Python from the toolchain layer
$py = Get-SourceBuildPython
if (-not (Test-Path $py.Exe)) { throw "Python not found at $($py.Exe)" }
Write-Host "Using Python: $($py.Exe)"

# Install pip (source-built Python doesn't include it)
Write-Host 'Installing pip...'
$pipScript = Join-Path $env:TEMP 'get-pip.py'
Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $pipScript -UseBasicParsing
# Use cmd.exe to avoid PowerShell's $ErrorActionPreference treating stderr as errors
cmd.exe /c """$($py.Exe)"" ""$pipScript"" --quiet 2>&1"
if ($LASTEXITCODE -ne 0) { throw 'get-pip.py failed' }
Remove-Item $pipScript -Force -ErrorAction SilentlyContinue

Write-Host 'Installing cmake, ninja, requests via pip...'
cmd.exe /c """$($py.Exe)"" -m pip install cmake ninja requests --no-warn-script-location --quiet 2>&1"
if ($LASTEXITCODE -ne 0) { throw 'pip install build deps failed' }

# Canonical preamble: VsDevCmd + Copy-CpythonPyConfigHeader in one call (replaces the
# previously duplicated three-line invocation in a different order than build-onnx).
Initialize-ToolchainPythonEnvironment | Out-Null

# Clone onnxruntime-genai
$ok = Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime-genai.git' -Tag "v$OnnxGenAiVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone ONNX GenAI' }

Set-Location $SourceDir

# Build ONNX GenAI directly with cmake (bypass build.py which always builds examples)
$genaiBuildDir = Join-Path $SourceDir 'build\Windows-ClangCL\Release'
# GPU environment is detected once via the canonical helper. GenAI keeps CUDA OFF at build
# time (clang-cl + nvcc host-compiler interplay issue with CUDA 13.x headers); GenAI uses
# ONNX Runtime's CUDA execution provider at runtime instead.
$gpuEnv = Get-GpuEnvironment
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
$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $genaiBuildDir -InstallPrefix $genaiInstallDir -ExtraArgs $cmakeExtraGenAi
if (-not $ok) { throw 'ONNX GenAI CMake configure failed' }

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
if (Test-Path $coroHeader) {
    $text = [System.IO.File]::ReadAllText($coroHeader)
    if ($text -match '_EMIT_STL_ERROR\(STL1009') {
        $text = $text -replace '_EMIT_STL_ERROR\(STL1009, ".*?"\)', ''
        [System.IO.File]::WriteAllText($coroHeader, $text)
        Write-Host 'Patched MSVC experimental/coroutine header'
    }
}
# Also patch yvals_core.h to make _EMIT_STL_ERROR a no-op when __clang__
$yvalsCore = Join-Path $msvcVersionDir 'include\yvals_core.h'
if (Test-Path $yvalsCore) {
    $text = [System.IO.File]::ReadAllText($yvalsCore)
    # NOTE: This _EMIT_STL_ERROR regex patch is MSVC version-specific (v143/v145 toolset).
    # The exact #define line format changes between MSVC releases.
    # When the MSVC toolset is updated, verify the macro signature still matches
    # before blindly applying this patch.
    if ($text -match '#define _EMIT_STL_ERROR') {
        $old = '#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)'
        $new = '#ifdef __clang__
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)
#else
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)
#endif'
        $text = $text -replace [regex]::Escape($old), $new
        [System.IO.File]::WriteAllText($yvalsCore, $text)
        Write-Host 'Patched MSVC yvals_core.h for clang compat'
    }
}

# Patch build.ninja to strip MSVC-only flags clang-cl errors on
Update-NinjaFile -NinjaFile (Join-Path $genaiBuildDir 'build.ninja') -StripPatterns @(
    '/Qspectre',
    '(?<=\s)/WX(?=\s)'
)

Write-Host 'Building with ninja directly...'
$batFile = Join-Path $env:TEMP 'build_genai.bat'
try {
    "@echo off
    ninja -C `"$genaiBuildDir`" -j%NUMBER_OF_PROCESSORS% 2>&1
    if errorlevel 1 ninja -C `"$genaiBuildDir`" 2>&1
    " | Set-Content -Path $batFile -Encoding ASCII
    cmd.exe /c $batFile
    $buildExit = $LASTEXITCODE
} finally {
    if (Test-Path $batFile) { Remove-Item $batFile -Force -ErrorAction SilentlyContinue }
}

if ($buildExit -ne 0) {
    # Try single-threaded to see full error
    Write-Host 'Retrying single-threaded for clear error output...'
    cmd.exe /c "ninja -C `"$genaiBuildDir`" -j1 2>&1"
    throw "ONNX GenAI build failed"
}

Write-Host 'Installing...'
& cmake --install $genaiBuildDir --config Release
if ($LASTEXITCODE -ne 0) { throw 'Install failed' }

Write-Host "Installing to $genaiInstallDir..."
# Copy built artifacts
$buildOutDir = Join-Path $SourceDir 'build\Windows-ClangCL\Release'
if (Test-Path $buildOutDir) {
    New-Item -Path $genaiInstallDir\include -ItemType Directory -Force | Out-Null
    New-Item -Path $genaiInstallDir\lib -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $buildOutDir '*.h') -Destination "$genaiInstallDir\include" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $buildOutDir '*.lib') -Destination "$genaiInstallDir\lib" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $buildOutDir '*.dll') -Destination "$genaiInstallDir\lib" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $buildOutDir '*.pyd') -Destination "$genaiInstallDir\lib" -Force -ErrorAction SilentlyContinue
}
# Also check alternate output dirs
$altOutDir = Join-Path $SourceDir 'build\Windows-ClangCL\Windows\Release'
if (Test-Path $altOutDir) {
    Copy-Item -Path (Join-Path $altOutDir '*') -Destination "$genaiInstallDir\lib" -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== ONNX Runtime GenAI source build completed ==='
Write-Host "Artifacts at: $genaiInstallDir"


