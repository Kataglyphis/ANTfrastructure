# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds the TensorRT plugin EP (onnxruntime_ep_tensorrt.dll) from its pinned commit against the chain's ORT (nvidia lane, amd64).
.DESCRIPTION
    ORT_HOME is a shim over the chain's headers and import library, and every FetchContent is a hash-pinned seed;
    see docs/windows-cross-builds.md § The TensorRT plugin EP.
.PARAMETER SourceDir
    The plugin's sources, seeds and build tree; the ORT gate scans all of it.
#>
param(
    [string]$SourceDir = 'C:\temp\ort-trt-ep-src',
    [string]$InstallDir = 'C:\runtime',
    [string]$BuildType = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }
Import-Module (Resolve-SourceBuildLeafModule -AssetRoot $scriptAssetRoot -Name 'WindowsNativeProvenance.Common.psm1') -DisableNameChecking
Import-Module (Resolve-SourceBuildLeafModule -AssetRoot $scriptAssetRoot -Name 'WindowsOrtProvenance.Build.psm1') -DisableNameChecking
# Get-PeImportNames and Get-OrtPluginEpExportGap are not re-exported through WindowsSourceBuild.Common.
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1') -DisableNameChecking

function Get-OrtTensorRtEpPin {
    # Both halves of every pin or a refusal: Invoke-DownloadWithRetry treats an empty hash as no check.
    $gh = 'https://github.com'
    $rows = @(
        @{ Name = 'onnxruntime-ep-tensorrt'; Ref = 'ORT_TENSORRT_EP_COMMIT'; Sha = 'ORT_TENSORRT_EP_SOURCE_SHA256'; Url = "$gh/onnxruntime/onnxruntime-ep-tensorrt/archive/{0}.tar.gz"; Repo = ''; Tag = '' }
        @{ Name = 'protobuf'; Ref = 'ORT_TENSORRT_EP_PROTOBUF_VERSION'; Sha = 'ORT_TENSORRT_EP_PROTOBUF_SHA256'; Url = "$gh/protocolbuffers/protobuf/archive/refs/tags/v{0}.tar.gz"; Repo = "$gh/protocolbuffers/protobuf.git"; Tag = 'v{0}' }
        @{ Name = 'onnx'; Ref = 'ORT_TENSORRT_EP_ONNX_COMMIT'; Sha = 'ORT_TENSORRT_EP_ONNX_SHA256'; Url = "$gh/onnx/onnx/archive/{0}.tar.gz"; Repo = "$gh/onnx/onnx.git"; Tag = '{0}' }
        @{ Name = 'gsl'; Ref = 'ORT_TENSORRT_EP_GSL_VERSION'; Sha = 'ORT_TENSORRT_EP_GSL_SHA256'; Url = "$gh/microsoft/GSL/archive/refs/tags/v{0}.tar.gz"; Repo = "$gh/microsoft/GSL.git"; Tag = 'v{0}' }
        @{ Name = 'flatbuffers'; Ref = 'ORT_TENSORRT_EP_FLATBUFFERS_VERSION'; Sha = 'ORT_TENSORRT_EP_FLATBUFFERS_SHA256'; Url = "$gh/google/flatbuffers/archive/refs/tags/v{0}.tar.gz"; Repo = "$gh/google/flatbuffers.git"; Tag = 'v{0}' }
    )
    foreach ($row in $rows) {
        $ref = "$([Environment]::GetEnvironmentVariable($row.Ref))".Trim()
        $sha = "$([Environment]::GetEnvironmentVariable($row.Sha))".Trim()
        if ($ref -notmatch '^[A-Za-z0-9._-]+$') { throw "$($row.Ref)='$ref' is not a version or commit (stale versions.env, or the Dockerfile ARG is missing)" }
        if ($sha -notmatch '^[0-9A-Fa-f]{64}$') { throw "$($row.Sha)='$sha' is not a 64-hex SHA256: refusing to fetch $($row.Name) unverified" }
        [pscustomobject]@{
            Name = $row.Name; Version = $ref; Sha256 = $sha.ToLowerInvariant(); Url = ($row.Url -f $ref)
            Repo = $row.Repo; Tag = $(if ($row.Tag) { $row.Tag -f $ref } else { '' })
        }
    }
}

function Get-OrtTensorRtEpDeclaration {
    # name -> 'repository@tag' of every FetchContent_Declare(<name> GIT_REPOSITORY <repo> GIT_TAG <tag>) in the plugin's CMake.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CMakeText)
    $map = [ordered]@{}
    foreach ($m in [regex]::Matches($CMakeText, '(?is)FetchContent_Declare\(\s*([A-Za-z0-9_.+-]+)\s+GIT_REPOSITORY\s+(\S+)\s+GIT_TAG\s+([^\s)]+)')) {
        $map[$m.Groups[1].Value.ToLowerInvariant()] = "$($m.Groups[2].Value)@$($m.Groups[3].Value)"
    }
    return $map
}

