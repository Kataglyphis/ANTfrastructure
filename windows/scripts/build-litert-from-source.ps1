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
$buildDir = Join-Path $SourceDir 'build'

# Detect CUDA for LiteRT (CUDA delegate available via external delegate)
$cudaRoot = if ($env:CUDA_ROOT) { $env:CUDA_ROOT } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { $null }
$cmakeExtra = @(
    '-DTFLITE_ENABLE_INSTALL=ON'
    '-DTFLITE_ENABLE_LABEL_IMAGE=ON'
    '-DTFLITE_ENABLE_BENCHMARK_MODEL=ON'
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
)

# Add CUDA paths for external delegate compilation if available
if ($cudaRoot -and (Test-Path $cudaRoot)) {
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$cudaRoot"
    $cudaInclude = Join-Path $cudaRoot 'include'
    if (Test-Path $cudaInclude) {
        $cmakeExtra += "-DCMAKE_CXX_FLAGS:STRING=-I$cudaInclude"
    }
}

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
$ok = Invoke-CmakeBuild -BuildDir $buildDir -Config Release -Install -LogFile $buildLog
if (-not $ok) { throw 'LiteRT build failed' }

Write-Host '=== LiteRT source build completed ==='
