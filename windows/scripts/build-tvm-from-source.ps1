# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\tvm-src',
    [string]$InstallDir = '',
    [string]$TvmVersion = '',
    [string]$BuildType = 'Release',
    [switch]$SkipPython
)

$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildEnvironment -InstallDir $InstallDir

$TvmVersion = Get-SourceBuildVersion -Value $TvmVersion -EnvironmentVariables @('TVM_REF', 'TVM_VERSION') -DefaultValue 'v0.25.0'

Write-Host "=== TVM source build (v$TvmVersion, Ninja+clang-cl) ==="

Invoke-GitClone -RepoUrl 'https://github.com/apache/tvm.git' -Tag $TvmVersion -SourceDir $SourceDir -Recursive | Out-Null

# TVM requires VsDevCmd for MSVC STL headers (but does not consume the source-built CPython directly
# -- TVM builds its own Python wheel against the system Python), so do VsDevCmd alone, not the full
# Initialize-ToolchainPythonEnvironment preamble.
Enter-VsDevCmdEnvironment

$buildDir = Join-Path $SourceDir 'build'
$tvmInstallDir = Join-Path $InstallDir 'lib\tvm'

# Auto-detect CUDA via the canonical GPU environment helper (CUDA_PATH / PATH already set by it).
$gpuEnv = Get-GpuEnvironment
$useCuda = if ($gpuEnv.GpuType -eq 'nvidia' -and $gpuEnv.CudaRoot) { 'ON' } else { 'OFF' }
if ($useCuda -eq 'ON') { Write-Host "CUDA detected at: $($gpuEnv.CudaRoot) - enabling TVM CUDA support" }

# GPU math libraries (CUDA lane only). cuBLAS ships inside the CUDA toolkit (found via
# CUDAToolkit_ROOT), so it needs no extra hint. cuDNN is a SEPARATE install: enable it only
# when cudnn.h + cudnn.lib actually resolve.
# NOTE: TVM uses its legacy cmake/utils/FindCUDA.cmake, which looks up the variable
# CUDA_CUDNN_LIBRARY (NOT the standard CUDNN_INCLUDE_DIR/CUDNN_LIBRARY -- those are silently
# ignored). Because cuDNN lives OUTSIDE the CUDA toolkit dir here, TVM's find_library returns
# NOTFOUND and configure dies, so we set CUDA_CUDNN_LIBRARY directly and also put cuDNN's
# include/lib on INCLUDE/LIB so clang-cl finds cudnn.h and lld-link finds cudnn.lib at compile.
$useCublas = $useCuda
$useCudnn  = 'OFF'
$cudnnArgs = @()
if ($useCuda -eq 'ON' -and $gpuEnv.CudnnRoot -and (Test-Path (Join-Path $gpuEnv.CudnnRoot 'include\cudnn.h'))) {
    # Shared cuDNN import-lib finder (prefers cudnn.lib over the 9.x split sub-libs); $null when absent.
    $cudnnLibPath = Get-CudnnLibrary -CudnnRoot $gpuEnv.CudnnRoot
    if ($cudnnLibPath) {
        $cudnnLibDir = Split-Path $cudnnLibPath -Parent
        $useCudnn  = 'ON'
        $cudnnArgs = @("-DCUDA_CUDNN_LIBRARY=$($cudnnLibPath -replace '\\','/')")
        $env:INCLUDE = "$(Join-Path $gpuEnv.CudnnRoot 'include');$env:INCLUDE"
        $env:LIB     = "$cudnnLibDir;$env:LIB"
        Write-Host "cuDNN detected at $($gpuEnv.CudnnRoot) - enabling TVM cuDNN (CUDA_CUDNN_LIBRARY=$(Split-Path $cudnnLibPath -Leaf))"
    }
}

# Auto-detect Vulkan SDK
$vulkanSdk = if ($env:VULKAN_SDK) { $env:VULKAN_SDK } else { $null }
$useVulkan = 'OFF'
if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    Write-Host "Vulkan SDK detected at: $vulkanSdk - enabling TVM Vulkan support"
    $useVulkan = 'ON'
}

