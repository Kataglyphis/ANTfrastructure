param(
    [string]$SourceDir = 'C:\temp\litert-lm-src',
    [string]$InstallDir = '',
    [string]$LiteRtLmVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$LiteRtLmVersion = Get-SourceBuildVersion -Value $LiteRtLmVersion -EnvironmentVariables @('LITERT_LM_VERSION') -DefaultValue '0.13.1'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\gstreamer' }
$litertLmInstallDir = Join-Path $InstallDir 'lib\litert-lm'

Write-Host "=== LiteRT-LM source build (v$LiteRtLmVersion, Ninja+clang-cl) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT-LM.git' -Tag "v$LiteRtLmVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone LiteRT-LM' }

# Install git-lfs and pull LFS data
Write-Host 'Setting up git-lfs...'
& git lfs install --skip-repo 2>&1 | Out-Null
Push-Location $SourceDir
& git lfs pull 2>&1 | Out-Null
Pop-Location

$buildDir = Join-Path $SourceDir 'build_ninja'

# Find the LiteRT installation (built in previous stage)
$litertInstallDir = Join-Path $InstallDir 'lib\litert'
$litertCmakeDir = Join-Path $litertInstallDir 'cmake'
if (-not (Test-Path $litertCmakeDir)) {
    $litertCmakeDir = Join-Path $litertInstallDir 'lib\cmake\LiteRT'
}
$litertIncludeDir = Join-Path $litertInstallDir 'include'

# Detect CUDA for LiteRT-LM external GPU delegate
$cudaRoot = if ($env:CUDA_ROOT) { $env:CUDA_ROOT } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { $null }

$cmakeExtra = @(
    '-DCMAKE_CXX_FLAGS:STRING=/EHs-c- /D_HAS_EXCEPTIONS=0'
    # Point to the built LiteRT
    "-DCMAKE_PREFIX_PATH=$litertInstallDir;$litertCmakeDir"
    "-DLiteRT_INCLUDE_DIR=$litertIncludeDir"
    # Enable GPU delegate when available
    '-DTFLITE_ENABLE_GPU=ON'
)

# Add CUDA support if detected
if ($cudaRoot -and (Test-Path $cudaRoot)) {
    $cmakeExtra += '-DUSE_CUDA=ON'
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$cudaRoot"
    $cudaBin = Join-Path $cudaRoot 'bin'
    if (Test-Path $cudaBin) { $cmakeExtra += "-DCMAKE_CUDA_COMPILER:FILEPATH=$(Join-Path $cudaBin 'nvcc.exe')" }
}

# Add LitRT cmake config dir if using find_package
if (Test-Path $litertCmakeDir) {
    $cmakeExtra += "-DLiteRT_DIR=$litertCmakeDir"
}

$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $litertLmInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'LiteRT-LM CMake configure failed' }

$buildLog = Join-Path $buildDir 'litert-lm-build.log'
$ok = Invoke-CmakeBuild -BuildDir $buildDir -Config Release -Install -LogFile $buildLog
if (-not $ok) { throw 'LiteRT-LM build failed' }

Write-Host '=== LiteRT-LM source build completed ==='
