param(
    [string]$SourceDir = 'C:\temp\onnx-src',
    [string]$InstallDir = '',
    [string]$OnnxVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$OnnxVersion = Get-SourceBuildVersion -Value $OnnxVersion -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.27.0'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\gstreamer' }

Write-Host "=== ONNX Runtime source build (Ninja + clang-cl + GPU: $(if ($env:GPU_TYPE) { $env:GPU_TYPE } else { 'none' })) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/microsoft/onnxruntime.git' -Tag "v$OnnxVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone ONNX Runtime' }

$cmakeSrc = if (Test-Path "$SourceDir\cmake\CMakeLists.txt") { "$SourceDir\cmake" } else { $SourceDir }
$buildDir = "$SourceDir\build"
$ortInstallDir = "$InstallDir\lib\onnxruntime-source"

# llvm-rc can't handle non-ASCII
$bytes = [System.IO.File]::ReadAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc")
[System.IO.File]::WriteAllBytes("$SourceDir\onnxruntime\core\dll\onnxruntime.rc", [byte[]]@($bytes | Where-Object { $_ -le 127 }))

# VsDevCmd: ml64 for .asm + cl.exe for nvcc host compiler
cmd /c """C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat"" -arch=amd64 -host_arch=amd64 && set" | ForEach-Object {
    if ($_ -match '^(.*?)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] }
}

if ((Test-Path 'C:\temp\cpython\PC\pyconfig.h') -and -not (Test-Path 'C:\temp\cpython\Include\pyconfig.h')) { Copy-Item 'C:\temp\cpython\PC\pyconfig.h' 'C:\temp\cpython\Include\pyconfig.h' }

$sccache = (Get-Command sccache.exe -ErrorAction Stop).Source; $env:SCCACHE_MAX_JOBS = '8'

$cxxFlags = '/WX- /clang:-mavx2 /clang:-mavx /clang:-mfma /clang:-msse4.2 /clang:-mf16c /clang:-mwaitpkg /clang:-maes /clang:-mpclmul /clang:-mavx512f /clang:-mavx512cd /clang:-mavx512bw /clang:-mavx512dq /clang:-mavx512vl /clang:-mavx512vnni /clang:-mavx512bf16 /clang:-mavx512fp16 /clang:-mavxvnni /clang:-mamx-int8 /clang:-mamx-tile /clang:-mamx-bf16 /clang:-Wno-invalid-specialization'

# ── GPU detection ──
$gpuArgs = @()
if ($env:GPU_TYPE -eq 'nvidia' -and $env:CUDA_ROOT) {
    Write-Host 'NVIDIA GPU detected: enabling CUDA + cuDNN'
    $cudaRoot = $env:CUDA_ROOT; $cudnnRoot = $env:CUDNN_ROOT
    $cudnnLib = if ($cudnnRoot) { (Get-ChildItem "$cudnnRoot\lib\x64\cudnn*.lib" -ErrorAction SilentlyContinue)[0].FullName }
    $env:PATH = "$cudaRoot\bin;$env:PATH"

    # CUDA PCH broken with CUDA 13.x CCCL
    $pch = "$SourceDir\onnxruntime\core\providers\cuda\CMakeLists.txt"
    if (Test-Path $pch) { [System.IO.File]::WriteAllText($pch, ([System.IO.File]::ReadAllText($pch) -replace 'target_precompile_headers\([^)]+\)', '')) }
    # clang-cl can't do and/or/not keywords
    foreach ($f in @("$SourceDir\onnxruntime\core\providers\cuda\math\softmax.cc", "$SourceDir\onnxruntime\core\providers\cuda\math\softmax.h")) {
        if (Test-Path $f) { [System.IO.File]::WriteAllText($f, ([System.IO.File]::ReadAllText($f) -replace '\bor\b', '||' -replace '\band\b', '&&' -replace '\bnot\b', '!')) }
    }

    $gpuArgs += '-Donnxruntime_USE_CUDA=ON', '-Donnxruntime_USE_TENSORRT=OFF'
    $gpuArgs += "-DCMAKE_CUDA_COMPILER:FILEPATH=$cudaRoot\bin\nvcc.exe"
    $gpuArgs += "-DCMAKE_CUDA_HOST_COMPILER:FILEPATH=$((Get-Command cl.exe -ErrorAction Stop).Source)"
    $gpuArgs += '-DCMAKE_CUDA_STANDARD:STRING=17'
    $gpuArgs += "-DCMAKE_CUDA_FLAGS:STRING=-Xcompiler=/wd4067 -Xcompiler=/Zc:preprocessor --compiler-options /Zc:preprocessor -DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING"
    $gpuArgs += '-DCMAKE_CUDA_ARCHITECTURES=80-real;86-real;89-real;90-real'
    $gpuArgs += "-DCUDNN_ROOT=$cudnnRoot", "-DCUDNN_INCLUDE_DIR=$cudnnRoot\include"
    $gpuArgs += "-DCMAKE_LIBRARY_PATH=$cudnnRoot\lib\x64", "-DCUDNN_LIBRARY=$cudnnLib"
    $gpuArgs += "-Donnxruntime_CUDNN_HOME=$cudnnRoot", "-Donnxruntime_CUDA_HOME=$cudaRoot"
} elseif ($env:GPU_TYPE -eq 'amd' -and $env:ROCM_ROOT) {
    Write-Host 'AMD GPU detected: enabling ROCm'
    $gpuArgs += '-Donnxruntime_USE_ROCM=ON'
} else {
    Write-Host 'No GPU layer detected: CPU-only build'
}

$cmakeArgs = @(
    '-Donnxruntime_BUILD_SHARED_LIB=ON', '-Donnxruntime_BUILD_UNIT_TESTS=OFF', '-Donnxruntime_BUILD_BENCHMARKS=OFF'
    '-Donnxruntime_USE_DML=OFF', '-Donnxruntime_ENABLE_PYTHON=OFF', '-Dprotobuf_MSVC_STATIC_RUNTIME=OFF'
    "-DCMAKE_CXX_FLAGS:STRING=$cxxFlags"
    "-DCMAKE_C_COMPILER_LAUNCHER:FILEPATH=$sccache"
    "-DCMAKE_CXX_COMPILER_LAUNCHER:FILEPATH=$sccache"
) + $gpuArgs
$ok = Invoke-CmakeConfigure -SourceDir $cmakeSrc -BuildDir $buildDir -InstallPrefix $ortInstallDir -ExtraArgs $cmakeArgs
if (-not $ok) { throw 'CMake configure failed' }

# ── Post-configure patches (NVIDIA CUDA + CUTLASS) ──
if ($env:GPU_TYPE -eq 'nvidia') {
    # CUTLASS headers: clang-cl can't handle `not`/`and`/`or` keywords
    $cutlassInclude = "$buildDir\_deps\cutlass-src\include"
    if (Test-Path $cutlassInclude) {
        Get-ChildItem $cutlassInclude -Recurse -Filter '*.hpp' | ForEach-Object {
            $c = [System.IO.File]::ReadAllText($_.FullName)
            $c2 = $c -replace '\bnot\b', '!' -replace '\band\b', '&&' -replace '\bor\b', '||'
            if ($c -ne $c2) { [System.IO.File]::WriteAllText($_.FullName, $c2) }
        }
    }
    # CUTLASS uint128: clang-cl lacks _udiv128
    $cut = "$buildDir\_deps\cutlass-src\include\cutlass\uint128.h"
    if (Test-Path $cut) { [System.IO.File]::WriteAllText($cut, ([System.IO.File]::ReadAllText($cut) -replace '_udiv128', 'udiv128')) }
    # CUTLASS cute/array_subbyte: suppressed via -Wno-invalid-specialization above
}

# Strip MSVC-only flags from build.ninja
$ninja = "$buildDir\build.ninja"
$t = [System.IO.File]::ReadAllText($ninja)
$t = $t -replace '--compiler-options /experimental:external\s*', ''
$t = $t -replace '(?<=\s)/experimental:external(?=\s)', '' -replace '(?<=\s)-WX(?=\s)', ''
$t = $t -replace '/arch:\S+', '' -replace '/bigobj', '' -replace '  +', ' '
[System.IO.File]::WriteAllText($ninja, $t)

$env:NINJA_STATUS = "[%f/%t] "
ninja -C $buildDir 2>&1; if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)" }
cmake --install $buildDir --config Release; if ($LASTEXITCODE -ne 0) { throw "Install failed" }
Write-Host '=== ONNX Runtime source build completed ==='
