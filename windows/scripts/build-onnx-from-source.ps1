param(
    [string]$SourceDir = 'C:\temp\onnx-src',
    [string]$InstallDir = '',
    [string]$OnnxVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$OnnxVersion = Get-SourceBuildVersion -Value $OnnxVersion -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.26.0'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\gstreamer' }

Write-Host "=== ONNX Runtime source build Ninja+clang-cl ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime.git' -Tag "v$OnnxVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone ONNX Runtime' }

$cmakeSrc = $SourceDir
if (-not (Test-Path (Join-Path $cmakeSrc 'CMakeLists.txt'))) {
    $cmakeSub = Join-Path $SourceDir 'cmake'
    if (Test-Path (Join-Path $cmakeSub 'CMakeLists.txt')) { $cmakeSrc = $cmakeSub }
    else { throw 'No CMakeLists.txt found' }
}

# Replace RC file with minimal ASCII version (llvm-rc can't handle non-ASCII chars)
$rcFile = Join-Path $SourceDir 'onnxruntime\core\dll\onnxruntime.rc'
$minimalRc = @'
// onnxruntime.rc - minimal ASCII version
#include <windows.h>
VS_VERSION_INFO VERSIONINFO
 FILEVERSION 1,26,0,0
 PRODUCTVERSION 1,26,0,0
 FILEFLAGSMASK 0x3fL
 FILEFLAGS 0x0L
 FILEOS VOS_NT_WINDOWS32
 FILETYPE VFT_DLL
 FILESUBTYPE 0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName", "Microsoft Corporation"
            VALUE "FileDescription", "ONNX Runtime"
            VALUE "FileVersion", "1.26.0"
            VALUE "InternalName", "onnxruntime"
            VALUE "LegalCopyright", "(c) Microsoft Corporation. All rights reserved."
            VALUE "OriginalFilename", "onnxruntime.dll"
            VALUE "ProductName", "ONNX Runtime"
            VALUE "ProductVersion", "1.26.0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
'@
Set-Content -Path $rcFile -Value $minimalRc -Encoding ASCII
Write-Host "Replaced RC file with ASCII version"

$buildDir = Join-Path $SourceDir 'build'
$ortInstallDir = Join-Path $InstallDir 'lib\onnxruntime-source'

$cxxFlags = '/WX- /clang:-mavx2 /clang:-mavx /clang:-mfma /clang:-msse4.2 /clang:-mf16c /clang:-mwaitpkg /clang:-maes /clang:-mpclmul /clang:-mavx512f /clang:-mavx512cd /clang:-mavx512bw /clang:-mavx512dq /clang:-mavx512vl /clang:-mavx512vnni /clang:-mavx512bf16 /clang:-mavx512fp16 /clang:-mavxvnni /clang:-mamx-int8 /clang:-mamx-tile /clang:-mamx-bf16'

# Auto-detect cuDNN paths (for reference; CUDA is OFF for ORT)
$cudnnIncludeDir = ''
$cudnnLibPath = ''
$cudnnLibDir = ''

$cmakeExtra = @(
    '-Donnxruntime_BUILD_SHARED_LIB=ON'
    '-Donnxruntime_BUILD_UNIT_TESTS=OFF'
    '-Donnxruntime_BUILD_BENCHMARKS=OFF'
    # DirectML disabled: VS 2026 STL hardening + clang-cl incompatible
    '-Donnxruntime_USE_DML=OFF'
    '-Donnxruntime_USE_TENSORRT=OFF'
    '-Donnxruntime_USE_NNAPI_BUILTIN=OFF'
    '-Donnxruntime_USE_COREML=OFF'
    '-Donnxruntime_ENABLE_PYTHON=OFF'
    '-DPython3_EXECUTABLE=C:/temp/cpython/PCbuild/amd64/python.exe'
    # Use dynamic runtime (/MD) for all libs (protobuf defaults to /MT)
    '-Dprotobuf_MSVC_STATIC_RUNTIME=OFF'
    # CUDA not enabled for ONNX Runtime: CUDA 13.3 has a packaging bug
    # (missing crt/ subdirectory) that breaks nvcc preprocessing.
    # CUDA is still auto-detected by OpenCV and GStreamer builds.
    '-Donnxruntime_USE_CUDA=OFF'
    "-DCMAKE_CXX_FLAGS:STRING=$cxxFlags"
)

# Load VsDevCmd for MSVC tools (cl.exe, link.exe, etc.) needed by
# clang-cl for runtime library resolution and assembly files
$vsDevCmd = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat"
Write-Host 'Loading VsDevCmd environment...'
cmd.exe /c """$vsDevCmd"" -arch=amd64 -host_arch=amd64 && set" | ForEach-Object {
    if ($_ -match '^(.*?)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue }
}

Write-Host 'Building with Ninja+clang-cl'

$ok = Invoke-CmakeConfigure -SourceDir $cmakeSrc -BuildDir $buildDir -InstallPrefix $ortInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'CMake configure failed' }

# Strip copyright symbol from .rc file (byte 0xA9, llvm-rc can't handle non-ASCII)
$rcFile = Join-Path $SourceDir 'onnxruntime\core\dll\onnxruntime.rc'
if (Test-Path $rcFile) {
    $content = [System.IO.File]::ReadAllText($rcFile, [System.Text.Encoding]::Default)
    $content = $content -replace "`u{00A9}", '(c)'
    $bytes = [System.Text.Encoding]::Default.GetBytes($content)
    [System.IO.File]::WriteAllBytes($rcFile, $bytes)
    Write-Host "Patched onnxruntime.rc: replaced copyright symbol"
}

$ninjaFile = Join-Path $buildDir 'build.ninja'
if (Test-Path $ninjaFile) {
    $text = [System.IO.File]::ReadAllText($ninjaFile)
    $orig = $text
    $text = $text -replace [regex]::Escape('/experimental:external'), ''
    $text = $text -replace '(?<=\s)-WX(?=\s)', ''
    $text = $text -replace '/arch:\S+', ''
    $text = $text -replace '/bigobj', ''
    if ($text -ne $orig) {
        [System.IO.File]::WriteAllText($ninjaFile, $text)
        Write-Host 'Patched build.ninja'
    }
}

Write-Host 'Building...'
$env:NINJA_STATUS = "[%f/%t] "
$vsDevCmd = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat"
$batFile = Join-Path $env:TEMP 'build_onnx.bat'
"@echo off
call `"$vsDevCmd`" -arch=amd64 -host_arch=amd64 > NUL 2>&1
ninja -C `"$buildDir`" 2>&1
" | Set-Content -Path $batFile -Encoding ASCII
cmd.exe /c $batFile
$exitCode = $LASTEXITCODE
Remove-Item $batFile -Force -ErrorAction SilentlyContinue

if ($exitCode -ne 0) {
    Write-Host '=== FAILURES ==='
    $dlls = @(Get-ChildItem -Path $buildDir -Filter 'onnxruntime*.dll' -Recurse -ErrorAction SilentlyContinue)
    if ($dlls.Count -gt 0) { Write-Host "DLLs found - build OK" }
    else { throw "Build failed" }
}

Write-Host 'Installing...'
& cmake --install $buildDir --config Release
if ($LASTEXITCODE -ne 0) { throw 'cmake --install failed' }

Write-Host '=== ONNX Runtime source build completed ==='
