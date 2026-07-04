# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Comprehensive smoke test for the Windows Kataglyphis container image.
    Validates all build tools, compilers, libraries, and AI runtimes.

.DESCRIPTION
    Runs inside the container (or on the build host) to verify:
    - Build tools (git, cmake, ninja, clang-cl, lld-link, msbuild)
    - Python 3.14.6 from source
    - Rust toolchain (cargo, rustc)
    - CUDA Toolkit + cuDNN
    - ONNX Runtime + GenAI (header, lib, DLL)
    - OpenCV 5 (header, lib, DLL)
    - GStreamer (gst-launch-1.0, core plugins)
    - Vulkan SDK
    - LLVM/Clang
    - WiX toolset
    - Flutter/Dart
    - VS Build Tools / VsDevCmd
    - TVM (source-built)
    - FFmpeg (source-built with DNN/ONNX integration)

.EXAMPLE
    powershell -File smoke-test-container.ps1
#>

param(
    [switch]$SkipCudaTests,
    [switch]$ExitOnFirstFailure
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:passed = 0
$script:failed = 0
$script:skipped = 0
$script:failureDetails = @()

function Write-TestHeader {
    param([string]$Title)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Assert-Test {
    param(
        [string]$Name,
        [scriptblock]$Condition,
        [string]$FailMessage = 'Assertion failed'
    )

    try {
        $result = & $Condition
        if ($result) {
            Write-Host "  [PASS] $Name" -ForegroundColor Green
            $script:passed++
        } else {
            Write-Host "  [FAIL] $Name : $FailMessage" -ForegroundColor Red
            $script:failed++
            $script:failureDetails += "[FAIL] $Name : $FailMessage"
            if ($ExitOnFirstFailure) { throw "Smoke test failed: $Name" }
        }
    } catch {
        Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
        $script:failureDetails += "[FAIL] $Name : $($_.Exception.Message)"
        if ($ExitOnFirstFailure) { throw "Smoke test failed: $Name" }
    }
}

function Assert-CommandExists {
    param([string]$Name)
    # GetNewClosure: the scriptblock is invoked inside Assert-Test, whose own $Name
    # parameter shadows this one under PowerShell's dynamic scoping — without the
    # closure this evaluated Get-Command "Command 'git' on PATH" and always failed.
    $commandName = $Name
    Assert-Test -Name "Command '$Name' on PATH" -Condition { (Get-Command $commandName -ErrorAction SilentlyContinue) -ne $null }.GetNewClosure() -FailMessage "$Name not found on PATH"
}

function Assert-FileExists {
    param([string]$Path, [string]$Description = $Path)
    Assert-Test -Name $Description -Condition { Test-Path $Path -PathType Leaf } -FailMessage "File not found: $Path"
}

function Assert-DirectoryExists {
    param([string]$Path, [string]$Description = $Path)
    Assert-Test -Name $Description -Condition { Test-Path $Path -PathType Container } -FailMessage "Directory not found: $Path"
}

function Assert-EnvVarSet {
    param([string]$Name, [string]$ExpectedPrefix = '')
    # GetNewClosure + renamed captures: Assert-Test's $Name parameter shadows this
    # one at invocation time (dynamic scoping), so the env var that was actually
    # queried used to be the test title — always failing.
    $envName = $Name
    $envPrefix = $ExpectedPrefix
    Assert-Test -Name "Env var $Name" -Condition {
        $val = [Environment]::GetEnvironmentVariable($envName)
        if ([string]::IsNullOrWhiteSpace($val)) { return $false }
        if ($envPrefix) { return $val -like "$envPrefix*" }
        return $true
    }.GetNewClosure() -FailMessage "$Name is not set or doesn't match expected prefix"
}

function Get-CommandVersion {
    param([string]$Name)
    try {
        $ver = & $Name --version 2>&1 | Select-Object -First 1
        return $ver
    } catch { return $null }
}

# Expected versions come from the single source of truth (versions.env), not
# hardcoded literals that silently drift on a version bump. load-versions.ps1
# bakes every versions.env key as a Machine-scoped env var during the base
# build, so in-container that env var is authoritative; on the build host we
# fall back to the repo's versions.env, then to a literal only as a last resort.
$script:versionsFromFile = @{}
$repoVersions = Join-Path $PSScriptRoot '..\..\linux\scripts\01-core\versions.env'
if (Test-Path $repoVersions) {
    Get-Content $repoVersions | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -notmatch '^#') {
            $kv = $line -split '=', 2
            if ($kv.Count -eq 2) { $script:versionsFromFile[$kv[0].Trim()] = $kv[1].Trim().Trim('"', "'") }
        }
    }
}
function Get-ExpectedVersion {
    param([string]$Key, [string]$Fallback)
    $v = [Environment]::GetEnvironmentVariable($Key)
    if ([string]::IsNullOrWhiteSpace($v)) { $v = $script:versionsFromFile[$Key] }
    if ([string]::IsNullOrWhiteSpace($v)) { return $Fallback }
    return $v.TrimStart('v')
}

