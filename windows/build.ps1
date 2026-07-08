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

.PARAMETER MediaBranches
    Subset of the media fan-out to (re)build within the 'media' stage (default: all
    three): media-core, media-litert, media-tvm. Use this to rebuild ONE branch after a
    source fix without recompiling the others -- e.g. -MediaBranches media-litert rebuilds
    only the LiteRT/LiteRT-LM branch; the media merge that follows still fans in the other
    branches from their existing images. Unselected branches must already be built (their
    windows-media-<branch> image must exist) for the merge to succeed.

.PARAMETER Docker
    Path to docker.exe. Defaults to $env:DOCKER_EXE, then the Stevedore install
    locations, then docker on PATH.

.PARAMETER FinalTag
    Tag for the final developer image.

.PARAMETER MediaMemoryGb
    --memory limit (GB) for the run+commit stages (media-core, toolchain, and the
    merge/GStreamer stage). Forwarded as MEMORY_LIMIT_GB so the build scripts scale
    parallelism to the cap. Default 0 = AUTO-DETECT from host RAM: usable physical
    GB minus -HostReserveGb (and minus 2*AuxMemoryGb in concurrent mode). Since
    media-core parallelism is memory-bound (jobs = min(cpu-count, mem/per-job-GB),
    ONNX ~4 GB/job), maximizing this is what actually raises the ONNX job count.
    Pass an explicit value to override the auto-detection.

.PARAMETER HostReserveGb
    RAM (GB) to leave for the Windows host when auto-detecting -MediaMemoryGb
    (default 22). This is NOT just idle Windows: during a GPU build dockerd +
    containerd juggling the ~50 GB CUDA image layers, plus svchost/Defender, hold
    ~16-18 GB steady on this host — measured after a 53 GB container starved the
    host to 0.3 GB free and hung media-core at 0% CPU. 22 GB reserve keeps the
    container (~39 GB here) + host comfortably under physical RAM. Lower it only if
    you have verified the host's real footprint is smaller (riskier: under memory
    pressure the container starves and the compile deadlocks / hcsshim ttrpc wedges).

.PARAMETER AuxMemoryGb
    --memory limit (GB) for each auxiliary media branch (litert, tvm) when building
    concurrently (see -ConcurrentMedia). Ignored for the media-core budget in the
    default sequential mode. When concurrent, the auto -MediaMemoryGb leaves room
    for 2*AuxMemoryGb so MediaMemoryGb + 2*AuxMemoryGb fits host RAM.

.PARAMETER MediaCoreCpus
    CPU count for the media-core run+commit build (docker run --cpu-count N).
    Defaults to the host's logical processor count ([Environment]::ProcessorCount)
    so the heavy compile uses all cores automatically; pass a smaller value to cap
    it. `docker build` is hard-capped at 2 CPUs on this host and process isolation
    cannot commit layers, so media-core builds via docker run + docker commit,
    which DOES honor --cpu-count under Hyper-V. NOTE: actual ninja parallelism is
    min(MediaCoreCpus, MediaMemoryGb / per-job-GB), so it is MEMORY-bound, not
    core-bound — ONNX is ~4 GB/job, so at 48 GB it runs ~j12 even with 32 cores.
    More cores only help the lighter TUs (OpenCV/FFmpeg); true j32 on ONNX needs
    ~128 GB RAM, which this host does not have.

.PARAMETER SequentialMedia
    Build the media branches one after another. This is the DEFAULT (it gives
    media-core the whole host RAM budget, maximizing ONNX parallelism). Kept for
    backward compatibility / explicitness.

.PARAMETER ConcurrentMedia
    Overlap the aux branches (litert, tvm) underneath media-core instead of the
    default sequential schedule. Hides the aux wall-clock, but the auto
    -MediaMemoryGb must then reserve 2*AuxMemoryGb, so media-core gets less RAM
    (fewer ONNX jobs). On a memory-constrained host, sequential is usually faster
    overall because the ONNX long pole gets more RAM.

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
    .\windows\build.ps1 -Gpu -Stages media,final -MediaBranches media-litert -SequentialMedia
    # rebuild ONLY the litert branch (full cores via run+commit), re-merge, re-final
