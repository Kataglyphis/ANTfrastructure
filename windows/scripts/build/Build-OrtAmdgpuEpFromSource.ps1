# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds AMD's ONNX Runtime plugin EP (migraphx-ep.dll) against the image's ORT and MIGraphX (rocm lane only).
.DESCRIPTION
    onnxruntime/onnxruntime-ep-amdgpu, pinned by commit, with USE_MIGRAPHX only: no DirectML copy
    (ORT carries its own), no closed HIP backend, no amdgpu umbrella. Host-only C++, so clang-cl
    builds it; upstream forces the static CRT (/MT) for the EP, which crosses to ORT and MIGraphX
    only through C APIs. Every FetchContent download is pre-seeded from a SHA256-pinned archive and
    FETCHCONTENT_FULLY_DISCONNECTED turns any other fetch into a configure error. The output
    directory is self-contained for loading: MIGraphX and the TheRock HIP runtime sit beside the
    EP. Refuses unless Get-GpuEnvironment reports HasRocm. docs/windows-builds.md § ROCm layer.
.PARAMETER OnnxRuntimeDir
    The ORT install prefix; empty = $env:ONNX_ROOT (C:\runtime\lib\onnxruntime-source).
#>
param(
    [string]$InstallDir = 'C:\runtime\lib\onnxruntime-ep-amdgpu',
    [string]$MigraphxDir = 'C:\runtime\lib\migraphx',
    [string]$OnnxRuntimeDir = '',
    [string]$WorkDir = 'C:\temp\ort-amdgpu-ep-work',
    [string]$BuildType = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
$migraphxModulePath = Join-Path $scriptAssetRoot 'modules\WindowsMigraphx.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($migraphxModulePath)))) { Import-Module $migraphxModulePath }

function Get-OrtAmdgpuEpCmakeArgs {
    # USE_MIGRAPHX alone; the no-fetch pair and the seeds make every download a pinned, verified one.
    param(
        [Parameter(Mandatory)][string]$MigraphxDir,
        [Parameter(Mandatory)][string]$RocmRoot,
        [Parameter(Mandatory)][string]$OrtCmakeDir,
        [Parameter(Mandatory)][string]$GpuTargets,
        [Parameter(Mandatory)][string]$Python,
        [string[]]$SeedArgs = @()
    )
    $py = $Python -replace '\\', '/'
    return @(
        '-DUSE_MIGRAPHX=ON', '-DUSE_AMDGPU=OFF', '-DUSE_DML=OFF', '-DUSE_HIP=OFF'
        "-DCMAKE_PREFIX_PATH:STRING=$($MigraphxDir -replace '\\', '/');$($RocmRoot -replace '\\', '/')"
        "-Donnxruntime_DIR:PATH=$($OrtCmakeDir -replace '\\', '/')"
        # hip-config falls back to probing the host GPU without it; there is none at build time.
        "-DGPU_TARGETS:STRING=$GpuTargets"
        # protobuf then takes abseil from the absl seed instead of a local install or a git clone.
        '-Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON', '-Dprotobuf_WITH_ZLIB=OFF'
        '-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON', '-DCMAKE_POLICY_DEFAULT_CMP0170:STRING=NEW'
        '-DCMAKE_POLICY_VERSION_MINIMUM:STRING=3.5'
        "-DPython3_EXECUTABLE:FILEPATH=$py", "-DPython_EXECUTABLE:FILEPATH=$py"
    ) + $SeedArgs
}

function Get-OrtAmdgpuEpStageGap {
    # What must sit beside migraphx-ep.dll for it to load; returns the missing names.
    param(
        [Parameter(Mandatory)][string]$EpDir,
        [string[]]$HipRuntimeName = @()
    )
    $required = @('migraphx-ep.dll', 'migraphx.dll', 'migraphx_c.dll', 'migraphx_gpu.dll', 'migraphx_device.dll',
        'migraphx_onnx.dll', 'migraphx-hiprtc-driver.exe') + $HipRuntimeName
    return @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $EpDir $_) -PathType Leaf) })
}