function Get-OrtTensorRtEpSeedGap {
    # googletest is declared only under the plugin's own tests, which stay off.
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Declared, [Parameter(Mandatory)][object[]]$Pin)
    if ($Declared.Count -eq 0) { return , 'the plugin CMake declares no FetchContent dependency: its layout moved and this check would check nothing' }
    $seeded = @{}
    foreach ($p in @($Pin | Where-Object { $_.Repo })) { $seeded[$p.Name] = "$($p.Repo)@$($p.Tag)" }
    return @(
        foreach ($name in @($Declared.Keys | Where-Object { $_ -ne 'googletest' })) {
            if (-not $seeded.ContainsKey($name)) { "$name ($($Declared[$name])) has no hash-pinned seed" }
            elseif ($seeded[$name] -ne $Declared[$name]) { "$name is declared as $($Declared[$name]) but the seed pins $($seeded[$name])" }
        }
        foreach ($name in $seeded.Keys) { if (-not $Declared.Contains($name)) { "the plugin no longer declares the seeded $name" } }
    )
}

function Save-OrtTensorRtEpSource {
    # flatbuffers' docs and Java tests are in-tree links 7-Zip refuses; nothing the build reads.
    param([Parameter(Mandatory)]$Pin, [Parameter(Mandatory)][string]$WorkDir)
    $archive = Join-Path $WorkDir "$($Pin.Name).tar.gz"
    Invoke-DownloadWithRetry -Url $Pin.Url -DestinationPath $archive -Description "$($Pin.Name) $($Pin.Version)" -ExpectedSha256 $Pin.Sha256
    $root = Expand-SourceTarball -Archive $archive -Destination (Join-Path $WorkDir "$($Pin.Name)-src") -SkippedLinkResolver ${function:Get-SevenZipSkippedLink} -RemoveIntermediateTar
    Remove-Item -LiteralPath $archive -Force
    return $root
}