.EXAMPLE
    .\windows\build.ps1 -Gpu -SccacheEndpoint http://192.168.1.10:5000
#>
param(
    [switch]$Gpu,
    [switch]$NoCache,
    [ValidateSet('base', 'sdk', 'toolchain', 'media', 'final')]
    [string[]]$Stages = @('base', 'sdk', 'toolchain', 'media', 'final'),
    [ValidateSet('media-core', 'media-litert', 'media-tvm')]
    [string[]]$MediaBranches = @('media-core', 'media-litert', 'media-tvm'),
    [string]$Docker = '',
    [string]$FinalTag = '',
    [int]$MediaMemoryGb = 0,
    [int]$HostReserveGb = 22,
    [int]$AuxMemoryGb = 8,
    [int]$MediaCoreCpus = [Environment]::ProcessorCount,
    [switch]$SequentialMedia,
    [switch]$ConcurrentMedia,
    [string]$SccacheEndpoint = $env:SCCACHE_WEBDAV_ENDPOINT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot

# Transient hcsshim/containerd failures ("failed to create shim task: ttrpc:
# closed") intermittently kill container creation, typically right after a big
# layer commit. Both Invoke-Stage and the media fan-out classify failures against
# this single pattern.
$script:TransientPattern = 'ttrpc: closed|failed to create shim task|failed to create task for container|hcsshim|error during connect'

# CPU note: Hyper-V-isolated build containers get only 2 CPUs, pinning every
# in-container `ninja -j` to 2 (Get-BuildJobCount = min(ProcessorCount, memGB/perJob)).
# `docker build` on this host's classic builder offers NO working lever to raise it
# (--cpu-count rejected, --cpuset-cpus fails), and --isolation process — which would
# expose all host CPUs — cannot commit layers here (hcsshim::ActivateLayer 0x20). So
# `docker build` stages run at 2 CPUs. Raising this requires a docker-run+commit
# path (docker run --cpu-count N does honor the flag under Hyper-V).

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

# NVIDIA versions are shared with Linux (full semvers in versions.env).
# Windows consumes the dotted major.minor (13.3) derived here; Linux derives
# its apt hyphen form (13-3) inside linux/Dockerfile.nvidia.
$cudaMajorMinor = ((Get-Ver 'CUDA_VERSION') -split '\.')[0..1] -join '.'

# Default the final image tag from the canonical registry prefix so it can never
# drift from versions.env. Override with -FinalTag.
if ([string]::IsNullOrWhiteSpace($FinalTag)) {
    $FinalTag = (Get-Ver 'IMAGE_REGISTRY_PREFIX') + ':winamd64'
}

function Get-DockerBuildArgList {
    param(
        [Parameter(Mandatory)] [string]$Dockerfile,
        [Parameter(Mandatory)] [string]$Tag,
        [hashtable]$BuildArgs = @{},
        [string[]]$ExtraFlags = @()
    )
    # NB: no --progress flag — Stevedore's classic builder (no BuildKit on
    # Windows Containers) rejects it.
    $dockerArgs = @('build')
    if ($NoCache) { $dockerArgs += '--no-cache' }
    # NB: we deliberately do NOT pass --isolation process. On this host process
    # isolation cannot commit ANY file-writing layer: hcsshim::ActivateLayer fails
    # 0x20 ("file used by another process"), reproduced even for a 100 MB dummy
    # layer and NOT caused by Defender/Search/SysMain (all ruled out). Hyper-V
    # isolation (the default) commits reliably but is hard-capped at 2 CPUs for
    # `docker build` (--cpu-count is rejected, --cpuset-cpus fails). Getting >2 CPUs
    # needs a `docker run --cpu-count N` + `docker commit` path, not a build flag.
    # See docs/windows-builds.md § Build isolation and CPU parallelism.
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
    # Capture output and retry up to twice with a cool-down; cached layers make
    # each retry resume at the failed step. Non-transient errors throw immediately.
    $dockerArgs = Get-DockerBuildArgList -Dockerfile $Dockerfile -Tag $Tag -BuildArgs $BuildArgs -ExtraFlags $ExtraFlags
    $stageLog = Join-Path ([System.IO.Path]::GetTempPath()) ("stage-" + [IO.Path]::GetFileName($Dockerfile) + ".log")
    foreach ($attempt in 1..3) {
        Write-Host "`n==> docker $($dockerArgs -join ' ')" -ForegroundColor Cyan
        & $Docker @dockerArgs 2>&1 | Tee-Object -FilePath $stageLog
        if ($LASTEXITCODE -eq 0) { return }
        $tail = Get-Content $stageLog -Tail 10 | Out-String
        if ($attempt -lt 3 -and $tail -match $script:TransientPattern) {
            Write-Host "[$Dockerfile] transient container-infrastructure failure — retry $attempt/2 in 60s" -ForegroundColor Yellow
            Start-Sleep -Seconds 60
            continue
        }
        throw "docker build failed for $Dockerfile (exit $LASTEXITCODE)"
    }
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
                CUDA_ARCHITECTURES        = Get-Ver 'CUDA_ARCHITECTURES'
                MEMORY_LIMIT_GB           = $MediaMemoryGb
            } + $sccache
        },
        @{
            Name              = 'media-litert'
            Dockerfile        = 'windows/Dockerfile.media-litert'          # concurrent path: 2-CPU docker build
            BuilderDockerfile = 'windows/Dockerfile.media-litert-builder'  # sequential path: run+commit (full cores)
            BuilderTag        = 'local/kataglyphis:windows-media-litert-builder'
            ContainerName     = 'kataglyphis-media-litert-build'
            RunScript         = 'build-litert-all.ps1'
            Tag               = 'local/kataglyphis:windows-media-litert'
            MemoryGb          = $AuxMemoryGb
            BuildArgs  = @{
                BASE_IMAGE        = 'local/kataglyphis:windows-toolchain'
                LITERT_VERSION    = Get-Ver 'LITERT_VERSION'
                LITERT_LM_VERSION = Get-Ver 'LITERT_LM_VERSION'
                MEMORY_LIMIT_GB   = $AuxMemoryGb
            } + $sccache
        },
        @{
            Name              = 'media-tvm'
            Dockerfile        = 'windows/Dockerfile.media-tvm'          # concurrent path: 2-CPU docker build
            BuilderDockerfile = 'windows/Dockerfile.media-tvm-builder'  # sequential path: run+commit (full cores)
            BuilderTag        = 'local/kataglyphis:windows-media-tvm-builder'
            ContainerName     = 'kataglyphis-media-tvm-build'
            RunScript         = 'build-tvm-from-source.ps1'
            Tag               = 'local/kataglyphis:windows-media-tvm'
            MemoryGb          = $AuxMemoryGb
            BuildArgs  = @{
                BASE_IMAGE      = 'local/kataglyphis:windows-toolchain'
                TVM_REF         = Get-Ver 'TVM_REF'
                MEMORY_LIMIT_GB = $AuxMemoryGb
            } + $sccache
        }
    )
}