# ============================================================================
Write-TestHeader '1. Build Tools'
# ============================================================================
Assert-CommandExists 'git'
Assert-CommandExists 'cmake'
Assert-CommandExists 'ninja'
Assert-CommandExists 'clang-cl'
Assert-CommandExists 'lld-link'
Assert-CommandExists 'llvm-lib'
Assert-CommandExists 'msbuild'  # from VS Build Tools
Assert-CommandExists 'nuget'

# Verify clang-cl version (major derived from LLVM_RELEASE in versions.env)
$clangVer = Get-CommandVersion 'clang-cl'
$clangMajor = (Get-ExpectedVersion 'LLVM_RELEASE' '22') -split '\.' | Select-Object -First 1
Assert-Test -Name "clang-cl version" -Condition { $clangVer -ne $null } -FailMessage "Could not get clang-cl version"
Assert-Test -Name "clang-cl version string" -Condition { $clangVer -match ([regex]::Escape($clangMajor) + '\.') } -FailMessage "clang-cl version is not $clangMajor.x"

# Verify cmake version
$cmakeVer = Get-CommandVersion 'cmake'
Assert-Test -Name "cmake version" -Condition { $cmakeVer -ne $null } -FailMessage "Could not get cmake version"

# ============================================================================
Write-TestHeader '2. Python (source-built)'
# ============================================================================
Assert-CommandExists 'python'
$pyMajorMinor = ((Get-ExpectedVersion 'PYTHON_VERSION' '3.14') -split '\.')[0..1] -join '.'
Assert-Test -Name "Python is $pyMajorMinor.x" -Condition {
    $ver = & python --version 2>&1
    return $ver -match ([regex]::Escape($pyMajorMinor) + '\.')
} -FailMessage "Python version is not $pyMajorMinor.x"

$cpythonDir = Join-Path $env:TEMP_DIR 'cpython'
Assert-Test -Name "Python source-built from $cpythonDir" -Condition {
    (Test-Path "$cpythonDir\PCbuild\amd64\python.exe") -or
    (Test-Path "$cpythonDir\PCbuild\amd64\python3.dll")
} -FailMessage "Python source build artifacts not found at $cpythonDir"

Assert-Test -Name "Python pip available" -Condition {
    & python -m pip --version 2>&1 | Select-Object -First 1 | ForEach-Object { $_ -ne $null }
} -FailMessage "pip not available"

