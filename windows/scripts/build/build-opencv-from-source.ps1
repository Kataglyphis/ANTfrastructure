# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\opencv-src',
    [string]$InstallDir = '',
    [string]$OpenCvVersion = ''
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

$OpenCvVersion = Get-SourceBuildVersion -Value $OpenCvVersion -EnvironmentVariables @('OPENCV_SOURCE_VERSION', 'OPENCV_VERSION') -DefaultValue '5.0.0'

Write-Host "=== OpenCV source build (branch $OpenCvVersion, Ninja+clang-cl) ==="

New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null
$mainSrc = Join-Path $SourceDir 'opencv'
Invoke-GitClone -RepoUrl 'https://github.com/opencv/opencv.git' -Branch $OpenCvVersion -SourceDir $mainSrc | Out-Null

$contribSrc = Join-Path $SourceDir 'opencv_contrib'
$contribOk = Invoke-GitClone -RepoUrl 'https://github.com/opencv/opencv_contrib.git' -Branch $OpenCvVersion -SourceDir $contribSrc -SkipOnFailure
if (-not $contribOk) { $contribSrc = ''; Write-Host 'Continuing without contrib modules' }

# Target arch is resolved HERE, before the patch block, because one patch below
# is ARM-only (see the softfloat float32_t collision).
$ocvTargetArch = Get-WindowsTargetArch
$ocvCross      = Test-WindowsCrossTarget -Arch $ocvTargetArch

# Source patches (idempotent git apply). These carry the Windows/clang-cl CUDA
# fixes -- see docs/windows-builds.md "Source Patch Policy":
#   opencv/001-cmake-clang-cl-compat.patch
#     - CMP0146/CMP0148 OLD -> NEW (CMake 4.x deprecation)
#     - OpenCVDetectCUDALanguage.cmake: allow CUDA detection under clang-cl
#     - OpenCVDetectCUDAUtils.cmake: strip clang-cl-only flags (/clang:, /FI,
#       -Xclang, -fopenmp, -W*) from the CUDA host (-Xcompiler) block, because
#       nvcc's Windows host compiler is cl.exe (rejects them; e.g. D8021 /Wno-undef)
#     - FindONNX.cmake: add_library instead of ocv_add_library on IMPORTED target
#   opencv_contrib/001-cudev-windows-llp64.patch
#     - cudev: define ulong/longlong/ulonglong and add 64-bit VecTraits/MakeVec so
#       CV_64U/CV_64S GpuMat conversions compile on Windows LLP64 (int64_t/uint64_t
#       are long long / unsigned long long, not long / ulong as on Unix LP64).
$patchDir = Join-Path $scriptAssetRoot 'patches'
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\001-cmake-clang-cl-compat.patch') -SourceDir $mainSrc -Description 'opencv: cmake clang-cl/CUDA compat' -IgnoreWhitespace
# OpenCV 5.0.0 bundles MLAS; its cmake treats clang-cl as GNU-Clang and passes
# the GNU pair `-include` + `cstring`, which the CL dialect parses as an INPUT
# FILE (clang-cl: error: no such file or directory: 'cstring' on the first
# mlas TU). The patch adds an MSVC-frontend branch using /FIcstring + /w.
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\002-mlas-clangcl-force-include.patch') -SourceDir $mainSrc -Description 'opencv: mlas clang-cl force-include' -IgnoreWhitespace
# Run-12 lesson (2026-08-10): 002 got the mlas C++ TUs compiling, then the
# GAS-only .S kernels (`.type sym,@function`, ELF directives) died in
# clang's integrated assembler for the COFF target. There is no MASM port
# of the vendored kernels; MSVC never hits this because check_language(ASM)
# finds no GAS there. 003 skips MLAS on Windows -> dnn's built-in SGEMM
# (inference in this stack runs on ONNX Runtime/DirectML anyway).
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\003-mlas-windows-skip.patch') -SourceDir $mainSrc -Description 'opencv: mlas Windows skip (GAS-only kernels)' -IgnoreWhitespace
# Run-13 lesson (2026-08-10): dnn's ORT profiling call passes char* to
# Ort::SessionOptions::EnableProfiling, but ORTCHAR_T is wchar_t on Windows
# (net_impl_backend.cpp:99) - the model-path call right below it IS guarded,
# this one is not; upstream Windows CI never builds dnn with ORT enabled.
# Genuine upstream bug, upstreamable as-is.
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\004-dnn-ort-profiling-wchar.patch') -SourceDir $mainSrc -Description 'opencv: dnn ORT profiling wchar_t path' -IgnoreWhitespace
if ($contribSrc) {
    Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv_contrib\001-cudev-windows-llp64.patch') -SourceDir $contribSrc -Description 'opencv_contrib: cudev Windows LLP64 64-bit VecTraits'
}

# FFmpeg 9 compatibility (backlog #94). A SCRIPT, not a .patch, on purpose: a
# unified diff must match upstream context byte for byte, while this edit only
# needs to find two accessor expressions — which survives OpenCV point releases
# far better. It carries its own no-op assertions (rule from #56): a pattern
# that matches nothing throws instead of quietly "succeeding", and a leftover
# direct field access after patching throws too.
# Only relevant when the chain's FFmpeg is actually linked; with the default
# prebuilt FFmpeg the videoio sources compile as they always did.
if ($env:OPENCV_LINK_CHAIN_FFMPEG -eq '1') {
    & (Join-Path $patchDir 'opencv\ffmpeg9-avcodec-config.ps1') -SourceDir $mainSrc
    if ($LASTEXITCODE -ne 0) { throw 'opencv: FFmpeg-9 videoio patch failed' }
}

# Inline patch (kept inline, NOT a .patch file): the mlas `<cstring>` include is
# a multi-file prepend loop that conditionally skips files which already include
# <cstring>. A static .patch cannot express the per-file conditional guard, so the
# loop form is the canonical representation. See docs/windows-builds.md "Source Patch Policy".
$mlasSrcDir = Join-Path $mainSrc '3rdparty\mlas'
if (Test-Path $mlasSrcDir) {
    Get-ChildItem -Path $mlasSrcDir -Filter '*.cpp' -Recurse | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        if ($content -notmatch '#include\s*<cstring>') {
            Set-Content -Path $_.FullName -Value ("#include <cstring>`n" + $content)
        }
    }
    Write-Host 'Patched mlas sources for clang-cl (added <cstring> include)'
}