function Invoke-RunCommitStage {
    # Generic run+commit builder: the ONLY way to exceed the 2-CPU `docker build`
    # cap on this host while still producing a committable image. `docker build` is
    # hard-capped at 2 CPUs (Hyper-V) and process isolation cannot commit ANY layer
    # (hcsshim::ActivateLayer 0x20 — the wcifs detach bug, re-verify with
    # windows/diagnostics/test-process-isolation-commit.ps1). So:
    #   1. `docker build` a THIN builder image (cheap COPY/clone layers commit fine
    #      under Hyper-V) carrying the sources + build scripts but NO heavy compile.
    #   2. `docker run --isolation hyperv --cpu-count N` the heavy compile — `docker
    #      run` DOES honor --cpu-count under Hyper-V (unlike `docker build`).
    #   3. `docker commit` the container to $ResultTag.
    # There is no per-stage layer cache inside the run; the sccache remote (when set)
    # covers recompilation. Used by media-core, toolchain (CPython), and the
    # media/GStreamer merge. See docs/windows-builds.md § Build isolation and CPU
    # parallelism.
    param(
        [Parameter(Mandatory)] [string]$BuilderDockerfile,
        [Parameter(Mandatory)] [string]$BuilderTag,
        [Parameter(Mandatory)] [string]$ResultTag,
        [Parameter(Mandatory)] [string]$ContainerName,
        [Parameter(Mandatory)] [string[]]$RunCommand,
        [Parameter(Mandatory)] [int]$Cpus,
        [Parameter(Mandatory)] [int]$MemoryGb,
        [hashtable]$BuildArgs = @{},
        [string]$Label = '',
        [string]$OutLog
    )
    if (-not $Label) { $Label = $ResultTag }

    # 1. Thin builder image via the shared Invoke-Stage (retry + transient handling).
    Invoke-Stage -Dockerfile $BuilderDockerfile -Tag $BuilderTag -BuildArgs $BuildArgs

    # 2. Heavy work via docker run, then commit; retry the run only on transient infra errors.
    $runArgs = @('run', '--isolation', 'hyperv', '--cpu-count', "$Cpus", '--memory', "${MemoryGb}g",
        '--name', $ContainerName, $BuilderTag) + $RunCommand
    foreach ($attempt in 1..3) {
        & $Docker container rm -f $ContainerName 2>&1 | Out-Null
        Write-Host "`n==> [$Label] docker run --isolation hyperv --cpu-count $Cpus --memory ${MemoryGb}g (attempt $attempt)" -ForegroundColor Cyan
        if ($OutLog) { & $Docker @runArgs 2>&1 | Tee-Object -FilePath $OutLog }
        else { & $Docker @runArgs 2>&1 }
        $runExit = $LASTEXITCODE
        if ($runExit -eq 0) {
            & $Docker commit $ContainerName $ResultTag 2>&1 | ForEach-Object { Write-Host $_ }
            $commitExit = $LASTEXITCODE
            & $Docker container rm -f $ContainerName 2>&1 | Out-Null
            if ($commitExit -ne 0) { throw "$Label commit failed (exit $commitExit)" }
            Write-Host "$Label built via run+commit ($Cpus CPUs) -> $ResultTag" -ForegroundColor Green
            return
        }
        $tail = if ($OutLog -and (Test-Path $OutLog)) { Get-Content $OutLog -Tail 15 | Out-String } else { '' }
        & $Docker container rm -f $ContainerName 2>&1 | Out-Null
        if ($attempt -lt 3 -and $tail -match $script:TransientPattern) {
            Write-Host "[$Label] transient container-infrastructure failure — retry $attempt/2 in 60s" -ForegroundColor Yellow
            Start-Sleep -Seconds 60
            continue
        }
        throw "$Label compile (docker run) failed (exit $runExit)"
    }
}