# ============================================================================
Write-TestHeader '3. Rust Toolchain'
# ============================================================================
Assert-CommandExists 'cargo'
Assert-CommandExists 'rustc'
# Rust is provisioned via scoop (unpinned unless RUST_VERSION is set in
# versions.env), so assert the pinned major.minor when known, otherwise just
# that rustc reports a well-formed semver - avoids a literal that silently
# drifts on every scoop bump.
$rustExpected = Get-ExpectedVersion 'RUST_VERSION' ''
$rustMajorMinor = if ($rustExpected) { ($rustExpected -split '\.')[0..1] -join '.' } else { '' }
Assert-Test -Name "Rust version$(if ($rustMajorMinor) { " is $rustMajorMinor.x" })" -Condition {
    $ver = & rustc --version 2>&1
    if ($rustMajorMinor) { return $ver -match ([regex]::Escape($rustMajorMinor) + '\.') }
    return $ver -match '\d+\.\d+\.\d+'
} -FailMessage "rustc --version did not report the expected version"

# ============================================================================
Write-TestHeader '4. LLVM / Clang + Flutter + WiX'
# ============================================================================
Assert-CommandExists 'flutter'
Assert-Test -Name "Flutter works" -Condition {
    $output = & flutter --version 2>&1 | Out-String
    return $output -match 'Flutter'
} -FailMessage "Flutter --version failed"

Assert-FileExists -Path 'C:\WiX\wix.exe' -Description 'WiX toolset'
Assert-CommandExists 'sccache'
Assert-CommandExists 'cppcheck'
Assert-CommandExists '7z'
Assert-CommandExists 'uv'
Assert-CommandExists 'nano'

# ============================================================================
Write-TestHeader '5. Visual Studio Build Tools'
# ============================================================================
$vsDevCmd = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat'
Assert-FileExists -Path $vsDevCmd -Description 'VsDevCmd.bat'

Assert-Test -Name "MSBuild works (ClangCL toolset available)" -Condition {
    $msbuildOutput = & msbuild /version 2>&1 | Out-String
    return $msbuildOutput -match '18\.'
} -FailMessage "MSBuild /version doesn't show VS 18"

Assert-EnvVarSet -Name 'VCToolsInstallDir'

# Verify ClangCL platform toolset is available
$clangClToolsetPath = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Microsoft\VC\v180\Platforms\x64\PlatformToolsets\ClangCL"
Assert-DirectoryExists -Path $clangClToolsetPath -Description 'ClangCL MSBuild toolset'

# ============================================================================
Write-TestHeader '6. Vulkan SDK'
# ============================================================================
Assert-CommandExists 'glslc'
Assert-CommandExists 'vulkaninfoSDK'
Assert-EnvVarSet -Name 'VULKAN_SDK'

# ============================================================================
Write-TestHeader '7. CUDA Toolkit + cuDNN'
# ============================================================================
if (-not $SkipCudaTests) {
    Assert-CommandExists 'nvcc'
    $cudaMajorMinor = ((Get-ExpectedVersion 'CUDA_VERSION' '13.3') -split '\.')[0..1] -join '.'
    Assert-Test -Name "nvcc version is $cudaMajorMinor.x" -Condition {
        $ver = & nvcc --version 2>&1 | Out-String
        return $ver -match [regex]::Escape($cudaMajorMinor)
    } -FailMessage "nvcc version is not $cudaMajorMinor.x"

    Assert-EnvVarSet -Name 'CUDA_ROOT'
    Assert-EnvVarSet -Name 'CUDA_PATH'

    Assert-DirectoryExists -Path $env:CUDA_ROOT -Description "CUDA_ROOT directory"
    Assert-FileExists -Path (Join-Path $env:CUDA_ROOT 'bin\nvcc.exe') -Description 'nvcc.exe in CUDA_ROOT\bin'

    # cuDNN
    Assert-EnvVarSet -Name 'CUDNN_ROOT'
    $cudnnRoot = [Environment]::GetEnvironmentVariable('CUDNN_ROOT')
    Assert-DirectoryExists -Path $cudnnRoot -Description "CUDNN_ROOT directory"

    # Check cuDNN headers/libs/DLLs recursively as they may be in subdirs
    $cudnnHeaders = Get-ChildItem -Path $cudnnRoot -Filter 'cudnn*.h' -Recurse -ErrorAction SilentlyContinue
    $cudnnLibs = Get-ChildItem -Path $cudnnRoot -Filter 'cudnn*.lib' -Recurse -ErrorAction SilentlyContinue
    $cudnnDlls = Get-ChildItem -Path $cudnnRoot -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue

    Assert-Test -Name "cuDNN headers (cudnn*.h)" -Condition { $cudnnHeaders.Count -gt 0 } -FailMessage "No cuDNN headers found"
    Assert-Test -Name "cuDNN libs (cudnn*.lib)" -Condition { $cudnnLibs.Count -gt 0 } -FailMessage "No cuDNN libs found"
    Assert-Test -Name "cuDNN DLLs (cudnn*.dll)" -Condition { $cudnnDlls.Count -gt 0 } -FailMessage "No cuDNN DLLs found"
} else {
    Write-Host '  [SKIP] CUDA/cuDNN tests skipped (--SkipCudaTests)' -ForegroundColor Yellow
    $script:skipped++
}

