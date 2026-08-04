# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\litert-src',
    [string]$InstallDir = '',
    [string]$LiteRtVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

# LITERT REF SYNC: this 'v2.1.6' is the AUTHORITATIVE default. The v0.14
# support-graft in litert-lm-export-bridge.ps1 resolves the same LITERT_VERSION
# env with the same fallback -- a LiteRT bump must update BOTH defaults.
$LiteRtVersion = Get-SourceBuildVersion -Value $LiteRtVersion -EnvironmentVariables @('LITERT_VERSION') -DefaultValue 'v2.1.6'
$litertInstallDir = Join-Path $InstallDir 'lib\litert'

Write-Host "=== LiteRT source build ($LiteRtVersion, Ninja+clang-cl) ==="

Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT.git' -Tag "$LiteRtVersion" -SourceDir $SourceDir -Recursive | Out-Null

$tfliteSrc = Join-Path $SourceDir 'tflite'

# Inline patch (kept inline, NOT a .patch file): LiteRT ships ~17 proto/CMakeLists.txt
# files across nested subprojects, and the set of patched files varies between
# versions (new tables land in minor releases). The loop's predicate (presence of
# `protobuf_generate|protoc`) drives a per-file conditional stub. A static .patch
# against a pinned tag would silently rot when the proto set changes. Removed the
# orphaned windows/scripts/patches/litert/001-disable-proto-generation.patch (it
# only covered 2 of the ~15 files). See docs/windows-builds.md "Source Patch Policy".
$patchedIndex = 0
Get-ChildItem -Path $tfliteSrc -Filter 'CMakeLists.txt' -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -match 'proto\\CMakeLists\.txt'
} | ForEach-Object {
    $content = [System.IO.File]::ReadAllText($_.FullName)
    if ($content -match 'protobuf_generate|protoc') {
        $patchedIndex++
        $targetName = "proto_stub_$patchedIndex"
        $noopCmake = @"
cmake_minimum_required(VERSION 3.10)
project($targetName)
add_library($targetName INTERFACE)
"@
        Set-Content -Path $_.FullName -Value $noopCmake -Encoding ASCII
        Write-Host "Patched: $($_.FullName) (target=$targetName)"
    }
}

$buildDir = Join-Path $SourceDir 'build'
# Clean any stale build artifacts (CMake pkgRedirects path casing issues).
# -ErrorAction Stop: this cleanup EXISTS to prevent stale caches -- silently
# leaving residue behind defeats its purpose, so a failed delete must be loud.
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction Stop }
if (Test-Path (Join-Path $SourceDir 'BUILD')) { Remove-Item (Join-Path $SourceDir 'BUILD') -Recurse -Force -ErrorAction Stop }

# Detect GPU environment via the canonical helper (single source of truth for CUDA/cuDNN/TRT).
$gpuEnv = Get-GpuEnvironment
$cmakeExtra = @(
    '-DTFLITE_ENABLE_INSTALL=OFF'
    '-DTFLITE_ENABLE_LABEL_IMAGE=OFF'
    '-DTFLITE_ENABLE_BENCHMARK_MODEL=OFF'
    '-DTFLITE_ENABLE_RUY=ON'
    '-DTFLITE_ENABLE_RESOURCE=ON'
    # GPU delegate via Vulkan/OpenGL ES (primary GPU acceleration on Windows)
    '-DTFLITE_ENABLE_GPU=ON'
    '-DTFLITE_ENABLE_XNNPACK=ON'
    # External delegate support for custom CUDA/ROCm delegates
    '-DTFLITE_ENABLE_EXTERNAL_DELEGATE=ON'
    '-DTFLITE_ENABLE_MMAP=OFF'
    '-DTFLITE_ENABLE_NNAPI=OFF'
)

# Add CUDA paths for external delegate compilation if available
$cmakeExtra += Get-CudaToolkitRootArg -GpuEnv $gpuEnv

# Fix CMAKE_AR path for llvm-lib (CMake resolves llvm-lib to C:\llvm-lib incorrectly)
$cmakeExtra += Get-LlvmArchiverCmakeArg

# Vulkan SDK is auto-detected by LiteRT via VULKAN_SDK env var; no need for explicit paths.

# InstallPrefix passed for CMake generator expressions even though TFLITE_ENABLE_INSTALL=OFF
Invoke-CmakeConfigure -SourceDir $tfliteSrc -BuildDir $buildDir -InstallPrefix $litertInstallDir -ExtraArgs $cmakeExtra | Out-Null

$buildLog = Join-Path $buildDir 'litert-build.log'
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 4 -LogFile $buildLog

# Manual install (TFLITE_ENABLE_INSTALL=OFF disables cmake --install)
# -InstallPrefix is still passed to Invoke-CmakeConfigure because CMake generator
# expressions and INTERFACE targets reference CMAKE_INSTALL_PREFIX even when
# the install() commands are no-ops. Without it, header search paths and
# pkg-config .pc files may resolve incorrectly.
Write-Host 'Installing LiteRT artifacts manually...'
Copy-BuildArtifact -BuildDir $buildDir -InstallDir $litertInstallDir -Recurse -Map @(
    @{ Filter = '*.dll'; Dest = 'bin' }
    @{ Filter = '*.lib'; Dest = 'lib' }
)
# Copy headers. LiteRT ships NO include/ directory — its public headers live
# in-tree (tflite\c\c_api.h, tflite\interpreter.h, ...). Mirror the header tree
# under include\tflite\ preserving relative paths so consumers can
# #include "tflite/c/c_api.h".
Write-Host 'Copying LiteRT headers (tflite/ tree)...'
$includeRoot = Join-Path $litertInstallDir 'include\tflite'
New-Item -Path $includeRoot -ItemType Directory -Force | Out-Null
$headerCount = 0
Get-ChildItem -Path $tfliteSrc -Filter '*.h' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($tfliteSrc.Length).TrimStart('\')
    $dest = Join-Path $includeRoot $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
    Copy-Item $_.FullName $dest -Force
    $headerCount++
}
Write-Host "Copied $headerCount headers to $includeRoot"
# Hard gates on the manual install (Copy-BuildArtifact is silent-by-design):
# an empty header tree or a lib\ without a single .lib means the litert-lm
# stage would only fail hours later against a hollow install dir.
if ($headerCount -eq 0) { throw "LiteRT manual install copied 0 headers to $includeRoot (source tree layout changed?)" }
$installedLibs = @(Get-ChildItem -Path (Join-Path $litertInstallDir 'lib') -Filter '*.lib' -File -ErrorAction SilentlyContinue)
if ($installedLibs.Count -lt 1) { throw "LiteRT manual install staged no .lib files into $(Join-Path $litertInstallDir 'lib') (build produced none under $buildDir?)" }
Write-Host 'LiteRT manual install completed'

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== LiteRT source build completed ==='

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0