function Get-OrtTensorRtMajor {
    # The SDK's own import library names the major the plugin links (nvinfer_<major>.lib), never a guess from a pin.
    param([Parameter(Mandatory)][string]$SdkRoot)
    $libs = @(Get-ChildItem -LiteralPath (Join-Path $SdkRoot 'lib') -Filter 'nvinfer_*.lib' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^nvinfer_(\d+)\.lib$' })
    if ($libs.Count -ne 1) { throw "TensorRT plugin EP: expected one nvinfer_<major>.lib under $SdkRoot\lib, found $($libs.Count)" }
    return ($libs[0].Name -replace '^nvinfer_(\d+)\.lib$', '$1')
}

function New-OrtTensorRtEpHome {
    # The plugin wants a release-package layout: flat headers in include\, onnxruntime.lib in lib\.
    param([Parameter(Mandatory)][string]$OrtPrefix, [Parameter(Mandatory)][string]$Path)
    $headers = Join-Path $OrtPrefix 'include\onnxruntime'
    if (-not (Test-Path -LiteralPath (Join-Path $headers 'onnxruntime_c_api.h') -PathType Leaf)) { throw "the chain ORT at $OrtPrefix installs no include\onnxruntime\onnxruntime_c_api.h" }
    $lib = @('lib', 'bin' | ForEach-Object { Join-Path $OrtPrefix "$_\onnxruntime.lib" } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($lib.Count -eq 0) { throw "the chain ORT at $OrtPrefix holds no onnxruntime.lib (Build-OnnxFromSource.ps1 runs first)" }
    Reset-SourceBuildDirectory -Path $Path
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $Path 'include'), (Join-Path $Path 'lib')
    Get-ChildItem -LiteralPath $headers -File | Copy-Item -Destination (Join-Path $Path 'include') -Force
    Copy-Item -LiteralPath $lib[0] -Destination (Join-Path $Path 'lib\onnxruntime.lib') -Force
    return $Path
}

function Get-OrtTensorRtEpCmakeArgs {
    param(
        [Parameter(Mandatory)][string]$OrtHome,
        [Parameter(Mandatory)][string]$TensorRtSdk,
        [Parameter(Mandatory)][string]$TrtMajor,
        [Parameter(Mandatory)][string]$CudaRoot,
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SeedRoot
    )
    $cxx = (@('/WX-', '/clang:-Wno-invalid-specialization', '/clang:-Wno-unused-value', (Get-WarningNoiseSuppressionFlags)) | Where-Object { $_ }) -join ' '
    $py = $Python -replace '\\', '/'
    return @(
        "-DORT_HOME:PATH=$($OrtHome -replace '\\', '/')", "-DTENSORRT_HOME:PATH=$($TensorRtSdk -replace '\\', '/')"
        "-DTRT_MAJOR_VERSION:STRING=$TrtMajor"
        # Its own find_program(sccache) would replace the launcher the resolver set.
        '-Donnxruntime_ep_tensorrt_OBJECT_CACHE=OFF', '-Donnxruntime_ep_tensorrt_INSTALL=OFF'
        '-Dprotobuf_WITH_ZLIB=OFF', '-DFLATBUFFERS_BUILD_FLATC=OFF'
        '-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON', '-DCMAKE_POLICY_DEFAULT_CMP0170:STRING=NEW'
        '-DCMAKE_POLICY_VERSION_MINIMUM:STRING=3.5', '-DCMAKE_COMPILE_WARNING_AS_ERROR=OFF'
        "-DPython3_EXECUTABLE:FILEPATH=$py", "-DPython_EXECUTABLE:FILEPATH=$py"
        "-DCMAKE_CXX_FLAGS:STRING=$cxx"
    ) + @(Get-NvccCudaCmakeArgs -CudaRoot $CudaRoot -CudaStandard '17') +
        @(foreach ($name in $SeedRoot.Keys) { "-DFETCHCONTENT_SOURCE_DIR_$($name.ToUpperInvariant()):PATH=$($SeedRoot[$name] -replace '\\', '/')" })
}

function Get-OrtTensorRtEpModuleFinding {
    # The plugin entry points, the chain's onnxruntime.dll as its only ORT, and the TensorRT DLLs it delay-loads present in the runtime set.
    param([Parameter(Mandatory)][string]$Dll, [Parameter(Mandatory)][string]$TrtMajor, [Parameter(Mandatory)][string]$TensorRtBin)
    $imports = @(Get-PeImportNames -Path $Dll -IncludeDelayLoad)
    return @(
        Get-OrtPluginEpExportGap -Path $Dll -ForbidProviderBridge
        $imports | Where-Object { $_ -match '^onnxruntime' -and $_ -ne 'onnxruntime.dll' } | ForEach-Object { "imports $_, which is not the chain ORT" }
        foreach ($trt in "nvinfer_$TrtMajor.dll", "nvinfer_plugin_$TrtMajor.dll", "nvonnxparser_$TrtMajor.dll") {
            if ($imports -notcontains $trt) { "$(Split-Path -Leaf $Dll) does not import $trt" }
            elseif (-not (Test-Path -LiteralPath (Join-Path $TensorRtBin $trt) -PathType Leaf)) { "$trt is not in $TensorRtBin" }
        }
    )
}

function Copy-OrtTensorRtEpLicense {
    # The plugin links its seeds statically (/MT), so their texts travel with it.
    param([Parameter(Mandatory)][string]$EpDir, [Parameter(Mandatory)][System.Collections.IDictionary]$SourceRoot)
    $texts = [ordered]@{
        'onnxruntime-ep-tensorrt' = @('LICENSE'); protobuf = @('LICENSE', 'third_party\utf8_range\LICENSE')
        onnx = @('LICENSE'); gsl = @('LICENSE'); flatbuffers = @('LICENSE')
    }
    $sep = [IO.Path]::DirectorySeparatorChar
    $staged = foreach ($name in $texts.Keys) {
        foreach ($rel in $texts[$name]) {
            $from = Join-Path $SourceRoot[$name] ($rel -replace '\\', $sep)
            if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "$name`: licence file $rel not found in $($SourceRoot[$name]) (upstream moved it?)" }
            $to = "licenses\$name\$rel"
            $dest = Join-Path $EpDir ($to -replace '\\', $sep)
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)
            Copy-Item -LiteralPath $from -Destination $dest -Force
            $to
        }
    }
    return @($staged)
}

