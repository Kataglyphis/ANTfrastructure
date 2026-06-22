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

Write-Host 'Setting up git-lfs...'
& git lfs install --skip-repo 2>&1 | Out-Null
Push-Location $SourceDir
& git lfs pull 2>&1 | Out-Null
Pop-Location

# Environment: vcpkg, Rust, PATH
$vcpkgRoot = 'C:\vcpkg\installed\x64-windows'
$vcpkgDir = 'C:\vcpkg'
$env:CMAKE_PREFIX_PATH = "$vcpkgRoot;$env:CMAKE_PREFIX_PATH"

$protobufTools = 'C:\vcpkg\installed\x64-windows\tools\protobuf'
if (Test-Path $protobufTools) { $env:PATH = "$protobufTools;$env:PATH" }

$rustDir = 'C:\Users\ContainerAdministrator\scoop\apps\rust\current\bin'
$env:PATH = "$rustDir;$env:USERPROFILE\.cargo\bin;$env:PATH"
$env:CARGO_HOME = "$env:USERPROFILE\.cargo"

# Patch runtime/proto/CMakeLists.txt BEFORE cmake configure to skip protobuf_generate
$runtimeProtoCmake = Join-Path $SourceDir 'runtime\proto\CMakeLists.txt'
if (Test-Path $runtimeProtoCmake) {
    $content = [System.IO.File]::ReadAllText($runtimeProtoCmake)
    $content = $content -replace 'protobuf_generate\([^)]*\)', '# protobuf_generate disabled (vcpkg)'
    $content = $content -replace 'find_package\(Protobuf', 'find_package(Protobuf QUIET'
    [System.IO.File]::WriteAllText($runtimeProtoCmake, $content)
    Write-Host 'Patched runtime/proto/CMakeLists.txt before configure'
}

$buildDir = Join-Path $SourceDir 'build_ninja'

$litertInstallDir = Join-Path $InstallDir 'lib\litert'
$litertCmakeDir = Join-Path $litertInstallDir 'cmake'
if (-not (Test-Path $litertCmakeDir)) {
    $litertCmakeDir = Join-Path $litertInstallDir 'lib\cmake\LiteRT'
}
$litertIncludeDir = Join-Path $litertInstallDir 'include'

$cudaRoot = if ($env:CUDA_ROOT) { $env:CUDA_ROOT } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { $null }

$cmakeExtra = @(
    '-DCMAKE_CXX_FLAGS:STRING=/EHs-c- /D_HAS_EXCEPTIONS=0'
    "-DCMAKE_PREFIX_PATH=$litertInstallDir;$litertCmakeDir"
    "-DLiteRT_INCLUDE_DIR=$litertIncludeDir"
    '-DTFLITE_ENABLE_GPU=ON'
)

if ($cudaRoot -and (Test-Path $cudaRoot)) {
    $cmakeExtra += '-DUSE_CUDA=ON'
    $cmakeExtra += "-DCUDA_TOOLKIT_ROOT_DIR=$cudaRoot"
}

if (Test-Path $litertCmakeDir) {
    $cmakeExtra += "-DLiteRT_DIR=$litertCmakeDir"
}

$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $litertLmInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'LiteRT-LM CMake configure failed' }

# After configure, generate proto files and place protoc where ninja expects it
$vcpkgProtoc = Join-Path $vcpkgDir 'installed\x64-windows\tools\protobuf\protoc.exe'
$protoDir = Join-Path $SourceDir 'runtime\proto'
$protoOutDir = Join-Path $SourceDir 'build_ninja\litert_lm\build\runtime\proto'
New-Item -Path $protoOutDir -ItemType Directory -Force | Out-Null

if ((Test-Path $vcpkgProtoc) -and (Test-Path $protoDir)) {
    Get-ChildItem -Path $protoDir -Filter '*.proto' | ForEach-Object {
        & $vcpkgProtoc --proto_path="$SourceDir" --cpp_out="$protoOutDir" $_.FullName 2>&1
    }
    Write-Host "Generated proto files from $protoDir"
}

# Place protoc at the location ExternalProject expects (so ninja is satisfied)
$protoInstallBin = Join-Path $SourceDir 'build_ninja\prebuild\build\external\protobuf\install\bin'
New-Item -Path $protoInstallBin -ItemType Directory -Force | Out-Null
Copy-Item $vcpkgProtoc (Join-Path $protoInstallBin 'protoc.exe') -Force
Write-Host "Placed protoc.exe at $protoInstallBin"

# Also copy proto include files
$vcpkgInclude = Join-Path $vcpkgDir 'installed\x64-windows\include'
$protoInstallInclude = Join-Path $SourceDir 'build_ninja\prebuild\build\external\protobuf\install\include'
New-Item -Path $protoInstallInclude -ItemType Directory -Force | Out-Null
Copy-Item "$vcpkgInclude\*" $protoInstallInclude -Recurse -Force -ErrorAction SilentlyContinue

$buildLog = Join-Path $buildDir 'litert-lm-build.log'
$ok = Invoke-CmakeBuild -BuildDir $buildDir -Config Release -Install -LogFile $buildLog
if (-not $ok) { throw 'LiteRT-LM build failed' }

Write-Host '=== LiteRT-LM source build completed ==='