# Inline patch, ARM targets ONLY (upstream bug, OpenCV 5.0.0 + clang aarch64).
#
# softfloat.cpp:163 does, INSIDE namespace cv:
#     typedef softfloat  float32_t;
#     typedef softdouble float64_t;
# intrin_neon.hpp also lives in namespace cv, so unqualified lookup for
# `float32_t` finds cv::float32_t BEFORE the ::float32_t (= float) that clang's
# arm_neon.h declares. Since clang 16 the NEON lane accessors are macros of the
# form `__ret = __builtin_bit_cast(float32_t, __builtin_neon_vgetq_lane_f32(..))`,
# and cv::softfloat has a user-provided copy ctor, so it is NOT trivially
# copyable -- which __builtin_bit_cast requires. Every v_extract_n instantiated
# in this TU then fails (measured 2026-08-23, LLVM 22.1.8):
#   intrin_neon.hpp(2202,1): error: '__builtin_bit_cast' destination type must
#                                    be trivially copyable
# x86 is unaffected: the SSE intrinsics never mention float32_t, which is why
# this has stayed invisible on the amd64 lane. Scoped to ARM so amd64 is
# byte-identical.
#
# The fix converts the two typedefs into OBJECT-LIKE MACROS. That is not a
# cosmetic difference, it is the whole mechanism: intrin_neon.hpp is textually
# preprocessed at `#include "precomp.hpp"` (line 66), long BEFORE line 163, so
# the template bodies keep a bare `float32_t` token that a later #define can no
# longer rewrite. Removing the typedef leaves nothing named cv::float32_t, so
# that token now resolves to ::float32_t (= float) exactly as clang intends,
# while every use AFTER line 163 -- i.e. all of the ported Berkeley SoftFloat
# code -- still expands to `softfloat` precisely as the typedef did. The file
# has no #include after line 163, so the macro cannot leak into a header.
# Upstream issue to file: see out/upstream-issue-litert-lm-cmake.md for the
# precedent this repo follows.
if ($ocvCross -and (Get-WindowsTargetArchInfo -Arch $ocvTargetArch).CMakeSystemProcessor -match 'ARM64') {
    $sfCpp = Join-Path $mainSrc 'modules\core\src\softfloat.cpp'
    [void](Invoke-InlineRegexPatch -Path $sfCpp -Guard 'typedef softfloat float32_t;' `
            -Pattern 'typedef\s+softfloat\s+float32_t;\s*\r?\n\s*typedef\s+softdouble\s+float64_t;' `
            -Replacement "#define float32_t softfloat`n#define float64_t softdouble" `
            -Description 'opencv softfloat.cpp: float32_t/float64_t typedef -> macro (NEON __builtin_bit_cast collision)')
    # Load-bearing drift assertion: if upstream renames or moves these typedefs,
    # a silent no-op here resurfaces as a wall of confusing bit_cast errors deep
    # inside arm_neon.h. Fail now, with the reason, instead.
    $sfText = [System.IO.File]::ReadAllText($sfCpp)
    if ($sfText -notmatch '#define\s+float32_t\s+softfloat') {
        throw "opencv softfloat.cpp: the float32_t/float64_t typedefs were not converted to macros (upstream layout changed?). intrin_neon.hpp will fail with '__builtin_bit_cast destination type must be trivially copyable'. Re-check $sfCpp."
    }

    # Third ARM-only inline patch, same class as 002/003: bundled MLAS assumes
    # "_M_ARM64 implies the MSVC compiler" and remaps two ACLE reduction
    # intrinsics onto MSVC's private spellings (mlasi.h):
    #     #if defined(_M_ARM64)
    #     #ifndef vmaxvq_f32
    #     #define vmaxvq_f32(src) neon_fmaxv(src)
    # clang-cl defines _M_ARM64 too, but implements the ACLE names and has no
    # neon_fmaxv/neon_fminv at all. The #ifndef guard does not save us: clang
    # provides vmaxvq_f32 as a FUNCTION, not a macro, so the guard is true and
    # MLAS shadows the real intrinsic. Result (measured 2026-08-23):
    #   mlasi.h(2771,12): error: use of undeclared identifier 'neon_fmaxv'
    # Each #define is wrapped rather than deleted, so a genuine MSVC build keeps
    # the mapping -- the condition being corrected is "which compiler", not
    # "which architecture". Matched on the #define lines themselves because the
    # upstream line numbers move between releases.
    # Idempotence is explicit here rather than via -Guard: the guard string would
    # still match AFTER patching (neon_fmaxv survives inside the wrapper), so a
    # re-run would nest a second wrapper around the same #define.
    $mlasiH = Join-Path $mainSrc '3rdparty\mlas\lib\mlasi.h'
    if (-not (Test-Path $mlasiH)) { throw "opencv mlasi.h not found at $mlasiH -- the bundled MLAS layout changed." }
    $mlasiText = [System.IO.File]::ReadAllText($mlasiH)
    if ($mlasiText -notmatch '#if !defined\(__clang__\)') {
        [void](Invoke-InlineRegexPatch -Path $mlasiH -Guard 'neon_fmaxv' `
                -Pattern '#define\s+(vmaxvq_f32|vminvq_f32)\(src\)\s+neon_(fmaxv|fminv)\(src\)' `
                -Replacement "#if !defined(__clang__)`n`$0`n#endif" `
                -Description 'opencv mlasi.h: MSVC neon_* remap excluded under clang-cl')
        $mlasiText = [System.IO.File]::ReadAllText($mlasiH)
    }
    if ($mlasiText -match 'neon_fmaxv' -and $mlasiText -notmatch '#if !defined\(__clang__\)') {
        throw "opencv mlasi.h: the MSVC neon_* remap is present but was not guarded for clang (upstream layout changed?). MLAS will fail with ""use of undeclared identifier 'neon_fmaxv'"". Re-check $mlasiH."
    }
}

# Canonical toolchain preamble: VsDevCmd (MSVC/SDK INCLUDE+LIB env — OpenCV
# needs them even without CUDA), pyconfig.h into Include\ (in-tree Windows
# CPython keeps it at PC\pyconfig.h; cv2's Python.h include chain needs it and
# earlier stages only HAPPENED to copy it), the win-amd64 platform-tag shim
# (must exist BEFORE pip runs so a 64-bit numpy is resolved), and the
# source-built python handle.
$ocvPy = Initialize-ToolchainPythonEnvironment
if (-not (Test-Path $ocvPy.Exe)) { throw "Source-built CPython not found at $($ocvPy.Exe) (toolchain layer missing?)" }

# EAP=Stop/StrictMode-safe interpreter query: capture output, gate on exit code
# and non-empty result, surface the full output on failure (a bare .ToString()
# on an error line used to feed garbage straight into the cmake args).
function Get-OcvPythonQueryResult {
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Label
    )
    $out = @(& $PythonExe -c $Code 2>&1)
    $exit = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    $last = if ($out.Count -gt 0) { $out[-1].ToString().Trim() } else { '' }
    if ($exit -ne 0 -or [string]::IsNullOrWhiteSpace($last)) {
        throw "python query '$Label' failed (exit $exit): $(($out -join [Environment]::NewLine))"
    }
    return $last
}