# Auto-detect LLVM
$llvmCmd = Get-Command llvm-config.exe -ErrorAction SilentlyContinue
$llvmConfig = if ($llvmCmd) { $llvmCmd.Source } else { $null }
$useLLVM = 'OFF'
if ($llvmConfig) {
    Write-Host "LLVM detected via llvm-config: $llvmConfig - enabling TVM LLVM codegen"
    $useLLVM = 'ON'
}

$pythonModule = if ($SkipPython) { 'OFF' } else { 'ON' }

$cmakeExtra = @(
    "-DCMAKE_BUILD_TYPE=$BuildType"
    '-DCMAKE_CXX_FLAGS="-Wno-unknown-attributes"'
    '-DUSE_OPENCL=OFF'
    '-DUSE_MICRO=OFF'
    "-DUSE_CUDA=$useCuda"
    "-DUSE_CUBLAS=$useCublas"
    "-DUSE_CUDNN=$useCudnn"
    "-DUSE_VULKAN=$useVulkan"
    "-DUSE_LLVM=$useLLVM"
    "-DTVM_BUILD_PYTHON_MODULE=$pythonModule"
)

$cmakeExtra += Get-CudaToolkitRootArg -GpuEnv $gpuEnv -ForwardSlash
$cmakeExtra += $cudnnArgs

if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    $cmakeExtra += "-DVulkan_INCLUDE_DIR=$(Join-Path $vulkanSdk 'Include')"
    $vulkanLib = Join-Path $vulkanSdk 'Lib'
    if (Test-Path $vulkanLib) {
        $cmakeExtra += "-DVulkan_LIBRARY=$(Join-Path $vulkanLib 'vulkan-1.lib')"
    }
}

# CMAKE_AR: find llvm-lib on PATH -- use :FILEPATH (matches OpenCV/LiteRT form) for consistency.
$cmakeExtra += Get-LlvmArchiverCmakeArg

Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $tvmInstallDir -ExtraArgs $cmakeExtra | Out-Null

Write-Host 'Building TVM (this may take 30-60 minutes)...'
$buildLog = Join-Path $buildDir 'tvm-build.log'
Invoke-CmakeBuild -BuildDir $buildDir -Config $BuildType -LogFile $buildLog | Out-Null

Write-Host 'Installing...'
& cmake --install $buildDir --config $BuildType

# TVM 0.25's FFI split builds libtvm_ffi as a SEPARATE shared lib that tvm_runtime.dll
# imports, but `cmake --install` does not stage tvm_ffi.dll -> tvm_runtime.dll then fails to
# load (0xC0000135 STATUS_DLL_NOT_FOUND) in the final image. Copy it next to the installed
# tvm_runtime.dll. Caught by the smoke-test TVM load probe.
$installedRuntime = Get-ChildItem -Path $tvmInstallDir -Filter 'tvm_runtime.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($installedRuntime) {
    $ffiSrc = Get-ChildItem -Path $buildDir -Filter 'tvm_ffi.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ffiSrc) {
        Copy-Item $ffiSrc.FullName -Destination $installedRuntime.DirectoryName -Force
        Write-Host "Staged tvm_ffi.dll -> $($installedRuntime.DirectoryName) (cmake --install missed the FFI shared lib)"
    } else {
        Write-Host "WARNING: tvm_ffi.dll not found under $buildDir -- tvm_runtime.dll may fail to load at runtime"
    }
}

# Install Python wheel if enabled
if ($pythonModule -eq 'ON') {
    $py = Get-SourceBuildPython
    if (Test-Path $py.Exe) {
        # Bootstrap pip if missing — this script can no longer rely on the GenAI
        # build having installed it first (parallel media branches).
        Install-CpythonPip -Python $py
        Write-Host 'Installing TVM Python wheel...'
        $wheelDir = Join-Path $buildDir 'python'
        if (Test-Path $wheelDir) {
            Push-Location $wheelDir
            Invoke-CpythonPip -Python $py -Arguments @('install', '.', '--no-deps', '--quiet') -Optional
            Pop-Location
        }
    }
}

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== TVM source build completed ==='
Write-Host "Artifacts at: $tvmInstallDir"