# Refuses off the rocm lane (Get-GpuEnvironment.HasRocm) before anything is fetched.
$build = Initialize-MigraphxBuild -InstallDir $InstallDir -ScriptRoot $PSScriptRoot -Component 'onnxruntime-ep-amdgpu'
$InstallDir = $build.InstallDir
$rocmRoot = $build.RocmRoot
$gpuTargets = $build.GpuTargets
if (-not $OnnxRuntimeDir) { $OnnxRuntimeDir = if ($env:ONNX_ROOT) { $env:ONNX_ROOT } else { 'C:\runtime\lib\onnxruntime-source' } }
$ortCmakeDir = Join-Path $OnnxRuntimeDir 'lib\cmake\onnxruntime'
if (-not (Test-Path -LiteralPath (Join-Path $ortCmakeDir 'onnxruntimeConfig.cmake') -PathType Leaf)) {
    throw "ORT's CMake package is missing at $ortCmakeDir (the EP needs find_package(onnxruntime))"
}
if (-not (Test-Path -LiteralPath (Join-Path $MigraphxDir 'lib\cmake\migraphx\migraphx-config.cmake') -PathType Leaf)) {
    throw "MIGraphX is not installed at $MigraphxDir (Build-MigraphxFromSource.ps1 runs first)"
}
Write-Host "=== onnxruntime-ep-amdgpu source build (migraphx-ep.dll, clang-cl, ORT $OnnxRuntimeDir) ==="

$python = Start-MigraphxBuildSession -WorkDir $WorkDir

