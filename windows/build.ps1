# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Builds the Windows container image chain: base -> [nvidia] -> toolchain -> media -> final.

.DESCRIPTION
    Single driver for the staged Windows build (see docs/windows-builds.md).
    Reads canonical versions from linux/scripts/01-core/versions.env and passes
    them as --build-arg so the Dockerfile ARG defaults can never drift from the
    single source of truth.

    Layer caching is ON by default — the Dockerfiles are ordered so that script
    edits only invalidate their own stage. Use -NoCache for a deliberate clean
    rebuild.

    The media stage fans out into three branch images built CONCURRENTLY
    (media-core: ONNX->GenAI->OpenCV->FFmpeg; media-litert: LiteRT->LiteRT-LM;
    media-tvm: TVM), then fans in via Dockerfile.media (merge + GStreamer).
    Use -SequentialMedia to build the branches one after another on
    memory-constrained hosts.

    The former Dockerfile.sdk no-op shim is replaced by a `docker tag`:
      - CPU lane (default): windows-base is tagged as windows-sdk.
      - GPU lane (-Gpu):    Dockerfile.nvidia builds FROM windows-base and is
                            tagged windows-sdk (requires the TensorRT zip in
                            windows/downloads/, see versions.env).

.PARAMETER Gpu
    Build the NVIDIA GPU layer (CUDA + cuDNN + TensorRT) as the sdk stage.

.PARAMETER NoCache
    Pass --no-cache to every docker build (full rebuild).

.PARAMETER Stages
    Subset of stages to build (default: all, in order): base, sdk, toolchain, media, final.

.PARAMETER Docker
    Path to docker.exe. Defaults to $env:DOCKER_EXE, then the Stevedore install
    locations, then docker on PATH.

.PARAMETER FinalTag
    Tag for the final developer image.

.PARAMETER MediaMemoryGb
    --memory limit (GB) for the media-core branch and the merge/GStreamer stage.
    Forwarded as MEMORY_LIMIT_GB so the build scripts scale their parallelism to
    the cap instead of host RAM.

.PARAMETER AuxMemoryGb
    --memory limit (GB) for each auxiliary media branch (litert, tvm) when
    building concurrently. Sized so MediaMemoryGb + 2*AuxMemoryGb roughly fits
    host RAM.

.PARAMETER SequentialMedia
    Build the media branches one after another instead of concurrently.