function Invoke-MediaCoreRunCommit {
    # media-core: ONNX -> GenAI -> OpenCV -> FFmpeg chain via the run+commit path.
    param(
        [Parameter(Mandatory)] [hashtable]$BuildArgs,
        [Parameter(Mandatory)] [int]$Cpus,
        [Parameter(Mandatory)] [int]$MemoryGb,
        [string]$OutLog
    )
    Invoke-RunCommitStage `
        -BuilderDockerfile 'windows/Dockerfile.media-core-builder' `
        -BuilderTag    'local/kataglyphis:windows-media-core-builder' `
        -ResultTag     'local/kataglyphis:windows-media-core' `
        -ContainerName 'kataglyphis-media-core-build' `
        -RunCommand    @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\temp\scripts\build-media-core-all.ps1') `
        -Cpus $Cpus -MemoryGb $MemoryGb -BuildArgs $BuildArgs -Label 'media-core' -OutLog $OutLog
}

function Invoke-MediaBranches {
    $specs    = Get-MediaBranchSpecs
    # -MediaBranches subsets the fan-out (rebuild one branch after a source fix without
    # recompiling the others). The merge that follows still fans in the unselected branches
    # from their existing windows-media-<branch> images.
    $specs    = @($specs | Where-Object { $MediaBranches -contains $_.Name })
    if ($specs.Count -eq 0) { throw "no media branches selected (-MediaBranches: $($MediaBranches -join ', '))" }
    if ($specs.Count -lt 3) { Write-Host "==> media fan-out limited to: $(@($specs | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Yellow }
    $coreSpec = $specs | Where-Object { $_.Name -eq 'media-core' } | Select-Object -First 1
    $auxSpecs = @($specs | Where-Object { $_.Name -ne 'media-core' })
    $logDir   = Join-Path $repoRoot 'out\windows-build-logs'
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    $coreLog  = Join-Path $logDir 'media-core.log'

    if ($script:UseSequentialMedia) {
        if ($coreSpec) {
            Invoke-MediaCoreRunCommit -BuildArgs $coreSpec.BuildArgs -Cpus $MediaCoreCpus `
                -MemoryGb $coreSpec.MemoryGb -OutLog $coreLog
        }
        # Aux branches (litert, tvm) also via run+commit at FULL cores + RAM. In
        # sequential mode media-core is already committed, so the whole CPU/RAM budget
        # is free — no reason to leave the aux compiles pinned to the 2-CPU `docker
        # build` cap. Parallelism stays memory-bound (jobs = min(cpu-count,
        # MEMORY_LIMIT_GB / perJob)), so we forward MediaMemoryGb (not AuxMemoryGb):
        # e.g. j2 @ 2cpu/8g  ->  ~j19 @ 32cpu/39g on this host.
        foreach ($spec in $auxSpecs) {
            $auxArgs = $spec.BuildArgs.Clone()
            $auxArgs['MEMORY_LIMIT_GB'] = $MediaMemoryGb
            $auxLog = Join-Path $logDir "$($spec.Name).log"
            Invoke-RunCommitStage `
                -BuilderDockerfile $spec.BuilderDockerfile `
                -BuilderTag        $spec.BuilderTag `
                -ResultTag         $spec.Tag `
                -ContainerName     $spec.ContainerName `
                -RunCommand        @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "C:\temp\scripts\$($spec.RunScript)") `
                -Cpus $MediaCoreCpus -MemoryGb $MediaMemoryGb -BuildArgs $auxArgs -Label $spec.Name -OutLog $auxLog
        }
        return
    }

    # Concurrent: launch the aux branches (docker build, 2 CPUs each) in the
    # background, then run media-core (run+commit, N CPUs) in the foreground — it is
    # the long pole, so the aux builds finish underneath it.
    $procs = @()
    foreach ($spec in $auxSpecs) {
        # Stagger container creation: launching several builds in the same instant
        # can trip hcsshim/containerd ("failed to create shim task: ttrpc: closed").
        Start-Sleep -Seconds 20
        $argList = Get-DockerBuildArgList -Dockerfile $spec.Dockerfile -Tag $spec.Tag `
            -BuildArgs $spec.BuildArgs -ExtraFlags @('--memory', "$($spec.MemoryGb)g")
        $outLog = Join-Path $logDir "$($spec.Name).log"
        $errLog = Join-Path $logDir "$($spec.Name).err.log"
        Write-Host "==> [$($spec.Name)] docker $($argList -join ' ')" -ForegroundColor Cyan
        Write-Host "    log: $outLog"
        $proc = Start-Process -FilePath $Docker -ArgumentList $argList `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
        $procs += @{ Spec = $spec; Proc = $proc; Log = $outLog; ErrLog = $errLog }
    }

    $coreFailed = $false; $coreError = $null
    if ($coreSpec) {
        Write-Host "`n==> [media-core] run+commit on $MediaCoreCpus CPUs; $($procs.Count) aux branch(es) building concurrently (log: $coreLog)" -ForegroundColor Cyan
        try {
            Invoke-MediaCoreRunCommit -BuildArgs $coreSpec.BuildArgs -Cpus $MediaCoreCpus `
                -MemoryGb $coreSpec.MemoryGb -OutLog $coreLog
        } catch { $coreFailed = $true; $coreError = $_ }
    }
    elseif ($procs.Count -gt 0) {
        Write-Host "`n==> media-core not selected; waiting on $($procs.Count) aux branch(es) (2-CPU docker build)" -ForegroundColor Cyan
    }

    # Wait for the aux branches to finish (media-core already done in the foreground).
    $lastBeat = Get-Date
    while (@($procs | Where-Object { -not $_.Proc.HasExited }).Count -gt 0) {
        if (((Get-Date) - $lastBeat).TotalSeconds -ge 120) {
            $status = ($procs | ForEach-Object {
                $state = if ($_.Proc.HasExited) { "done(exit $($_.Proc.ExitCode))" } else { 'running' }
                "$($_.Spec.Name)=$state"
            }) -join ', '
            Write-Host "[media aux $(Get-Date -Format HH:mm:ss)] $status"
            $lastBeat = Get-Date
        }
        Start-Sleep -Seconds 10
    }
    $failed = @($procs | Where-Object { $_.Proc.ExitCode -ne 0 })

    # Transient-infrastructure failures (container never started) get a foreground
    # retry via Invoke-Stage — layer caching resumes at the failed step, so this is
    # cheap, and Invoke-Stage already owns the cool-down + transient-vs-real retry
    # loop. Non-transient failures are collected and reported without a retry.
    $stillFailed = @()
    foreach ($f in $failed) {
        $logText = @($f.Log, $f.ErrLog) | Where-Object { Test-Path $_ } | ForEach-Object { Get-Content $_ -Tail 10 } | Out-String
        if ($logText -match $script:TransientPattern) {
            Write-Host "`n[$($f.Spec.Name)] transient container-infrastructure failure — retrying in the foreground" -ForegroundColor Yellow
            try {
                Invoke-Stage -Dockerfile $f.Spec.Dockerfile -Tag $f.Spec.Tag `
                    -BuildArgs $f.Spec.BuildArgs -ExtraFlags @('--memory', "$($f.Spec.MemoryGb)g")
            } catch {
                $stillFailed += $f
            }
        } else {
            $stillFailed += $f
        }
    }

    foreach ($f in $stillFailed) {
        Write-Host "`n=== [$($f.Spec.Name)] FAILED (exit $($f.Proc.ExitCode)) — last 40 log lines ===" -ForegroundColor Red
        foreach ($log in @($f.Log, $f.ErrLog)) {
            if (Test-Path $log) { Get-Content $log -Tail 40 | ForEach-Object { Write-Host "  $_" } }
        }
    }

    $failNames = @()
    if ($coreFailed) {
        Write-Host "`n=== [media-core] FAILED (run+commit) ===" -ForegroundColor Red
        Write-Host "  $coreError"
        if (Test-Path $coreLog) { Get-Content $coreLog -Tail 40 | ForEach-Object { Write-Host "  $_" } }
        $failNames += 'media-core'
    }
    $failNames += @($stillFailed | ForEach-Object { $_.Spec.Name })
    if ($failNames.Count -gt 0) {
        throw "media branch build(s) failed: $($failNames -join ', ')"
    }
    Write-Host 'All media branches built.' -ForegroundColor Green
}

# ---- resolve media scheduling + auto-detect the run+commit memory budget ----
# Sequential is the default (media-core gets the whole RAM budget → most ONNX jobs);
# -ConcurrentMedia overlaps the aux branches; -SequentialMedia forces sequential.
$script:UseSequentialMedia = -not $ConcurrentMedia
if ($SequentialMedia) { $script:UseSequentialMedia = $true }

# -MediaMemoryGb 0 = auto-detect from host RAM. In sequential mode media-core runs
# alone, so it gets usable-RAM minus the host reserve; in concurrent mode it must
# also leave room for the two aux branches (2*AuxMemoryGb).
if ($MediaMemoryGb -le 0) {
    $usableGb = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $reserve  = $HostReserveGb + $(if ($script:UseSequentialMedia) { 0 } else { 2 * $AuxMemoryGb })
    $MediaMemoryGb = [math]::Max(8, $usableGb - $reserve)
    Write-Host ("Auto-detected -MediaMemoryGb=${MediaMemoryGb}g (usable ${usableGb}GB - ${reserve}GB reserve; mode=$(if ($script:UseSequentialMedia) { 'sequential' } else { 'concurrent' }); cores=$MediaCoreCpus)") -ForegroundColor Cyan
} else {
    Write-Host ("-MediaMemoryGb=${MediaMemoryGb}g (explicit); mode=$(if ($script:UseSequentialMedia) { 'sequential' } else { 'concurrent' }); cores=$MediaCoreCpus") -ForegroundColor Cyan
}

$started = Get-Date

try {
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
                CUDNN_VERSION            = Get-Ver 'CUDNN_VERSION'
                TENSORRT_VERSION         = Get-Ver 'TENSORRT_VERSION'
            }
        } else {
            Write-Host "`n==> CPU lane: tagging windows-base as windows-sdk (no GPU layer)" -ForegroundColor Cyan
            & $Docker tag local/kataglyphis:windows-base local/kataglyphis:windows-sdk
            if ($LASTEXITCODE -ne 0) { throw 'docker tag failed' }
        }
    }

    if ($Stages -contains 'toolchain') {
        # CPython build.bat is CPU-bound, so it uses the run+commit path for full
        # cores instead of the 2-CPU `docker build`. The thin builder clones CPython
        # + writes Directory.Build.props (cheap, IO-bound); the run does the compile.
        $tcLog = Join-Path $repoRoot 'out\windows-build-logs\toolchain.log'
        New-Item -Path (Split-Path $tcLog) -ItemType Directory -Force | Out-Null
        Invoke-RunCommitStage `
            -BuilderDockerfile 'windows/Dockerfile.toolchain-builder' `
            -BuilderTag    'local/kataglyphis:windows-toolchain-builder' `
            -ResultTag     'local/kataglyphis:windows-toolchain' `
            -ContainerName 'kataglyphis-toolchain-build' `
            -RunCommand    @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\temp\scripts\build-toolchain-all.ps1') `
            -Cpus $MediaCoreCpus -MemoryGb $MediaMemoryGb `
            -BuildArgs @{
                BASE_IMAGE     = 'local/kataglyphis:windows-sdk'
                PYTHON_VERSION = Get-Ver 'PYTHON_VERSION'
            } `
            -Label 'toolchain' -OutLog $tcLog
    }

    if ($Stages -contains 'media') {
        # Fan-out: three branch images concurrently, then fan-in (merge + GStreamer).
        Invoke-MediaBranches
        # The merge stage splits: the fan-in (COPY --from of the three branch trees)
        # MUST be a `docker build` — `docker run` cannot COPY --from — but it is only
        # IO, so 2 CPUs is fine. The CPU-bound GStreamer compile then runs via the
        # run+commit path (Dockerfile.media-merge-builder carries the merged tree +
        # env + GStreamer scripts but does NOT run the compile; the run does).
        $gstLog = Join-Path $repoRoot 'out\windows-build-logs\gstreamer.log'
        New-Item -Path (Split-Path $gstLog) -ItemType Directory -Force | Out-Null
        Invoke-RunCommitStage `
            -BuilderDockerfile 'windows/Dockerfile.media-merge-builder' `
            -BuilderTag    'local/kataglyphis:windows-media-merge-builder' `
            -ResultTag     'local/kataglyphis:windows-media' `
            -ContainerName 'kataglyphis-media-merge-build' `
            -RunCommand    @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\temp\scripts\build-gstreamer-from-source.ps1', '-InstallDir', 'C:\runtime', '-LogDir', 'C:\temp\logs') `
            -Cpus $MediaCoreCpus -MemoryGb $MediaMemoryGb `
            -BuildArgs @{
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
            } `
            -Label 'media-merge+gstreamer' -OutLog $gstLog
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
}
finally {
    Pop-Location
}
