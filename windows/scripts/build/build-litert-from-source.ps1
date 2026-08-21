# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\litert-src',
    [string]$InstallDir = '',
    [string]$LiteRtVersion = ''
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

# LITERT REF SYNC: this default is the AUTHORITATIVE one. The v0.14
# support-graft in litert-lm-export-bridge.ps1 resolves the same LITERT_VERSION
# env with the same fallback -- a LiteRT bump must update BOTH defaults.
$LiteRtVersion = Get-SourceBuildVersion -Value $LiteRtVersion -EnvironmentVariables @('LITERT_VERSION') -DefaultValue 'v2.2.0'
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

# Inject the TFLite C API shared lib (tensorflowlite_c) into the MAIN build.
# gst-plugins-bad's tflite plugin resolves cc.find_library('tensorflowlite_c')
# FIRST and only falls back to the C++ `tensorflow-lite` lib -- which lacks the
# C API symbols like TfLiteInterpreterCreate -- when it is absent, so without
# this the gst tflite plugin fails meson configure. Upstream's own
# tflite/c/CMakeLists.txt CANNOT be reused: it is a STANDALONE project() that
# re-adds the whole tflite tree (a duplicate `tensorflow-lite` target) and
# hardcodes the pre-rename `tensorflow/lite/` layout that LiteRT no longer has.
# So append the target directly against THIS build's tensorflow-lite target and
# TFLITE_SOURCE_DIR (=CMAKE_CURRENT_LIST_DIR, the tflite dir). On WIN32,
# TFL_COMPILE_LIBRARY dllexports the C API and there are no version-script link
# flags, so it links cleanly under clang-cl. All four sources verified present.
$mainCmake = Join-Path $tfliteSrc 'CMakeLists.txt'
$capiSnippet = @'

# ---- tensorflowlite_c (TFLite C API) injected by build-litert-from-source.ps1 ----
if(NOT TARGET tensorflowlite_c)
  add_library(tensorflowlite_c SHARED
    ${TFLITE_SOURCE_DIR}/core/c/c_api.cc
    ${TFLITE_SOURCE_DIR}/core/c/c_api_experimental.cc
    ${TFLITE_SOURCE_DIR}/core/c/common.cc
    ${TFLITE_SOURCE_DIR}/core/c/operator.cc
  )
  target_compile_definitions(tensorflowlite_c PRIVATE TFL_COMPILE_LIBRARY)
  target_link_libraries(tensorflowlite_c tensorflow-lite)
  # tensorflow-lite adds -DTFL_STATIC_LIBRARY_BUILD as a PUBLIC compile option
  # (tflite/CMakeLists.txt), which this target INHERITS via the link above. In
  # c_api_types.h that macro is checked BEFORE TFL_COMPILE_LIBRARY and makes
  # TFL_CAPI_EXPORT expand to nothing -- so none of the C API (TfLiteInterpreter*
  # etc.) gets __declspec(dllexport) and the DLL exports zero C API symbols, so
  # gst-plugins-bad's tflite plugin fails to LINK. Let CMake generate a .def from
  # this target's own objects (c_api.cc, common.cc, ...) so the C API is exported
  # regardless of the macro -- independent of -D/-U ordering.
  set_target_properties(tensorflowlite_c PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
  # WINDOWS_EXPORT_ALL_SYMBOLS only exports THIS target's own object files
  # (c_api.cc, ...). The XNNPACK delegate C API (TfLiteXNNPackDelegate*) lives in
  # the linked-in tensorflow-lite static lib (TFLITE_ENABLE_XNNPACK=ON) and is
  # built without TFL_COMPILE_LIBRARY, so it is neither auto-exported nor
  # dllexport'd -- gst's tflite plugin needs it for the XNNPACK accelerator.
  # Force lld-link to pull those three from the static lib and export them.
  target_link_options(tensorflowlite_c PRIVATE
    /EXPORT:TfLiteXNNPackDelegateCreate
    /EXPORT:TfLiteXNNPackDelegateDelete
    /EXPORT:TfLiteXNNPackDelegateOptionsDefault
  )
endif()
'@
Add-Content -Path $mainCmake -Value $capiSnippet -Encoding ASCII
Write-Host "Injected tensorflowlite_c (TFLite C API) target into $mainCmake"

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

# Persistent log (backlog #43): inside $buildDir it dies with the failed solve.
$buildLog = Get-PersistentBuildLogPath -Name 'litert-build.log' -FallbackDir $buildDir
# The injected tensorflowlite_c target (see above) is a normal add_library, so
# `all` builds it alongside tensorflow-lite -- no separate target invocation
# needed. The manual-install gate below hard-fails if its import lib is missing.
# MemGBPerJob 2, not 4 (backlog #74) — see the note in build-onnx-genai.
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

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
# The TFLite C API import lib is a hard requirement for the gst-plugins-bad tflite
# plugin (fails loud HERE instead of hours later in the merge's meson configure).
if ('tensorflowlite_c.lib' -notin $installedLibs.Name) {
    throw ("LiteRT install is missing tensorflowlite_c.lib (the TFLite C API import lib) in $(Join-Path $litertInstallDir 'lib'). " +
        "The explicit tensorflowlite_c target build produced no import lib. Present: $($installedLibs.Name -join ', ')")
}
Write-Host "LiteRT manual install completed ($($installedLibs.Count) libs incl. tensorflowlite_c.lib)"

Remove-SourceBuildTree -Path $SourceDir

Complete-SourceBuild -Banner '=== LiteRT source build completed ==='  # cleanup + banner + exit 0 (see module help)