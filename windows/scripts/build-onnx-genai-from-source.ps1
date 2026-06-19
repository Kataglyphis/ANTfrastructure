param(
    [string]$SourceDir = 'C:\temp\onnx-genai-src',
    [string]$InstallDir = '',
    [string]$OnnxGenAiVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$OnnxGenAiVersion = Get-SourceBuildVersion -Value $OnnxGenAiVersion -EnvironmentVariables @('ONNXRUNTIME_GENAI_VERSION', 'ONNX_GENAI_VERSION') -DefaultValue '0.13.1'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\gstreamer' }

Write-Host "=== ONNX Runtime GenAI source build (v$OnnxGenAiVersion, Ninja+clang-cl) ==="
Write-Host "SourceDir: $SourceDir"
Write-Host "InstallDir: $InstallDir"

$genaiInstallDir = Join-Path $InstallDir 'lib\onnxruntime-genai-source'

# Use the source-built Python from the toolchain layer
$pythonExe = 'C:\temp\cpython\PCbuild\amd64\python.exe'
if (-not (Test-Path $pythonExe)) { throw "Python not found at $pythonExe" }
Write-Host "Using Python: $pythonExe"

# Install pip (source-built Python doesn't include it)
Write-Host 'Installing pip...'
$pipScript = Join-Path $env:TEMP 'get-pip.py'
Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $pipScript -UseBasicParsing
# Use cmd.exe to avoid PowerShell's $ErrorActionPreference treating stderr as errors
cmd.exe /c """$pythonExe"" ""$pipScript"" --quiet 2>&1"
if ($LASTEXITCODE -ne 0) { throw 'get-pip.py failed' }
Remove-Item $pipScript -Force -ErrorAction SilentlyContinue

Write-Host 'Installing cmake, ninja, requests via pip...'
cmd.exe /c """$pythonExe"" -m pip install cmake ninja requests --no-warn-script-location --quiet 2>&1"
if ($LASTEXITCODE -ne 0) { throw 'pip install build deps failed' }

Write-Host 'Locating VS installation via vswhere...'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere not found at $vswhere" }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'VS installation not found' }
Write-Host "VS path: $vsPath"

Write-Host 'Loading VsDevCmd environment...'
cmd.exe /c """$vsPath\Common7\Tools\VsDevCmd.bat"" -arch=x64 -host_arch=x64 && set" | ForEach-Object {
    if ($_ -match '^(.*?)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue }
}

# Clone onnxruntime-genai
$ok = Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime-genai.git' -Tag "v$OnnxGenAiVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone ONNX GenAI' }

Set-Location $SourceDir

# Copy pyconfig.h to Include/ (CPython builds it in PC/ not Include/)
$pyConfigSrc = 'C:\temp\cpython\PC\pyconfig.h'
$pyConfigDst = 'C:\temp\cpython\Include\pyconfig.h'
if ((Test-Path $pyConfigSrc) -and -not (Test-Path $pyConfigDst)) { Copy-Item $pyConfigSrc $pyConfigDst -Force; Write-Host 'Copied pyconfig.h to Include/' }

# Build ONNX GenAI directly with cmake (bypass build.py which always builds examples)
$genaiBuildDir = Join-Path $SourceDir 'build\Windows-ClangCL\Release'
$ortInstallDir = Join-Path $InstallDir 'lib\onnxruntime-source'
# Auto-detect CUDA for GenAI
$genaiCudaArgs = @()
$cudaRoot = if ($env:CUDA_ROOT) { $env:CUDA_ROOT } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { $null }
$cudnnRoot = if ($env:CUDNN_ROOT) { $env:CUDNN_ROOT } else { $null }
# NOTE: CUDA=OFF because clang-cl cannot compile cuRAND host headers
# (curand_kernel.h uses __syncthreads, __umulhi, NV_PROVIDES_SM_61).
# GenAI uses ONNX Runtime's CUDA execution provider at runtime instead.
$genaiCudaArgs += '-DUSE_CUDA=OFF'
Write-Host 'CUDA support disabled for ONNX GenAI build (clang-cl incompatibility with CUDA headers)'

$cmakeExtraGenAi = @(
    '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
    '-DUSE_TRT_RTX=OFF', '-DUSE_DML=OFF'
    '-DENABLE_JAVA=OFF', '-DBUILD_WHEEL=OFF', '-DUSE_GUIDANCE=OFF'
    '-DPUBLISH_JAVA_MAVEN_LOCAL=OFF'
    '-DBUILD_EXAMPLES=OFF', '-DBUILD_TESTING=OFF'
    "-DCMAKE_CXX_FLAGS:STRING=/GR /EHsc -D_SILENCE_CLANG_COROUTINE_MESSAGE"
    "-DPYTHON_EXECUTABLE=$pythonExe"
    "-DPYTHON_LIBRARY=C:/temp/cpython/PCbuild/amd64/python3.lib"
    "-DPYTHON_INCLUDE_DIR=C:/temp/cpython/Include"
) + $genaiCudaArgs
$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $genaiBuildDir -InstallPrefix $genaiInstallDir -ExtraArgs $cmakeExtraGenAi
if (-not $ok) { throw 'ONNX GenAI CMake configure failed' }

# Patch MSVC STL experimental/coroutine header to disable clang static_assert
$coroHeader = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231\include\experimental\coroutine"
if (Test-Path $coroHeader) {
    $text = [System.IO.File]::ReadAllText($coroHeader)
    if ($text -match '_EMIT_STL_ERROR\(STL1009') {
        $text = $text -replace '_EMIT_STL_ERROR\(STL1009, ".*?"\)', ''
        [System.IO.File]::WriteAllText($coroHeader, $text)
        Write-Host 'Patched MSVC experimental/coroutine header'
    }
}
# Also patch yvals_core.h to make _EMIT_STL_ERROR a no-op when __clang__
$yvalsCore = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231\include\yvals_core.h"
if (Test-Path $yvalsCore) {
    $text = [System.IO.File]::ReadAllText($yvalsCore)
    if ($text -match '#define _EMIT_STL_ERROR') {
        $old = '#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)'
        $new = '#ifdef __clang__
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)
#else
#define _EMIT_STL_ERROR(NUMBER, MESSAGE)   static_assert(false, "error " #NUMBER ": " MESSAGE)
#endif'
        $text = $text -replace [regex]::Escape($old), $new
        [System.IO.File]::WriteAllText($yvalsCore, $text)
        Write-Host 'Patched MSVC yvals_core.h for clang compat'
    }
}

# Patch build.ninja to strip MSVC-only flags clang-cl errors on
$ninjaFile = Join-Path $genaiBuildDir 'build.ninja'
if (Test-Path $ninjaFile) {
    $text = [System.IO.File]::ReadAllText($ninjaFile)
    $orig = $text
    $text = $text -replace '/Qspectre', ''
    $text = $text -replace '(?<=\s)/WX(?=\s)', ''
    if ($text -ne $orig) {
        [System.IO.File]::WriteAllText($ninjaFile, $text)
        Write-Host 'Patched build.ninja for clang-cl compatibility'
    }
}

Write-Host 'Building with ninja directly...'
$batFile = Join-Path $env:TEMP 'build_genai.bat'
"@echo off
ninja -C `"$genaiBuildDir`" -j%NUMBER_OF_PROCESSORS% 2>&1
if errorlevel 1 ninja -C `"$genaiBuildDir`" 2>&1
" | Set-Content -Path $batFile -Encoding ASCII
cmd.exe /c $batFile
$buildExit = $LASTEXITCODE

if ($buildExit -ne 0) {
    # Try single-threaded to see full error
    Write-Host 'Retrying single-threaded for clear error output...'
    cmd.exe /c "ninja -C `"$genaiBuildDir`" -j1 2>&1"
    throw "ONNX GenAI build failed"
}

Write-Host 'Installing...'
& cmake --install $genaiBuildDir --config Release
if ($LASTEXITCODE -ne 0) { throw 'Install failed' }

Write-Host "Installing to $genaiInstallDir..."
# Copy built artifacts
$buildOutDir = Join-Path $SourceDir 'build\Windows-ClangCL\Release'
if (Test-Path $buildOutDir) {
    New-Item -Path $genaiInstallDir\include -ItemType Directory -Force | Out-Null
    New-Item -Path $genaiInstallDir\lib -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $buildOutDir '*.h') -Destination "$genaiInstallDir\include" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $buildOutDir '*.lib') -Destination "$genaiInstallDir\lib" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $buildOutDir '*.dll') -Destination "$genaiInstallDir\lib" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $buildOutDir '*.pyd') -Destination "$genaiInstallDir\lib" -Force -ErrorAction SilentlyContinue
}
# Also check alternate output dirs
$altOutDir = Join-Path $SourceDir 'build\Windows-ClangCL\Windows\Release'
if (Test-Path $altOutDir) {
    Copy-Item -Path (Join-Path $altOutDir '*') -Destination "$genaiInstallDir\lib" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '=== ONNX Runtime GenAI source build completed ==='
Write-Host "Artifacts at: $genaiInstallDir"