# ============================================================================
Write-TestHeader '8. ONNX Runtime (source-built)'
# ============================================================================
$onnxRoot = [Environment]::GetEnvironmentVariable('ONNX_ROOT')
if ($onnxRoot) {
    Assert-DirectoryExists -Path $onnxRoot -Description "ONNX_ROOT"
    # Recursive search: ORT installs headers nested (include\onnxruntime\...), not flat
    $onnxCxxHdr = Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime_cxx_api.h' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name 'ONNX C++ API header' -Condition { $onnxCxxHdr.Count -gt 0 } -FailMessage "onnxruntime_cxx_api.h not found under $onnxRoot"
    $onnxCHdr = Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime_c_api.h' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name 'ONNX C API header' -Condition { $onnxCHdr.Count -gt 0 } -FailMessage "onnxruntime_c_api.h not found under $onnxRoot"

    $libFiles = Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime*.lib' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "ONNX lib files" -Condition { $libFiles.Count -gt 0 } -FailMessage "No onnxruntime*.lib found in $onnxRoot"

    $dllFiles = Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime*.dll' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "ONNX DLL files" -Condition { $dllFiles.Count -gt 0 } -FailMessage "No onnxruntime*.dll found in $onnxRoot"
} else {
    Write-Host '  [SKIP] ONNX_ROOT not set' -ForegroundColor Yellow
    $script:skipped++
}

# ============================================================================
Write-TestHeader '9. ONNX Runtime GenAI (source-built)'
# ============================================================================
$genaiRoot = [Environment]::GetEnvironmentVariable('ONNX_GENAI_ROOT')
if ($genaiRoot) {
    Assert-DirectoryExists -Path $genaiRoot -Description "ONNX_GENAI_ROOT"
    $genaiHdr = Get-ChildItem -Path $genaiRoot -Filter 'ort_genai*.h' -Recurse -ErrorAction SilentlyContinue
    if (-not $genaiHdr) { $genaiHdr = Get-ChildItem -Path $genaiRoot -Filter 'onnxruntime-genai.h' -Recurse -ErrorAction SilentlyContinue }
    Assert-Test -Name 'ONNX GenAI header' -Condition { $genaiHdr.Count -gt 0 } -FailMessage "No GenAI header (ort_genai*.h / onnxruntime-genai.h) found under $genaiRoot"

    $genaiLibs = Get-ChildItem -Path $genaiRoot -Filter 'onnxruntime-genai*.lib' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "ONNX GenAI lib files" -Condition { $genaiLibs.Count -gt 0 } -FailMessage "No onnxruntime-genai*.lib found"

    $genaiDlls = Get-ChildItem -Path $genaiRoot -Filter 'onnxruntime-genai*.dll' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "ONNX GenAI DLL files" -Condition { $genaiDlls.Count -gt 0 } -FailMessage "No onnxruntime-genai*.dll found"
} else {
    Write-Host '  [SKIP] ONNX_GENAI_ROOT not set' -ForegroundColor Yellow
    $script:skipped++
}