try {
    Switch-BuildPhase '1. EP source + FetchContent seeds'
    $epSource = Resolve-PinnedSource -Name 'onnxruntime-ep-amdgpu' -VersionKey 'ORT_AMDGPU_EP_COMMIT' -ShaKey 'ORT_AMDGPU_EP_SOURCE_SHA256' `
        -UrlFormat 'https://github.com/onnxruntime/onnxruntime-ep-amdgpu/archive/{0}.tar.gz'
    $epRoot = Save-PinnedSource -Source $epSource -WorkDir $WorkDir

    $specs = @(Get-MigraphxPinnedSourceSpec -Set OrtAmdgpuEp)
    $resolved = @{}
    foreach ($spec in $specs) { $resolved[$spec.Name] = Resolve-PinnedSource @spec }
    $declared = Get-FetchContentUrlMap -CMakeText ([System.IO.File]::ReadAllText((Join-Path $epRoot 'src\CMakeLists.txt')))
    $seededUrls = @{}
    foreach ($name in $resolved.Keys) { if ($name -ne 'absl') { $seededUrls[$name] = $resolved[$name].Url } }
    # eigen, d3dx12 and boost are declared under if(USE_DML), which stays OFF.
    Assert-FetchContentSeeded -Declared $declared -Seeded $seededUrls -Inactive @('eigen', 'd3dx12', 'boost')

    $seedArgs = @()
    $seedRoots = @{}
    foreach ($spec in $specs) {
        $root = Save-PinnedSource -Source $resolved[$spec.Name] -WorkDir $WorkDir
        $seedRoots[$spec.Name] = $root
        $seedArgs += Get-FetchContentSeedArg -Name $spec.Name -SourceDir $root
        if ($spec.Name -eq 'protobuf') {
            $wanted = Get-MigraphxTreeFact -Fact ProtobufAbseil -CMakeText ([System.IO.File]::ReadAllText((Join-Path $root 'cmake\dependencies.cmake')))
            if ($wanted -ne $resolved['absl'].Version) {
                throw "protobuf $($resolved['protobuf'].Version) wants abseil $wanted, ORT_AMDGPU_EP_ABSEIL_VERSION is $($resolved['absl'].Version)"
            }
        }
    }

    Switch-BuildPhase '2. EP configure (clang-cl, /MT)'
    $buildDir = Join-Path $WorkDir 'ep-build'
    $epArgs = @(Get-OrtAmdgpuEpCmakeArgs -MigraphxDir $MigraphxDir -RocmRoot $rocmRoot -OrtCmakeDir $ortCmakeDir `
            -GpuTargets $gpuTargets -Python $python -SeedArgs $seedArgs) + @(Get-LlvmArchiverCmakeArg)
    # -AllowRocmPrefix: find_package(hip) and migraphx's MIOpen/rocBLAS/hipBLASLt dependencies live in TheRock.
    Invoke-CmakeConfigure -SourceDir $epRoot -BuildDir $buildDir -InstallPrefix $InstallDir -BuildType $BuildType `
        -ExtraArgs $epArgs -AllowRocmPrefix

    Switch-BuildPhase '3. EP build'
    # No `cmake --install`: upstream packages from the build tree, where POST_BUILD copies the MIGraphX closure.
    Invoke-NinjaBuildWithRetry -BuildDir $buildDir -Targets @('migraphx-ep') -RetryJobs 2
    $epDll = Get-ChildItem -LiteralPath $buildDir -Recurse -File -Filter 'migraphx-ep.dll' | Select-Object -First 1
    if (-not $epDll) { throw "migraphx-ep.dll not found under $buildDir after the build" }

    Switch-BuildPhase '4. stage'
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Get-ChildItem -LiteralPath $epDll.DirectoryName -File | Where-Object { $_.Extension -in '.dll', '.exe' -or $_.Name -eq 'problem_cache.json' } |
        Copy-Item -Destination $InstallDir -Force
    $hipRuntime = @(Get-MigraphxHipRuntimeFile -RocmBin (Join-Path $rocmRoot 'bin'))
    if ($hipRuntime.Count -eq 0) { throw "no amdhip64/amd_comgr/hiprtc DLLs under $rocmRoot\bin" }
    $hipRuntime | Copy-Item -Destination $InstallDir -Force
    Copy-Item -LiteralPath (Join-Path $epRoot 'LICENSE') -Destination (Join-Path $InstallDir 'LICENSE') -Force
    $licenses = Join-Path $epRoot 'LICENSES'
    if (Test-Path -LiteralPath $licenses) { Copy-Item -LiteralPath $licenses -Destination $InstallDir -Recurse -Force }
    # The texts of the seeds linked in statically (/MT); docs/deps/deps.json registers the same set.
    Save-MigraphxLicense -Set OrtAmdgpuEp -SourceRoot $seedRoots -InstallDir $InstallDir

    Switch-BuildPhase '5. verify'
    $gap = @(Get-OrtAmdgpuEpStageGap -EpDir $InstallDir -HipRuntimeName @($hipRuntime | ForEach-Object Name)) +
        @(Get-MigraphxLicenseGap -InstallDir $InstallDir -Set OrtAmdgpuEp)
    if ($gap.Count -gt 0) { throw "onnxruntime-ep-amdgpu stage is missing: $($gap -join ', ')" }
    $epStaged = Join-Path $InstallDir 'migraphx-ep.dll'
    $static = @(Get-PeImportNames -Path $epStaged)
    if ($static -match '^amdhip64') { throw 'migraphx-ep.dll imports amdhip64 statically: /DELAYLOAD did not reach the linker' }
    if ($static -notcontains 'migraphx_c.dll') { throw "migraphx-ep.dll does not import migraphx_c.dll (imports: $($static -join ', '))" }
    Complete-CurrentBuildPhase
} catch {
    Complete-CurrentBuildPhase -ErrorRecord $_
    Write-BuildPhaseSummary -Label 'onnxruntime-ep-amdgpu'
    throw
}

Complete-MigraphxBuildSession -Label 'onnxruntime-ep-amdgpu' -WorkDir $WorkDir -Banner "=== onnxruntime-ep-amdgpu build complete ($InstallDir) ==="
