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

# #108: container mounts are FLAT (C:\bkmnt, C:\temp\scripts) while the repo is
# scripts/<group>/ -- shared assets sit beside this script or one level up.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
# G2's gate: modules\ in the repo, a per-file mount under ortmods\ in the container (never the shared closure).
$ortGateModule = @('modules', 'ortmods') | ForEach-Object { Join-Path $scriptAssetRoot $_ 'WindowsOrtProvenance.Build.psm1' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
Import-Module ($ortGateModule ?? $(throw 'WindowsOrtProvenance.Build.psm1 (the G2 ORT gate) is not mounted')) -DisableNameChecking

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

# Source patches (idempotent git apply) -- see docs/windows-builds.md "Source Patch Policy".
$patchDir = Join-Path $scriptAssetRoot 'patches'
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\001-cmake-clang-cl-compat.patch') -SourceDir $mainSrc -Description 'opencv: cmake clang-cl/CUDA compat' -IgnoreWhitespace
# Bundled MLAS passes the GNU pair `-include cstring`, which the CL dialect parses as an INPUT
# FILE; the patch adds an MSVC-frontend branch using /FIcstring.
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\002-mlas-clangcl-force-include.patch') -SourceDir $mainSrc -Description 'opencv: mlas clang-cl force-include' -IgnoreWhitespace
# MLAS's GAS-only .S kernels have no MASM port and die in clang's integrated assembler for the
# COFF target. Patch 002 already modified the CMakeLists.txt, so a second .patch file's
# git-apply index hash never matches. Instead, apply the skip INLINE: read the file, insert the
# guard before include(CheckLanguage), write it back. Idempotent (skip if already present).
$mlasCmake = Join-Path $mainSrc '3rdparty\mlas\CMakeLists.txt'
if (Test-Path $mlasCmake) {
    $mlasContent = Get-Content $mlasCmake -Raw
    # Remove any existing guard (from a previous run that inserted it in the
    # wrong place — before include(CheckLanguage) instead of before add_library).
    if ($mlasContent -match 'OPENCV_DNN_MLAS_SKIP_REASON') {
        $mlasContent = $mlasContent -replace '(?ms)if\(WIN32\)\s*\n\s*set\(OPENCV_DNN_MLAS_SKIP_REASON.*?return\(\)\s*\nendif\(\)\s*\n\s*\n', ''
        Write-Host "MLAS: removed existing skip guard (re-inserting at correct position)"
    }
    # Insert BEFORE add_library, not before include(CheckLanguage):
    # the .S sources are already in the target by the time check_language
    # runs, so a return() there is too late.
    $guard = @'
if(WIN32)
  set(OPENCV_DNN_MLAS_SKIP_REASON
    "vendored GAS kernels have no MASM/COFF port on Windows"
    CACHE INTERNAL "" FORCE)
  message(STATUS "MLAS: skipped on Windows (GAS-only kernels; DNN uses its built-in SGEMM)")
  return()
endif()

'@
    $mlasContent = $mlasContent -replace '(?m)^(add_library\(opencv_dnn_mlas)', "$guard`$1"
    [IO.File]::WriteAllText($mlasCmake, $mlasContent)
    Write-Host "MLAS: WIN32 skip guard inserted before add_library (arm64 C++ NEON kernels stay for a future per-arch gate)"
}
# Upstream bug: dnn passes char* to Ort::SessionOptions::EnableProfiling, but ORTCHAR_T is
# wchar_t on Windows (net_impl_backend.cpp:99) -- upstream CI never builds dnn with ORT.
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\004-dnn-ort-profiling-wchar.patch') -SourceDir $mainSrc -Description 'opencv: dnn ORT profiling wchar_t path' -IgnoreWhitespace
if ($contribSrc) {
    Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv_contrib\001-cudev-windows-llp64.patch') -SourceDir $contribSrc -Description 'opencv_contrib: cudev Windows LLP64 64-bit VecTraits'
    # Windows-ARM64 CUDA (#176 phase 2): cudafilters' wavelet_matrix_2d.cuh picks
    # _mm_popcnt_u64 whenever _MSC_VER is defined -- an x86 intrinsic MSVC-on-ARM64
    # does not have. The guard change falls through to __builtin_popcountll; it is a
    # no-op on x64 and on non-MSVC compilers, so both lanes take the same path.
    Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv_contrib\002-arm64-cudafilters-popcount.patch') -SourceDir $contribSrc -Description 'opencv_contrib: cudafilters popcount for Windows ARM64'
}

# FFmpeg 9 compat (#94): a SCRIPT, not a .patch -- it matches two accessor expressions rather
# than upstream context, and self-asserts (a no-op match or a leftover field access throws, #56).
if ($env:OPENCV_LINK_CHAIN_FFMPEG -eq '1') {
    & (Join-Path $patchDir 'opencv\Get-Ffmpeg9AvcodecConfig.ps1') -SourceDir $mainSrc
    if ($LASTEXITCODE -ne 0) { throw 'opencv: FFmpeg-9 videoio patch failed' }
}

# Inline, NOT a .patch: the per-file "already includes <cstring>" guard cannot be expressed as a
# static diff. See docs/windows-builds.md "Source Patch Policy".
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

# ARM-only (upstream bug): cv::float32_t, a typedef at softfloat.cpp:163, shadows clang's
# ::float32_t inside namespace cv and breaks every NEON __builtin_bit_cast. MACROS, not
# typedefs, because intrin_neon.hpp is preprocessed long BEFORE line 163 -- the mechanism is
# in docs/windows-cross-builds.md § softfloat.cpp typedef -> macro.
if ($ocvCross -and (Get-WindowsTargetArchInfo -Arch $ocvTargetArch).CMakeSystemProcessor -match 'ARM64') {
    # #129: OpenCV's AArch64 feature probes compile only under `__GNUC__` (the `_MSC_VER &&
    # _M_ARM64` alternative is commented out upstream, opencv/opencv#25052), so under clang-cl
    # every probe #errors REGARDLESS of the dispatch flags. Patched by SEARCH over the checks
    # directory, floored: fewer than two patched files means the probes moved.
    $checksDir = Join-Path $mainSrc 'cmake\checks'
    $probePattern = '\(defined __GNUC__ && \(defined __arm__ \|\| defined __aarch64__\)\)\s*/\*\s*\|\|\s*\(defined _MSC_VER && \(defined _M_ARM64 \|\| defined _M_ARM64EC\)\)\s*\*/'
    $probeReplacement = '(defined __GNUC__ && (defined __arm__ || defined __aarch64__)) || (defined __clang__ && (defined _M_ARM64 || defined _M_ARM64EC)) /* clang-cl: clang''s arm_neon.h carries the intrinsics (#129) */'
    $probesPatched = 0
    foreach ($probe in @(Get-ChildItem -Path $checksDir -Filter 'cpu_*.cpp' -File -ErrorAction SilentlyContinue)) {
        if (Invoke-InlineRegexPatch -Path $probe.FullName -SkipIfMatch '__clang__ && \(defined _M_ARM64' `
                -Pattern $probePattern -Replacement $probeReplacement `
                -Description "opencv feature probe $($probe.Name): accept clang-cl on ARM64 (#129)") { $probesPatched++ }
    }
    if ($probesPatched -lt 2) { throw "opencv cmake/checks: only $probesPatched probe file(s) carried the commented-out Windows-ARM64 guard (expected >= 2: cpu_neon_fp16.cpp, cpu_neon_dotprod.cpp) -- upstream changed the probes; the NEON_FP16/DOTPROD dispatch would fail silently (#129). Check $checksDir." }
    Write-Host "OpenCV feature probes: $probesPatched file(s) now accept clang-cl on ARM64 (#129)"
    $sfCpp = Join-Path $mainSrc 'modules\core\src\softfloat.cpp'
    [void](Invoke-InlineRegexPatch -Path $sfCpp -Guard 'typedef softfloat float32_t;' `
            -Pattern 'typedef\s+softfloat\s+float32_t;\s*\r?\n\s*typedef\s+softdouble\s+float64_t;' `
            -Replacement "#define float32_t softfloat`n#define float64_t softdouble" `
            -Description 'opencv softfloat.cpp: float32_t/float64_t typedef -> macro (NEON __builtin_bit_cast collision)')
    # Drift assertion: a silent no-op here resurfaces as bit_cast errors deep inside arm_neon.h.
    $sfText = [System.IO.File]::ReadAllText($sfCpp)
    if ($sfText -notmatch '#define\s+float32_t\s+softfloat') {
        throw "opencv softfloat.cpp: the float32_t/float64_t typedefs were not converted to macros (upstream layout changed?). intrin_neon.hpp will fail with '__builtin_bit_cast destination type must be trivially copyable'. Re-check $sfCpp."
    }

    # ARM-only: bundled MLAS remaps vmaxvq_f32/vminvq_f32 onto MSVC's neon_fmaxv/neon_fminv under
    # _M_ARM64, which clang-cl also defines but does not implement (its #ifndef guard does not
    # save us -- clang provides them as FUNCTIONS). Each #define is WRAPPED, not deleted, so a
    # genuine MSVC build keeps the mapping. Idempotence is explicit: -Guard would still match
    # after patching (neon_fmaxv survives inside the wrapper) and nest a second wrapper.
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

# Toolchain preamble: VsDevCmd env, pyconfig.h into Include\ (in-tree CPython keeps it at
# PC\pyconfig.h, which cv2's include chain needs), the platform-tag shim (must exist BEFORE pip
# resolves wheels), and the source-built python handle.
$ocvPy = Initialize-ToolchainPythonEnvironment
if (-not (Test-Path $ocvPy.Exe)) { throw "Source-built CPython not found at $($ocvPy.Exe) (toolchain layer missing?)" }

# EAP=Stop/StrictMode-safe interpreter query: gate on exit code AND a non-empty result -- a bare
# .ToString() on an error line used to feed garbage straight into the cmake args.
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

# The stub goes in OpenCV's own cmake dir: OpenCV's internal scripts override CMAKE_MODULE_PATH,
# so a module path of ours would never be searched.
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

# cv2 needs numpy at configure + compile time; the platform-tag shim above already ran.
Install-CpythonPip -Python $ocvPy
Invoke-CpythonPip -Python $ocvPy -Arguments @('install', '--quiet', 'numpy')
$numpyInclude = (Get-OcvPythonQueryResult -PythonExe $ocvPy.Exe -Code 'import numpy; print(numpy.get_include())' -Label 'numpy include dir') -replace '\\', '/'
if (-not (Test-Path $numpyInclude)) { throw "numpy include dir not resolved (got '$numpyInclude')" }
Write-Host "numpy include: $numpyInclude"

$buildDir = Join-Path $SourceDir 'build'
$ocvInstallDir = Join-Path $InstallDir 'lib\opencv5'

# (MSVC/SDK INCLUDE+LIB env vars were loaded by the toolchain preamble above.)

# Pre-created for dnn's bundled ORT download (a missing bin/ once failed configure with "Invalid argument"). That
# download is pre-empted now (Get-OpencvOrtCmakeArgs); the empty dir stays because it costs nothing.
$null = New-Item -Path (Join-Path $buildDir 'bin') -ItemType Directory -Force

# The amd64 SIMD string is pinned byte-for-byte by TargetArch.Common.Tests; arm64 returns none on
# purpose (NEON is baseline, the rest is runtime dispatch). CPU_BASELINE/CPU_DISPATCH stay unset
# on both lanes -- adding them would re-key every amd64 per-file command line.
$simdFlags = Get-WindowsTargetSimdFlags -Arch $ocvTargetArch
# The triple must ride in THIS script's CMAKE_*_FLAGS, not only in CMAKE_*_FLAGS_INIT: passing
# -DCMAKE_C_FLAGS DEFINES the cache variable, so _INIT is never applied and an "arm64" OpenCV
# would configure green while emitting x86_64 objects.
$crossTargetFlag = if ($ocvCross) { "--target=$(Get-ClangTargetTriple -Arch $ocvTargetArch)" } else { '' }
# ARM-only: carotene (the NEON HAL) uses M_PI, which the MSVC CRT withholds without this.
$mathDefinesFlag = if ($ocvCross) { '/D_USE_MATH_DEFINES' } else { '' }
# The AArch64 jump-table and branch-range workarounds (#135) have been REMOVED:
# the patched toolchain (BUILD_PATCHED_LLVM=1, now the default) fixes the root
# cause (EH_LABEL size under-count in getInstSizeInBytes, llvm#219275 + #219276).
$simdFlags = (@($simdFlags, $crossTargetFlag, $mathDefinesFlag) | Where-Object { $_ }) -join ' '

# EXPERIMENT KNOB: OpenCV's nvcc command lines go through CMake response files, which sccache
# passes through UNCACHED. OPENCV_CUDA_NO_RSP=1 inlines them so sccache's nvcc decomposition is
# reachable -- only meaningful once the quote-protection fix ships (#114 / mozilla/sccache#2811).
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
    # Silence CMake policy deprecation warnings baked into OpenCV's own CMakeLists.
    '-DCMAKE_POLICY_DEFAULT_CMP0146=NEW',
    '-DCMAKE_POLICY_DEFAULT_CMP0148=NEW',
    '-DCMAKE_POLICY_DEFAULT_CMP0177=NEW',
    '-DCMAKE_CXX_STANDARD=17',
    "-DCMAKE_C_FLAGS:STRING=$simdFlags",
    # /FIcstring, not `-include cstring`: the CL dialect parses the GNU pair's second word as an
    # INPUT FILE. Same ambiguity patch 002 fixes inside MLAS, here for every C++ TU.
    # -Wno-deprecated-copy: matx.hpp's user-provided copy ctors deprecate every implicit copy
    # ASSIGNMENT, ~7,700 lines of upstream noise. Parent group on purpose -- it is older, and an
    # unknown -Wno- is only a warning to clang. Safe for CUDA: ocv_cuda_filter_options strips
    # -W* before nvcc's cl.exe host compiler sees them (patches/opencv/001), which rejects D8021.
    "-DCMAKE_CXX_FLAGS:STRING=/FIcstring $(Get-WarningNoiseSuppressionFlags) $simdFlags",
    '-DBUILD_TESTS=OFF', '-DBUILD_PERF_TESTS=OFF', '-DBUILD_EXAMPLES=OFF',
                         # BUILD_opencv_world=OFF: avoids FFmpeg/ONNX importing issues
                         '-DBUILD_opencv_world=OFF',
    '-DBUILD_JPEG=ON', '-DBUILD_PNG=ON', '-DBUILD_TIFF=ON', '-DBUILD_WEBP=ON',
    '-DBUILD_OPENJPEG=ON', '-DBUILD_HARFBUZZ=ON',
    # BUILD_TBB=OFF, unconditional on both lanes: ON would have CMake fetch TBB from GitHub at
    # configure time, an unpinned mid-configure download of the kind #94 removed for FFmpeg.
    # Nothing else in the chain provisions TBB either, so WITH_TBB below likely resolves to NO.
    '-DBUILD_TBB=OFF',
    '-DBUILD_CLAPACK=ON', '-DBUILD_IPP_IW=ON',
    # cv2: ON on both lanes (#120 step 2) whenever the target CPython import lib exists -- see
    # the PYTHON3_* block below for the host-exe / target-lib split and the install destination.
    "-DBUILD_opencv_python3=$(if ($ocvCross -and -not (Get-TargetBuildPython).Available) { 'OFF' } else { 'ON' })", '-DBUILD_opencv_java=OFF', '-DBUILD_opencv_apps=OFF',
    # opencv_contrib dnn_superres references ENGINE_CLASSIC removed in OpenCV 5.x DNN
    '-DBUILD_opencv_dnn_superres=OFF',
    '-DWITH_TBB=ON', '-DWITH_IPP=ON', '-DWITH_OPENCL=ON', '-DWITH_OPENEXR=ON',
    # WITH_OPENGL=OFF: ON makes opencv_core*.dll hard-import OPENGL32.dll, which Server Core
    # lacks -> every OpenCV DLL fails to load (0xC0000135). A headless container needs no GL.
    '-DWITH_OPENGL=OFF', '-DWITH_DIRECTX=ON', '-DWITH_DIRECTML=ON',
    '-DWITH_VULKAN=ON', '-DWITH_EIGEN=ON',
    # The chain's ORT is wired in by Get-OpencvOrtCmakeArgs below, which also stops dnn downloading its own.
                         '-DWITH_ONNXRUNTIME=ON',
    # WITH_MSMF=OFF *and* WITH_OBSENSOR=OFF: Server Core ships no Media Foundation, and obsensor
    # (default ON) hard-imports it INDEPENDENTLY of WITH_MSMF via its UVC path -- MSMF=OFF alone
    # still produced an unloadable videoio. FFmpeg + GStreamer backends remain.
    '-DWITH_VTK=OFF', '-DWITH_MSMF=OFF', '-DWITH_OBSENSOR=OFF', '-DWITH_FFMPEG=ON', '-DWITH_GSTREAMER=ON',
    # NB: OPENCV_FFMPEG_SKIP_DOWNLOAD is deliberately NOT set here -- see the #94 block below.
    # WITH_OPENMP=OFF: clang-cl lowers `#pragma omp` to __kmpc_* calls but libomp.lib never
    # reaches the link line -> lld-link "undefined symbol: __kmpc_fork_call".
    '-DWITH_OPENCL_SVM=ON', '-DWITH_OPENMP=OFF',
    # NVCUVID/NVCUVENC require the NVIDIA Video Codec SDK (separate download, not in container)
    '-DWITH_NVCUVID=OFF', '-DWITH_NVCUVENC=OFF'
    # NB: CUDA is added in the GPU-guarded block below -- unconditionally here, a CPU-only build
    # would enable_language(CUDA) with no nvcc present and fail to configure.
)

# --- cross-lane deltas (a later -D of the same cache var wins) ----------------
# Appended rather than folded into the array above so the amd64 command line stays byte-identical.
if ($ocvCross) {
    # IPP is x86-only, and upstream's ippicv.cmake selects the blob by x86 checks its Windows
    # branch never guards against ARM -- a win-arm64 configure pulls the 32-bit ia32 blob
    # (upstream bug worth filing). Either flavour is x86 COFF lld-link rejects. IPP_IW needs IPP.
    $cmakeExtra += '-DWITH_IPP=OFF', '-DBUILD_IPP_IW=OFF'
    # WITH_DIRECTML=ON on both lanes (#118): it feeds contrib G-API's ONNX DirectML EP, not
    # cv::dnn, and USE_DML=ON (#113) installs the dml_provider_factory.h its detection needs.
    # INSTALL LAYOUT: OpenCV's ARM64 branch keys off CMAKE_GENERATOR_PLATFORM, which only the
    # Visual Studio generator sets -- under Ninja an aarch64 build installs into
    # ...\opencv5\x64\vc18\ while every consumer looks under the TARGET arch dir. OpenCV_ARCH and
    # OpenCV_RUNTIME must BOTH be defined or the override branch never fires
    # (OpenCVDetectCXXCompiler.cmake:150); 'vc18' is what its MSVC_VERSION mapping picks for the
    # pinned toolset, and the literal already hardcoded in the merge/gstreamer/smoke-test scripts.
    $cmakeExtra += "-DOpenCV_ARCH=$(Get-OpenCvArchDir -Arch $ocvTargetArch)", '-DOpenCV_RUNTIME=vc18'
    Write-Host "OpenCV cross ($ocvTargetArch): WITH_IPP=OFF (x86-only), BUILD_IPP_IW=OFF, WITH_DIRECTML=ON (parity restored, #118 -- feeds G-API's ONNX DirectML EP, not cv::dnn), install layout -> $(Get-OpenCvArchDir -Arch $ocvTargetArch)\vc18"
}

# --- FFmpeg discovery for videoio (backlog #94) -------------------------------
# Do NOT add OPENCV_FFMPEG_SKIP_DOWNLOAD on its own: detect_ffmpeg.cmake guards the pkg-config
# route with `if(NOT HAVE_FFMPEG AND PKG_CONFIG_FOUND)`, and OpenCV never runs
# find_package(PkgConfig) on Windows -- so skipping the download only removes the path that was
# working, measured as a flat `FFMPEG: NO`. The shim block further down is what makes it fire.
$ffPkgConfig = Join-Path $InstallDir 'ffmpeg\lib\pkgconfig'
if (Test-Path $ffPkgConfig) {
    $pcParts = @($ffPkgConfig) + @($env:PKG_CONFIG_PATH -split ';' | Where-Object { $_ })
    $env:PKG_CONFIG_PATH = ($pcParts | Select-Object -Unique) -join ';'
    Write-Host "PKG_CONFIG_PATH = $env:PKG_CONFIG_PATH"
} else {
    Write-Host "NOTE: no FFmpeg pkgconfig dir at $ffPkgConfig (harmless today; OpenCV uses its own prebuilt FFmpeg — backlog #94)"
}

# OpenCV 5.x's find_python() round-trips through FindPythonInterp/FindPythonLibs, BOTH removed in
# CMake 4.x, so detection can never succeed and python3 silently drops out of the module list. It
# is wrapped in `if(NOT PYTHON3INTERP_FOUND)`, so preset EVERY output instead (forward slashes).
$numpyVersion = Get-OcvPythonQueryResult -PythonExe $ocvPy.Exe -Code 'import numpy; print(numpy.__version__)' -Label 'numpy version'
# #120 step 2: on cross the LIBRARY comes from the TARGET build and cv2 installs into the SHIPPED
# interpreter's site-packages -- inside the merge arch gate's scan root, so a wrong-arch cv2*.pyd
# fails the merge instead of shipping. On amd64 host == target and the accessor collapses.
$ocvTargetPy = Get-TargetBuildPython
$pyLibFwd = ($ocvTargetPy.Lib) -replace '\\', '/'
$pyIncFwd = ($ocvTargetPy.Include) -replace '\\', '/'
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
# Derived from the python handle, not hardcoded -- the cpython tree location is the toolchain's.
$pySitePackagesFwd = (Join-Path (Split-Path $ocvPy.Include -Parent) 'Lib\site-packages') -replace '\\', '/'
if ($ocvCross -and $ocvTargetPy.Available) {
    $targetSitePackages = Join-Path $InstallDir 'python\Lib\site-packages'
    New-Item -Path $targetSitePackages -ItemType Directory -Force | Out-Null
    $pySitePackagesFwd = $targetSitePackages -replace '\\', '/'
    Write-Host "OpenCV cross: cv2 will install into the TARGET interpreter's site-packages ($targetSitePackages)"
}
$cmakeExtra += "-DPYTHON3_PACKAGES_PATH=$pySitePackagesFwd"
$cmakeExtra += "-DPYTHON3_NUMPY_INCLUDE_DIRS=$numpyInclude"
$cmakeExtra += "-DPYTHON3_NUMPY_VERSION=$numpyVersion"

# Every lane: dnn and G-API build against the CHAIN's ORT (USE_DML=ON). ORT installs its headers flat, but FindONNX's
# DirectML probe and G-API's dml_ep.cpp want the source-tree layout, so a nested copy of them stands in as the root.
function New-OpencvOrtNestedInclude {
    param([Parameter(Mandatory)][string]$OrtRoot, [Parameter(Mandatory)][string]$ShimRoot)
    $flat = Join-Path $OrtRoot 'include\onnxruntime'
    foreach ($header in 'onnxruntime_cxx_api.h', 'dml_provider_factory.h') {
        if (-not (Test-Path -LiteralPath (Join-Path $flat $header) -PathType Leaf)) {
            throw "OpenCV: the chain ONNX Runtime has no $(Join-Path $flat $header); ORT is built before OpenCV, with USE_DML=ON on every lane"
        }
    }
    $session = Join-Path $ShimRoot 'include\onnxruntime\core\session'
    $dml = Join-Path $ShimRoot 'include\onnxruntime\core\providers\dml'
    $null = New-Item -ItemType Directory -Force -Path $session, $dml
    Get-ChildItem -LiteralPath $flat -File | Copy-Item -Destination $session -Force
    Copy-Item -LiteralPath (Join-Path $flat 'dml_provider_factory.h') -Destination $dml -Force
    $ShimRoot.Replace('\', '/').TrimEnd('/')
}

# HAVE_ONNXRUNTIME pre-empts dnn's download, the import library comes from the chain, the hooks dir delay-loads G-API's
# DirectX DLLs, and ORT's config package stays off (FindONNX would take the DLL it exports as the link library).
function Get-OpencvOrtCmakeArgs {
    param(
        [Parameter(Mandatory)][string]$OrtRoot,
        [Parameter(Mandatory)][string]$ShimRoot,
        [Parameter(Mandatory)][string]$OrtVersion,
        [Parameter(Mandatory)][string]$HooksDir
    )
    $fwd = { param([string]$Path) $Path.Replace('\', '/').TrimEnd('/') }
    "-DONNXRT_ROOT_DIR=$(& $fwd $ShimRoot)"
    "-DCMAKE_LIBRARY_PATH:PATH=$(& $fwd $OrtRoot)/lib"
    '-DHAVE_ONNXRUNTIME=ON'
    "-DONNXRUNTIME_VERSION=$OrtVersion"
    '-DCMAKE_DISABLE_FIND_PACKAGE_onnxruntime:BOOL=ON'
    '-DCMAKE_DISABLE_FIND_PACKAGE_ONNXRuntime:BOOL=ON'
    "-DOPENCV_CMAKE_HOOKS_DIR:PATH=$(& $fwd $HooksDir)"
}

$ortRoot = Join-Path $InstallDir 'lib\onnxruntime-source'
$ortVersion = Get-SourceBuildVersion -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.30.0' -StripVPrefix
$ortShimRoot = New-OpencvOrtNestedInclude -OrtRoot $ortRoot -ShimRoot (Join-Path $SourceDir 'ort-nested')
$ocvHooksDir = Join-Path $scriptAssetRoot 'patches\opencv\cmake-hooks'
if (-not (Test-Path -LiteralPath (Join-Path $ocvHooksDir 'POST_CREATE_MODULE_LIBRARY_opencv_gapi.cmake') -PathType Leaf)) {
    throw "OpenCV: the G-API delay-load hook is missing from $ocvHooksDir (patches\opencv not mounted?)"
}
$ocvOrtArgs = @(Get-OpencvOrtCmakeArgs -OrtRoot $ortRoot -ShimRoot $ortShimRoot -OrtVersion $ortVersion -HooksDir $ocvHooksDir)
$cmakeExtra += $ocvOrtArgs
Write-Host "OpenCV ONNX Runtime: the chain's $ortVersion at $ortRoot, nested headers at $ortShimRoot, no configure-time download"

# rocm lane only (empty elsewhere): OpenCL is already ON on every lane, and OpenCV 5.0.0 has no HIP
# path, so this only pins the dormant clBLAS/clFFT probes OFF. docs/windows-builds.md § ROCm layer
function Get-OpencvRocmCmakeArgs {
    param([bool]$Cross, [Parameter(Mandatory)][hashtable]$GpuEnv)
    if ($GpuEnv.ContainsKey('HasRocm') -and $GpuEnv.HasRocm) {
        if ($Cross) { throw 'OpenCV: the rocm lane is amd64-only (AMD ships no Windows arm64 ROCm), but this is a cross build' }
        '-DWITH_OPENCLAMDFFT=OFF'
        '-DWITH_OPENCLAMDBLAS=OFF'
    }
}

# rocm-lane configure gate: the T-API is compiled in, and neither a printed configure line nor a
# CMakeCache.txt entry (where QUIET finds land without printing) resolves into the ROCm tree.
function Get-OpencvRocmConfigureFinding {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfigureLog,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CMakeCache,
        [Parameter(Mandatory)][string]$RocmRoot
    )
    $lines = @($ConfigureLog -split '\r?\n')
    $root = $RocmRoot.TrimEnd('\', '/').Replace('\', '/')
    $inRoot = { param([string]$Text) $Text.Replace('\', '/').IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
    if (-not ($lines -match '(?<![\w/])OpenCL:\s+YES\b')) { 'the configure summary lacks "OpenCL: YES" (the OpenCL T-API is off)' }
    $lines | Where-Object { & $inRoot $_ } | ForEach-Object { "a configure line resolves into the ROCm tree: $($_.Trim())" }
    # Entries only ('//' and '#' are comments); CMAKE_IGNORE_PREFIX_PATH is Invoke-CmakeConfigure's own isolation arg.
    $entries = @($CMakeCache -split '\r?\n' | Where-Object { $_ -match '^[^/#\s][^=]*=' })
    if ($entries.Count -eq 0) { 'CMakeCache.txt is missing or has no entries, so the silent find results cannot be checked' }
    $entries | Where-Object { $_ -notmatch '^CMAKE_IGNORE_PREFIX_PATH:' -and (& $inRoot $_) } |
        ForEach-Object { "a CMake cache entry resolves into the ROCm tree: $($_.Trim())" }
}

# One variable of the first non-phony build.ninja statement whose outputs match: $null when none matches, '' when it
# lacks the variable. The outputs end at the first ':' that ninja did not escape as '$:'.
function Get-NinjaBuildVariable {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BuildNinja,
        [Parameter(Mandatory)][string]$OutputPattern,
        [Parameter(Mandatory)][string]$Variable
    )
    $inStatement = $false
    foreach ($line in ($BuildNinja -split '\r?\n')) {
        if ($inStatement) {
            if ($line -match "^\s+$([regex]::Escape($Variable))\s*=\s*(.*)$") { return $Matches[1] }
            if ($line -notmatch '^\s') { return '' }
        } elseif ($line -match '^build\s+(.*?)(?<!\$):\s*(\S+)') {
            $outputs = $Matches[1]
            if ($Matches[2] -ne 'phony' -and $outputs -match $OutputPattern) { $inStatement = $true }
        }
    }
    if ($inStatement) { '' } else { $null }
}

# Every-lane ORT gate: no configure-time ORT download, dnn and G-API on the chain's ORT through the nested headers, and
# G-API's DirectML EP compiled in (HAVE_ONNX_DML, DirectX DLLs delay-loaded) with no TU defining HAVE_ONNX_COREML.
function Get-OpencvOrtConfigureFinding {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfigureLog,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CMakeCache,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BuildNinja,
        [Parameter(Mandatory)][string]$OrtRoot,
        [Parameter(Mandatory)][string]$ShimRoot,
        [Parameter(Mandatory)][string]$OrtVersion
    )
    $norm = { param([string]$Path) $Path.Trim().Replace('\', '/').TrimEnd('/') }
    $same = { param([string]$A, [string]$B) [string]::Equals((& $norm $A), (& $norm $B), [StringComparison]::OrdinalIgnoreCase) }
    $chain = & $norm $OrtRoot
    $shim = & $norm $ShimRoot
    $lines = [string[]]@($ConfigureLog -split '\r?\n')
    $lines | Where-Object { $_ -match 'DNN: ONNX Runtime (download mode|package|was not found)|(Downloading|Extracting) ONNX Runtime|onnxruntime/releases/download/' } |
        ForEach-Object { "dnn fetched its own ONNX Runtime at configure time: $($_.Trim())" }
    $head = [Array]::FindLastIndex($lines, [Predicate[string]] { param($l) $l -match '(?<![\w/])ONNX Runtime:\s' })
    $state = if ($head -ge 0) { ($lines[$head] -replace '^.*?ONNX Runtime:\s*', '').Trim() } else { '' }
    if ($head -lt 0) {
        "the configure summary has no 'ONNX Runtime:' line, so dnn and G-API may have no ONNX Runtime at all"
    } elseif ($state -notmatch '^YES\b') {
        "the configure summary reads 'ONNX Runtime: $state', not YES (ver $OrtVersion)"
    } else {
        if ($state -ne "YES (ver $OrtVersion)") { "the configure summary reads 'ONNX Runtime: $state', not YES (ver $OrtVersion)" }
        $sub = @($lines | Select-Object -Skip ($head + 1) -First 3)
        $inc = "$(@($sub | ForEach-Object { if ($_ -match 'Include path:\s*(.*?)\s*$') { $Matches[1] } }) | Select-Object -First 1)"
        $lib = "$(@($sub | ForEach-Object { if ($_ -match 'Link libraries:\s*(.*?)\s*$') { $Matches[1] } }) | Select-Object -First 1)"
        if (-not (& $same $inc "$shim/include/onnxruntime/core/session")) { "ONNX Runtime's include path is '$inc', not the nested chain headers $shim/include/onnxruntime/core/session" }
        if (-not (& $same $lib "$chain/lib/onnxruntime.lib")) { "ONNX Runtime links '$lib', not the chain's import library $chain/lib/onnxruntime.lib" }
    }
    $entries = @($CMakeCache -split '\r?\n' | Where-Object { $_ -match '^[^/#\s][^=]*=' })
    if ($entries.Count -eq 0) {
        'CMakeCache.txt is missing or has no entries, so the DirectML probe cannot be checked'
    } else {
        $ep = "$(@($entries | Where-Object { $_ -match '^ORT_EP_INCLUDE:' } | ForEach-Object { $_ -replace '^[^=]*=', '' }) | Select-Object -First 1)"
        if (-not (& $same $ep "$shim/include/onnxruntime/core/providers/dml")) {
            "FindONNX's DirectML probe resolved to '$ep', not the nested dml_provider_factory.h, so HAVE_ONNX_DML is off"
        }
        $entries | Where-Object { $_ -match '3rdparty[\\/]onnxruntime' } |
            ForEach-Object { "a CMake cache entry names dnn's ORT download dir: $($_.Trim())" }
    }
    if ([string]::IsNullOrWhiteSpace($BuildNinja)) { return 'build.ninja is missing or empty, so the G-API compile and link lines cannot be checked' }
    $defines = Get-NinjaBuildVariable -BuildNinja $BuildNinja -OutputPattern '[\\/]opencv_gapi\.dir[\\/](.*[\\/])?dml_ep\.cpp\.obj(\s|$)' -Variable 'DEFINES'
    if ($null -eq $defines) {
        "build.ninja has no compile statement for G-API's dml_ep.cpp"
    } else {
        foreach ($def in 'HAVE_ONNX', 'HAVE_ONNX_DML', 'HAVE_DIRECTML') {
            if ($defines -notmatch "(^|\s)[-/]D$def=1(\s|$)") { "dml_ep.cpp compiles without $def=1, so G-API's DirectML EP is the throwing stub" }
        }
    }
    if ($BuildNinja -match '[-/]DHAVE_ONNX_COREML\b') { 'a compile statement defines HAVE_ONNX_COREML (FindONNX shares ORT_EP_INCLUDE between its DirectML and CoreML probes)' }
    $linkFlags = Get-NinjaBuildVariable -BuildNinja $BuildNinja -OutputPattern '(^|[\\/\s])opencv_gapi\d*\.dll(\s|$)' -Variable 'LINK_FLAGS'
    if ($null -eq $linkFlags) {
        'build.ninja has no link statement for opencv_gapi*.dll'
    } else {
        foreach ($dll in 'dxcore.dll', 'd3d12.dll', 'dxgi.dll', 'DirectML.dll') {
            if ($linkFlags -notmatch "/DELAYLOAD:$([regex]::Escape($dll))(?=[`"\s]|$)") { "opencv_gapi hard-imports ${dll}: the cmake-hooks delay-load did not reach its link line" }
        }
    }
}

# Get-GpuEnvironment sets CUDA_PATH/CUDA_HOME and prepends CUDA bin to PATH; only CUDACXX is
# needed on top, for CMake's enable_language(CUDA) probe.
$gpuEnv = Get-GpuEnvironment
# Cross lane: never take CUDA from a HOST probe -- but #176 phase 2 (2026-09-20) enables it
# when the IMAGE carries the arm64 payload (lib\arm64, staged by Install-Cuda.ps1 -TargetArch
# arm64). Same positive signal as ORT: a cross image without the payload stays CPU + DML.
$ocvCudaUsable = $gpuEnv.HasCuda -and ((-not $ocvCross) -or (Test-CudaWindowsArm64Payload -CudaRoot $gpuEnv.CudaRoot))
if ($ocvCudaUsable) {
    $env:CUDACXX = Join-Path $gpuEnv.CudaRoot 'bin\nvcc.exe'
    $cmakeExtra += '-DWITH_CUDA=ON', '-DWITH_CUDNN=ON', '-DWITH_CUBLAS=ON'
    $cmakeExtra += '-DENABLE_CUDA_FIRST_CLASS_LANGUAGE=ON', '-DOPENCV_DNN_CUDA=ON'
    # nvcc needs cl.exe as its Windows host compiler; clang-cl-only flags are stripped from the
    # -Xcompiler block by patches/opencv/001. CUDAToolkit_ROOT/DIR feed CMake's CONFIG-mode
    # find_package(CUDAToolkit) -- MODULE mode is broken in CMake 4.x.
    $cRootFwd = $gpuEnv.CudaRoot -replace '\\', '/'
    $cmakeExtra += "-DCUDAToolkit_ROOT=$cRootFwd"
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$cRootFwd"
    $cmakeExtra += "-DCMAKE_CUDA_COMPILER:FILEPATH=$($env:CUDACXX -replace '\\', '/')"
    # Arch-aware host compiler (#176): the x64-hosted arm64 cl on the cross lane.
    $cmakeExtra += "-DCMAKE_CUDA_HOST_COMPILER:FILEPATH=$((Get-NvccHostCompilerPath -Arch $ocvTargetArch) -replace '\\', '/')"
    $cmakeExtra += "-DCMAKE_CUDA_ARCHITECTURES=$(Get-CudaArchitectureList -Decoration '-real')"
    if ($ocvCross) {
        # Documented x64->ARM64 flow; and OpenCV's find_package(CUDNN) must be pointed at the
        # STAGED arm64 lib explicitly (its default search would find the x64 one).
        $cmakeExtra += '-DCMAKE_CUDA_FLAGS:STRING=--use-local-env'
        $cudnnLib = Get-CudnnLibrary -CudnnRoot $gpuEnv.CudnnRoot -Arch $ocvTargetArch
        if ($cudnnLib) {
            $cmakeExtra += "-DCUDNN_LIBRARY=$($cudnnLib -replace '\\', '/')"
            $cmakeExtra += "-DCUDNN_INCLUDE_DIR=$((Join-Path $gpuEnv.CudnnRoot 'include') -replace '\\', '/')"
        }
    }
} else {
    $cmakeExtra += '-DWITH_CUDA=OFF'
    if ($gpuEnv.HasRocm) { Write-Host 'OpenCV: rocm lane -> WITH_CUDA=OFF; the AMD GPU path is the OpenCL T-API (ON on every lane)' }
    else { Write-Host 'OpenCV: no CUDA toolkit detected -> building CPU-only (WITH_CUDA=OFF)' }
}
$ocvRocmArgs = @(Get-OpencvRocmCmakeArgs -GpuEnv $gpuEnv -Cross $ocvCross)
if ($ocvRocmArgs.Count -gt 0) {
    $cmakeExtra += $ocvRocmArgs
    Write-Host "OpenCV rocm lane: $($ocvRocmArgs -join ' ')"
}

# CMAKE_AR: find llvm-lib on PATH and pass full path
$cmakeExtra += Get-LlvmArchiverCmakeArg

if ($contribSrc) {
    $cmakeExtra += "-DOPENCV_EXTRA_MODULES_PATH=$(Join-Path $contribSrc 'modules')"
    $cmakeExtra += '-DOPENCV_FORCE_3RDPARTY_BUILD=ON'
}

# --- link the CHAIN's FFmpeg instead of a downloaded prebuilt (backlog #94) ---
# Three flags that only work TOGETHER, and only with the Get-Ffmpeg9AvcodecConfig.ps1 patch applied
# above: CMAKE_PROJECT_INCLUDE runs the find_package(PkgConfig) OpenCV skips on Windows,
# SKIP_DOWNLOAD stops the prebuilt satisfying HAVE_FFMPEG first, ENABLE_LIBAVDEVICE fixes the
# `avdevice: NO` half of #94. SKIP_DOWNLOAD alone measured `FFMPEG: NO`. Default ON since
# 2026-08-17; opt out with -BuildArg OPENCV_LINK_CHAIN_FFMPEG=.
# Report the OBSERVED value, always: BuildKit silently discards a --build-arg for an ARG the
# Dockerfile does not declare, so an opt-in can never arrive and look like "the flag is broken".
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

# Never swallow the configure output: it is the only place OpenCV states its CPU dispatch set and
# its parallel framework, and the FFmpeg gate below has nothing to read without it. Stream it AND
# tee to a persistent path (survives the failed solve, #43).
# #129: OpenCV's AArch64 probes hand the compiler `-march=armv8.2-a+fp16` (GCC spelling) and the
# `if(MSVC)` branch of OpenCVCompilerOptimizations.cmake blanks it under clang-cl, so every
# fp16/dotprod/bf16 probe compiled WITHOUT its feature and the summary printed an EMPTY
# `Dispatched code generation:` line. The flag vars are ocv_update'd, so a cache definition wins;
# CPU_DISPATCH itself stays at OpenCV's AArch64 default.
if ($ocvCross) {
    $cmakeExtra += @(
        '-DCPU_NEON_FP16_FLAGS_ON=/clang:-march=armv8.2-a+fp16',
        '-DCPU_NEON_DOTPROD_FLAGS_ON=/clang:-march=armv8.2-a+dotprod',
        '-DCPU_NEON_BF16_FLAGS_ON=/clang:-march=armv8.2-a+bf16',
        '-DCPU_NEON_I8MM_FLAGS_ON=/clang:-march=armv8.2-a+i8mm'
    )
}
$cfgLog = Get-PersistentBuildLogPath -Name 'opencv-configure.log' -FallbackDir $buildDir
Invoke-CmakeConfigure -SourceDir $mainSrc -BuildDir $buildDir -InstallPrefix $ocvInstallDir -ExtraArgs $cmakeExtra 2>&1 |
    Tee-Object -FilePath $cfgLog
Write-Host "CMake configure log: $cfgLog"
$ocvOrtCfg = @(Get-OpencvOrtConfigureFinding -ConfigureLog "$(Get-Content -LiteralPath $cfgLog -Raw)" `
        -CMakeCache "$(Get-Content -LiteralPath (Join-Path $buildDir 'CMakeCache.txt') -Raw -ErrorAction SilentlyContinue)" `
        -BuildNinja "$(Get-Content -LiteralPath (Join-Path $buildDir 'build.ninja') -Raw -ErrorAction SilentlyContinue)" `
        -OrtRoot $ortRoot -ShimRoot $ortShimRoot -OrtVersion $ortVersion)
if ($ocvOrtCfg.Count -gt 0) { throw "OpenCV ONNX Runtime configure gate ($cfgLog): $($ocvOrtCfg -join '; ')" }
Write-Host "OpenCV ONNX Runtime gate OK: chain ORT $ortVersion, no download, G-API DirectML EP compiled in with its DirectX DLLs delay-loaded"
if ($gpuEnv.HasRocm) {
    $ocvRocmCfg = @(Get-OpencvRocmConfigureFinding -ConfigureLog "$(Get-Content -LiteralPath $cfgLog -Raw)" `
            -CMakeCache "$(Get-Content -LiteralPath (Join-Path $buildDir 'CMakeCache.txt') -Raw -ErrorAction SilentlyContinue)" -RocmRoot $gpuEnv.RocmRoot)
    if ($ocvRocmCfg.Count -gt 0) { throw "OpenCV rocm-lane configure gate ($cfgLog): $($ocvRocmCfg -join '; ')" }
    Write-Host 'OpenCV rocm-lane configure gate OK: OpenCL T-API YES, no configure line or CMake cache entry resolves into the ROCm tree'
}

# GATE (#129): an empty dispatch line is a build that "succeeds" with every optional kernel
# silently dropped. Cross must name NEON_FP16; amd64 may never regress to nothing.
$dispatchLine = @(Get-Content $cfgLog | Where-Object { $_ -match 'Dispatched code generation:\s*(.*)$' } | Select-Object -Last 1)
$dispatched = if ($dispatchLine.Count -gt 0 -and $dispatchLine[0] -match 'Dispatched code generation:\s*(.*)$') { $Matches[1].Trim() } else { '' }
# Never throw blind: the probe RESULT is in the configure log, but the compiler ERRORS behind it
# are only in CMakeFiles\CMakeError.log.
function Write-OpenCvProbeDiagnostics {
    $errLog = Join-Path $buildDir 'CMakeFiles\CMakeError.log'
    Write-Host '--- CPU feature probe lines from the configure log ---'
    Get-Content $cfgLog | Where-Object { $_ -match 'HAVE_CPU_(NEON|SSE|AVX)|CPU_[A-Z0-9_]+_FLAGS|is not supported by|Dispatched|requested:' } | ForEach-Object { Write-Host "  $_" }
    if (Test-Path $errLog) {
        Write-Host "--- CMakeError.log excerpts for the NEON probes ($errLog) ---"
        $lines = @(Get-Content $errLog)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'cpu_neon_(fp16|dotprod|bf16)|NEON_(FP16|DOTPROD|BF16)') {
                $from = [math]::Max(0, $i - 2); $to = [math]::Min($lines.Count - 1, $i + 40)
                $lines[$from..$to] | ForEach-Object { Write-Host "  $_" }
                $i = $to
            }
        }
    } else { Write-Host "  (no $errLog)" }
}
if (-not $dispatched) { Write-OpenCvProbeDiagnostics; throw "OpenCV configure reports NO dispatched code generation (the 'Dispatched code generation:' summary line is empty or missing in $cfgLog) -- every optional SIMD kernel would be dropped silently (#129)" }
if ($ocvCross -and $dispatched -notmatch '\bNEON_FP16\b') { Write-OpenCvProbeDiagnostics; throw "OpenCV cross configure dispatches '$dispatched' but not NEON_FP16 -- the clang-cl feature-flag override (#129) is not taking effect for that probe; see the diagnostics above and $cfgLog" }
Write-Host "OpenCV dispatched code generation: $dispatched"

# GATE: prove FFmpeg was detected before spending ~20 min compiling -- a dropped backend still
# builds, installs and passes every test, and only surfaces at cv::VideoCapture in production
# (that is how #93/#94 survived for months). DO NOT gate on cvconfig.h: HAVE_FFMPEG does not
# exist in OpenCV 5.0.0's cvconfig.h.in, so such a gate fails 100 % of the time no matter what
# was detected. The configure summary is the authoritative signal -- the same text
# cv2.getBuildInformation() reproduces at runtime, which #95 asserts on.
$chainAvcodecMajor = ''
$ffProbe = Join-Path $InstallDir 'ffmpeg\bin\ffmpeg.exe'
if (Test-Path $ffProbe) {
    # ffmpeg.exe needs its own bin dir AND the ORT dir on PATH (#112): avfilter statically imports
    # onnxruntime.dll, which lives elsewhere, so with either missing the exe dies 0xC0000135, the
    # version reads back EMPTY and this gate degrades to "provenance unverified" every build.
    $ffBinDir = Split-Path $ffProbe -Parent
    $probeDirs = @($ffBinDir)
    $ortDll = Get-ChildItem (Join-Path $InstallDir 'lib\onnxruntime-source') -Recurse -Filter 'onnxruntime.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ortDll) { $probeDirs += $ortDll.DirectoryName }
    $savedPath = $env:PATH
    try {
        $env:PATH = ($probeDirs -join ';') + ';' + $env:PATH
        if (Test-WindowsCrossTarget -Arch $ocvTargetArch) {
            # ffmpeg.exe is a TARGET binary and cannot run here, but the gate needs no execution:
            # the chain-side avcodec major is a STATIC fact in the staged avcodec-<N>.dll name.
            $avcodecDll = Get-ChildItem -Path $ffBinDir -Filter 'avcodec-*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $ffVer = ''
            $ffExit = 0
            if ($avcodecDll -and $avcodecDll.Name -match '^avcodec-(\d+)\.dll$') {
                # Feed the same variable the runnable probe fills, in its shape.
                $ffVer = "libavcodec $($Matches[1]).0.0"
                Write-Host "ffmpeg.exe version probe replaced by a static read on the cross lane: $($avcodecDll.Name) -> avcodec major $($Matches[1])"
            } else {
                Write-Host "NOTE: no avcodec-<N>.dll in $ffBinDir - chain avcodec major unknown, provenance gate degrades to configure-log evidence"
            }
        } else {
            $ffVer = & $ffProbe -version 2>&1 | Out-String
            $ffExit = $LASTEXITCODE
        }
    } finally { $env:PATH = $savedPath }
    if ($ffVer -match '(?m)^\s*libavcodec\s+(\d+)\.') { $chainAvcodecMajor = $Matches[1] }
    elseif ($ffExit -ne 0) {
        # 0xC0000135 with empty output is a missing-DLL signature, not a parse miss.
        Write-Host ("NOTE: ffmpeg.exe -version exited {0} (0x{0:X8}) with no parseable output - probe dirs: {1}" -f $ffExit, ($probeDirs -join ';'))
    }
}
$cfgText = if (Test-Path $cfgLog) { Get-Content $cfgLog -Raw } else { '' }
$cfgFfmpegYes = $cfgText -match '(?m)^\s*--\s+FFMPEG:\s+YES'
$cfgAvcodecMajor = ''
if ($cfgText -match '(?m)^\s*--\s+avcodec:\s+(?:YES\s*\()?(\d+)\.') { $cfgAvcodecMajor = $Matches[1] }

Write-Host "FFmpeg gate inputs: configure says FFMPEG=$(if ($cfgFfmpegYes) { 'YES' } else { 'NO/absent' }), avcodec=$cfgAvcodecMajor; chain builds avcodec=$chainAvcodecMajor"

# The provenance gate only has teeth in the opt-in mode: with OpenCV's own prebuilt, a mismatch
# is the KNOWN state of #94, not a regression.
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
    # Print the evidence, not a log path: this throw happens in a container about to be discarded.
    # Filter the pkgconfig-shim line -- CMAKE_PROJECT_INCLUDE runs per project(), ~20x.
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

# Do not reintroduce the per-TU `/Od` pass that used to sit here: it only ever "worked" by
# disabling the compressed-jump-table pass as a side effect.

# The per-TU /Ob1 workaround for median_blur/multiview_calibration (#135 defect 2) has been
# REMOVED: the patched toolchain (BUILD_PATCHED_LLVM=1, now the default) fixes the root cause
# (EH_LABEL size under-count, which BranchRelaxation also consumes).



# Persistent log (#43): inside $buildDir it dies with the failed solve.
$buildLog = Get-PersistentBuildLogPath -Name 'opencv-build.log' -FallbackDir $buildDir
# Parallel first, then ninja -j1 on failure -- incremental, so it jumps straight to the failing
# TU without paying the serial cost on the happy path.
# MemGBPerJob=2 (#28): same envelope as the ONNX vertex -> ~19 jobs, well under the 39 GB budget.
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog -Install
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

# Fail HERE if cv2 did not land: a silently-skipped python3 module otherwise surfaces hours later
# in the final image's smoke test.
if (Test-WindowsCrossTarget -Arch $ocvTargetArch) {
    if ($ocvTargetPy.Available) {
        # #120 step 2: an aarch64 .pyd cannot be imported by this x64 host, but the failure this
        # gate exists for -- a silently skipped python3 module -- is fully detectable statically.
        $cv2Pyd = Get-ChildItem -Path (Join-Path $InstallDir 'python\Lib\site-packages') -Recurse -Filter 'cv2*.pyd' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cv2Pyd) { throw "cv2 python module did NOT land in the target site-packages ($(Join-Path $InstallDir 'python\Lib\site-packages')) although BUILD_opencv_python3=ON -- the python3 module was silently skipped" }
        # Machine AND name: `cv2.cp314-win_amd64.pyd` with machine 0xAA64 shipped once -- right
        # bytes, unloadable name. OpenCV takes EXT_SUFFIX from the build interpreter's sysconfig,
        # which the sitecustomize shim pins to the TARGET tag; this asserts the pin reached cv2.
        [void](Assert-PeTargetMachine -Path $cv2Pyd.FullName -Arch $ocvTargetArch -Context 'cv2 module (linked against the wrong python import lib?)')
        [void](Assert-PythonExtensionTag -Name $cv2Pyd.Name -Arch $ocvTargetArch -Context 'cv2 module (sitecustomize EXT_SUFFIX pin missing?)')
        Write-Host ('cv2 static gate OK (cross lane): {0} present, machine 0x{1:X4}; import deferred to the target host' -f $cv2Pyd.Name, (Get-PeMachineType -Arch $ocvTargetArch))
    } else {
        Write-Host 'Skipping the cv2 gate: cross build without a target CPython (python bindings were OFF)'
    }
} else {
    Test-PythonImport -Python $ocvPy -ModuleName 'cv2'
}

# G2: the whole tree, both records and the configure log hold the chain ORT only; a pass stamps it for G1.
Assert-ChainOrtOnly -Consumer 'opencv' -OrtRoot $ortRoot -TreeRoot $SourceDir -Shim $ortShimRoot -Log $cfgLog `
    -Record (Join-Path $buildDir 'CMakeCache.txt'), (Join-Path $buildDir 'build.ninja')

Remove-SourceBuildTree -Path $SourceDir

Complete-SourceBuild -Banner '=== OpenCV source build completed ==='  # cleanup + banner + exit 0 (see module help)
