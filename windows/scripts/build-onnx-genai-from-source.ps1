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

# Build using the official build.py with Ninja+clang-cl
Write-Host 'Building ONNX GenAI with build.py (Ninja+clang-cl)...'
& $pythonExe build.py `
    --config Release `
    --update `
    --build `
    --skip_tests `
    --skip_wheel `
    --parallel `
    --build_dir build\Windows-ClangCL `
    --cmake_generator Ninja `
    --cmake_extra_defines CMAKE_C_COMPILER=clang-cl CMAKE_CXX_COMPILER=clang-cl

if ($LASTEXITCODE -ne 0) { throw 'ONNX GenAI build failed' }

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