# Create FindPythonInterp.cmake stub directly in OpenCV's cmake dir so
# find_host_package(PythonInterp ...) finds it (CMAKE_MODULE_PATH is overridden
# by OpenCV's internal cmake scripts — placing it in the source tree avoids that).
$pythonModuleDir = Join-Path $mainSrc 'cmake'
$pyExePath = $ocvPy.Exe -replace '\\', '/'
# Version derived from canonical PYTHON_VERSION (versions.env via load-versions/ENV)
$pyVersion = if (-not [string]::IsNullOrWhiteSpace($env:PYTHON_VERSION)) { $env:PYTHON_VERSION } else { '3.14.7' }
$pyParts = $pyVersion -split '\.'
if ($pyParts.Count -lt 2) { throw "PYTHON_VERSION '$pyVersion' is not MAJOR.MINOR[.PATCH] -- cannot derive PYTHON_VERSION_MAJOR/MINOR" }
$findPythonInterpStub = @"
# Stub FindPythonInterp.cmake — CMake 4.x removed the original module.
set(PYTHONINTERP_FOUND TRUE)
set(PYTHON_EXECUTABLE "$pyExePath" CACHE FILEPATH "Python interpreter" FORCE)
set(PYTHON_VERSION_STRING "$pyVersion")
set(PYTHON_VERSION_MAJOR $($pyParts[0]))
set(PYTHON_VERSION_MINOR $($pyParts[1]))
set(PYTHON_VERSION_PATCH $(if ($pyParts.Count -ge 3) { $pyParts[2] } else { 0 }))
mark_as_advanced(PYTHONINTERP_FOUND PYTHON_EXECUTABLE)
"@
Set-Content -Path (Join-Path $pythonModuleDir 'FindPythonInterp.cmake') -Value $findPythonInterpStub
Write-Host "Created FindPythonInterp.cmake stub for Python $pyVersion"

# Python bindings (cv2): numpy is required at configure + compile time (the
# platform-tag shim was written by Initialize-ToolchainPythonEnvironment above,
# before this pip run resolves wheels).
Install-CpythonPip -Python $ocvPy
Invoke-CpythonPip -Python $ocvPy -Arguments @('install', '--quiet', 'numpy')
$numpyInclude = (Get-OcvPythonQueryResult -PythonExe $ocvPy.Exe -Code 'import numpy; print(numpy.get_include())' -Label 'numpy include dir') -replace '\\', '/'
if (-not (Test-Path $numpyInclude)) { throw "numpy include dir not resolved (got '$numpyInclude')" }
Write-Host "numpy include: $numpyInclude"

$buildDir = Join-Path $SourceDir 'build'
$ocvInstallDir = Join-Path $InstallDir 'lib\opencv5'

# (MSVC/SDK INCLUDE+LIB env vars were loaded by the toolchain preamble above.)

# Pre-create the bin/ directory so OpenCV's cmake file(COPY ...) for the bundled
# ONNX Runtime download has a valid destination (avoids "Invalid argument" error
# on Windows when the destination directory doesn't exist yet during configure).
$null = New-Item -Path (Join-Path $buildDir 'bin') -ItemType Directory -Force

# $ocvTargetArch / $ocvCross are resolved above, before the patch block.
# Arch-aware. amd64 is byte-identical: Get-WindowsX86SimdFlags IS
# `Get-WindowsTargetSimdFlags -Arch amd64` (back-compat shim), and
# $crossTargetFlag below is EMPTY on the host arch. arm64 returns NO baseline
# SIMD flags on purpose: NEON is mandatory in the AArch64 baseline, and
# dotprod/i8mm/SVE are runtime-dispatch decisions, never a global -m flag.
#
# CPU_BASELINE / CPU_DISPATCH are deliberately NOT introduced for either lane:
# this script has never passed them, so OpenCV's own defaults are what ships
# today. Adding them on amd64 would change every emitted per-file command line,
# which the arm64 work is not allowed to cost.
$simdFlags = Get-WindowsTargetSimdFlags -Arch $ocvTargetArch
# The clang target triple has to ride in THIS script's explicit CMAKE_C_FLAGS /
# CMAKE_CXX_FLAGS strings, not only in Get-CMakeCrossArgs' CMAKE_*_FLAGS_INIT:
# passing -DCMAKE_C_FLAGS on the command line DEFINES the cache variable, and
# CMake then never applies CMAKE_C_FLAGS_INIT at all. Without this, an "arm64"
# OpenCV would configure green and emit x86_64 objects -- the exact silent
# wrong-arch failure the arch module exists to prevent.
$crossTargetFlag = if ($ocvCross) { "--target=$(Get-ClangTargetTriple -Arch $ocvTargetArch)" } else { '' }
# _USE_MATH_DEFINES is required by OpenCV's ARM NEON HAL (hal/carotene), which is
# compiled ONLY for ARM targets and so has never been exercised on this chain.
# It uses M_PI, which the C standard does not mandate and the MSVC CRT headers
# withhold unless this macro is defined -- carotene assumes POSIX behaviour:
#   hal\carotene\src\phase.cpp(121,5): error: use of undeclared identifier 'M_PI'
# (measured 2026-08-23). Scoped to the cross branch so the amd64 command line is
# untouched; carotene is not built there at all.
$mathDefinesFlag = if ($ocvCross) { '/D_USE_MATH_DEFINES' } else { '' }
# AArch64 compressed jump tables overflow their one-byte entries in switch-heavy
# code and abort the compile with a diagnostic that names no source file:
#     error: value evaluated as 284 is out of range.
# AArch64AsmPrinter::emitJumpTableImpl emits a compressed entry as
# (LBB - Base) >> 2 through MCObjectStreamer::emitValueImpl with Size = 1, and
# that is the ONLY producer of this message in LLVM. Every value measured here
# lands just past 255*4 = 1020 bytes of table span: 256, 259, 262, 272, 284
# (=1024/1036/1048/1088/1136). Disabling the compression pass keeps FULL /O2 --
# uncompressed tables are merely larger, not slower.
#
# This replaced a per-TU /Od workaround that was based on a WRONG root cause
# (an 8-bit .xdata "Code Words" unwind field). That story was refuted from
# primary source: MCWin64EH.cpp reports the Code-Words ceiling as
# report_fatal_error("SEH unwind data splitting is only implemented for large
# functions ..."), which is a different message entirely. The jump-table
# explanation also accounts for what /Od-vs-/Ob0 actually did:
# AArch64CompressJumpTables only runs when getOptLevel() != None, so /Od
# switched the pass off wholesale while /Ob0 merely reshuffled which TU
# overflowed. Switch-heavy code is the common thread in every offender found
# (protobuf descriptors, the TIFF decoder, G-API graph serialisation).
$jumpTableFlag = if ($ocvCross) { '-mllvm -aarch64-enable-compress-jump-tables=false' } else { '' }
$simdFlags = (@($simdFlags, $crossTargetFlag, $mathDefinesFlag, $jumpTableFlag) | Where-Object { $_ }) -join ' '

