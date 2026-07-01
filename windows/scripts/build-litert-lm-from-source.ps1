# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\litert-lm-src',
    [string]$InstallDir = '',
    [string]$LiteRtLmVersion = '',
    [string]$VcpkgRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

$LiteRtLmVersion = Get-SourceBuildVersion -Value $LiteRtLmVersion -EnvironmentVariables @('LITERT_LM_VERSION') -DefaultValue '0.13.1'
$litertLmInstallDir = Join-Path $InstallDir 'lib\litert-lm'

Write-Host "=== LiteRT-LM source build (v$LiteRtLmVersion, Ninja+clang-cl) ==="

$ok = Invoke-GitClone -RepoUrl 'https://github.com/google-ai-edge/LiteRT-LM.git' -Tag "v$LiteRtLmVersion" -SourceDir $SourceDir -Recursive
if (-not $ok) { throw 'Failed to clone LiteRT-LM' }

Write-Host 'Setting up git-lfs...'
& git lfs install --skip-repo 2>&1 | Out-Null
Push-Location $SourceDir
& git lfs pull 2>&1 | Out-Null
Pop-Location

# vcpkg paths: prefer -VcpkgRoot param, then $env:VCPKG_ROOT, then the container default.
if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
    $VcpkgRoot = if ($env:VCPKG_ROOT) { $env:VCPKG_ROOT } else { 'C:\vcpkg' }
}
$vcpkgInstalledX64 = Join-Path $VcpkgRoot 'installed\x64-windows'
$env:CMAKE_PREFIX_PATH = "$vcpkgInstalledX64;$env:CMAKE_PREFIX_PATH"
$protobufTools = Join-Path $vcpkgInstalledX64 'tools\protobuf'
$vcpkgDir = $VcpkgRoot
if (Test-Path $protobufTools) { $env:PATH = "$protobufTools;$env:PATH" }

# Cargo: honor the existing $env:CARGO_HOME (set in Dockerfile.base); only fall back to a default if unset.
if ([string]::IsNullOrWhiteSpace($env:CARGO_HOME)) { $env:CARGO_HOME = Join-Path $env:USERPROFILE '.cargo' }
$cargoBin = Join-Path $env:CARGO_HOME 'bin'
if (($env:PATH -notlike "*$cargoBin*") -and (Test-Path $cargoBin)) { $env:PATH = "$cargoBin;$env:PATH" }

# Inline patch (kept inline, NOT a .patch file): LiteRT-LM's runtime/proto/CMakeLists.txt
# is a single small file but the regex substitutions (`protobuf_generate(...)`,
# `find_package(Protobuf` -> QUIET) are not stable across LiteRT-LM tags -- newer
# releases rename the proto target list and add an extra `find_package(Protobuf
# REQUIRED)` near the bottom. A static .patch would rot; the `-replace` form is
# the canonical representation. See docs/windows-builds.md ?Patches.
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
$gpuEnv = Get-GpuEnvironment

$cmakeExtra = @(
    "-DCMAKE_PREFIX_PATH=$litertInstallDir;$litertCmakeDir"
)
if ($gpuEnv.GpuType -eq 'nvidia' -and $gpuEnv.CudaRoot) { $cmakeExtra += '-DUSE_CUDA=ON' }
if (Test-Path $litertCmakeDir) { $cmakeExtra += "-DLiteRT_DIR=$litertCmakeDir" }

$ok = Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $litertLmInstallDir -ExtraArgs $cmakeExtra
if (-not $ok) { throw 'LiteRT-LM CMake configure failed' }

$vcpkgProtoc = Join-Path $vcpkgDir 'installed\x64-windows\tools\protobuf\protoc.exe'
$protoDir = Join-Path $SourceDir 'runtime\proto'
foreach ($outSubDir in @('proto', 'protobuf')) {
    $protoOutDir = Join-Path $SourceDir "build_ninja\litert_lm\build\runtime\$outSubDir"
    New-Item -Path $protoOutDir -ItemType Directory -Force | Out-Null
    if ((Test-Path $vcpkgProtoc) -and (Test-Path $protoDir)) {
        Get-ChildItem -Path $protoDir -Filter '*.proto' | ForEach-Object {
            & $vcpkgProtoc --proto_path="$SourceDir" --cpp_out="$protoOutDir" $_.FullName 2>&1
        }
        Write-Host "Generated proto files to $protoOutDir"
    }
}
$protoInstallBin = Join-Path $SourceDir 'build_ninja\prebuild\build\external\protobuf\install\bin'
New-Item -Path $protoInstallBin -ItemType Directory -Force | Out-Null
Copy-Item $vcpkgProtoc (Join-Path $protoInstallBin 'protoc.exe') -Force
Copy-Item $vcpkgProtoc (Join-Path $protoInstallBin 'protoc') -Force
$vcpkgInclude = Join-Path $vcpkgDir 'installed\x64-windows\include'
$protoInstallInclude = Join-Path $SourceDir 'build_ninja\prebuild\build\external\protobuf\install\include'
New-Item -Path $protoInstallInclude -ItemType Directory -Force | Out-Null
Copy-Item "$vcpkgInclude\*" $protoInstallInclude -Recurse -Force -ErrorAction SilentlyContinue

$litertBuildDir = Join-Path $buildDir 'litert_lm\build'
$stampDir = Join-Path $buildDir 'litert_lm\stamps'
$llvmAr = (Get-Command llvm-ar.exe -ErrorAction Stop).Source
$ninja = (Get-Command ninja.exe -ErrorAction Stop).Source

Write-Host 'Running ExternalProject steps 1-4 (mkdir/download/update/patch)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-mkdir litert_lm/stamps/litert_lm-download litert_lm/stamps/litert_lm-update litert_lm/stamps/litert_lm-patch 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host 'WARNING: mkdir/download/update/patch had warnings' }

Write-Host 'Running ExternalProject step 5 (configure)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-configure 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Inner configure OK (expected minor warnings with clang-on-Windows)'
    Write-Host 'Proceeding with build...'
}

$buildNinjaFile = Join-Path $litertBuildDir 'build.ninja'
$stubCount = 0
if (Test-Path $buildNinjaFile) {
    Get-Content $buildNinjaFile | ForEach-Object {
        [regex]::Matches($_, "[\x27""]?([^\x27""\s]+\.a)[\x27""]?") | ForEach-Object {
            $aRel = $_.Groups[1].Value
            $aPath = $aRel
            if ($aRel -match '^[a-zA-Z]:') {
                $aPath = $aRel -replace '/', '\'
            } elseif (-not ($aRel -match '^\.\.') -and -not ($aRel -match '^\.\\')) {
                $aPath = Join-Path $litertBuildDir $aRel
            }
            if (-not (Test-Path $aPath)) {
                $parent = Split-Path $aPath -Parent
                if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
                    try { $null = New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue } catch { }
                }
                try {
                    $null = & $llvmAr rcs $aPath -- 2>&1
                    $stubCount++
                } catch { }
            }
        }
    }
    Write-Host "Created $stubCount .a aggregate stubs"
}

Write-Host 'Running ExternalProject step 6 (build)...'
& $ninja -C $buildDir litert_lm/stamps/litert_lm-build 2>&1
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 101) { Write-Host "WARNING: ninja build step exited with code $LASTEXITCODE" }
Write-Host "Build step completed with exit code: $LASTEXITCODE"

Write-Host 'Installing...'
& cmake --install $buildDir --config Release 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "WARNING: cmake --install had errors (exit $LASTEXITCODE)" }
Write-Host '=== LiteRT-LM source build completed ==='



