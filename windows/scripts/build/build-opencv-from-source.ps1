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
# COFF target; 003 skips MLAS on Windows -> dnn's built-in SGEMM.
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\003-mlas-windows-skip.patch') -SourceDir $mainSrc -Description 'opencv: mlas Windows skip (GAS-only kernels)' -IgnoreWhitespace
# Upstream bug: dnn passes char* to Ort::SessionOptions::EnableProfiling, but ORTCHAR_T is
# wchar_t on Windows (net_impl_backend.cpp:99) -- upstream CI never builds dnn with ORT.
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\004-dnn-ort-profiling-wchar.patch') -SourceDir $mainSrc -Description 'opencv: dnn ORT profiling wchar_t path' -IgnoreWhitespace
if ($contribSrc) {
    Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv_contrib\001-cudev-windows-llp64.patch') -SourceDir $contribSrc -Description 'opencv_contrib: cudev Windows LLP64 64-bit VecTraits'
}

# FFmpeg 9 compat (#94): a SCRIPT, not a .patch -- it matches two accessor expressions rather
# than upstream context, and self-asserts (a no-op match or a leftover field access throws, #56).
if ($env:OPENCV_LINK_CHAIN_FFMPEG -eq '1') {
    & (Join-Path $patchDir 'opencv\ffmpeg9-avcodec-config.ps1') -SourceDir $mainSrc
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

# Pre-create bin/ so OpenCV's file(COPY) for the bundled ONNX Runtime download has a valid
# destination -- on Windows a missing one fails configure with "Invalid argument".
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
    # Our source-built ORT is auto-detected via PKG_CONFIG_PATH; otherwise OpenCV downloads its own.
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

# Provide our source-built ONNX Runtime root so FindONNX.cmake finds it
# (derived from $InstallDir -- forward slashes for the cmake arg).
$ortRoot = (Join-Path $InstallDir 'lib\onnxruntime-source') -replace '\\', '/'
if (Test-Path "$ortRoot/include/onnxruntime/onnxruntime_c_api.h") {
    $cmakeExtra += "-DONNXRT_ROOT_DIR=$ortRoot"
    Write-Host "ONNX Runtime found at $ortRoot"
}

# Get-GpuEnvironment sets CUDA_PATH/CUDA_HOME and prepends CUDA bin to PATH; only CUDACXX is
# needed on top, for CMake's enable_language(CUDA) probe.
$gpuEnv = Get-GpuEnvironment
# Cross lane: NEVER take CUDA from a HOST probe. It answers "does this amd64 BUILD HOST have a
# toolkit", which says nothing about the target -- a bare host probe would point nvcc at x64
# device libs and link them into an "arm64" OpenCV. Enforced here as well as in the driver so a
# direct script invocation cannot bypass it. (Windows-on-ARM CUDA/cuDNN exists; it is backlog
# work, not the reason for this guard.)
if ($gpuEnv.HasCuda -and -not (Test-WindowsCrossTarget -Arch $ocvTargetArch)) {
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
# Three flags that only work TOGETHER, and only with the ffmpeg9-avcodec-config.ps1 patch applied
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
        '-DCPU_NEON_BF16_FLAGS_ON=/clang:-march=armv8.2-a+bf16'
    )
}
$cfgLog = Get-PersistentBuildLogPath -Name 'opencv-configure.log' -FallbackDir $buildDir
Invoke-CmakeConfigure -SourceDir $mainSrc -BuildDir $buildDir -InstallPrefix $ocvInstallDir -ExtraArgs $cmakeExtra 2>&1 |
    Tee-Object -FilePath $cfgLog
Write-Host "CMake configure log: $cfgLog"

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

Remove-SourceBuildTree -Path $SourceDir

Complete-SourceBuild -Banner '=== OpenCV source build completed ==='  # cleanup + banner + exit 0 (see module help)