# EXPERIMENT KNOB (2026-08-18, rides with OPENCV_CUDA_LAUNCHER): OpenCV's
# nvcc command lines go through CMake response files, which sccache passes
# through UNCACHED (measured: 2018 requests, zero CUDA cache categories) -
# so a wrapped OpenCV CUDA compile is bare-but-green and wins nothing.
# OPENCV_CUDA_NO_RSP=1 disables the CUDA response files so the calls arrive
# inline and enter sccache's nvcc decomposition. ONLY meaningful once the
# quote-protection fix ships (#114 / mozilla/sccache#2811) - without it,
# inline calls inherit the dropped-instantiation miscompile. Command-length
# risk: ninja spawns directly (32,767-char limit); OpenCV's lists are ~5-8k,
# and an overflow fails loudly at build, not silently.
$cudaRspArgs = @()
if ($env:OPENCV_CUDA_NO_RSP -eq '1') {
    Write-Host 'OPENCV_CUDA_NO_RSP=1: disabling CUDA response files (inline nvcc args -> sccache decomposition reachable)'
    $cudaRspArgs = @(
        '-DCMAKE_CUDA_USE_RESPONSE_FILE_FOR_INCLUDES:BOOL=OFF',
        '-DCMAKE_CUDA_USE_RESPONSE_FILE_FOR_LIBRARIES:BOOL=OFF',
        '-DCMAKE_CUDA_USE_RESPONSE_FILE_FOR_OBJECTS:BOOL=OFF'
    )
}

$cmakeExtra = $cudaRspArgs + @(
    # Suppress CMake policy deprecation warnings baked into OpenCV's own CMakeLists.txt
    # (CMP0146: cmake_minimum_required version range; CMP0148: FindPython* deprecation;
    #  CMP0177: install() DESTINATION path normalisation).
    '-DCMAKE_POLICY_DEFAULT_CMP0146=NEW',
    '-DCMAKE_POLICY_DEFAULT_CMP0148=NEW',
    '-DCMAKE_POLICY_DEFAULT_CMP0177=NEW',
    '-DCMAKE_CXX_STANDARD=17',
    # /FI<cstring> fixes clang-cl -include cstring ambiguity (file vs header)
    "-DCMAKE_C_FLAGS:STRING=$simdFlags",
    # -Wno-deprecated-copy: core/matx.hpp declares a user-provided copy CTOR for
    # every Matx<> specialisation, so clang deprecates each implicit copy
    # ASSIGNMENT operator. matx.hpp is included by nearly every OpenCV TU, which
    # made this ~7 700 lines -- the single largest warning flood in the chain
    # (16 % of a 459 061-line build log was upstream warnings). It is noise from
    # upstream's own header, not from anything this repo writes.
    # The parent group is used deliberately, not the narrower
    # -Wdeprecated-copy-with-user-provided-copy: the parent has existed far
    # longer, and an unknown -Wno- is only a warning to clang, never an error.
    # Safe for the CUDA path: ocv_cuda_filter_options strips /clang:*, /FI*,
    # -Xclang, -fopenmp AND -W* from CMAKE_CXX_FLAGS before handing them to
    # nvcc's cl.exe host compiler (patches/opencv/001-cmake-clang-cl-compat.patch)
    # -- cl.exe would reject a GNU-style -W flag with D8021.
    # Verify the count actually dropped: windows\scripts\diagnostics\Measure-BuildWarnings.ps1
    "-DCMAKE_CXX_FLAGS:STRING=/FIcstring $(Get-WarningNoiseSuppressionFlags) $simdFlags",
    '-DBUILD_TESTS=OFF', '-DBUILD_PERF_TESTS=OFF', '-DBUILD_EXAMPLES=OFF',
                         # BUILD_opencv_world=OFF: avoids FFmpeg/ONNX importing issues
                         '-DBUILD_opencv_world=OFF',
    '-DBUILD_JPEG=ON', '-DBUILD_PNG=ON', '-DBUILD_TIFF=ON', '-DBUILD_WEBP=ON',
    '-DBUILD_OPENJPEG=ON', '-DBUILD_HARFBUZZ=ON', '-DBUILD_TBB=OFF',  # source build only on ARM Windows
    '-DBUILD_CLAPACK=ON', '-DBUILD_IPP_IW=ON',
    # cv2 python module: cmake --install drops it into CPython's site-packages
    # (queried from the interpreter); the media merge fans site-packages into the
    # shipped image. numpy include dir resolved above.
    # Python bindings are OFF for a cross build: nothing can execute the target
    # interpreter here, so an aarch64 cv2.pyd could never be imported by this
    # container's x64 CPython, and OpenCV's binding generation is a host-
    # interpreter fact that does not describe the target.
    "-DBUILD_opencv_python3=$(if ($ocvCross) { 'OFF' } else { 'ON' })", '-DBUILD_opencv_java=OFF', '-DBUILD_opencv_apps=OFF',
    # opencv_contrib dnn_superres references ENGINE_CLASSIC removed in OpenCV 5.x DNN
    '-DBUILD_opencv_dnn_superres=OFF',
    '-DWITH_TBB=ON', '-DWITH_IPP=ON', '-DWITH_OPENCL=ON', '-DWITH_OPENEXR=ON',
    # WITH_OPENGL=OFF: WITH_OPENGL=ON makes opencv_core*.dll hard-import OPENGL32.dll,
    # which the Windows Server Core base image lacks -> every OpenCV DLL fails to load
    # (0xC0000135 STATUS_DLL_NOT_FOUND) in the final image. A headless container needs no
    # GL windowing; this was caught by the smoke-test OpenCV link+run gate.
    '-DWITH_OPENGL=OFF', '-DWITH_DIRECTX=ON', '-DWITH_DIRECTML=ON',
    '-DWITH_VULKAN=ON', '-DWITH_EIGEN=ON',
    # ONNX Runtime enabled -- OpenCV auto-detects our source-built ORT via PKG_CONFIG_PATH.
    # If not found via pkg-config, OpenCV falls back to its bundled download (v1.25.1).
                         '-DWITH_ONNXRUNTIME=ON',
    # WITH_MSMF=OFF *and* WITH_OBSENSOR=OFF: Server Core ships NO Media Foundation
    # (MF.dll/MFPlat.DLL/MFReadWrite.dll). BOTH backends hard-import it into
    # opencv_videoio510.dll -- obsensor (Orbbec depth cams, default ON) does so
    # INDEPENDENTLY of WITH_MSMF via its MSMFStreamChannel UVC path, which is why
    # MSMF=OFF alone still produced an unloadable videoio (dep-walk 2026-07-13).
    # Any consumer linking all modules (the cv2 pyd!) then dies 0xC0000135. Same
    # class as the WITH_OPENGL=OFF fix; FFmpeg + GStreamer backends remain.
    '-DWITH_VTK=OFF', '-DWITH_MSMF=OFF', '-DWITH_OBSENSOR=OFF', '-DWITH_FFMPEG=ON', '-DWITH_GSTREAMER=ON',
    # NB: OPENCV_FFMPEG_SKIP_DOWNLOAD is deliberately NOT set — see the block
    # below the flag list. Setting it produced `FFMPEG: NO` (measured 2026-08-16,
    # a real regression), because OpenCV's Windows pkg-config fallback is gated
    # on PKG_CONFIG_FOUND, which is never set on this platform. Backlog #94.
    # WITH_OPENMP=OFF: clang-cl compiles `#pragma omp` (e.g. contrib surface_matching)
    # into __kmpc_* runtime calls but the generated link line never includes libomp.lib
    # -> lld-link "undefined symbol: __kmpc_fork_call". TBB (WITH_TBB=ON above) is
    # OpenCV's preferred cv::parallel backend anyway, so no parallelism is lost.
    '-DWITH_OPENCL_SVM=ON', '-DWITH_OPENMP=OFF',
    # NVCUVID/NVCUVENC require the NVIDIA Video Codec SDK (separate download, not in container)
    '-DWITH_NVCUVID=OFF', '-DWITH_NVCUVENC=OFF'
    # NB: CUDA (WITH_CUDA/CUDNN/CUBLAS + ENABLE_CUDA_FIRST_CLASS_LANGUAGE + the cv::dnn CUDA
    # backend) is added in the GPU-guarded block below, ONLY when an nvidia CUDA toolkit is
    # detected. Enabling it here unconditionally would make a CPU-only build enable_language(CUDA)
    # with no nvcc present and fail to configure.
)