.PARAMETER SccacheEndpoint
    Optional sccache WebDAV endpoint reachable FROM INSIDE build containers
    (e.g. http://<host-lan-ip>:5000). Enables a persistent cross-build compile
    cache; empty disables sccache entirely (a container-local cache would only
    bloat layers). See docs/windows-builds.md § Persistent compile cache.

.EXAMPLE
    .\windows\build.ps1 -Gpu
.EXAMPLE
    .\windows\build.ps1 -Gpu -Stages media,final   # iterate on media only
.EXAMPLE
    .\windows\build.ps1 -Gpu -SccacheEndpoint http://192.168.1.10:5000
#>
param(
    [switch]$Gpu,
    [switch]$NoCache,
    [ValidateSet('base', 'sdk', 'toolchain', 'media', 'final')]
    [string[]]$Stages = @('base', 'sdk', 'toolchain', 'media', 'final'),
    [string]$Docker = '',
    [string]$FinalTag = 'ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64',
    [int]$MediaMemoryGb = 48,
    [int]$AuxMemoryGb = 8,
    [switch]$SequentialMedia,
    [string]$SccacheEndpoint = $env:SCCACHE_WEBDAV_ENDPOINT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

# ---- resolve docker CLI (Stevedore's docker.exe preferred; nerdctl build has broken DNS) ----
if ([string]::IsNullOrWhiteSpace($Docker)) {
    $candidates = @(
        $env:DOCKER_EXE,
        'D:\Stevedore\bin\docker.exe',
        (Join-Path $env:ProgramFiles 'Stevedore\bin\docker.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }
    $Docker = if ($candidates) { @($candidates)[0] } else { (Get-Command docker -ErrorAction Stop).Source }
}
Write-Host "Using docker: $Docker"

# ---- load canonical versions (single source of truth) ----
$versionsFile = Join-Path $repoRoot 'linux\scripts\01-core\versions.env'
if (-not (Test-Path $versionsFile)) { throw "versions.env not found at $versionsFile" }
$versions = @{}
Get-Content $versionsFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and $line -notmatch '^#') {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) { $versions[$parts[0].Trim()] = $parts[1].Trim().Trim('"', "'") }
    }
}
function Get-Ver([string]$Name) {
    if (-not $versions.ContainsKey($Name)) { throw "versions.env is missing $Name" }
    return $versions[$Name]
}

# Windows uses dot notation (13.3); versions.env keeps the Linux apt hyphen form (13-3).
$cudaMajorMinor = ((Get-Ver 'CUDA_VERSION') -split '\.')[0..1] -join '.'

function Get-DockerBuildArgList {
    param(
        [Parameter(Mandatory)] [string]$Dockerfile,
        [Parameter(Mandatory)] [string]$Tag,
        [hashtable]$BuildArgs = @{},
        [string[]]$ExtraFlags = @()
    )
    $dockerArgs = @('build', '--progress=plain')
    if ($NoCache) { $dockerArgs += '--no-cache' }
    foreach ($key in ($BuildArgs.Keys | Sort-Object)) {
        $value = $BuildArgs[$key]
        if ($null -ne $value -and "$value" -ne '') { $dockerArgs += '--build-arg', "$key=$value" }
    }
    $dockerArgs += $ExtraFlags
    $dockerArgs += '-t', $Tag, '-f', $Dockerfile, '.'
    return $dockerArgs
}

function Invoke-Stage {
    param(
        [Parameter(Mandatory)] [string]$Dockerfile,
        [Parameter(Mandatory)] [string]$Tag,
        [hashtable]$BuildArgs = @{},
        [string[]]$ExtraFlags = @()
    )
    $dockerArgs = Get-DockerBuildArgList -Dockerfile $Dockerfile -Tag $Tag -BuildArgs $BuildArgs -ExtraFlags $ExtraFlags
    Write-Host "`n==> docker $($dockerArgs -join ' ')" -ForegroundColor Cyan
    & $Docker @dockerArgs
    if ($LASTEXITCODE -ne 0) { throw "docker build failed for $Dockerfile (exit $LASTEXITCODE)" }
}

# Common per-branch args for the media fan-out
function Get-MediaBranchSpecs {
    $sccache = @{ SCCACHE_WEBDAV_ENDPOINT = $SccacheEndpoint }
    @(
        @{
            Name       = 'media-core'
            Dockerfile = 'windows/Dockerfile.media-core'
            Tag        = 'local/kataglyphis:windows-media-core'
            MemoryGb   = $MediaMemoryGb
            BuildArgs  = @{
                BASE_IMAGE                = 'local/kataglyphis:windows-toolchain'
                ONNXRUNTIME_VERSION       = Get-Ver 'ONNXRUNTIME_VERSION'
                ONNXRUNTIME_GENAI_VERSION = Get-Ver 'ONNXRUNTIME_GENAI_VERSION'
                OPENCV_SOURCE_VERSION     = Get-Ver 'OPENCV_VERSION'
                FFMPEG_VERSION            = Get-Ver 'FFMPEG_VERSION'
                MEMORY_LIMIT_GB           = $MediaMemoryGb
            } + $sccache
        },
        @{
            Name       = 'media-litert'
            Dockerfile = 'windows/Dockerfile.media-litert'
            Tag        = 'local/kataglyphis:windows-media-litert'
            MemoryGb   = $AuxMemoryGb
            BuildArgs  = @{
                BASE_IMAGE        = 'local/kataglyphis:windows-toolchain'
                LITERT_VERSION    = Get-Ver 'LITERT_VERSION'
                LITERT_LM_VERSION = Get-Ver 'LITERT_LM_VERSION'
                MEMORY_LIMIT_GB   = $AuxMemoryGb
            } + $sccache
        },
        @{
            Name       = 'media-tvm'
            Dockerfile = 'windows/Dockerfile.media-tvm'
            Tag        = 'local/kataglyphis:windows-media-tvm'
            MemoryGb   = $AuxMemoryGb
            BuildArgs  = @{
                BASE_IMAGE      = 'local/kataglyphis:windows-toolchain'
                TVM_REF         = Get-Ver 'TVM_REF'
                MEMORY_LIMIT_GB = $AuxMemoryGb
            } + $sccache
        }
    )
}

function Invoke-MediaBranches {
    $specs = Get-MediaBranchSpecs
    if ($SequentialMedia) {
        foreach ($spec in $specs) {
            Invoke-Stage -Dockerfile $spec.Dockerfile -Tag $spec.Tag -BuildArgs $spec.BuildArgs `
                -ExtraFlags @('--memory', "$($spec.MemoryGb)g")
        }
        return
    }

    $logDir = Join-Path $repoRoot 'out\windows-build-logs'
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    $procs = @()
    foreach ($spec in $specs) {
        $argList = Get-DockerBuildArgList -Dockerfile $spec.Dockerfile -Tag $spec.Tag `
            -BuildArgs $spec.BuildArgs -ExtraFlags @('--memory', "$($spec.MemoryGb)g")
        $outLog = Join-Path $logDir "$($spec.Name).log"
        $errLog = Join-Path $logDir "$($spec.Name).err.log"
        Write-Host "==> [$($spec.Name)] docker $($argList -join ' ')" -ForegroundColor Cyan
        Write-Host "    log: $outLog"
        # NB: docker's --progress=plain output goes to stderr — the .err.log is the live one
        $proc = Start-Process -FilePath $Docker -ArgumentList $argList `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
        $procs += @{ Spec = $spec; Proc = $proc; Log = $outLog; ErrLog = $errLog }
    }

    Write-Host "`nBuilding $($procs.Count) media branches concurrently (tail the logs above for live progress)..."
    $lastBeat = Get-Date
    while ($true) {
        $alive = @($procs | Where-Object { -not $_.Proc.HasExited })
        if ($alive.Count -eq 0) { break }
        if (((Get-Date) - $lastBeat).TotalSeconds -ge 120) {
            $status = ($procs | ForEach-Object {
                $state = if ($_.Proc.HasExited) { "done(exit $($_.Proc.ExitCode))" } else { 'running' }
                "$($_.Spec.Name)=$state"
            }) -join ', '
            Write-Host "[media fan-out $(Get-Date -Format HH:mm:ss)] $status"
            $lastBeat = Get-Date
        }
        Start-Sleep -Seconds 10
    }

    $failed = @($procs | Where-Object { $_.Proc.ExitCode -ne 0 })
    foreach ($f in $failed) {
        Write-Host "`n=== [$($f.Spec.Name)] FAILED (exit $($f.Proc.ExitCode)) — last 40 log lines ===" -ForegroundColor Red
        foreach ($log in @($f.Log, $f.ErrLog)) {
            if (Test-Path $log) { Get-Content $log -Tail 40 | ForEach-Object { Write-Host "  $_" } }
        }
    }
    if ($failed.Count -gt 0) {
        throw "media branch build(s) failed: $(($failed | ForEach-Object { $_.Spec.Name }) -join ', ')"
    }
    Write-Host 'All media branches built.' -ForegroundColor Green
}

$started = Get-Date

if ($Stages -contains 'base') {
    Invoke-Stage -Dockerfile 'windows/Dockerfile.base' -Tag 'local/kataglyphis:windows-base' -BuildArgs @{
        WINDOWS_LTSC   = Get-Ver 'WINDOWS_LTSC'
        VULKAN_VERSION = Get-Ver 'VULKAN_VERSION'
        CMAKE_VERSION  = Get-Ver 'CMAKE_VERSION'
    }
}

if ($Stages -contains 'sdk') {
    if ($Gpu) {
        Invoke-Stage -Dockerfile 'windows/Dockerfile.nvidia' -Tag 'local/kataglyphis:windows-sdk' -BuildArgs @{
            BASE_IMAGE               = 'local/kataglyphis:windows-base'
            CUDA_VERSION             = Get-Ver 'CUDA_VERSION'
            CUDA_VERSION_MAJOR_MINOR = $cudaMajorMinor
            CUDNN_VERSION            = Get-Ver 'CUDNN_VERSION_WINDOWS'
            TENSORRT_VERSION         = Get-Ver 'TENSORRT_VERSION_WINDOWS'
        }
    } else {
        Write-Host "`n==> CPU lane: tagging windows-base as windows-sdk (no GPU layer)" -ForegroundColor Cyan
        & $Docker tag local/kataglyphis:windows-base local/kataglyphis:windows-sdk
        if ($LASTEXITCODE -ne 0) { throw 'docker tag failed' }
    }
}

if ($Stages -contains 'toolchain') {
    Invoke-Stage -Dockerfile 'windows/Dockerfile.toolchain' -Tag 'local/kataglyphis:windows-toolchain' -BuildArgs @{
        BASE_IMAGE     = 'local/kataglyphis:windows-sdk'
        PYTHON_VERSION = Get-Ver 'PYTHON_VERSION'
    }
}

if ($Stages -contains 'media') {
    # Fan-out: three branch images concurrently, then fan-in (merge + GStreamer).
    Invoke-MediaBranches
    Invoke-Stage -Dockerfile 'windows/Dockerfile.media' -Tag 'local/kataglyphis:windows-media' `
        -ExtraFlags @('--memory', "$($MediaMemoryGb)g") -BuildArgs @{
        BASE_IMAGE                = 'local/kataglyphis:windows-toolchain'
        CORE_IMAGE                = 'local/kataglyphis:windows-media-core'
        LITERT_IMAGE              = 'local/kataglyphis:windows-media-litert'
        TVM_IMAGE                 = 'local/kataglyphis:windows-media-tvm'
        GSTREAMER_VERSION         = Get-Ver 'GSTREAMER_VERSION'
        ONNXRUNTIME_VERSION       = Get-Ver 'ONNXRUNTIME_VERSION'
        ONNXRUNTIME_GENAI_VERSION = Get-Ver 'ONNXRUNTIME_GENAI_VERSION'
        OPENCV_SOURCE_VERSION     = Get-Ver 'OPENCV_VERSION'
        FFMPEG_VERSION            = Get-Ver 'FFMPEG_VERSION'
        LITERT_VERSION            = Get-Ver 'LITERT_VERSION'
        LITERT_LM_VERSION         = Get-Ver 'LITERT_LM_VERSION'
        TVM_REF                   = Get-Ver 'TVM_REF'
        MEMORY_LIMIT_GB           = $MediaMemoryGb
    }
}

if ($Stages -contains 'final') {
    $vcsRef = ''
    try { $vcsRef = (& git rev-parse --short HEAD 2>$null); if ($LASTEXITCODE -ne 0) { $vcsRef = '' } } catch { }
    Invoke-Stage -Dockerfile 'windows/Dockerfile' -Tag $FinalTag -BuildArgs @{
        BASE_IMAGE = 'local/kataglyphis:windows-media'
        BUILD_DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        VCS_REF    = $vcsRef
    }
}

$elapsed = (Get-Date) - $started
Write-Host ("`nDone in {0:hh\:mm\:ss}. Stages built: {1}{2}" -f $elapsed, ($Stages -join ', '), $(if ($Gpu) { ' (GPU lane)' } else { ' (CPU lane)' }))
