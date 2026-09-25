# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds AMD MIGraphX from source against TheRock and installs it to a prefix (rocm lane only).
.DESCRIPTION
    The spike behind windows/Dockerfile.rocm-migraphx. The host-only deps (abseil, protobuf,
    msgpack-c, SQLite) build with the image's clang-cl, as upstream's Windows CI does; MIGraphX
    itself compiles with TheRock's AMD clang++ by absolute path, because the hub's clang-cl has no
    AMDGPU backend. rocMLIR is not in the tarball, so MIGRAPHX_ENABLE_MLIR=OFF - a configuration
    no upstream CI builds. Refuses unless Get-GpuEnvironment reports HasRocm.
    docs/windows-builds.md § ROCm layer.
.PARAMETER InstallDir
    The MIGraphX prefix: bin (DLLs, migraphx-driver.exe), lib (import libs, CMake package), include.
.PARAMETER WorkDir
    Scratch for sources, the dep prefix and the build trees; removed before the layer closes.
#>
param(
    [string]$InstallDir = 'C:\runtime\lib\migraphx',
    [string]$WorkDir = 'C:\temp\migraphx-work',
    [string]$BuildType = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
$migraphxModulePath = Join-Path $scriptAssetRoot 'modules\WindowsMigraphx.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($migraphxModulePath)))) { Import-Module $migraphxModulePath }

function Get-MigraphxDepCmakeArgs {
    # Static libs on the /MD CRT MIGraphX uses; FULLY_DISCONNECTED turns any fetch into a configure error.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DepsPrefix
    )
    # Typed where no project declares the name, so Assert-CmakeArgsConsumed only flags real options.
    $common = @(
        '-DBUILD_SHARED_LIBS:BOOL=OFF'
        '-DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON'
        '-DCMAKE_POLICY_DEFAULT_CMP0091:STRING=NEW'
        '-DCMAKE_MSVC_RUNTIME_LIBRARY:STRING=MultiThreadedDLL'
        "-DCMAKE_PREFIX_PATH:STRING=$($DepsPrefix -replace '\\', '/')"
        '-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON'
        '-DCMAKE_POLICY_DEFAULT_CMP0170:STRING=NEW'
        '-DCMAKE_POLICY_VERSION_MINIMUM:STRING=3.5'
    )
    switch ($Name) {
        'abseil' {
            return $common + @('-DCMAKE_CXX_STANDARD:STRING=17', '-DABSL_PROPAGATE_CXX_STD=ON', '-DABSL_ENABLE_INSTALL=ON',
                '-DABSL_MSVC_STATIC_RUNTIME=OFF', '-DABSL_BUILD_TESTING=OFF', '-DBUILD_TESTING:BOOL=OFF')
        }
        'protobuf' {
            return $common + @('-DCMAKE_CXX_STANDARD:STRING=17', '-Dprotobuf_BUILD_TESTS=OFF', '-Dprotobuf_BUILD_SHARED_LIBS=OFF',
                '-Dprotobuf_MSVC_STATIC_RUNTIME=OFF', '-Dprotobuf_BUILD_LIBPROTOC=ON', '-Dprotobuf_BUILD_PROTOC_BINARIES=ON',
                '-Dprotobuf_BUILD_PROTOBUF_BINARIES=ON', '-Dprotobuf_WITH_ZLIB=OFF', '-Dprotobuf_LOCAL_DEPENDENCIES_ONLY=ON')
        }
        'msgpack' { return $common + @('-DMSGPACK_BUILD_TESTS=OFF', '-DMSGPACK_BUILD_EXAMPLES=OFF') }
        'sqlite' { return $common }
        default { throw "no configure args for MIGraphX dep '$Name'" }
    }
}