# --- cross-lane deltas (a later -D of the same cache var wins) ----------------
# Everything here is x86-only or has no ARM64 import library. Appended rather
# than folded into the array above so the amd64 command line stays byte-identical
# and the reason for each override stays attached to it.
if ($ocvCross) {
    # IPP is Intel's x86-only primitives library; there is no AArch64 build of it
    # at all. OpenCV still resolved and unpacked 3rdparty/ippicv/ippicv_win here,
    # so its headers were already on the include path of every core TU (visible in
    # the failing include chain: private.hpp:220 -> ippicv.h). Even had that
    # compiled, the staged .lib is x64 COFF and lld-link would reject it against an
    # arm64 image. BUILD_IPP_IW builds the IPP integration wrapper, which is
    # meaningless without IPP.
    $cmakeExtra += '-DWITH_IPP=OFF', '-DBUILD_IPP_IW=OFF'
    # DirectML: OFF here is SEQUENCING, not a platform gap. The claim recorded
    # until 2026-08-23 -- that DirectML ships no arm64 import library -- was wrong:
    # Microsoft.AI.DirectML 1.15.4 ships bin/arm64-win/DirectML.lib (machine
    # 0xAA64). ONNX Runtime failed on an upper/lower-case path mismatch in its own
    # CMake, patched under backlog #113, and now builds USE_DML=ON on this lane.
    # OpenCV stays OFF until that is proven green: cv::dnn would otherwise
    # advertise a backend whose runtime half of the stack is unverified.
    $cmakeExtra += '-DWITH_DIRECTML=OFF'
    # INSTALL LAYOUT. OpenCV composes <root>\<OpenCV_ARCH>\<OpenCV_RUNTIME>\{bin,lib}
    # and its ARM64 branch in OpenCVDetectCXXCompiler.cmake keys off
    #     elseif("${CMAKE_GENERATOR_PLATFORM}" MATCHES "ARM64")
    # which ONLY the Visual Studio generator sets. This chain is Ninja-only, so
    # detection falls through to the x64 branch and an aarch64 build installs
    # into ...\opencv5\x64\vc18\ -- while OPENCV_LIB/OPENCV_BIN (baked as ENV by
    # Dockerfile.media-merge-builder) and build-gstreamer's fallback both look
    # under the TARGET arch dir. GStreamer then dies with:
    #   ERROR: no import libraries found in C:\runtime\lib\opencv5\arm64\vc18\lib
    # Note this is the opposite of what build-buildkit.ps1's OPENCV_ARCH_DIR
    # comment predicted: the consumers were right, the producer was wrong.
    #
    # OpenCV ships an explicit override for exactly this case, as the FIRST
    # branch of the detection chain (OpenCVDetectCXXCompiler.cmake:150):
    #     if(DEFINED OpenCV_ARCH AND DEFINED OpenCV_RUNTIME)
    #       # custom overridden values
    #     elseif(MSVC)
    #       ...
    # BOTH must be defined or the branch never fires and MSVC detection runs
    # instead -- which is why the runtime is passed too, even though only the
    # arch is wrong. CMake variable names are case-sensitive and these are the
    # exact spellings, matching what OpenCVInstallLayout.cmake then reads.
    # 'vc18' is what OpenCV's own MSVC_VERSION mapping picks for the pinned
    # toolset (`elseif(MSVC_VERSION MATCHES "^195[0-9]$") set(OpenCV_RUNTIME vc18)`)
    # and the literal already hardcoded in Dockerfile.media-merge-builder,
    # build-gstreamer-from-source.ps1 and smoke-test-container.ps1.
    $cmakeExtra += "-DOpenCV_ARCH=$(Get-OpenCvArchDir -Arch $ocvTargetArch)", '-DOpenCV_RUNTIME=vc18'
    Write-Host "OpenCV cross ($ocvTargetArch): WITH_IPP=OFF (x86-only), BUILD_IPP_IW=OFF, WITH_DIRECTML=OFF (sequencing: ORT arm64 DML unverified, backlog #113 -- NOT a missing import lib), install layout -> $(Get-OpenCvArchDir -Arch $ocvTargetArch)\vc18"
}

# --- FFmpeg discovery for videoio (backlog #94) -------------------------------
# The chain builds FFmpeg BEFORE OpenCV (swapped 2026-08-16) and puts its .pc
# files on PKG_CONFIG_PATH here. That much is correct and stays — other probes
# (ONNX Runtime) use the same mechanism.
#
# WHAT DOES NOT WORK, MEASURED: adding `-DOPENCV_FFMPEG_SKIP_DOWNLOAD=ON` to
# make OpenCV link THIS FFmpeg instead of downloading its own turned
# `FFMPEG: YES (prebuilt binaries)` into a flat `FFMPEG: NO` — strictly worse.
# Reverted the same day. The reason is in OpenCV's own
# modules/videoio/cmake/detect_ffmpeg.cmake (5.0.0), where the pkg-config route
# is guarded by:
#
#     if(NOT HAVE_FFMPEG AND PKG_CONFIG_FOUND)
#
# `PKG_CONFIG_FOUND` comes from find_package(PkgConfig), which OpenCV does not
# run on Windows — so skipping the download removes the only detection path that
# was working and the fallback never fires, no matter what PKG_CONFIG_PATH says.
# pkg-config itself is fine here: `pkg-config --modversion libavcodec` returns
# 63.1.100 inside the same image.
#
# So a real #94 fix has to give CMake a detection route it actually takes on
# Windows — the find_package branch (OPENCV_FFMPEG_USE_FIND_PACKAGE, which needs
# a FindFFMPEG providing AVCODEC/AVFORMAT/AVUTIL/SWSCALE), or setting
# PKG_CONFIG_FOUND/HAVE_FFMPEG plus the FFMPEG_* variables directly. Do not try
# SKIP_DOWNLOAD again on its own; that experiment has been run.
$ffPkgConfig = Join-Path $InstallDir 'ffmpeg\lib\pkgconfig'
if (Test-Path $ffPkgConfig) {
    $pcParts = @($ffPkgConfig) + @($env:PKG_CONFIG_PATH -split ';' | Where-Object { $_ })
    $env:PKG_CONFIG_PATH = ($pcParts | Select-Object -Unique) -join ';'
    Write-Host "PKG_CONFIG_PATH = $env:PKG_CONFIG_PATH"
} else {
    Write-Host "NOTE: no FFmpeg pkgconfig dir at $ffPkgConfig (harmless today; OpenCV uses its own prebuilt FFmpeg — backlog #94)"
}