# ============================================================================
Write-TestHeader '10. OpenCV 5 (source-built)'
# ============================================================================
$opencvInclude = [Environment]::GetEnvironmentVariable('OPENCV_INCLUDE')
$opencvLib = [Environment]::GetEnvironmentVariable('OPENCV_LIB')
$opencvBin = [Environment]::GetEnvironmentVariable('OPENCV_BIN')

if ($opencvInclude -and (Test-Path $opencvInclude)) {
    $cvHeaders = Get-ChildItem -Path $opencvInclude -Filter 'opencv.hpp' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "OpenCV headers (opencv.hpp)" -Condition { $cvHeaders.Count -gt 0 } -FailMessage "No OpenCV headers found"
} else {
    Write-Host '  [SKIP] OPENCV_INCLUDE not set or not found' -ForegroundColor Yellow
    $script:skipped++
}

if ($opencvBin -and (Test-Path $opencvBin)) {
    $cvDlls = Get-ChildItem -Path $opencvBin -Filter 'opencv_world*.dll' -ErrorAction SilentlyContinue
    Assert-Test -Name "OpenCV world DLL" -Condition { $cvDlls.Count -gt 0 } -FailMessage "No opencv_world*.dll found"
} else {
    Write-Host '  [SKIP] OPENCV_BIN not set or not found' -ForegroundColor Yellow
    $script:skipped++
}

# ============================================================================
Write-TestHeader '11. GStreamer (source-built)'
# ============================================================================
Assert-CommandExists 'gst-launch-1.0'
Assert-CommandExists 'gst-inspect-1.0'
Assert-Test -Name "GStreamer core plugin available" -Condition {
    $plugins = & gst-inspect-1.0 2>&1 | Out-String
    return $plugins -match 'coreelements'
} -FailMessage "GStreamer coreelements plugin not found"

$gstBin = [Environment]::GetEnvironmentVariable('GSTREAMER_BIN')
Assert-DirectoryExists -Path $gstBin -Description "GSTREAMER_BIN"

# Verify GStreamer can create and run a trivial pipeline. num-buffers=1 is
# essential: a bare fakesrc produces buffers FOREVER and hangs the smoke test.
Assert-Test -Name "GStreamer pipeline creation (fake)" -Condition {
    $result = & gst-launch-1.0 --gst-plugin-path="$gstBin\..\lib\gstreamer-1.0" fakesrc num-buffers=1 ! fakesink 2>&1 | Out-String
    # If GST_PLUGIN_ERROR occurs but not a crash, the binary loads
    return $result -notmatch 'error while loading shared libraries'
} -FailMessage "GStreamer gst-launch-1.0 failed to load"

# ============================================================================
Write-TestHeader '12. LiteRT (AI Edge runtime, source-built)'
# ============================================================================
$litertRoot = 'C:\runtime\lib\litert'
$litertInclude = Join-Path $litertRoot 'include'
$litertLibDir = Join-Path $litertRoot 'lib'
$litertBinDir = Join-Path $litertRoot 'bin'

Assert-DirectoryExists -Path $litertRoot -Description 'LiteRT root dir'
Assert-DirectoryExists -Path $litertInclude -Description 'LiteRT include dir'

if (Test-Path $litertInclude) {
    # NB: -Filter matches file NAMES only — the old 'tensorflow/lite/c_api.h'
    # path-style filters could never match anything.
    $litertHeaders = Get-ChildItem -Path $litertInclude -Filter 'c_api.h' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "LiteRT C API header" -Condition { $litertHeaders.Count -gt 0 } -FailMessage "No c_api.h found under $litertInclude"
    $litertCxxHeaders = Get-ChildItem -Path $litertInclude -Filter 'interpreter.h' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "LiteRT C++ API header" -Condition { $litertCxxHeaders.Count -gt 0 } -FailMessage "No interpreter.h found under $litertInclude"
    $litertGpuHeaders = Get-ChildItem -Path $litertInclude -Filter '*.h' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\gpu\\' }
    Assert-Test -Name "LiteRT GPU delegate headers" -Condition { @($litertGpuHeaders).Count -gt 0 } -FailMessage "No GPU delegate headers found under $litertInclude"
}

