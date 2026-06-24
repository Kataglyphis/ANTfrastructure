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
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\gstreamer' }

Write-Host "=== TVM source build (v$TvmVersion, Ninja+clang-cl) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/apache/tvm.git' -Tag $TvmVersion -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone TVM' }

# Load VsDevCmd: ml64 for .asm + cl.exe for CUDA host compiler
cmd /c """C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat"" -arch=amd64 -host_arch=amd64 && set" | ForEach-Object {
    if ($_ -match '^(.*?)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] }
}

$buildDir = Join-Path $SourceDir 'build'
$tvmInstallDir = Join-Path $InstallDir 'lib\tvm'

# Auto-detect CUDA
$cudaRoot = if ($env:CUDA_ROOT) { $env:CUDA_ROOT } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { $null }
$useCuda = 'OFF'
if ($cudaRoot -and (Test-Path $cudaRoot)) {
    Write-Host "CUDA detected at: $cudaRoot — enabling TVM CUDA support"
    $useCuda = 'ON'
    $env:CUDA_PATH = $cudaRoot
    $cudaBin = Join-Path $cudaRoot 'bin'
    if (Test-Path $cudaBin) { $env:PATH = "$cudaBin;$env:PATH" }
}

# Auto-detect Vulkan SDK
$vulkanSdk = if ($env:VULKAN_SDK) { $env:VULKAN_SDK } else { $null }
$useVulkan = 'OFF'
if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    Write-Host "Vulkan SDK detected at: $vulkanSdk — enabling TVM Vulkan support"
    $useVulkan = 'ON'
}

# Auto-detect LLVM
$llvmConfig = (Get-Command llvm-config.exe -ErrorAction SilentlyContinue).Source
$useLvm = 'OFF'
if ($llvmConfig) {
    Write-Host "LLVM detected via llvm-config: $llvmConfig — enabling TVM LLVM codegen"
    $useLvm = 'ON'
}

$pythonModule = if ($SkipPython) { 'OFF' } else { 'ON' }

$cmakeExtra = @(
    "-DCMAKE_BUILD_TYPE=$BuildType"
    '-DUSE_OPENCL=OFF'
    '-DUSE_MICRO=OFF'
    "-DUSE_CUDA=$useCuda"
    "-DUSE_VULKAN=$useVulkan"
    "-DUSE_LLVM=$useLvm"
    "-DTVM_BUILD_PYTHON_MODULE=$pythonModule"
)

if ($cudaRoot -and (Test-Path $cudaRoot)) {
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$cudaRoot"
}

if ($vulkanSdk -and (Test-Path $vulkanSdk)) {
    $cmakeExtra += "-DVulkan_INCLUDE_DIR=$(Join-Path $vulkanSdk 'Include')"
    $vulkanLib = Join-Path $vulkanSdk 'Lib'
    if (Test-Path $vulkanLib) {
        $cmakeExtra += "-DVulkan_LIBRARY=$(Join-Path $vulkanLib 'vulkan-1.lib')"
    }
}

$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $tvmInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'TVM CMake configuration failed' }

Write-Host 'Building TVM (this may take 30-60 minutes)...'
$buildLog = Join-Path $buildDir 'tvm-build.log'
$ok = Invoke-CmakeBuild -BuildDir $buildDir -Config $BuildType -Install -LogFile $buildLog
if (-not $ok) { throw 'TVM build failed' }

# Install Python wheel if enabled
if ($pythonModule -eq 'ON') {
    $pythonExe = 'C:\temp\cpython\PCbuild\amd64\python.exe'
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