# cv2 python module inputs. OpenCV 5.x's find_python() still round-trips through
# find_package(PythonInterp)/find_package(PythonLibs) -- BOTH removed in CMake
# 4.x -- so its detection can never succeed here and python3 silently drops out
# of the module list (cost one rebuild to learn, 2026-07-12). find_python() is
# wrapped in `if(NOT PYTHON3INTERP_FOUND)`, so preset EVERY output it would
# produce and skip detection wholesale (forward slashes for CMake).
$numpyVersion = Get-OcvPythonQueryResult -PythonExe $ocvPy.Exe -Code 'import numpy; print(numpy.__version__)' -Label 'numpy version'
$pyLibFwd = ($ocvPy.Lib) -replace '\\', '/'
$pyIncFwd = ($ocvPy.Include) -replace '\\', '/'
$cmakeExtra += '-DPYTHON3INTERP_FOUND=TRUE'
$cmakeExtra += "-DPYTHON3_EXECUTABLE=$pyExePath"
$cmakeExtra += "-DPYTHON3_VERSION_STRING=$pyVersion"
$cmakeExtra += "-DPYTHON3_VERSION_MAJOR=$($pyParts[0])"
$cmakeExtra += "-DPYTHON3_VERSION_MINOR=$($pyParts[1])"
$cmakeExtra += '-DPYTHON3LIBS_FOUND=TRUE'
$cmakeExtra += "-DPYTHON3LIBS_VERSION_STRING=$pyVersion"
$cmakeExtra += "-DPYTHON3_LIBRARY=$pyLibFwd"
$cmakeExtra += "-DPYTHON3_LIBRARIES=$pyLibFwd"
$cmakeExtra += "-DPYTHON3_INCLUDE_DIR=$pyIncFwd"
$cmakeExtra += "-DPYTHON3_INCLUDE_PATH=$pyIncFwd"
# site-packages derived from the python handle (Include = <cpython>\Include),
# not hardcoded to C:/temp -- the cpython tree location is owned by the toolchain.
$pySitePackagesFwd = (Join-Path (Split-Path $ocvPy.Include -Parent) 'Lib\site-packages') -replace '\\', '/'
$cmakeExtra += "-DPYTHON3_PACKAGES_PATH=$pySitePackagesFwd"
$cmakeExtra += "-DPYTHON3_NUMPY_INCLUDE_DIRS=$numpyInclude"
$cmakeExtra += "-DPYTHON3_NUMPY_VERSION=$numpyVersion"

# Provide our source-built ONNX Runtime root so FindONNX.cmake finds it
# (derived from $InstallDir -- forward slashes for the cmake arg).
$ortRoot = (Join-Path $InstallDir 'lib\onnxruntime-source') -replace '\\', '/'
if (Test-Path "$ortRoot/include/onnxruntime/onnxruntime_c_api.h") {
    $cmakeExtra += "-DONNXRT_ROOT_DIR=$ortRoot"
    Write-Host "ONNX Runtime found at $ortRoot"
}

# Enable CUDA via CMake's first-class language support (ENABLE_CUDA_FIRST_CLASS_LANGUAGE=ON
# above tells OpenCV to use modern CUDA detection instead of the deprecated FindCUDA.cmake).
# Get-GpuEnvironment sets $env:CUDA_PATH / CUDA_HOME and prepends CUDA bin to PATH; we only
# need CUDACXX on top (CMake's built-in enable_language(CUDA) probe uses it).
$gpuEnv = Get-GpuEnvironment
# Cross lane: NEVER take CUDA from a HOST probe. Get-GpuEnvironment answers "does
# this windows/amd64 BUILD HOST have a CUDA toolkit", which says nothing about the
# target -- and there is no CUDA/cuDNN/TensorRT for Windows-on-ARM at all. A bare
# host probe here would enable_language(CUDA), point nvcc at x64 device libs and
# link them into an "arm64" OpenCV. The driver already refuses -Gpu with a
# non-amd64 -TargetArch; this enforces the same rule where the decision is
# actually made, so a direct script invocation cannot bypass it.
if ($gpuEnv.HasCuda -and -not (Test-WindowsCrossTarget -Arch $ocvTargetArch)) {
    $env:CUDACXX = Join-Path $gpuEnv.CudaRoot 'bin\nvcc.exe'
    $cmakeExtra += '-DWITH_CUDA=ON', '-DWITH_CUDNN=ON', '-DWITH_CUBLAS=ON'
    $cmakeExtra += '-DENABLE_CUDA_FIRST_CLASS_LANGUAGE=ON', '-DOPENCV_DNN_CUDA=ON'
    # nvcc requires MSVC cl.exe as the host compiler on Windows.
    # clang-cl-only flags forwarded via -Xcompiler (e.g. /Wno-undef,
    # /clang:*, /FIcstring) are stripped from the CUDA host block by the
    # ocv_cuda_filter_options patch (opencv/001-cmake-clang-cl-compat.patch).
    # Provide CUDAToolkit_ROOT + CUDAToolkit_DIR so CMake's CONFIG-mode
    # find_package(CUDAToolkit) can find CUDA 13.3 (MODULE mode broken in CMake 4.x).
    $cRootFwd = $gpuEnv.CudaRoot -replace '\\', '/'
    $cmakeExtra += "-DCUDAToolkit_ROOT=$cRootFwd"
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$cRootFwd"
    $cmakeExtra += "-DCMAKE_CUDA_COMPILER:FILEPATH=$($env:CUDACXX -replace '\\', '/')"
    $cmakeExtra += "-DCMAKE_CUDA_ARCHITECTURES=$(Get-CudaArchitectureList -Decoration '-real')"
} else {
    $cmakeExtra += '-DWITH_CUDA=OFF'
    Write-Host 'OpenCV: no CUDA toolkit detected -> building CPU-only (WITH_CUDA=OFF)'
}

# CMAKE_AR: find llvm-lib on PATH and pass full path
$cmakeExtra += Get-LlvmArchiverCmakeArg

