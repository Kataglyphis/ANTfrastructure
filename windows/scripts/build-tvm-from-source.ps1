# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\tvm-src',
    [string]$InstallDir = '',
    [string]$TvmVersion = '',
    [string]$BuildType = 'Release',
    [switch]$SkipPython
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$TvmVersion = Get-SourceBuildVersion -Value $TvmVersion -EnvironmentVariables @('TVM_REF', 'TVM_VERSION') -DefaultValue 'v0.25.0'

Write-Host "=== TVM source build (v$TvmVersion, Ninja+clang-cl) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/apache/tvm.git' -Tag $TvmVersion -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone TVM' }

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
    "-DUSE_VULKAN=$useVulkan"
    "-DUSE_LLVM=$useLLVM"
    "-DTVM_BUILD_PYTHON_MODULE=$pythonModule"
)

if ($gpuEnv.CudaRoot) {
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$($gpuEnv.CudaRoot -replace '\\', '/')"
}

if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    $cmakeExtra += "-DVulkan_INCLUDE_DIR=$(Join-Path $vulkanSdk 'Include')"
    $vulkanLib = Join-Path $vulkanSdk 'Lib'
    if (Test-Path $vulkanLib) {
        $cmakeExtra += "-DVulkan_LIBRARY=$(Join-Path $vulkanLib 'vulkan-1.lib')"
    }
}

# CMAKE_AR: find llvm-lib on PATH -- use :FILEPATH (matches OpenCV/LiteRT form) for consistency.
$llvmLib = Resolve-LlvmArchiver
if ($llvmLib) {
    $cmakeExtra += "-DCMAKE_AR:FILEPATH=$llvmLib"
}

$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $tvmInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'TVM CMake configuration failed' }

Write-Host 'Building TVM (this may take 30-60 minutes)...'
$buildLog = Join-Path $buildDir 'tvm-build.log'
$ok = Invoke-CmakeBuild -BuildDir $buildDir -Config $BuildType -LogFile $buildLog
if (-not $ok) { throw 'TVM build failed' }

Write-Host 'Installing...'
& cmake --install $buildDir --config $BuildType

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
            cmd.exe /c """$($py.Exe)"" -m pip install . --no-deps --quiet 2>&1"
            if ($LASTEXITCODE -ne 0) { Write-Host "WARNING: TVM Python wheel install failed (exit $LASTEXITCODE) - C++ runtime is still installed" }
            Pop-Location
        }
    }
}

Remove-SourceBuildTree -Path $SourceDir

Write-Host '=== TVM source build completed ==='
Write-Host "Artifacts at: $tvmInstallDir"