function Write-SqliteCmakeProject {
    # The amalgamation ships no build system; one static library is all MIGraphX links.
    param([Parameter(Mandatory)][string]$SourceDir)
    Set-Content -LiteralPath (Join-Path $SourceDir 'CMakeLists.txt') -Encoding ascii -Value @(
        'cmake_minimum_required(VERSION 3.20)'
        'project(sqlite3 C)'
        'add_library(sqlite3 STATIC sqlite3.c)'
        'install(TARGETS sqlite3 ARCHIVE DESTINATION lib)'
        'install(FILES sqlite3.h sqlite3ext.h DESTINATION include)'
    )
}

function Get-MigraphxCmakeArgs {
    # Compilers go in separately (absolute AMD clang); everything else that selects the build is here.
    param(
        [Parameter(Mandatory)][string]$RocmRoot,
        [Parameter(Mandatory)][string]$DepsPrefix,
        [Parameter(Mandatory)][string]$GpuTargets,
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$NlohmannJsonDir,
        [Parameter(Mandatory)][string]$HipMathOverlay
    )
    $deps = $DepsPrefix -replace '\\', '/'
    $rocm = $RocmRoot -replace '\\', '/'
    return @(
        "-DCMAKE_AR:FILEPATH=$(Get-RocmLlvmToolPath -RocmRoot $RocmRoot -Tool 'llvm-ar')"
        "-DCMAKE_RANLIB:FILEPATH=$(Get-RocmLlvmToolPath -RocmRoot $RocmRoot -Tool 'llvm-ranlib')"
        "-DCMAKE_PREFIX_PATH:STRING=$deps;$rocm"
        "-DGPU_TARGETS:STRING=$GpuTargets"
        '-DMIGRAPHX_ENABLE_GPU=ON', '-DMIGRAPHX_ENABLE_CPU=OFF', '-DMIGRAPHX_ENABLE_FPGA=OFF'
        '-DMIGRAPHX_ENABLE_PYTHON=OFF', '-DMIGRAPHX_ENABLE_TENSORFLOW=OFF', '-DMIGRAPHX_ENABLE_ONNX=ON'
        # rocMLIR is not in TheRock 10.0; upstream's Windows CI builds it from source instead.
        '-DMIGRAPHX_ENABLE_MLIR=OFF', '-DMIGRAPHX_USE_COMPOSABLEKERNEL=OFF'
        '-DMIGRAPHX_USE_MIOPEN=ON', '-DMIGRAPHX_USE_ROCBLAS=ON', '-DMIGRAPHX_USE_HIPBLASLT=ON'
        '-DMIGRAPHX_USE_AMDMLSS=OFF', '-DMIGRAPHX_USE_EIGEN=OFF'
        # BUILD_DEV=OFF selects MIGRAPHX_USE_HIPRTC: kernels JIT through hiprtc at run time.
        '-DBUILD_DEV=OFF', '-DBUILD_TESTING=OFF'
        '-DCMAKE_POLICY_DEFAULT_CMP0091:STRING=NEW', '-DCMAKE_MSVC_RUNTIME_LIBRARY:STRING=MultiThreadedDLL'
        '-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON', '-DCMAKE_POLICY_DEFAULT_CMP0170:STRING=NEW'
        # Ahead of clang's resource dir: HIP's math headers yield isgreater & co. to MSVC 14.51's constexpr
        # <cmath> versions (Write-HipMsvcCmathOverlay). Only HIP sources include those two headers.
        "-DCMAKE_CXX_FLAGS:STRING=-isystem $($HipMathOverlay -replace '\\', '/')"
        "-DSQLite3_INCLUDE_DIR:PATH=$deps/include"
        "-DSQLite3_LIBRARY:FILEPATH=$deps/lib/sqlite3.lib"
        # TheRock's header-only copy (the licence notice staged below is the one compiled in), through
        # the shim that drops the natvis its dist lacks (Write-NlohmannJsonConfigShim).
        "-Dnlohmann_json_DIR:PATH=$($NlohmannJsonDir -replace '\\', '/')"
        "-DPython_EXECUTABLE:FILEPATH=$($Python -replace '\\', '/')"
        # The offload-arch check must use AMD's own tools, never whatever LLVM PATH finds first.
        "-DLLVM_OBJCOPY:FILEPATH=$(Get-RocmLlvmToolPath -RocmRoot $RocmRoot -Tool 'llvm-objcopy')"
        "-DCLANG_OFFLOAD_BUNDLER:FILEPATH=$(Get-RocmLlvmToolPath -RocmRoot $RocmRoot -Tool 'clang-offload-bundler')"
        "-DLLVM_READOBJ:FILEPATH=$(Get-RocmLlvmToolPath -RocmRoot $RocmRoot -Tool 'llvm-readobj')"
    )
}

