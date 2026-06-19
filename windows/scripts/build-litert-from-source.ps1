param(
    [string]$SourceDir = 'C:\temp\litert-src',
    [string]$InstallDir = '',
    [string]$LiteRtVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$LiteRtVersion = Get-SourceBuildVersion -Value $LiteRtVersion -EnvironmentVariables @('LITERT_VERSION') -DefaultValue '2.1.5'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\gstreamer' }
$litertInstallDir = Join-Path $InstallDir 'lib\litert'

Write-Host "=== LiteRT source build (v$LiteRtVersion, Ninja+clang-cl) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT.git' -Tag "$LiteRtVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone LiteRT' }

$tfliteSrc = Join-Path $SourceDir 'tflite'

# Patch: disable ALL protobuf-based proto generation (proto_path issue on Windows)
# Replace every proto/CMakeLists.txt with a no-op to avoid protoc --proto_path errors
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

# Detect CUDA for LiteRT (CUDA delegate available via external delegate)
$cudaRoot = if ($env:CUDA_ROOT) { $env:CUDA_ROOT } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { $null }
$cmakeExtra = @(
    '-DTFLITE_ENABLE_INSTALL=OFF'
    '-DTFLITE_ENABLE_LABEL_IMAGE=OFF'
    '-DTFLITE_ENABLE_BENCHMARK_MODEL=OFF'
    '-DTFLITE_ENABLE_RUY=ON'
    '-DTFLITE_ENABLE_RESOURCE=ON'
    # GPU delegate via Vulkan/OpenGL ES (primary GPU acceleration on Windows)
    '-DTFLITE_ENABLE_GPU=ON'
    # GPU delegate via OpenCL (alternative GPU path on Windows)
    '-DTFLITE_ENABLE_GPU_OPENCL=ON'
    '-DTFLITE_ENABLE_XNNPACK=ON'
    # External delegate support for custom CUDA/ROCm delegates
    '-DTFLITE_ENABLE_EXTERNAL_DELEGATE=ON'
    '-DTFLITE_ENABLE_MMAP=OFF'
    '-DTFLITE_ENABLE_NNAPI=OFF'
    # Enable hexagon delegate on Windows (dsp sim)
    '-DTFLITE_ENABLE_HEXAGON=OFF'
    # Disable profiling (avoids protobuf proto_path compilation error on Windows)
    '-DTFLITE_ENABLE_PROFILING=OFF'
)

# Add CUDA paths for external delegate compilation if available
if ($cudaRoot -and (Test-Path $cudaRoot)) {
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$cudaRoot"
    $cudaInclude = Join-Path $cudaRoot 'include'
    if (Test-Path $cudaInclude) {
        $cmakeExtra += "-DCMAKE_CXX_FLAGS:STRING=-I$cudaInclude"
    }
}

# Fix CMAKE_AR path for llvm-lib (CMake resolves llvm-lib to C:\llvm-lib incorrectly)
$llvmLib = (Get-Command 'llvm-lib' -ErrorAction SilentlyContinue).Source
if (-not $llvmLib) { $llvmLib = (Get-Command 'llvm-lib.exe' -ErrorAction SilentlyContinue).Source }
if ($llvmLib) { $cmakeExtra += "-DCMAKE_AR:FILEPATH=$llvmLib" }

# Add Vulkan SDK path (needed for GPU delegate Vulkan backend)
$vulkanSdk = if ($env:VULKAN_SDK) { $env:VULKAN_SDK } else { $null }
if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    $cmakeExtra += "-DVulkan_INCLUDE_DIR=$(Join-Path $vulkanSdk 'Include')"
    $vulkanLib = Join-Path $vulkanSdk 'Lib'
    if (Test-Path $vulkanLib) { $cmakeExtra += "-DVulkan_LIBRARY=$(Join-Path $vulkanLib 'vulkan-1.lib')" }
}

$ok = Invoke-CmakeConfigure -SourceDir $tfliteSrc -BuildDir $buildDir -InstallPrefix $litertInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'LiteRT CMake configure failed' }

$buildLog = Join-Path $buildDir 'litert-build.log'
$ok = Invoke-CmakeBuild -BuildDir $buildDir -Config Release -Install:$false -LogFile $buildLog
if (-not $ok) { throw 'LiteRT build failed' }

# Manual install (TFLITE_ENABLE_INSTALL=OFF disables cmake --install)
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
