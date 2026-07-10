# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\opencv-src',
    [string]$InstallDir = '',
    [string]$OpenCvVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildEnvironment -InstallDir $InstallDir

$OpenCvVersion = Get-SourceBuildVersion -Value $OpenCvVersion -EnvironmentVariables @('OPENCV_SOURCE_VERSION', 'OPENCV_VERSION') -DefaultValue '5.x'

Write-Host "=== OpenCV source build (branch $OpenCvVersion, Ninja+clang-cl) ==="

New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null
$mainSrc = Join-Path $SourceDir 'opencv'
Invoke-GitClone -RepoUrl 'https://github.com/opencv/opencv.git' -Branch $OpenCvVersion -SourceDir $mainSrc | Out-Null

$contribSrc = Join-Path $SourceDir 'opencv_contrib'
$contribOk = Invoke-GitClone -RepoUrl 'https://github.com/opencv/opencv_contrib.git' -Branch $OpenCvVersion -SourceDir $contribSrc -SkipOnFailure
if (-not $contribOk) { $contribSrc = ''; Write-Host 'Continuing without contrib modules' }

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
$patchDir = Join-Path $PSScriptRoot 'patches'
Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv\001-cmake-clang-cl-compat.patch') -SourceDir $mainSrc -Description 'opencv: cmake clang-cl/CUDA compat'
if ($contribSrc) {
    Invoke-SourcePatch -PatchFile (Join-Path $patchDir 'opencv_contrib\001-cudev-windows-llp64.patch') -SourceDir $contribSrc -Description 'opencv_contrib: cudev Windows LLP64 64-bit VecTraits'
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

# Create FindPythonInterp.cmake stub directly in OpenCV's cmake dir so
# find_host_package(PythonInterp ...) finds it (CMAKE_MODULE_PATH is overridden
# by OpenCV's internal cmake scripts — placing it in the source tree avoids that).
$pythonModuleDir = Join-Path $mainSrc 'cmake'
$ocvPy = Get-SourceBuildPython
$pyExePath = if (Test-Path $ocvPy.Exe) { $ocvPy.Exe -replace '\\', '/' } else { 'C:/temp/cpython/PCbuild/amd64/python.exe' }
# Version derived from canonical PYTHON_VERSION (versions.env via load-versions/ENV)
$pyVersion = if (-not [string]::IsNullOrWhiteSpace($env:PYTHON_VERSION)) { $env:PYTHON_VERSION } else { '3.14.6' }
$pyParts = $pyVersion -split '\.'
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

$buildDir = Join-Path $SourceDir 'build'
$ocvInstallDir = Join-Path $InstallDir 'lib\opencv5'

# Pre-create the bin/ directory so OpenCV's cmake file(COPY ...) for the bundled
# ONNX Runtime download has a valid destination (avoids "Invalid argument" error
# on Windows when the destination directory doesn't exist yet during configure).
$null = New-Item -Path (Join-Path $buildDir 'bin') -ItemType Directory -Force

$simdFlags = Get-WindowsX86SimdFlags

$cmakeExtra = @(
    # Suppress CMake policy deprecation warnings baked into OpenCV's own CMakeLists.txt
    # (CMP0146: cmake_minimum_required version range; CMP0148: FindPython* deprecation;
    #  CMP0177: install() DESTINATION path normalisation).
    '-DCMAKE_POLICY_DEFAULT_CMP0146=NEW',
    '-DCMAKE_POLICY_DEFAULT_CMP0148=NEW',
    '-DCMAKE_POLICY_DEFAULT_CMP0177=NEW',
    '-DCMAKE_CXX_STANDARD=17',
    # /FI<cstring> fixes clang-cl -include cstring ambiguity (file vs header)
    "-DCMAKE_C_FLAGS:STRING=$simdFlags",
    "-DCMAKE_CXX_FLAGS:STRING=/FIcstring $simdFlags",
    '-DBUILD_TESTS=OFF', '-DBUILD_PERF_TESTS=OFF', '-DBUILD_EXAMPLES=OFF',
                         # BUILD_opencv_world=OFF: avoids FFmpeg/ONNX importing issues
                         '-DBUILD_opencv_world=OFF',
    '-DBUILD_JPEG=ON', '-DBUILD_PNG=ON', '-DBUILD_TIFF=ON', '-DBUILD_WEBP=ON',
    '-DBUILD_OPENJPEG=ON', '-DBUILD_HARFBUZZ=ON', '-DBUILD_TBB=OFF',  # source build only on ARM Windows
    '-DBUILD_CLAPACK=ON', '-DBUILD_IPP_IW=ON',
    '-DBUILD_opencv_python3=OFF', '-DBUILD_opencv_java=OFF', '-DBUILD_opencv_apps=OFF',
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
    '-DWITH_VTK=OFF', '-DWITH_MSMF=ON', '-DWITH_FFMPEG=ON', '-DWITH_GSTREAMER=ON',
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

# Provide our source-built ONNX Runtime root so FindONNX.cmake finds it.
$ortRoot = 'C:/runtime/lib/onnxruntime-source'
if (Test-Path "$ortRoot/include/onnxruntime/onnxruntime_c_api.h") {
    $cmakeExtra += "-DONNXRT_ROOT_DIR=$ortRoot"
    Write-Host "ONNX Runtime found at $ortRoot"
}

# Enable CUDA via CMake's first-class language support (ENABLE_CUDA_FIRST_CLASS_LANGUAGE=ON
# above tells OpenCV to use modern CUDA detection instead of the deprecated FindCUDA.cmake).
# Set CUDACXX and CUDA_PATH env vars for CMake's built-in enable_language(CUDA) probe.
                     $cudaRootForOpenCV = Get-CudaRoot
                     if ($cudaRootForOpenCV -and (Test-Path $cudaRootForOpenCV)) {
                         Enter-VsDevCmdEnvironment
                         $env:CUDACXX = Join-Path $cudaRootForOpenCV 'bin\nvcc.exe'
                         $env:CUDA_PATH = $cudaRootForOpenCV
                         $env:PATH = "$(Join-Path $cudaRootForOpenCV 'bin');$env:PATH"
                         # Enable CUDA only now that a toolkit is confirmed present (this is what
                         # keeps the CPU-only lane from enable_language(CUDA)-ing with no nvcc).
                         # OPENCV_DNN_CUDA adds the cv::dnn CUDA backend on top of the core modules.
                         $cmakeExtra += '-DWITH_CUDA=ON', '-DWITH_CUDNN=ON', '-DWITH_CUBLAS=ON'
                         $cmakeExtra += '-DENABLE_CUDA_FIRST_CLASS_LANGUAGE=ON', '-DOPENCV_DNN_CUDA=ON'
                         # nvcc requires MSVC cl.exe as the host compiler on Windows.
                         # clang-cl-only flags forwarded via -Xcompiler (e.g. /Wno-undef,
                         # /clang:*, /FIcstring) are stripped from the CUDA host block by the
                         # ocv_cuda_filter_options patch (opencv/001-cmake-clang-cl-compat.patch).
                         # Provide CUDAToolkit_ROOT + CUDAToolkit_DIR so CMake's CONFIG-mode
                         # find_package(CUDAToolkit) can find CUDA 13.3 (MODULE mode broken in CMake 4.x).
                         $cRootFwd = $cudaRootForOpenCV -replace '\\', '/'
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

Invoke-CmakeConfigure -SourceDir $mainSrc -BuildDir $buildDir -InstallPrefix $ocvInstallDir -ExtraArgs $cmakeExtra | Out-Null

$buildLog = Join-Path $buildDir 'opencv-build.log'
# Parallel build first; on failure re-run ninja -j1 (incremental — it jumps straight
# to the failing TU) so the error output is unambiguous without paying the serial
# build cost on the happy path.
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 4 -LogFile $buildLog -Install

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== OpenCV source build completed ==='



