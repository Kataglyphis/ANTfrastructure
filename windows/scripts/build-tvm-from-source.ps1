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

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$TvmVersion = Get-SourceBuildVersion -Value $TvmVersion -EnvironmentVariables @('TVM_REF', 'TVM_VERSION') -DefaultValue 'v0.24.0'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }

Write-Host "=== TVM source build (v$TvmVersion, Ninja+clang-cl) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/apache/tvm.git' -Tag $TvmVersion -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone TVM' }

Enter-VsDevCmdEnvironment

$buildDir = Join-Path $SourceDir 'build'
$tvmInstallDir = Join-Path $InstallDir 'lib\tvm'

# Auto-detect CUDA
$cudaRoot = Get-CudaRoot
$useCuda = 'OFF'
if ($cudaRoot -and (Test-Path $cudaRoot)) {
    Write-Host "CUDA detected at: $cudaRoot - enabling TVM CUDA support"
    $useCuda = 'ON'
    $env:CUDA_PATH = $cudaRoot
    $cudaBin = Join-Path $cudaRoot 'bin'
    if (Test-Path $cudaBin) { $env:PATH = "$cudaBin;$env:PATH" }
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
    "-DUSE_VULKAN=$useVulkan"
    "-DUSE_LLVM=$useLLVM"
    "-DTVM_BUILD_PYTHON_MODULE=$pythonModule"
)

if ($cudaRoot -and (Test-Path $cudaRoot)) {
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$($cudaRoot -replace '\\', '/')"
}

if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    $cmakeExtra += "-DVulkan_INCLUDE_DIR=$(Join-Path $vulkanSdk 'Include')"
    $vulkanLib = Join-Path $vulkanSdk 'Lib'
    if (Test-Path $vulkanLib) {
        $cmakeExtra += "-DVulkan_LIBRARY=$(Join-Path $vulkanLib 'vulkan-1.lib')"
    }
}

# Fix llvm-lib archiver path for clang-cl builds
$llvmLib = Get-Command llvm-lib.exe -ErrorAction SilentlyContinue
if ($llvmLib) {
    $cmakeExtra += "-DCMAKE_AR:PATH=$($llvmLib.Source)"
}

$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $tvmInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'TVM CMake configuration failed' }

Write-Host 'Building TVM (this may take 30-60 minutes)...'
$buildLog = Join-Path $buildDir 'tvm-build.log'
Write-Host "Building..."
& cmake --build $buildDir --config $BuildType --parallel 2>&1 | Tee-Object -FilePath $buildLog
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n=== BUILD FAILED: FAILED: lines ==="
    Select-String -Path $buildLog -Pattern 'FAILED:' -SimpleMatch | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
    Write-Host "=== BUILD FAILED: error: lines ==="
    Select-String -Path $buildLog -Pattern '^.*error:.*$' | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
    Write-Host "=== BUILD FAILED: last 20 lines ==="
    Get-Content $buildLog -Tail 20 | ForEach-Object { Write-Host $_ }
    throw 'TVM build failed'
}
Write-Host 'Installing...'
& cmake --install $buildDir --config $BuildType

# Install Python wheel if enabled
if ($pythonModule -eq 'ON') {
    $pythonExe = Join-Path $env:TEMP_DIR 'cpython\PCbuild\amd64\python.exe'
    if (Test-Path $pythonExe) {
        Write-Host 'Installing TVM Python wheel...'
        $wheelDir = Join-Path $buildDir 'python'
        if (Test-Path $wheelDir) {
            Push-Location $wheelDir
            cmd.exe /c """$pythonExe"" -m pip install . --no-deps --quiet 2>&1"
            Pop-Location
        }
    }
}

Write-Host '=== TVM source build completed ==='
Write-Host "Artifacts at: $tvmInstallDir"