if ($contribSrc) {
    $cmakeExtra += "-DOPENCV_EXTRA_MODULES_PATH=$(Join-Path $contribSrc 'modules')"
    $cmakeExtra += '-DOPENCV_FORCE_3RDPARTY_BUILD=ON'
}

# --- link the CHAIN's FFmpeg instead of a downloaded prebuilt (backlog #94) ---
# Three flags that only work TOGETHER:
#   CMAKE_PROJECT_INCLUDE  runs find_package(PkgConfig) right after project(),
#                          which is the piece OpenCV skips on Windows and the
#                          sole reason its pkg-config route never fires here.
#   SKIP_DOWNLOAD          stops OpenCV grabbing its own prebuilt FFmpeg, which
#                          would otherwise satisfy HAVE_FFMPEG first and make
#                          the pkg-config branch unreachable.
#   ENABLE_LIBAVDEVICE     picks up libavdevice too; the prebuilt route left
#                          `avdevice: NO`, which #94 lists as part of the defect.
# Passing SKIP_DOWNLOAD without the shim was measured on 2026-08-16 and produced
# `FFMPEG: NO` — strictly worse than the prebuilt. Keep them together or not at all.
# DEFAULT ON since 2026-08-17 (the ARG in Dockerfile.media-builder's opencv
# stage defaults to 1; opt out with -BuildArg OPENCV_LINK_CHAIN_FFMPEG=).
# Full-chain verified: smoke gate 188/1/1, all three #94 assertions green in
# the shipped image (FFmpeg backend present, avdevice YES, avcodec major ==
# the chain's 63).
#
# The three parts below only work TOGETHER with the FFmpeg-9 source patch
# applied earlier in this script (ffmpeg9-avcodec-config.ps1): OpenCV 5.0.0's
# videoio does not compile against FFmpeg n9.0 without it — AVCodec::pix_fmts
# and ::supported_framerates were REMOVED in favour of
# avcodec_get_supported_config().
# Report the switch's OBSERVED value, always. A `--opt build-arg` for an ARG the
# Dockerfile does not declare is discarded by BuildKit without a warning, so an
# opt-in can silently never arrive — that happened here on 2026-08-16 and cost a
# 25-minute run that looked like "the flag does not work". One printed line is
# the difference between diagnosing that in seconds and rebuilding to find out.
Write-Host "OPENCV_LINK_CHAIN_FFMPEG='$($env:OPENCV_LINK_CHAIN_FFMPEG)' (empty = OpenCV uses its own prebuilt FFmpeg)"

$ocvShim = Join-Path $scriptAssetRoot 'patches\opencv\pkgconfig-shim.cmake'
if ($env:OPENCV_LINK_CHAIN_FFMPEG -eq '1' -and (Test-Path $ocvShim)) {
    Write-Host 'OPENCV_LINK_CHAIN_FFMPEG=1: linking the chain FFmpeg (needs the AVCodec source patch — backlog #94)'
    $cmakeExtra += "-DCMAKE_PROJECT_INCLUDE=$($ocvShim -replace '\\', '/')"
    $cmakeExtra += '-DOPENCV_FFMPEG_SKIP_DOWNLOAD=ON'
    $cmakeExtra += '-DOPENCV_FFMPEG_ENABLE_LIBAVDEVICE=ON'
} else {
    Write-Host 'OpenCV uses its own prebuilt FFmpeg (backlog #94 blocked on an OpenCV-5.0.0-vs-FFmpeg-9 source patch)'
}

# `| Out-Null` used to sit here and swallowed the ENTIRE configure output —
# every `-- ...` STATUS line CMake emits, including OpenCV's own
# "FFMPEG is disabled" explanation and this build's pkgconfig-shim message.
# When the FFmpeg gate below first fired there was literally nothing to read,
# which is a "never swallow logs" violation at exactly the moment the log
# matters. Tee to a persistent path instead (survives the failed solve, #43).
$cfgLog = Get-PersistentBuildLogPath -Name 'opencv-configure.log' -FallbackDir $buildDir
Invoke-CmakeConfigure -SourceDir $mainSrc -BuildDir $buildDir -InstallPrefix $ocvInstallDir -ExtraArgs $cmakeExtra 2>&1 |
    Tee-Object -FilePath $cfgLog | Out-Null
Write-Host "CMake configure log: $cfgLog"

# GATE: prove FFmpeg was actually detected before spending ~20 min compiling.
# Without this the failure mode is silent — a configure that quietly drops the
# backend still builds, still installs, still passes every existing test, and the
# loss only surfaces when someone calls cv::VideoCapture in production. That is
# precisely how #93/#94 survived for months, and how the 2026-08-16 SKIP_DOWNLOAD
# attempt shipped `FFMPEG: NO` into an image before a probe caught it.
# cvconfig.h is the authoritative artifact: CMake writes #define HAVE_FFMPEG
# there only when detection succeeded.
# DO NOT gate on cvconfig.h. `HAVE_FFMPEG` DOES NOT EXIST in OpenCV 5.0.0's
# cmake/templates/cvconfig.h.in (verified against the 5.0.0 tag) — videoio
# backend flags are not emitted there any more, so a gate looking for it fails
# 100 % of the time no matter what was detected. That produced two false build
# failures on 2026-08-16 while the configure log plainly showed FFmpeg found
# with avcodec 63.1.100. Cost: two ~25-minute rebuilds chasing a defect in the
# gate rather than in the build.
#
# The authoritative signal is OpenCV's own configure summary — the same text
# `cv2.getBuildInformation()` reproduces at runtime, which is what backlog #95
# asserts on. Read it from the log captured above.
$chainAvcodecMajor = ''
$ffProbe = Join-Path $InstallDir 'ffmpeg\bin\ffmpeg.exe'
if (Test-Path $ffProbe) {
    # ffmpeg.exe needs its own bin dir on PATH to resolve avcodec-63.dll etc.;
    # without it the exe dies on startup, the version reads back EMPTY, and this
    # gate degraded to "provenance unverified" in every build (the probe's
    # recurring `chain=?`). Same fix as in smoke-test-container.ps1.
    #
    # #112 root cause (measured in-image 2026-08-19): the bin dir alone is NOT
    # enough - avfilter-12.dll statically imports onnxruntime.dll
    # (--enable-libonnxruntime links the chain's ORT), which lives under
    # lib\onnxruntime-source, so ffmpeg.exe still died 0xC0000135
    # STATUS_DLL_NOT_FOUND with an EMPTY version and chain='' every build.
    $ffBinDir = Split-Path $ffProbe -Parent
    $probeDirs = @($ffBinDir)
    $ortDll = Get-ChildItem (Join-Path $InstallDir 'lib\onnxruntime-source') -Recurse -Filter 'onnxruntime.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ortDll) { $probeDirs += $ortDll.DirectoryName }
    $savedPath = $env:PATH
    try {
        $env:PATH = ($probeDirs -join ';') + ';' + $env:PATH
        if (Test-WindowsCrossTarget -Arch $ocvTargetArch) {
            # ffmpeg.exe here is a TARGET binary; running it on this x64 host
            # yields a loader error, not a version string. The value it produces
            # ($chainAvcodecMajor) only feeds the FFmpeg-vs-OpenCV consistency
            # gate below, so leaving it empty degrades that gate to the
            # configure-log evidence it already reads -- rather than reporting a
            # bogus 0xC0000135 as if it were a missing DLL.
            Write-Host 'Skipping the ffmpeg.exe version probe: cross build (a target binary cannot execute on this host)'
            $ffVer = ''
            $ffExit = 0
        } else {
            $ffVer = & $ffProbe -version 2>&1 | Out-String
            $ffExit = $LASTEXITCODE
        }
    } finally { $env:PATH = $savedPath }
    if ($ffVer -match '(?m)^\s*libavcodec\s+(\d+)\.') { $chainAvcodecMajor = $Matches[1] }
    elseif ($ffExit -ne 0) {
        # Never swallow the loader's verdict again: 0xC0000135 with empty
        # output is a missing-DLL signature, not a parse miss.
        Write-Host ("NOTE: ffmpeg.exe -version exited {0} (0x{0:X8}) with no parseable output - probe dirs: {1}" -f $ffExit, ($probeDirs -join ';'))
    }
}
$cfgText = if (Test-Path $cfgLog) { Get-Content $cfgLog -Raw } else { '' }
$cfgFfmpegYes = $cfgText -match '(?m)^\s*--\s+FFMPEG:\s+YES'
$cfgAvcodecMajor = ''
if ($cfgText -match '(?m)^\s*--\s+avcodec:\s+(?:YES\s*\()?(\d+)\.') { $cfgAvcodecMajor = $Matches[1] }