if (Test-Path $litertLibDir) {
    $litertLibs = Get-ChildItem -Path $litertLibDir -Filter '*.lib' -ErrorAction SilentlyContinue
    Assert-Test -Name "LiteRT lib files" -Condition { $litertLibs.Count -gt 0 } -FailMessage "No LiteRT .lib files found"
}

if (Test-Path $litertBinDir) {
    # LiteRT builds statically by default (TFLITE_ENABLE_INSTALL=OFF, no
    # BUILD_SHARED_LIBS) — DLLs are optional; static .lib files above are the
    # real artifact. Report informationally instead of failing.
    $litertDlls = Get-ChildItem -Path $litertBinDir -Filter '*.dll' -ErrorAction SilentlyContinue
    if ($litertDlls.Count -gt 0) {
        Write-Host "  [PASS] LiteRT DLL files ($($litertDlls.Count) found)" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host '  [SKIP] LiteRT DLL files (static build - .lib only)' -ForegroundColor Yellow
        $script:skipped++
    }
}

# ============================================================================
Write-TestHeader '13. LiteRT-LM (on-device LLM inference, source-built)'
# ============================================================================
$litertLmRoot = 'C:\runtime\lib\litert-lm'
$litertLmInclude = Join-Path $litertLmRoot 'include'
$litertLmLibDir = Join-Path $litertLmRoot 'lib'

Assert-DirectoryExists -Path $litertLmRoot -Description 'LiteRT-LM root dir'

if (Test-Path $litertLmInclude) {
    $litertLmHeaders = Get-ChildItem -Path $litertLmInclude -Filter '*.h' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "LiteRT-LM headers" -Condition { $litertLmHeaders.Count -gt 0 } -FailMessage "No LiteRT-LM headers found"
}

if (Test-Path $litertLmLibDir) {
    $litertLmLibs = Get-ChildItem -Path $litertLmLibDir -Filter '*.lib' -ErrorAction SilentlyContinue
    Assert-Test -Name "LiteRT-LM lib files" -Condition { $litertLmLibs.Count -gt 0 } -FailMessage "No LiteRT-LM .lib files found"
    $litertLmDlls = Get-ChildItem -Path $litertLmLibDir -Filter '*.dll' -ErrorAction SilentlyContinue
    Assert-Test -Name "LiteRT-LM DLL files" -Condition { $litertLmDlls.Count -gt 0 } -FailMessage "No LiteRT-LM .dll files found"
}

# ============================================================================
Write-TestHeader '14. Compiler smoke test (clang-cl builds C++)'
# ============================================================================
$tmpDir = Join-Path $env:TEMP 'kataglyphis-smoke-test'
New-Item -Path $tmpDir -ItemType Directory -Force | Out-Null

$cppSource = @"
#include <iostream>
#include <vector>
#include <string>
int main() {
    std::vector<std::string> items = {"smoke", "test", "ok"};
    std::cout << items[0] << " " << items[1] << " " << items[2] << std::endl;
    return 0;
}
"@

$srcFile = Join-Path $tmpDir 'smoke.cpp'
$exeFile = Join-Path $tmpDir 'smoke.exe'
Set-Content -Path $srcFile -Value $cppSource -Encoding ASCII

Assert-Test -Name "clang-cl compiles C++ program" -Condition {
    & clang-cl $srcFile /Fe$exeFile /std:c++17 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
} -FailMessage "clang-cl failed to compile simple C++ program"

Assert-Test -Name "Compiled program runs" -Condition {
    $output = & $exeFile 2>&1 | Out-String
    return $output.Trim() -eq 'smoke test ok'
} -FailMessage "Compiled program produced wrong output"

Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================================
Write-TestHeader '15. CMake + Ninja + clang-cl integration'
# ============================================================================
$tmpDir2 = Join-Path $env:TEMP 'kataglyphis-smoke-cmake'
New-Item -Path $tmpDir2 -ItemType Directory -Force | Out-Null

