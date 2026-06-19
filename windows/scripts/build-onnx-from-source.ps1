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

# Disable precompiled headers for CUDA provider (avoids CCCL header deps missing in CUDA 13.x)
$cudaPchCmake = Join-Path $SourceDir 'onnxruntime\core\providers\cuda\CMakeLists.txt'
if (Test-Path $cudaPchCmake) {
    $pchContent = [System.IO.File]::ReadAllText($cudaPchCmake)
    $pchContent = $pchContent -replace 'target_precompile_headers\([^)]+\)', ''
    [System.IO.File]::WriteAllText($cudaPchCmake, $pchContent)
    Write-Host "Patched CUDA provider CMakeLists: removed target_precompile_headers"
}

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

# Full SIMD flags for maximum inference performance.
# NOTE: clang-cl needs ~48 GB RAM to compile template-heavy ONNX Runtime files
# (element_wise_ops.cc, cast_op.cc) with AVX-512+AMX enabled. Use:
#   docker build --memory 48g --cpus 32 ...
$cxxFlags = '/WX- /clang:-mavx2 /clang:-mavx /clang:-mfma /clang:-msse4.2 /clang:-mf16c /clang:-mwaitpkg /clang:-maes /clang:-mpclmul /clang:-mavx512f /clang:-mavx512cd /clang:-mavx512bw /clang:-mavx512dq /clang:-mavx512vl /clang:-mavx512vnni /clang:-mavx512bf16 /clang:-mavx512fp16 /clang:-mavxvnni /clang:-mamx-int8 /clang:-mamx-tile /clang:-mamx-bf16'

# Detect CUDA and cuDNN paths for ONNX Runtime CUDA build
$cudnnIncludeDir = ''
$cudnnLibPath = ''
$cudnnLibDir = ''

$cudaRoot = if ($env:CUDA_ROOT) { $env:CUDA_ROOT } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { $null }

# CUDA 13.x CCCL missing headers workaround
# setup-cuda.ps1 already creates nv/target.h and crt/* stubs; do NOT patch cuda_fp16.h
# as that would break FP16 support (the nv/target.h stub satisfies the include)
if ($cudaRoot -and (Test-Path $cudaRoot)) {
    $cudaInclude = Join-Path $cudaRoot 'include'

    # Verify nv/target.h and crt/ stubs exist (created by setup-cuda.ps1)
    $nvTargetH = Join-Path $cudaInclude 'nv\target.h'
    $crtDir = Join-Path $cudaInclude 'crt'
    if (-not (Test-Path $nvTargetH)) {
        Write-Host "WARNING: nv/target.h stub not found at $nvTargetH"
    }
    if (-not (Test-Path $crtDir)) {
        Write-Host "WARNING: crt/ directory not found at $crtDir"
    }

    # Also detect cuDNN for CUDA provider
    $cudnnRoot = if ($env:CUDNN_ROOT) { $env:CUDNN_ROOT } else { $null }
    if ($cudnnRoot -and (Test-Path $cudnnRoot)) {
        $cudnnIncludeDir = Join-Path $cudnnRoot 'include'
        $cudnnLibDir = Join-Path $cudnnRoot 'lib\x64'
        $cudnnLibFiles = Get-ChildItem -Path $cudnnLibDir -Filter 'cudnn*.lib' -ErrorAction SilentlyContinue
        if ($cudnnLibFiles) { $cudnnLibPath = $cudnnLibFiles[0].FullName }
    }
}

