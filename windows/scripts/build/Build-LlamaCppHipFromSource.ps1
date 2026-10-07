# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds llama.cpp's HIP backend (ggml-hip.dll) from source against TheRock (rocm lane only).
.DESCRIPTION
    Upstream's windows-rocm recipe at the pinned tag, with TheRock's AMD clang; Install-LlamaCpp.ps1 -Backend hip
    then installs it beside the same tag's CPU zip. See docs/windows-rocm.md § llama.cpp HIP and Vulkan.
.PARAMETER OutputDir
    Receives ggml-hip.dll and llama-cpp-hip-build.json (the pins it was built from).
.PARAMETER WorkDir
    Scratch for the source and the build tree; removed before the layer closes.
#>
param(
    [string]$OutputDir = 'C:\temp\llama-cpp-hip-built',
    [string]$WorkDir = 'C:\temp\llama-cpp-hip-work',
    [string]$BuildType = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
$migraphxModulePath = Join-Path $scriptAssetRoot 'modules\WindowsMigraphx.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($migraphxModulePath)))) { Import-Module $migraphxModulePath }

<#
.SYNOPSIS
    The build number and commit LLAMA_CPP_HIP_BUILD/_COMMIT name; throws on a malformed one before anything is fetched.
#>
function Get-LlamaCppHipSourcePin {
    $pin = [pscustomobject]@{ Build = "$env:LLAMA_CPP_HIP_BUILD".Trim(); Commit = "$env:LLAMA_CPP_HIP_COMMIT".Trim() }
    if ($pin.Build -notmatch '^\d+$') { throw "LLAMA_CPP_HIP_BUILD must be a build number like 11472; got '$($pin.Build)'" }
    if ($pin.Commit -cnotmatch '^[0-9a-f]{40}$') { throw "LLAMA_CPP_HIP_COMMIT must be the 40-hex commit of tag b$($pin.Build); got '$($pin.Commit)'" }
    return $pin
}

<#
.SYNOPSIS
    Configure args: upstream's ggml-hip recipe, with every part that could download or build more switched off.
#>
function Get-LlamaCppHipCmakeArgs {
    param(
        [Parameter(Mandatory)][string]$RocmRoot,
        [Parameter(Mandatory)][string]$GpuTargets,
        [Parameter(Mandatory)][string]$Build,
        [Parameter(Mandatory)][string]$Commit
    )
    return @(
        "-DCMAKE_AR:FILEPATH=$(Get-RocmLlvmToolPath -RocmRoot $RocmRoot -Tool 'llvm-ar')"
        "-DCMAKE_RANLIB:FILEPATH=$(Get-RocmLlvmToolPath -RocmRoot $RocmRoot -Tool 'llvm-ranlib')"
        "-DCMAKE_PREFIX_PATH:STRING=$($RocmRoot -replace '\\', '/')"
        # Explicit: hip-config otherwise probes the host for a GPU, and there is none at build time.
        "-DGPU_TARGETS:STRING=$GpuTargets"
        '-DGGML_HIP=ON', '-DGGML_BACKEND_DL=ON', '-DGGML_NATIVE=OFF', '-DGGML_CPU=OFF'
        '-DCMAKE_C_FLAGS:STRING=-Wno-error=incompatible-pointer-types'
        # Device passes over MSVC headers warn on every dllimport: over 100k lines per build otherwise.
        '-DCMAKE_CXX_FLAGS:STRING=-Wno-ignored-attributes -Wno-nested-anon-types'
        # A tarball has no git history, so the build identity comes from the pin.
        "-DLLAMA_BUILD_NUMBER:STRING=$Build", "-DLLAMA_BUILD_COMMIT:STRING=$($Commit.Substring(0, 7))"
        # Only ggml-hip is built; the tools come from the CPU zip, and the UI and BoringSSL would download unpinned.
        '-DLLAMA_BUILD_COMMON=OFF', '-DLLAMA_BUILD_TESTS=OFF', '-DLLAMA_BUILD_TOOLS=OFF', '-DLLAMA_BUILD_EXAMPLES=OFF'
        '-DLLAMA_BUILD_SERVER=OFF', '-DLLAMA_BUILD_APP=OFF', '-DLLAMA_OPENSSL=OFF', '-DLLAMA_USE_PREBUILT_UI=OFF'
        '-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON', '-DCMAKE_POLICY_DEFAULT_CMP0170:STRING=NEW'
        '-DCMAKE_MSVC_RUNTIME_LIBRARY:STRING=MultiThreadedDLL'
    )
}

<#
.SYNOPSIS
    Writes what the installer records in its manifest: the pins this DLL was built from.
#>
function Write-LlamaCppHipBuildRecord {
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)]$Pin,
        [Parameter(Mandatory)][string]$SourceSha256,
        [Parameter(Mandatory)][string]$GpuTargets,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RocmRelease
    )
    $record = [ordered]@{ build = $Pin.Build; commit = $Pin.Commit; source_sha256 = $SourceSha256.ToLowerInvariant()
        gpu_targets = $GpuTargets; rocm_release = $RocmRelease }
    $path = Join-Path $OutputDir 'llama-cpp-hip-build.json'
    [System.IO.File]::WriteAllText($path, ($record | ConvertTo-Json))
    return $path
}