function Install-OrtTensorRtEpArtifact {
    # The DLL alone: the plugin finds TensorRT on PATH, so the 2 GB runtime set stays in TENSORRT_ROOT\current\bin only.
    param([Parameter(Mandatory)][string]$BuildDir, [Parameter(Mandatory)][System.Collections.IDictionary]$SourceRoot,
        [Parameter(Mandatory)][string]$EpDir, [Parameter(Mandatory)]$Pin)
    $built = Get-UniqueBuildArtifact -Root $BuildDir -Filter 'onnxruntime_ep_tensorrt.dll' -Context 'TensorRT plugin EP'
    Reset-SourceBuildDirectory -Path $EpDir
    # The reset removes the directory, and a copy to a missing one writes a file under its name.
    $null = New-Item -ItemType Directory -Force -Path $EpDir
    Copy-Item -LiteralPath $built.FullName -Destination $EpDir -Force
    $texts = Copy-OrtTensorRtEpLicense -EpDir $EpDir -SourceRoot $SourceRoot
    Write-NativeFileProvenance -Root $EpDir -Owner 'onnxruntime-ep-tensorrt' -File $built.Name -Notice $texts `
        -Source @{ Name = 'onnxruntime-ep-tensorrt'; Version = $Pin.Version; Sha256 = $Pin.Sha256; Url = $Pin.Url }
    return (Join-Path $EpDir $built.Name)
}

$epDir = Join-Path $InstallDir 'lib\onnxruntime-ep-tensorrt'
$ortPrefix = Join-Path $InstallDir 'lib\onnxruntime-source'
trap { Complete-SourceBuildFailure -Label 'onnxruntime-ep-tensorrt' -ErrorRecord $_; break }

Switch-BuildPhase '1. TensorRT SDK + pinned plugin and seed sources'
$gpuEnv = Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU'
if (-not $gpuEnv.HasCuda) {
    Write-Host 'TensorRT plugin EP: off -- not the nvidia lane'
    exit 0
}
if (Test-WindowsCrossTarget) {
    Write-Host 'TensorRT plugin EP: off -- NVIDIA ships no Windows arm64 TensorRT'
    exit 0
}
$trtSdk = $gpuEnv.TensorRtRoot
if (-not $trtSdk) { throw 'TensorRT plugin EP: the nvidia lane mounts no TensorRT SDK at TENSORRT_SDK_ROOT (Dockerfile.nvidia trt-extract)' }
$trtMajor = Get-OrtTensorRtMajor -SdkRoot $trtSdk
$pins = @(Get-OrtTensorRtEpPin)
Reset-SourceBuildDirectory -Path $SourceDir
$roots = [ordered]@{}
foreach ($pin in $pins) { $roots[$pin.Name] = Save-OrtTensorRtEpSource -Pin $pin -WorkDir $SourceDir }
$epSource = $roots['onnxruntime-ep-tensorrt']
$declared = Get-OrtTensorRtEpDeclaration -CMakeText ([IO.File]::ReadAllText((Join-Path $epSource 'CMakeLists.txt')))
$seedGap = @(Get-OrtTensorRtEpSeedGap -Declared $declared -Pin $pins)
if ($seedGap.Count -gt 0) { throw "TensorRT plugin EP: FetchContent would download unpinned: $($seedGap -join '; ')" }
$ortHome = New-OrtTensorRtEpHome -OrtPrefix $ortPrefix -Path (Join-Path $SourceDir 'ort-home')
Write-Host "TensorRT plugin EP $($pins[0].Version.Substring(0, 12)): TensorRT $trtMajor SDK $trtSdk, chain ORT $ortPrefix"

Switch-BuildPhase '2. configure (ORT_HOME over the chain ORT, every FetchContent seeded)'
$py = Initialize-ToolchainPythonEnvironment
$buildDir = Join-Path $SourceDir 'build'
$cfgLog = Get-PersistentBuildLogPath -Name 'ort-trt-ep-configure.log' -FallbackDir $SourceDir
$seedRoots = [ordered]@{}
foreach ($name in @($roots.Keys | Where-Object { $_ -ne 'onnxruntime-ep-tensorrt' })) { $seedRoots[$name] = $roots[$name] }
$trtArgs = Get-OrtTensorRtEpCmakeArgs -OrtHome $ortHome -TensorRtSdk $trtSdk -TrtMajor $trtMajor -CudaRoot $gpuEnv.CudaRoot -Python $py.Exe -SeedRoot $seedRoots
Invoke-CmakeConfigure -SourceDir $epSource -BuildDir $buildDir -InstallPrefix $epDir -BuildType $BuildType -ExtraArgs $trtArgs 2>&1 |
    Tee-Object -FilePath $cfgLog

Switch-BuildPhase '3. build'
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -Targets @('onnxruntime_ep_tensorrt') -RetryJobs 2
Write-SccacheStatsToStderr

Switch-BuildPhase '4. stage + verify'
$staged = Install-OrtTensorRtEpArtifact -BuildDir $buildDir -SourceRoot $roots -EpDir $epDir -Pin $pins[0]
$findings = @(Get-OrtTensorRtEpModuleFinding -Dll $staged -TrtMajor $trtMajor -TensorRtBin (Join-Path $trtSdk 'bin'))
if ($findings.Count -gt 0) { throw "TensorRT plugin EP check:`n  $($findings -join "`n  ")" }
# The plugin compiles against the shim's copies of the chain headers; a pass stamps it for the image census.
Assert-ChainOrtOnly -Consumer 'tensorrt-ep' -OrtRoot $ortPrefix -TreeRoot $SourceDir -Shim $ortHome -Log $cfgLog `
    -Record (Join-Path $buildDir 'CMakeCache.txt'), (Join-Path $buildDir 'build.ninja')
Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'onnxruntime-ep-tensorrt'
Complete-SourceBuild -Banner "=== TensorRT plugin EP build completed ($epDir) ===" -SourceDir $SourceDir