function Get-MigraphxInstallGap {
    # What migraphx-ep.dll and the bare-host proof need from the prefix; returns the missing paths.
    param([Parameter(Mandatory)][string]$InstallDir)
    $required = @(
        'bin\migraphx.dll', 'bin\migraphx_c.dll', 'bin\migraphx_gpu.dll', 'bin\migraphx_device.dll',
        'bin\migraphx_onnx.dll', 'bin\migraphx-hiprtc-driver.exe', 'bin\migraphx-driver.exe',
        'lib\migraphx_c.lib', 'lib\cmake\migraphx\migraphx-config.cmake', 'include\migraphx\migraphx.hpp'
    )
    return @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $InstallDir $_) -PathType Leaf) })
}

# Refuses off the rocm lane (Get-GpuEnvironment.HasRocm) before anything is fetched.
$build = Initialize-MigraphxBuild -InstallDir $InstallDir -ScriptRoot $PSScriptRoot -Component 'MIGraphX'
$InstallDir = $build.InstallDir
$rocmRoot = $build.RocmRoot
$gpuTargets = $build.GpuTargets
# Read raw, no fallback: the tree's own version is checked against it below.
$migraphxVersion = "$env:MIGRAPHX_VERSION".Trim()
if (-not $migraphxVersion) { throw 'MIGRAPHX_VERSION is not set (the Dockerfile ARG is missing?)' }
Write-Host "=== MIGraphX $migraphxVersion source build (AMD clang++ from $rocmRoot, GPU_TARGETS=$gpuTargets) ==="

$python = Start-MigraphxBuildSession -WorkDir $WorkDir