$session = Initialize-MigraphxBuild -InstallDir $OutputDir -ScriptRoot $PSScriptRoot -Component 'llama.cpp HIP'
# Both pins are checked before the VS environment, the scratch dirs or the network are touched.
$pin = Get-LlamaCppHipSourcePin
$source = Resolve-PinnedSource -Name 'llama.cpp' -VersionKey 'LLAMA_CPP_HIP_COMMIT' -ShaKey 'LLAMA_CPP_HIP_SOURCE_SHA256' `
    -UrlFormat 'https://github.com/ggml-org/llama.cpp/archive/{0}.tar.gz'
Write-Host "=== llama.cpp b$($pin.Build) ggml-hip source build (AMD clang from $($session.RocmRoot), GPU_TARGETS=$($session.GpuTargets)) ==="

Enter-VsDevCmdEnvironment
foreach ($dir in $WorkDir, $session.InstallDir) { Reset-SourceBuildDirectory -Path $dir; [void][System.IO.Directory]::CreateDirectory($dir) }
Start-SccacheServerSession

try {
    Switch-BuildPhase '1. llama.cpp source'
    $tree = Save-PinnedSource -Source $source -WorkDir $WorkDir

    Switch-BuildPhase '2. configure (AMD clang)'
    $ninjaDir = Join-Path $WorkDir 'build'
    $cmakeArgs = Get-LlamaCppHipCmakeArgs -RocmRoot $session.RocmRoot -GpuTargets $session.GpuTargets -Build $pin.Build -Commit $pin.Commit
    # ggml-hip needs find_package(hip/hipblas/rocblas) from TheRock; nothing is installed, only the target is copied.
    [void](Invoke-RocmClangConfigure -SourceDir $tree -BuildDir $ninjaDir -InstallPrefix (Join-Path $WorkDir 'install') -RocmRoot $session.RocmRoot `
        -BuildType $BuildType -ExtraArgs $cmakeArgs)

    Switch-BuildPhase '3. build ggml-hip'
    Invoke-NinjaBuildWithRetry -BuildDir $ninjaDir -Targets @('ggml-hip') -RetryJobs 2

    Switch-BuildPhase '4. verify + stage'
    $dll = Join-Path $ninjaDir 'bin\ggml-hip.dll'
    Assert-RocmBuiltPe -Path $dll
    Copy-Item -LiteralPath $dll -Destination $session.InstallDir
    $record = Write-LlamaCppHipBuildRecord -OutputDir $session.InstallDir -Pin $pin -SourceSha256 $source.Sha256 -GpuTargets $session.GpuTargets `
        -RocmRelease "$env:ROCM_WINDOWS_RELEASE"
    Write-Host ('ggml-hip.dll: {0:N0} bytes; build record {1}' -f ([System.IO.FileInfo]::new($dll)).Length, $record)
    Complete-CurrentBuildPhase
} catch {
    Complete-CurrentBuildPhase -ErrorRecord $_
    Write-BuildPhaseSummary -Label 'llama.cpp HIP'
    throw
}

Write-BuildPhaseSummary -Label 'llama.cpp HIP'
Write-SccacheStats -Label 'llama.cpp HIP'
Complete-SccacheServerSession
Complete-SourceBuild -Banner "=== llama.cpp b$($pin.Build) ggml-hip build complete ($($session.InstallDir), $($session.GpuTargets)) ===" -SourceDir $WorkDir
