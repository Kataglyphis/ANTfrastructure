# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\opencv-src',
    [string]$InstallDir = '',
    [string]$OpenCvVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$OpenCvVersion = Get-SourceBuildVersion -Value $OpenCvVersion -EnvironmentVariables @('OPENCV_SOURCE_VERSION', 'OPENCV_VERSION') -DefaultValue '5.x'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }

Write-Host "=== OpenCV source build (branch $OpenCvVersion, Ninja+clang-cl) ==="

New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null
$mainSrc = Join-Path $SourceDir 'opencv'
$ok = Invoke-GitClone -RepoUrl 'https://github.com/opencv/opencv.git' -Branch $OpenCvVersion -SourceDir $mainSrc
if (-not $ok) { throw 'Failed to clone opencv main repo' }

$contribSrc = Join-Path $SourceDir 'opencv_contrib'
$contribOk = Invoke-GitClone -RepoUrl 'https://github.com/opencv/opencv_contrib.git' -Branch $OpenCvVersion -SourceDir $contribSrc -SkipOnFailure
if (-not $contribOk) { $contribSrc = ''; Write-Host 'Continuing without contrib modules' }

# Patch mlas for clang-cl: add missing <cstring> include
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

# Patch OpenCV's cmake to NOT add -include cstring (clang-cl treats it as filename)
$cvOptsPath = Join-Path $mainSrc 'cmake/OpenCVCompilerOptions.cmake'
if (Test-Path $cvOptsPath) {
    $content = Get-Content $cvOptsPath -Raw
    $patched = $content -replace '-include cstring', ''
    Set-Content -Path $cvOptsPath -Value $patched
    Write-Host 'Patched OpenCVCompilerOptions.cmake: removed -include cstring'
}

$buildDir = Join-Path $SourceDir 'build'
$ocvInstallDir = Join-Path $InstallDir 'lib\opencv5'

$simdFlags = '/clang:-mavx2 /clang:-mavx /clang:-mfma /clang:-mssse3 /clang:-msse3 /clang:-msse4.1 /clang:-msse4.2 /clang:-mpopcnt'

$cmakeExtra = @(
    '-DCMAKE_CXX_STANDARD=17',
    # /FI<cstring> fixes clang-cl -include cstring ambiguity (file vs header)
    "-DCMAKE_C_FLAGS:STRING=$simdFlags",
    "-DCMAKE_CXX_FLAGS:STRING=/FIcstring $simdFlags",
    '-DBUILD_TESTS=OFF', '-DBUILD_PERF_TESTS=OFF', '-DBUILD_EXAMPLES=OFF',
    '-DBUILD_opencv_world=ON',
    '-DBUILD_JPEG=ON', '-DBUILD_PNG=ON', '-DBUILD_TIFF=ON', '-DBUILD_WEBP=ON',
    '-DBUILD_OPENJPEG=ON', '-DBUILD_HARFBUZZ=ON', '-DBUILD_TBB=OFF',  # source build only on ARM Windows
    '-DBUILD_CLAPACK=ON', '-DBUILD_IPP_IW=ON',
    '-DBUILD_opencv_python3=OFF', '-DBUILD_opencv_java=OFF', '-DBUILD_opencv_apps=OFF',
    '-DWITH_TBB=ON', '-DWITH_IPP=ON', '-DWITH_OPENCL=ON', '-DWITH_OPENEXR=ON',
    '-DWITH_OPENGL=ON', '-DWITH_DIRECTX=ON', '-DWITH_DIRECTML=ON',
    '-DWITH_VULKAN=ON', '-DWITH_EIGEN=ON',
    # ONNX Runtime enabled — OpenCV auto-detects our source-built ORT via PKG_CONFIG_PATH.
    # If not found via pkg-config, OpenCV falls back to its bundled download (v1.25.1).
    '-DWITH_ONNXRUNTIME=ON',
    '-DWITH_VTK=OFF', '-DWITH_MSMF=ON', '-DWITH_FFMPEG=ON', '-DWITH_GSTREAMER=ON',
    '-DWITH_OPENCL_SVM=ON', '-DWITH_OPENMP=ON',
    # CUDA unconditionally ON; if NVIDIA layer is absent, OpenCV warns and skips gracefully
    '-DWITH_CUDA=ON', '-DWITH_CUDNN=ON', '-DWITH_CUBLAS=ON'
)

$cudaRoot = Get-CudaRoot
if ($cudaRoot -and (Test-Path $cudaRoot)) {
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$cudaRoot"
    $nvccPath = Join-Path $cudaRoot 'bin\nvcc.exe'
    if (Test-Path $nvccPath) { $cmakeExtra += "-DCMAKE_CUDA_COMPILER=$nvccPath" }
}

# CMAKE_AR: find llvm-lib on PATH and pass full path
$llvmLib = (Get-Command 'llvm-lib' -ErrorAction SilentlyContinue).Source
if (-not $llvmLib) { $llvmLib = (Get-Command 'llvm-lib.exe' -ErrorAction SilentlyContinue).Source }
if ($llvmLib) { $cmakeExtra += "-DCMAKE_AR:FILEPATH=$llvmLib" }

if ($contribSrc) {
    $cmakeExtra += "-DOPENCV_EXTRA_MODULES_PATH=$(Join-Path $contribSrc 'modules')"
    $cmakeExtra += '-DOPENCV_FORCE_3RDPARTY_BUILD=ON'
}

$ok = Invoke-CmakeConfigure -SourceDir $mainSrc -BuildDir $buildDir -InstallPrefix $ocvInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'OpenCV CMake configuration failed' }

$buildLog = Join-Path $buildDir 'opencv-build.log'
$ok = Invoke-CmakeBuild -BuildDir $buildDir -Config Release -Install -LogFile $buildLog
if (-not $ok) { throw 'OpenCV build failed' }

Write-Host '=== OpenCV source build completed ==='