# Load VsDevCmd for MSVC tools (cl.exe, link.exe, etc.) needed by
# clang-cl for runtime library resolution and assembly files
$vsDevCmd = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat"
Write-Host 'Loading VsDevCmd environment...'
cmd.exe /c """$vsDevCmd"" -arch=amd64 -host_arch=amd64 && set" | ForEach-Object {
    if ($_ -match '^(.*?)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue }
}

# Ensure CUDA and cuDNN are on PATH for ONNX Runtime cmake (VsDevCmd may strip these)
if ($cudaRoot) {
    $env:CUDA_PATH = $cudaRoot
    $env:CUDA_ROOT = $cudaRoot
    $env:CUDA_HOME = $cudaRoot
    $cudaBin = Join-Path $cudaRoot 'bin'
    if ((Test-Path $cudaBin) -and ($env:PATH -notlike "*$cudaBin*")) {
        $env:PATH = "$cudaBin;$env:PATH"
        Write-Host "Added $cudaBin to PATH"
    }
}
if ($cudnnRoot) {
    $env:CUDNN_ROOT = $cudnnRoot
    $cudnnBin = Join-Path $cudnnRoot 'bin'
    if ((Test-Path $cudnnBin) -and ($env:PATH -notlike "*$cudnnBin*")) {
        $env:PATH = "$cudnnBin;$env:PATH"
        Write-Host "Added $cudnnBin to PATH"
    }
}
if ($cudnnLibDir) {
    $env:CMAKE_LIBRARY_PATH = $cudnnLibDir
}

Write-Host 'Building with Ninja+clang-cl'

if ($cudaRoot) {
    $cudaBin = Join-Path $cudaRoot 'bin'
    $env:PATH = "$cudaBin;$env:PATH"
}

# ONNX Runtime CUDA: enabled via Scoop CUDA toolkit (full local installer extracted)
# NVCC requires MSVC (cl.exe) as host compiler on Windows — cannot use clang-cl.
# We set CMAKE_CUDA_COMPILER to provide nvcc path and CMAKE_CUDA_HOST_COMPILER to cl.exe.
# Constructed AFTER VsDevCmd so cl.exe is resolvable on PATH.
$cudaArgs = @()
if ($cudaRoot -and (Test-Path $cudaRoot)) {
    $cudaArgs += '-Donnxruntime_USE_CUDA=ON'
    $cudaArgs += '-Donnxruntime_USE_TENSORRT=OFF'
    # Set CMAKE_CUDA_COMPILER to bypass ONNX Runtime's setup_cuda_compiler find_program
    $cudaArgs += "-DCMAKE_CUDA_COMPILER:FILEPATH=$(Join-Path $cudaRoot 'bin\nvcc.exe')"
    # nvcc needs MSVC cl.exe as host compiler (cannot use clang-cl for host code)
    $clExePath = (Get-Command cl.exe -ErrorAction SilentlyContinue).Source
    if (-not $clExePath) {
        Write-Host "WARNING: cl.exe not found on PATH; CUDA host compilation may fail"
    } else {
        Write-Host "CUDA host compiler: $clExePath"
        $cudaArgs += "-DCMAKE_CUDA_HOST_COMPILER:FILEPATH=$clExePath"
    }
    $cudaArgs += "-DCMAKE_PROGRAM_PATH=$(Join-Path $cudaRoot 'bin')"
    $cudaArgs += "-DCUDA_TOOLKIT_ROOT_DIR=$cudaRoot"
    $cudaArgs += "-DCUDA_CUDA_DLL_ROOT_DIR=$(Join-Path $cudaRoot 'bin')"
    $cudaArgs += "-DCUDA_NVCC_EXECUTABLE=$(Join-Path $cudaRoot 'bin\nvcc.exe')"
    $cudaArgs += "-DCMAKE_CUDA_ARCHITECTURES=80-real;86-real;89-real;90-real"
    if ($cudnnRoot -and (Test-Path $cudnnRoot)) {
        $cudaArgs += "-DCUDNN_ROOT=$cudnnRoot"
        $cudaArgs += "-DCUDNN_INCLUDE_DIR=$cudnnIncludeDir"
        $cudaArgs += "-DCMAKE_LIBRARY_PATH=$cudnnLibDir"
        $cudaArgs += "-DCUDNN_LIBRARY=$cudnnLibPath"
    }
} else {
    $cudaArgs += '-Donnxruntime_USE_CUDA=OFF'
}

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
    "-DCMAKE_CXX_FLAGS:STRING=$cxxFlags"
) + $cudaArgs

$ok = Invoke-CmakeConfigure -SourceDir $cmakeSrc -BuildDir $buildDir -InstallPrefix $ortInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'CMake configure failed' }

# Patch CUTLASS uint128.h after CMake fetch: clang-cl doesn't support MSVC _udiv128 intrinsic
$cutlassUint128 = Join-Path $SourceDir 'build\_deps\cutlass-src\include\cutlass\uint128.h'
if (Test-Path $cutlassUint128) {
    $content = [System.IO.File]::ReadAllText($cutlassUint128)
    $content = $content -replace '_udiv128', 'udiv128'
    [System.IO.File]::WriteAllText($cutlassUint128, $content)
    Write-Host 'Patched cutlass/uint128.h: _udiv128 -> udiv128'
}

# Patch softmax.cc: clang-cl in MSVC mode doesn't recognize C++ alternative tokens
# ("or", "and", "not") as keywords even in C++20 mode.
$softmaxFiles = @(
    "$SourceDir\onnxruntime\core\providers\cuda\math\softmax.cc",
    "$SourceDir\onnxruntime\core\providers\cuda\math\softmax.h"
)
foreach ($sf in $softmaxFiles) {
    if (Test-Path $sf) {
        $content = [System.IO.File]::ReadAllText($sf)
        $content = $content -replace '\bor\b', '||'
        $content = $content -replace '\band\b', '&&'
        $content = $content -replace '\bnot\b', '!'
        [System.IO.File]::WriteAllText($sf, $content)
        Write-Host "Patched alternative tokens in: $sf"
    }
}

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
if ($LASTEXITCODE -ne 0) {
    Write-Host "cmake --install failed (exit $LASTEXITCODE) - checking if artifacts exist"
    $dlls = @(Get-ChildItem -Path $buildDir -Filter 'onnxruntime*.dll' -Recurse -ErrorAction SilentlyContinue)
    $libs = @(Get-ChildItem -Path $buildDir -Filter 'onnxruntime*.lib' -Recurse -ErrorAction SilentlyContinue)
    if ($dlls.Count -gt 0) {
        Write-Host "Found $($dlls.Count) DLLs and $($libs.Count) LIBs - copying manually"
        New-Item -Path "$ortInstallDir\lib" -ItemType Directory -Force | Out-Null
        New-Item -Path "$ortInstallDir\bin" -ItemType Directory -Force | Out-Null
        $dlls | Copy-Item -Destination "$ortInstallDir\bin" -Force -ErrorAction SilentlyContinue
        $libs | Copy-Item -Destination "$ortInstallDir\lib" -Force -ErrorAction SilentlyContinue
        # Copy headers
        $srcInclude = Join-Path $SourceDir 'include'
        if (Test-Path $srcInclude) { Copy-Item -Path $srcInclude -Destination "$ortInstallDir\" -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "Manual installation completed - $($dlls.Count) DLLs copied"
    } else {
        throw 'cmake --install failed and no DLLs found'
    }
}

Write-Host '=== ONNX Runtime source build completed ==='