$cmakeLists = @"
cmake_minimum_required(VERSION 3.20)
project(SmokeTest CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable(smoke_cmake smoke_cmake.cpp)
"@
$cppSource2 = @"
#include <iostream>
int main() { std::cout << "cmake+clangcl ok" << std::endl; return 0; }
"@

Set-Content -Path (Join-Path $tmpDir2 'CMakeLists.txt') -Value $cmakeLists -Encoding ASCII
Set-Content -Path (Join-Path $tmpDir2 'smoke_cmake.cpp') -Value $cppSource2 -Encoding ASCII

$buildDir2 = Join-Path $tmpDir2 'build'
Assert-Test -Name "CMake+Ninja+clang-cl configure" -Condition {
    & cmake -S $tmpDir2 -B $buildDir2 -G Ninja -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
} -FailMessage "CMake configure with Ninja+clang-cl failed"

Assert-Test -Name "CMake+Ninja+clang-cl build" -Condition {
    & cmake --build $buildDir2 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
} -FailMessage "CMake build with Ninja+clang-cl failed"

Remove-Item $tmpDir2 -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================================
Write-TestHeader '16. VS MSBuild + ClangCL toolset integration'
# ============================================================================
$tmpDir3 = Join-Path $env:TEMP 'kataglyphis-smoke-msbuild'
New-Item -Path $tmpDir3 -ItemType Directory -Force | Out-Null

# NB: single-quoted here-string — a double-quoted form makes PowerShell evaluate
# MSBuild's $(VCTargetsPath) as a subexpression. The template also needs the
# ProjectConfigurations item group + ConfigurationType, or VC targets reject it
# with MSB8013 (validated in-container: builds clean with ClangCL).
$vcxproj = @'
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup Label="ProjectConfigurations">
    <ProjectConfiguration Include="Release|x64">
      <Configuration>Release</Configuration>
      <Platform>x64</Platform>
    </ProjectConfiguration>
  </ItemGroup>
  <PropertyGroup Label="Globals">
    <ProjectGuid>{D497C90E-6D4C-4E96-9B21-000000000001}</ProjectGuid>
    <Keyword>Win32Proj</Keyword>
  </PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.Default.props" />
  <PropertyGroup>
    <ConfigurationType>Application</ConfigurationType>
    <PlatformToolset>ClangCL</PlatformToolset>
  </PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.props" />
  <ItemGroup>
    <ClCompile Include="smoke_msbuild.cpp" />
  </ItemGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.targets" />
</Project>
'@
$cppSource3 = @"
int main() { return 0; }
"@

Set-Content -Path (Join-Path $tmpDir3 'smoke_msbuild.vcxproj') -Value $vcxproj -Encoding ASCII
Set-Content -Path (Join-Path $tmpDir3 'smoke_msbuild.cpp') -Value $cppSource3 -Encoding ASCII

Assert-Test -Name "MSBuild+ClangCL builds" -Condition {
    & msbuild (Join-Path $tmpDir3 'smoke_msbuild.vcxproj') /p:Configuration=Release /p:Platform=x64 /nologo 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
} -FailMessage "MSBuild with ClangCL toolset failed"

Remove-Item $tmpDir3 -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================================
Write-TestHeader '17. TVM (source-built)'
# ============================================================================
$tvmRoot = Join-Path 'C:\runtime\lib' 'tvm'
if (Test-Path $tvmRoot) {
    Assert-DirectoryExists -Path $tvmRoot -Description "TVM install root ($tvmRoot)"
    $tvmInclude = Join-Path $tvmRoot 'include'
    if (Test-Path $tvmInclude) {
        # Layout-agnostic: TVM's runtime header names change across releases
        # (c_runtime_api.h was dropped by the new FFI in 0.25) — assert the
        # tvm/runtime header directory exists and is non-empty instead.
        $tvmHeaders = Get-ChildItem -Path (Join-Path $tvmInclude 'tvm\runtime') -Filter '*.h' -Recurse -ErrorAction SilentlyContinue
        Assert-Test -Name "TVM runtime headers (tvm/runtime/*.h)" -Condition { $tvmHeaders.Count -gt 0 } -FailMessage "No headers found under $tvmInclude\tvm\runtime"
    } else {
        Write-Host '  [SKIP] TVM include dir not found' -ForegroundColor Yellow
        $script:skipped++
    }
    $tvmLibs = Get-ChildItem -Path $tvmRoot -Filter 'tvm*.lib' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "TVM lib files" -Condition { $tvmLibs.Count -gt 0 } -FailMessage "No tvm*.lib found under $tvmRoot"
    $tvmDlls = Get-ChildItem -Path $tvmRoot -Filter 'tvm*.dll' -Recurse -ErrorAction SilentlyContinue
    Assert-Test -Name "TVM DLL files" -Condition { $tvmDlls.Count -gt 0 } -FailMessage "No tvm*.dll found under $tvmRoot"
} else {
    Write-Host '  [SKIP] TVM not installed (C:\runtime\lib\tvm not found)' -ForegroundColor Yellow
    $script:skipped++
}

# ============================================================================
Write-TestHeader '18. FFmpeg (source-built with DNN/ONNX)'
# ============================================================================
$ffmpegBin = 'C:\runtime\ffmpeg\bin'
if (Test-Path $ffmpegBin) {
    $ffmpegExe = Join-Path $ffmpegBin 'ffmpeg.exe'
    $ffprobeExe = Join-Path $ffmpegBin 'ffprobe.exe'
    Assert-FileExists -Path $ffmpegExe -Description 'ffmpeg.exe'
    Assert-FileExists -Path $ffprobeExe -Description 'ffprobe.exe'

    Assert-Test -Name "ffmpeg --version responds" -Condition {
        $v = & $ffmpegExe -version 2>&1 | Select-Object -First 1
        return ($v -ne $null) -and ($v -match 'ffmpeg')
    } -FailMessage "ffmpeg -version failed"

    # Verify ONNX-backed DNN support. NB: `-configure` is not an ffmpeg option
    # (the old checks grepped an error message); the configuration line is part
    # of the -version banner. `--enable-dnn` is not a real configure flag either
    # — DNN filters are enabled by enabling a backend (libonnxruntime).
    $ffCfg = & $ffmpegExe -version 2>&1 | Out-String
    Assert-Test -Name "ffmpeg built with --enable-libonnxruntime" -Condition {
        $ffCfg -match 'enable-libonnxruntime'
    } -FailMessage "ffmpeg was not configured with --enable-libonnxruntime"

    Assert-Test -Name "ffmpeg dnn_processing filter available" -Condition {
        $filters = & $ffmpegExe -hide_banner -filters 2>&1 | Out-String
        return ($filters -match 'dnn_')
    } -FailMessage "no dnn_* filters reported by ffmpeg -filters"
} else {
    Write-Host '  [SKIP] FFmpeg not installed (C:\runtime\ffmpeg\bin not found)' -ForegroundColor Yellow
    $script:skipped++
}

# ============================================================================
Write-TestHeader '== SUMMARY =='
# ============================================================================
$total = $script:passed + $script:failed
Write-Host "  Passed:  $($script:passed)" -ForegroundColor Green
Write-Host "  Failed:  $($script:failed)" -ForegroundColor Red
Write-Host "  Skipped: $($script:skipped)" -ForegroundColor Yellow
Write-Host "  Total:   $total" -ForegroundColor Cyan

if ($script:failed -gt 0) {
    Write-Host "`n--- FAILURE DETAILS ---" -ForegroundColor Red
    foreach ($detail in $script:failureDetails) {
        Write-Host "  $detail" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host "`nAll smoke tests passed!" -ForegroundColor Green
    exit 0
}
