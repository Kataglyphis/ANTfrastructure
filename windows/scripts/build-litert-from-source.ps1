# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\litert-src',
    [string]$InstallDir = '',
    [string]$LiteRtVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$LiteRtVersion = Get-SourceBuildVersion -Value $LiteRtVersion -EnvironmentVariables @('LITERT_VERSION') -DefaultValue '2.1.5'
$litertInstallDir = Join-Path $InstallDir 'lib\litert'

Write-Host "=== LiteRT source build (v$LiteRtVersion, Ninja+clang-cl) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT.git' -Tag "$LiteRtVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone LiteRT' }

$tfliteSrc = Join-Path $SourceDir 'tflite'

# Inline patch (kept inline, NOT a .patch file): LiteRT ships ~17 proto/CMakeLists.txt
# files across nested subprojects, and the set of patched files varies between
# versions (new tables land in minor releases). The loop's predicate (presence of
# `protobuf_generate|protoc`) drives a per-file conditional stub. A static .patch
# against a pinned tag would silently rot when the proto set changes. Removed the
# orphaned windows/scripts/patches/litert/001-disable-proto-generation.patch (it
# only covered 2 of the ~15 files). See docs/windows-builds.md ?Patches.
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
# Clean any stale build artifacts (CMake pkgRedirects path casing issues)
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path (Join-Path $SourceDir 'BUILD')) { Remove-Item (Join-Path $SourceDir 'BUILD') -Recurse -Force -ErrorAction SilentlyContinue }

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
if ($gpuEnv.CudaRoot) {
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$($gpuEnv.CudaRoot)"
}

# Fix CMAKE_AR path for llvm-lib (CMake resolves llvm-lib to C:\llvm-lib incorrectly)
$llvmLib = Resolve-LlvmArchiver
if ($llvmLib) { $cmakeExtra += "-DCMAKE_AR:FILEPATH=$llvmLib" }

# Vulkan SDK is auto-detected by LiteRT via VULKAN_SDK env var; no need for explicit paths.

# InstallPrefix passed for CMake generator expressions even though TFLITE_ENABLE_INSTALL=OFF
$ok = Invoke-CmakeConfigure -SourceDir $tfliteSrc -BuildDir $buildDir -InstallPrefix $litertInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'LiteRT CMake configure failed' }

$buildLog = Join-Path $buildDir 'litert-build.log'
$ok = Invoke-CmakeBuild -BuildDir $buildDir -Config Release -Install:$false -LogFile $buildLog
if (-not $ok) { throw 'LiteRT build failed' }

# Manual install (TFLITE_ENABLE_INSTALL=OFF disables cmake --install)
# -InstallPrefix is still passed to Invoke-CmakeConfigure because CMake generator
# expressions and INTERFACE targets reference CMAKE_INSTALL_PREFIX even when
# the install() commands are no-ops. Without it, header search paths and
# pkg-config .pc files may resolve incorrectly.
Write-Host 'Installing LiteRT artifacts manually...'
New-Item -Path "$litertInstallDir\lib" -ItemType Directory -Force | Out-Null
New-Item -Path "$litertInstallDir\bin" -ItemType Directory -Force | Out-Null
$dlls = Get-ChildItem -Path $buildDir -Filter '*.dll' -Recurse -ErrorAction SilentlyContinue
$libs = Get-ChildItem -Path $buildDir -Filter '*.lib' -Recurse -ErrorAction SilentlyContinue
$exps = Get-ChildItem -Path $buildDir -Filter '*.exp' -Recurse -ErrorAction SilentlyContinue
if ($dlls) { $dlls | Copy-Item -Destination "$litertInstallDir\bin" -Force -ErrorAction SilentlyContinue; Write-Host "Copied $($dlls.Count) DLLs" }
if ($libs) { $libs | Copy-Item -Destination "$litertInstallDir\lib" -Force -ErrorAction SilentlyContinue; Write-Host "Copied $($libs.Count) LIBs" }
# Copy headers
$tfliteIncludeDir = Join-Path $tfliteSrc 'include'
if (Test-Path $tfliteIncludeDir) {
    New-Item -Path "$litertInstallDir\include" -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$tfliteIncludeDir\*" -Destination "$litertInstallDir\include\" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Copied headers from $tfliteIncludeDir"
}
Write-Host 'LiteRT manual install completed'

Write-Host '=== LiteRT source build completed ==='