try {
    Switch-BuildPhase '1. MIGraphX source'
    $source = Resolve-PinnedSource -Name 'AMDMIGraphX' -VersionKey 'MIGRAPHX_WINDOWS_COMMIT' -ShaKey 'MIGRAPHX_WINDOWS_SOURCE_SHA256' `
        -UrlFormat 'https://github.com/ROCm/AMDMIGraphX/archive/{0}.tar.gz'
    $sourceRoot = Save-PinnedSource -Source $source -WorkDir $WorkDir
    $treeVersion = Get-MigraphxTreeFact -Fact MigraphxVersion -CMakeText ([System.IO.File]::ReadAllText((Join-Path $sourceRoot 'CMakeLists.txt')))
    if ($treeVersion -ne $migraphxVersion) { throw "MIGRAPHX_WINDOWS_COMMIT is MIGraphX $treeVersion, but MIGRAPHX_VERSION is $migraphxVersion" }

    Switch-BuildPhase '2. host deps (clang-cl)'
    $depsPrefix = Join-Path $WorkDir 'deps'
    # MIGraphX's OWN rocm-cmake pin, installed ahead of TheRock's (which lacks rocm_add_version_resource).
    $requirements = [System.IO.File]::ReadAllText((Join-Path $sourceRoot 'requirements.txt'))
    $rocmCmakeRoot = Save-GitCommitSource -Name 'rocm-cmake' -Repository 'https://github.com/ROCm/rocm-cmake.git' `
        -Commit (Get-MigraphxRocmCmakeCommit -RequirementsText $requirements) -WorkDir $WorkDir
    Invoke-CmakeConfigure -SourceDir $rocmCmakeRoot -BuildDir (Join-Path $WorkDir 'rocm-cmake-build') -InstallPrefix $depsPrefix `
        -BuildType $BuildType -ExtraArgs @('-DBUILD_TESTING:BOOL=OFF')
    Invoke-NinjaBuildWithRetry -BuildDir (Join-Path $WorkDir 'rocm-cmake-build') -Install -InstallConfig $BuildType -RetryJobs 2
    $depRoots = @{}
    foreach ($spec in Get-MigraphxPinnedSourceSpec -Set MigraphxDeps) {
        $depSource = Resolve-PinnedSource @spec
        $depRoot = Save-PinnedSource -Source $depSource -WorkDir $WorkDir
        $depRoots[$spec.Name] = $depRoot
        if ($spec.Name -eq 'sqlite') { Write-SqliteCmakeProject -SourceDir $depRoot }
        $depBuild = Join-Path $WorkDir "$($spec.Name)-build"
        $depArgs = @(Get-MigraphxDepCmakeArgs -Name $spec.Name -DepsPrefix $depsPrefix) + @(Get-LlvmArchiverCmakeArg)
        Invoke-CmakeConfigure -SourceDir $depRoot -BuildDir $depBuild -InstallPrefix $depsPrefix -BuildType $BuildType -ExtraArgs $depArgs
        Invoke-NinjaBuildWithRetry -BuildDir $depBuild -Install -InstallConfig $BuildType -RetryJobs 2
    }

    Switch-BuildPhase '3. MIGraphX configure (AMD clang++)'
    $buildDir = Join-Path $WorkDir 'migraphx-build'
    $jsonDir = Write-NlohmannJsonConfigShim -RocmRoot $rocmRoot -DepsPrefix $depsPrefix
    $migraphxArgs = Get-MigraphxCmakeArgs -RocmRoot $rocmRoot -DepsPrefix $depsPrefix -GpuTargets $gpuTargets -Python $python `
        -NlohmannJsonDir $jsonDir -HipMathOverlay (Write-HipMsvcCmathOverlay -WorkDir $WorkDir)
    # -AllowRocmPrefix: this build needs find_package(hip/miopen/rocblas/hipblaslt/hiprtc) from TheRock.
    Invoke-CmakeConfigure -SourceDir $sourceRoot -BuildDir $buildDir -InstallPrefix $InstallDir -BuildType $BuildType `
        -CCompiler (Get-RocmLlvmToolPath -RocmRoot $rocmRoot -Tool 'clang') `
        -CxxCompiler (Get-RocmLlvmToolPath -RocmRoot $rocmRoot -Tool 'clang++') `
        -Linker '' -Archiver '' -ExtraArgs $migraphxArgs -AllowRocmPrefix

    Switch-BuildPhase '4. MIGraphX build + install'
    Invoke-NinjaBuildWithRetry -BuildDir $buildDir -Install -InstallConfig $BuildType -RetryJobs 2
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') -Destination (Join-Path $InstallDir 'LICENSE') -Force
    # The texts of what is linked in statically; docs/deps/deps.json registers the same set.
    Save-MigraphxLicense -Set MigraphxDeps -SourceRoot $depRoots -InstallDir $InstallDir -RocmRoot $rocmRoot

    Switch-BuildPhase '5. verify'
    $gap = @(Get-MigraphxInstallGap -InstallDir $InstallDir) + @(Get-MigraphxLicenseGap -InstallDir $InstallDir -Set MigraphxDeps)
    if ($gap.Count -gt 0) { throw "MIGraphX install is missing: $($gap -join ', ')" }
    $gpuDll = Join-Path $InstallDir 'bin\migraphx_gpu.dll'
    $machine = Get-PeFileMachine -Path $gpuDll
    if ($machine -ne (Get-PeMachineType -Arch 'amd64')) { throw ('migraphx_gpu.dll PE machine 0x{0:X4} is not amd64' -f $machine) }
    Complete-CurrentBuildPhase
} catch {
    Complete-CurrentBuildPhase -ErrorRecord $_
    Write-BuildPhaseSummary -Label 'MIGraphX'
    throw
}

Complete-MigraphxBuildSession -Label 'MIGraphX' -WorkDir $WorkDir -Banner "=== MIGraphX $migraphxVersion build complete ($InstallDir, $gpuTargets) ==="