Write-Host "FFmpeg gate inputs: configure says FFMPEG=$(if ($cfgFfmpegYes) { 'YES' } else { 'NO/absent' }), avcodec=$cfgAvcodecMajor; chain builds avcodec=$chainAvcodecMajor"

# The provenance gate only has teeth in the opt-in mode. With the default
# (OpenCV's own prebuilt FFmpeg) a mismatch is the KNOWN state of #94, not a
# regression, and failing the build over it would just stop the chain.
if (-not $cfgFfmpegYes -and $env:OPENCV_LINK_CHAIN_FFMPEG -ne '1') {
    Write-Host 'NOTE: no FFMPEG: YES in the configure summary; not gating (chain-FFmpeg mode is off) — backlog #94'
} elseif ($cfgFfmpegYes) {
    Write-Host 'FFmpeg backend gate OK: OpenCV configured WITH the FFmpeg backend'
    # The point of #94 is not merely THAT FFmpeg was found but WHICH one.
    if ($chainAvcodecMajor -and $cfgAvcodecMajor) {
        if ($chainAvcodecMajor -eq $cfgAvcodecMajor) {
            Write-Host "FFmpeg provenance gate OK: OpenCV linked avcodec $cfgAvcodecMajor, matching this chain"
        } else {
            throw ("OpenCV linked avcodec $cfgAvcodecMajor but this chain builds avcodec $chainAvcodecMajor - " +
                "it fell back to a foreign/bundled FFmpeg. Backlog #94.")
        }
    } else {
        Write-Host "NOTE: could not compare avcodec majors (chain='$chainAvcodecMajor' configure='$cfgAvcodecMajor') - provenance unverified"
    }
} else {
    # Print the evidence INSTEAD of pointing at a log the reader may not be able
    # to reach: this throw happens inside a container whose filesystem is about
    # to be discarded, so "see the configure log" is useless advice here.
    # Filter out the pkgconfig-shim's own line: CMAKE_PROJECT_INCLUDE runs once
    # per project() call, so it repeats ~20x and crowded the real message out of
    # this very dump the first time it fired.
    Write-Host "`n--- FFmpeg-related lines from the configure log ---"
    if (Test-Path $cfgLog) {
        @(Get-Content $cfgLog -ErrorAction SilentlyContinue |
            Where-Object { $_ -match 'FFMPEG|ffmpeg|avcodec|libav|PkgConfig|pkg-config' -and $_ -notmatch 'pkgconfig-shim' }) |
            Select-Object -First 40 | ForEach-Object { Write-Host "  cfg| $_" }
    } else {
        Write-Host "  (no configure log at $cfgLog)"
    }
    Write-Host "--- end of configure evidence ---`n"
    throw ("OpenCV configured WITHOUT the FFmpeg backend (no 'FFMPEG: YES' in the configure summary). " +
        "cv::VideoCapture would silently lose its FFmpeg path. The lines above are the reason; " +
        "PKG_CONFIG_PATH was '$env:PKG_CONFIG_PATH'. Backlog #94.")
}

# NOTE (2026-08-23): a per-TU `/Od` pass over build.ninja used to sit here as a
# workaround for `error: value evaluated as <N> is out of range.` in the bundled
# protobuf, the TIFF decoder and G-API serialisation. It was removed once the
# real cause was traced to AArch64 COMPRESSED JUMP TABLES rather than the
# .xdata unwind ceiling it was originally blamed on -- see $jumpTableFlag near
# the top of this script, which fixes every offender build-wide while keeping
# full /O2. Do not reintroduce a blanket /Od here without re-reading that
# comment first: /Od "worked" only because it disables the compression pass as
# a side effect of turning optimisation off entirely.

# Persistent log (backlog #43): inside $buildDir it dies with the failed solve.
$buildLog = Get-PersistentBuildLogPath -Name 'opencv-build.log' -FallbackDir $buildDir
# Parallel build first; on failure re-run ninja -j1 (incremental — it jumps straight
# to the failing TU) so the error output is unambiguous without paying the serial
# build cost on the happy path.
# MemGBPerJob=2 (backlog #28): same memory envelope as the ONNX vertex (runs
# 12+13, peak per-process ~1 GB, fleet 5.5 GB at -j9) -> ~19 jobs at 2 GB/job,
# well under the 39 GB budget. Doubles OpenCV compile parallelism.
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog -Install
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

# Fail HERE if cv2 didn't land + import -- a silently-skipped python3 module
# otherwise only surfaces hours later in the final image's smoke test.
# (Shared EAP=Stop-safe helper: exit-code based, stderr-noise tolerant.)
if (Test-WindowsCrossTarget -Arch $ocvTargetArch) {
    # Cross lane: cv2 was not built (BUILD_opencv_python3=OFF above) and an
    # aarch64 .pyd could not be loaded by this x64 CPython even if it had been.
    # Skipping is the only correct behaviour; the gate stays MANDATORY on the
    # native lane, where it catches a silently-skipped python3 module.
    Write-Host 'Skipping the cv2 import gate: cross build (python bindings off; the target interpreter cannot run on this host)'
} else {
    Test-PythonImport -Python $ocvPy -ModuleName 'cv2'
}

Remove-SourceBuildTree -Path $SourceDir

Complete-SourceBuild -Banner '=== OpenCV source build completed ==='  # cleanup + banner + exit 0 (see module help)